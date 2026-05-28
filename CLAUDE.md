# CLAUDE.md

Guidance for Claude Code working in this repository. Read this fully before editing any file.

## What this repo is

A Tailscale-native, "play-not-work" deployment template for self-hosted federated social services (Pixelfed, Mastodon, Funkwhale, etc.) on a single Debian host (with a clean path to multi-host clustering later).

The design goal: an unseasoned operator should be able to clone this repo, edit one `.env` file, paste one ACL JSON into the Tailscale admin console, and run `docker compose up -d` in each stack directory. They should never need to touch iptables, learn Docker networking internals, or hand-configure TLS for internal services.

The security model is **Tailscale ACLs over Docker network namespaces**, not host firewall rules. Internal services (Postgres, Redis) have zero exposure to the host network — their only reachable interface is `tailscale0` inside their sidecar's namespace. The host Nginx terminates public TLS and proxies to public-facing app tiers via MagicDNS.

## Architecture

### Topology

- **Shared services stack** (`shared-db/`): Postgres + Redis, each behind its own Tailscale sidecar. No host port bindings. Tagged `tag:db-postgres` and `tag:db-redis`. Reachable only via tailnet.
- **Per-app stacks** (`pixelfed/`, `mastodon/`, `funkwhale/`, ...): Each app's web/worker/streaming components run behind their own Tailscale sidecars, tagged per role. They reach Postgres/Redis via MagicDNS hostnames over the tailnet.
- **Host Nginx** (not containerized, see "Host Nginx" below): terminates public TLS, proxies to app web tiers by MagicDNS name.
- **Host-level Tailscale**: already installed and authenticated on the Debian host. Independent of the sidecars. Used by host Nginx to resolve MagicDNS and reach app web tiers, and used by Syncthing (separate concern, do not touch).

### The sidecar pattern

Every container that needs tailnet identity gets its own `tailscale/tailscale` sidecar. The app container uses `network_mode: "service:<sidecar-name>"` to share the sidecar's network namespace. This means:

- The app container has no network interfaces of its own.
- The app's "localhost" is the sidecar's localhost.
- The app's only outbound path is through `tailscale0`.
- There is no Docker bridge network involved for these containers, and no `ports:` mapping is possible or appropriate.

This is the security boundary. **Do not break it.**

### Auth model

- Single OAuth client registered in Tailscale admin console, scoped to the tags this repo uses.
- Client ID + client secret stored in top-level `.env`.
- Every sidecar passes `TS_AUTHKEY=${TS_OAUTH_CLIENT_SECRET}?ephemeral=true` and advertises its tag via `TS_EXTRA_ARGS=--advertise-tags=tag:<role>`.
- Nodes are **ephemeral**: `docker compose down` self-cleans them from the admin console. No `TS_STATE_DIR` volumes.
- Ephemeral nodes get new tailnet IPs on each restart. **MagicDNS hostnames are stable.** Always reference services by MagicDNS name, never by IP.

## Repo layout

```
federated-social/
├── CLAUDE.md                   # this file
├── README.md                   # operator-facing setup guide
├── .env.example                # template; operators copy to .env
├── acl.example.hujson          # Tailscale ACL template
├── shared-db/
│   └── docker-compose.yml      # postgres + redis + sidecars
├── pixelfed/
│   └── docker-compose.yml
├── mastodon/
│   └── docker-compose.yml
├── funkwhale/
│   └── docker-compose.yml
└── nginx/
    └── sites-available/        # host nginx snippets, reference only
```

Each app directory is self-contained and copy-pasteable. Adding a new app means copying an existing app directory, renaming, updating tags, and adding the tag to the ACL.

## The `.env` contract

The `.env` file at the repo root is the entire operator surface. Every compose file reads from it. Never hardcode values that belong in `.env`.

Required keys:

```bash
# Tailscale OAuth (from admin console, one-time)
TS_OAUTH_CLIENT_ID=
TS_OAUTH_CLIENT_SECRET=
TS_TAILNET=                     # e.g. tailfe8c.ts.net

# MagicDNS hostnames (operator picks these once)
DB_MAGIC_NAME=pgsql-prod
REDIS_MAGIC_NAME=redis-prod
PIXELFED_MAGIC_NAME=pixelfed
MASTODON_WEB_MAGIC_NAME=mastodon
MASTODON_STREAMING_MAGIC_NAME=mastodon-streaming
# ... one per public-facing app component

# Database credentials
POSTGRES_PASSWORD=
PIXELFED_DB_NAME=pixelfed
PIXELFED_DB_USER=pixelfed
PIXELFED_DB_PASSWORD=
MASTODON_DB_NAME=mastodon
MASTODON_DB_USER=mastodon
MASTODON_DB_PASSWORD=
# ... one set per app

# App-specific (varies)
PIXELFED_DOMAIN=
MASTODON_DOMAIN=
```

When adding a new app or component, add its env vars to `.env.example` with sensible defaults or empty placeholders, and document any non-obvious value in a comment.

## Sidecar boilerplate

Every Tailscale sidecar service uses this skeleton. Deviations need a stated reason.

```yaml
ts-<role>:
  image: tailscale/tailscale:latest
  hostname: ${<ROLE>_MAGIC_NAME}
  environment:
    TS_AUTHKEY: ${TS_OAUTH_CLIENT_SECRET}?ephemeral=true
    TS_EXTRA_ARGS: --advertise-tags=tag:<role>
    TS_HOSTNAME: ${<ROLE>_MAGIC_NAME}
    TS_ACCEPT_DNS: "true"
    TS_AUTH_ONCE: "true"
    TS_USERSPACE: "false"
    TS_ENABLE_HEALTH_CHECK: "true"
    TS_LOCAL_ADDR_PORT: "127.0.0.1:9002"
  devices:
    - /dev/net/tun:/dev/net/tun
  cap_add:
    - NET_ADMIN
    - NET_RAW
  healthcheck:
    test: ["CMD", "wget", "-qO-", "http://127.0.0.1:9002/healthz"]
    interval: 10s
    timeout: 5s
    retries: 6
    start_period: 30s
  restart: unless-stopped
```

Notes on each setting (do not change without reason):

- `TS_USERSPACE: "false"` + `cap_add: [NET_ADMIN, NET_RAW]` + `/dev/net/tun` — kernel networking. Userspace would work but is slower and Postgres/Redis benefit from kernel mode.
- `TS_ACCEPT_DNS: "true"` — required for MagicDNS resolution inside the namespace. Without this, `${DB_MAGIC_NAME}.${TS_TAILNET}` won't resolve. **Never omit.**
- `TS_ENABLE_HEALTH_CHECK: "true"` + `TS_LOCAL_ADDR_PORT: "127.0.0.1:9002"` — exposes `/healthz` for Compose to wait on. Bind to 127.0.0.1, never `0.0.0.0` or `[::]`, so it isn't reachable across the tailnet.
- Ephemeral auth: the `?ephemeral=true` suffix on the auth key is required. Do not remove it without also adding `TS_STATE_DIR` and a persistent volume.

## App container pattern

Every app container that needs tailnet presence:

```yaml
<app>:
  image: <app-image>
  network_mode: "service:ts-<role>"
  environment:
    DB_HOST: ${DB_MAGIC_NAME}.${TS_TAILNET}
    REDIS_HOST: ${REDIS_MAGIC_NAME}.${TS_TAILNET}
    # ... other app env
  depends_on:
    ts-<role>:
      condition: service_healthy
  restart: unless-stopped
```

Hard rules:

- **No `ports:` directive on app containers using `network_mode: "service:..."`**. It's a Compose error and exposes nothing useful.
- **No `networks:` directive on these containers** — they share the sidecar's namespace.
- **`depends_on` must use `condition: service_healthy`**, not the bare form. Bare `depends_on` only waits for container start, not tailnet authentication, and the app will crash-loop trying to dial MagicDNS names that haven't resolved yet.
- **DB/Redis hostnames are always `${VAR_NAME}.${TS_TAILNET}` form**. Never `db`, never `localhost`, never an IP.

## The leak-resistance invariant

This is the most important property of the repo. Internal services (Postgres, Redis, anything in `shared-db/` or future internal stacks) must satisfy all three:

1. **No `ports:` mapping anywhere in their compose file.**
2. **The data container uses `network_mode: "service:<sidecar>"`** so it has no interface other than `tailscale0`.
3. **Tailscale ACLs gate access by tag**, not by IP or hostname.

If a change would violate any of these, stop and surface it to the user. Do not "just add a port for debugging" — operators should debug via `tailscale ssh` or a temporary admin tag in the ACL, never by exposing a host port.

Public-facing app web tiers are different: they are reached by host Nginx via MagicDNS, and the host Nginx is the only thing that should reach them. They still don't bind host ports — Nginx proxies to their tailnet hostname.

## Host Nginx

Nginx stays on the host (not containerized) for now. The host has Tailscale installed and can resolve MagicDNS, so configs look like:

```nginx
server {
    listen 443 ssl http2;
    server_name pixelfed.example.com;
    # ... ssl config ...

    location / {
        proxy_pass http://pixelfed.tailfe8c.ts.net:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Reference snippets live in `nginx/sites-available/` for operators to copy. Do not propose containerizing Nginx without explicit user request — the operator's existing legacy infrastructure depends on host Nginx.

## ACL conventions

The Tailscale ACL is the security policy. It lives in `acl.example.hujson` as a template, and operators paste it into the admin console.

Tag naming convention: `tag:<app>-<role>` where role is one of `web`, `streaming`, `worker`, or for shared services `tag:db-<engine>`.

Examples in use:

- `tag:db-postgres`, `tag:db-redis` — shared services
- `tag:pixelfed-web`, `tag:pixelfed-worker`
- `tag:mastodon-web`, `tag:mastodon-streaming`, `tag:mastodon-sidekiq`

ACL rules follow the principle: **app tiers can reach exactly the shared services they need, on exactly the ports they need, and nothing else**. Admin group can reach everything for debugging.

```hujson
{
  "tagOwners": {
    "tag:db-postgres":         ["autogroup:admin"],
    "tag:db-redis":            ["autogroup:admin"],
    "tag:pixelfed-web":        ["autogroup:admin"],
    "tag:pixelfed-worker":     ["autogroup:admin"],
    "tag:mastodon-web":        ["autogroup:admin"],
    "tag:mastodon-streaming":  ["autogroup:admin"],
    "tag:mastodon-sidekiq":    ["autogroup:admin"],
  },
  "acls": [
    {
      "action": "accept",
      "src": [
        "tag:pixelfed-web", "tag:pixelfed-worker",
        "tag:mastodon-web", "tag:mastodon-streaming", "tag:mastodon-sidekiq",
      ],
      "dst": ["tag:db-postgres:5432", "tag:db-redis:6379"],
    },
    {
      "action": "accept",
      "src": ["autogroup:admin"],
      "dst": ["*:*"],
    },
  ],
}
```

When adding a new app, add its tags to `tagOwners` and add its web/worker tags to the `src` list of the DB-access rule. Don't broaden the `dst` ports without reason.

## Bring-up order

`shared-db/` must be up and healthy before any app stack. The DB sidecars must be reachable on the tailnet (visible in admin console, MagicDNS resolves) before app sidecars try to dial them.

Documented operator order in `README.md`:

1. `cd shared-db && docker compose up -d`
2. Wait for both DB sidecars to appear in admin console.
3. `cd pixelfed && docker compose up -d` (or any other app stack).

Compose `depends_on` cannot enforce this across separate compose files. The healthcheck on the app sidecar will catch a missing DB at app boot, but the failure mode is a crash loop, not a clean message. Document the order; don't try to engineer around it.

## When editing compose files

- Preserve the sidecar boilerplate exactly. If a Tailscale parameter changes, update every sidecar consistently in one pass.
- Every new env var added to a compose file must also appear in `.env.example` with a comment.
- Every new tag must be added to `acl.example.hujson` with a corresponding rule.
- Every new app must include `TS_ACCEPT_DNS: "true"` on its sidecar. Forgetting this is the single most common breakage.
- Healthchecks are mandatory on sidecars. Don't remove them to "simplify."
- Volumes for stateful containers (Postgres data, Redis if persistent, app uploads) must be named volumes declared at the bottom of the compose file. Never bind-mount to host paths without explicit user instruction.

## When adding a new federated app

1. Copy the closest existing app directory (e.g. `pixelfed/` for a single-web-tier app, `mastodon/` for a multi-component app).
2. Rename services and update `TS_HOSTNAME` / `--advertise-tags` for each sidecar.
3. Add new env vars to `.env.example`.
4. Add new tags to `acl.example.hujson` and add them to the DB-access rule's `src` list.
5. Add a host Nginx reference snippet in `nginx/sites-available/`.
6. Update `README.md` operator instructions.
7. Verify: no `ports:` directives, every sidecar has `TS_ACCEPT_DNS: "true"`, every app has `depends_on: condition: service_healthy`, all hostnames use `${VAR}.${TS_TAILNET}` form.

### Pitfalls learned the hard way

- **Compose does not expand variables inside other variables.** Writing `MY_HOST=${DB_MAGIC_NAME}.${TS_TAILNET}` and then referencing `${MY_HOST}` produces an empty string. Always inline `${DB_MAGIC_NAME}.${TS_TAILNET}` directly in the consuming env var (e.g. `GTS_DB_ADDRESS`, `DATABASE_HOST`).
- **Check the app's actual env-var → config-key mapping before naming variables.** Apps derive env-var names in different ways and a wrong name is silently ignored. Examples caught in this repo: GoToSocial maps `db-address` → `GTS_DB_ADDRESS` (not `GTS_DB_HOST`); PeerTube maps `secrets.peertube` → `PEERTUBE_SECRET` (not `PEERTUBE_SECRETS_PEERTUBE`). Always verify against the app's `custom-environment-variables.yaml` or equivalent before writing a new env var.
- **Many official images set the binary as `ENTRYPOINT`.** When invoking via `docker compose run <svc> <cmd>`, do NOT prefix with the binary name — that becomes the first argv and scrambles the CLI parser. Pass subcommands directly.
- **`docker compose run` parses its own flags interspersedly** and will swallow app flags that overlap (notably `--user`/`--username`). For app admin commands that take `--username`, use `docker exec` into the already-running container instead of `docker compose run`.
- **Bind-mounted cache directories inherit host ownership.** For caches that the app writes to as a non-root uid (e.g. GTS Wazero cache), use a named volume instead — Docker manages ownership from the image filesystem.
- **`shared-db/initdb/*.sh` only runs on an empty pg-data volume.** Adding a new app's DB credentials after first boot requires manual `CREATE ROLE` / `CREATE DATABASE` via `docker compose exec`. The README has the snippet under "Troubleshooting".

## What not to do

- **Don't add `ports:` to any internal service.** If a port is needed externally, route it through host Nginx + MagicDNS.
- **Don't add Docker bridge networks between sidecar-attached containers.** They share the sidecar netns; bridges are redundant and break the model.
- **Don't suggest containerizing host Nginx** unless the user explicitly asks. The user's legacy infrastructure constrains this choice.
- **Don't replace ephemeral auth with persistent state** unless the user explicitly asks. The play-not-work design depends on `docker compose down` being a clean operation.
- **Don't reference services by tailnet IP.** Always MagicDNS hostnames.
- **Don't add complexity that the operator has to learn.** Complexity belongs in the templates the user (the repo author) maintains, not in the operator's day. If a fix requires the operator to learn a new concept, surface that tradeoff before implementing.
- **Don't bind healthcheck or metrics endpoints to anything other than 127.0.0.1.** Binding to `[::]` or `0.0.0.0` exposes them across the tailnet.

## Editor and tooling notes

- The repo author uses Vim/Neovim. Keep formatting clean and consistent — 2-space indent in YAML, no trailing whitespace.
- Compose file version field: omit it (modern Compose ignores it and warns if present).
- Comments in compose files are welcome where they explain non-obvious choices, especially around the sidecar pattern.

## Open design questions

These are deliberately unresolved and should be flagged to the user when relevant, not silently decided:

- **Multi-host clustering**: current design is single-host. Moving Postgres to a dedicated host on the tailnet is a known future step but not implemented.
- **Backup strategy for `pg-data` and similar volumes**: not yet templated. Operator's responsibility for now.
- **Cert management for host Nginx**: assumed to be the operator's existing process (Let's Encrypt via certbot or similar). Not in scope for this repo.
- **Object storage for media**: PeerTube has S3 templated (opt-in via `PEERTUBE_OBJECT_STORAGE_*` env vars in `.env.example`). Pixelfed and Funkwhale are still local-volume only — retrofit them with the same `<APP>_OBJECT_STORAGE_*` pattern when an operator needs it.

If a user request touches one of these, say so and ask before implementing.
