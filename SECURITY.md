# Security Assessment — the Tailscale Sidecar Model

**Scope:** the architecture of this repository — Tailscale sidecars, Docker
network namespace sharing, tailnet ACLs, and the operational tooling around
them — as of commit `b58627b` (June 2026).

**What this document is:** an honest technical assessment of what the model
protects against, what it does not, and how to harden the surrounding system
so the model delivers its full value. It is written to educate, not to sell.

**What this document is not:** a penetration test, a formal audit, or a
compliance artifact. Nobody attacked this stack to write it. It is an
architecture review by a careful reader with full access to the source.

---

## 1. The model in brief

Every service that needs network identity gets a `tailscale/tailscale`
sidecar container. The service container joins the sidecar's network
namespace:

```yaml
ts-postgres:
  image: tailscale/tailscale:v1.98.4
  environment:
    TS_AUTHKEY: ${TS_OAUTH_CLIENT_SECRET}?ephemeral=true
    TS_EXTRA_ARGS: --advertise-tags=tag:db-postgres
  cap_add: [NET_ADMIN, NET_RAW]
  devices: [/dev/net/tun:/dev/net/tun]

postgres:
  image: postgres:16-alpine
  network_mode: "service:ts-postgres"   # <-- shares the sidecar's netns
```

There are no `ports:` mappings anywhere in the repository. Access between
services is governed by a central Tailscale ACL using tags
(`tag:db-postgres`, `tag:pixelfed-web`, ...), with port-scoped grants.
Nodes are ephemeral: `docker compose down` deregisters them, and no
Tailscale state persists on disk.

Three distinct mechanisms are doing the work, and it pays to keep them
separate in your head:

1. **Namespace composition** (Docker): the app container has no network
   interfaces of its own. It cannot accidentally publish a port, join a
   bridge, or be given a host mapping without editing the compose file.
2. **WireGuard identity** (Tailscale data plane): every connection between
   nodes is mutually authenticated with per-node keys and encrypted
   end-to-end. Peers are identified cryptographically, not by IP.
3. **Central policy** (Tailscale control plane): the ACL is default-deny.
   A node tagged `tag:pixelfed-web` can reach `tag:db-postgres` on TCP/5432
   and nothing else, because a grant says so.

### 1.1 Correcting the mental model: the underlay exists

Comments in this repository describe the sidecar netns as having "only `lo`
and `tailscale0`." That is not quite true, and the difference matters for
threat modeling.

The sidecar needs outbound connectivity to reach the Tailscale coordination
server and DERP relays, so Docker attaches it to the compose project's
default bridge network. The shared namespace therefore has **three**
interfaces:

```
lo          — loopback, shared by sidecar and app
eth0        — the compose project's bridge (172.x.x.x), NATed egress
tailscale0  — the WireGuard interface (100.x.x.x)
```

Postgres binds `0.0.0.0`, so it listens on `eth0` too. Consequences:

- **From the internet or LAN: not reachable.** No DNAT rules exist (no
  `ports:`), Docker's `FORWARD` policy is DROP, and nothing routes the
  bridge subnet from outside. The "leak-resistance" claim holds against
  external parties.
- **From the host: reachable.** The host owns the bridge and can connect
  to `172.x.x.x:5432` directly, bypassing every tailnet ACL.
- **From containers on the same compose project's bridge: reachable.**
  In `shared-db`, the Redis sidecar's namespace can reach Postgres over
  the bridge without any ACL mediating it. Same-project containers are
  effectively one trust zone.

None of this breaks the design — the host was always the root of trust
(see §3.1) — but "reachable from the tailnet only" should be read as
"reachable from the tailnet only, *plus the host and same-project
containers*, which you already had to trust."

---

## 2. What the model genuinely does well

### 2.1 It eliminates the single most common self-hosting failure

The classic self-hosted-database breach is not an exotic exploit. It is
`-p 5432:5432` plus the false belief that UFW is protecting you. Docker
inserts its DNAT rules ahead of host firewall chains; a published port is
reachable from the internet *even when UFW says deny*. Thousands of
Postgres, Redis, and MongoDB instances have been ransomed exactly this way.

This stack is structurally immune, not procedurally immune: there is no
port to publish and no compose file where adding one would go unnoticed
(the repo's conventions prohibit it, and `network_mode: "service:..."`
makes `ports:` a hard Compose error). Structural immunity beats a checklist.

### 2.2 Identity-based, default-deny, port-scoped east-west traffic

Between tailnet nodes, reachability requires a grant. The web tier of one
app cannot connect to another app's web tier, cannot reach the Garage admin
port, cannot SSH anywhere. A compromised Pixelfed container's lateral
options over the tailnet are exactly: Postgres on 5432, Redis on 6379,
Garage on 3900, and whatever Authelia grant exists — with valid app-layer
credentials still required at each. That is a real reduction in blast
radius compared to a flat Docker bridge or a shared `backend` network,
where a compromised container can portscan every neighbor.

The ACL file doubles as complete, enforced documentation of every
inter-service relationship — a property flat networks never have.

### 2.3 Encryption in transit, everywhere, without app cooperation

All node-to-node traffic is WireGuard. Postgres and Redis speak plaintext
protocols, and here that is acceptable *for the transit path*: an on-path
observer (compromised switch, hostile datacenter neighbor, future
multi-host WAN link) sees only WireGuard frames. When this stack grows to
multiple hosts, nothing about transport security has to change — the model
already assumed the network was hostile.

### 2.4 Ephemeral identity limits credential residue

No `TS_STATE_DIR` volume means no long-lived node key sitting on disk to
be exfiltrated from a backup or a discarded VPS image. `docker compose
down` self-cleans the node from the tailnet. The node key exists only in
the running container's writable layer. (The OAuth client secret in `.env`
is the durable credential — see §3.3; ephemerality moves the problem, it
does not remove it.)

### 2.5 Small, deliberate touches

- Sidecar health endpoints bind `127.0.0.1:9002`, not `[::]` — they are
  not probeable across the tailnet.
- Per-app Postgres roles and databases: a stolen Pixelfed DB password does
  not read Mastodon's tables.
- Pinned image versions across the stack (see §3.6 for the caveat).
- Mail listeners trust PROXY protocol headers only from the tailnet CGNAT
  range, and only on mail ports — and the ACL further restricts who may
  even reach those ports (`tag:reverse-proxy`).

---

## 3. What the model does not do

This is the important section. Read it as "the residual risk you are
accepting," not as a list of flaws — every architecture has this section,
most just don't write it down.

### 3.1 It does not protect you from the host

The host runs the Docker daemon. Root on the host (or membership in the
`docker` group, which is root-equivalent) can enter any namespace, read
any volume — `pg-data`, the mail spool — read `.env` with every secret in
the stack, and impersonate any container. Host-level Tailscale, the
reverse proxy, and the mail edge all live there too.

The tailnet ACL is a fence between *nodes*. The host stands under the
fence, holding every key. This is not a flaw of the sidecar model — some
machine always has this power — but it means **host hardening (§5) is not
optional polish; it is where the actual security budget should go.**

### 3.2 Logical separation inside shared services is thin

Three concrete examples in this stack, in increasing order of concern:

- **Postgres** is the good case: per-app roles and databases, password
  auth. Lateral movement requires another app's credentials.
- **Garage** uses a single access key with read/write/owner on *every*
  bucket, including the private mail bucket. Any app tier that can reach
  Garage and holds the shared key can read every other app's media — and
  the mail store. Per-app keys would partition this; today it is one key.
- **Redis** has no authentication (`--protected-mode no`, gated by ACL),
  and **Redis logical database indices are a namespacing convention, not
  a security boundary** — any client may `SELECT 4`. Authelia's session
  store lives in that Redis. Therefore: a compromised container from *any*
  app with a Redis grant (Pixelfed, Mastodon, Diaspora, Funkwhale,
  PeerTube) can read and write Authelia session state — which is a
  plausible path to SSO session forgery, i.e. escalation from "one app
  compromised" to "identity provider compromised." Redis 6+ ACL users
  (per-app passwords, key-pattern and command restrictions) would close
  this; see §5.7.

### 3.3 `.env` is a tailnet admission ticket, not just a password file

`TS_OAUTH_CLIENT_SECRET` can mint new tagged nodes. Anyone holding it can
join your tailnet as `tag:pixelfed-web` from anywhere on the internet and
receive exactly the grants that tag enjoys — a straight shot to Postgres
with no further network barrier (app-layer passwords, also in the same
file, then apply). The file also contains every DB password, the Garage
key, SMTP credentials, and OIDC secrets.

Treat `.env` as the single most valuable file on the machine. Concretely:
`chmod 0600`, root-owned; never in git (enforced by `.gitignore`); only in
encrypted backups; scope the OAuth client to exactly the tags and scopes
this stack needs; rotate it if you even suspect exposure; and audit the
tailnet device list for nodes you don't recognize (§5.1).

### 3.4 You are trusting a control plane

The Tailscale coordination server distributes node public keys, tag
assignments, ACL policy, and MagicDNS answers. Payload encryption is
end-to-end (Tailscale-the-company cannot read your Postgres traffic, and
DERP relays see only ciphertext plus traffic metadata), but a compromised
or coerced control plane could add a node to your tailnet, loosen your
ACL, or repoint a MagicDNS name at an attacker's node. Your tailnet admin
*account* is part of this surface: whoever controls it controls the
policy, and `autogroup:admin → *:*` means an attacker who phishes your
Tailscale SSO login owns the stack's network layer.

Mitigations, in practical order: hardware-key MFA on the account behind
your tailnet (§5.1); device approval; Tailscale's audit log. [Tailnet
lock](https://tailscale.com/kb/1226/tailnet-lock) closes the
add-a-node hole cryptographically, but is operationally awkward with this
repo's ephemeral OAuth-minted nodes (every new node key needs signing);
evaluate it deliberately rather than assuming it drops in. The other
mitigation is Headscale — see §4.

### 3.5 Shared loopback inside the namespace

The app shares `lo` with its sidecar. Anything the sidecar serves on
loopback — the health endpoint, tailscaled's local TCP listener — is
reachable from a compromised app process. The blast radius appears small
(the state-changing LocalAPI surface expects a token, and the socket-based
API is not shared because mount namespaces are separate), but the honest
statement is: namespace sharing means the app and sidecar are one security
domain. A compromised app can also simply *use* the tailnet connectivity
of its own sidecar — that is what the ACL's port-scoping is for.

Note also that the sidecar holds `NET_ADMIN`/`NET_RAW` in the shared netns:
a compromised *sidecar* image could sniff or redirect all app traffic. You
are trusting the `tailscale/tailscale` image roughly as much as the kernel.

### 3.6 Version pinning is by tag, not digest

Pinned tags (`postgres:16-alpine`, `tailscale/tailscale:v1.98.4`) prevent
surprise upgrades, which was their goal here. They do not prevent a
registry-side re-push of the same tag with different content. Digest
pinning (`image@sha256:...`) is the stronger guarantee at the cost of
uglier bumps. For this stack's threat model, tag-pinning is a reasonable
call — but know which guarantee you hold.

### 3.7 The public surface is untouched, and it is the likely way in

Federation is the point of this stack, and federation means every app
parses hostile input from the entire fediverse: ActivityPub documents,
media files, WebFinger lookups, link previews. The reverse proxy, the mail
edge (ports 25/143/443/465/587/993 open to the world), and each app's web
UI are all standard attack surface that the tailnet does nothing about.
Statistically, the first compromise of this stack will be an
unauthenticated RCE or SSRF in one of the apps, not a WireGuard break. The
sidecar model's job is to make that first compromise *contained* — which
is exactly why §3.2's shared-service gaps deserve attention.

Two deliberate ACL broadenings worth flagging as high-value targets: the
`tag:console-web → *:*` fleet-observer grant (one compromised dashboard
reaches everything) and the standing `autogroup:admin → *:*` grant (your
laptop is part of the production trust boundary — treat it accordingly).

---

## 4. Control plane choices: Tailscale vs Headscale

[Headscale](https://github.com/juanfont/headscale) is a self-hosted,
open-source implementation of the Tailscale coordination protocol. The
sidecars in this repo work with it — the data plane (WireGuard, the
official client, MagicDNS, ACL tags) is the same. What changes is who you
trust and what you operate.

### What moves in your favor

- **Third-party trust is removed.** No external company can add nodes,
  alter policy, or observe your control-plane metadata. For some threat
  models (or jurisdictions) this is decisive.
- **The policy file lives with you** — in Headscale's config, versionable
  in your own git.

### What moves against you

- **You now run an internet-reachable auth server.** Headscale's
  compromise has exactly the same power as Tailscale Inc.'s compromise in
  §3.4 — except patching it, backing it up, TLS-ing it, and monitoring it
  is now your job. A neglected Headscale is strictly worse than hosted
  Tailscale.
- **No tailnet lock.** The cryptographic mitigation for control-plane
  compromise is unavailable; the control plane is fully trusted.
- **No OAuth clients.** This repo's `TS_OAUTH_CLIENT_SECRET` flow is a
  Tailscale-hosted feature. With Headscale you use pre-auth keys instead —
  same power, different lifecycle (explicit expiry, per-user, generated by
  your CLI).
- **Availability is yours.** Headscale down: existing nodes keep working
  (data plane is peer-to-peer), but new/restarting ephemeral sidecars
  cannot join — and this stack restarts sidecars routinely.
- **DERP:** either keep using Tailscale's public relays (ciphertext only,
  but a third party is back in the metadata path) or run your own.

### What the sidecar looks like against Headscale

```yaml
ts-postgres:
  image: tailscale/tailscale:v1.98.4
  environment:
    # Pre-auth key minted by YOUR server, e.g.:
    #   headscale preauthkeys create --user infra \
    #     --tags tag:db-postgres --ephemeral --expiration 24h
    TS_AUTHKEY: ${HEADSCALE_PREAUTH_KEY}
    TS_EXTRA_ARGS: >-
      --login-server=https://headscale.example.net
      --advertise-tags=tag:db-postgres
    TS_ACCEPT_DNS: "true"
```

The ACL translates to Headscale's policy file with largely the same HuJSON
grammar; tags and port-scoped rules carry over.

### Honest recommendation

For a single-host, single-operator deployment of this stack,
Tailscale-hosted is the pragmatic default: the control-plane risk is real
but bounded, and the operational risk of running your own auth server
poorly is at least as large. Choose Headscale when third-party control is
unacceptable *and* you will genuinely operate it with care — patched,
monitored, backed up, MFA'd. "I installed Headscale once" is not the
threat-model upgrade it feels like.

---

## 5. Hardening the host

Ordered by leverage. The first three matter more than everything after
them combined.

### 5.1 The accounts above the machine

- **Tailnet admin account:** hardware-key MFA (or the strongest second
  factor your SSO identity provider supports — the tailnet is only as
  strong as the identity provider behind it). Enable device approval so a
  leaked OAuth secret alone cannot silently add nodes. Review
  **Machines** in the admin console on a schedule; configure a
  [webhook](https://tailscale.com/kb/1213/webhooks) for `nodeCreated`
  events so a surprise node pages you.
- **VPS provider account:** MFA. Anyone with provider console access has
  disk snapshots, serial console, and reset powers — the provider account
  *is* the host.
- **Your admin laptop** holds `autogroup:admin → *:*`. Full-disk
  encryption, screen lock, patched browser. It is production.

### 5.2 `.env` custody

Covered in §3.3. Additionally: exclude it from any general-purpose backup
that isn't encrypted; if you use configuration management, template it at
deploy time rather than storing rendered copies; and after any suspected
exposure rotate in this order — Tailscale OAuth secret (and audit the
device list), then DB passwords, then the Garage key, then app secrets.

### 5.3 SSH

Key-only auth (`PasswordAuthentication no`), `PermitRootLogin no`,
a dedicated non-root user with sudo. The strongest available move is
removing SSH from the public internet entirely — bind it to the tailscale
interface or firewall it to the tailnet — *provided* you keep an
out-of-band path (provider serial console) for the day Tailscale breaks.
Locking yourself out is a bigger practical risk than SSH brute force
against key-only auth; sequence this change carefully.

### 5.4 Run a host firewall anyway

The model doesn't depend on one — that's its strength — but defense in
depth is cheap: default-deny inbound, allow 80/443 (and the mail ports if
this host is the mail edge), plus your chosen SSH path. Know the Docker
caveat: **published ports bypass UFW/firewalld INPUT rules** via Docker's
own NAT chains. This stack publishes nothing, which is why the two coexist
peacefully — the firewall guards host services, the compose model guards
containers. If you ever need to police *forwarded* container traffic
(e.g. the §1.1 bridge paths), the sanctioned hook is the `DOCKER-USER`
iptables chain — rules there survive Docker restarts and are evaluated
before Docker's own accept rules.

### 5.5 Patching cadence

`unattended-upgrades` for the OS security channel; subscribe to release
feeds for the fediverse apps (federation-facing RCEs get exploited fast);
bump the pinned image versions deliberately but *regularly* — a pin that
ages two years is a vulnerability list. The repo's convention of
validating one pinned version, then bumping, is right; the discipline is
doing it on a schedule.

### 5.6 Docker daemon hygiene

Never expose the daemon API on TCP. Treat `docker` group membership as
root. Rootless Docker is largely incompatible with this stack's kernel-mode
sidecars (`/dev/net/tun` + `NET_ADMIN`); the honest alternatives are
accepting rootful Docker with a hardened host, or switching sidecars to
`TS_USERSPACE=true` — which removes the tun/cap requirements at a real
throughput/latency cost to Postgres traffic. That trade is documented
here so it's a choice, not an accident.

### 5.7 Close the in-stack gaps (§3.2)

- **Redis:** move to Redis ACL users — per-app username/password, key
  pattern restrictions, `SELECT` confined to the app's index. (A single
  shared `requirepass` adds little here — every app would hold the same
  password; per-user ACLs are the meaningful step.) The Authelia-session
  exposure is the motivating case.
- **Garage:** create per-app keys (`garage key create pixelfed`) granted
  only their buckets; keep the mail bucket on a key only Stalwart holds.
- **Postgres:** optionally add `pg_hba.conf` rules restricting connections
  to the tailnet CGNAT range (`100.64.0.0/10`), which closes the §1.1
  bridge path to the data tier without touching iptables.

### 5.8 Observability

Persistent journald (`Storage=persistent`); `auditd` watches on `.env`
and the compose directories; rate limiting on the public edge (the
custom Caddy build already carries `caddy-ratelimit` — configure it);
periodic `tailscale status --json` snapshots make "what nodes existed
when" answerable after an incident, which ephemeral nodes otherwise
erase.

### 5.9 Backups

The repo's `pg-backup` tooling covers the database; ensure the encryption
covers *everything* leaving the host (mail spool, media volumes), that
offsite copies exist, and that you have restored one, once, on purpose.
An untested backup is a hypothesis. Remember backups contain everything
the ACL protects — a stolen backup bypasses the entire model.

---

## 6. Residual risk summary

| Threat | Mitigated by the model? | Residual / notes |
|---|---|---|
| Accidental public exposure of Postgres/Redis | **Yes — structurally** | The model's strongest property |
| LAN/on-path snooping of service traffic | **Yes** (WireGuard e2e) | DERP sees metadata only |
| Lateral movement between tailnet nodes | **Largely** (default-deny, port-scoped) | App-layer creds are the second gate |
| Compromised app container | **Contained, imperfectly** | Redis/Authelia sessions & shared Garage key are the escape hatches (§3.2, §5.7) |
| Host compromise | **No** | Host is the root of trust; §5 is the answer |
| `.env` theft | **No** | Tailnet admission + every credential (§3.3) |
| Control-plane compromise (Tailscale/Headscale) | **Partially** (payload stays encrypted) | Node injection / ACL tamper possible; MFA, device approval, §4 |
| Public web / federation exploit | **No** (out of scope by design) | The most likely initial vector (§3.7) |
| Supply chain (images) | **Partially** (tag pins) | Tags are mutable; digests are the stronger claim (§3.6) |
| Stolen backups | **No** | Encrypt them; they contain the whole model's contents |

---

## 7. Verdict

For its stated threat model — a solo operator running federated services
on one or two hosts, prioritizing "cannot accidentally expose the
database" over enterprise ceremony — the sidecar model is a genuinely good
design, and notably better than the common alternatives (published ports
behind a host firewall; one flat `backend` bridge; a VPN bolted on
afterwards). Its two best properties are structural: exposure requires
editing code, not forgetting a firewall rule; and every permitted flow is
written down in one enforced file.

Its honest limits are the ones every single-host design shares — the host
and the operator's accounts are the real perimeter — plus a short list of
in-stack gaps (shared Redis without auth, one Garage key, tag-pinning)
that are cheap to close and are enumerated above so they can be closed
deliberately or accepted knowingly.

Security is not a property this stack *has*; it is the sum of what the
model enforces (§2), what the operator hardens (§5), and what both choose
to accept (§3, §6). This document exists so those choices are made with
eyes open.

---

*Assessed and written by **Claude Fable 5** (Anthropic) — the generally
available Mythos-class model — at the maintainer's request, based on a
full read of this repository's compose files, ACL policy, bootstrap
tooling, and history. It reflects commit `b58627b`, June 2026. Treat it
as an informed architecture review by its author, an AI system: verify
load-bearing claims before relying on them, and re-review when the
architecture changes.*
