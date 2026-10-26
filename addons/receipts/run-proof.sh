#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  eval "[ -n \"\${$_jg_new+set}\" ]" && continue
  eval "_jg_val=\${_jg_old}"
  export "$_jg_new=$_jg_val"
done
unset _jg_old _jg_new _jg_val 2>/dev/null || true
# run-proof.sh: the receipt-candidate hook proof for done-done. Runs the receipts hook journey, which drives the
# real fork bin/jg-pr-check.sh with this add-on's jg_receipts_pr_candidate, and keeps its transcript as evidence.
# JG_TEST_FORK names a read-only Firstmate checkout (default ~/firstmate); nothing in it is changed.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
mkdir -p "$evidence"
export JG_TEST_FORK=${JG_TEST_FORK:-$HOME/firstmate}
bash "$repo/receipts/tests/receipts-hook-e2e.sh" 2>&1 | tee "$evidence/receipt-candidate.txt"
test "${PIPESTATUS[0]}" -eq 0
cat > "$evidence/steps.json" <<'J'
{"target":{"version":"firstmate bin/jg-pr-check.sh from a read-only fork checkout, with this add-on's receipts library"},
 "start":"a disposable firstmate home with one direct-PR task and a verified forge head",
 "steps":["call jg_receipts_pr_candidate for a pull request outside the worktree's origin, for one in it, and with an empty head","run the real jg-pr-check.sh with the add-on library for the outside-origin and the same-repo pull request and read the candidate the gate receives"],
 "result":"the outside-origin pull request's verified head is the receipt candidate; a same-repo or unverified one gives none; the transcript ends with ok"}
J
