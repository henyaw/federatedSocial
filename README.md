# Federated Social Stack

Self-host federated social services (Pixelfed, Mastodon, Diaspora, Funkwhale, GoToSocial, PeerTube, and more) on a single server with shared database infrastructure and Tailscale-based networking. No firewall rules to write. No internal services exposed to the public internet. Edit one file, run `docker compose up -d`, done.

## What you get

- **Shared Postgres and Redis** that all your apps connect to — one database stack instead of one per app.
- **Tailscale-native networking**: internal services are only reachable over your private Tailscale network. They have no exposed ports on your server.
- **Tag-based access control**: who can talk to what is defined in a single JSON file in the Tailscale admin console, not in iptables or firewall configs.
- **Clean teardown**: `docker compose down` removes the services from your Tailscale admin console automatically. No ghost devices to clean up.
- **One `.env` file** controls the whole stack. Hostnames, passwords, domains — all in one place.

## What you need

- A Linux server (Debian or Ubuntu recommended) with Docker and Docker Compose installed.
- A [Tailscale account](https://tailscale.com/) (the free tier covers up to 100 devices, which is plenty for several apps).
- A domain name with DNS pointing at your server's public IP, for each app you plan to run publicly.
- A reverse proxy on the host (Nginx, Caddy, etc.) for terminating public HTTPS. The repo includes reference Nginx snippets.
- Basic comfort with editing config files and running shell commands. You do not need to know iptables, Docker networking internals, or Tailscale beyond the basics.

## How it works (the short version)

Every container in this stack joins your Tailscale network as its own device. Your apps reach the database and Redis through Tailscale's private network using hostnames like `pgsql-prod.your-tailnet.ts.net`. Postgres and Redis have no ports bound to your server — the only way to reach them is from inside your Tailscale network, gated by access rules you define.

Your reverse proxy on the host receives public HTTPS traffic and forwards it to the appropriate app's Tailscale hostname. Everything internal stays internal.

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
3. Under **Scopes**, enable **Devices: Core (write)**.
4. Under **Tags**, add every tag this stack uses. At minimum:
   - `tag:db-postgres`
   - `tag:db-redis`
   - Plus one or more app tags (e.g. `tag:pixelfed-web`) for each app you'll run.
   See `acl.example.hujson` for the full list.
5. Click **Generate client** and copy both the **Client ID** and **Client secret**. You'll need them in a moment.

### 3. Set your Tailscale ACL

In the admin console, go to **Access Controls** and paste the contents of `acl.example.hujson` into the editor. Adjust if you're only running some of the apps (you can delete tags you don't need). Save.

This file defines which services can talk to which. The defaults allow app web/worker tiers to reach Postgres and Redis, and allow you (as an admin) to reach everything for debugging.

### 4. Configure `.env`

Copy the example and edit it:

```bash
cp .env.example .env
$EDITOR .env
```

You'll need to fill in:

- `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_CLIENT_SECRET` from step 2.
- `TS_TAILNET` — your tailnet's domain (visible in the admin console, looks like `tailfe8c.ts.net` or `yourname.ts.net`).
- Hostnames for each service (`DB_MAGIC_NAME`, `REDIS_MAGIC_NAME`, etc.). These become the names your services appear under in Tailscale. Pick whatever you want; the defaults are fine.
- Database credentials. Generate strong passwords; you won't be typing these often.
- Per-app settings (domain names, app-specific secrets). Each app's section is commented.

### 5. Bring up the shared database stack first

```bash
cd shared-db
docker compose up -d
```

Wait about 30 seconds, then check the Tailscale admin console. You should see two new devices (the Postgres and Redis sidecars) with the hostnames you chose. If they don't appear, check the logs:

```bash
docker compose logs ts-postgres
docker compose logs ts-redis
```

The most common issue is a typo in the OAuth client secret or a missing tag in the OAuth client config.

### 6. Bring up each app stack

For each app you want to run:

```bash
cd ../pixelfed   # or mastodon, funkwhale, etc.
docker compose up -d
```

Check the admin console again — the app's web tier (and any workers, streaming services, etc.) should appear as Tailscale devices.

### 7. Configure your reverse proxy

For each public-facing app, add a server block to your host reverse proxy. Reference snippets are in `nginx/sites-available/`. The pattern is:

```nginx
server {
    listen 443 ssl http2;
    server_name social.example.com;
    # your SSL cert config here

    location / {
        proxy_pass http://pixelfed.your-tailnet.ts.net:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

The hostname `pixelfed.your-tailnet.ts.net` resolves because Tailscale is installed and running on the host. If it doesn't resolve, run `tailscale up` on the host and make sure MagicDNS is enabled in your admin console under **DNS**.

Reload your reverse proxy and visit your domain. You should see the app.

## Day-to-day operation

### Updating an app

```bash
cd pixelfed
docker compose pull
docker compose up -d
```

That's it. Compose recreates only the containers whose images changed.

### Stopping a stack

```bash
docker compose down
```

The Tailscale devices automatically disappear from your admin console. Bringing it back up registers fresh devices with the same hostnames.

### Adding a new app

Each app lives in its own directory. To add one not already included:

1. Copy an existing app directory as a starting point (use `pixelfed/` for simple apps, `mastodon/` for multi-component apps).
2. Update the image references, environment variables, and hostnames inside the new directory's `docker-compose.yml`.
3. Add the new app's environment variables to `.env`.
4. Add the new app's tag to your OAuth client's allowed tags in the admin console.
5. Add the tag to `acl.example.hujson` and update your ACL in the admin console.
6. Add a reverse proxy snippet for the new app.
7. `docker compose up -d` in the new directory.

### Backups

The repo doesn't ship a backup automation. At minimum, back up:

- The named Docker volumes for Postgres data and any app media volumes. `docker volume ls` shows you what exists; `docker run --rm -v <volume>:/data -v $(pwd):/backup alpine tar czf /backup/<volume>.tar.gz /data` is a basic approach.
- Your `.env` file (it contains all your passwords).
- Your Tailscale ACL JSON (export it from the admin console).

Set up something automated before you have data you'd miss losing.

## Troubleshooting

**App container keeps restarting with "database connection refused"**

Almost always means the database sidecar isn't healthy yet. Check `docker compose ps` in the `shared-db/` directory — both sidecars should show `(healthy)`. If they don't, check their logs. If they do, check that the app's `.env` values for `DB_HOST` match what the database stack is advertising.

**Adding an app after shared-db has already run once — its DB user doesn't exist**

The `shared-db/initdb/00-create-app-dbs.sh` script only runs on a fresh `pg-data` volume. If you add a new app's credentials to `.env` after the first boot, Postgres skips initdb and the new role/database are never created. Create them manually (substitute your password from `.env`):

```bash
docker compose -f shared-db/docker-compose.yml exec postgres \
  psql -U postgres -c "
    CREATE ROLE <app> LOGIN PASSWORD '<password>';
    CREATE DATABASE <app> OWNER <app>;
    GRANT ALL PRIVILEGES ON DATABASE <app> TO <app>;"
```

PeerTube additionally needs three extensions in its database. After creating the role and database above, run:

```bash
docker compose -f shared-db/docker-compose.yml exec postgres \
  psql -U postgres -d peertube -c "
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
    CREATE EXTENSION IF NOT EXISTS unaccent;
    CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";"
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

- Internal services (Postgres, Redis) have no exposed ports on your server. They are only reachable through your tailnet. This is enforced by container network configuration, not firewall rules — meaning a host firewall misconfiguration cannot expose them.
- Access between services is controlled by Tailscale ACL tags. If you add a new app, make sure to add the right tags to the ACL or it won't be able to reach the database.
- The `.env` file contains all your passwords. Don't commit it to git. The included `.gitignore` excludes it by default; don't override that.
- Your OAuth client secret is roughly as sensitive as your Tailscale account credentials for this stack. Rotate it if you suspect exposure.
- Public-facing apps are still public-facing. The tailnet protects internal service-to-service communication, not the public web interface. Standard web security applies: keep apps updated, use strong admin passwords, enable 2FA where supported.

## Design philosophy

This stack is intentionally opinionated. It assumes you'd rather have something that works out of the box with reasonable defaults than something infinitely configurable. If you need a different topology — separate hosts for database and apps, persistent (non-ephemeral) Tailscale identities, a containerized reverse proxy — this isn't the wrong starting point but you'll be modifying templates. The `CLAUDE.md` in the repo root documents the architecture in detail if you want to understand or extend it.

The goal is for operators to spend their time running a community, not running infrastructure.

## License

See `LICENSE` in the repo root.

## Contributing

Issues and pull requests welcome. New app templates especially welcome — if you've gotten an app working in this pattern, contribute its directory back.
