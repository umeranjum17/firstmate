#!/usr/bin/env bash
# The fork's real completion-receipt journey (tests/fm-dod-lib.test.sh publishes,
# refuses and accepts receipts and lands locally) with acceptance and the
# publisher served from the add-on through the step-B hook lines. Absent ->
# the guarded lines are a no-op. FM_TEST_FORK names a read-only Firstmate checkout.
set -euo pipefail
addons=$(cd "$(dirname "$0")/../.." && pwd)
: "${FM_TEST_FORK:?set FM_TEST_FORK to a Firstmate checkout}"
d=$(mktemp -d)
cleanup() {
  rc=$?
  if [ "$rc" -eq 0 ]; then rm -rf -- "$d"; else printf 'fixture retained: %s\n' "$d" >&2; fi
}
trap cleanup EXIT
export HOME=$d/user TMPDIR=$d/tmp
mkdir -p "$HOME" "$TMPDIR"
git clone --shared "$FM_TEST_FORK" "$d/fork" >/dev/null
# The current fork already has the optional add-on source and call-site hooks.
# Keep its scripts intact so the fork's executable journeys cover those hooks.
# shellcheck disable=SC2016 # the shim body expands when the shim runs
printf '#!/usr/bin/env bash\nFM_FORK_BIN="$(dirname "$0")" exec "$FM_ADDONS_DIR/receipts/bin/fm-run-receipt.sh" "$@"\n' > "$d/fork/bin/fm-run-receipt.sh"
chmod +x "$d/fork/bin/fm-run-receipt.sh"
bash -n "$d/fork/bin/fm-dod-lib.sh"

for test in fm-dod-lib.test.sh fm-task-delivery.test.sh fm-pr-merge.test.sh; do
  (cd "$d/fork" && env -u FM_TASK_ID FM_ADDONS_DIR="$addons" bash "tests/$test") > "$d/$test.out" 2>&1 \
    || { echo "FAIL: fork receipt hook journey $test" >&2; tail -20 "$d/$test.out" >&2; exit 1; }
done

# Helpers the spawn, promote and brief hooks call.
export FM_HOME=$d/home FM_ADDONS_DIR=$addons
mkdir -p "$FM_HOME"
# Source the real fork library so the add-on helper runs with its real dependencies.
FM_ADDONS_DIR=$addons
# shellcheck disable=SC1091 # sourced from the private fork clone at runtime
. "$d/fork/bin/fm-dod-lib.sh"
printf 'x\nCompletion receipt: required\n' > "$d/brief"
[ "$(fm_receipts_inherit "$d/brief")" = receipt_required=1 ] || { echo "FAIL: inherit from brief" >&2; exit 1; }
[ -z "$(KIND=scout fm_receipts_inherit "$d/brief")" ] || { echo "FAIL: scout must not require" >&2; exit 1; }
printf 'receipt_required=1\n' > "$d/old.meta"; : > "$d/plain"
[ "$(fm_receipts_inherit "$d/plain" "$d/old.meta")" = receipt_required=1 ] || { echo "FAIL: relaunch inherit" >&2; exit 1; }
printf 'kind=ship\nreceipt_required=0\n' > "$d/tmp.meta"
fm_receipts_promote "$d/old.meta" "$d/tmp.meta"
[ "$(grep -c '^receipt_required=' "$d/tmp.meta")" -eq 1 ] && grep -qx 'receipt_required=1' "$d/tmp.meta" || { echo "FAIL: promote" >&2; exit 1; }
fm_receipts_brief demo-id | grep -q "$addons/receipts/bin/fm-run-receipt.sh demo-id PASS" || { echo "FAIL: brief contract" >&2; exit 1; }

# Done acceptance through the helper: a PASS receipt bound to the worktree head
# accepts; a FAIL receipt for the same head refuses.
w=$d/wt; mkdir "$w"; git -C "$w" init -q; git -C "$w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m c
h=$(git -C "$w" rev-parse HEAD); st=$d/state; mkdir "$st"; printf 'mode=direct-PR\nspawn_gen=1\nreceipt_required=1\n' > "$st/t.meta"
rcpt() { printf '{"schema":1,"task":"t","mode":"direct-PR","spawn_gen":"1","head":"%s","verdict":"%s","evidence":"ran","at":1}\n' "$h" "$1" > "$st/t.run-receipt.json"; }
rcpt PASS
fm_receipts_accept_done "$w" direct-PR "done: x" "$st" t "$st/t.meta" "" >/dev/null || { echo "FAIL: accept_done accept" >&2; exit 1; }
rcpt FAIL
! fm_receipts_accept_done "$w" direct-PR "done: x" "$st" t "$st/t.meta" "" >/dev/null || { echo "FAIL: accept_done refuse" >&2; exit 1; }

# Absent: source the real fork library with no add-on and prove it defines no hooks.
( set -e; FM_ADDONS_DIR=$d/none FM_HOME=$d/absent-home
  unset -f fm_receipts_brief fm_receipts_inherit fm_receipts_promote fm_receipts_accept_done fm_dod_receipt_accept
  # shellcheck disable=SC1091 # sourced from the private fork clone at runtime
  . "$d/fork/bin/fm-dod-lib.sh"
  for fn in fm_receipts_brief fm_receipts_inherit fm_receipts_promote fm_receipts_accept_done fm_dod_receipt_accept; do
    if declare -F "$fn" >/dev/null; then exit 1; fi
  done ) \
  || { echo "FAIL: absent add-on must be a no-op" >&2; exit 1; }
echo "ok: done-acceptance, local-delivery and both PR-merge suites pass with add-on loaded; absent add-on loads no hooks"
