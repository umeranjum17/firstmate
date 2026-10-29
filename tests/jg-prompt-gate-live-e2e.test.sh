#!/usr/bin/env bash
# Live guard for the permission-prompt gate (live-harness-optin family): the
# matcher reads OpenCode's rendered dialog, so per juggernaut-coding-guidelines
# "Harness-dependent checks" it is proven against the real installed binary.
# A squad_lead is hand-restarted the way an operator does it (`opencode
# --continue`, no OPENCODE_CONFIG_CONTENT grant) in a lab home on a private
# tmux server, and the real watcher runs over it:
#   - a read of the lead's parent steering inbox is approved, logged in
#     state/prompt-approvals.jsonl, shown by the fleet view, and the read lands;
#   - a read outside the fleet's roots is left unanswered: the watcher wakes
#     once with the prompt and its path and hands it to the escalation chain;
#   - a read of the parent's data/ is rejected and the lead is told why.
# It submits prompts to a free OpenCode model, so it is opt-in:
# JG_PROMPT_GATE_LIVE=1 (JG_PROMPT_GATE_MODEL overrides the model).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

jg_live_gate opt-in JG_PROMPT_GATE_LIVE opencode tmux

MODEL=${JG_PROMPT_GATE_MODEL:-opencode/glm-5.3-flash-free}
TMP_ROOT=$(jg_test_tmproot jg-prompt-gate-live)
LAB=$("$ROOT/bin/jg-lab-home.sh" create "$TMP_ROOT/home")
TMUX_TMPDIR=$("$ROOT/bin/jg-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR
LEAD="$TMP_ROOT/lead"
W=jglab:jg-lead1
WATCHER=
cleanup_live() {
  [ -z "$WATCHER" ] || kill "$WATCHER" 2>/dev/null
  tmux kill-server 2>/dev/null
  "$ROOT/bin/jg-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
}
trap 'cleanup_live; jg_test_cleanup' EXIT

note() { printf '# %s\n' "$1"; }
screen() { tmux capture-pane -p -t "$W" 2>/dev/null; }
wait_screen() {  # <grep pattern> <seconds>
  local i
  for i in $(seq 1 "$2"); do
    screen | grep -q -- "$1" && return 0
    sleep 1
  done
  return 1
}
wait_gone() {  # <grep pattern> <seconds>; text typed right after Escape reads as Alt+key, so wait for it to take
  local i
  for i in $(seq 1 "$2"); do
    screen | grep -q -- "$1" || return 0
    sleep 1
  done
  return 1
}
ask() { tmux send-keys -t "$W" -l "$1"; sleep 1; tmux send-keys -t "$W" Enter; }
watch_lab() {  # <out> -> background watcher pid in WATCHER
  JG_HOME="$LAB" SIGN_OFF_HOME="$LAB/signoff" JG_POLL=2 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 \
    "$ROOT/bin/jg-watch.sh" > "$1" 2>&1 &
  WATCHER=$!
}
drain_lab() {  # Main reads and acknowledges its wakes, so a re-armed watcher supervises instead of re-announcing them
  local ack ack_args
  JG_HOME="$LAB" JG_STATE_OVERRIDE="$LAB/state" "$ROOT/bin/jg-wake-drain.sh" >/dev/null 2>"$TMP_ROOT/drain.err" || return 0
  ack=$(sed -n 's/^WAKE_ACK_REQUIRED: *//p' "$TMP_ROOT/drain.err")
  read -ra ack_args <<< "${ack#*jg-wake-drain.sh}"
  [ -z "$ack" ] || JG_HOME="$LAB" JG_STATE_OVERRIDE="$LAB/state" "$ROOT/bin/jg-wake-drain.sh" "${ack_args[@]}" >/dev/null 2>&1 || true
}

mkdir -p "$LEAD" "$LAB/state/lead1.inbox" "$LAB/signoff" "$LAB/projects"
printf 'schema=jg-task-inbox.v1\n--\nhello-from-the-parent\n' > "$LAB/state/lead1.inbox/001.msg"
printf 'parent-private-note\n' > "$LAB/data/notes.txt"
git -C "$LEAD" init -q
note "opencode $(opencode --version 2>/dev/null), model $MODEL"

# Launch, finish one turn, exit, then hand-restart with no grant.
tmux new-session -d -s jglab -n jg-lead1 -x 160 -y 50 -c "$LEAD" \
  "env -u OPENCODE_CONFIG_CONTENT opencode --model $MODEL --prompt 'Reply with just the word ready.'"
wait_screen '▣  Build · .* · ' 90 || fail "first OpenCode turn never finished"
ask /exit
sleep 3
tmux new-session -d -s jglab -n jg-lead1 -x 160 -y 50 -c "$LEAD" \
  "env -u OPENCODE_CONFIG_CONTENT opencode --continue --model $MODEL"
wait_screen 'ready' 30 || fail "hand-restarted lead did not resume its session"
printf 'window=%s\nendpoint_task_id=lead1\nworktree=%s\nhome=%s\nharness=opencode\nkind=squad_lead\nmode=squad_lead\nyolo=off\nbackend=tmux\n' \
  "$W" "$LEAD" "$LEAD" > "$LAB/state/lead1.meta"

test_inbox_read_is_approved_and_logged() {
  ask "Use your read tool to read the file $LAB/state/lead1.inbox/001.msg and print its last line. Do nothing else."
  wait_screen 'Permission required' 90 || fail "the inbox read raised no permission prompt"
  watch_lab "$TMP_ROOT/watch1.out"
  wait_screen 'hello-from-the-parent' 60 || { screen; cat "$TMP_ROOT/watch1.out"; fail "the inbox read was not approved"; }
  kill "$WATCHER" 2>/dev/null; wait "$WATCHER" 2>/dev/null; WATCHER=
  jq -e --arg p "$LAB/state/lead1.inbox/001.msg" 'select(.path == $p and .root == "inbox" and .tool == "read")' \
    "$LAB/state/prompt-approvals.jsonl" >/dev/null || fail "the approval was not logged: $(cat "$LAB/state/prompt-approvals.jsonl" 2>&1)"
  JG_HOME="$LAB" "$ROOT/bin/jg-fleet-view.sh" 2>/dev/null | grep -F "$LAB/state/lead1.inbox/001.msg" >/dev/null \
    || fail "the fleet view does not show the approval"
  pass "a hand-restarted lead's inbox read is approved, logged, and shown in the fleet view"
}

test_outside_read_wakes_main_once() {
  printf 'outside-note\n' > "$LAB/projects/notes.txt"
  ask "Use your read tool to read the file $LAB/projects/notes.txt and print it. Do nothing else."
  wait_screen 'Permission required' 90 || fail "the outside read raised no permission prompt"
  local i
  for i in 1 2 3 4 5; do  # a killed watcher's successor first reports its re-arm
    watch_lab "$TMP_ROOT/watch2.$i.out"
    wait "$WATCHER"; WATCHER=
    cat "$TMP_ROOT/watch2.$i.out" >> "$TMP_ROOT/watch2.out"
    grep -q 'permission prompt' "$TMP_ROOT/watch2.$i.out" && break
  done
  grep -F "stale: $W (permission prompt: Access external directory $LAB/projects" "$TMP_ROOT/watch2.out" \
    | grep -F "not answered: outside this fleet's own roots" >/dev/null \
    || fail "the watcher did not wake with the prompt: $(cat "$TMP_ROOT/watch2.out")"
  grep -qF "prompt: Access external directory $LAB/projects" "$LAB/state/.wait-sources/lead1.prompt" \
    || fail "the prompt was not handed to the escalation chain"
  screen | grep -q 'Permission required' || fail "the outside read prompt was answered"
  ! screen | grep -q 'outside-note' || fail "the outside read went through"
  tmux send-keys -t "$W" Escape
  wait_gone 'Permission required' 30 || fail "the outside read prompt did not close"
  pass "a read outside the fleet's roots wakes Main once and rides the escalation chain, never an approval"
}

test_data_read_is_rejected() {
  ask "Use your read tool to read the file $LAB/data/notes.txt and print it. Do nothing else."
  wait_screen 'Permission required' 90 || fail "the data read raised no permission prompt"
  screen > "$TMP_ROOT/data-prompt.txt"
  local i
  drain_lab
  watch_lab "$TMP_ROOT/watch3.0.out"
  for i in $(seq 1 60); do  # a watcher that exits on another wake is re-armed
    grep -qF "rejected permission prompt (secrets path): $W" "$LAB/state/.watch-triage.log" 2>/dev/null \
      && grep -rqF "Supervision rejected your permission prompt" "$LAB/state/lead1.inbox" && break
    if ! kill -0 "$WATCHER" 2>/dev/null; then
      wait "$WATCHER"
      drain_lab
      watch_lab "$TMP_ROOT/watch3.$i.out"
    fi
    sleep 1
  done
  kill "$WATCHER" 2>/dev/null; wait "$WATCHER" 2>/dev/null; WATCHER=
  cat "$TMP_ROOT"/watch3.*.out > "$TMP_ROOT/watch3.out"
  wait_gone 'Permission required' 30 || true
  ! screen | grep -q 'Permission required' || fail "the data read prompt was not rejected: $(cat "$TMP_ROOT/watch3.out") screen at the prompt: $(cat "$TMP_ROOT/data-prompt.txt")"
  ! screen | grep -q 'parent-private-note' || fail "the data read went through"
  grep -F "rejected permission prompt (secrets path): $W $LAB/data" "$LAB/state/.watch-triage.log" >/dev/null \
    || fail "the rejection was not logged: $(tail -5 "$LAB/state/.watch-triage.log" 2>&1) $(cat "$TMP_ROOT/watch3.out") screen at the prompt: $(cat "$TMP_ROOT/data-prompt.txt")"
  grep -rqF "Supervision rejected your permission prompt" "$LAB/state/lead1.inbox" \
    || fail "the lead was not told why: $(grep -F "$W" "$LAB/state/.watch-triage.log" | tail -3)"
  pass "a read of a home's data/ is rejected and the lead is told why"
}

test_inbox_read_is_approved_and_logged
test_outside_read_wakes_main_once
test_data_read_is_rejected
