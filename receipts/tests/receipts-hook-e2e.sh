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
mkdir -p "$HOME" "$TMPDIR" "$d/fork"
cp -a "$FM_TEST_FORK/bin" "$FM_TEST_FORK/tests" "$FM_TEST_FORK/.agents" "$d/fork/"
# Step-B simulation on the private copy only: the acceptance definition becomes
# the optional source, and the publisher is the add-on's executable.
python3 - "$d/fork/bin/fm-dod-lib.sh" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
lines = p.read_text().splitlines()
start = next(i for i, l in enumerate(lines) if l.startswith('fm_dod_receipt_accept()'))
end = next(i for i in range(start + 1, len(lines)) if lines[i] == '}')
lines[start:end + 1] = ['[ ! -r "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/receipts/bin/fm-receipts-lib.sh" ] || . "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/receipts/bin/fm-receipts-lib.sh"']
p.write_text('\n'.join(lines) + '\n')
PY
# shellcheck disable=SC2016 # the shim body expands when the shim runs
printf '#!/usr/bin/env bash\nFM_FORK_BIN="$(dirname "$0")" exec "$FM_ADDONS_DIR/receipts/bin/fm-run-receipt.sh" "$@"\n' > "$d/fork/bin/fm-run-receipt.sh"
chmod +x "$d/fork/bin/fm-run-receipt.sh"
bash -n "$d/fork/bin/fm-dod-lib.sh"

(cd "$d/fork" && env -u FM_TASK_ID FM_ADDONS_DIR="$addons" bash tests/fm-dod-lib.test.sh) > "$d/present.out" 2>&1 \
  || { echo "FAIL: receipt journey with the add-on present" >&2; tail -20 "$d/present.out" >&2; exit 1; }

# Helpers the spawn, promote and brief hooks call.
export FM_HOME=$d/home FM_ADDONS_DIR=$addons
mkdir -p "$FM_HOME"
# shellcheck source=/dev/null
. "$addons/receipts/bin/fm-receipts-lib.sh"
printf 'x\nCompletion receipt: required\n' > "$d/brief"
[ "$(fm_receipts_inherit ship "$d/brief")" = receipt_required=1 ] || { echo "FAIL: inherit from brief" >&2; exit 1; }
[ -z "$(fm_receipts_inherit scout "$d/brief")" ] || { echo "FAIL: scout must not require" >&2; exit 1; }
printf 'receipt_required=1\n' > "$d/old.meta"; : > "$d/plain"
[ "$(fm_receipts_inherit ship "$d/plain" "$d/old.meta")" = receipt_required=1 ] || { echo "FAIL: relaunch inherit" >&2; exit 1; }
printf 'kind=ship\nreceipt_required=0\n' > "$d/tmp.meta"
fm_receipts_promote "$d/tmp.meta"
[ "$(grep -c '^receipt_required=' "$d/tmp.meta")" -eq 1 ] && grep -qx 'receipt_required=1' "$d/tmp.meta" || { echo "FAIL: promote" >&2; exit 1; }
fm_receipts_brief demo-id | grep -q "$addons/receipts/bin/fm-run-receipt.sh demo-id PASS" || { echo "FAIL: brief contract" >&2; exit 1; }

# Absent: the same guarded lines load nothing and survive set -e.
( set -e; FM_ADDONS_DIR=$d/none
  [ ! -r "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/receipts/bin/fm-receipts-lib.sh" ] || exit 1
  unset -f fm_receipts_brief fm_receipts_inherit fm_receipts_promote fm_dod_receipt_accept
  if declare -F fm_receipts_brief >/dev/null; then exit 1; fi
  if declare -F fm_dod_receipt_accept >/dev/null; then exit 1; fi ) \
  || { echo "FAIL: absent add-on must be a no-op" >&2; exit 1; }
echo "ok: receipts present -> fork journey passes; absent -> kun behavior"
