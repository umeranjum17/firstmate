#!/usr/bin/env bash
# done-done journey: scaffold real ship briefs with bin/jg-brief.sh (UI change yes, no, absent),
# then run the real jg_dod_nav_gate from bin/jg-merge-gate-lib.sh on a task record per brief
# against PR bodies that keep, add, rename, drop and captain-remove a menu.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
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
record() {  # <id>: the task record the spawn writes, from the brief's UI line
  local id=$1 call
  call=$(sed -n -E 's/^UI change \(nav-check\): (yes|no)$/\1/p' "$T/home/data/$id/brief.md" | head -1)
  : > "$T/home/state/$id.meta"
  [ -z "$call" ] || echo "ui_change=$call" > "$T/home/state/$id.meta"
}
gate() {  # <id> <pr body>
  jg_dod_nav_gate "$1" "$T/home/state/$1.meta" "$2" 2>&1; echo "exit=$?"
}
check() {  # <label> <want exit> <id> <body>
  local out
  echo "--- $1"; out=$(gate "$3" "$4"); echo "$out"; expect "$1" "exit=$2" "$(echo "$out" | tail -1)"
}
{
  scaffold t-yes --ui-change yes
  scaffold t-no --ui-change no
  scaffold t-old
  grep -h "^UI change\|^Nav before\|^Nav after\|^An item in before" "$T"/home/data/t-yes/brief.md
  for i in t-yes t-no t-old; do record "$i"; done
  BEFORE=$'Nav before: Home, Inbox, Settings'
  check "yes, no nav lines" 1 t-yes "prose only"
  check "yes, nav kept and one added" 0 t-yes "$BEFORE"$'\nNav after: Home, Inbox, Settings, Reports'
  check "yes, Settings silently dropped" 1 t-yes "$BEFORE"$'\nNav after: Home, Inbox'
  check "yes, Settings renamed" 1 t-yes "$BEFORE"$'\nNav after: Home, Inbox, Preferences'
  check "yes, Settings dropped with captain words" 0 t-yes "$BEFORE"$'\nNav after: Home, Inbox\nRemoved by captain words: "drop Settings"'
  check "no task is unaffected" 0 t-no "prose only"
  out=$(gate t-old "prose only"); echo "--- older brief"; echo "$out"
  expect older "exit=0" "$(echo "$out" | tail -1)"
  case $out in *"counting it as ui_change=no"*) ;; *) echo "FAIL older: no warning"; : > "$T/fails" ;; esac
} 2>&1 | tee "$OUT/nav-removal-gate-transcript.txt"
cat > "$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut bin/jg-brief.sh and bin/jg-merge-gate-lib.sh at this commit"},
 "start":"a disposable juggernaut home",
 "steps":["scaffold ship briefs with UI change yes, no and none","run the nav gate on a yes task with no nav lines, a kept menu, a dropped menu, a renamed menu and a dropped menu with captain words","run the gate on a no task and on a task with no recorded UI call"],
 "result":"the yes task is refused when the PR body has no nav lines or drops or renames a menu without captain words; it passes otherwise; the no task passes; the older task warns and passes"}
J
status=0
[ -e "$T/fails" ] && status=1
rm -rf -- "$T"
exit "$status"
