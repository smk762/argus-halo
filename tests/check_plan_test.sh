#!/usr/bin/env bash
# check-plan.py must refuse each bad plan and pass the good one.
set -euo pipefail
cd "$(dirname "$0")/.."
run() { python3 scripts/check-plan.py "$@" >/dev/null 2>&1; }
run tests/plans/safe.txt
run --allow-replace tests/plans/replace.txt
for bad in replace destroy incomplete; do
  if run "tests/plans/$bad.txt"; then echo "accepted $bad.txt" >&2; exit 1; fi
done
echo "check-plan: ok"
