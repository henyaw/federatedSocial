# Federated Social Stack

Self-host federated social services (Pixelfed, Mastodon, Diaspora, Funkwhale, GoToSocial, PeerTube, and more) on one server — or several, in different countries — with shared database and object-storage infrastructure and Tailscale-based networking. No firewall rules to write. No internal services exposed to the public internet. Edit one file, run one command per stack, done.

## What you get

- **Shared Postgres and Redis** that all your apps connect to — one database stack instead of one per app.
- **Shared Garage object storage** (S3-compatible). Opt any app into storing its media in Garage instead of a local volume, so instances are portable across servers and survive a host rebuild. Also the foundation for backups.
- **Tailscale-native networking**: internal services are only reachable over your private Tailscale network. They have no exposed ports on your server.
- **Tag-based access control**: who can talk to what is defined in a single JSON file in the Tailscale admin console, not in iptables or firewall configs.
- **A single operator script** (`bootstrap.sh`) that brings stacks up and down, provisions databases and storage, and creates admin users — so you don't have to learn each app's CLI.
- **Clean teardown**: tearing a stack down removes its services from your Tailscale admin console automatically. No ghost devices to clean up.
- **One `.env` file** controls the whole stack. Hostnames, passwords, domains, SMTP, storage keys — all in one place.

## What you need

- A Linux server (Debian or Ubuntu recommended) with Docker and Docker Compose installed. Multiple servers on the same tailnet also work — Postgres, Redis, and Garage can live anywhere your apps can reach over Tailscale.
- A [Tailscale account](https://tailscale.com/) (the free tier covers up to 100 devices, which is plenty for several apps).
- A domain name with DNS pointing at your server's public IP, for each app you plan to run publicly.
- A reverse proxy on the host for terminating public HTTPS. The repo includes reference configs for both **Caddy** (`caddy/Caddyfile`, the simplest path — automatic Let's Encrypt) and **Nginx** (`nginx/sites-available/`).
- An SMTP relay (SendGrid, Mailgun, Postmark, SES, your own Postfix…) if you want password resets and signup confirmations to work. Strongly recommended — see [Email (SMTP)](#email-smtp).
- Basic comfort with editing config files and running shell commands. You do not need to know iptables, Docker networking internals, or Tailscale beyond the basics.

## How it works (the short version)

Every container in this stack joins your Tailscale network as its own device. Your apps reach the database, Redis, and object storage through Tailscale's private network using hostnames like `pgsql-prod.your-tailnet.ts.net`. Those services have no ports bound to your server — the only way to reach them is from inside your Tailscale network, gated by access rules you define.

Your reverse proxy on the host receives public HTTPS traffic and forwards it to the appropriate app's Tailscale hostname. Everything internal stays internal.

## The `bootstrap.sh` interface

`bootstrap.sh` is the front door for day-to-day operations. It reads your repo-root `.env`, wraps `docker compose` for each stack, and handles the fiddly bits (per-stack `.env` symlinks, idempotent database and storage provisioning, per-app admin-user creation).

```
./bootstrap.sh up   <stack>               Bring up a stack (auto-provisions its DB if shared-db is local)
./bootstrap.sh down <stack>               Tear down a stack
./bootstrap.sh logs <stack> [service]     Tail logs
./bootstrap.sh ps   [stack]               Show container status
./bootstrap.sh provision-db <app>         Idempotent DB role + database setup
./bootstrap.sh provision-garage           Idempotent Garage layout + buckets + key
./bootstrap.sh user-create <app> <user> <email>   Create an admin user
```

Stacks: `shared-db`, `garage`, `pixelfed`, `mastodon`, `diaspora`, `funkwhale`, `gotosocial`, `peertube`.

You can still `cd` into a stack directory and run `docker compose` directly — `bootstrap.sh` doesn't hide anything, it just saves steps.

## Setup

### 1. Clone the repo

```bash
git clone <repo-url> federated-social
cd federated-social
```

### 2. Create your Tailscale OAuth client

In the [Tailscale admin console](https://login.tailscale.com/admin/settings/oauth):

1. Go to **Settings → OAuth clients → Generate OAuth client**.
2. Give it a description (e.g. "federated-social stack").
3. Under **Scopes**, enable **Devices: Core (write)**, **Keys: Auth Keys (read/write)**, and **Keys: OAuth Keys (read/write)**. (See the comments in `acl.example.hujson` for why all three are needed.)
4. Under **Tags**, add every tag this stack uses. At minimum:
   - `tag:db-postgres`
   - `tag:db-redis`
   - `tag:garage` (if you'll use object storage)
   - Plus one or more app tags (e.g. `tag:pixelfed-web`) for each app you'll run.
   See `acl.example.hujson` for the full list.
5. Click **Generate client** and copy both the **Client ID** and **Client secret**. You'll need them in a moment.

### 3. Set your Tailscale ACL

In the admin console, go to **Access Controls** and paste the contents of `acl.example.hujson` into the editor. Adjust if you're only running some of the apps (you can delete tags you don't need). Save.

This file defines which services can talk to which. The defaults allow app tiers to reach Postgres, Redis, and Garage, allow your host reverse proxy to reach the app web tiers, and allow you (as an admin) to reach everything for debugging.

### 4. Configure `.env`

Copy the example and edit it:

```bash
cp .env.example .env
$EDITOR .env
```

You'll need to fill in:

- `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_CLIENT_SECRET` from step 2.
- `TS_TAILNET` — your tailnet's domain (visible in the admin console, looks like `tailfe8c.ts.net` or `yourname.ts.net`).
- Hostnames for each service (`DB_MAGIC_NAME`, `REDIS_MAGIC_NAME`, `GARAGE_MAGIC_NAME`, etc.). These become the names your services appear under in Tailscale. Pick whatever you want; the defaults are fine.
- Database credentials. Generate strong passwords; you won't be typing these often. (Note the comment on `FUNKWHALE_DB_PASSWORD` — use hex, not base64.)
- `GARAGE_RPC_SECRET` if you'll run object storage (`openssl rand -hex 32`). Leave `GARAGE_ACCESS_KEY_ID`/`SECRET` blank for now — `provision-garage` fills those in.
- The shared `SMTP_*` relay block — see [Email (SMTP)](#email-smtp).
- Per-app settings (domain names, app-specific secrets). Each app's section is commented.

### 5. Bring up the shared database stack first

```bash
./bootstrap.sh up shared-db
```

Wait about 30 seconds, then check the Tailscale admin console. You should see two new devices (the Postgres and Redis sidecars) with the hostnames you chose. If they don't appear, check the logs:

```bash
./bootstrap.sh logs shared-db ts-postgres
./bootstrap.sh logs shared-db ts-redis
```

The most common issue is a typo in the OAuth client secret or a missing tag in the OAuth client config.

### 6. (Optional) Bring up Garage object storage

If you want apps to store media in shared object storage instead of local volumes:

```bash
./bootstrap.sh up garage
```

This brings up Garage and runs `provision-garage`, which initialises the cluster layout, creates the app buckets, and generates an access key. It prints two values:

```
GARAGE_ACCESS_KEY_ID=...
GARAGE_SECRET_ACCESS_KEY=...
```

Paste those into your `.env`. You can now opt any app into S3 storage by setting its flag (`MASTODON_S3_ENABLED=true`, `PIXELFED_FS_DRIVER=s3`, `PEERTUBE_OBJECT_STORAGE_ENABLED=true`) before bringing it up. See [Object storage](#object-storage-garage).

### 7. Bring up each app stack

For each app you want to run:

```bash
./bootstrap.sh up pixelfed   # or mastodon, funkwhale, gotosocial, peertube, diaspora
```

`up` provisions the app's database automatically (idempotent — works on a fresh or long-running Postgres). Then check the admin console again — the app's web tier (and any workers, streaming services, etc.) should appear as Tailscale devices.

### 8. Create your admin user

**Configure SMTP first** (see [Email (SMTP)](#email-smtp)) — several apps have no password-reset CLI, so a working relay is your only recovery path if you forget the admin password.

```bash
./bootstrap.sh user-create mastodon alice alice@example.com
```

Generated passwords are printed once — save them. (PeerTube and GoToSocial differ slightly; `user-create` explains each as you run it.)

### 9. Configure your reverse proxy

For each public-facing app, add a server block to your host reverse proxy.

**Caddy** (recommended — automatic TLS): copy `caddy/Caddyfile`, replace the example domains and the `tailfe8c.ts.net` placeholder with your tailnet, and reload. Every app already has a block.

**Nginx**: reference snippets are in `nginx/sites-available/`. The pattern is:

```nginx
server {
    listen 443 ssl http2;
    server_name social.example.com;
    # your SSL cert config here

    location / {
        proxy_pass http://pixelfed.your-tailnet.ts.net:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Either way, your host must be on the tailnet **and tagged `tag:reverse-proxy`** so the ACL lets it reach the app web tiers. The hostname `pixelfed.your-tailnet.ts.net` resolves because Tailscale is installed and running on the host; if it doesn't resolve, run `tailscale up` on the host and make sure MagicDNS is enabled in your admin console under **DNS**. (Each app listens on its own internal port — Pixelfed/Funkwhale on 80, Mastodon on 3000, GoToSocial on 8080, PeerTube on 9000; the reference configs have the right port per app.)

Reload your reverse proxy and visit your domain. You should see the app.

## Object storage (Garage)

[Garage](https://garagehq.deuxfleurs.fr) is a lightweight, S3-compatible, distributed object store. It runs as its own stack (`garage/`) behind a Tailscale sidecar, just like the database.

**Why use it.** Local Docker volumes don't travel. The moment you move an instance to another server, or put it behind a load balancer, locally-stored media is stranded. Postgres already travels with the tailnet; Garage does the same for uploads. It's also the natural target for backups.

**How it's wired.** Each media app has an S3 opt-in block in its `.env` section, off by default. Flip the flag and the app reads/writes objects in Garage over the tailnet instead of a local volume:

| App | Enable with |
|-----|-------------|
| Mastodon | `MASTODON_S3_ENABLED=true` |
| Pixelfed | `PIXELFED_FS_DRIVER=s3` |
| PeerTube | `PEERTUBE_OBJECT_STORAGE_ENABLED=true` |

All three share the one `GARAGE_ACCESS_KEY_ID` / `GARAGE_SECRET_ACCESS_KEY` pair from `provision-garage`. Buckets are created for you (`mastodon-media`, `pixelfed-media`, `peertube-web-videos`, `peertube-streaming-playlists`, `funkwhale-music`, plus `pg-backups` for database dumps).

**Single node vs. cluster.** Garage starts single-node (`replication_factor = 1` in `garage/garage.toml`). To add a second node on another server: bring it up with the same `GARAGE_RPC_SECRET`, add its tailnet address to `rpc_bootstrap_peers`, raise the replication factor, and re-run `provision-garage`. Two servers in two countries is exactly Garage's intended topology.

**Want to use an external bucket instead?** Point an app's endpoint at your provider (Backblaze B2, Wasabi, Scaleway, AWS) rather than Garage. PeerTube's `.env` section documents the per-field overrides; the same pattern applies to the others.

## Email (SMTP)

Every app shares one SMTP relay. Fill in the `SMTP_*` block in `.env` once
(`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`) and each app maps it
into the variable names it expects — you don't configure email six times.
Per-app sender addresses live in each app's `.env` section since they differ
by domain.

Do this **before creating your admin user**. Several apps (Pixelfed most
notably) have no password-reset CLI — without working email, a forgotten
admin password means editing the database by hand. To turn email on after
filling in the relay:

- **Pixelfed**: set `PIXELFED_MAIL_DRIVER=smtp` (default `log` just writes to
  the app log).
- **Diaspora**: set `DIASPORA_MAIL_ENABLE=true`.
- **Mastodon / GoToSocial / PeerTube**: send automatically once `SMTP_HOST` is
  set.
- **Funkwhale**: takes a single connection string instead of discrete fields.
  Set `FUNKWHALE_EMAIL_CONFIG=smtp+tls://USER:PASSWORD@HOST:PORT`
  (URL-encode special characters in USER/PASSWORD).

Port 587 (STARTTLS) is the default throughout. For an implicit-TLS relay on
port 465, set `SMTP_PORT=465` and flip the per-app TLS switch where one
exists (e.g. `PEERTUBE_SMTP_TLS=true`, `PIXELFED_MAIL_ENCRYPTION=ssl`).

## Day-to-day operation

### Updating an app

```bash
cd pixelfed
docker compose pull
./bootstrap.sh up pixelfed   # or: docker compose up -d
```

Compose recreates only the containers whose images changed.

### Stopping a stack

```bash
./bootstrap.sh down pixelfed
```

The Tailscale devices automatically disappear from your admin console. Bringing it back up registers fresh devices with the same hostnames.

### Adding a new app

Each app lives in its own directory. To add one not already included:

1. Copy an existing app directory as a starting point (use `pixelfed/` for simple apps, `mastodon/` for multi-component apps).
2. Update the image references, environment variables, and hostnames inside the new directory's `docker-compose.yml`. Wire its SMTP and S3 to the shared vars.
3. Add the new app's environment variables to `.env` and `.env.example`.
4. Add the new app's tag to your OAuth client's allowed tags in the admin console.
5. Add the tag to `acl.example.hujson` (and the relevant grant rules) and update your ACL in the admin console.
6. Add a reverse proxy block (Caddy and/or Nginx).
7. Add the app to `bootstrap.sh` (`ALL_STACKS`, `DB_STACKS`, and a `provision-db`/`user-create` case).
8. `./bootstrap.sh up <newapp>`.

`CLAUDE.md` documents this checklist in detail, including the env-var pitfalls each app's config system imposes.

### Backups

Garage gives you a place to put backups that isn't the same disk as your data. The `pg-backups` bucket is created for exactly this. A minimal strategy:

- **Database**: `pg_dumpall` (or per-database `pg_dump`) on a cron, shipped to the `pg-backups` bucket. This is the one piece worth automating — everything else can be rebuilt.
- **Media**: already in Garage if you've opted apps into S3 storage; replicate it to a second node or an external bucket for off-site safety.
- **Redis**: no backup needed — every app in this stack treats it as a cache/queue, not a source of truth.
- **`.env`**: the only thing that must live outside Garage. Keep a copy in a password manager or encrypted off-site store — it holds every secret, and recovery starts here.
- **Tailscale ACL JSON**: export it from the admin console.

A `pg_dump`-to-Garage cron is not yet templated in this repo; it's the obvious next addition. Set up *something* before you have data you'd miss losing.

## Troubleshooting

**App container keeps restarting with "database connection refused"**

Almost always means the database sidecar isn't healthy yet. Check `docker compose ps` in the `shared-db/` directory — both sidecars should show `(healthy)`. If they don't, check their logs. If they do, check that the app's `.env` values for `DB_HOST` match what the database stack is advertising.

**Adding an app after shared-db has already run once — its DB user doesn't exist**

The `shared-db/initdb/00-create-app-dbs.sh` script only runs on a fresh `pg-data` volume. If you add a new app after first boot, use `bootstrap.sh provision-db` instead — it is idempotent and works on any volume state:

```bash
./bootstrap.sh provision-db peertube   # or pixelfed, mastodon, etc.
```

> **Multi-server note:** `provision-db` must be run from the host where shared-db is running — it uses `docker exec` into the Postgres container. On a multi-server setup, `bootstrap.sh up <app>` on the app host skips auto-provisioning (shared-db is not visible locally) and tells you so. Run `provision-db` on the shared-db host manually, then bring up the app.

`./bootstrap.sh up <app>` also calls this automatically when shared-db is running, so the normal bring-up flow handles it end-to-end.

**A config secret (e.g. `secrets.peertube`) is "missing" even though it's in `.env`**

Two common causes. First: you ran `docker compose -f <stack>/...` from the repo root without the per-stack `.env` symlink, so Compose read the wrong `.env`. Use `./bootstrap.sh up <stack>` (it creates the symlink) or run from inside the stack directory. Second: a restarting container caches the env from when it first started — `down` then `up` to force a fresh read.

**Garage opt-in is on but the app can't reach the bucket**

Confirm Garage is up and healthy (`./bootstrap.sh ps garage`), that you ran `./bootstrap.sh provision-garage` and pasted the printed `GARAGE_ACCESS_KEY_ID`/`SECRET` into `.env`, and that `tag:garage` is in both your OAuth client tags and the ACL.

**Sidecar shows "needs login" or doesn't appear in admin console**

The OAuth client secret in `.env` is wrong, or the tag the sidecar is trying to advertise isn't allowed by the OAuth client. Check the OAuth client config in the admin console and confirm the tag is listed.

**Hostnames like `pgsql-prod.tailfe8c.ts.net` don't resolve from the host**

MagicDNS isn't enabled, or the host isn't on the tailnet. Run `tailscale status` to confirm the host is connected, and check **DNS → MagicDNS** in the admin console.

**App is reachable from your reverse proxy but federation isn't working**

Federation problems are usually app-level (domain configuration, public URL settings, signed HTTP signatures), not networking. Check the specific app's documentation. Your tailnet is irrelevant once traffic reaches the app — federation traffic comes in through your reverse proxy like any other web request.

**"docker compose up" fails with `network_mode: service:... is incompatible with ports`**

You've added a `ports:` directive somewhere it shouldn't be. Containers using `network_mode: "service:..."` share their sidecar's network namespace and cannot have their own port mappings. Remove the `ports:` lines.

**A Tailscale device for an old hostname is still in the admin console**

If you renamed a service in `.env`, the old name's device is now an unused ephemeral node. It will time out and disappear on its own, or you can delete it manually from the admin console.

## Security notes

- Internal services (Postgres, Redis, Garage) have no exposed ports on your server. They are only reachable through your tailnet. This is enforced by container network configuration, not firewall rules — meaning a host firewall misconfiguration cannot expose them.
- Access between services is controlled by Tailscale ACL tags. If you add a new app, make sure to add the right tags to the ACL or it won't be able to reach the database or storage.
- The `.env` file contains all your passwords and storage keys. Don't commit it to git. The included `.gitignore` excludes it by default; don't override that.
- Your OAuth client secret is roughly as sensitive as your Tailscale account credentials for this stack. Rotate it if you suspect exposure.
- Public-facing apps are still public-facing. The tailnet protects internal service-to-service communication, not the public web interface. Standard web security applies: keep apps updated, use strong admin passwords, enable 2FA where supported.

## Design philosophy

This stack is intentionally opinionated. It assumes you'd rather have something that works out of the box with reasonable defaults than something infinitely configurable. If you need a different topology — separate hosts for database and apps, persistent (non-ephemeral) Tailscale identities, a containerized reverse proxy — this isn't the wrong starting point but you'll be modifying templates. The `CLAUDE.md` in the repo root documents the architecture in detail if you want to understand or extend it.

The goal is for operators to spend their time running a community, not running infrastructure.

## License

See `LICENSE` in the repo root.

## Contributing

Issues and pull requests welcome. New app templates especially welcome — if you've gotten an app working in this pattern, contribute its directory back.
