#!/usr/bin/env bash
# Seeds the demo tier's read-only service data from the tape's demo/ subtree
# (#9): quarry pool, curated export, precomputed EvalReports, and curator's
# live-mode corpus (#14). Runs BEFORE `compose up` -- unlike core's
# restore-tape.sh, which loads INTO running stores -- because these are
# bind-mount SOURCES the containers read at start. Idempotent via a marker.
# Same archive as scripts/build-tape.sh; only demo/ is used here (core reads
# lineage/qdrant/blobs, which this ignores).
set -euo pipefail
set -a
# shellcheck source=/dev/null
. /opt/argus/deploy.env
set +a

MARKER=/srv/argus/.seed-restored

# deploy.env carries the URL the host was born with -- useless once an R2
# presign has expired. TAPE_DUMP_URL in the environment overrides it:
#   TAPE_DUMP_URL='<fresh url>' /opt/argus/stack/restore-seed.sh
TAPE_URL="${TAPE_DUMP_URL:-}"

[ -f "$MARKER" ] && { echo "demo seed already restored"; exit 0; }
# "Empty" is degraded, not broken -- except quarry: its pool is mounted
# :ro, so unlike the pre-0.2.3 rw mount it cannot create a store on first
# request, and /ready plus every data GET answer 503 until a pool is
# seeded. The other tiers render empty pages.
[ -z "$TAPE_URL" ] && { echo "no tape_dump_url set, demo tiers start empty (quarry 503s until seeded -- its :ro mount forbids creating a store)"; exit 0; }

cd /srv/argus
# Mirror restore-tape.sh's fetch: separate transport failures from an expired
# presign so the message names the actual fix. See docs/runbook.md.
rm -f tape.tar.zst
curl_rc=0
http_code="$(curl -sSL --retry 3 --retry-all-errors --retry-delay 5 \
  --remove-on-error -o tape.tar.zst -w '%{http_code}' "$TAPE_URL")" || curl_rc=$?
if [ "$curl_rc" -ne 0 ]; then
  rm -f tape.tar.zst
  echo "could not fetch the tape: curl exited $curl_rc -- transport (DNS/TLS/dropped)," >&2
  echo "not the URL. Retry before rebuilding the tape." >&2
  exit 1
fi
case "$http_code" in
  2??) ;;
  401|403)
    rm -f tape.tar.zst
    echo "the tape URL was rejected (HTTP $http_code) -- an R2 presign expires after" >&2
    echo "7 days. Rebuild with 'make tape', then re-run PASSING the fresh URL (the one" >&2
    echo "in deploy.env expired with it), and set the tape_dump_url workspace variable:" >&2
    echo "  TAPE_DUMP_URL='<new url>' /opt/argus/stack/restore-seed.sh" >&2
    exit 1 ;;
  *)
    rm -f tape.tar.zst
    echo "the tape fetch returned HTTP $http_code -- check what tape_dump_url points at." >&2
    exit 1 ;;
esac

# An older, core-only tape has no demo/ subtree: come up empty (the pre-#9
# behaviour) rather than failing, since that tape is still valid for core.
# List once into a variable -- `tar -tf | grep -q` can SIGPIPE tar under
# pipefail and misreport a present subtree as absent.
members="$(tar --zstd -tf tape.tar.zst)" || { echo "cannot read the tape archive" >&2; exit 1; }
if ! printf '%s\n' "$members" | grep -q '^demo/'; then
  echo "this tape carries no demo/ subtree -- tiers start empty (rebuild with a" >&2
  echo "#9-aware 'make tape' to seed them; quarry 503s until then, its :ro mount" >&2
  echo "forbids creating a store)." >&2
  rm -f tape.tar.zst
  exit 0
fi
rm -rf /srv/argus/tape && mkdir -p /srv/argus/tape
tar --zstd -xf tape.tar.zst -C /srv/argus/tape demo

# Drop each tier's tree onto its mount source. Copy the CONTENTS (-a to keep
# the layout the services expect) so the existing mount point is preserved.
seed() {  # seed <subtree> <dest>
  local sub="/srv/argus/tape/demo/$1" dest="$2"
  [ -d "$sub" ] || { echo "  (no $1 in tape; $dest left empty)"; return 0; }
  mkdir -p "$dest"
  cp -a "$sub/." "$dest/"
  # The tape preserves whatever owners and modes the build box had (tapes
  # older than the pack-time normalization in build-tape.sh carry them
  # verbatim), and these trees are read through :ro mounts by images that
  # may not run as root -- quarry 0.2.3+ is uid 10001 (argus-quarry#8) --
  # so grant world-read (a+rX: read plus directory traversal) per tier,
  # or every GET 500s on open(). Per seed, not after the loop, so a
  # failure in a later tier cannot strand this one seeded-but-unreadable.
  chmod -R a+rX "$dest"
  echo "  seeded $dest ($(find "$sub" -type f | wc -l | tr -d ' ') files)"
}
seed samples /srv/argus/samples
seed quarry  /srv/argus/quarry
seed exports /srv/argus/exports
seed proof   /srv/argus/proof

rm -rf /srv/argus/tape tape.tar.zst
touch "$MARKER"
echo "demo seed restored"
