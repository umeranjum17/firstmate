#!/usr/bin/env bash
# tests/jg-ticket.test.sh - bin/jg-ticket.sh, the fork-side call the lifecycle makes
# to record a task's ticket truth now. The add-on writer is optional: an absent
# writer or an absent fleet board is a silent no-op, and a present one receives the
# task, the flags and this home exactly as given.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-ticket)
TICKET="$ROOT/bin/jg-ticket.sh"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config" "$TMP_ROOT/xdg"
CALLS="$TMP_ROOT/calls"

# A stand-in writer that records what it was handed.
install_writer() {
  mkdir -p "$TMP_ROOT/xdg/jg-tickets-sync/tickets-sync"
  cat > "$TMP_ROOT/xdg/jg-tickets-sync/tickets-sync/ticket.py" <<'SH'
import json, os, sys
with open(os.environ['FM_TICKET_TEST_CALLS'], 'a') as out:
    out.write(json.dumps({'home': os.environ.get('FM_HOME'), 'argv': sys.argv[1:]}) + '\n')
SH
}

run() { FM_TICKET_TEST_CALLS="$CALLS" FM_HOME="$HOME_DIR" XDG_DATA_HOME="$TMP_ROOT/xdg" "$@"; }

"$TICKET" --help | grep -q '^Usage: jg-ticket.sh <task-id>' || fail "jg-ticket --help does not print its usage"

run "$TICKET" 'bad id' --stage building 2>/dev/null && fail "jg-ticket accepted an invalid task id"
run "$TICKET" task --nonsense 2>/dev/null && fail "jg-ticket accepted an unknown flag"

# No writer installed: the board is optional, so this is a silent success.
run "$TICKET" task --stage building || fail "jg-ticket failed without the add-on installed"
[ ! -s "$CALLS" ] || fail "jg-ticket called a writer that is not installed"

# A writer without a fleet board pointer is not asked either.
install_writer
run "$TICKET" task --stage building || fail "jg-ticket failed without a fleet board"
[ ! -s "$CALLS" ] || fail "jg-ticket wrote to a board this home does not have"

printf '%s\n' "$TMP_ROOT/board/board.json" > "$HOME_DIR/config/fleet-board"
run "$TICKET" task --stage merging --state 'in progress' --pr https://example.invalid/pull/1 --release v9 ||
  fail "jg-ticket failed with a writer and a fleet board"
jq -e --arg home "$HOME_DIR" '
  .home == $home and .argv == ["task", "--stage", "merging", "--state", "in progress",
    "--pr", "https://example.invalid/pull/1", "--release", "v9"]' "$CALLS" >/dev/null ||
  fail "jg-ticket handed the writer something other than this home and its flags: $(cat "$CALLS")"
pass "jg-ticket stays quiet without the add-on or a board, and hands the installed writer this home's task and flags"
