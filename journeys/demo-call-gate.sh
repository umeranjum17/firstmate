#!/usr/bin/env bash
# done-done journey: scaffold real ship briefs with bin/jg-brief.sh (demo call yes, no, absent, switch on and off),
# then run the real jg_dod_demo_gate from bin/jg-merge-gate-lib.sh on a task record per brief.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
HEAD_SHA=1111111111111111111111111111111111111111
mkdir -p "$T/home/data" "$T/home/state" "$T/home/config"
export JG_HOME="$T/home"
jg_dod_meta_value() { sed -n "s/^$2=//p" "$1" | tail -1; }
# shellcheck source=bin/jg-merge-gate-lib.sh
. "$REPO/bin/jg-merge-gate-lib.sh"
expect() {  # <label> <want> <got>
  [ "$2" = "$3" ] || { echo "FAIL $1: want [$2] got [$3]"; : > "$T/fails"; }
}
scaffold() {  # <id> [brief flags...]
  local id=$1; shift
  "$REPO/bin/jg-brief.sh" "$id" some-proj --mode direct-PR "$@" >/dev/null
}
record() {  # <id>: the task record the spawn writes, from the brief's call line
  local id=$1 call
  call=$(sed -n -E 's/^Demo-video call \(TakeOne\): (yes|no)( - .*)?$/\1/p' "$T/home/data/$id/brief.md" | head -1)
  printf 'worktree=%s\n' "$T" > "$T/home/state/$id.meta"
  [ -z "$call" ] || echo "demo_call=$call" >> "$T/home/state/$id.meta"
}
receipt() {  # <id> <evidence>
  jq -n --arg t "$1" --arg h "$HEAD_SHA" --arg e "$2" '{schema:1,task:$t,head:$h,verdict:"PASS",evidence:$e,at:1}' > "$T/home/state/$1.run-receipt.json"
}
gate() { jg_dod_demo_gate "$T/home/config" "$T/home/state" "$1" "$T/home/state/$1.meta" "$HEAD_SHA" 2>&1; echo "exit=$?"; }
{
  echo "--- switch off: the brief carries no demo line, the gate is silent"
  scaffold t-off --demo-call yes --demo-reason "launch video"
  [ -z "$(grep -h '^Demo-video call' "$T/home/data/t-off/brief.md")" ] || expect off-no-line "none" "a demo line"
  record t-off; echo "demo_call=yes" >> "$T/home/state/t-off.meta"
  out=$(gate t-off); echo "$out"; expect off-gate "exit=0" "$(echo "$out" | tail -1)"
  : > "$T/home/config/takeone-demo"
  scaffold t-yes --demo-call yes --demo-reason "launch video"
  scaffold t-no --demo-call no --demo-reason "no video in this task"
  scaffold t-old
  grep -h "^Demo-video call" "$T"/home/data/t-yes/brief.md "$T"/home/data/t-no/brief.md
  for i in t-yes t-no t-old; do record "$i"; done
  echo "--- on, yes, no receipt";           out=$(gate t-yes); echo "$out"; expect yes-no-receipt "exit=1" "$(echo "$out" | tail -1)"
  receipt t-yes "ran tests only"
  echo "--- on, yes, receipt without line"; out=$(gate t-yes); echo "$out"; expect yes-no-line "exit=1" "$(echo "$out" | tail -1)"
  receipt t-yes $'ran tests\nfirst-draft receipt: fd-0001'
  echo "--- on, yes, first-draft line only"; out=$(gate t-yes); echo "$out"; expect yes-wrong-line "exit=1" "$(echo "$out" | tail -1)"
  receipt t-yes $'ran tests\ntakeone receipt: to-0001'
  echo "--- on, yes, takeone line";         out=$(gate t-yes); echo "$out"; expect yes-with-line "exit=0" "$(echo "$out" | tail -1)"
  echo "--- on, no";                        out=$(gate t-no);  echo "$out"; expect no "exit=0" "$(echo "$out" | tail -1)"
  echo "--- on, missing (older brief)";     out=$(gate t-old); echo "$out"; expect missing "exit=0" "$(echo "$out" | tail -1)"
  case $out in *"counting it as demo_call=no"*) ;; *) echo "FAIL missing: no warning"; : > "$T/fails" ;; esac
} 2>&1 | tee "$OUT/demo-call-gate-transcript.txt"
cat > "$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut bin/jg-brief.sh and bin/jg-merge-gate-lib.sh at this commit"},
 "start":"a disposable juggernaut home with the TakeOne switch off",
 "steps":["scaffold a yes brief with the switch off and run the gate","turn the switch on with config/takeone-demo and scaffold briefs with demo call yes, no and none","run the demo gate on a yes task with no receipt, a receipt without a line, a first-draft line only, and a takeone receipt line","run the gate on a no task and on a task with no recorded call"],
 "result":"with the switch off nothing is checked; with it on, the yes task is refused until its receipt carries a takeone receipt line; the no task passes; the older task warns and passes"}
J
status=0
[ -e "$T/fails" ] && status=1
rm -rf -- "$T"
exit "$status"
