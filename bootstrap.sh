#!/usr/bin/env bash
# bootstrap.sh — unified operator interface for the federated-social stack.
#
# Wraps per-app CLIs (tootctl, php artisan, funkwhale-manage, rails runner)
# behind a single consistent interface so operators don't have to learn each
# app's tooling separately. The app CLIs remain the source of truth — this
# script just calls them with the right arguments.
#
# Usage:
#   ./bootstrap.sh up   <stack>                  bring up a stack
#   ./bootstrap.sh down <stack>                  tear down a stack
#   ./bootstrap.sh logs <stack> [service]        tail logs
#   ./bootstrap.sh ps   [stack]                  show container status
#   ./bootstrap.sh user-create <app> <username> <email>
#
# <stack>/<app>: shared-db | pixelfed | mastodon | diaspora | funkwhale
#
# user-create requires the stack to already be running (the app sidecar must
# be up for the run container to get network access). Run `up` first.
#
# Passwords are generated randomly and printed once. Save them — there is no
# recovery path from this script. Operators can change passwords via the web
# UI after first login.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
ALL_STACKS=(shared-db pixelfed mastodon diaspora funkwhale)

# Load .env so variable references in messages resolve correctly.
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
else
  echo "Warning: ${ENV_FILE} not found. Copy .env.example to .env and fill it in." >&2
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

dc() {
  local stack="$1"; shift
  docker compose \
    -f "${REPO_ROOT}/${stack}/docker-compose.yml" \
    --env-file "$ENV_FILE" \
    "$@"
}

die() { echo "Error: $*" >&2; exit 1; }

require_stack() {
  local stack="$1"
  local valid=0
  for s in "${ALL_STACKS[@]}"; do [[ "$s" == "$stack" ]] && valid=1; done
  [[ $valid -eq 1 ]] || die "Unknown stack '${stack}'. Valid: ${ALL_STACKS[*]}"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_up() {
  local stack="${1:-}"
  [[ -n "$stack" ]] || die "Usage: ./bootstrap.sh up <stack>"
  require_stack "$stack"

  # Ensure a per-stack .env symlink exists so operators can also run
  # docker compose directly inside the stack directory.
  local stack_env="${REPO_ROOT}/${stack}/.env"
  if [[ ! -e "$stack_env" ]]; then
    ln -s "../.env" "$stack_env"
    echo "[bootstrap] Created ${stack}/.env -> ../.env"
  fi

  echo "[bootstrap] Starting ${stack}..."
  dc "$stack" up -d
  echo "[bootstrap] ${stack} is up. Tip: ./bootstrap.sh logs ${stack}"
}

cmd_down() {
  local stack="${1:-}"
  [[ -n "$stack" ]] || die "Usage: ./bootstrap.sh down <stack>"
  require_stack "$stack"
  dc "$stack" down
}

cmd_logs() {
  local stack="${1:-}"
  [[ -n "$stack" ]] || die "Usage: ./bootstrap.sh logs <stack> [service]"
  require_stack "$stack"
  local service="${2:-}"
  dc "$stack" logs -f $service
}

cmd_ps() {
  local stack="${1:-}"
  if [[ -n "$stack" ]]; then
    require_stack "$stack"
    dc "$stack" ps
  else
    for s in "${ALL_STACKS[@]}"; do
      echo "=== ${s} ==="
      dc "$s" ps 2>/dev/null || true
    done
  fi
}

cmd_user_create() {
  local app="${1:-}"  username="${2:-}"  email="${3:-}"
  [[ -n "$app" && -n "$username" && -n "$email" ]] ||
    die "Usage: ./bootstrap.sh user-create <app> <username> <email>"

  # Generate a strong random password for apps that need one passed in.
  local password
  password="$(openssl rand -base64 24)"

  case "$app" in

    mastodon)
      echo "[bootstrap] Creating Mastodon admin: ${username} <${email}>"
      echo "[bootstrap] tootctl will print a generated password below. Save it."
      echo ""
      dc mastodon run --rm web \
        bundle exec tootctl accounts create "$username" \
          --email "$email" --confirmed --approve --role Owner
      dc mastodon run --rm web \
        bundle exec tootctl accounts modify "$username" --enable
      ;;

    pixelfed)
      echo "[bootstrap] Creating Pixelfed admin: ${username} <${email}>"
      echo "[bootstrap] Generated password: ${password}"
      echo "[bootstrap] Change it at: https://${PIXELFED_DOMAIN:-your-domain}/settings"
      echo ""
      dc pixelfed run --rm web \
        php artisan user:create \
          --name="$username" \
          --username="$username" \
          --email="$email" \
          --password="$password" \
          --is_admin=1 \
          --confirm_email=1
      ;;

    diaspora)
      # Diaspora has no user:create CLI. Uses rails runner via exec into the
      # running container.
      #
      # Three quirks solved here:
      # 1. bundle lives in RVM dirs (~/.rvm/gems/.../bin) only added to PATH
      #    by a login shell sourcing ~/.bash_profile. `/bin/bash -lc` does that.
      # 2. Must run as the `diaspora` user (--user) so RVM reads the right home.
      # 3. Ruby code is passed via env var (BOOTSTRAP_RUBY) so we don't embed
      #    Ruby single-quotes inside bash single-quotes inside a shell command.
      local ruby_code
      read -r -d '' ruby_code << 'RUBY' || true
u = User.build(
  username: ENV["BOOTSTRAP_USERNAME"],
  email:    ENV["BOOTSTRAP_EMAIL"],
  password: ENV["BOOTSTRAP_PASSWORD"],
  password_confirmation: ENV["BOOTSTRAP_PASSWORD"]
)
u.getting_started = false
u.save! or raise u.errors.full_messages.join(", ")
u.person.profile = Profile.new(first_name: ENV["BOOTSTRAP_USERNAME"])
u.person.save!
Role.add_admin(u.person)
puts "Created: " + u.username + " <" + u.email + ">"
RUBY
      echo "[bootstrap] Creating Diaspora admin: ${username} <${email}>"
      echo "[bootstrap] Generated password: ${password}"
      echo "[bootstrap] Change it at: ${DIASPORA_URL:-https://your-diaspora-domain/}profile/edit"
      echo ""
      BOOTSTRAP_USERNAME="$username" \
      BOOTSTRAP_EMAIL="$email" \
      BOOTSTRAP_PASSWORD="$password" \
      BOOTSTRAP_RUBY="$ruby_code" \
      dc diaspora exec \
        --user diaspora \
        -e BOOTSTRAP_USERNAME \
        -e BOOTSTRAP_EMAIL \
        -e BOOTSTRAP_PASSWORD \
        -e BOOTSTRAP_RUBY \
        diaspora \
        /bin/bash -lc 'cd /home/diaspora/diaspora && bundle exec rails runner "$BOOTSTRAP_RUBY"'
      ;;

    funkwhale)
      echo "[bootstrap] Creating Funkwhale admin: ${username} <${email}>"
      echo "[bootstrap] Generated password: ${password}"
      echo "[bootstrap] Change it at: https://${FUNKWHALE_DOMAIN:-your-domain}/settings"
      echo ""
      dc funkwhale run --rm api \
        funkwhale-manage fw users create \
          --superuser \
          --username "$username" \
          --email "$email" \
          --password "$password"
      ;;

    *)
      die "Unknown app '${app}'. Valid: mastodon pixelfed diaspora funkwhale"
      ;;
  esac
}

usage() {
  cat <<EOF
Usage: ./bootstrap.sh <command> [args]

  up   <stack>                   Bring up a stack
  down <stack>                   Tear down a stack
  logs <stack> [service]         Tail logs (Ctrl-C to stop)
  ps   [stack]                   Show container status for one or all stacks
  user-create <app> <user> <email>   Create an admin user

Stacks: ${ALL_STACKS[*]}

Examples:
  ./bootstrap.sh up shared-db
  ./bootstrap.sh up mastodon
  ./bootstrap.sh user-create mastodon alice alice@example.com
  ./bootstrap.sh user-create funkwhale alice alice@example.com
  ./bootstrap.sh ps
  ./bootstrap.sh logs mastodon web

Note: user-create requires the stack to be running first (./bootstrap.sh up <app>).
EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

command="${1:-help}"
shift || true

case "$command" in
  up)           cmd_up "$@" ;;
  down)         cmd_down "$@" ;;
  logs)         cmd_logs "$@" ;;
  ps)           cmd_ps "$@" ;;
  user-create)  cmd_user_create "$@" ;;
  help|--help|-h) usage ;;
  *) echo "Unknown command: ${command}"; echo ""; usage; exit 1 ;;
esac
