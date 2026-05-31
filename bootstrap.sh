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
#   ./bootstrap.sh user-create <app> <username> <email>
#
# <stack>/<app>: shared-db | garage | pixelfed | mastodon | diaspora | funkwhale | gotosocial | peertube
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
ALL_STACKS=(shared-db garage pixelfed mastodon diaspora funkwhale gotosocial peertube)
# Stacks that need a Postgres DB provisioned before starting.
DB_STACKS=(pixelfed mastodon diaspora funkwhale gotosocial peertube)

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
    *)
      die "Unknown app '${app}'. Valid: pixelfed mastodon diaspora funkwhale gotosocial peertube"
      ;;
  esac
  echo "[bootstrap] DB provisioning complete for ${app}."
}

cmd_provision_garage() {
  local container
  container=$(dc garage ps -q garage 2>/dev/null | head -1)
  [[ -n "$container" ]] || die "Garage is not running. Start it first: ./bootstrap.sh up garage"

  # Inline Garage CLI wrapper — all garage commands run inside the container.
  _g() { docker exec "$container" garage "$@"; }

  echo "[bootstrap] Checking Garage cluster layout..."

  local layout_version
  layout_version=$(_g layout show 2>/dev/null \
    | grep -oE 'Current cluster layout version: [0-9]+' \
    | grep -oE '[0-9]+$' || echo "0")

  if [[ "$layout_version" == "0" ]]; then
    echo "[bootstrap] Initializing cluster layout (zone=${GARAGE_ZONE:-dc1}, capacity=${GARAGE_CAPACITY:-100G})..."
    local node_id
    node_id=$(_g node id 2>/dev/null | head -1 | cut -d@ -f1)
    [[ -n "$node_id" ]] || die "Could not get Garage node ID. Check: ./bootstrap.sh logs garage garage"
    _g layout assign "$node_id" \
      --zone     "${GARAGE_ZONE:-dc1}" \
      --capacity "${GARAGE_CAPACITY:-100G}" \
      --tag      "${GARAGE_MAGIC_NAME}"
    _g layout apply --version 1
    echo "[bootstrap] Layout applied (version 1)."
  else
    echo "[bootstrap] Layout already at version ${layout_version} — skipping."
  fi

  echo "[bootstrap] Ensuring buckets..."
  local buckets=(pg-backups mastodon-media pixelfed-media peertube-web-videos peertube-streaming-playlists funkwhale-music)
  for bucket in "${buckets[@]}"; do
    if _g bucket create "$bucket" 2>/dev/null; then
      echo "[bootstrap]   created: ${bucket}"
    else
      echo "[bootstrap]   exists:  ${bucket}"
    fi
  done

  echo "[bootstrap] Ensuring access key 'federated-social-apps'..."
  local key_output
  if key_output=$(_g key create federated-social-apps 2>&1); then
    echo "[bootstrap] Key created."
  elif echo "$key_output" | grep -qi "already\|exists"; then
    echo "[bootstrap] Key exists."
    key_output=$(_g key info federated-social-apps 2>/dev/null || true)
  else
    die "Garage key error: ${key_output}"
  fi

  echo "[bootstrap] Granting key access to all buckets..."
  for bucket in "${buckets[@]}"; do
    _g bucket allow "$bucket" --read --write --owner --key federated-social-apps 2>/dev/null || true
  done

  local key_id secret_key
  key_id=$(echo    "$key_output" | grep -i "Key ID"     | awk '{print $NF}')
  secret_key=$(echo "$key_output" | grep -i "Secret key" | awk '{print $NF}')

  echo ""
  echo "[bootstrap] ============================================================"
  if [[ -n "$key_id" && -n "$secret_key" ]]; then
    echo "[bootstrap] Add these to your .env:"
    echo ""
    echo "  GARAGE_ACCESS_KEY_ID=${key_id}"
    echo "  GARAGE_SECRET_ACCESS_KEY=${secret_key}"
    echo ""
    echo "[bootstrap] Then opt in apps via .env and restart their stacks:"
    echo "  MASTODON_S3_ENABLED=true"
    echo "  PIXELFED_FS_DRIVER=s3"
    echo "  PEERTUBE_OBJECT_STORAGE_ENABLED=true"
  else
    echo "[bootstrap] Key already existed — secret is not redisplayable."
    echo "[bootstrap] To rotate: docker exec <container> garage key delete federated-social-apps"
    echo "[bootstrap]   then re-run: ./bootstrap.sh provision-garage"
    [[ -n "$key_id" ]] && echo "  GARAGE_ACCESS_KEY_ID=${key_id}"
  fi
  echo "[bootstrap] ============================================================"
}

cmd_up() {
  local stack="${1:-}"
  [[ -n "$stack" ]] || die "Usage: ./bootstrap.sh up <stack>"
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

    echo "[bootstrap] Starting Garage..."
    dc garage up -d

    # Poll until the garage container is healthy. ts-garage has a 30 s
    # start_period; Garage itself has a 60 s start_period — budget 150 s.
    echo "[bootstrap] Waiting for Garage to be healthy (up to 150 s)..."
    local elapsed=0 interval=5 timeout=150
    while true; do
      local container health
      container=$(dc garage ps -q garage 2>/dev/null | head -1)
      if [[ -n "$container" ]]; then
        health=$(docker inspect "$container" \
          --format='{{.State.Health.Status}}' 2>/dev/null || true)
        [[ "$health" == "healthy" ]] && break
      fi
      elapsed=$(( elapsed + interval ))
      if [[ $elapsed -ge $timeout ]]; then
        die "Garage did not become healthy after ${timeout}s.
  Check logs: ./bootstrap.sh logs garage
  Ensure GARAGE_RPC_SECRET is set correctly in .env"
      fi
      sleep "$interval"
    done

    cmd_provision_garage
    return 0
  fi

  echo "[bootstrap] Starting ${stack}..."
  dc "$stack" up -d
  echo "[bootstrap] ${stack} is up. Tip: ./bootstrap.sh logs ${stack}"
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
          --is_admin=1 \
          --confirm_email=1
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

    *)
      die "Unknown app '${app}'. Valid: mastodon pixelfed diaspora funkwhale gotosocial peertube"
      ;;

  esac
}

usage() {
  cat <<EOF
Usage: ./bootstrap.sh <command> [args]

  up               <stack>               Bring up a stack
  down             <stack>               Tear down a stack
  logs             <stack> [service]     Tail logs (Ctrl-C to stop)
  ps               [stack]               Show container status for one or all stacks
  provision-db     <app>                 Idempotent DB role + database setup
  provision-garage                       Idempotent Garage layout + bucket + key setup
  user-create      <app> <user> <email>  Create an admin user

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
  provision-db)      cmd_provision_db "$@" ;;
  provision-garage)  cmd_provision_garage ;;
  user-create)       cmd_user_create "$@" ;;
  help|--help|-h) usage ;;
  *) echo "Unknown command: ${command}"; echo ""; usage; exit 1 ;;
esac
