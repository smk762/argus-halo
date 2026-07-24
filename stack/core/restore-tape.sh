#!/usr/bin/env bash
# Seeds all three stores from the recorded pipeline run. Idempotent: the
# marker means a re-run won't clobber live data. Consumes the archive built by
# `make tape` (scripts/build-tape.sh) -- same layout:
#   lineage.sql, qdrant/<collection>.snapshot, blobs/...
#
# Config comes from /opt/argus/.env + /opt/argus/deploy.env (sourced below), not
# from plan-time templating -- this script ships in the fetched stack, so a
# changed tape URL or password reaches it via those files, not a host rebuild.
set -euo pipefail
# Capture an operator-supplied override BEFORE sourcing: a plain assignment in
# a sourced file overwrites the environment (set -a only marks for export, it
# gives sourced values no default-only semantics), so deploy.env's baked
# TAPE_DUMP_URL would otherwise clobber the fresh URL passed on the command line.
CLI_TAPE_URL="${TAPE_DUMP_URL:-}"
set -a
# shellcheck source=/dev/null
. /opt/argus/.env
# shellcheck source=/dev/null
. /opt/argus/deploy.env
set +a

MARKER=/opt/argus/data/.tape-restored

# deploy.env carries the URL the host was born with -- useless once an R2
# presign has expired. An operator-supplied TAPE_DUMP_URL (captured above)
# takes precedence:
#   TAPE_DUMP_URL='<fresh url>' /opt/argus/stack/restore-tape.sh
TAPE_URL="${CLI_TAPE_URL:-${TAPE_DUMP_URL:-}}"

[ -f "$MARKER" ] && { echo "tape already restored"; exit 0; }
[ -z "$TAPE_URL" ] && { echo "no tape_dump_url set, starting clean"; exit 0; }

# Bounded readiness wait: probe every 2s but give up after ~5min, so a store
# that never comes up fails the restore instead of hanging forever.
wait_for() {  # wait_for <name> <probe cmd...>
  local name="$1"; shift
  local i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -ge 150 ] && { echo "timed out waiting for $name to become ready" >&2; exit 1; }
    sleep 2
  done
}

cd /opt/argus
# Separate the failure modes instead of blaming expiry for all of them: a
# dropped transfer, a DNS failure and a 403 on a stale presign are different
# problems with different fixes. --retry rides out the transient ones;
# --remove-on-error keeps a truncated archive from sitting there looking like a
# finished download. See docs/runbook.md > Seed the tape.
rm -f tape.tar.zst
curl_rc=0
http_code="$(curl -sSL --retry 3 --retry-all-errors --retry-delay 5 \
  --remove-on-error -o tape.tar.zst -w '%{http_code}' "$TAPE_URL")" || curl_rc=$?
if [ "$curl_rc" -ne 0 ]; then
  rm -f tape.tar.zst
  echo "could not fetch the tape: curl exited $curl_rc." >&2
  echo "That is a transport failure -- DNS, TLS, or the connection dropped." >&2
  echo "It is NOT a URL problem; retry before rebuilding the tape." >&2
  exit 1
fi
case "$http_code" in
  2??) ;;
  401|403)
    rm -f tape.tar.zst
    echo "the tape URL was rejected (HTTP $http_code)." >&2
    echo "If it is an R2 presigned URL it has almost certainly EXPIRED -- R2" >&2
    echo "caps them at 7 days. Rebuild with 'make tape', then re-run here and" >&2
    echo "PASS the fresh URL -- the one in deploy.env was written at plan time" >&2
    echo "and expired with it, so a bare re-run just repeats this:" >&2
    echo "  TAPE_DUMP_URL='<new url>' /opt/argus/stack/restore-tape.sh" >&2
    echo "Also set it as the tape_dump_url workspace variable, or the NEXT" >&2
    echo "rebuild of this host repeats this failure." >&2
    exit 1 ;;
  *)
    rm -f tape.tar.zst
    echo "the tape fetch returned HTTP $http_code -- not an expiry." >&2
    echo "Check the bucket and object that tape_dump_url points at." >&2
    exit 1 ;;
esac
rm -rf /opt/argus/tape && mkdir -p /opt/argus/tape
tar --zstd -xf tape.tar.zst -C /opt/argus/tape

# --- precondition: the tape's Qdrant minor must match this host's ---
# build-tape.sh records the source version in MANIFEST because a snapshot only
# restores into a matching minor. Check it HERE, where both numbers are actually
# known: this catches a pin moved on one side only, and it fails BEFORE psql
# touches Postgres, so a rejected tape leaves the stores untouched instead of
# half-seeded. An older tape with no qdrant_version line skips the check.
wait_for qdrant curl -fsS "http://$PRIVATE_IP:6333/readyz"
tape_qdrant="$(sed -n 's/^qdrant_version=//p' /opt/argus/tape/MANIFEST 2>/dev/null || true)"
live_qdrant="$(curl -fsS "http://$PRIVATE_IP:6333/" \
  | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')" || true
if [ -n "$tape_qdrant" ] && [ -n "$live_qdrant" ] \
   && [ "$(printf '%s' "$tape_qdrant" | cut -d. -f1,2)" \
     != "$(printf '%s' "$live_qdrant" | cut -d. -f1,2)" ]; then
  echo "tape was built against Qdrant $tape_qdrant but this host runs $live_qdrant." >&2
  echo "Snapshots do not cross minor versions -- refusing to restore rather" >&2
  echo "than half-seeding the stores. Rebuild the tape against $live_qdrant, or" >&2
  echo "move the qdrant pin in stack/core/compose.yaml (build-tape.sh reads it" >&2
  echo "from there, so the two move together)." >&2
  exit 1
fi

# --- lineage (Postgres) ---
wait_for postgres pg_isready -h "$PRIVATE_IP" -U argus -q
# ON_ERROR_STOP: a failed/partial load must abort (set -e) BEFORE the marker
# is written, so a broken restore is retried, not recorded as success.
psql "postgresql://argus:$POSTGRES_PASSWORD@$PRIVATE_IP:5432/argus" \
  -v ON_ERROR_STOP=1 -f /opt/argus/tape/lineage.sql

# --- vectors (Qdrant) ---
# Each snapshot's filename is its collection name; upload recreates the
# collection from it (priority=snapshot => snapshot data wins).
for snap in /opt/argus/tape/qdrant/*.snapshot; do
  [ -e "$snap" ] || break
  col="$(basename "$snap" .snapshot)"
  echo "restoring qdrant collection $col"
  curl -fsS -X POST \
    "http://$PRIVATE_IP:6333/collections/$col/snapshots/upload?priority=snapshot" \
    -H "Content-Type:multipart/form-data" -F "snapshot=@$snap"
done

# --- blobs (MinIO) ---
# Always ensure the bucket exists (even for a blob-less tape, so the first
# cortex write doesn't hit NoSuchBucket), then mirror the archived objects
# into it via the mc image (no host client to install); --network host
# reaches the private-IP endpoint. An empty blobs/ makes the mirror a no-op.
wait_for minio curl -fsS "http://$PRIVATE_IP:9000/minio/health/ready"
echo "restoring minio blobs into $S3_BUCKET"
docker run --rm --network host -v /opt/argus/tape/blobs:/blobs:ro \
  -e PRIVATE_IP -e S3_BUCKET -e MINIO_ROOT_USER -e MINIO_ROOT_PASSWORD \
  --entrypoint sh minio/mc:RELEASE.2025-08-13T08-35-41Z -ec '
    mc alias set core "http://$PRIVATE_IP:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
    mc mb --ignore-existing "core/$S3_BUCKET" >/dev/null
    mc mirror --overwrite /blobs "core/$S3_BUCKET"
  '

touch "$MARKER"
# Reclaim the extraction scratch (a full second copy of the blobs) now that
# the stores hold the data; the marker records completion.
rm -f tape.tar.zst
rm -rf /opt/argus/tape
