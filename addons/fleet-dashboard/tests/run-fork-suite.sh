#!/usr/bin/env bash
# Runs the moved jg-dashboard behavior suite against this add-on's dashboard.
# Takes a Firstmate checkout (argument or FM_FIRSTMATE_DIR; with neither, a
# fresh clone), clones it into a scratch tree, swaps in this add-on's
# jg-dashboard.sh, its jg-dashboard/ app and the moved test, runs the test
# there and exits with its status.
set -eu

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ADDON=$(dirname "$HERE")

FORK=${1:-${FM_FIRSTMATE_DIR:-https://github.com/umeranjum17/firstmate}}
case "$FORK" in
  *://*) ;;
  *) FORK="file://$(cd "$FORK" && pwd)" ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/jg-dashboard-fork-suite.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
TREE="$TMP/firstmate"

git clone --depth 1 --quiet "$FORK" "$TREE"

rm -rf "$TREE/bin/jg-dashboard"
cp "$ADDON/jg-dashboard.sh" "$TREE/bin/jg-dashboard.sh"
cp "$ADDON/task_rows.py" "$TREE/bin/task_rows.py"
cp -R "$ADDON/jg-dashboard" "$TREE/bin/jg-dashboard"
cp "$HERE/jg-dashboard.test.sh" "$TREE/tests/jg-dashboard.test.sh"
chmod +x "$TREE/bin/jg-dashboard.sh" "$TREE/tests/jg-dashboard.test.sh"

cd "$TREE"
FM_ADDONS_DIR=$(cd "$ADDON/.." && pwd) bash tests/jg-dashboard.test.sh
