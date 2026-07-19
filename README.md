# Federated Social Stack

Self-host federated social services — Pixelfed, Mastodon, Diaspora, Funkwhale, GoToSocial, PeerTube, Lemmy, and more — plus shared mail (Stalwart), single sign-on (Authelia), and object storage (Garage), on one server or spread across several in different countries. Tailscale-based networking means no firewall rules to write and no internal services exposed to the public internet. Edit one `.env` file, run one command per stack, done.

## What you get

- **Shared Postgres and Redis** that all your apps connect to — one database stack instead of one per app.
- **Shared Garage object storage** (S3-compatible). Opt any app into storing its media in Garage instead of a local volume, so instances are portable across servers and survive a host rebuild. Also the foundation for backups.
- **Tailscale-native networking**: internal services are only reachable over your private Tailscale network. They have no exposed ports on your server.
- **Tag-based access control**: who can talk to what is defined in a single JSON file in the Tailscale admin console, not in iptables or firewall configs.
- **A single operator script** (`bootstrap.sh`) that brings stacks up and down, provisions databases and storage, and creates admin users — so you don't have to learn each app's CLI.
- **Stalwart mail server** (SMTP, IMAP, JMAP) on the tailnet. All configuration lives in Postgres; mail blobs in Garage. One mail stack shared by all your instances, with Let's Encrypt certificates via ACME and a web admin UI.
- **Authelia SSO/OIDC** — single sign-on for the apps that support it (verified for GoToSocial, Mastodon, and PeerTube — see [What works today](#what-works-today)). One set of credentials, one login portal at `auth.yourdomain.com`. OIDC clients are registered in `authelia/configuration.yml`.
- **Lemmy** federated link aggregator and community discussion board, with full ActivityPub federation.
- **Clean teardown**: tearing a stack down removes its services from your Tailscale admin console automatically. No ghost devices to clean up.
- **One `.env` file** controls the whole stack. Hostnames, passwords, domains, SMTP, storage keys — all in one place.

## What works today

Not every app is at the same level of polish. This stack ships templates for more apps than have been verified end-to-end — so here's the honest scorecard, to save you a wasted afternoon.

> **Legend** — ✅ **works** (wired and verified end-to-end) · 🟡 **kinda works** (usable, but read the caveat) · 🚧 **you're on your own** (template/stub, unverified — expect to debug) · ✗ **not available**

| App | Kind | Media → Garage (S3) | SSO (Authelia OIDC) | Status |
|-----|------|:-------------------:|:-------------------:|--------|
| **GoToSocial** | microblog | ✅ | ✅ | ✅ Full boat |
| **Mastodon** | microblog | ✅ | ✅ | ✅ Full boat |
| **Pixelfed** | photos | ✅ | ✗ ¹ | 🟡 No SSO |
| **Lemmy** | link aggregator | ✅ | ✗ ² | 🟡 No SSO |
| **Stalwart** | mail | ✅ | 🟡 ³ | 🟡 Token-only SSO |
| **Diaspora** | microblog | ✗ ⁴ | 🚧 | 🟡 Local media only |
| **Funkwhale** | audio | ✅ | ✗ ⁶ | 🟡 S3 only |
| **PeerTube** | video | ✅ ⁷ | ✅ ⁸ | ✅ Full boat |

¹ Pixelfed has no first-class OIDC upstream — SSO would be a custom job.
² Lemmy's OAuth/OIDC lives only on its dev branch; no stable release has it (checked through 0.19.19). S3 via pict-rs object storage works.
³ Stalwart v0.16 external OIDC is **token validation only** — a client presents an Authelia access token via `OAUTHBEARER` SASL; there is **no browser SSO** for the web-admin console. Admin/relay accounts keep password auth as break-glass.
⁴ Diaspora's S3 support is AWS-only (no custom endpoint), so it can't target Garage — media stays on a local volume.
⁶ Funkwhale has no OpenID Connect/SSO support upstream (OAuth2 provider + LDAP only) — OIDC login is a long-standing, unimplemented feature request. Media is served through the front nginx over the tailnet, so no public media host is needed.

⁷ PeerTube's S3 client has **no path-style option** (upstream [#4455](https://github.com/Chocobozzz/PeerTube/issues/4455)) — it uses virtual-host addressing (`<bucket>.endpoint`), which MagicDNS can't resolve, so the move-to-object-storage job fails with `ENOTFOUND`. Set `PEERTUBE_OBJECT_STORAGE_ENDPOINT` to Garage's Tailscale **IP** to force path-style. Verified end-to-end (move + HLS playback via the public `*-media` hosts). Under HLS-only transcoding (the 7.x default) the `streaming-playlists` bucket is the one populated; `web-videos` stays empty. The HLS player fetches segments cross-origin, so the PeerTube buckets also need a **CORS** rule (`provision-garage` sets it via `PutBucketCors`; missing CORS shows as a video that spins forever with no error) — plain image/video media on the other apps doesn't need this.

⁸ PeerTube OIDC is delegated to the `peertube-plugin-auth-openid-connect` plugin, installed + configured in the admin UI after first boot (it has no env-based OIDC). `bootstrap.sh` registers the matching Authelia client from the `PEERTUBE_OIDC_*` vars in `.env`. **Gotcha:** the plugin authenticates with `client_secret_post`, so the Authelia client sets `token_endpoint_auth_method: client_secret_post` (GoToSocial/Mastodon use the default `client_secret_basic`, hence don't need it). Verified end-to-end — login auto-provisions the PeerTube account.

Infrastructure stacks (`shared-db`, `garage`, `authelia`) are the foundation the verified apps run on and are considered working.

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
./bootstrap.sh provision-stalwart         Configure Stalwart via JMAP (auto-run by 'up stalwart')
./bootstrap.sh user-create <app> <user> <email>   Create an admin user
./bootstrap.sh backup-cron                Install the nightly pg-backup cron (interactive)
```

Stacks: `shared-db`, `garage`, `stalwart`, `authelia`, `pixelfed`, `mastodon`, `diaspora`, `funkwhale`, `gotosocial`, `peertube`, `lemmy`.

You can still `cd` into a stack directory and run `docker compose` directly — `bootstrap.sh` doesn't hide anything, it just saves steps.

## Utility stack: bring-up order

Before any app stack, bring up infrastructure services in this order — each depends on the one before it:

| # | Stack | Provides | Requires |
|---|-------|----------|---------|
| 1 | `shared-db` | Postgres + Redis for all apps | — |
| 2 | `garage` | S3 object storage; required by Stalwart, optional for media apps | — |
| 3 | `stalwart` | SMTP / IMAP / JMAP mail server | Postgres + Garage |
| 4 | `authelia` | SSO / OIDC login portal | Postgres + Redis |

App stacks (`pixelfed`, `mastodon`, `diaspora`, `funkwhale`, `gotosocial`, `peertube`, `lemmy`) only need Postgres and Redis, so they can come up any time after step 1. Steps 3 and 4 must follow step 2.

Within each stack the sidecar healthcheck enforces ordering: the app container won't start until its sidecar is on the tailnet *and* `nc` confirms each backend is reachable. Across separate compose files, the order is yours to manage — the table above is the rule.

> **Multi-server note:** `provision-db` and `provision-garage` use `docker exec` into locally-running containers and must be run on the host where `shared-db` or `garage` is running — not on a remote app host. When you run `./bootstrap.sh up <app>` on a remote host, it detects that shared-db is not local, skips auto-provisioning, and prints a reminder. Run the provision commands on the infrastructure host first, then bring up the app.

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

It's also worth reading even if you never edit it: because every grant names its source tag, destination tag, and port, **the ACL file documents every service port and inter-service relationship in the stack**. If you're ever unsure what talks to what (or on which port), `acl.example.hujson` is the single authoritative map.

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

If you want apps to store media in shared object storage instead of local volumes — or if you plan to run Stalwart (which stores mail blobs and its admin web UI assets in Garage):

```bash
./bootstrap.sh up garage
```

This brings up Garage and runs `provision-garage`, which initialises the cluster layout, creates the app buckets, and generates an access key. It prints two values:

```
GARAGE_ACCESS_KEY_ID=...
GARAGE_SECRET_ACCESS_KEY=...
```

Paste those into your `.env`. You can now opt any app into S3 storage by setting its flag (`MASTODON_S3_ENABLED=true`, `PIXELFED_ENABLE_CLOUD=true`, `PEERTUBE_OBJECT_STORAGE_ENABLED=true`) before bringing it up. See [Object storage](#object-storage-garage).

### 7. (Optional) Bring up Stalwart mail server

Stalwart handles SMTP, IMAP, and JMAP for your instances. It stores its full configuration in Postgres and mail blobs in Garage — both must be up and provisioned before starting Stalwart.

Fill in the Stalwart section of `.env` first (at minimum `STALWART_FALLBACK_ADMIN_SECRET`, the `STALWART_DB_*` credentials, and the Garage keys from step 6).

```bash
./bootstrap.sh up stalwart
```

This generates `stalwart/config/config.runtime.json` and starts the container. The sidecar healthcheck gates on Postgres (port 5432) *and* Garage (port 3900) before releasing Stalwart, so it waits rather than crash-loops if backends aren't ready yet.

After the container is running, **finish setup in the admin UI before mail will flow** — see [Stalwart: first-boot configuration](#stalwart-first-boot-configuration).

### 8. (Optional) Bring up Authelia SSO

Authelia provides single sign-on for apps that support OIDC (GoToSocial, Mastodon, Funkwhale, PeerTube). It needs Postgres and Redis.

**Generate the OIDC signing key before starting Authelia** — the container won't start without it:

```bash
openssl genrsa -out authelia/private.pem 4096
```

This file is gitignored. Keep it safe — losing it invalidates all active sessions.

```bash
./bootstrap.sh up authelia
```

`bootstrap.sh` generates `authelia/configuration.runtime.yml` from your `.env` — including the pbkdf2 client-secret hashes for every templated OIDC client (GoToSocial, Mastodon, PeerTube; an unset `*_OIDC_CLIENT_SECRET` renders a throwaway hash so the client stays a valid-but-unused registration) — verifies `private.pem` exists, and creates an empty `authelia/users.yml` placeholder if none is present. See [Authelia: first-boot configuration](#authelia-first-boot-configuration) to add users and register OIDC clients.

### 9. Bring up each app stack

For each app you want to run:

```bash
./bootstrap.sh up pixelfed   # or mastodon, funkwhale, gotosocial, peertube, diaspora, lemmy
```

`up` provisions the app's database automatically (idempotent — works on a fresh or long-running Postgres). Then check the admin console again — the app's web tier (and any workers, streaming services, etc.) should appear as Tailscale devices.

**Lemmy**: has no admin CLI. The first visit to your Lemmy domain walks you through creating the admin account in the browser.

### 10. Create your admin user

**Configure SMTP first** (see [Email (SMTP)](#email-smtp)) — several apps have no password-reset CLI, so a working relay is your only recovery path if you forget the admin password.

```bash
./bootstrap.sh user-create mastodon alice alice@example.com
```

Generated passwords are printed once — save them. (PeerTube and GoToSocial differ slightly; `user-create` explains each as you run it.)

### 11. Configure your reverse proxy

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

Either way, your host must be on the tailnet **and tagged `tag:reverse-proxy`** so the ACL lets it reach the app web tiers. The hostname `pixelfed.your-tailnet.ts.net` resolves because Tailscale is installed and running on the host; if it doesn't resolve, run `tailscale up` on the host and make sure MagicDNS is enabled in your admin console under **DNS**. (Each app listens on its own internal port — Pixelfed/Funkwhale/Lemmy on 80, Mastodon on 3000, GoToSocial on 8080, PeerTube on 9000, Authelia on 9091, Stalwart admin/JMAP on 8080; the reference configs have the right port per app. Note: Stalwart's mail ports — SMTP 25/465/587 and IMAP 143/993 — are served by the L4 edge in `stalwart/caddy/`, not by this reverse proxy.)

Reload your reverse proxy and visit your domain. You should see the app.

## Object storage (Garage)

[Garage](https://garagehq.deuxfleurs.fr) is a lightweight, S3-compatible, distributed object store. It runs as its own stack (`garage/`) behind a Tailscale sidecar, just like the database.

**Why use it.** Local Docker volumes don't travel. The moment you move an instance to another server, or put it behind a load balancer, locally-stored media is stranded. Postgres already travels with the tailnet; Garage does the same for uploads. It's also the natural target for backups.

**How it's wired.** Each media app has an S3 opt-in block in its `.env` section, off by default. Flip the flag and the app reads/writes objects in Garage over the tailnet instead of a local volume:

| App | Enable with |
|-----|-------------|
| Mastodon | `MASTODON_S3_ENABLED=true` |
| Pixelfed | `PIXELFED_ENABLE_CLOUD=true` |
| PeerTube | `PEERTUBE_OBJECT_STORAGE_ENABLED=true` |

All three share the one `GARAGE_ACCESS_KEY_ID` / `GARAGE_SECRET_ACCESS_KEY` pair from `provision-garage`. Buckets are created for you (`mastodon-media`, `pixelfed-media`, `peertube-web-videos`, `peertube-streaming-playlists`, `funkwhale-music`, plus `pg-backups` for database dumps).

**Serving media to the public — you need a media host.** Enabling S3 changes where an app *stores* media, not how browsers *fetch* it. With cloud storage on, apps embed object URLs that point at Garage's tailnet address — specifically its **S3 API port `3900`, which only answers *signed* requests** (an anonymous browser GET gets `403 "does not support anonymous access"`). Public clients can neither reach the tailnet nor sign requests, so media silently fails to load even though uploads succeed. The fix is a small public reverse-proxy vhost that forwards to Garage's **web endpoint (`3902`)** and **rewrites the `Host` header to the bucket's web vhost** (`<bucket>.web.garage.local`) — and must *not* rewrite the path. The ready-to-uncomment config lives **next to each app's web proxy** — a commented media block at the bottom of `nginx/sites-available/<app>.conf`, and the matching block in `caddy/Caddyfile`. Then point each app at its media domain:

| App | Public-media var | Notes |
|-----|------------------|-------|
| Pixelfed | `PIXELFED_S3_URL=https://media.example.com` | full URL, with scheme |
| Mastodon | `MASTODON_S3_ALIAS_HOST=mastodon-media.example.com` | host only, no scheme |
| GoToSocial | `GOTOSOCIAL_S3_REDIRECT_URL=https://gts-media.example.com` | requires `GOTOSOCIAL_S3_PROXY=false` |

Each media domain maps to **exactly one bucket**, so give every app its **own** hostname (its own public DNS record + TLS cert). PeerTube is the exception — it builds public object URLs from its own `PEERTUBE_OBJECT_STORAGE_*` settings; see its `.env` block. Skip this step and you get a working upload but broken images: wrong port (3900 instead of 3902), no proxy, and a lost afternoon tracing it.

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
- **Lemmy**: the SMTP block in `lemmy/lemmy.hjson` is commented out by default. Uncomment it and fill in the relay details, then run `./bootstrap.sh up lemmy` — it regenerates `lemmy.runtime.hjson` and restarts the stack.
- **Authelia**: SMTP is configured via env vars in `authelia/docker-compose.yml`. The notifier block is commented out to avoid startup failures when no relay is configured. Uncomment `AUTHELIA_NOTIFIER_SMTP_*` once you have a relay, then restart with `./bootstrap.sh up authelia`.

Port 587 (STARTTLS) is the default throughout. For an implicit-TLS relay on
port 465, set `SMTP_PORT=465` and flip the per-app TLS switch where one
exists (e.g. `PEERTUBE_SMTP_TLS=true`, `PIXELFED_MAIL_ENCRYPTION=ssl`).

## Stalwart: first-boot configuration

After `./bootstrap.sh up stalwart` the container is running, but mail will not flow until you finish setup in the admin UI.

### Log in

Visit `https://mail.yourdomain.com` (your `STALWART_DOMAIN`) and log in with the fallback admin credentials:
- **Username:** `admin`
- **Password:** your `STALWART_FALLBACK_ADMIN_SECRET` from `.env`

### Configure TLS (ACME)

In **Server → TLS → ACME providers**, add a DNS-01 ACME provider. Stalwart handles its own certificate acquisition for mail ports — Caddy does not issue certs for SMTP/IMAP hostnames. DNS-01 is required because HTTP-01 cannot validate a mail hostname that must accept connections on non-HTTP ports.

### Configure PROXY protocol

The L4 edge (`stalwart/caddy/`) sends PROXY protocol v2 headers on mail ports so Stalwart sees real client IPs rather than the tailnet hop address. In **Server → Network**, enable PROXY protocol on each mail listener (SMTP, IMAP, LMTP) and set the trusted CIDR to `100.64.0.0/10` (Tailscale CGNAT). Do **not** enable PROXY on the JMAP/admin port (8080) — the L7 Caddy forwards that without PROXY headers.

### Configure storage (S3 / Garage)

In **Settings → Store**, add a blob store pointing at your Garage instance:
- Endpoint: `http://<GARAGE_MAGIC_NAME>.<TS_TAILNET>:3900`
- Access key / secret: your Garage keys from `.env`
- Bucket: `stalwart-mail`

### Deploy the L4 edge

Public mail ports (25, 465, 587, 143, 993) are served by a Caddy L4 instance in `stalwart/caddy/`, separate from the L7 Caddy. Bring it up on your mail host:

```bash
cd stalwart/caddy
docker compose up -d
```

> **`:443` collision**: if this host also runs your L7 Caddy reverse proxy, the L4 edge takes the public `:443` listener for MTA-STS/autoconfig/autodiscover SNI routing. Move L7 Caddy off `:443` by adding `https_port 8443` to its global options block — the L4 edge forwards unmatched `:443` traffic to `127.0.0.1:8443` automatically. See the comment block in `caddy/Caddyfile` for the exact change.

> **Multi-server note:** if Stalwart runs on a dedicated host separate from your L7 reverse proxy, the L4 edge runs on that host and connects to Stalwart via the loopback — no tailnet hops for SMTP traffic.

> **nginx instead of Caddy?** If you'd rather not run a second Caddy and already operate nginx, `nginx/sites-available/stalwart-mail.conf` is a feature-for-feature `stream {}` translation (raw mail-port pass-through + PROXY protocol + `ssl_preread` SNI fan-out on `:443`). It is **untested** — the Caddy edge is the known-good path. The one functional difference: nginx emits PROXY protocol v1, Caddy v2; Stalwart auto-detects either.

### Add DNS records

At minimum you'll need:
- `MX` record for your mail domain pointing to your Stalwart hostname
- `A` / `AAAA` for the Stalwart hostname
- `SPF` TXT record (`v=spf1 mx -all` as a starting point)
- `DKIM` TXT record — generated in Stalwart's admin UI under **Authentication → DKIM** after TLS is configured
- `DMARC` TXT record
- `_mta-sts` and `_smtp._tls` TXT records (Stalwart auto-serves `/.well-known/mta-sts.txt` once TLS is up)

---

## Authelia: first-boot configuration

After `openssl genrsa -out authelia/private.pem 4096` and `./bootstrap.sh up authelia`:

### Create your first user

```bash
docker exec federated-authelia-authelia-1 \
  authelia crypto hash generate argon2 --password 'your-password'
```

Copy the hash output. Create `authelia/users.yml`:

```yaml
users:
  alice:
    displayname: Alice
    password: "$argon2id$v=19$m=65536,..."   # paste hash here
    email: alice@yourdomain.com
    groups: [admins]
```

Restart Authelia so it picks up the new user:

```bash
./bootstrap.sh down authelia && ./bootstrap.sh up authelia
```

### Register OIDC clients

Edit `authelia/configuration.yml` and uncomment the client blocks for the apps you want to connect. Each client needs:
- `client_id` — a stable identifier (e.g. `gotosocial`)
- `client_secret` — generate with `openssl rand -hex 32`, then hash with `authelia crypto hash generate`
- `redirect_uris` — the exact callback URL the app expects (documented in each app's OIDC setup guide)

Run `./bootstrap.sh up authelia` after editing — it regenerates `configuration.runtime.yml`. If the container was already running, follow up with `docker compose restart authelia` (from `authelia/`): Authelia only reads the mounted config at startup, and `up` on a running stack won't recreate the container.

### Point apps at Authelia

OIDC discovery endpoint: `https://auth.yourdomain.com/.well-known/openid-configuration`

Each app has its own OIDC configuration location:
- **GoToSocial**: `GTS_OIDC_*` env vars in `.env`, then restart the stack
- **Mastodon**: **Admin → Settings** in the Mastodon web UI (or `OIDC_ENABLED=true` in `.env`)
- **Funkwhale**: `SOCIAL_AUTH_*` env vars
- **PeerTube**: install the `peertube-plugin-auth-openid-connect` plugin, then **Admin → Plugins → auth-openid-connect → Settings** (Discover URL = the `.well-known` URL above, client id/secret from `PEERTUBE_OIDC_*`). The Authelia client must use `token_endpoint_auth_method: client_secret_post` — the bootstrap-rendered client already does.

---

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

### Restarting a stack

```bash
./bootstrap.sh restart shared-db
```

**Do not run `docker compose restart` on a whole stack (or on a sidecar).** Every data service runs with `network_mode: "service:ts-<role>"` and borrows its Tailscale sidecar's network namespace. `docker compose restart` ignores `depends_on` ordering, so it races the data container against the sidecar recreating that namespace — the data container fails to join it, exits **128**, and because that's a *start* failure, `restart: unless-stopped` never revives it. You're left with a dead database behind a still-healthy-looking sidecar (an outage that hides from a casual `docker ps`). `bootstrap.sh restart` does `down` then an ordered `up` (sidecar healthy → then the data container), reusing all the normal provisioning. Bouncing a single app service — `docker compose restart <appservice>`, sidecar left running — is fine; it's only the whole-stack/sidecar restart that bites.

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

Garage gives you a place to put backups that isn't the same disk as your data. The `pg-backups` bucket is created for exactly this. The overall strategy:

- **Database**: `backup/pg-backup.sh` on a cron (see below). This is the one piece worth automating — everything else can be rebuilt.
- **Media**: already in Garage if you've opted apps into S3 storage; replicate it to a second node or an external bucket for off-site safety.
- **Redis**: no backup needed — every app in this stack treats it as a cache/queue, not a source of truth.
- **`.env`**: the only thing that must live outside Garage. Keep a copy in a password manager or encrypted off-site store — it holds every secret, and recovery starts here. `bootstrap.sh` keeps the on-disk copy at `chmod 600`; leave it in place — Compose interpolates `${VAR}` from it on every `up`, so the stack can't start (or recreate a container after a reboot) without it.
- **Tailscale ACL JSON**: export it from the admin console.

> **Validated (2026-07-11):** the nightly cron has run against a live stack for two weeks, and a production dump pulled back from Garage restored cleanly into a throwaway `postgres:16-alpine` cluster — every database and role replayed, app roles authenticate with their `.env` passwords, and the only `psql` error was the expected `role "postgres" already exists`. Still do the manual first run below on a new deployment. Known failure mode: if the Garage endpoint is unreachable at run time the script exits non-zero without pruning anything — set `MAILTO` so those nights reach you, and check `log/pg-backup.log` if an expected object is missing.

#### What the backup script does

`backup/pg-backup.sh` runs `pg_dumpall` inside the shared-db Postgres container, gzips the stream, and uploads it straight to `s3://pg-backups/pg-<timestamp>.sql.gz` in Garage — no local temp file. It then prunes objects older than `PG_BACKUP_RETENTION_DAYS` (default 14). The upload uses a throwaway `amazon/aws-cli` container pointed at the Garage S3 endpoint over the tailnet, so there's nothing extra to install on the host.

**Prerequisites:** run it on the host where `shared-db` lives (it uses `docker exec`), with Garage up, `provision-garage` already run, and `GARAGE_ACCESS_KEY_ID` / `GARAGE_SECRET_ACCESS_KEY` filled into `.env`. On a multi-server setup, that means the shared-db host — and it needs an ACL grant to reach `tag:garage:3900` (the admin-owned host already has this; a dedicated backup host needs a grant added to `acl.example.hujson`).

#### Set it up (cron)

Test a run by hand first:

```bash
./backup/pg-backup.sh
```

You should see it dump, upload, and report the key. Confirm the object exists:

```bash
./backup/pg-restore.sh --list      # lists what's in the pg-backups bucket
```

Then schedule it. The easiest way is the interactive helper, which installs the job in your own crontab:

```bash
./bootstrap.sh backup-cron
```

It prompts for the alert email (defaulting to `SMTP_FROM_NAME` from `.env`) and the hour to run (default 03:00), then writes a self-contained, idempotent block to your crontab — re-running it updates the block rather than duplicating it.

Prefer to do it by hand? Edit the operator's crontab (`crontab -e`) and add a nightly run at 03:00. Mind the alerting mechanics: **cron emails output, not exit codes** — if you redirect everything into the log, `MAILTO` will never fire. The `|| echo` below prints a single line only on failure, and that line is the only mail cron ever sends you:

```cron
MAILTO=you@example.com
0 3 * * * cd /path/to/federated-social && ./backup/pg-backup.sh >> log/pg-backup.log 2>&1 || echo "pg-backup FAILED — see log/pg-backup.log"
```

Use an absolute path to the repo — cron runs with a minimal environment. The script sources the repo-root `.env` itself, so no extra env setup is needed in the crontab.

Logs go to the repo-local `log/` directory (auto-created by `bootstrap.sh`, gitignored) — **no root or `/var/log` access required**, so this works for an unprivileged shell account. If you *do* have root and would rather run it as a system service, a `systemd` timer is a tidy alternative (journald logging, survives reboots).

#### Recover

List available backups and restore one (defaults to the most recent if you don't name a key):

```bash
./backup/pg-restore.sh --list                       # see what's available
./backup/pg-restore.sh                              # restore the latest
./backup/pg-restore.sh pg-20260613-030000.sql.gz   # restore a specific one
```

`pg-restore.sh` streams the chosen dump from Garage, gunzips it, and pipes it into `psql -U postgres` inside the shared-db container. Because `pg_dumpall` captures roles **and** every database, this rebuilds the whole cluster.

> **Destructive — read before running.** A `pg_dumpall` restore replays `CREATE ROLE` / `CREATE DATABASE` / `COPY` against the live cluster and can overwrite existing data and roles. The script makes you type `restore` to confirm. For a real disaster-recovery drill, restore into a throwaway Postgres first to validate the dump, rather than testing against production. Bring the affected app stacks down during a production restore so nothing is writing mid-replay.

## Troubleshooting

**App container keeps restarting with "database connection refused"**

Almost always means the database sidecar isn't healthy yet. Check `docker compose ps` in the `shared-db/` directory — both sidecars should show `(healthy)`. If they don't, check their logs. If they do, check that the app's `.env` values for `DB_HOST` match what the database stack is advertising.

**Postgres shows `Exited (128)` while its sidecar is still `Up (healthy)`**

You ran `docker compose restart` on the whole `shared-db` stack (or on the `ts-postgres` sidecar). The Postgres container shares the sidecar's network namespace and lost the race to re-join it when the sidecar was recreated — it failed to start (exit 128), and `restart: unless-stopped` doesn't retry a start failure, so it stays dead behind a healthy-looking sidecar. Symptoms downstream: every app on the shared DB errors, and `pg-backup` logs `postgres container not found`. Recover with an ordered bring-up:

```bash
./bootstrap.sh up shared-db      # or: ./bootstrap.sh restart shared-db
```

Then use `./bootstrap.sh restart <stack>` in future, never `docker compose restart` on a whole stack — see "Restarting a stack" above.

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

**Funkwhale: the library counts uploads (size/track count) but the Tracks tab is empty**

Funkwhale requires embedded metadata — at minimum an **artist** tag — on every uploaded file. Untagged files (common for DAW stem exports) are accepted and counted toward the library size, but fail import with `error_code: invalid_metadata` (`"artists.0.name": "This field is required"`) and never become playable tracks, so the **Tracks** tab stays empty. Tag the files (Artist + Title at minimum) with `kid3-cli`, `eyeD3`, or Picard and re-upload, then delete the errored uploads to clear the count. Check import state with:

```bash
docker exec <funkwhale-api> funkwhale-manage shell -c \
  "from collections import Counter; from funkwhale_api.music.models import Upload; \
   print(Counter(Upload.objects.values_list('import_status', flat=True)))"
```

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
- Access between services is controlled by Tailscale ACL tags. If you add a new app, make sure to add the right tags to the ACL or it won't be able to reach the database or storage. A side benefit: the ACL file doubles as the stack's connectivity documentation — every service port and inter-service relationship is spelled out in `acl.example.hujson`.
- The `.env` file contains all your passwords and storage keys. Don't commit it to git. The included `.gitignore` excludes it by default; don't override that.
- Your OAuth client secret is roughly as sensitive as your Tailscale account credentials for this stack. Rotate it if you suspect exposure.
- Public-facing apps are still public-facing. The tailnet protects internal service-to-service communication, not the public web interface. Standard web security applies: keep apps updated, use strong admin passwords, enable 2FA where supported.

## Design philosophy

This stack is intentionally opinionated. It assumes you'd rather have something that works out of the box with reasonable defaults than something infinitely configurable. If you need a different topology — separate hosts for database and apps, persistent (non-ephemeral) Tailscale identities, a containerized reverse proxy — this isn't the wrong starting point but you'll be modifying templates. The `CLAUDE.md` in the repo root documents the architecture in detail if you want to understand or extend it.

The goal is for operators to spend their time running a community, not running infrastructure.

## Acknowledgements

Pixelfed support in this stack is **proudly built on [Pixelfed Glitch](https://pixelfed-glitch.github.io/docs)** — a community-maintained fork of [Pixelfed](https://pixelfed.org). The pinned container images this repo deploys come from their project; the version is set via `PIXELFED_VERSION` in `.env`.

- 🌐 **Website** — <https://pixelfed-glitch.github.io/docs>
- 📖 **Documentation** — <https://pixelfed-glitch.github.io/docs/running-pixelfed/>
- 💻 **Repository** — <https://github.com/pixelfed-glitch/pixelfed>

GoToSocial support deploys the official **[GoToSocial](https://gotosocial.org)** container images (`docker.io/superseriousbusiness/gotosocial`, pinned via `GOTOSOCIAL_VERSION` in `.env`) — a lightweight, AGPLv3-licensed ActivityPub server by the GoToSocial Authors. Single sign-on is wired through Authelia OIDC.

- 🌐 **Website** — <https://gotosocial.org>
- 📖 **Documentation** — <https://docs.gotosocial.org>
- 💻 **Repository** — <https://codeberg.org/superseriousbusiness/gotosocial>

Lemmy support deploys the official **[Lemmy](https://join-lemmy.org)** images (`dessalines/lemmy` + `dessalines/lemmy-ui`, pinned via `LEMMY_VERSION` in `.env`) with [pict-rs](https://git.asonix.dog/asonix/pict-rs) for image hosting — an AGPLv3-licensed federated link aggregator by the LemmyNet authors. Images can be stored in Garage S3 via pict-rs (`LEMMY_PICTRS_STORE=object_storage`). Note: **SSO is not yet wired** — Lemmy's OAuth/OIDC support is dev-branch only and absent from current stable releases (0.19.x); it'll be added when Lemmy ships it.

- 🌐 **Website** — <https://join-lemmy.org>
- 📖 **Documentation** — <https://join-lemmy.org/docs>
- 💻 **Repository** — <https://github.com/LemmyNet/lemmy>

## License

See `LICENSE` in the repo root.

## Contributing

Issues and pull requests welcome. New app templates especially welcome — if you've gotten an app working in this pattern, contribute its directory back.
