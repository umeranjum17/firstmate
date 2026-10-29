#!/usr/bin/env bash
# done-done journey: the installed merge gate refuses a change that adds a unit, snapshot or mock
# test file, with a clear message, and accepts a journey test. Real git branches, real gate.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
bash "$REPO/addons/owner-rules/tests/test-kind.test.sh" > "$OUT/test-kind-gate.txt" 2>&1 || { cat "$OUT/test-kind-gate.txt"; echo "FAIL: gate test"; exit 1; }
cat "$OUT/test-kind-gate.txt"
jq -n '{target:{version:"addons/owner-rules from this branch"},
  start:"a repo with a merge gate installed and branches that add test files",
  steps:["a branch adds a unit, snapshot or mock test file","the merge gate runs","a branch adds a journey test and the gate runs again"],
  result:"unit, snapshot and mock test files are refused with a clear message; a journey test is accepted"}' > "$OUT/steps.json"
