#!/usr/bin/env bash
#
# Build "the tape": a single tape.tar.zst holding the recorded pipeline run that
# core restores on first boot. Run this locally, against the stores the real
# pipeline populated (README > The tape, step 1). Invoked via `make tape`.
#
# Archive layout -- the contract this script SHARES with two restore sides:
# core's (modules/core/cloud-init.yaml.tftpl > restore-tape.sh) reads the store
# dumps; the demo host's (modules/demo/cloud-init.yaml.tftpl > restore-seed.sh)
# reads only the demo/ subtree. Change the layout, change all three.
#
#     MANIFEST                      what's inside + counts, for eyeballing
#     lineage.sql                   pg_dump of the lineage DAG (schema + data)
#     qdrant/<collection>.snapshot  one Qdrant snapshot per collection
#     blobs/...                     a mirror of the S3/MinIO bucket's objects
#     demo/samples/...              curator live-mode corpus (argus-halo#14)
#     demo/quarry/...               quarry provenance pool (QUARRY_HOME)
#     demo/exports/...              curated export forge renders configs from
#     demo/proof/...                precomputed EvalReports proof replays (#9)
#
# Collections are discovered from the live Qdrant, not hardcoded: cortex's
# canonical ones are image_embeddings / tagset_embeddings, but callers may use
# others (argus-cortex/store/vector.py), so whatever is there is what we capture.
#
# Source stores default to a local dev suite and honour the CORTEX_* env. A bare
# `source .env` does NOT survive `make` (only exported vars reach a recipe), so
# point ENV_FILE at your cortex .env instead -- this script loads it with `set -a`:
#
#     ENV_FILE           dotenv to load first, e.g. ENV_FILE=../cortex/.env
#
# Override any individual value:
#
#     SRC_PG_URL         postgresql://argus:argus@localhost:5432/argus
#     SRC_QDRANT_URL     http://localhost:6333
#     SRC_S3_ENDPOINT    http://localhost:9000
#     SRC_S3_ACCESS_KEY  minioadmin
#     SRC_S3_SECRET_KEY  minioadmin
#     SRC_S3_BUCKET      argus-tape
#     OUT                ./tape.tar.zst
#
# Demo-tier seed trees (#9) are local directories, each optional -- point them at
# the pipeline's local stores to seed the gallery/forge/proof pages, or leave them
# unset and that tier renders empty (the pre-#9 behaviour; a core-only tape still
# builds). The demo host extracts these; core ignores them:
#
#     SRC_SAMPLES        curator live-mode corpus  -> demo/samples (argus-halo#14)
#     SRC_QUARRY_HOME    quarry provenance pool    -> demo/quarry  (or $QUARRY_HOME)
#     SRC_FORGE_EXPORTS  curated export + captions -> demo/exports
#     SRC_PROOF_DIR      precomputed EvalReports    -> demo/proof
#
# A Qdrant snapshot only restores into the SAME minor version, so the build
# refuses to pack a tape the demo could not restore. The minor is read from the
# qdrant image pin in modules/core/cloud-init.yaml.tftpl, so there is nothing to
# keep in sync by hand. Override only to build against a pin that is not in this
# checkout; the restore side re-checks the version regardless, from MANIFEST:
#
#     TAPE_QDRANT_MINOR  minor the restore side runs (default: read from the pin)
#
# Upload to R2 is opt-in: set the R2_* block and the archive is copied to the
# bucket and a presigned URL is printed for the tape_dump_url workspace variable.
# Without it, the build stops at the local archive and tells you the next step.
#
#     R2_ACCOUNT_ID          Cloudflare account id (or set R2_ENDPOINT directly)
#     R2_ACCESS_KEY_ID       R2 S3 API token
#     R2_SECRET_ACCESS_KEY   R2 S3 API token secret
#     R2_BUCKET              defaults to the terraform `tape_bucket` output (aborts if unreadable)
#     R2_URL_EXPIRY          presign lifetime, default 168h (7d, R2's max)
#
# Deliberately dependency-light: pg_dump, curl, jq, tar+zstd on the host, and
# Docker for the MinIO client (the minio/mc image, so there's no `mc` to install).

set -euo pipefail

# Load a dotenv first if asked (e.g. cortex's .env). `make` passes only EXPORTED
# vars to a recipe, so a bare `source .env && make tape` never reaches us; `set -a`
# re-exports everything the file defines so CORTEX_*/SRC_* resolve as documented.
if [ -n "${ENV_FILE:-}" ]; then
  [ -f "$ENV_FILE" ] || { printf 'error: ENV_FILE not found: %s\n' "$ENV_FILE" >&2; exit 1; }
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
fi

# --- config ------------------------------------------------------------------
SRC_PG_URL="${SRC_PG_URL:-${CORTEX_PG_URL:-postgresql://argus:argus@localhost:5432/argus}}"
SRC_QDRANT_URL="${SRC_QDRANT_URL:-${CORTEX_QDRANT_URL:-http://localhost:6333}}"
SRC_S3_ENDPOINT="${SRC_S3_ENDPOINT:-${CORTEX_S3_ENDPOINT:-http://localhost:9000}}"
SRC_S3_ACCESS_KEY="${SRC_S3_ACCESS_KEY:-${CORTEX_S3_ACCESS_KEY:-minioadmin}}"
SRC_S3_SECRET_KEY="${SRC_S3_SECRET_KEY:-${CORTEX_S3_SECRET_KEY:-minioadmin}}"
SRC_S3_BUCKET="${SRC_S3_BUCKET:-${CORTEX_S3_BUCKET:-argus-tape}}"
OUT="${OUT:-tape.tar.zst}"
MC_IMAGE="${MC_IMAGE:-minio/mc:RELEASE.2025-08-13T08-35-41Z}"

# Demo-tier seed sources (#9). Each optional -- unset means that tier ships empty.
SRC_SAMPLES="${SRC_SAMPLES:-}"
SRC_QUARRY_HOME="${SRC_QUARRY_HOME:-${QUARRY_HOME:-}}"
SRC_FORGE_EXPORTS="${SRC_FORGE_EXPORTS:-}"
SRC_PROOF_DIR="${SRC_PROOF_DIR:-}"

# Trim any trailing slash so URL joins are clean.
SRC_QDRANT_URL="${SRC_QDRANT_URL%/}"
SRC_S3_ENDPOINT="${SRC_S3_ENDPOINT%/}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need pg_dump; need curl; need jq; need tar; need zstd; need docker

# --- 0. qdrant compatibility gate --------------------------------------------
# A Qdrant snapshot restores only into the same minor version, and the restore
# side runs a pinned image -- so a dev box on a different minor produces an
# archive that packs, uploads and validates fine, then fails on core at first
# boot with nothing to point at. That is the one silent path in an otherwise
# fail-loud script, so it runs FIRST: before mktemp, before the pg_dump, before
# anything that costs time or touches the source stores.
#
# The minor is READ from the qdrant image pin rather than restated here, so the
# two cannot drift. The restore side independently re-checks the version it
# actually booted with against the MANIFEST this script writes, which is what
# catches a pin moved on only one side.
CORE_TFTPL="$(dirname "$0")/../modules/core/cloud-init.yaml.tftpl"
if [ -z "${TAPE_QDRANT_MINOR:-}" ]; then
  TAPE_QDRANT_MINOR="$(sed -n \
    's#^[[:space:]]*image:[[:space:]]*qdrant/qdrant:v\([0-9][0-9]*\.[0-9][0-9]*\)\..*#\1#p' \
    "$CORE_TFTPL" 2>/dev/null | head -1)"
  [ -n "$TAPE_QDRANT_MINOR" ] || die "could not read the qdrant pin from $CORE_TFTPL --
       run this from a checkout, or set TAPE_QDRANT_MINOR to the minor core restores on."
fi

# Capture explicitly: a bare `x="$(curl ... | jq ...)"` is a simple command, so
# under `set -e` a connection failure kills the script here and the guidance
# below never prints -- the case it was written for is the case it would miss.
src_qdrant_version=""
if ! src_qdrant_version="$(curl -fsS "$SRC_QDRANT_URL/" | jq -r '.version // empty')"; then
  die "could not reach a Qdrant at $SRC_QDRANT_URL -- is it up, and is SRC_QDRANT_URL right?"
fi
[ -n "$src_qdrant_version" ] || die "no version in the response from $SRC_QDRANT_URL -- is it Qdrant?"
src_qdrant_minor="$(printf '%s' "$src_qdrant_version" | cut -d. -f1,2)"
if [ "$src_qdrant_minor" != "$TAPE_QDRANT_MINOR" ]; then
  die "source Qdrant is $src_qdrant_version (minor $src_qdrant_minor) but the demo restores on
       $TAPE_QDRANT_MINOR.x -- snapshots do not cross minor versions, so this tape would fail to
       restore. Match your local Qdrant to $TAPE_QDRANT_MINOR.x, or move the qdrant pin in
       modules/core/cloud-init.yaml.tftpl (which is where this minor is read from)."
fi
say "source qdrant $src_qdrant_version matches the restore pin ($TAPE_QDRANT_MINOR.x)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/qdrant" "$work/blobs"

# --- 1. lineage (Postgres) ---------------------------------------------------
# Plain SQL, no ownership/ACLs -- restore replays it into a fresh `argus` db that
# has no matching roles. This captures the WHOLE database named in SRC_PG_URL --
# that DB is the dedicated lineage store (POSTGRES_DB=argus) -- so point SRC_PG_URL
# at the pipeline's argus DB and nothing unrelated rides along.
# `--clean --if-exists` makes the dump DROP each object
# before recreating it, so a re-seed (or a retry after a partially-failed
# restore) replays cleanly instead of erroring on existing tables / doubling
# rows. Restore runs it under `psql -v ON_ERROR_STOP=1`, so a genuine failure
# aborts loudly rather than being silently recorded as a successful seed.
# Redact any user:pass@ before echoing the URL so a real password never hits the log.
say "pg_dump lineage  <-  $(printf '%s' "$SRC_PG_URL" | sed -E 's#://[^@/]+@#://***@#')"
pg_dump "$SRC_PG_URL" --no-owner --no-privileges --clean --if-exists --file "$work/lineage.sql"
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
# Iterate names line-by-line: a collection name with a space or glob metachar
# must not be word-split or globbed into a bad request (`for c in $collections`).
while IFS= read -r c; do
  [ -n "$c" ] || continue
  snap="$(curl -fsS -X POST "$SRC_QDRANT_URL/collections/$c/snapshots" | jq -r '.result.name')"
  [ -n "$snap" ] && [ "$snap" != "null" ] || die "Qdrant returned no snapshot name for '$c'"
  curl -fsS "$SRC_QDRANT_URL/collections/$c/snapshots/$snap" -o "$work/qdrant/$c.snapshot"
  curl -fsS -X DELETE "$SRC_QDRANT_URL/collections/$c/snapshots/$snap" >/dev/null || true
  say "  captured $c"
  qdrant_count=$((qdrant_count + 1))
done <<< "$collections"

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
    # Prove the endpoint is reachable with these creds before concluding "no
    # blobs": a failed bucket LIST is a connection/auth error and must abort, not
    # silently pack an empty tape.
    if ! mc ls src >/dev/null; then
      echo "cannot reach source S3 at $SRC_S3_ENDPOINT -- bad endpoint or credentials" >&2
      exit 1
    fi
    if mc ls "src/$SRC_S3_BUCKET" >/dev/null 2>&1; then
      mc mirror --overwrite "src/$SRC_S3_BUCKET" /blobs
    else
      echo "bucket $SRC_S3_BUCKET not found on source -- tape will carry no blobs" >&2
    fi
  '
blob_count="$(find "$work/blobs" -type f | wc -l | tr -d ' ')"

# --- 3b. demo-tier seed trees (#9) -------------------------------------------
# quarry/forge/proof and curator's live mode read from the demo host's local
# /srv/argus/* dirs, not from core's stores -- so their seed rides in a demo/
# subtree that the demo host's restore-seed.sh extracts (core ignores it). Each
# source is optional: unset yields an empty subtree and a warning, so a core-only
# tape (the pre-#9 shape) still builds and restores. The subtree names ARE the
# contract with restore-seed.sh -- samples/quarry/exports/proof.
say "demo-tier seed  <-  local dirs (#9)"
mkdir -p "$work/demo"
demo_files=0
capture_tree() {  # capture_tree <label> <src dir> <dest subdir under demo/>
  local label="$1" src="$2" dest="$work/demo/$3"
  if [ -z "$src" ]; then
    warn "no $label seed source set -- the demo $label tier will render empty (#9)"
    return 0
  fi
  [ -d "$src" ] || die "$label seed source is not a directory: $src"
  mkdir -p "$dest"
  # Copy the contents, not the dir itself, so the subtree root is <dest> and the
  # restore side drops it straight onto /srv/argus/<tier> without a nested level.
  cp -a "$src/." "$dest/"
  local n; n="$(find "$dest" -type f | wc -l | tr -d ' ')"
  demo_files=$((demo_files + n))
  say "  captured $label ($n files)  <-  $src"
}
capture_tree samples "$SRC_SAMPLES"       samples
capture_tree quarry  "$SRC_QUARRY_HOME"   quarry
capture_tree forge   "$SRC_FORGE_EXPORTS" exports
capture_tree proof   "$SRC_PROOF_DIR"     proof

# quarry's store is WAL-mode SQLite and the demo mounts its pool :ro -- quarry
# 0.2.3+ refuses to serve a DB with a non-empty -wal sidecar from a read-only
# mount (it cannot create the -shm there, and immutable mode would read a stale
# snapshot; argus-quarry#5). A tape captured while the source store had an open
# or uncleanly-closed connection carries exactly that, and it restores fine on
# a rw mount but 503s every quarry route on the demo host. So checkpoint OUR
# COPY into a self-contained DB before packing; the source store is untouched.
while IFS= read -r -d '' wal; do
  db="${wal%-wal}"
  # An orphan sidecar with no base DB is leftover garbage -- drop it.
  [ -f "$db" ] || { rm -f "$wal"; continue; }
  command -v sqlite3 >/dev/null 2>&1 \
    || die "the captured quarry pool has an un-checkpointed WAL ($(basename "$wal")), which
       quarry cannot serve from its read-only mount. Install sqlite3 so the build can
       checkpoint the copy, or checkpoint/stop the source store and re-run."
  sqlite3 "$db" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
  rm -f "$wal" "$db-shm"
  say "  checkpointed $(basename "$db") -- quarry serves it from a :ro mount"
done < <(find "$work/demo" -path "$work/demo/quarry/*" -name '*-wal' -type f -print0 2>/dev/null)

# --- 4. manifest + archive ---------------------------------------------------
{
  echo "# argus tape -- restored into core on first boot (README > The tape)"
  echo "lineage_rows=$pg_rows"
  echo "qdrant_collections=$qdrant_count"
  # Recorded because it is a restore PRECONDITION, not trivia: these snapshots
  # only load into a matching minor.
  echo "qdrant_version=$src_qdrant_version"
  echo "blobs=$blob_count"
  echo "source_bucket=$SRC_S3_BUCKET"
  echo "demo_seed_files=$demo_files"
} > "$work/MANIFEST"

say "packing $OUT"
# Normalize what the archive RECORDS: both restore sides extract as root, and
# root's tar restores recorded owners and modes verbatim -- so without this the
# tape carries the build box's uids and any restrictive local modes (0600
# SQLite files) straight onto the demo tiers, which non-root images read
# through :ro mounts (quarry 0.2.3+ is uid 10001). --mode is symbolic-chmod
# style, so X keeps directories traversable and preserves existing exec bits
# without adding any. restore-seed.sh still chmods per tier as a backstop for
# tapes built before this line.
tar --zstd --owner=0 --group=0 --mode='u=rwX,go=rX' \
  -cf "$OUT" -C "$work" MANIFEST lineage.sql qdrant blobs demo
say "built $OUT ($(du -h "$OUT" | cut -f1)) -- ${pg_rows} lineage rows, ${qdrant_count} collections, ${blob_count} blobs, ${demo_files} demo-seed files"

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

# Default the R2 destination to the bucket Terraform provisioned -- what
# `terraform output -raw tape_bucket` reports and the runbook tells you to use.
#
# If that lookup fails, ABORT rather than falling back to SRC_S3_BUCKET. The two
# names differ by default (`argus-halo-tape` vs `argus-tape`) and `mc mb
# --ignore-existing` below would happily create the wrong one -- publishing the
# tape into a bucket Terraform does not manage and `prevent_destroy` does not
# cover, which is exactly the durability claim dns.tf makes. A silent near-miss
# here looks like success right up until the bucket is deleted by someone tidying
# up. Name it explicitly with R2_BUCKET if you really do want somewhere else.
if [ -z "${R2_BUCKET:-}" ]; then
  R2_BUCKET="$(terraform output -raw tape_bucket 2>/dev/null || true)"
  [ -n "$R2_BUCKET" ] || die "could not read 'terraform output -raw tape_bucket' -- run this from
       an initialized checkout (terraform login && terraform init), or set R2_BUCKET explicitly.
       Refusing to guess: uploading to the wrong bucket looks like success."
fi
R2_URL_EXPIRY="${R2_URL_EXPIRY:-168h}"
say "upload  ->  $R2_ENDPOINT/$R2_BUCKET/tape.tar.zst"
docker run --rm \
  -e R2_ENDPOINT -e R2_ACCESS_KEY_ID -e R2_SECRET_ACCESS_KEY -e R2_BUCKET -e R2_URL_EXPIRY \
  -v "$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT"):/tape.tar.zst:ro" \
  --entrypoint sh "$MC_IMAGE" -ec '
    mc alias set r2 "$R2_ENDPOINT" "$R2_ACCESS_KEY_ID" "$R2_SECRET_ACCESS_KEY" >/dev/null
    mc mb --ignore-existing "r2/$R2_BUCKET" >/dev/null
    mc cp /tape.tar.zst "r2/$R2_BUCKET/tape.tar.zst"
    # Capture then require a non-empty URL: set -e aborts if mc share fails, and
    # the emptiness check catches a parse miss (an mc output-format change) so a
    # broken publish fails loudly instead of printing nothing and exiting 0.
    raw="$(mc share download --expire="$R2_URL_EXPIRY" "r2/$R2_BUCKET/tape.tar.zst")"
    url="$(printf "%s\n" "$raw" | sed -n "s/^Share: //p")"
    if [ -z "$url" ]; then
      echo "could not parse a presigned URL from mc share output:" >&2
      printf "%s\n" "$raw" >&2
      exit 1
    fi
    echo
    echo "Set this as the tape_dump_url workspace variable (expires in $R2_URL_EXPIRY):"
    printf "%s\n" "$url"
  '
