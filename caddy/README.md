# caddy — host reverse proxy

Caddy runs on the host (not in Docker) and does double duty:

- **L7 reverse proxy** (`Caddyfile` site blocks): terminates public TLS for web apps
  and proxies to their sidecar-attached containers via MagicDNS.
- **L4 mail edge** (`layer4 {}` global block): pipes raw SMTP/IMAP TCP connections
  to the Stalwart mailbox container on the tailnet using PROXY protocol v2.
  Stalwart terminates all TLS itself — the L4 edge is a pure TCP pipe.

## Why a custom binary

`apt install caddy` installs the standard Caddy package, which does not include
the `caddy-l4` module required for raw TCP proxying of mail ports. You need a
custom binary with the L4 plugin compiled in.

If you only need the L7 reverse proxy (no mail stack), the standard package is
fine and you can remove the `layer4 {}` block from the Caddyfile entirely.

## Building / downloading the custom binary

Download a prebuilt binary from Caddy's official build server (no local Go
toolchain required):

```bash
# Adjust arch if not amd64 (arm64, etc.)
CADDY_VER=2.11.4
curl -fsSL -o /tmp/caddy \
  "https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com%2Fmholt%2Fcaddy-l4&p=github.com%2Fmartinjirku%2Fcaddy-ratelimit&v=${CADDY_VER}"

# Verify it has the layer4 module
./tmp/caddy list-modules | grep layer4

# Install
sudo mv /tmp/caddy /usr/local/bin/caddy
sudo chmod 755 /usr/local/bin/caddy
sudo chown root:root /usr/local/bin/caddy
```

Add more plugins by appending `&p=<url-encoded-module-path>` to the download URL.

After installing a new binary, restart (not just reload) Caddy so systemd picks
up the new executable:

```bash
sudo systemctl restart caddy
```

Verify:

```bash
caddy version          # should show 2.11.4
caddy list-modules | grep layer4  # must show layer4.* entries
```

## Cert management

This setup uses **certbot** (not Caddy's built-in ACME) to acquire certificates.
A certbot deploy hook mirrors certs into `/etc/caddy/certs/<domain>/` after each
renewal, and Caddy's site blocks reference them explicitly:

```caddyfile
mail.example.com {
  tls /etc/caddy/certs/mail.example.com/fullchain.pem /etc/caddy/certs/mail.example.com/privkey.pem
  reverse_proxy stalwart.tailfe8c.ts.net:8080
}
```

**Stalwart's own TLS certs** are managed independently via Stalwart's admin UI
(Settings → ACME → DNS-01 provider). Stalwart stores its certificates in
Postgres and terminates TLS directly on all mail ports and its HTTPS endpoints.
The L4 Caddy edge plays no role in Stalwart's cert acquisition — it is a pure
TCP pass-through, not a TLS terminator.

## The :443 collision

If you enable the `layer4 :443 {}` block (for MTA-STS/autoconfig/autodiscover
SNI fan-out), the `layer4` server owns the public `:443` listener. Caddy's own
HTTPS server cannot also bind `:443`.

Fix: uncomment `https_port 8443` in the Caddyfile global options block. The
layer4 catch-all route forwards unmatched SNI to `127.0.0.1:8443`, so your web
vhosts continue to work. The only operator-visible change is that internal tools
(like certbot's HTTP-01 challenge redirect) must reference `:443`, not `:8443` —
but since you are using DNS-01 for certs, this does not apply.

A dedicated edge host (running the mail edge on a separate box with no web
vhosts) can omit the `:443 {}` block entirely.

## Deploying with bootstrap.sh

```bash
./bootstrap.sh up caddy
```

This:
1. Checks that `/usr/local/bin/caddy` (or `$CADDY_BIN`) exists and includes the
   `layer4` module.
2. Validates the Caddyfile (`caddy validate`).
3. Copies `caddy/Caddyfile` to `/etc/caddy/Caddyfile`.
4. Reloads the system Caddy service (`sudo systemctl reload caddy`).

Edit `caddy/Caddyfile` to replace the placeholder domains (`example.com`,
`tailfe8c.ts.net`) with your real values before the first deploy. These match
the domain and tailnet values in your `.env` file.

## Operator one-time setup

1. Install the custom binary (see above).
2. Edit `caddy/Caddyfile`:
   - Replace `admin@example.com` with your email (Let's Encrypt expiry notices).
   - Replace `tailfe8c.ts.net` with your `TS_TAILNET` value throughout.
   - Replace all `*.example.com` site labels with your real public domains.
   - In the `layer4` block: replace `stalwart.tailfe8c.ts.net` with your
     `STALWART_MAGIC_NAME.TS_TAILNET` and `mail.example.com` with your
     `STALWART_DOMAIN`.
   - If using the `:443` SNI fan-out: uncomment `https_port 8443`.
3. `./bootstrap.sh up caddy`
4. Verify Caddy is listening on mail ports: `ss -tlnp | grep -E ':25|:465|:587|:143|:993'`

## Standalone edge alternative

If your reverse-proxy host does not run a system Caddy (or you want to run the
mail L4 edge on a separate dedicated box), use the Docker-based approach instead:

```bash
cd stalwart/caddy
docker compose up -d --build
```

See `stalwart/caddy/README.md` for details. That approach uses `network_mode: host`
to bind the mail ports directly and does not conflict with a system Caddy because
it runs on a different host.
