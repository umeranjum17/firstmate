#!/usr/bin/env bash
# Behavior tests for the Claude external-imports spawn gate
# (claude_wait_for_imports_answer in bin/fm-spawn.sh).
#
# The gate under test is executed verbatim from bin/fm-spawn.sh (extracted at
# test time so the test tracks the implementation); only the backend boundary
# is scripted: claude_visible_capture replays canned viewport frames and
# spawn_send_key records Enter presses. Assertions cover observable behavior -
# exit codes, Enter counts, and poll counts - never implementation text.
#
# Invariants: the imports dialog is answered exactly once with Enter (its
# cursor rests on the fail-closed decline); the trust dialog is never touched
# (Enter there selects "No, exit"); a single non-dialog frame right after the
# answer - including an empty capture from a failed backend read - must not
# report success (post-answer clear streak); a dialog that never clears fails
# the spawn loudly instead of parking a worker at the dialog. Sustained
# empty reads count toward the clear streak, so a pane that never renders
# exits without burning the full poll budget.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

# Execute the real gate. fm-spawn.sh has no source guard (it is a launcher,
# not a library), so only the gate function is evaluated, verbatim.
eval "$(awk '/^claude_wait_for_imports_answer\(\)/,/^\}/' "$ROOT/bin/fm-spawn.sh")"

TMP_ROOT=$(fm_test_tmproot fm-claude-imports-gate)

IMPORTS_FRAME='Allow external CLAUDE.md file imports?
This project'"'"'s CLAUDE.md imports files outside the current working directory.
> No, disable external imports
  Yes, allow external imports'
TRUST_FRAME='Accessing workspace: /tmp/wt-a
Quick safety check: Is this a project you created or one you trust?
Claude Code'"'"'ll be able to read, edit, and execute files here.
> No, exit
  Yes, I trust this folder
Enter to confirm . Esc to cancel'
IDLE_FRAME='worker ready
❯'
EMPTY_FRAME=''

# Scripted backend boundary. Frames live in files (command substitution runs
# in a subshell, so a shell-variable cursor would never advance).
GATE_DIR=
gate_setup() {  # <name> <frame...> (each "name:content" via parallel arrays is
  # overkill; callers write frames with gate_frame)
  GATE_DIR="$TMP_ROOT/$1"
  mkdir -p "$GATE_DIR"
  printf '0' >"$GATE_DIR/idx"
  : >"$GATE_DIR/enters"
  : >"$GATE_DIR/calls"
  # The gate's only free inputs, as a real spawn provides them: T is the
  # window the Enter goes to, W rides along for backend calls.
  # shellcheck disable=SC2034 # read by the eval'd spawn gate at call time
  T=test-window W=test-pane
} 

gate_frame() {  # <text>  (appends one replay frame)
  local n
  n=$(find "$GATE_DIR" -maxdepth 1 -name 'frame-*' 2>/dev/null | wc -l | tr -d ' ')
  printf '%s' "$1" >"$GATE_DIR/frame-$n"
}

claude_visible_capture() {
  local idx n
  idx=$(cat "$GATE_DIR/idx")
  n=$(find "$GATE_DIR" -maxdepth 1 -name 'frame-*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$idx" -ge "$n" ] && idx=$((n - 1))
  printf 'call\n' >>"$GATE_DIR/calls"
  printf '%s' "$((idx + 1))" >"$GATE_DIR/idx"
  cat "$GATE_DIR/frame-$idx"
}

spawn_send_key() {  # <target> <key>
  [ "${2:-}" = Enter ] || fail "gate pressed unexpected key '$2'"
  printf 'enter\n' >>"$GATE_DIR/enters"
  return 0
}

gate_run() {  # <max-polls> -> rc
  FM_CLAUDE_IMPORTS_POLLS=$1 FM_CLAUDE_IMPORTS_POLL_INTERVAL=0 \
    claude_wait_for_imports_answer
}

gate_enters() { wc -l <"$GATE_DIR/enters" | tr -d ' '; }
gate_calls() { wc -l <"$GATE_DIR/calls" | tr -d ' '; }

test_no_dialog_exits_clean_without_pressing() {
  local rc i
  gate_setup no-dialog
  for ((i = 0; i < 12; i++)); do gate_frame "$IDLE_FRAME"; done
  gate_run 60; rc=$?
  [ "$rc" -eq 0 ] || fail "no dialog must exit 0, got $rc"
  [ "$(gate_enters)" -eq 0 ] || fail "no dialog must press nothing"
  pass "no imports dialog exits 0 without pressing Enter"
}

test_imports_dialog_answered_once_then_clears() {
  local rc
  gate_setup answered-clears
  gate_frame "$IMPORTS_FRAME"
  gate_frame "$IDLE_FRAME"; gate_frame "$IDLE_FRAME"; gate_frame "$IDLE_FRAME"
  gate_frame "$IDLE_FRAME"; gate_frame "$IDLE_FRAME"
  gate_run 60; rc=$?
  [ "$rc" -eq 0 ] || fail "cleared dialog must exit 0, got $rc"
  [ "$(gate_enters)" -eq 1 ] || fail "cleared dialog must press Enter exactly once, got $(gate_enters)"
  pass "imports dialog is answered once with Enter and success follows the clear"
}

test_single_transient_frame_after_answer_is_not_success() {
  local rc calls
  gate_setup transient-frame
  gate_frame "$IMPORTS_FRAME"
  gate_frame "$IDLE_FRAME"     # one transient non-dialog frame: must not succeed
  gate_frame "$IMPORTS_FRAME"  # dialog still present
  gate_frame "$IDLE_FRAME"; gate_frame "$IDLE_FRAME"; gate_frame "$IDLE_FRAME"
  gate_frame "$IDLE_FRAME"; gate_frame "$IDLE_FRAME"
  gate_run 60; rc=$?
  calls=$(gate_calls)
  [ "$rc" -eq 0 ] || fail "eventually-cleared dialog must exit 0, got $rc"
  [ "$(gate_enters)" -eq 1 ] || fail "must press Enter exactly once, got $(gate_enters)"
  [ "$calls" -gt 2 ] || fail "a single post-answer frame must not report success (returned after $calls polls)"
  pass "one transient non-dialog frame after answering does not report success"
}

test_empty_capture_after_answer_is_not_success() {
  local rc calls
  gate_setup empty-frame
  gate_frame "$IMPORTS_FRAME"
  gate_frame "$EMPTY_FRAME"    # failed backend read: counts toward the streak but one alone must not succeed
  gate_frame "$IMPORTS_FRAME"
  gate_frame "$IDLE_FRAME"; gate_frame "$IDLE_FRAME"; gate_frame "$IDLE_FRAME"
  gate_frame "$IDLE_FRAME"; gate_frame "$IDLE_FRAME"
  gate_run 60; rc=$?
  calls=$(gate_calls)
  [ "$rc" -eq 0 ] || fail "eventually-cleared dialog must exit 0, got $rc"
  [ "$(gate_enters)" -eq 1 ] || fail "must press Enter exactly once, got $(gate_enters)"
  [ "$calls" -gt 2 ] || fail "an empty capture after answering must not report success (returned after $calls polls)"
  pass "an empty capture after answering does not report success"
}

test_trust_dialog_is_never_touched() {
  local rc i
  gate_setup trust
  for ((i = 0; i < 12; i++)); do gate_frame "$TRUST_FRAME"; done
  gate_run 12; rc=$?
  [ "$rc" -eq 0 ] || fail "trust dialog must exit 0 (stale path owns it), got $rc"
  [ "$(gate_enters)" -eq 0 ] || fail "trust dialog must never be answered: Enter there selects No, exit"
  pass "trust dialog is never answered and stays a stale-wake matter"
}

test_dialog_that_never_clears_fails_loudly() {
  local rc i
  gate_setup never-clears
  for ((i = 0; i < 14; i++)); do gate_frame "$IMPORTS_FRAME"; done
  gate_run 12; rc=$?
  [ "$rc" -eq 1 ] || fail "an uncleared dialog must fail the spawn (rc 1), got $rc"
  [ "$(gate_enters)" -eq 1 ] || fail "must press Enter exactly once before failing, got $(gate_enters)"
  pass "an imports dialog that never clears fails the spawn instead of parking a worker"
}

test_sustained_empty_exits_without_burning_full_budget() {
  local rc calls
  gate_setup sustained-empty
  local i
  for ((i = 0; i < 60; i++)); do gate_frame "$EMPTY_FRAME"; done
  gate_run 60; rc=$?
  calls=$(gate_calls)
  [ "$rc" -eq 0 ] || fail "sustained empty must exit 0, got $rc"
  [ "$(gate_enters)" -eq 0 ] || fail "must press nothing when no dialog was seen"
  [ "$calls" -eq 10 ] || fail "sustained empty must exit on the clear streak (10 polls), not burn the full budget (used $calls polls)"
  pass "a pane that never renders exits on the clear streak instead of hanging the full budget"
}

test_no_dialog_seen_at_all_exits_clean() {
  local rc i
  gate_setup all-empty
  for ((i = 0; i < 8; i++)); do gate_frame "$EMPTY_FRAME"; done
  gate_run 8; rc=$?
  [ "$rc" -eq 0 ] || fail "no answered dialog must exit 0, got $rc"
  [ "$(gate_enters)" -eq 0 ] || fail "must press nothing when no dialog was seen"
  pass "empty captures with no dialog exit 0 without pressing"
}

test_no_dialog_exits_clean_without_pressing
test_imports_dialog_answered_once_then_clears
test_single_transient_frame_after_answer_is_not_success
test_empty_capture_after_answer_is_not_success
test_trust_dialog_is_never_touched
test_dialog_that_never_clears_fails_loudly
test_sustained_empty_exits_without_burning_full_budget
test_no_dialog_seen_at_all_exits_clean
