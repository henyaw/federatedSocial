# Contributing

This guide covers the most common contribution: **adding a new federated app
to the stack**. It also documents the invariants every change must preserve,
the pitfalls this repo has already paid for, and how to test and submit your
work.

If you are fixing a bug in an existing stack rather than adding one, skip to
[Invariants](#invariants-do-not-break-these), [Testing](#testing-your-change),
and [Submitting](#submitting-your-change).

Read [`CLAUDE.md`](./CLAUDE.md) for the architecture and
[`SECURITY.md`](./SECURITY.md) for the threat model before making structural
changes. This guide assumes both.

---

## Table of contents

- [The shape of a contribution](#the-shape-of-a-contribution)
- [Before you write anything](#before-you-write-anything)
- [Step 1 — the stack directory and compose file](#step-1--the-stack-directory-and-compose-file)
- [Step 2 — `.env.example`](#step-2--envexample)
- [Step 3 — the Tailscale ACL](#step-3--the-tailscale-acl)
- [Step 4 — `bootstrap.sh`](#step-4--bootstrapsh)
- [Step 5 — reverse proxy snippets](#step-5--reverse-proxy-snippets)
- [Step 6 — `.gitignore`](#step-6--gitignore)
- [Step 7 — `README.md`](#step-7--readmemd)
- [Optional — object storage and SSO](#optional--object-storage-and-sso)
- [Invariants](#invariants-do-not-break-these)
- [Pitfalls](#pitfalls-learned-the-hard-way)
- [Testing your change](#testing-your-change)
- [Submitting your change](#submitting-your-change)

---

## The shape of a contribution

Adding an app touches **eight** files. Missing one produces a confusing
failure rather than a clean error, so treat this as a checklist:

| # | File | What you add |
|---|------|--------------|
| 1 | `<app>/docker-compose.yml` | Sidecar(s) + app container(s) |
| 2 | `.env.example` | An `<APP>_*` section |
| 3 | `acl.example.hujson` | `tagOwners` entries + grants |
| 4 | `bootstrap.sh` | `ALL_STACKS`, `DB_STACKS`, `provision-db` case, `user-create` case |
| 5 | `caddy/Caddyfile` + `nginx/sites-available/<app>.conf` | Public vhost |
| 6 | `.gitignore` | `<app>/.env` (and any runtime-generated config) |
| 7 | `README.md` | Support-matrix row + any app-specific notes |
| 8 | `CLAUDE.md` | Only if you discovered a new general pitfall |

---

## Before you write anything

Three questions decide the whole design. Answer them from **upstream
documentation and the app's actual source**, not from analogy with another
app in this repo — that assumption has broken this stack more than once.

**1. How many network identities does it need?**

One sidecar per container that needs its own tailnet presence. A worker that
only talks *outbound* to Postgres/Redis still needs one (it needs tailnet
egress), but it does not need a reverse-proxy grant.

- *Single tier* (GoToSocial, Lemmy, Stalwart) — one sidecar. Copy `gotosocial/`.
- *Multi tier* (Mastodon: web + streaming + sidekiq; Pixelfed: web + worker + cron)
  — one sidecar per tier. Copy `mastodon/`.

Containers that share a tier's namespace (Lemmy's `lemmy`, `lemmy-ui`,
`pictrs` all ride `ts-lemmy-web`) do **not** get their own sidecar — they
reach each other over `127.0.0.1`.

**2. Which backends does it actually use?**

Postgres, Redis, Garage — and *only* the ones it genuinely requires. This
decides both the ACL grants and the sidecar healthcheck gates. GoToSocial has
no Redis dependency; Lemmy is Postgres-only. Do not grant what the app does
not use.

**3. How does it read configuration?**

Environment variables, a config file, or both? **Verify the exact env-var
names against the app's own mapping file** — `custom-environment-variables.yaml`
for Node apps, the config struct for Go apps, `config/` for Rails apps. A
wrong name is silently ignored and the app boots with a default, which is
much harder to debug than a crash. Real examples this repo has been bitten
by: GoToSocial maps `db-address` → `GTS_DB_ADDRESS` (not `GTS_DB_HOST`);
PeerTube maps `secrets.peertube` → `PEERTUBE_SECRET` (not
`PEERTUBE_SECRETS_PEERTUBE`).

If the app needs a config *file* with values from `.env`, use the
[template → runtime pattern](#config-files-the-template--runtime-pattern).

---

## Step 1 — the stack directory and compose file

```bash
mkdir myapp
cp gotosocial/docker-compose.yml myapp/docker-compose.yml   # single-tier
# or: cp mastodon/docker-compose.yml myapp/docker-compose.yml   # multi-tier
```

### Naming conventions

| Thing | Convention | Example |
|---|---|---|
| Directory | app name, lowercase | `myapp/` |
| Compose project | `federated-<app>` | `name: federated-myapp` |
| Sidecar service | `ts-<app>[-<role>]` | `ts-myapp-web` |
| App service | the app name, or its role | `myapp`, `worker` |
| Tailscale tag | `tag:<app>[-<role>]` | `tag:myapp-web` |
| MagicDNS var | `<APP>_MAGIC_NAME`, or `<APP>_<ROLE>_MAGIC_NAME` if multi-tier | `MYAPP_MAGIC_NAME` |
| Env prefix | `<APP>_` | `MYAPP_DB_USER` |

### The sidecar block

This boilerplate is **fixed**. Copy it verbatim; changing a field needs a
stated reason in the PR, and any Tailscale-parameter change must be applied
to *every* sidecar in the repo in one pass.

```yaml
  ts-myapp-web:
    image: tailscale/tailscale:${TAILSCALE_VERSION:-v1.98.4}
    hostname: ${MYAPP_MAGIC_NAME}
    environment:
      TS_AUTHKEY: ${TS_OAUTH_CLIENT_SECRET}?ephemeral=true
      TS_EXTRA_ARGS: --advertise-tags=tag:myapp-web
      TS_HOSTNAME: ${MYAPP_MAGIC_NAME}
      TS_ACCEPT_DNS: "true"
      TS_AUTH_ONCE: "true"
      TS_USERSPACE: "false"
      TS_ENABLE_HEALTH_CHECK: "true"
      TS_LOCAL_ADDR_PORT: "127.0.0.1:9002"
    # Bootstrap DNS before Tailscale's MagicDNS is active.
    dns: [1.1.1.1, 1.0.0.1]
    devices:
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
      - NET_RAW
    # containerboot (PID 1) never reaps: orphans from the healthcheck or a
    # `docker exec` would zombie forever. tini reaps; SIGTERM still forwards.
    init: true
    healthcheck:
      # Gate on the backends this app ACTUALLY uses — see below.
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:9002/healthz && nc -z -w3 ${DB_MAGIC_NAME}.${TS_TAILNET} 5432"]
      interval: 10s
      timeout: 15s
      retries: 6
      start_period: 30s
    restart: unless-stopped
```

Why each line matters:

- `TS_ACCEPT_DNS: "true"` — without it, `${DB_MAGIC_NAME}.${TS_TAILNET}`
  does not resolve inside the namespace. **Forgetting this is the single
  most common breakage.**
- `TS_USERSPACE: "false"` + `cap_add` + `/dev/net/tun` — kernel networking.
  Userspace works but is measurably slower for Postgres traffic.
- `TS_LOCAL_ADDR_PORT: "127.0.0.1:9002"` — bind loopback only. `0.0.0.0` or
  `[::]` exposes the health endpoint across the tailnet.
- `?ephemeral=true` — nodes self-clean on `compose down`. Removing it
  requires adding `TS_STATE_DIR` and a persistent volume.
- `init: true` — `containerboot` is not an init and never reaps. Any child
  the healthcheck forks (or that a `docker exec` leaves behind) zombies
  permanently without tini. See commit `a8740ac`.

**Healthcheck backend gates.** Append one `nc -z -w3` per backend the app
requires. This is what makes `depends_on: service_healthy` meaningful — the
app is not released until its dependencies are actually reachable over the
tailnet, not merely until the sidecar started.

```
Postgres  → nc -z -w3 ${DB_MAGIC_NAME}.${TS_TAILNET} 5432
Redis     → nc -z -w3 ${REDIS_MAGIC_NAME}.${TS_TAILNET} 6379
Garage    → nc -z -w3 ${GARAGE_MAGIC_NAME}.${TS_TAILNET} 3900
```

Gate only on **required** backends. Do not gate on optional S3 — the stack
would refuse to start when Garage is down even though the app is configured
for local storage.

### The app container block

```yaml
  myapp:
    image: example/myapp:${MYAPP_VERSION:-1.2.3}
    network_mode: "service:ts-myapp-web"
    environment:
      # Inline the MagicDNS host. Compose does NOT expand variables inside
      # other variables, so an intermediate MYAPP_DB_HOST would be empty.
      MYAPP_DB_HOST: ${DB_MAGIC_NAME}.${TS_TAILNET}
      MYAPP_DB_PORT: "5432"
      MYAPP_DB_NAME: ${MYAPP_DB_NAME}
      MYAPP_DB_USER: ${MYAPP_DB_USER}
      MYAPP_DB_PASSWORD: ${MYAPP_DB_PASSWORD}
      # Shared SMTP relay — map the shared vars into whatever names the app
      # expects. Do not invent per-app SMTP host/user/password vars.
      MYAPP_SMTP_HOST: ${SMTP_HOST}
      MYAPP_SMTP_PORT: ${SMTP_PORT}
      MYAPP_SMTP_USER: ${SMTP_USER}
      MYAPP_SMTP_PASSWORD: ${SMTP_PASSWORD}
      MYAPP_SMTP_FROM: ${MYAPP_SMTP_FROM}
    volumes:
      - myapp-data:/var/lib/myapp
    healthcheck:
      # Prefer exec form — no shell, no forked children, nothing to orphan.
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 120s
    depends_on:
      ts-myapp-web:
        condition: service_healthy
    restart: unless-stopped

volumes:
  myapp-data:
```

Hard rules for this block:

- **No `ports:`.** It is a Compose error under `network_mode: "service:..."`
  and would expose nothing useful anyway.
- **No `networks:`.** The container shares the sidecar's namespace.
- **`depends_on` must use `condition: service_healthy`.** The bare form waits
  only for container start, not tailnet auth, and the app crash-loops trying
  to dial names that do not resolve yet.
- **Named volumes only.** Declare them at the bottom. No host bind-mounts
  without explicit maintainer sign-off — bind-mounted directories inherit
  host ownership and break apps that write as a non-root uid.
- **Pin the image** via `${MYAPP_VERSION:-<default>}`. Never `:latest`.
- **Prefer exec-form healthchecks** (`["CMD", ...]`). A `CMD-SHELL` probe
  containing `|`, `&&`, `||` or `;` forks children that Docker orphans on
  timeout; if the app's PID 1 is not an init, add `init: true` to that
  service too. (A *simple* `CMD-SHELL` command is `exec`'d by the shell and
  does not fork — that case is safe.)

### Config files: the template → runtime pattern

If the app needs a config file containing `.env` values, commit a **template
with `__PLACEHOLDER__` tokens** and generate the real file at `up` time.
Never commit a file containing operator values.

`myapp/config.yml` (tracked):

```yaml
database:
  host: __DB_HOST__
  name: __MYAPP_DB_NAME__
```

In `cmd_up` (see Step 4), before the `up -d`:

```bash
  if [[ "$stack" == "myapp" ]]; then
    sed \
      -e "s|__DB_HOST__|${DB_MAGIC_NAME}.${TS_TAILNET}|g" \
      -e "s|__MYAPP_DB_NAME__|${MYAPP_DB_NAME:-myapp}|g" \
      "${REPO_ROOT}/myapp/config.yml" \
      > "${REPO_ROOT}/myapp/config.runtime.yml"
    echo "[bootstrap] Generated myapp/config.runtime.yml."
  fi
```

Mount `./config.runtime.yml`, and add it to `.gitignore` (Step 6). Existing
examples: `garage/garage.toml`, `stalwart/config/config.json`,
`authelia/configuration.yml`, `lemmy/lemmy.hjson`.

---

## Step 2 — `.env.example`

Add a section in the same style as the others. **Every variable your compose
file reads must appear here**, with a comment explaining anything non-obvious.

```bash
# ----------------------------------------------------------------------------
# MyApp
# ----------------------------------------------------------------------------
# Public hostname (no scheme, no trailing slash). DO NOT change after first
# boot — it is baked into federation URIs.
MYAPP_DOMAIN=myapp.example.com

# Image tag. Pin and bump deliberately — schema migrations run on start.
MYAPP_VERSION=1.2.3

# Postgres credentials. Generate: openssl rand -base64 24
MYAPP_DB_NAME=myapp
MYAPP_DB_USER=myapp
MYAPP_DB_PASSWORD=

# Sender address for the shared SMTP relay (host/user/password are shared).
MYAPP_SMTP_FROM=noreply@myapp.example.com
```

Also add the MagicDNS name to the hostnames block near the top:

```bash
MYAPP_MAGIC_NAME=myapp
```

Rules:

- **Passwords embedded in a URL must be hex.** If the app assembles a
  `postgresql://user:pass@host/db` connection string, `openssl rand -base64`
  can emit `/` or `+` and corrupt the URI. Use `openssl rand -hex 32` and say
  so in the comment. (Funkwhale learned this the hard way.)
- **Reuse shared credentials.** SMTP (`SMTP_HOST`/`SMTP_PORT`/`SMTP_USER`/
  `SMTP_PASSWORD`/`SMTP_FROM_NAME`) and Garage (`GARAGE_ACCESS_KEY_ID`/
  `GARAGE_SECRET_ACCESS_KEY`/`GARAGE_REGION`) are configured once and mapped
  into each app. Only per-app values (sender address, bucket, toggles) get
  their own vars.
- **Compose cannot nest defaults.** `${A:-${B}}` is unreliable, so
  "per-app override falling back to shared" is not expressible. Map the
  shared var directly.
- **Redis DB index**, if used: claim a free one and record it in the
  allocation comment in the Redis section (0 = fediverse apps, 3 = Stalwart,
  4 = Authelia).

---

## Step 3 — the Tailscale ACL

Edit `acl.example.hujson`. Two additions.

**`tagOwners`** — note the tag must own *itself*, or auth-key node creation
is rejected with `requested tags [...] are invalid or not permitted`:

```hujson
    "tag:myapp-web": ["autogroup:admin", "tag:myapp-web"],
```

**Grants** — add your tag as a `src` to the backend rules it needs, and add a
`dst` rule for the reverse proxy:

```hujson
    // add "tag:myapp-web" to the src list of the existing Postgres rule
    { "src": [..., "tag:myapp-web"], "dst": ["tag:db-postgres"], "ip": ["tcp:5432"] },

    // new: the host reverse proxy reaches the app on its INTERNAL port
    { "src": ["tag:reverse-proxy"], "dst": ["tag:myapp-web"], "ip": ["tcp:8080"] },
```

The destination port is the port the app **listens on inside its namespace**
— not 80 or 443, which belong to the host proxy's public side.

Grant the minimum. Do not add a `dst` port "just in case"; the ACL file is
the stack's authoritative connectivity map and over-granting silently widens
the blast radius of a compromised container.

---

## Step 4 — `bootstrap.sh`

Five edits, all small. Line numbers drift — search for the anchors.

**1. Register the stack** (near line 44):

```bash
ALL_STACKS=(shared-db garage pixelfed ... lemmy myapp)
```

**2. If it uses Postgres, register it for provisioning** (near line 46):

```bash
DB_STACKS=(pixelfed mastodon ... lemmy myapp)
```

**3. Add a `provision-db` case** in `cmd_provision_db()`:

```bash
    myapp)
      _provision_role_db "${MYAPP_DB_USER:-myapp}" "${MYAPP_DB_PASSWORD}" "${MYAPP_DB_NAME:-myapp}"
      # If the app needs Postgres extensions (superuser-only), add them here:
      # _provision_extension "${MYAPP_DB_NAME}" pg_trgm
      ;;
```

Also update the `die` message listing valid apps at the bottom of that `case`.

**4. Add a `user-create` case** in `cmd_user_create()`. Pick the pattern that
matches how the app actually creates admins:

```bash
    myapp)
      echo "[bootstrap] Creating MyApp admin: ${username} <${email}>"
      echo "[bootstrap] Generated password: ${password}"
      echo ""
      # Prefer `docker exec` into the RUNNING container when the CLI takes
      # --username or --user: `docker compose run` parses those flags itself
      # and will swallow them.
      local cid
      cid=$(dc myapp ps -q myapp 2>/dev/null | head -1)
      [[ -n "$cid" ]] || die "MyApp is not running. Start it first: ./bootstrap.sh up myapp"
      docker exec "$cid" myapp-admin create \
        --username "$username" --email "$email" --password "$password"
      ;;
```

If the app has no admin CLI (Lemmy, PeerTube), print instructions instead of
pretending — see those cases for the house style. Update the `die` message
listing valid apps.

**5. Optional — runtime config generation** in `cmd_up()`, if you used the
template pattern. Place it with the other `if [[ "$stack" == ... ]]` blocks,
*before* the `dc "$stack" up -d` call. Fail fast on missing operator-created
files rather than letting Docker create empty directories in their place.

**Only if you add a new top-level command:** register it in `usage()` and in
the `case "$command" in` dispatch at the bottom, and document it in the
header comment block.

---

## Step 5 — reverse proxy snippets

Provide **both** — operators run one or the other.

`caddy/Caddyfile` — add a block:

```caddyfile
myapp.example.com {
    reverse_proxy myapp.tailfe8c.ts.net:8080 {
        header_up X-Forwarded-Proto {scheme}
    }
}
```

`nginx/sites-available/myapp.conf` — a full server block with TLS, following
the existing files. Include `proxy_set_header Host/X-Real-IP/X-Forwarded-For/
X-Forwarded-Proto`, and a note that MagicDNS names must be used because
ephemeral nodes change IP on restart.

If the app needs WebSockets, a large `client_max_body_size` for uploads, or a
separate public media host for S3, say so in a comment — these are the three
things operators most often get wrong.

---

## Step 6 — `.gitignore`

`bootstrap.sh up` auto-creates a per-stack `.env` symlink, so it must be
ignored or it will be committed by accident:

```
myapp/.env
```

Plus any runtime-generated config:

```
# Generated at runtime by bootstrap.sh — rebuilt on every 'up myapp'.
# Edit myapp/config.yml (the tracked template), not this file.
myapp/config.runtime.yml
```

---

## Step 7 — `README.md`

Add a row to the **What works today** matrix. Be honest — the table exists to
save operators a wasted afternoon, and an optimistic row is worse than no row:

- ✅ **works** — you wired it *and verified it end to end on a real deploy*
- 🟡 **kinda works** — usable, with a documented caveat
- 🚧 **you're on your own** — template only, unverified
- ✗ **not available** — upstream does not support it

If your app cannot do S3 or SSO because *upstream* lacks it, add a footnote
with a link to the upstream issue. That footnote is often the most valuable
part of the contribution.

---

## Optional — object storage and SSO

**Garage S3.** Add the bucket to the `buckets=(...)` array in
`cmd_provision_garage` (near line 251). If media must be publicly readable,
also add it to `public_buckets=(...)` (near line 300) — that enables website
serving on Garage's web endpoint (`:3902`), because the S3 API (`:3900`)
rejects anonymous reads. Keep private buckets (mail, backups) out of that
list. Wire the app to the shared `GARAGE_*` credentials behind an opt-in
toggle (`MYAPP_S3_ENABLED`), defaulting to local storage.

Each app that serves media from Garage needs its **own** public media domain
— one domain maps to exactly one bucket.

**Authelia OIDC.** Register a client in `authelia/configuration.yml` using
`__PLACEHOLDER__` tokens rendered by `bootstrap.sh` (never commit a real
client secret hash or domain — see commit `e0c6360` for why). Add the app tag
to the Authelia grant in the ACL. Note the auth method: most clients use the
default `client_secret_basic`, but some (PeerTube's plugin) require
`client_secret_post`.

---

## Invariants (do not break these)

These are non-negotiable. A PR that violates one will be asked to change,
regardless of how well it works.

1. **No `ports:` on any container.** Public traffic reaches apps through the
   host reverse proxy over MagicDNS. Internal services are never published.
2. **No bridge networks between sidecar-attached containers.** They share a
   namespace; a bridge is redundant and breaks the model.
3. **Every sidecar has `TS_ACCEPT_DNS: "true"`.**
4. **Every app container uses `depends_on: condition: service_healthy`.**
5. **Backend hosts are always `${VAR}.${TS_TAILNET}`** — never `localhost`,
   never a service name, never a tailnet IP (ephemeral nodes change IP;
   MagicDNS names are stable).
6. **Health/metrics endpoints bind `127.0.0.1` only.**
7. **No secrets in tracked files.** Templates use `__PLACEHOLDER__`; real
   values live in `.env`.
8. **No `:latest` image tags.**
9. **Do not containerize the host reverse proxy** without maintainer
   agreement — operators' existing infrastructure depends on it staying on
   the host.

If a change would violate one, raise it in the PR description rather than
working around it. "Just add a port for debugging" is never the answer —
debug via `tailscale ssh` or a temporary admin grant in the ACL.

---

## Pitfalls learned the hard way

Each of these cost a debugging session. They are in `CLAUDE.md` too; repeated
here because they bite contributors specifically.

- **Compose does not expand variables inside variables.** `MY_HOST=${A}.${B}`
  then `${MY_HOST}` yields an empty string. Inline it at the point of use.
- **Verify env-var names against the app's own mapping.** A wrong name is
  silently ignored, not an error.
- **Many official images set the binary as `ENTRYPOINT`.** With
  `docker compose run <svc> <cmd>`, do *not* repeat the binary name — it
  becomes argv[1] and scrambles the CLI parser.
- **`docker compose run` swallows `--user`/`--username`.** Use `docker exec`
  into the running container for admin commands that take those flags.
- **`shared-db/initdb/*.sh` only runs on an empty `pg-data` volume.** Use
  `bootstrap.sh provision-db <app>`, which is idempotent on any volume state.
- **Bind-mounted cache dirs inherit host ownership** and break non-root
  writers. Use named volumes.
- **Base64 passwords break URL-style connection strings.** Use hex.
- **`docker compose down` deletes the ephemeral tailnet node**, and the
  replacement gets a new IP. Anything referencing an IP will break; MagicDNS
  will not.
- **Healthcheck probes leak zombies.** Docker SIGKILLs only the top-level
  probe process on timeout; forked children reparent to PID 1 and zombie
  there forever if PID 1 is not an init. Prefer exec-form probes; add
  `init: true` where PID 1 does not reap.

---

## Testing your change

There is no CI. Test on a real host with a real tailnet before opening a PR,
and say in the description exactly how far you got.

**Static checks (no Docker needed):**

```bash
bash -n bootstrap.sh                                   # syntax
docker compose -f myapp/docker-compose.yml config -q   # compose validity
grep -rn ':latest' --include='*.yml' .                 # must be empty
grep -rn 'ports:' --include='*.yml' .                  # must be empty
```

Confirm every `${VAR}` your compose file reads exists in `.env.example`:

```bash
grep -oE '\$\{[A-Z_][A-Z0-9_]*' myapp/docker-compose.yml \
  | tr -d '${' | sort -u \
  | while read v; do grep -q "^${v}=" .env.example || echo "MISSING: $v"; done
```

**Live bring-up:**

```bash
./bootstrap.sh up shared-db
./bootstrap.sh up garage          # only if your app uses S3
./bootstrap.sh up myapp
./bootstrap.sh ps myapp           # sidecar healthy BEFORE app starts
./bootstrap.sh logs myapp
```

Then verify:

1. The node appears in the Tailscale admin console with the right tag.
2. MagicDNS resolves: `tailscale ping myapp` from the host.
3. The app is reachable from the host proxy but **not** from anywhere else.
4. `./bootstrap.sh user-create myapp alice alice@example.com` works.
5. `./bootstrap.sh down myapp` removes the node from the admin console.
6. `./bootstrap.sh up myapp` again — idempotent, no errors on re-run.
7. Federation actually works (follow a remote account, confirm delivery).

**Leak check** — the point of the whole architecture:

```bash
ss -tlnp | grep -E ':5432|:6379|:3900'   # nothing from your stack
docker compose -f myapp/docker-compose.yml ps --format '{{.Ports}}'   # empty
```

---

## Submitting your change

**Branch and commits.** Branch from `main`. Keep commits focused — one
logical change each. Message style, matching the existing history:

```
myapp: add stack with Postgres, shared SMTP, and Caddy vhost

Longer body explaining WHY, not what the diff already shows. Note any
upstream quirk you had to work around, with a link. Note anything you
could not verify.
```

Prefix with the stack name (`myapp:`, `bootstrap:`, `caddy:`, `docs:`) or use
`feat:`/`fix:`/`docs:`/`chore:`. Both forms appear in history; be consistent
within a PR.

**PR description.** Include:

- What the app is and why it belongs here.
- Which of the eight files you touched (and which you deliberately did not).
- **Exactly what you tested**, on what — "brought up on Debian 12, verified
  federation with mastodon.social, S3 untested" is far more useful than
  "works".
- Any invariant you had to bend, and why.
- Upstream limitations that shaped the design.

**Checklist to paste into your PR:**

```markdown
- [ ] `<app>/docker-compose.yml` — no `ports:`, no `networks:`, pinned image
- [ ] Sidecar: `TS_ACCEPT_DNS`, `init: true`, loopback health port, backend gates
- [ ] App container: `depends_on: condition: service_healthy`, named volumes
- [ ] `.env.example` — every var documented; hex password if URL-embedded
- [ ] `acl.example.hujson` — self-owning tag + minimal grants
- [ ] `bootstrap.sh` — ALL_STACKS, DB_STACKS, provision-db, user-create
- [ ] `caddy/Caddyfile` + `nginx/sites-available/<app>.conf`
- [ ] `.gitignore` — `<app>/.env` and any runtime config
- [ ] `README.md` — support-matrix row, honestly rated
- [ ] No secrets, real domains, or personal identifiers in tracked files
- [ ] Tested live: bring-up, user-create, teardown, re-up, federation
```

**Before you push, check for leaked secrets.** Tracked templates must never
contain real domains, hashes, or credentials — including in commit messages,
which survive a later scrub of the file:

```bash
git diff --cached | grep -iE 'password|secret|pbkdf2|@[a-z0-9.-]+\.(com|net|org)'
```

---

## Questions

Open an issue before investing significant time in a large change — an app
that needs a new architectural pattern (a second edge proxy, persistent
tailnet identity, a non-Postgres datastore) is worth discussing first. Small
fixes can go straight to a PR.
