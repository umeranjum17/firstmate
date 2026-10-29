#!/usr/bin/env bash
# Integration journey for jg-board-inputs.sh against a fake board and a fake sign-off-axi.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
export JG_HOME=$TMP/home JG_CODE_ROOT=$TMP/home JG_STATE_OVERRIDE=$TMP/home/state JG_CONFIG_OVERRIDE=$TMP/home/config
S=$JG_HOME/state
mkdir -p "$JG_HOME"/{bin,state/inbox/handled,config} "$TMP/b"
cat > "$JG_HOME/bin/jg-task-inbox-lib.sh" <<'SH'
jg_task_inbox_write_idempotent() {
  local dir="$1/$2.inbox" f; mkdir -p "$dir/handled"
  f="$dir/$(printf '%s' "$3" | sha256sum | cut -c1-12).msg"
  [ -e "$f" ] || [ -e "$dir/handled/${f##*/}" ] || printf '%s' "$3" > "$f"
  printf '%s' "$f"
}
jg_backend_of_meta() { echo fixture; }
jg_backend_target_of_meta() { echo target; }
jg_task_inbox_ring() { return 0; }
SH
# Fake jg-inbox: a note is a pending file; `ack` moves it to handled.
cat > "$JG_HOME/bin/jg-inbox.sh" <<'SH'
#!/usr/bin/env bash
rid=$3; mkdir -p "$JG_STATE_OVERRIDE/inbox/.requests"
[ -e "$JG_STATE_OVERRIDE/inbox/.requests/$rid" ] || { echo "n-$rid" > "$JG_STATE_OVERRIDE/inbox/.requests/$rid"; : > "$JG_STATE_OVERRIDE/inbox/n-$rid.note"; }
SH
mkdir -p "$TMP/path"
cat > "$TMP/path/sign-off-axi" <<'SH'
#!/usr/bin/env bash
case $1 in
  list) printf '{"decisions":[{"key":"rep","filer":"task-a"},{"key":"ask","filer":"uuid-nobody"},{"key":"old","filer":"task-a"}]}' ;;
  feedback) shift; printf '%s\n' "$*" >> "$CALLS" ;;
esac
SH
chmod +x "$JG_HOME/bin/jg-inbox.sh" "$TMP/path/sign-off-axi"
export PATH=$TMP/path:$PATH CALLS=$TMP/calls
printf 'kind=ship\n' > "$S/task-a.meta"
B=$TMP/b/board.json; : > "$B"
echo '{"id":"v1","key":"rep","part":"understood","verdict":"agree","at":"2026-10-29T04:00:00Z"}
{"id":"c1","key":"rep","part":"next","text":"Yes makes sense","at":"2026-10-29T04:01:00Z"}
{"id":"o1","key":"old","part":"x","verdict":"agree","at":"2026-09-01T00:00:00Z"}' > "$TMP/b/board.annotations.jsonl"
echo '{"key":"ask","answer":"text","label":"Reply","close":"done","at":"2026-10-29T04:02:00Z","note":"How will you trim it?"}
{"key":"gone","answer":"yes","label":"Yes","at":"2026-10-29T04:03:00Z"}' > "$TMP/b/board.answers.jsonl"
relay() { JG_BOARD_INPUT_NOW=$1 "$ROOT/bin/jg-board-inputs.sh" relay "$B"; }
T0=$(date -d 2026-10-29T04:05:00Z +%s)

relay "$T0"
# Delivered: verdict and comment reach task-a, the text reply reaches Main; stale and removed cards do not.
[ "$(grep -l 'v1\|c1' "$S"/task-a.inbox/*.msg | wc -l)" -eq 2 ]
[ -e "$S/inbox/n-signoff-input-ask@2026-10-29T04:02:00Z.note" ]
[ "$(grep -c '^sent' "$S/signoff-inputs")" -eq 3 ]
[ "$(grep -c -- '--delivered' "$CALLS")" -eq 3 ]
relay "$T0"                                   # a second round sends nothing new
[ "$(grep -c '^sent' "$S/signoff-inputs")" -eq 3 ]
[ "$(find "$S/task-a.inbox" -name '*.msg' | wc -l)" -eq 2 ]
[ "$(grep -c "^read" "$S/signoff-inputs" || true)" -eq 0 ]

# Read: task-a handles one message and Main acks the note.
f=$(grep -l v1 "$S"/task-a.inbox/*.msg); mv "$f" "$S/task-a.inbox/handled/"
mv "$S"/inbox/n-signoff-input-ask*.note "$S/inbox/handled/"
relay "$((T0 + 60))"
[ "$(grep -c '^read' "$S/signoff-inputs")" -eq 2 ]
grep -q '^rep .*--read' "$CALLS"; grep -q '^ask .*--read' "$CALLS"

# Replied: sign-off's trail shows replies on both cards, so only the unread c1 escalates below.
printf '%s\n' '{"op":"reply","key":"rep","text":"ok"}' '{"op":"reply","key":"ask","text":"ok"}' > "$TMP/b/board.trail.jsonl"

# Escalation: c1 sits unread 31 min, Main gets exactly one note.
relay "$((T0 + 1860))"; relay "$((T0 + 1900))"
[ "$(grep -c '^escalated' "$S/signoff-inputs")" -eq 1 ]
[ "$(find "$S/inbox/.requests" -name "*unread" | wc -l)" -eq 1 ]
echo 'board-inputs fixture journey passed'
