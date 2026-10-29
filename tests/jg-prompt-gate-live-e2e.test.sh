#!/usr/bin/env bash
# Live guard for the permission-prompt gate (live-harness-optin family): the
# matcher reads OpenCode's rendered dialog, so per juggernaut-coding-guidelines
# "Harness-dependent checks" it is proven against the real installed binary.
# A squad_lead is hand-restarted the way an operator does it (`opencode
# --continue`, no OPENCODE_CONFIG_CONTENT grant) in a lab home on a private
# tmux server, and the real watcher runs over it:
#   - a read of the lead's parent steering inbox is approved, logged in
#     state/prompt-approvals.jsonl, shown by the fleet view, and the read lands;
#   - a read of the parent's data/ is not approved: the watcher wakes with the
#     prompt, its path, and a card on a scratch sign-off board.
# It submits prompts to a free OpenCode model, so it is opt-in:
# JG_PROMPT_GATE_LIVE=1 (JG_PROMPT_GATE_MODEL overrides the model).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

jg_live_gate opt-in JG_PROMPT_GATE_LIVE opencode tmux sign-off-axi

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
ask() { tmux send-keys -t "$W" -l "$1"; sleep 1; tmux send-keys -t "$W" Enter; }
watch_lab() {  # <out> -> background watcher pid in WATCHER
  JG_HOME="$LAB" SIGN_OFF_HOME="$LAB/signoff" JG_POLL=2 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 \
    "$ROOT/bin/jg-watch.sh" > "$1" 2>&1 &
  WATCHER=$!
}

mkdir -p "$LEAD" "$LAB/state/lead1.inbox" "$LAB/signoff"
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

test_data_read_is_a_card() {
  ask "Use your read tool to read the file $LAB/data/notes.txt and print it. Do nothing else."
  wait_screen 'Permission required' 90 || fail "the data read raised no permission prompt"
  local i
  for i in 1 2 3 4 5; do  # a killed watcher's successor first reports its re-arm
    watch_lab "$TMP_ROOT/watch2.$i.out"
    wait "$WATCHER"; WATCHER=
    cat "$TMP_ROOT/watch2.$i.out" >> "$TMP_ROOT/watch2.out"
    grep -q 'permission prompt' "$TMP_ROOT/watch2.$i.out" && break
  done
  grep -F "stale: $W (permission prompt: Access external directory $LAB/data" "$TMP_ROOT/watch2.out" \
    | grep -F "not auto-approved: outside this fleet's own roots; card prompt-gate-lead1-" >/dev/null \
    || fail "the watcher did not wake with the prompt and its card: $(cat "$TMP_ROOT/watch2.out")"
  SIGN_OFF_HOME="$LAB/signoff" sign-off-axi list --json | jq -e '[.decisions[]? | select(.key | startswith("prompt-gate-lead1-"))] | length == 1' >/dev/null \
    || fail "no card for the prompt on the board"
  screen | grep -q 'Permission required' || fail "the data read prompt was answered"
  ! screen | grep -q 'parent-private-note' || fail "the data read went through"
  pass "a read outside the fleet's roots is a card and a wake, never an approval"
}

test_inbox_read_is_approved_and_logged
test_data_read_is_a_card
