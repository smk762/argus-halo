#!/usr/bin/env bash
#
# Build "the tape": a single tape.tar.zst holding the recorded pipeline run that
# core restores on first boot. Run this locally, against the stores the real
# pipeline populated (README > The tape, step 1). Invoked via `make tape`.
#
# Archive layout -- the contract this script SHARES with the restore side
# (modules/core/cloud-init.yaml.tftpl > restore-tape.sh). Change one, change both.
#
#     MANIFEST                      what's inside + counts, for eyeballing
#     lineage.sql                   pg_dump of the lineage DAG (schema + data)
#     qdrant/<collection>.snapshot  one Qdrant snapshot per collection
#     blobs/...                     a mirror of the S3/MinIO bucket's objects
#
# Collections are discovered from the live Qdrant, not hardcoded: cortex's
# canonical ones are image_embeddings / tagset_embeddings, but callers may use
# others (argus-cortex/store/vector.py), so whatever is there is what we capture.
#
# Source stores default to a local dev suite and honour the CORTEX_* env (a
# sourced .env just works). Override any of them:
#
#     SRC_PG_URL         postgresql://argus:argus@localhost:5432/argus
#     SRC_QDRANT_URL     http://localhost:6333
#     SRC_S3_ENDPOINT    http://localhost:9000
#     SRC_S3_ACCESS_KEY  minioadmin
#     SRC_S3_SECRET_KEY  minioadmin
#     SRC_S3_BUCKET      argus-tape
#     OUT                ./tape.tar.zst
#
# Upload to R2 is opt-in: set the R2_* block and the archive is copied to the
# bucket and a presigned URL is printed for the tape_dump_url workspace variable.
# Without it, the build stops at the local archive and tells you the next step.
#
#     R2_ACCOUNT_ID          Cloudflare account id (or set R2_ENDPOINT directly)
#     R2_ACCESS_KEY_ID       R2 S3 API token
#     R2_SECRET_ACCESS_KEY   R2 S3 API token secret
#     R2_BUCKET              defaults to SRC_S3_BUCKET
#     R2_URL_EXPIRY          presign lifetime, default 168h (7d, R2's max)
#
# Deliberately dependency-light: pg_dump, curl, jq, tar+zstd on the host, and
# Docker for the MinIO client (the minio/mc image, so there's no `mc` to install).

set -euo pipefail

# --- config ------------------------------------------------------------------
SRC_PG_URL="${SRC_PG_URL:-${CORTEX_PG_URL:-postgresql://argus:argus@localhost:5432/argus}}"
SRC_QDRANT_URL="${SRC_QDRANT_URL:-${CORTEX_QDRANT_URL:-http://localhost:6333}}"
SRC_S3_ENDPOINT="${SRC_S3_ENDPOINT:-${CORTEX_S3_ENDPOINT:-http://localhost:9000}}"
SRC_S3_ACCESS_KEY="${SRC_S3_ACCESS_KEY:-${CORTEX_S3_ACCESS_KEY:-minioadmin}}"
SRC_S3_SECRET_KEY="${SRC_S3_SECRET_KEY:-${CORTEX_S3_SECRET_KEY:-minioadmin}}"
SRC_S3_BUCKET="${SRC_S3_BUCKET:-${CORTEX_S3_BUCKET:-argus-tape}}"
OUT="${OUT:-tape.tar.zst}"
MC_IMAGE="${MC_IMAGE:-minio/mc:latest}"

# Trim any trailing slash so URL joins are clean.
SRC_QDRANT_URL="${SRC_QDRANT_URL%/}"
SRC_S3_ENDPOINT="${SRC_S3_ENDPOINT%/}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need pg_dump; need curl; need jq; need tar; need zstd; need docker

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/qdrant" "$work/blobs"

# --- 1. lineage (Postgres) ---------------------------------------------------
# Plain SQL, no ownership/ACLs -- restore replays it into a fresh `argus` db that
# has no matching roles. Schema + data in one file (cortex's ensure_schema is
# CREATE TABLE IF NOT EXISTS, so replaying the DDL is harmless).
say "pg_dump lineage  <-  ${SRC_PG_URL%%\?*}"
pg_dump "$SRC_PG_URL" --no-owner --no-privileges --file "$work/lineage.sql"
# Count actual data rows, not statements: pg_dump emits a COPY block (rows
# between "COPY ... FROM stdin;" and the "\." terminator), plus any INSERTs.
pg_rows="$(awk '
  /^COPY .* FROM stdin;/ {c=1; next}
  c && /^\\\.$/          {c=0; next}
  c                      {n++}
  /^INSERT INTO /        {n++}
  END                    {print n+0}
' "$work/lineage.sql")"

# --- 2. vectors (Qdrant) -----------------------------------------------------
# For each collection: ask Qdrant to snapshot it, download the snapshot, then
# delete the server-side copy so repeated builds don't pile them up on the source.
say "qdrant snapshots  <-  $SRC_QDRANT_URL"
collections="$(curl -fsS "$SRC_QDRANT_URL/collections" | jq -r '.result.collections[].name')"
if [ -z "$collections" ]; then
  warn "no Qdrant collections found -- tape will carry no vectors"
fi
qdrant_count=0
for c in $collections; do
  snap="$(curl -fsS -X POST "$SRC_QDRANT_URL/collections/$c/snapshots" | jq -r '.result.name')"
  [ -n "$snap" ] && [ "$snap" != "null" ] || die "Qdrant returned no snapshot name for '$c'"
  curl -fsS "$SRC_QDRANT_URL/collections/$c/snapshots/$snap" -o "$work/qdrant/$c.snapshot"
  curl -fsS -X DELETE "$SRC_QDRANT_URL/collections/$c/snapshots/$snap" >/dev/null || true
  say "  captured $c"
  qdrant_count=$((qdrant_count + 1))
done

# --- 3. blobs (MinIO / S3) ---------------------------------------------------
# `mc mirror` the whole bucket into blobs/. Run mc from its own image so the host
# needs no client; --network host lets it reach a localhost endpoint. Run as the
# invoking user (with a writable config dir) so the mirrored files -- and thus the
# temp dir -- are owned by us and cleanable, not left root-owned by the container.
say "mirror blobs  <-  $SRC_S3_ENDPOINT/$SRC_S3_BUCKET"
docker run --rm --network host --user "$(id -u):$(id -g)" -e MC_CONFIG_DIR=/tmp/.mc \
  -e SRC_S3_ENDPOINT -e SRC_S3_ACCESS_KEY -e SRC_S3_SECRET_KEY -e SRC_S3_BUCKET \
  -v "$work/blobs:/blobs" --entrypoint sh "$MC_IMAGE" -ec '
    mc alias set src "$SRC_S3_ENDPOINT" "$SRC_S3_ACCESS_KEY" "$SRC_S3_SECRET_KEY" >/dev/null
    if mc ls "src/$SRC_S3_BUCKET" >/dev/null 2>&1; then
      mc mirror --overwrite "src/$SRC_S3_BUCKET" /blobs
    else
      echo "bucket $SRC_S3_BUCKET not found on source -- tape will carry no blobs" >&2
    fi
  '
blob_count="$(find "$work/blobs" -type f | wc -l | tr -d ' ')"

# --- 4. manifest + archive ---------------------------------------------------
{
  echo "# argus tape -- restored into core on first boot (README > The tape)"
  echo "lineage_rows=$pg_rows"
  echo "qdrant_collections=$qdrant_count"
  echo "blobs=$blob_count"
  echo "source_bucket=$SRC_S3_BUCKET"
} > "$work/MANIFEST"

say "packing $OUT"
tar --zstd -cf "$OUT" -C "$work" MANIFEST lineage.sql qdrant blobs
say "built $OUT ($(du -h "$OUT" | cut -f1)) -- ${pg_rows} lineage rows, ${qdrant_count} collections, ${blob_count} blobs"

# --- 5. upload to R2 (opt-in) ------------------------------------------------
R2_ENDPOINT="${R2_ENDPOINT:-}"
if [ -z "$R2_ENDPOINT" ] && [ -n "${R2_ACCOUNT_ID:-}" ]; then
  R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
fi

if [ -z "$R2_ENDPOINT" ] || [ -z "${R2_ACCESS_KEY_ID:-}" ] || [ -z "${R2_SECRET_ACCESS_KEY:-}" ]; then
  cat <<EOF

Local archive is ready but was NOT uploaded (no R2 credentials in env).
To publish and get a tape_dump_url, either upload manually to the bucket from
\`terraform output -raw tape_bucket\`, or re-run with the R2_* block set:

  R2_ACCOUNT_ID=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... make tape
EOF
  exit 0
fi

R2_BUCKET="${R2_BUCKET:-$SRC_S3_BUCKET}"
R2_URL_EXPIRY="${R2_URL_EXPIRY:-168h}"
say "upload  ->  $R2_ENDPOINT/$R2_BUCKET/tape.tar.zst"
docker run --rm \
  -e R2_ENDPOINT -e R2_ACCESS_KEY_ID -e R2_SECRET_ACCESS_KEY -e R2_BUCKET -e R2_URL_EXPIRY \
  -v "$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT"):/tape.tar.zst:ro" \
  --entrypoint sh "$MC_IMAGE" -ec '
    mc alias set r2 "$R2_ENDPOINT" "$R2_ACCESS_KEY_ID" "$R2_SECRET_ACCESS_KEY" >/dev/null
    mc mb --ignore-existing "r2/$R2_BUCKET" >/dev/null
    mc cp /tape.tar.zst "r2/$R2_BUCKET/tape.tar.zst"
    echo
    echo "Set this as the tape_dump_url workspace variable (expires in '"$R2_URL_EXPIRY"'):"
    mc share download --expire="$R2_URL_EXPIRY" "r2/$R2_BUCKET/tape.tar.zst" | sed -n "s/^Share: //p"
  '
