#!/usr/bin/env bash
# done-done proof: validate the fixture reader and capture a redacted real reading for dispatch.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$evidence" "$work/home/state"
export FM_HOME=$work/home

bash "$repo/claude-accounts/tests/claude-accounts.test.sh" >"$evidence/test.txt" 2>&1
"$repo/claude-accounts/bin/claude-accounts-quota.sh" >/dev/null
jq 'del(.accounts[].folder)' "$FM_HOME/state/claude-accounts.json" >"$evidence/reading.json"
echo "run-proof: fixture tests and a redacted dispatch reading are in $evidence"
