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

# Install the Caddyfile at a fixed path OUTSIDE the swapped stack tree,
# truncating in place: the running container's bind mount pins the inode it
# resolved at creation, so writing through the same inode (core's
# prometheus.yml render does the same) is what lets the reload below actually
# see a merged route edit. Mounting the in-tree copy would go stale on every
# argus-update swap -- the mv replaces the directory entry, not the inode.
cat Caddyfile > /opt/argus/Caddyfile

# Seed the read-only mount sources BEFORE the containers that mount them start
# (#9). A no-op when tape_dump_url is unset or the tape predates the demo/
# subtree -- though an unseeded quarry answers 503 on /ready and its data
# routes until a pool arrives: its :ro mount forbids creating a store. The
# other tiers render empty pages. A genuine seed FAILURE (e.g. an expired
# presign) is degraded, not fatal: it must not wedge the deploy itself, or a
# stale tape URL blocks every future pin/route update before `compose up`.
./restore-seed.sh \
  || echo "restore-seed.sh failed -- demo tiers stay empty; see the error above and docs/runbook.md (Seed the tape)" >&2

# The sourced env above also feeds compose's ${VAR} interpolation (DOMAIN and
# the mount targets); services themselves read config via env_file as before.
# -p pins the project name: compose derives it from the compose-file directory
# otherwise, and this file used to live in /opt/argus ("argus") but now lives
# in /opt/argus/stack -- an unpinned name would orphan every container and
# named volume (caddy_data and the origin cert!) on the first in-place update.
docker compose -p argus -f compose.yaml up -d --remove-orphans

# A Caddyfile edit does not recreate the caddy container (the file is a bind
# mount), so reload explicitly. Zero-downtime; a no-op when nothing changed.
# Retried: on first boot the admin socket can lag the container's `running`
# state by a moment. A reload still failing after that is a real error -- the
# running config would silently stay stale -- so it fails the apply, with
# caddy's stderr kept visible instead of discarded.
if docker compose -p argus -f compose.yaml ps caddy --status running -q 2>/dev/null | grep -q .; then
  reloaded=""
  for _ in 1 2 3; do
    if docker compose -p argus -f compose.yaml exec -T caddy \
      caddy reload --config /etc/caddy/Caddyfile; then
      reloaded=1
      break
    fi
    sleep 2
  done
  [ -n "$reloaded" ] || {
    echo "caddy reload FAILED -- the running config is stale; see caddy's error above" >&2
    exit 1
  }
fi
