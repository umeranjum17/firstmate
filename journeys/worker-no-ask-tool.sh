#!/usr/bin/env bash
# done-done journey: a real Claude worker (Haiku) told to ask the human a question. With the flag
# bin/jg-spawn.sh puts on every worker launch it has no ask tool and no dialog opens; the control
# pane launched without it opens the dialog.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
export TMUX_TMPDIR=$T/tmux
mkdir -p "$TMUX_TMPDIR" "$T/work"
trap 'tmux kill-server 2>/dev/null; rm -rf -- "$T"' EXIT
log() { printf '%s\n' "$*" | tee -a "$OUT/replay.txt"; }
fail() { log "FAIL: $*"; exit 1; }
: > "$OUT/replay.txt"
FLAG=$(grep -o -e '--disallowedTools=AskUserQuestion' "$REPO/bin/jg-spawn.sh" | head -1)
[ -n "$FLAG" ] || fail "bin/jg-spawn.sh carries no ask-tool flag for a worker"
log "worker launch flag from bin/jg-spawn.sh: $FLAG"
ASK='Call the AskUserQuestion tool right now with one question: Which color? options Red and Blue. If you have no such tool, reply exactly NO-ASK-TOOL and nothing else.'
tmux new-session -d -s lab -n control -x 150 -y 45 -c "$T/work" \
  "claude --model claude-haiku-5-5 --dangerously-skip-permissions '$ASK'"
tmux new-window -t lab -n worker -c "$T/work" \
  "claude --model claude-haiku-5-5 --dangerously-skip-permissions $FLAG '$ASK'"
for _ in $(seq 1 60); do tmux capture-pane -p -t lab:control | grep -q 'Enter to select' && break; sleep 1; done
for _ in $(seq 1 60); do tmux capture-pane -p -t lab:worker | grep -q 'NO-ASK-TOOL' && break; sleep 1; done
tmux capture-pane -p -t lab:control > "$OUT/pane-control.txt"
tmux capture-pane -p -t lab:worker > "$OUT/pane-worker.txt"
grep -q 'Enter to select' "$OUT/pane-control.txt" || fail "the control worker never opened its question dialog"
log "control (no flag): the question dialog opened"
! grep -q 'Enter to select' "$OUT/pane-worker.txt" || fail "the worker with the flag still opened a dialog"
grep -q 'NO-ASK-TOOL' "$OUT/pane-worker.txt" || fail "the worker with the flag neither asked nor reported it has no ask tool"
log "worker (flag): no dialog opened and the worker reported it has no ask tool"
jq -n --arg v "$(claude --version 2>/dev/null | head -1)" '{target:{version:("claude " + $v)},
  start:"a real Claude Haiku worker launched with the ask-tool flag, and a control launched without it",
  steps:["both workers are told to ask the human a question","the control opens a question dialog","the flagged worker opens no dialog and reports it has no ask tool"],
  result:"the worker launched like a Juggernaut worker cannot put a question dialog in front of the human"}' > "$OUT/steps.json"
log "PASS"
