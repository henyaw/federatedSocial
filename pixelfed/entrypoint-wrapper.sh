#!/bin/sh
# Pixelfed-glitch's image expects /var/www/.env and validates it with dottie
# at startup (entrypoint.d/02-check-config.sh). This wrapper materializes the
# file from environment variables — set by docker-compose.yml's environment:
# block, themselves sourced from the prefixed keys in the repo-root .env —
# then chains to the upstream entrypoint.
#
# Why not mount the root .env directly? It contains keys for every app stack
# (PIXELFED_*, MASTODON_*, DIASPORA_*) and shared infra. Pixelfed treats it
# as Laravel config and would either pick up wrong values or warn loudly.
# Generating a clean per-app .env here keeps the root .env as the single
# operator surface without leaking other apps' settings into Pixelfed.

set -eu

# Compose's environment: block populates these. If any required value is
# missing, fail loudly here rather than letting Pixelfed produce a confusing
# error five layers deep.
: "${APP_DOMAIN:?APP_DOMAIN must be set}"
: "${APP_KEY:?APP_KEY must be set (generate with: echo \"base64:\$(openssl rand -base64 32)\")}"
: "${DB_HOST:?DB_HOST must be set}"
: "${DB_DATABASE:?DB_DATABASE must be set}"
: "${DB_USERNAME:?DB_USERNAME must be set}"
: "${DB_PASSWORD:?DB_PASSWORD must be set}"
: "${REDIS_HOST:?REDIS_HOST must be set}"

cat > /var/www/.env <<EOF
APP_NAME="Pixelfed"
APP_ENV=production
APP_DEBUG=false
APP_URL=https://${APP_DOMAIN}
APP_DOMAIN=${APP_DOMAIN}
ADMIN_DOMAIN=${APP_DOMAIN}
SESSION_DOMAIN=${APP_DOMAIN}
APP_KEY=${APP_KEY}

DB_CONNECTION=pgsql
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT:-5432}
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}

REDIS_CLIENT=phpredis
REDIS_SCHEME=tcp
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT:-6379}
REDIS_PASSWORD=null
REDIS_DATABASE=0

BROADCAST_DRIVER=redis
CACHE_DRIVER=redis
QUEUE_DRIVER=redis
SESSION_DRIVER=redis
HORIZON_PREFIX=horizon-

ENFORCE_EMAIL_VERIFICATION=${ENFORCE_EMAIL_VERIFICATION:-false}
PF_ENABLE_CLOUD=false
INSTANCE_CONTACT_EMAIL=${INSTANCE_CONTACT_EMAIL:-admin@${APP_DOMAIN}}

# Federation
ACTIVITY_PUB=true
AP_REMOTE_FOLLOW=true
AP_INBOX=true
AP_OUTBOX=true
AP_SHAREDINBOX=true

# Logging
LOG_CHANNEL=stderr
EOF

exec /docker/entrypoint.sh "$@"
