# stalwart/caddy — layer-4 mail proxy

A Caddy build with `caddy-l4` that pipes the public mail ports to the Stalwart
sidecar over the tailnet. Pure TCP pass-through with PROXY protocol v2 —
Stalwart terminates all TLS itself. Runs on any host with a public IP that
is on the tailnet and tagged `tag:reverse-proxy`; does not need to share a
host with the mailbox.

## Why layer 4 and not a normal Caddy vhost

Web apps reverse-proxy at layer 7 (route by Host/SNI, Caddy terminates TLS).
Mail can't: port 25 has no SNI (STARTTLS comes after connect), and you need
one global `:25` listener. So the edge is a dumb L4 pipe and Stalwart owns
the TLS.

## Build & run

```bash
docker compose up -d --build
```

The Dockerfile pulls the prebuilt L4-enabled binary from `caddyserver.com/api/download`,
avoiding the ~1GB-RAM local `xcaddy` build. The build fails loudly if
`caddy-l4` is missing from the downloaded binary.

## Configuration

`caddy.json` is a template containing `$STALWART_MAGIC_NAME`, `$STALWART_DOMAIN`,
and `$TS_TAILNET` placeholders. The compose `command` runs `envsubst` on the
template at startup and passes the result to Caddy — no hardcoded MagicDNS
names in the committed file. Set the three variables in `docker-compose.yml`'s
`environment` block (they read from the root `.env`).

## The :443 SNI fan-out

Stalwart publishes DNS names for MTA-STS, autoconfig, and autodiscover that
point at this edge box's public IP. Those names must be served over `:443`,
which collides with any other web server on the same box.

The fix: the `web` server in `caddy.json` owns `:443` and fans out by SNI:

- `mta-sts.`, `autoconfig.`, `autodiscover.<STALWART_DOMAIN>` → `stalwart:443`
  (TLS pass-through; Stalwart terminates with its wildcard cert — no PROXY
  protocol on `:443`, unlike the mail ports).
- All other SNI → `127.0.0.1:8443`, the box's existing web Caddy.

For that fallback to work, move the web Caddy's HTTPS listener off `:443`:

```caddyfile
{
    https_port 8443
}
your-website.example { reverse_proxy … }
```

A mail-only edge (no other web vhosts on the box) can remove the `web` server
block from `caddy.json` entirely.

## Prerequisites

- Host joined to tailnet, tagged `tag:reverse-proxy`.
- Public firewall opens ports 25, 465, 587, 143, 993 (plus 443 if using the
  SNI fan-out).
- Nothing else bound to those ports on the host.
- Tailscale ACL grants `tag:reverse-proxy → tag:stalwart` on all mail ports
  plus `tcp:443` and `tcp:8080`. See `../../acl.example.hujson`.
