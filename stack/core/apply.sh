#!/usr/bin/env bash
# Bring the core tier to the state this stack checkout describes. Run by
# /opt/argus/argus-update after every fetch (first boot included), so it must
# be idempotent: mkdirs are -p, the tape restore is marker-gated, and
# `compose up -d` only touches services whose definition changed.
set -euo pipefail
cd "$(dirname "$0")"

set -a
# shellcheck source=/dev/null
. /opt/argus/.env
# shellcheck source=/dev/null
. /opt/argus/deploy.env
set +a

# Scrape targets carry host private IPs, which prometheus cannot read from its
# environment -- render them in here. $-substitution only for the two names
# listed, so a future ${...} in the template cannot be swallowed silently.
envsubst '$PRIVATE_IP $DEMO_PRIVATE_IP' \
  < prometheus.yml.tpl > /opt/argus/prometheus.yml

mkdir -p /opt/argus/data/postgres /opt/argus/data/qdrant /opt/argus/data/minio

# The sourced env above also feeds compose's ${VAR} interpolation (PRIVATE_IP,
# GRAFANA_PORT); services themselves read config via env_file as before.
# -p pins the project name: compose derives it from the compose-file directory
# otherwise, and this file used to live in /opt/argus ("argus") but now lives
# in /opt/argus/stack -- an unpinned name would orphan every container and
# named volume (grafana_data!) on the first in-place update.
docker compose -p argus -f compose.yaml up -d --remove-orphans

./restore-tape.sh
