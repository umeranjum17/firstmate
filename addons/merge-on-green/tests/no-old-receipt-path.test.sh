#!/usr/bin/env bash
# E2E: both lint entry points publish the completion receipt through the receipts add-on's publisher
# ($FM_ADDONS_DIR/receipts/bin/fm-run-receipt.sh) and never through the old firstmate publisher (bin/fm-run-receipt.sh
# in the home or the main home). The add-on publisher is a recording stub; the old paths are tripwires that fail the run.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home XDG_DATA_HOME=$d/xdg TMPDIR=$d FM_HOME=$d/fm FM_MAIN_HOME=$d/main FM_ADDONS_DIR=$d/addons CALLS=$d
mkdir -p "$HOME" "$XDG_DATA_HOME" "$d/bin" "$FM_HOME"/{bin,state,data/lane-x/evidence} "$FM_MAIN_HOME/bin" "$HOME/firstmate/bin" "$FM_ADDONS_DIR/receipts/bin" "$d/wt"
fails=0
ok() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }

cat > "$FM_ADDONS_DIR/receipts/bin/fm-run-receipt.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$CALLS/addon-calls"
STUB
cat > "$d/trip" <<'STUB'
#!/usr/bin/env bash
echo "$0" >> "$CALLS/old-calls"
exit 1
STUB
for old in "$FM_HOME/bin" "$FM_MAIN_HOME/bin" "$HOME/firstmate/bin"; do cp "$d/trip" "$old/fm-run-receipt.sh"; done
# A done-done that passes the version probe and logs one passing lint row.
cat > "$d/bin/done-done" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  lint) if [ "${2:-}" = --help ]; then echo 'checks.generated_paths:'; else
          printf 't\t%s\thead1\tpass\tok\n' "$2" >> "$DONE_DONE_HOME/lint.log"; fi ;;
esac
STUB
chmod +x "$FM_ADDONS_DIR/receipts/bin/fm-run-receipt.sh" "$FM_HOME/bin/fm-run-receipt.sh" "$FM_MAIN_HOME/bin/fm-run-receipt.sh" "$HOME/firstmate/bin/fm-run-receipt.sh" "$d/bin/done-done"
printf 'mode=direct-PR\nspawn_gen=1\nworktree=%s\n' "$d/wt" > "$FM_HOME/state/lane-x.meta"
git -C "$d/wt" init -q .
git -C "$d/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'frame\n' > "$FM_HOME/data/lane-x/evidence/shot.png"
report="$FM_HOME/data/lane-x/report.md"
printf '## Checks\noutcome: the lane proves the new screen\nrepro: n/a: no bug\nproof: no verify skill - bash fixture\nevidence: evidence/shot.png\n' > "$report"
printf 'pr=%s\n' "$report" >> "$FM_HOME/state/lane-x.meta"

# 1. fm-checks-lint.sh (the legacy lint, also the fallback of checks-lint.sh).
"$ROOT/merge-on-green/fm-checks-lint.sh" "$report" "$FM_HOME/data/lane-x" >/dev/null 2>&1 || bad "fm-checks-lint.sh must PASS the fixture"
[ "$(cat "$d/addon-calls" 2>/dev/null)" = "lane-x|PASS" ] && ok "fm-checks-lint.sh publishes through the add-on publisher" || bad "fm-checks-lint.sh did not publish lane-x PASS through the add-on: $(cat "$d/addon-calls" 2>/dev/null)"
[ ! -e "$d/old-calls" ] && ok "fm-checks-lint.sh never calls the old publisher" || bad "fm-checks-lint.sh called the old publisher: $(cat "$d/old-calls")"

# 2. checks-lint.sh on the done-done path.
rm -f "$d/addon-calls"
FM_DONE_DONE_BIN="$d/bin/done-done" "$ROOT/merge-on-green/checks-lint.sh" "$report" "$FM_HOME/data/lane-x" >/dev/null 2>&1 || bad "checks-lint.sh must PASS the fixture"
[ "$(cat "$d/addon-calls" 2>/dev/null)" = "lane-x|PASS" ] && ok "checks-lint.sh publishes through the add-on publisher" || bad "checks-lint.sh did not publish lane-x PASS through the add-on: $(cat "$d/addon-calls" 2>/dev/null)"
[ ! -e "$d/old-calls" ] && ok "checks-lint.sh never calls the old publisher" || bad "checks-lint.sh called the old publisher: $(cat "$d/old-calls")"

[ "$fails" -eq 0 ] && echo 'PASS: lint publishes receipts only through the receipts add-on' || { echo "FAIL: $fails" >&2; exit 1; }
