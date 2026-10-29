#!/usr/bin/env bash
# done-done journey: real pi, codex and OpenCode TUIs in a private tmux server. Pi and codex (Plan
# mode) are told to ask the human a question and open their own dialog; OpenCode is sent a prompt and
# shows either its question dialog or, when its provider quota is spent, its quota banner. Each pane
# goes through the real jg_stuck_verdict, which must name the cause on screen.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
export TMUX_TMPDIR=$T/tmux
mkdir -p "$TMUX_TMPDIR" "$T/work"
trap 'tmux kill-server 2>/dev/null; rm -rf -- "$T"' EXIT
log() { printf '%s\n' "$*" | tee -a "$OUT/replay.txt"; }
fail() { log "FAIL: $*"; exit 1; }
# shellcheck source=bin/jg-stuck-gate-lib.sh
. "$REPO/bin/jg-stuck-gate-lib.sh"
: > "$OUT/replay.txt"
ASK='Call your ask user question tool right now with one question: Which color? options Red and Blue. Do nothing else.'
tmux new-session -d -s lab -n pi -x 150 -y 45 -c "$T/work" "pi --model openai-codex/gpt-6-luna '$ASK'"
tmux new-window -t lab -n codex -c "$T/work" "codex --model gpt-5.6-luna -c model_reasoning_effort=low --dangerously-bypass-approvals-and-sandbox"
tmux new-window -t lab -n opencode -c "$T/work" \
  "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode --model opencode/beam-free --prompt '$ASK'"
# Clear codex's start-up dialogs by what is on screen (never a blind Enter: its update dialog's
# default is "Update now", which runs npm install -g): skip an update, trust the scratch folder.
for _ in $(seq 1 40); do
  pane=$(tmux capture-pane -p -t lab:codex)
  case "$pane" in
    *"Update available"*) tmux send-keys -t lab:codex Escape ;;
    *"Trust and continue"*) tmux send-keys -t lab:codex Enter ;;
    *"OpenAI Codex (v"*) break ;;
  esac
  sleep 1
done
sleep 3
tmux send-keys -t lab:codex '/plan' Enter
sleep 3
tmux send-keys -t lab:codex "$ASK" Enter
sleep 5
tmux send-keys -t lab:opencode Enter; sleep 2; tmux send-keys -t lab:opencode Enter
verdict_of() {  # <window> <capture-file> <want-regex>: wait up to 90s for the verdict
  local w=$1 f=$2 want=$3 v=
  for _ in $(seq 1 90); do
    tmux capture-pane -p -t "lab:$w" | sed 's/[[:space:]]*$//' > "$f"
    v=$(jg_stuck_verdict < "$f")
    case "${v%%$'\t'*}" in "$want") break ;; esac
    sleep 1
  done
  printf '%s' "$v"
}
v=$(verdict_of pi "$OUT/pane-pi.txt" 'question'); [ "${v%%$'\t'*}" = question ] || fail "pi: no question verdict (got: ${v:-none})"
log "pi: question dialog on screen, verdict: ${v#*$'\t'}"
v=$(verdict_of codex "$OUT/pane-codex.txt" 'question'); [ "${v%%$'\t'*}" = question ] || fail "codex: no question verdict (got: ${v:-none})"
log "codex: Plan mode question dialog on screen, verdict: ${v#*$'\t'}"
v=$(verdict_of opencode "$OUT/pane-opencode.txt" '(question|quota)'); [ -n "$v" ] || fail "opencode: neither a question dialog nor a quota banner was detected"
log "opencode: ${v%%$'\t'*} on screen, verdict: ${v#*$'\t'}"
jq -n --arg p "$(pi --version 2>&1 | head -1)" --arg c "$(codex --version | head -1)" --arg o "$(opencode --version | head -1)" '{target:{version:("pi " + $p + ", " + $c + ", opencode " + $o)},
  start:"three real runtimes launched in a private tmux server",
  steps:["pi is told to ask a question and opens its dialog","codex is put in Plan mode and opens its question dialog","opencode shows its question dialog or its provider quota banner","each pane is read by jg_stuck_verdict"],
  result:"the stuck-worker matcher names the question or quota cause for each real runtime"}' > "$OUT/steps.json"
log "PASS"
