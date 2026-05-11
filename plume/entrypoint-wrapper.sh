#!/bin/sh
# Plume entrypoint wrapper.
#
# `plm migration run` and `plm search init` are both idempotent and safe to
# run on every boot — but only when starting the main service. When the
# operator invokes one-off commands like `docker compose run --rm plume
# plm instance new ...`, we skip the auto-init and pass through.
#
# The check works because compose passes the resolved command as argv:
#   service startup       -> argv: ["plume"]              (from `command:`)
#   docker compose run    -> argv: ["plm", "instance", ...] (operator-supplied)

set -eu

if [ "${1:-plume}" = "plume" ]; then
  plm migration run
  # search init creates the Tantivy index on first boot. On subsequent
  # boots the directory already exists; the command's exit code differs
  # by Plume version, so we treat any non-zero as "already initialized".
  plm search init 2>/dev/null || true
fi

exec "$@"
