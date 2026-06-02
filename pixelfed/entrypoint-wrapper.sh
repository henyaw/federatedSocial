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
#
# NOTE: variables expanded in the heredoc below must not contain $, \, `,
# or ! characters — those are interpreted by the shell. Passwords generated
# with openssl rand -hex 32 or -base64 32 are safe; arbitrary passphrases
# may not be.

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
APP_NAME="${APP_NAME:-Pixelfed}"
APP_ENV=production
APP_DEBUG=false
APP_URL=https://${APP_DOMAIN}
APP_DOMAIN=${APP_DOMAIN}
ADMIN_DOMAIN=${ADMIN_DOMAIN:-${APP_DOMAIN}}
SESSION_DOMAIN=${APP_DOMAIN}
APP_KEY=${APP_KEY}
APP_TIMEZONE=${APP_TIMEZONE:-UTC}
APP_LOCALE=${APP_LOCALE:-en}
APP_FALLBACK_LOCALE=${APP_FALLBACK_LOCALE:-en}

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

# Instance identity
INSTANCE_DESCRIPTION="${INSTANCE_DESCRIPTION:-}"
INSTANCE_CONTACT_EMAIL=${INSTANCE_CONTACT_EMAIL:-admin@${APP_DOMAIN}}
INSTANCE_CONTACT_FORM=${INSTANCE_CONTACT_FORM:-false}
TRUST_PROXIES=${TRUST_PROXIES:-100.64.0.0/10}

# Registration
OPEN_REGISTRATION=${OPEN_REGISTRATION:-false}
ENFORCE_EMAIL_VERIFICATION=${ENFORCE_EMAIL_VERIFICATION:-false}
INSTANCE_CUR_REG=${INSTANCE_CUR_REG:-false}

# Federation
ACTIVITY_PUB=${ACTIVITY_PUB:-true}
AP_REMOTE_FOLLOW=${AP_REMOTE_FOLLOW:-true}
AP_SHAREDINBOX=${AP_SHAREDINBOX:-true}
AP_INBOX=${AP_INBOX:-true}
AP_OUTBOX=${AP_OUTBOX:-true}
ATOM_FEEDS=${ATOM_FEEDS:-true}
NODEINFO=${NODEINFO:-true}
WEBFINGER=${WEBFINGER:-true}

# Moderation
INSTANCE_REPORTS_EMAIL_ENABLED=${INSTANCE_REPORTS_EMAIL_ENABLED:-false}
INSTANCE_REPORTS_EMAIL_ADDRESSES=${INSTANCE_REPORTS_EMAIL_ADDRESSES:-}
INSTANCE_REPORTS_EMAIL_AUTOSPAM=${INSTANCE_REPORTS_EMAIL_AUTOSPAM:-false}

# Content
STORIES_ENABLED=${STORIES_ENABLED:-false}
PF_HIDE_NSFW_ON_PUBLIC_FEEDS=${PF_HIDE_NSFW_ON_PUBLIC_FEEDS:-false}

# Email
MAIL_DRIVER=${MAIL_DRIVER:-log}
MAIL_HOST=${MAIL_HOST:-}
MAIL_PORT=${MAIL_PORT:-587}
MAIL_USERNAME=${MAIL_USERNAME:-}
MAIL_PASSWORD=${MAIL_PASSWORD:-}
MAIL_ENCRYPTION=${MAIL_ENCRYPTION:-tls}
MAIL_FROM_ADDRESS=${MAIL_FROM_ADDRESS:-noreply@${APP_DOMAIN}}
MAIL_FROM_NAME="${MAIL_FROM_NAME:-Pixelfed}"

# Object storage (S3)
PF_ENABLE_CLOUD=${PF_ENABLE_CLOUD:-false}
FILESYSTEM_CLOUD=${FILESYSTEM_CLOUD:-s3}
PF_LOCAL_AVATAR_TO_CLOUD=${PF_LOCAL_AVATAR_TO_CLOUD:-false}
MEDIA_DELETE_LOCAL_AFTER_CLOUD=${MEDIA_DELETE_LOCAL_AFTER_CLOUD:-false}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-}
AWS_BUCKET=${AWS_BUCKET:-}
AWS_ENDPOINT=${AWS_ENDPOINT:-}
AWS_USE_PATH_STYLE_ENDPOINT=${AWS_USE_PATH_STYLE_ENDPOINT:-false}
AWS_URL=${AWS_URL:-}

# Logging
LOG_CHANNEL=stderr
EOF

exec /docker/entrypoint.sh "$@"
