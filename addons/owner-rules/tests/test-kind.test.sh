#!/usr/bin/env bash
# Tests-rule journey: a real git change run through the installed config/merge-gate.
# Usage: owner-rules/tests/test-kind.test.sh
# A branch adding a unit test, a snapshot, or a mock-using test is refused with the clear message; a journey test and a
# change with no test file reach the gate's next check (the proof receipt). No forge, no done-done.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/owner-rules-test-kind.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
export HOME=$work/user
fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }

home=$work/home repo=$work/repo; mkdir -p "$home/config" "$repo/tests"
"$addons/owner-rules/install.sh" "$home" >/dev/null
g() { git -C "$repo" -c user.name=t -c user.email=t@example.com "$@"; }
git init -q -b main "$repo" && echo base > "$repo/README" && g add -A && g commit -qm base
# change <file> <content>: a branch off main that adds exactly that file; prints the gate's output.
change() {
  g checkout -q -B change main && mkdir -p "$(dirname "$repo/$1")" && printf '%s\n' "$2" > "$repo/$1" && g add -A && g commit -qm change
  JG_HOME=$home "$home/config/merge-gate" lane "$repo" "$(g rev-parse HEAD)" - 2>&1
}
refuses() { # <label> <file> <content> <reason>
  local out; out=$(change "$2" "$3")
  [[ $out == *"adds $2, and $4; this repo takes integration and end-to-end journey tests only"* ]] && ok "refused: $1" || no "$1 was not refused: $out"
}
passes() { # <label> <file> <content>
  local out; out=$(change "$2" "$3")
  [[ $out == *"no passed-proof receipt"* && $out != *"journey tests only"* ]] && ok "accepted: $1" || no "$1 was refused or stuck: $out"
}
refuses "unit test by name" tests/fm-widget.unit.test.sh 'true' 'its path marks a unit, snapshot or mock test'
refuses "snapshot file" tests/__snapshots__/widget.snap 'x' 'its path marks a unit, snapshot or mock test'
refuses "mock-library content" tests/widget.test.ts "jest.mock('./db')" 'it uses a snapshot or mock library'
passes "journey test" tests/widget-journey.test.sh 'true'
passes "e2e test" tests/e2e/widget.test.ts 'await page.click()'
passes "change with no test file" docs/widget.md 'text'

[ "$fails" -eq 0 ] && echo "PASS test-kind" || { echo "FAIL test-kind: $fails"; exit 1; }
