# Caddy with the layer-4 (TCP/UDP) app so it can proxy raw mail ports.
#
# Pulls the prebuilt static binary from caddyserver.com's build server,
# NOT a local xcaddy/Go build. The compile burns ~1GB RAM; the download
# server does it for us. The base image only contributes its entrypoint
# and CA certs; we swap in the L4-enabled binary over the stock one.
#
#   docker build -t stalwart-caddy-l4 ./caddy
#
# Add more plugins by appending &p=<url-encoded module path> to CADDY_DOWNLOAD.
FROM caddy:2.11.4

ARG CADDY_DOWNLOAD="https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com%2Fmholt%2Fcaddy-l4&v=2.11.4"

RUN apk add --no-cache curl gettext \
 && curl -fsSL -o /usr/bin/caddy "$CADDY_DOWNLOAD" \
 && chmod 0755 /usr/bin/caddy
# Fail the build loudly if the L4 module isn't actually in the binary.
RUN caddy list-modules | grep -q 'layer4' || { echo 'caddy-l4 missing from binary!'; exit 1; }
