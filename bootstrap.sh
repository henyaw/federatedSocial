#!/usr/bin/env bash
# bootstrap.sh — unified operator interface for the federated-social stack.
#
# Wraps per-app CLIs (tootctl, php artisan, funkwhale-manage, rails runner)
# behind a single consistent interface so operators don't have to learn each
# app's tooling separately. The app CLIs remain the source of truth — this
# script just calls them with the right arguments.
#
# Usage:
#   ./bootstrap.sh up   <stack>                  bring up a stack
#   ./bootstrap.sh down <stack>                  tear down a stack
#   ./bootstrap.sh logs <stack> [service]        tail logs
#   ./bootstrap.sh ps   [stack]                  show container status
#   ./bootstrap.sh provision-db <app>            idempotent DB + role setup
#   ./bootstrap.sh provision-garage              idempotent Garage bucket + key setup
#   ./bootstrap.sh provision-stalwart            configure Stalwart via JMAP (auto-run by 'up stalwart')
#   ./bootstrap.sh user-create <app> <username> <email>
#
# <stack>/<app>: shared-db | garage | pixelfed | mastodon | diaspora | funkwhale | gotosocial | peertube | stalwart | authelia | lemmy
#
# Bring-up order: shared-db → garage → app stacks.
#
# provision-db is called automatically by 'up' for app stacks. Run it
# standalone if you add a new app after shared-db has already been running.
#
# provision-garage is called automatically by 'up garage'. Run it standalone
# after first boot to initialize the cluster layout, create buckets, and
# generate the access key. Re-running is idempotent.
#
# user-create requires the stack to already be running (the app sidecar must
# be up for the run container to get network access). Run `up` first.
#
# Passwords are generated randomly and printed once. Save them — there is no
# recovery path from this script. Operators can change passwords via the web
# UI after first login.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
ALL_STACKS=(shared-db garage pixelfed mastodon diaspora funkwhale gotosocial peertube stalwart authelia lemmy)
# Stacks that need a Postgres DB provisioned before starting.
DB_STACKS=(pixelfed mastodon diaspora funkwhale gotosocial peertube stalwart authelia lemmy)

# Load .env — required before any command.
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
else
  echo "Error: ${ENV_FILE} not found." >&2
  echo "" >&2
  echo "  cp ${REPO_ROOT}/.env.example ${ENV_FILE}" >&2
  echo "  \$EDITOR ${ENV_FILE}" >&2
  echo "" >&2
  echo "Fill in all required values before running bootstrap.sh." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

dc() {
  local stack="$1"; shift
  docker compose \
    -f "${REPO_ROOT}/${stack}/docker-compose.yml" \
    --env-file "$ENV_FILE" \
    "$@"
}

die() { echo "Error: $*" >&2; exit 1; }

# After a failed 'docker compose up', scan sidecar logs for the Tailscale
# "requested tags ... not permitted" error and print an ACL reminder.
_check_ts_auth() {
  local stack="$1"
  # Brief pause — Tailscale may crash immediately on a tag rejection and the
  # log buffer may not be flushed to the daemon by the time we call `logs`.
  sleep 2
  local logs
  logs=$(dc "$stack" logs 2>/dev/null || true)
  if echo "$logs" | grep -qi "requested tags.*invalid\|not permitted"; then
    echo "" >&2
    echo "[bootstrap] Tailscale tag error: the tag(s) for '${stack}' are not in your ACL." >&2
    echo "[bootstrap]   1. Open acl.example.hujson and find the tag(s) for '${stack}'" >&2
    echo "[bootstrap]   2. Add them to tagOwners in the Tailscale admin console:" >&2
    echo "[bootstrap]      https://login.tailscale.com/admin/acls" >&2
    echo "[bootstrap]   3. Re-run: ./bootstrap.sh up ${stack}" >&2
    echo "" >&2
  else
    echo "[bootstrap] Start failed. Check logs: ./bootstrap.sh logs ${stack}" >&2
  fi
}

require_stack() {
  local stack="$1"
  local valid=0
  for s in "${ALL_STACKS[@]}"; do [[ "$s" == "$stack" ]] && valid=1; done
  [[ $valid -eq 1 ]] || die "Unknown stack '${stack}'. Valid: ${ALL_STACKS[*]}"
}

# ---------------------------------------------------------------------------
# DB provisioning helpers — idempotent, safe to re-run at any time.
# ---------------------------------------------------------------------------

# Run psql as superuser inside the shared-db postgres container.
_pg_exec() {
  local container
  container=$(dc shared-db ps -q postgres 2>/dev/null | head -1)
  [[ -n "$container" ]] || die "Postgres container not found. Is shared-db running? ./bootstrap.sh up shared-db"
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 --username postgres "$@"
}

# Idempotent role + database: creates on first run, updates password on re-runs.
_provision_role_db() {
  local user="$1" password="$2" dbname="$3"
  echo "[bootstrap] Provisioning role '${user}' and database '${dbname}'..."
  _pg_exec --dbname postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${user}') THEN
    CREATE ROLE "${user}" LOGIN PASSWORD '${password}';
  ELSE
    ALTER ROLE "${user}" WITH LOGIN PASSWORD '${password}';
  END IF;
END
\$\$;
SELECT 'CREATE DATABASE "${dbname}" OWNER "${user}"'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${dbname}')\gexec
GRANT ALL PRIVILEGES ON DATABASE "${dbname}" TO "${user}";
SQL
}

# Idempotent extension install (requires superuser, hence run here not by app).
_provision_extension() {
  local dbname="$1" ext="$2"
  _pg_exec --dbname "$dbname" -c "CREATE EXTENSION IF NOT EXISTS \"${ext}\";"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_provision_db() {
  local app="${1:-}"
  [[ -n "$app" ]] || die "Usage: ./bootstrap.sh provision-db <app>"

  case "$app" in
    shared-db)
      echo "[bootstrap] shared-db has no app database to provision."
      ;;
    pixelfed)
      _provision_role_db "${PIXELFED_DB_USER}" "${PIXELFED_DB_PASSWORD}" "${PIXELFED_DB_NAME}"
      ;;
    mastodon)
      _provision_role_db "${MASTODON_DB_USER}" "${MASTODON_DB_PASSWORD}" "${MASTODON_DB_NAME}"
      ;;
    diaspora)
      _provision_role_db "${DIASPORA_DB_USER}" "${DIASPORA_DB_PASSWORD}" "${DIASPORA_DB_NAME}"
      ;;
    funkwhale)
      _provision_role_db "${FUNKWHALE_DB_USER}" "${FUNKWHALE_DB_PASSWORD}" "${FUNKWHALE_DB_NAME}"
      ;;
    gotosocial)
      _provision_role_db "${GOTOSOCIAL_DB_USER}" "${GOTOSOCIAL_DB_PASSWORD}" "${GOTOSOCIAL_DB_NAME}"
      ;;
    peertube)
      _provision_role_db "${PEERTUBE_DB_USER}" "${PEERTUBE_DB_PASSWORD}" "${PEERTUBE_DB_NAME}"
      _provision_extension "${PEERTUBE_DB_NAME}" pg_trgm
      _provision_extension "${PEERTUBE_DB_NAME}" unaccent
      _provision_extension "${PEERTUBE_DB_NAME}" uuid-ossp
      ;;
    stalwart)
      _provision_role_db "${STALWART_DB_USER:-stalwart}" "${STALWART_DB_PASSWORD}" "${STALWART_DB_NAME:-stalwart}"
      ;;
    authelia)
      _provision_role_db "${AUTHELIA_DB_USER:-authelia}" "${AUTHELIA_DB_PASSWORD}" "${AUTHELIA_DB_NAME:-authelia}"
      ;;
    lemmy)
      _provision_role_db "${LEMMY_DB_USER:-lemmy}" "${LEMMY_DB_PASSWORD}" "${LEMMY_DB_NAME:-lemmy}"
      ;;
    *)
      die "Unknown app '${app}'. Valid: pixelfed mastodon diaspora funkwhale gotosocial peertube stalwart authelia lemmy"
      ;;
  esac
  echo "[bootstrap] DB provisioning complete for ${app}."
}

cmd_provision_garage() {
  local container
  container=$(dc garage ps -q garage 2>/dev/null | head -1)
  [[ -n "$container" ]] || die "Garage is not running. Start it first: ./bootstrap.sh up garage"

  # Confirm the container is actually running, not just Created/Exited.
  local running
  running=$(docker inspect "$container" --format='{{.State.Running}}' 2>/dev/null || echo "false")
  [[ "$running" == "true" ]] || die "Garage container exists but is not running (state: $(docker inspect "$container" --format='{{.State.Status}}' 2>/dev/null)). Try: ./bootstrap.sh up garage"

  # Inline Garage CLI wrapper — all garage commands run inside the container.
  # The dxflrs/garage image places the binary at /garage (not on $PATH).
  _g() { docker exec "$container" /garage "$@"; }

  echo "[bootstrap] Checking Garage cluster layout..."

  local layout_version
  # Garage v1.0.x prints: ==== CURRENT CLUSTER LAYOUT (version N) ====
  # Extract the number from that line, case-insensitively.
  layout_version=$(_g layout show 2>/dev/null \
    | grep -i "CURRENT CLUSTER LAYOUT" \
    | grep -oE '[0-9]+' \
    | head -1 || echo "0")
  # Treat empty (no output / Garage not yet init'd) as 0.
  [[ -n "$layout_version" ]] || layout_version="0"

  if [[ "$layout_version" == "0" ]]; then
    echo "[bootstrap] Initializing cluster layout (zone=${GARAGE_ZONE:-dc1}, capacity=${GARAGE_CAPACITY:-100G})..."
    # Run node id without stderr suppression so errors are visible.
    local node_id_raw node_id
    node_id_raw=$(_g node id || true)
    node_id=$(echo "$node_id_raw" | head -1 | cut -d@ -f1)
    if [[ -z "$node_id" ]]; then
      echo "[bootstrap] 'garage node id' output: ${node_id_raw:-<empty>}" >&2
      die "Could not get Garage node ID. Check: ./bootstrap.sh logs garage garage"
    fi
    echo "[bootstrap] Assigning node ${node_id}..."
    if ! _g layout assign "$node_id" \
        --zone     "${GARAGE_ZONE:-dc1}" \
        --capacity "${GARAGE_CAPACITY:-100G}" \
        --tag      "${GARAGE_MAGIC_NAME:-garage}"; then
      die "garage layout assign failed — see output above"
    fi
    echo "[bootstrap] Applying layout version 1..."
    if ! _g layout apply --version 1; then
      die "garage layout apply failed — see output above"
    fi
    echo "[bootstrap] Layout applied (version 1)."
  else
    echo "[bootstrap] Layout already at version ${layout_version} — skipping."
  fi

  echo "[bootstrap] Ensuring buckets..."
  local buckets=(pg-backups mastodon-media pixelfed-media gotosocial-media stalwart-mail peertube-web-videos peertube-streaming-playlists funkwhale-music)
  for bucket in "${buckets[@]}"; do
    if _g bucket create "$bucket" 2>/dev/null; then
      echo "[bootstrap]   created: ${bucket}"
    else
      echo "[bootstrap]   exists:  ${bucket}"
    fi
  done

  echo "[bootstrap] Ensuring access key 'federated-social-apps'..."
  # Garage allows multiple keys with the same label, so 'key create' always
  # succeeds and mints a new key. Check the key list first.
  local key_id key_output
  key_id=$(_g key list 2>/dev/null \
    | awk '/federated-social-apps/ {print $1; exit}' || true)

  if [[ -n "$key_id" ]]; then
    echo "[bootstrap] Key exists (ID: ${key_id})."
    echo "[bootstrap] Secret key is not redisplayable after creation."
    echo "[bootstrap] If you have lost it, rotate it:"
    echo "[bootstrap]   docker exec <garage-container> /garage key rotate ${key_id}"
    echo "[bootstrap]   then re-run: ./bootstrap.sh provision-garage"
    key_output=$(_g key info "$key_id" 2>/dev/null || true)
  else
    key_output=$(_g key create federated-social-apps 2>&1) \
      || die "Failed to create Garage access key: ${key_output}"
    echo "[bootstrap] Key created."
  fi

  echo "[bootstrap] Granting key access to all buckets..."
  for bucket in "${buckets[@]}"; do
    _g bucket allow "$bucket" --read --write --owner --key federated-social-apps 2>/dev/null || true
  done

  # Enable website serving on public media buckets.
  #
  # Garage's S3 API (port 3900) requires every request to be signed and
  # returns 403 "does not support anonymous access" for unauthenticated GETs.
  # Public browsers therefore cannot fetch media through the S3 API at all.
  #
  # The web endpoint (port 3902, configured in garage.toml [s3_web]) is the
  # mechanism for anonymous public reads. A bucket must have website serving
  # explicitly enabled to be reachable there. The host nginx/Caddy proxy
  # terminates public TLS and forwards to this endpoint — see
  # nginx/sites-available/garage-media.conf.
  #
  # pg-backups and stalwart-mail are intentionally excluded — mail blobs are private.
  local public_buckets=(mastodon-media pixelfed-media gotosocial-media peertube-web-videos peertube-streaming-playlists funkwhale-music)
  echo "[bootstrap] Enabling website serving on public media buckets..."
  for bucket in "${public_buckets[@]}"; do
    if _g bucket website --allow "$bucket" 2>/dev/null; then
      echo "[bootstrap]   website enabled: ${bucket}"
    else
      echo "[bootstrap]   website already enabled or failed: ${bucket}"
    fi
  done

  # CORS on the HLS buckets (PeerTube only).
  #
  # PeerTube's HLS player fetches manifests and fmp4 byte-range segments
  # cross-origin via fetch()/XHR (MSE), so the browser requires
  # Access-Control-Allow-Origin on the media host — without it playback hangs on
  # a spinner with no error and no timeout. Plain media (<img>/<video src> as
  # used by Mastodon/Pixelfed/GoToSocial) does NOT need CORS, so only the HLS
  # buckets get a rule. Garage honours per-bucket CORS on its web endpoint, but
  # the garage CLI cannot set it — it's an S3 PutBucketCors call, which needs an
  # S3 client and the access key (not the garage admin socket used by _g above).
  local hls_buckets=(peertube-web-videos peertube-streaming-playlists)
  local s3ep="http://${GARAGE_MAGIC_NAME}.${TS_TAILNET}:3900"
  local cors_json='{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["GET","HEAD"],"AllowedHeaders":["*"],"ExposeHeaders":["Content-Length","Content-Range","Accept-Ranges"],"MaxAgeSeconds":86400}]}'
  echo "[bootstrap] Setting CORS on HLS (PeerTube) buckets..."
  if [[ -z "${GARAGE_SECRET_ACCESS_KEY:-}" ]]; then
    echo "[bootstrap]   skipped — GARAGE_SECRET_ACCESS_KEY not in .env yet."
    echo "[bootstrap]   Add the key printed below to .env, then re-run provision-garage."
  elif command -v aws >/dev/null 2>&1; then
    local cf; cf=$(mktemp); printf '%s' "$cors_json" >"$cf"
    for bucket in "${hls_buckets[@]}"; do
      if AWS_ACCESS_KEY_ID="${GARAGE_ACCESS_KEY_ID}" AWS_SECRET_ACCESS_KEY="${GARAGE_SECRET_ACCESS_KEY}" \
         aws --endpoint-url "$s3ep" --region "${GARAGE_REGION:-garage}" \
         s3api put-bucket-cors --bucket "$bucket" --cors-configuration "file://${cf}" 2>/dev/null; then
        echo "[bootstrap]   CORS set: ${bucket}"
      else
        echo "[bootstrap]   CORS failed: ${bucket} (set it manually — see note below)"
      fi
    done
    rm -f "$cf"
  else
    echo "[bootstrap]   'aws' CLI not found — set CORS manually (required for HLS playback):"
    for bucket in "${hls_buckets[@]}"; do
      echo "[bootstrap]     aws --endpoint-url ${s3ep} --region ${GARAGE_REGION:-garage} \\"
      echo "[bootstrap]       s3api put-bucket-cors --bucket ${bucket} \\"
      echo "[bootstrap]       --cors-configuration '${cors_json}'"
    done
  fi

  local secret_key
  # 'key create' output includes "Secret key: <value>"; 'key info' does not.
  secret_key=$(echo "$key_output" | grep -i "Secret key" | awk '{print $NF}')
  # key_id was set above from 'key list' (existing) or parsed from create output.
  [[ -n "$key_id" ]] || key_id=$(echo "$key_output" | grep -i "Key ID" | awk '{print $NF}')

  echo ""
  echo "[bootstrap] ============================================================"
  if [[ -n "$secret_key" ]]; then
    echo "[bootstrap] Add these to your .env:"
    echo ""
    echo "  GARAGE_ACCESS_KEY_ID=${key_id}"
    echo "  GARAGE_SECRET_ACCESS_KEY=${secret_key}"
    echo ""
    echo "[bootstrap] Then opt in apps via .env and restart their stacks:"
    echo "  MASTODON_S3_ENABLED=true"
    echo "  PIXELFED_ENABLE_CLOUD=true"
    echo "  PEERTUBE_OBJECT_STORAGE_ENABLED=true"
  else
    echo "[bootstrap] Key already existed — secret not redisplayable."
    [[ -n "$key_id" ]] && echo "  GARAGE_ACCESS_KEY_ID=${key_id}"
    echo "[bootstrap] To rotate: /garage key rotate ${key_id:-<key-id>}"
    echo "[bootstrap]   then re-run: ./bootstrap.sh provision-garage"
  fi
  echo "[bootstrap] ============================================================"
}

# ---------------------------------------------------------------------------
# Stalwart provisioning — JMAP x: management API
# Called automatically by `cmd_up stalwart` and available standalone:
#   ./bootstrap.sh provision-stalwart
#
# Idempotent: queries for existing objects before creating. Safe to re-run.
# ---------------------------------------------------------------------------

# Module-level state for the current provision run (set inside cmd_provision_stalwart).
_SW_AUTH=""      # "user:password" for HTTP Basic auth
_SW_ACCT_ID=""   # JMAP account ID (queried from session after auth)
_SW_JMAP=""      # full JMAP endpoint URL

# PROXY protocol trust for mail listeners only (25/465/587/143/993).
# Includes Tailscale CGNAT range and the ULA subnet used by the sidecar netns.
# NOT applied to http(:8080) or https(:443) — those don't receive PROXY headers.
_SW_NET_TRUST='{"100.64.0.0/10":true,"fd7a:115c:a1e0::/48":true}'

_sw_call() {
  curl -s -m 25 -u "$_SW_AUTH" -H 'Content-Type: application/json' "$_SW_JMAP" -X POST \
    --data "$(jq -nc --argjson mc "$1" \
      '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":$mc}')"
}

_sw_ok() {
  local r="$1"
  if echo "$r" | jq -e '.methodResponses[0][0]=="error"' >/dev/null 2>&1; then
    die "JMAP error: $(echo "$r" | jq -c '.methodResponses[0][1]')"
  fi
  if echo "$r" | jq -e '.methodResponses[0][1] | (.notCreated//{}|length>0) or (.notUpdated//{}|length>0) or (.notDestroyed//[]|length>0)' >/dev/null 2>&1; then
    die "JMAP set rejected: $(echo "$r" | jq -c '.methodResponses[0][1]|{notCreated,notUpdated,notDestroyed}')"
  fi
}

# Find the ID of a named object of the given type. Returns empty string if absent.
_sw_find_id() {
  local type="$1" name="$2"
  local r; r=$(_sw_call "$(jq -nc --arg t "$type" --arg acct "$_SW_ACCT_ID" '[
    [($t+"/query"), {"accountId":$acct}, "0"],
    [($t+"/get"),   {"accountId":$acct,
                     "#ids":{"resultOf":"0","name":($t+"/query"),"path":"/ids"},
                     "properties":["name"]}, "1"]
  ]')")
  echo "$r" | jq -r --arg n "$name" '.methodResponses[1][1].list[]? | select(.name==$n) | .id' | head -1
}

# Authenticate. Prefers the persistent admin@DOMAIN; falls back to the
# first-boot virtual admin ("admin") if no real account exists yet.
_sw_auth() {
  local u
  for u in "admin@${STALWART_DOMAIN}" "admin"; do
    if curl -s -m 8 -u "${u}:${STALWART_FALLBACK_ADMIN_SECRET}" \
        -o /dev/null -w '%{http_code}' "${_SW_JMAP}/session" 2>/dev/null | grep -q 200; then
      _SW_AUTH="${u}:${STALWART_FALLBACK_ADMIN_SECRET}"
      echo "[bootstrap]   authenticated as ${u}"
      return 0
    fi
  done
  die "Cannot authenticate to Stalwart at ${_SW_JMAP} — check STALWART_FALLBACK_ADMIN_SECRET"
}

# Populate _SW_ACCT_ID from the JMAP session response.
_sw_get_acct_id() {
  local session
  session=$(curl -s -m 10 -u "$_SW_AUTH" "${_SW_JMAP}/session")
  _SW_ACCT_ID=$(echo "$session" | jq -r '
    .primaryAccounts["urn:ietf:params:jmap:core"] //
    .primaryAccounts["urn:stalwart:jmap"] //
    (.accounts | to_entries | first | .key) //
    empty
  ')
  [[ -n "$_SW_ACCT_ID" ]] || \
    die "Cannot determine JMAP account ID from session. Is Stalwart fully initialized?"
  echo "[bootstrap]   JMAP account ID: ${_SW_ACCT_ID}"
}

# Switch to the persistent admin@DOMAIN after creating it. Once a real admin
# exists, Stalwart's first-boot fallback goes inert — all subsequent calls
# must use the real account or they will get 401.
_sw_re_auth() {
  local u="admin@${STALWART_DOMAIN}"
  if curl -s -m 8 -u "${u}:${STALWART_FALLBACK_ADMIN_SECRET}" \
      -o /dev/null -w '%{http_code}' "${_SW_JMAP}/session" 2>/dev/null | grep -q 200; then
    _SW_AUTH="${u}:${STALWART_FALLBACK_ADMIN_SECRET}"
    _sw_get_acct_id
    echo "[bootstrap]   re-authenticated as ${u}"
  fi
}

cmd_provision_stalwart() {
  command -v jq >/dev/null || die "jq is required: apt install jq"

  local missing=()
  for v in STALWART_MAGIC_NAME TS_TAILNET STALWART_DOMAIN STALWART_HOSTNAME \
            STALWART_FALLBACK_ADMIN_SECRET STALWART_REDIS_DB \
            REDIS_MAGIC_NAME GARAGE_MAGIC_NAME GARAGE_REGION \
            GARAGE_ACCESS_KEY_ID GARAGE_SECRET_ACCESS_KEY \
            STALWART_S3_BUCKET STALWART_RELAY_USER STALWART_RELAY_PASSWORD; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "Required vars missing from .env: ${missing[*]}"

  _SW_JMAP="http://${STALWART_MAGIC_NAME}.${TS_TAILNET}:8080/jmap"
  local relay_addr="${STALWART_RELAY_USER}@${STALWART_DOMAIN}"

  echo "[bootstrap] Provisioning Stalwart at ${_SW_JMAP}..."
  echo "[bootstrap] Waiting for JMAP API (up to 120 s)..."
  local elapsed=0 interval=5 timeout=120
  while true; do
    if curl -s -m 5 -o /dev/null -w '%{http_code}' "${_SW_JMAP}/session" 2>/dev/null | grep -qE '^[24]'; then
      break
    fi
    elapsed=$(( elapsed + interval ))
    if [[ $elapsed -ge $timeout ]]; then
      die "Stalwart JMAP API did not respond after ${timeout}s.
  Ensure shared-db and garage are healthy: ./bootstrap.sh ps
  Check Stalwart logs: ./bootstrap.sh logs stalwart"
    fi
    sleep "$interval"
  done

  _sw_auth
  _sw_get_acct_id

  # ── Blob store → Garage S3 ────────────────────────────────────────────────
  echo "[bootstrap] Setting blob store (Garage S3, bucket ${STALWART_S3_BUCKET})..."
  _sw_ok "$(_sw_call "$(jq -nc \
    --arg ep     "http://${GARAGE_MAGIC_NAME}.${TS_TAILNET}:3900" \
    --arg region "${GARAGE_REGION}" \
    --arg bucket "${STALWART_S3_BUCKET}" \
    --arg ak     "${GARAGE_ACCESS_KEY_ID}" \
    --arg sk     "${GARAGE_SECRET_ACCESS_KEY}" \
    --arg acct   "$_SW_ACCT_ID" \
    '[["x:BlobStore/set",{"accountId":$acct,"update":{"singleton":{
      "@type":"S3",
      "region":{"@type":"Custom","customEndpoint":$ep,"customRegion":$region},
      "bucket":$bucket,
      "accessKey":$ak,
      "secretKey":{"@type":"Value","secret":$sk},
      "verifyAfterWrite":true
    }}},"0"]]')")"

  # ── In-memory store → Redis ───────────────────────────────────────────────
  echo "[bootstrap] Setting in-memory store (Redis db ${STALWART_REDIS_DB})..."
  _sw_ok "$(_sw_call "$(jq -nc \
    --arg url  "redis://${REDIS_MAGIC_NAME}.${TS_TAILNET}:6379/${STALWART_REDIS_DB}" \
    --arg acct "$_SW_ACCT_ID" \
    '[["x:InMemoryStore/set",{"accountId":$acct,"update":{"singleton":{
      "@type":"Redis",
      "url":$url
    }}},"0"]]')")"

  # ── Primary domain ────────────────────────────────────────────────────────
  echo "[bootstrap] Ensuring domain ${STALWART_DOMAIN} (catch-all → ${relay_addr})..."
  local domain_id
  domain_id=$(_sw_find_id x:Domain "${STALWART_DOMAIN}")
  if [[ -z "$domain_id" ]]; then
    local r; r=$(_sw_call "$(jq -nc \
      --arg d    "${STALWART_DOMAIN}" \
      --arg ca   "$relay_addr" \
      --arg acct "$_SW_ACCT_ID" \
      '[["x:Domain/set",{"accountId":$acct,"create":{"d":{
        "name":$d,
        "isEnabled":true,
        "description":"Primary mail domain",
        "catchAllAddress":$ca,
        "subAddressing":{"@type":"Enabled"},
        "dkimManagement":{
          "@type":"Automatic",
          "algorithms":{"Dkim1Ed25519Sha256":true,"Dkim1RsaSha256":true},
          "selectorTemplate":"v{version}-{algorithm}-{date-%Y%m%d}",
          "rotateAfter":7776000000,
          "retireAfter":604800000,
          "deleteAfter":2592000000
        }
      }}},"0"]]')")
    _sw_ok "$r"
    domain_id=$(echo "$r" | jq -r '.methodResponses[0][1].created.d.id')
    echo "[bootstrap]   domain created (ID: ${domain_id})"
  else
    echo "[bootstrap]   domain ${STALWART_DOMAIN} present (ID: ${domain_id})"
  fi

  # ── Persistent admin account ──────────────────────────────────────────────
  echo "[bootstrap] Ensuring admin account (admin@${STALWART_DOMAIN})..."
  if [[ -z "$(_sw_find_id x:Account admin)" ]]; then
    _sw_ok "$(_sw_call "$(jq -nc \
      --arg pw   "${STALWART_FALLBACK_ADMIN_SECRET}" \
      --arg dom  "$domain_id" \
      --arg acct "$_SW_ACCT_ID" \
      '[["x:Account/set",{"accountId":$acct,"create":{"a":{
        "@type":"User",
        "name":"admin",
        "domainId":$dom,
        "description":"System administrator",
        "roles":{"@type":"Admin"},
        "credentials":{"0":{"@type":"Password","secret":$pw}}
      }}},"0"]]')")"
    echo "[bootstrap]   admin account created"
  else
    echo "[bootstrap]   admin account present"
  fi

  # Switch to the persistent admin — the first-boot fallback goes inert once a
  # real admin exists and will reject further calls with 401.
  _sw_re_auth

  # ── Relay / catch-all account ─────────────────────────────────────────────
  echo "[bootstrap] Ensuring relay account (${relay_addr})..."
  if [[ -z "$(_sw_find_id x:Account "${STALWART_RELAY_USER}")" ]]; then
    _sw_ok "$(_sw_call "$(jq -nc \
      --arg n    "${STALWART_RELAY_USER}" \
      --arg dom  "$domain_id" \
      --arg pw   "${STALWART_RELAY_PASSWORD}" \
      --arg acct "$_SW_ACCT_ID" \
      '[["x:Account/set",{"accountId":$acct,"create":{"a":{
        "@type":"User",
        "name":$n,
        "domainId":$dom,
        "description":"Relay and catch-all",
        "credentials":{"0":{"@type":"Password","secret":$pw}}
      }}},"0"]]')")"
    echo "[bootstrap]   relay account ${relay_addr} created"
  else
    echo "[bootstrap]   relay account ${relay_addr} present"
  fi

  # ── Network listeners ─────────────────────────────────────────────────────
  # proxyTrust=1 → trust Tailscale CGNAT for PROXY protocol v2 (mail ports).
  # Listeners are created once and persist in Postgres; container restarts do
  # not recreate them. A container restart is required after NEW listeners are
  # created for Stalwart to bind the new ports.
  echo "[bootstrap] Ensuring network listeners..."
  local listener_rows=(
    "smtp         25   smtp         0  1"
    "submission   587  smtp         0  1"
    "submissions  465  smtp         1  1"
    "imap         143  imap         0  1"
    "imaps        993  imap         1  1"
    "http         8080 http         0  0"
    "https        443  http         1  0"
    "sieve        4190 manageSieve  0  0"
  )
  local row lname lport lproto limpl ltrust lid impl_bool pt
  for row in "${listener_rows[@]}"; do
    read -r lname lport lproto limpl ltrust <<< "$row"
    lid=$(_sw_find_id x:NetworkListener "$lname")
    if [[ -n "$lid" ]]; then
      echo "[bootstrap]   listener ${lname} present"
      continue
    fi
    impl_bool="false"; [[ "$limpl" == 1 ]] && impl_bool="true"
    pt="{}";            [[ "$ltrust" == 1 ]] && pt="$_SW_NET_TRUST"
    _sw_ok "$(_sw_call "$(jq -nc \
      --arg n    "$lname" \
      --arg bind "[::]:${lport}" \
      --arg p    "$lproto" \
      --argjson impl "$impl_bool" \
      --argjson pt   "$pt" \
      --arg acct "$_SW_ACCT_ID" \
      '[["x:NetworkListener/set",{"accountId":$acct,"create":{"l":{
        "name":$n,
        "bind":{($bind):true},
        "protocol":$p,
        "useTls":true,
        "tlsImplicit":$impl,
        "overrideProxyTrustedNetworks":$pt
      }}},"0"]]')")"
    echo "[bootstrap]   created listener ${lname} (:${lport})"
  done

  # ── System settings ───────────────────────────────────────────────────────
  echo "[bootstrap] Setting system hostname (${STALWART_HOSTNAME}) and default domain..."
  _sw_ok "$(_sw_call "$(jq -nc \
    --arg h    "${STALWART_HOSTNAME}" \
    --arg d    "$domain_id" \
    --arg acct "$_SW_ACCT_ID" \
    '[["x:SystemSettings/set",{"accountId":$acct,"update":{"singleton":{
      "defaultHostname":$h,
      "defaultDomainId":$d
    }}},"0"]]')")"

  # ── SSO via Authelia OIDC (opt-in) ────────────────────────────────────────
  if [[ "${STALWART_SSO_ENABLE:-false}" == "true" ]]; then
    [[ -n "${AUTHELIA_PORTAL_URL:-}" ]] || \
      die "STALWART_SSO_ENABLE=true but AUTHELIA_PORTAL_URL is empty"
    [[ -n "${STALWART_OIDC_CLIENT_SECRET:-}" ]] || \
      die "STALWART_SSO_ENABLE=true but STALWART_OIDC_CLIENT_SECRET is empty"
    echo "[bootstrap] Configuring OIDC directory → Authelia (${AUTHELIA_PORTAL_URL})..."
    if [[ -z "$(_sw_find_id x:Directory authelia)" ]]; then
      _sw_ok "$(_sw_call "$(jq -nc \
        --arg iss  "${AUTHELIA_PORTAL_URL}" \
        --arg ud   "${STALWART_DOMAIN}" \
        --arg acct "$_SW_ACCT_ID" \
        '[["x:Directory/set",{"accountId":$acct,"create":{"d":{
          "@type":"Oidc",
          "description":"authelia",
          "issuerUrl":$iss,
          "claimUsername":"preferred_username",
          "claimName":"name",
          "claimGroups":"groups",
          "usernameDomain":$ud
        }}},"0"]]')")"
      echo "[bootstrap]   OIDC directory created"
    else
      echo "[bootstrap]   OIDC directory present"
    fi
    cat <<OIDCEOF

[bootstrap] Add to authelia/configuration.yml under identity_providers.oidc.clients
[bootstrap] (hash the secret first):
[bootstrap]   docker exec federated-authelia-authelia-1 \\
[bootstrap]     authelia crypto hash generate pbkdf2 --password '${STALWART_OIDC_CLIENT_SECRET}'

    - client_id: stalwart
      client_name: Stalwart Mail
      client_secret: '<PBKDF2-HASH-OF-STALWART_OIDC_CLIENT_SECRET>'
      public: false
      authorization_policy: two_factor
      redirect_uris:
        - https://${STALWART_HOSTNAME}/auth/oauth
      scopes: [openid, profile, email, groups]

[bootstrap] admin and ${relay_addr} retain password auth as break-glass.
OIDCEOF
  fi

  # ── DNS records (always tier-1: print for manual publish) ─────────────────
  echo ""
  echo "[bootstrap] ============================================================"
  echo "[bootstrap]  DNS records to publish for ${STALWART_DOMAIN}"
  echo "[bootstrap] ============================================================"
  _sw_call "$(jq -nc \
    --arg id   "$domain_id" \
    --arg acct "$_SW_ACCT_ID" \
    '[["x:Domain/get",{"accountId":$acct,"ids":[$id],"properties":["dnsZoneFile"]},"0"]]')" \
    | jq -r '.methodResponses[0][1].list[0].dnsZoneFile //
             "  (not yet available — DKIM keys may still be generating; re-run in a moment)"'
  echo "[bootstrap] ============================================================"
  echo ""
  echo "[bootstrap] Done. Next steps:"
  echo "[bootstrap]   1. Publish the DNS records above."
  echo "[bootstrap]   2. Configure ACME (DNS-01) in the admin UI:"
  echo "[bootstrap]      http://${STALWART_MAGIC_NAME}.${TS_TAILNET}:8080"
  echo "[bootstrap]      Settings → TLS → ACME Providers → Add"
  echo "[bootstrap]   3. Restart Stalwart to activate newly-created listeners:"
  echo "[bootstrap]      docker compose -f stalwart/docker-compose.yml restart stalwart"
}

_cmd_up_caddy() {
  local caddy_bin="${CADDY_BIN:-/usr/local/bin/caddy}"
  local caddyfile="${REPO_ROOT}/caddy/Caddyfile"

  # 1. Verify the custom binary exists and includes the layer4 module.
  if [[ ! -x "$caddy_bin" ]]; then
    die "Custom Caddy binary not found at ${caddy_bin}.
  Download it with the caddy-l4 plugin from caddyserver.com/api/download
  See caddy/README.md for the exact command."
  fi
  if ! "$caddy_bin" list-modules 2>/dev/null | grep -q 'layer4'; then
    die "Caddy at ${caddy_bin} lacks the caddy-l4 module.
  See caddy/README.md for the download command with required plugins."
  fi
  echo "[bootstrap] Caddy binary OK (layer4 module present)."

  # 2. Validate the Caddyfile before touching the live system config.
  if ! "$caddy_bin" validate --config "$caddyfile" --adapter caddyfile; then
    die "Caddyfile validation failed. Fix ${caddyfile} before deploying."
  fi
  echo "[bootstrap] Caddyfile valid."

  # 3. Deploy and reload.
  sudo cp "$caddyfile" /etc/caddy/Caddyfile
  sudo systemctl reload caddy
  echo "[bootstrap] Caddy reloaded. Check: sudo journalctl -u caddy -n 50"
}

cmd_up() {
  local stack="${1:-}"
  [[ -n "$stack" ]] || die "Usage: ./bootstrap.sh up <stack>"

  # caddy is a system service, not a Docker Compose stack — handle separately.
  if [[ "$stack" == "caddy" ]]; then
    _cmd_up_caddy
    return 0
  fi

  require_stack "$stack"

  # Ensure a per-stack .env symlink exists so operators can also run
  # docker compose directly inside the stack directory.
  local stack_env="${REPO_ROOT}/${stack}/.env"
  if [[ ! -e "$stack_env" ]]; then
    ln -s "../.env" "$stack_env"
    echo "[bootstrap] Created ${stack}/.env -> ../.env"
  fi

  # Provision DB for app stacks (idempotent — safe on fresh or existing
  # volumes). Skip for shared-db and garage; skip gracefully if shared-db
  # isn't up yet.
  local is_db_stack=0
  for s in "${DB_STACKS[@]}"; do [[ "$s" == "$stack" ]] && is_db_stack=1; done
  if [[ $is_db_stack -eq 1 ]]; then
    local pg_container
    pg_container=$(dc shared-db ps -q postgres 2>/dev/null | head -1)
    if [[ -n "$pg_container" ]]; then
      cmd_provision_db "$stack"
    else
      echo "[bootstrap] Warning: shared-db postgres not running — skipping DB provisioning."
      echo "[bootstrap] Bring up shared-db first: ./bootstrap.sh up shared-db"
    fi
  fi

  # After Garage comes up, auto-run provision-garage (idempotent).
  # Skipped if layout is already initialized — effectively a no-op on restarts.
  if [[ "$stack" == "garage" ]]; then
    [[ -n "${GARAGE_RPC_SECRET:-}" ]] || \
      die "GARAGE_RPC_SECRET is not set in .env. Generate one: openssl rand -hex 32"

    # Generate garage.runtime.toml from the tracked template, substituting
    # .env values for fields Garage can't read from environment variables.
    # The runtime file is gitignored; the template stays clean for git pulls.
    local region="${GARAGE_REGION:-garage}"
    sed "s|^s3_region *=.*|s3_region     = \"${region}\"|" \
        "${REPO_ROOT}/garage/garage.toml" > "${REPO_ROOT}/garage/garage.runtime.toml"
    echo "[bootstrap] Generated garage.runtime.toml (s3_region=${region})."

    echo "[bootstrap] Starting Garage..."
    if ! dc garage up -d; then
      _check_ts_auth garage
      exit 1
    fi

    # Poll until the Garage admin API responds (i.e. 'garage node id' exits 0).
    # This matches the container healthcheck and is immune to Docker health
    # state lag or healthcheck misconfiguration.
    echo "[bootstrap] Waiting for Garage to be ready (up to 90 s)..."
    local elapsed=0 interval=5 timeout=90
    while true; do
      local container
      container=$(dc garage ps -q garage 2>/dev/null | head -1)
      if [[ -n "$container" ]]; then
        if docker exec "$container" /garage node id >/dev/null 2>&1; then
          break
        fi
      fi
      elapsed=$(( elapsed + interval ))
      if [[ $elapsed -ge $timeout ]]; then
        die "Garage did not become ready after ${timeout}s.
  Check logs: ./bootstrap.sh logs garage
  Ensure GARAGE_RPC_SECRET is set correctly in .env"
      fi
      sleep "$interval"
    done

    cmd_provision_garage
    return 0
  fi

  # Generate stalwart/config/config.runtime.json from the tracked template,
  # substituting .env values. Pattern mirrors garage.runtime.toml.
  if [[ "$stack" == "stalwart" ]]; then
    local db_host="${DB_MAGIC_NAME}.${TS_TAILNET}"
    local db_name="${STALWART_DB_NAME:-stalwart}"
    local db_user="${STALWART_DB_USER:-stalwart}"
    sed \
      -e "s|__DB_HOST__|${db_host}|g" \
      -e "s|__STALWART_DB_NAME__|${db_name}|g" \
      -e "s|__STALWART_DB_USER__|${db_user}|g" \
      "${REPO_ROOT}/stalwart/config/config.json" \
      > "${REPO_ROOT}/stalwart/config/config.runtime.json"
    echo "[bootstrap] Generated stalwart/config/config.runtime.json (host=${db_host}, db=${db_name}, user=${db_user})."
  fi

  # Generate lemmy/lemmy.runtime.hjson from the tracked template.
  # Pattern mirrors garage.runtime.toml and stalwart config.runtime.json.
  if [[ "$stack" == "lemmy" ]]; then
    [[ -n "${LEMMY_DB_PASSWORD:-}" ]] || die "LEMMY_DB_PASSWORD is not set in .env"
    [[ -n "${LEMMY_PICTRS_API_KEY:-}" ]] || die "LEMMY_PICTRS_API_KEY is not set in .env"
    sed \
      -e "s|__LEMMY_DOMAIN__|${LEMMY_DOMAIN:-lemmy.example.com}|g" \
      -e "s|__DB_HOST__|${DB_MAGIC_NAME}.${TS_TAILNET}|g" \
      -e "s|__LEMMY_DB_NAME__|${LEMMY_DB_NAME:-lemmy}|g" \
      -e "s|__LEMMY_DB_USER__|${LEMMY_DB_USER:-lemmy}|g" \
      -e "s|__LEMMY_DB_PASSWORD__|${LEMMY_DB_PASSWORD}|g" \
      -e "s|__LEMMY_PICTRS_API_KEY__|${LEMMY_PICTRS_API_KEY}|g" \
      "${REPO_ROOT}/lemmy/lemmy.hjson" \
      > "${REPO_ROOT}/lemmy/lemmy.runtime.hjson"
    echo "[bootstrap] Generated lemmy/lemmy.runtime.hjson (domain=${LEMMY_DOMAIN:-lemmy.example.com}, host=${DB_MAGIC_NAME}.${TS_TAILNET})."
  fi

  # Authelia preflight: generate runtime config and fail fast on missing
  # operator-created files rather than letting Docker create empty directories
  # in their place (which silently breaks the container with confusing errors).
  if [[ "$stack" == "authelia" ]]; then
    # Generate configuration.runtime.yml from the tracked template.
    # Pattern mirrors garage.runtime.toml and stalwart config.runtime.json.
    # The tracked template ships placeholders only — no secrets or real domains.
    local authelia_domain="${AUTHELIA_DOMAIN:-auth.example.com}"
    local gts_url="${GOTOSOCIAL_URL:-gotosocial.example.com}"

    # GoToSocial OIDC client_secret: Authelia stores a pbkdf2 HASH; GTS holds the
    # plaintext (GOTOSOCIAL_OIDC_CLIENT_SECRET). Derive the hash here so only the
    # gitignored runtime config ever contains it. SSO must have a secret when
    # enabled; when off we hash a throwaway so the client stays valid-but-unused
    # (Authelia requires >=1 client).
    if [[ "${GOTOSOCIAL_OIDC_ENABLED:-false}" == "true" && -z "${GOTOSOCIAL_OIDC_CLIENT_SECRET:-}" ]]; then
      die "GOTOSOCIAL_OIDC_ENABLED=true but GOTOSOCIAL_OIDC_CLIENT_SECRET is empty.
  Generate one: openssl rand -hex 32"
    fi
    local gts_oidc_secret="${GOTOSOCIAL_OIDC_CLIENT_SECRET:-$(openssl rand -hex 16)}"
    local gts_oidc_hash
    gts_oidc_hash="$(docker run --rm "authelia/authelia:${AUTHELIA_VERSION:-4.39.20}" \
      authelia crypto hash generate pbkdf2 --variant sha512 --password "${gts_oidc_secret}" \
      2>/dev/null | sed -n 's/^Digest: //p')"
    [[ -n "$gts_oidc_hash" ]] || die "Failed to derive GoToSocial OIDC client secret hash (is docker + the authelia image available?)."

    # Mastodon OIDC client_secret: same pattern as GoToSocial — Authelia stores a
    # pbkdf2 HASH, Mastodon holds the plaintext (MASTODON_OIDC_CLIENT_SECRET).
    local mastodon_url="${MASTODON_DOMAIN:-mastodon.example.com}"
    if [[ "${MASTODON_OIDC_ENABLED:-false}" == "true" && -z "${MASTODON_OIDC_CLIENT_SECRET:-}" ]]; then
      die "MASTODON_OIDC_ENABLED=true but MASTODON_OIDC_CLIENT_SECRET is empty.
  Generate one: openssl rand -hex 32"
    fi
    local mastodon_oidc_secret="${MASTODON_OIDC_CLIENT_SECRET:-$(openssl rand -hex 16)}"
    local mastodon_oidc_hash
    mastodon_oidc_hash="$(docker run --rm "authelia/authelia:${AUTHELIA_VERSION:-4.39.20}" \
      authelia crypto hash generate pbkdf2 --variant sha512 --password "${mastodon_oidc_secret}" \
      2>/dev/null | sed -n 's/^Digest: //p')"
    [[ -n "$mastodon_oidc_hash" ]] || die "Failed to derive Mastodon OIDC client secret hash (is docker + the authelia image available?)."

    sed -e "s|__AUTHELIA_DOMAIN__|${authelia_domain}|g" \
        -e "s|__GOTOSOCIAL_URL__|${gts_url}|g" \
        -e "s|__GTS_OIDC_HASH__|${gts_oidc_hash}|g" \
        -e "s|__MASTODON_URL__|${mastodon_url}|g" \
        -e "s|__MASTODON_OIDC_HASH__|${mastodon_oidc_hash}|g" \
      "${REPO_ROOT}/authelia/configuration.yml" \
      > "${REPO_ROOT}/authelia/configuration.runtime.yml"
    echo "[bootstrap] Generated authelia/configuration.runtime.yml (domain=${authelia_domain}, gts=${gts_url}/oidc=${GOTOSOCIAL_OIDC_ENABLED:-false}, mastodon=${mastodon_url}/oidc=${MASTODON_OIDC_ENABLED:-false})."

    local pem="${REPO_ROOT}/authelia/private.pem"
    local users="${REPO_ROOT}/authelia/users.yml"
    if [[ ! -f "$pem" ]]; then
      die "authelia/private.pem not found.
  Generate it once and keep it safe (it's gitignored):
    openssl genrsa -out ${REPO_ROOT}/authelia/private.pem 4096"
    fi
    if [[ ! -f "$users" ]]; then
      echo "[bootstrap] Warning: authelia/users.yml not found — creating empty placeholder."
      echo "[bootstrap] Add users with: ./bootstrap.sh user-create authelia"
      printf 'users: {}\n' > "$users"
    fi
  fi

  echo "[bootstrap] Starting ${stack}..."
  if ! dc "$stack" up -d; then
    _check_ts_auth "$stack"
    exit 1
  fi
  echo "[bootstrap] ${stack} is up. Tip: ./bootstrap.sh logs ${stack}"

  # After Stalwart comes up, auto-run provision-stalwart (idempotent).
  # This wires stores, domain, listeners, and accounts from .env — same as
  # provision-garage auto-runs after 'up garage'. Run standalone any time:
  #   ./bootstrap.sh provision-stalwart
  if [[ "$stack" == "stalwart" ]]; then
    cmd_provision_stalwart
  fi
}

cmd_down() {
  local stack="${1:-}"
  [[ -n "$stack" ]] || die "Usage: ./bootstrap.sh down <stack>"
  require_stack "$stack"
  dc "$stack" down
}

cmd_logs() {
  local stack="${1:-}"
  [[ -n "$stack" ]] || die "Usage: ./bootstrap.sh logs <stack> [service]"
  require_stack "$stack"
  local service="${2:-}"
  dc "$stack" logs -f $service
}

cmd_ps() {
  local stack="${1:-}"
  if [[ -n "$stack" ]]; then
    require_stack "$stack"
    dc "$stack" ps
  else
    for s in "${ALL_STACKS[@]}"; do
      echo "=== ${s} ==="
      dc "$s" ps 2>/dev/null || true
    done
  fi
}

cmd_user_create() {
  local app="${1:-}"  username="${2:-}"  email="${3:-}"
  [[ -n "$app" && -n "$username" && -n "$email" ]] ||
    die "Usage: ./bootstrap.sh user-create <app> <username> <email>"

  # Generate a strong random password for apps that need one passed in.
  local password
  password="$(openssl rand -base64 24)"

  case "$app" in

    mastodon)
      echo "[bootstrap] Creating Mastodon admin: ${username} <${email}>"
      echo "[bootstrap] tootctl will print a generated password below. Save it."
      echo ""
      dc mastodon run --rm web \
        bundle exec tootctl accounts create "$username" \
          --email "$email" --confirmed --approve --role Owner
      dc mastodon run --rm web \
        bundle exec tootctl accounts modify "$username" --enable
      ;;

    pixelfed)
      echo "[bootstrap] Creating Pixelfed admin: ${username} <${email}>"
      echo "[bootstrap] Generated password: ${password}"
      echo "[bootstrap] Change it at: https://${PIXELFED_DOMAIN:-your-domain}/settings"
      echo "[bootstrap] NOTE: password reset requires SMTP to be configured (no reset CLI exists)."
      echo ""
      dc pixelfed run --rm web \
        php artisan user:create \
          --name="$username" \
          --username="$username" \
          --email="$email" \
          --password="$password" \
          --confirm_email=1
      dc pixelfed run --rm web \
        php artisan user:admin "$username"
      ;;

    diaspora)
      # Diaspora has no user:create CLI. Uses rails runner via exec into the
      # running container.
      #
      # Three quirks solved here:
      # 1. bundle lives in RVM dirs (~/.rvm/gems/.../bin) only added to PATH
      #    by a login shell sourcing ~/.bash_profile. `/bin/bash -lc` does that.
      # 2. Must run as the `diaspora` user (--user) so RVM reads the right home.
      # 3. Ruby code is passed via env var (BOOTSTRAP_RUBY) so we don't embed
      #    Ruby single-quotes inside bash single-quotes inside a shell command.
      local ruby_code
      read -r -d '' ruby_code << 'RUBY' || true
u = User.build(
  username: ENV["BOOTSTRAP_USERNAME"],
  email:    ENV["BOOTSTRAP_EMAIL"],
  password: ENV["BOOTSTRAP_PASSWORD"],
  password_confirmation: ENV["BOOTSTRAP_PASSWORD"]
)
u.getting_started = false
u.save! or raise u.errors.full_messages.join(", ")
u.person.profile = Profile.new(first_name: ENV["BOOTSTRAP_USERNAME"])
u.person.save!
Role.add_admin(u.person)
puts "Created: " + u.username + " <" + u.email + ">"
RUBY
      echo "[bootstrap] Creating Diaspora admin: ${username} <${email}>"
      echo "[bootstrap] Generated password: ${password}"
      echo "[bootstrap] Change it at: ${DIASPORA_URL:-https://your-diaspora-domain/}profile/edit"
      echo ""
      BOOTSTRAP_USERNAME="$username" \
      BOOTSTRAP_EMAIL="$email" \
      BOOTSTRAP_PASSWORD="$password" \
      BOOTSTRAP_RUBY="$ruby_code" \
      dc diaspora exec \
        --user diaspora \
        -e BOOTSTRAP_USERNAME \
        -e BOOTSTRAP_EMAIL \
        -e BOOTSTRAP_PASSWORD \
        -e BOOTSTRAP_RUBY \
        diaspora \
        /bin/bash -lc 'cd /home/diaspora/diaspora && bundle exec rails runner "$BOOTSTRAP_RUBY"'
      ;;

    funkwhale)
      echo "[bootstrap] Creating Funkwhale admin: ${username} <${email}>"
      echo "[bootstrap] Generated password: ${password}"
      echo "[bootstrap] Change it at: https://${FUNKWHALE_DOMAIN:-your-domain}/settings"
      echo ""
      dc funkwhale run --rm api \
        funkwhale-manage fw users create \
          --superuser \
          --username "$username" \
          --email "$email" \
          --password "$password"
      ;;

    peertube)
      # PeerTube auto-creates the "root" admin on first boot and prints a
      # random password to the container logs. There is no admin-create CLI;
      # the username/email args are ignored. After first login change the
      # password and email via the web UI.
      echo "[bootstrap] Retrieving auto-generated PeerTube root password from logs..."
      echo "[bootstrap] (Provided username/email args are ignored — root is the only auto-created user.)"
      echo ""
      dc peertube logs peertube 2>&1 | grep -iE "user.*password|root.*password|admin.*password" \
        || die "Could not find password in logs. Try: ./bootstrap.sh logs peertube peertube | grep -i password
If the container has been restarted many times, the boot-time log line may have rolled off.
You can reset the root password instead:
  docker exec -it federated-peertube-peertube-1 npm run reset-password -- -u root"
      ;;

    gotosocial)
      echo "[bootstrap] Creating GoToSocial admin: ${username} <${email}>"
      echo "[bootstrap] Generated password: ${password}"
      echo "[bootstrap] Change it at: https://${GOTOSOCIAL_URL:-your-domain}/settings"
      echo ""
      # docker compose run swallows --username as its own -u/--user flag.
      # Use docker exec into the running container instead — same approach as
      # the user's working manual command.
      local cid
      cid=$(dc gotosocial ps -q gotosocial 2>/dev/null | head -1)
      [[ -n "$cid" ]] || die "GoToSocial is not running. Start it first: ./bootstrap.sh up gotosocial"
      docker exec "$cid" \
        /gotosocial/gotosocial admin account create \
          --username "$username" \
          --email "$email" \
          --password "$password"
      docker exec "$cid" \
        /gotosocial/gotosocial admin account promote --username "$username"
      ;;

    lemmy)
      echo "[bootstrap] Lemmy creates the admin account on first web visit."
      echo "[bootstrap] Navigate to https://${LEMMY_DOMAIN:-lemmy.example.com} and follow the setup wizard."
      echo "[bootstrap] (No CLI user-create — the web setup wizard is the only path.)"
      ;;

    authelia)
      echo "[bootstrap] Authelia has no CLI user-create flow."
      echo "[bootstrap] Steps to add users:"
      echo "[bootstrap]   1. Bring up the authelia stack first: ./bootstrap.sh up authelia"
      echo "[bootstrap]   2. Generate a password hash:"
      echo "[bootstrap]      docker exec federated-authelia-authelia-1 authelia crypto hash generate argon2 --password 'yourpassword'"
      echo "[bootstrap]   3. Edit authelia/users.yml with the hashed password."
      echo "[bootstrap]      (users.yml is gitignored — it is operator-managed)"
      ;;

    *)
      die "Unknown app '${app}'. Valid: mastodon pixelfed diaspora funkwhale gotosocial peertube authelia lemmy"
      ;;

  esac
}

usage() {
  cat <<EOF
Usage: ./bootstrap.sh <command> [args]

  up                  <stack>               Bring up a stack
  down                <stack>               Tear down a stack
  logs                <stack> [service]     Tail logs (Ctrl-C to stop)
  ps                  [stack]               Show container status for one or all stacks
  provision-db        <app>                 Idempotent DB role + database setup
  provision-garage                          Idempotent Garage layout + bucket + key setup
  provision-stalwart                        Configure Stalwart via JMAP (auto-run by 'up stalwart')
  user-create         <app> <user> <email>  Create an admin user

Stacks: ${ALL_STACKS[*]}

Examples:
  ./bootstrap.sh up shared-db
  ./bootstrap.sh up mastodon
  ./bootstrap.sh provision-db peertube
  ./bootstrap.sh user-create mastodon alice alice@example.com
  ./bootstrap.sh user-create funkwhale alice alice@example.com
  ./bootstrap.sh ps
  ./bootstrap.sh logs mastodon web

Note: 'up' calls provision-db automatically when shared-db is running.
      Run shared-db first, then 'up <app>' — the DB will be ready.
EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

command="${1:-help}"
shift || true

case "$command" in
  up)           cmd_up "$@" ;;
  down)         cmd_down "$@" ;;
  logs)         cmd_logs "$@" ;;
  ps)           cmd_ps "$@" ;;
  provision-db)          cmd_provision_db "$@" ;;
  provision-garage)      cmd_provision_garage ;;
  provision-stalwart)    cmd_provision_stalwart ;;
  user-create)           cmd_user_create "$@" ;;
  help|--help|-h) usage ;;
  *) echo "Unknown command: ${command}"; echo ""; usage; exit 1 ;;
esac
