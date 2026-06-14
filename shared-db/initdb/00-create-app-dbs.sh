#!/usr/bin/env bash
# Create per-app Postgres users and databases on first boot.
#
# Postgres only runs files in /docker-entrypoint-initdb.d/ when its data
# directory is empty (i.e., the first time the container starts against a
# fresh `pg-data` volume). Re-running this script is therefore a non-issue
# for normal operation — the script is idempotent regardless, in case the
# volume is reused or the container is rebuilt.
#
# Adding a new app: append another create_app_db block at the bottom and
# add the corresponding *_DB_NAME / *_DB_USER / *_DB_PASSWORD env vars to
# the postgres service in docker-compose.yml.

set -euo pipefail

create_app_db() {
  local db_name="$1" db_user="$2" db_password="$3"

  if [[ -z "${db_name}" || -z "${db_user}" || -z "${db_password}" ]]; then
    echo "[initdb] skipping: empty name/user/password (not configured in .env)"
    return 0
  fi

  echo "[initdb] ensuring user '${db_user}' and database '${db_name}'"

  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname postgres <<-SQL
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${db_user}') THEN
        CREATE ROLE "${db_user}" LOGIN PASSWORD '${db_password}';
      END IF;
    END
    \$\$;

    SELECT 'CREATE DATABASE "${db_name}" OWNER "${db_user}"'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db_name}')\gexec

    GRANT ALL PRIVILEGES ON DATABASE "${db_name}" TO "${db_user}";
SQL
}

create_app_extension() {
  local db_name="$1" extension="$2"

  [[ -n "${db_name}" ]] || return 0

  echo "[initdb] ensuring extension '${extension}' in '${db_name}'"
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname "${db_name}" \
    -c "CREATE EXTENSION IF NOT EXISTS \"${extension}\";"
}

create_app_db "${PIXELFED_DB_NAME:-}" "${PIXELFED_DB_USER:-}" "${PIXELFED_DB_PASSWORD:-}"
create_app_db "${MASTODON_DB_NAME:-}" "${MASTODON_DB_USER:-}" "${MASTODON_DB_PASSWORD:-}"
create_app_db "${DIASPORA_DB_NAME:-}"   "${DIASPORA_DB_USER:-}"   "${DIASPORA_DB_PASSWORD:-}"
create_app_db "${FUNKWHALE_DB_NAME:-}" "${FUNKWHALE_DB_USER:-}" "${FUNKWHALE_DB_PASSWORD:-}"
create_app_db "${GOTOSOCIAL_DB_NAME:-}" "${GOTOSOCIAL_DB_USER:-}" "${GOTOSOCIAL_DB_PASSWORD:-}"
create_app_db "${PEERTUBE_DB_NAME:-}"   "${PEERTUBE_DB_USER:-}"   "${PEERTUBE_DB_PASSWORD:-}"

# PeerTube requires three extensions for full-text search and UUID generation.
# Extensions must be created by the superuser, after the database exists.
if [[ -n "${PEERTUBE_DB_NAME:-}" ]]; then
  create_app_extension "${PEERTUBE_DB_NAME}" "pg_trgm"
  create_app_extension "${PEERTUBE_DB_NAME}" "unaccent"
  create_app_extension "${PEERTUBE_DB_NAME}" "uuid-ossp"
fi
