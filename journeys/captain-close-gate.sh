#!/usr/bin/env bash
# done-done journey: the real bin/jg-tasks-axi.sh against a real tasks-axi backlog. A [captain-ask]
# ticket with no delivery cannot be closed, cancelled or deleted without the captain's quoted words
# or an answered confirm card; an ordinary ticket is unaffected; the quote lands in the ticket note.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
mkdir -p "$T/code/data" "$T/home/data" "$T/home/state" "$T/home/config"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$T/home/data/backlog.md"
ln -s "$T/home/data/backlog.md" "$T/code/data/backlog.md"
cp "$REPO/.tasks.toml" "$T/code/.tasks.toml"
export JG_TASK_PRIORITY_CHECK=/nonexistent JG_HOME="$T/home" JG_ROOT_OVERRIDE="$T/code"
unset TASKS_AXI_FILE JG_DATA_OVERRIDE JG_STATE_OVERRIDE
jg() { (cd "$T/code" && "$REPO/bin/jg-tasks-axi.sh" "$@"); }
hold() { (cd "$T/code" && "$REPO/bin/jg-captain-hold.sh" "$@"); }
expect() {  # <label> <want rc> <got rc>
  [ "$2" = "$3" ] || { echo "FAIL $1: want exit $2 got $3"; echo x >> "$T/fails"; }
}
step() {  # <label> <want rc> <args...>
  local label=$1 want=$2 rc=0; shift 2
  echo "--- $label"; jg "$@" 2>&1 | sed 's/^/    /'; rc=${PIPESTATUS[0]}
  expect "$label" "$want" "$rc"
}
{
  for id in rejected quoted carded plain; do jg add "$id" "$([ $id = plain ] && echo ordinary || echo "[captain-ask] $id")" >/dev/null; done
  printf 'Yes.\n' > "$T/answer.txt"
  jg add card-1 "[captain-ask] confirm closing carded" >/dev/null
  jg add card-2 "[captain-ask] confirm closing rejected" >/dev/null
  hold hold card-2 --reason "confirm" >/dev/null
  hold hold card-1 --reason "confirm" >/dev/null && hold answer card-1 --decision-file "$T/answer.txt" >/dev/null
  step "cancel a captain-asked ticket, no words" 2 rm rejected
  step "close it, no words" 2 "done" --no-prune rejected
  step "blank quote" 2 rm --captain-quote "  " rejected
  step "card that names it but is not answered" 2 rm --confirm-card card-2 rejected
  step "its own recorded answer is not a confirm card" 2 "done" --no-prune --confirm-card carded carded
  step "card that names another ticket" 2 "done" --no-prune --confirm-card card-1 rejected
  step "quote closes it" 0 rm --captain-quote "yes, cancel the rejected ticket" quoted
  step "answered card closes it" 0 "done" --no-prune --confirm-card card-1 carded
  step "ordinary ticket unaffected" 0 rm plain
  echo "--- the record"
  cat "$T/home/data/captain-closures.md"
  grep -q "captain words: yes, cancel the rejected ticket" "$T/home/data/captain-closures.md" || { echo "FAIL: quote not recorded"; echo x >> "$T/fails"; }
  jg show carded --full | grep -q "Closed on answered board confirm card: card-1" || { echo "FAIL: card not in ticket note"; echo x >> "$T/fails"; }
  grep -q "rejected" "$T/home/data/backlog.md" || { echo "FAIL: refused ticket left the backlog"; echo x >> "$T/fails"; }
} 2>&1 | tee "$OUT/captain-close-gate-transcript.txt"
cat > "$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut bin/jg-tasks-axi.sh and bin/jg-captain-ask-lib.sh at this commit"},
 "start":"a disposable juggernaut home with a real tasks-axi backlog",
 "steps":["try to cancel and close a captain-asked ticket with no words, a blank quote and an unanswered card","close one with a quote and one with an answered confirm card","remove an ordinary ticket"],
 "result":"the captain-asked ticket stays until his words or an answered card are given, and the words are recorded; an ordinary ticket is unaffected"}
J
status=0
[ -e "$T/fails" ] && status=1
rm -rf -- "$T"
exit "$status"
