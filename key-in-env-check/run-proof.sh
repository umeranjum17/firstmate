#!/usr/bin/env bash
# Capture the key-in-env check's fixture-process journey for done-done.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
capture_dir=$evidence/proof
mkdir -p "$capture_dir"
cd "$repo"

printf '$ bash key-in-env-check/tests/key-in-env-check-e2e.sh\n' >"$capture_dir/key-in-env-check.txt"
bash key-in-env-check/tests/key-in-env-check-e2e.sh >>"$capture_dir/key-in-env-check.txt" 2>&1

python3 - "$capture_dir/steps.json" "$(git rev-parse HEAD)" <<'PY'
import json, sys
record = {
    "target": {"version": sys.argv[2]},
    "start": "A fixture home with synthetic key-carrying processes, a key-free process, and a local provider-auth HTTP fixture.",
    "steps": [
        "Run the key-in-env checker against the fixture process tree and inspect its incident list.",
        "Repeat the unchanged finding, then increase the carrier count by 10% and confirm silence.",
        "Increase the carrier count by exactly 26%, add a new key name, and return HTTP 401 from the provider fixture.",
        "Run a clean scan followed by the same finding and inspect the alert and redaction output."
    ],
    "result": "The checker alerts initially, stays quiet for an unchanged finding and a 10% increase, alerts at 26% and for a new key name, adds key revoked after HTTP 401, re-alerts after a clean scan, and never exposes the canary value."
}
with open(sys.argv[1], "w") as f:
    json.dump(record, f, indent=2)
    f.write("\n")
PY
echo "run-proof: captured the key-in-env check journey"
