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
# Runs the moved jg-dashboard behavior suite against this add-on's dashboard.
# Takes a Juggernaut checkout (argument or JG_JUGGERNAUT_DIR; with neither, a
# fresh clone), clones it into a scratch tree, swaps in this add-on's
# jg-dashboard.sh, its jg-dashboard/ app and the moved test, runs the test
# there and exits with its status.
set -eu

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ADDON=$(dirname "$HERE")

FORK=${1:-${JG_JUGGERNAUT_DIR:-https://github.com/umeranjum17/juggernaut}}
case "$FORK" in
  *://*) ;;
  *) FORK="file://$(cd "$FORK" && pwd)" ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/jg-dashboard-fork-suite.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
TREE="$TMP/juggernaut"

git clone --depth 1 --quiet "$FORK" "$TREE"

rm -rf "$TREE/bin/jg-dashboard"
cp "$ADDON/jg-dashboard.sh" "$TREE/bin/jg-dashboard.sh"
cp "$ADDON/task_rows.py" "$TREE/bin/task_rows.py"
cp -R "$ADDON/jg-dashboard" "$TREE/bin/jg-dashboard"
cp "$HERE/jg-dashboard.test.sh" "$TREE/tests/jg-dashboard.test.sh"
chmod +x "$TREE/bin/jg-dashboard.sh" "$TREE/tests/jg-dashboard.test.sh"

cd "$TREE"
JG_ADDONS_DIR=$(cd "$ADDON/.." && pwd) bash tests/jg-dashboard.test.sh
