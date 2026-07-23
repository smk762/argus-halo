#!/usr/bin/env bash
# Bring the demo tier to the state this stack checkout describes. Run by
# /opt/argus/argus-update after every fetch (first boot included), so it must
# be idempotent: mkdirs are -p, the seed restore is marker-gated, and
# `compose up -d` only touches services whose definition changed.
set -euo pipefail
cd "$(dirname "$0")"

set -a
# shellcheck source=/dev/null
. /opt/argus/.env
# shellcheck source=/dev/null
. /opt/argus/deploy.env
set +a

# Create every mount source before compose starts. Docker would create a
# missing bind source as a root-owned directory anyway, but doing it here keeps
# the seed layout explicit and matches what the tape restores into (#9).
mkdir -p /srv/argus/samples /srv/argus/quarry /srv/argus/exports \
  /srv/argus/proof/reports /srv/argus/proof/exports /srv/argus/proof/runs

# Seed the read-only mount sources BEFORE the containers that mount them start
# (#9). A no-op when tape_dump_url is unset or the tape predates the demo/
# subtree, so this never blocks boot -- though an unseeded quarry answers 503
# on /ready and its data routes until a pool arrives: its :ro mount forbids
# creating a store. The other tiers render empty pages.
./restore-seed.sh

# The sourced env above also feeds compose's ${VAR} interpolation (DOMAIN and
# the mount targets); services themselves read config via env_file as before.
# -p pins the project name: compose derives it from the compose-file directory
# otherwise, and this file used to live in /opt/argus ("argus") but now lives
# in /opt/argus/stack -- an unpinned name would orphan every container and
# named volume (caddy_data and the origin cert!) on the first in-place update.
docker compose -p argus -f compose.yaml up -d --remove-orphans

# A Caddyfile edit does not recreate the caddy container (the file is a bind
# mount), so reload explicitly. Zero-downtime; a no-op when nothing changed.
# Guarded: on first boot the exec target may still be starting.
if docker compose -p argus -f compose.yaml ps caddy --status running -q 2>/dev/null | grep -q .; then
  docker compose -p argus -f compose.yaml exec -T caddy \
    caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
    || echo "caddy reload skipped (container not ready yet)"
fi
