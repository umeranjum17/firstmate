#!/usr/bin/env bash
# done-done journey: scaffold real ship briefs with bin/jg-brief.sh (design call yes, no, absent),
# then run the real jg_dod_design_gate from bin/jg-merge-gate-lib.sh on a task record per brief.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
HEAD_SHA=1111111111111111111111111111111111111111
mkdir -p "$T/home/data" "$T/home/state"
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
  call=$(sed -n -E 's/^Design call \(first-draft\): (yes|no)( - .*)?$/\1/p' "$T/home/data/$id/brief.md" | head -1)
  printf 'worktree=%s\n' "$T" > "$T/home/state/$id.meta"
  [ -z "$call" ] || echo "design_call=$call" >> "$T/home/state/$id.meta"
}
receipt() {  # <id> <evidence>
  jq -n --arg t "$1" --arg h "$HEAD_SHA" --arg e "$2" '{schema:1,task:$t,head:$h,verdict:"PASS",evidence:$e,at:1}' > "$T/home/state/$1.run-receipt.json"
}
gate() { jg_dod_design_gate "$T/home/state" "$1" "$T/home/state/$1.meta" "$HEAD_SHA" 2>&1; echo "exit=$?"; }
{
  scaffold t-yes --design-call yes --design-reason "new landing page"
  scaffold t-no --design-call no --design-reason "one-line copy fix"
  scaffold t-old
  grep -h "^Design call" "$T"/home/data/t-*/brief.md
  for i in t-yes t-no t-old; do record "$i"; done
  echo "--- yes, no receipt";            out=$(gate t-yes); echo "$out"; expect yes-no-receipt "exit=1" "$(echo "$out" | tail -1)"
  receipt t-yes "ran tests only"
  echo "--- yes, receipt without line";  out=$(gate t-yes); echo "$out"; expect yes-no-line "exit=1" "$(echo "$out" | tail -1)"
  jq -n '{made:{command:"make",files:[{file:"designs/option-1.html"}]}}' > "$T/fd-0001"
  receipt t-yes $'ran tests\nfirst-draft receipt: fd-0001'
  echo "--- yes, receipt with a first-draft make record"; out=$(gate t-yes); echo "$out"; expect yes-with-line "exit=0" "$(echo "$out" | tail -1)"
  echo "--- no";                         out=$(gate t-no);  echo "$out"; expect no "exit=0" "$(echo "$out" | tail -1)"
  echo "--- missing (older brief)";      out=$(gate t-old); echo "$out"; expect missing "exit=0" "$(echo "$out" | tail -1)"
  case $out in *"counting it as design_call=no"*) ;; *) echo "FAIL missing: no warning"; : > "$T/fails" ;; esac
} 2>&1 | tee "$OUT/design-call-gate-transcript.txt"
cat > "$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut bin/jg-brief.sh and bin/jg-merge-gate-lib.sh at this commit"},
 "start":"a disposable juggernaut home",
 "steps":["scaffold ship briefs with design call yes, no and none","run the design gate on a yes task with no receipt, a receipt without the first-draft line, and a receipt whose line names a first-draft make record","run the gate on a no task and on a task with no recorded call"],
 "result":"the yes task is refused until its receipt carries a first-draft receipt line that names a make record; the no task passes; the older task warns and passes"}
J
status=0
[ -e "$T/fails" ] && status=1
rm -rf -- "$T"
exit "$status"
