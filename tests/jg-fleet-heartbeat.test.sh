#!/usr/bin/env bash
# tests/jg-fleet-heartbeat.test.sh - one shell pass proves every home in the fleet
# is moving, and its check wakes Main on a gap until the gap closes
# (bin/jg-fleet-heartbeat.sh).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-fleet-heartbeat)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
HB="$ROOT/bin/jg-fleet-heartbeat.sh"

lane() {  # <home> <task> <last status line>
  printf 'kind=ship\n' > "$1/state/$2.meta"
  printf '%s\n' "$3" > "$1/state/$2.status"
}

home() {  # <dir> <ready> [target] -> a home whose watcher beat just now
  mkdir -p "$1/state" "$1/config"
  printf '{"ready_work":%s}\n' "$2" > "$1/state/home-summary.json"
  [ -z "${3-}" ] || printf '%s\n' "$3" > "$1/config/lane-target"
  touch "$1/state/.last-watcher-beat"
}

setup() {  # <name> -> a primary home with three local Squad Leads and one remote
  local d=$TMP_ROOT/$1
  home "$d/main" 0
  mkdir -p "$d/main/data"
  lane "$d/main" ship-a 'working [at=1]: building'
  home "$d/leads/gappy" 3 2
  lane "$d/leads/gappy" g1 'working [at=1]: building'
  lane "$d/leads/gappy" g2 'paused [at=1]: waiting on CI until 2026-10-30T09:00Z'
  home "$d/leads/quiet" 0
  lane "$d/leads/quiet" q1 'done [at=1]: PR https://example.test/pr/1'
  home "$d/leads/dead" 1
  touch -d '2 hours ago' "$d/leads/dead/state/.last-watcher-beat"
  {
    printf -- '- gappy - a lead with free lanes (home: %s; scope: g; projects: g; added 2026-10-30)\n' "$d/leads/gappy"
    printf -- '- quiet - an idle lead (home: %s; scope: q; projects: q; added 2026-10-30)\n' "$d/leads/quiet"
    printf -- '- dead - a lead whose watcher stopped (home: %s; scope: x; projects: x; added 2026-10-30)\n' "$d/leads/dead"
    printf -- '- far - a remote lead (host: box; root: /r; home: /r/h; scope: f; projects: f; added 2026-10-30)\n'
  } > "$d/main/data/squad_leads.md"
  printf '%s\n' "$d"
}

hb() {  # <case-dir> args...
  local d=$1
  shift
  env JG_HOME="$d/main" "$HB" "$@" 2>&1
}

verdict() { printf '%s\n' "$1" | awk -F '\t' -v h="$2" '$1 == h { print $2 }'; }

test_rows_give_every_home_one_verdict() {
  local d out
  d=$(setup rows)
  out=$(hb "$d" rows) || fail "rows failed: $out"
  assert_equals "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 5 "one row per home: $out"
  assert_equals "$(verdict "$out" overwatch)" MOVING "a working lane with no ready work is moving"
  assert_equals "$(verdict "$out" gappy)" GAP "ready work with a free lane is a gap"
  assert_contains "$out" "3 ready, 1 of 2 lanes working" "a paused lane must not count as working"
  assert_equals "$(verdict "$out" quiet)" IDLE "a done lane and no ready work is idle"
  assert_equals "$(verdict "$out" dead)" STALLED "work with no supervision beat is stalled"
  assert_equals "$(verdict "$out" far)" UNREAD "a remote home is not read"
  pass "rows give every home one verdict"
}

test_an_open_wait_is_a_gap_and_filled_lanes_are_moving() {
  local d out
  d=$(setup waits)
  lane "$d/leads/gappy" g3 'working [at=1]: building'
  mkdir -p "$d/main/state/.waiting-timers"
  printf 'x\n' > "$d/main/state/.waiting-timers/ship-a"
  out=$(hb "$d" rows)
  assert_equals "$(verdict "$out" gappy)" MOVING "lanes at the target with ready work are moving"
  assert_equals "$(verdict "$out" overwatch)" GAP "an open wait is a gap"
  pass "an open wait is a gap and filled lanes are moving"
}

test_check_wakes_on_a_gap_refires_and_reports_recovery_once() {
  local d out
  d=$(setup check)
  out=$(hb "$d" check)
  assert_contains "$out" "fleet heartbeat: gappy GAP" "the first gap must wake Main"
  assert_contains "$out" "fleet heartbeat: dead STALLED" "a stalled home must wake Main"
  assert_not_contains "$out" "overwatch" "a moving home must stay silent"
  assert_equals "$(hb "$d" check)" "" "an unchanged gap inside the re-fire window is silent"
  out=$(JG_FLEET_HEARTBEAT_REFIRE_SECS=0 hb "$d" check)
  assert_contains "$out" "fleet heartbeat: gappy GAP" "a gap still open after the window must re-fire"
  lane "$d/leads/gappy" g2 'working [at=2]: CI green, back on it'
  out=$(hb "$d" check)
  assert_contains "$out" "fleet heartbeat: gappy MOVING again" "recovery must be reported"
  assert_not_contains "$(hb "$d" check)" "gappy" "recovery is reported once"
  pass "check wakes on a gap, re-fires, and reports recovery once"
}

test_arm_registers_a_check_the_watcher_trusts_only_on_a_primary_home() {
  local d
  d=$(setup arm)
  hb "$d" arm > /dev/null || fail "arm failed"
  bash -c '. "$1/bin/jg-pr-lib.sh"; . "$1/bin/jg-check-lib.sh"; jg_custom_check_registered "$2" fleet-heartbeat' _ "$ROOT" "$d/main/state" \
    || fail "the watcher would reject the armed check"
  hb "$d" disarm > /dev/null
  [ ! -e "$d/main/state/fleet-heartbeat.check.sh" ] || fail "disarm left the shim"
  touch "$d/main/.jg-squad-lead-home"
  if hb "$d" arm > /dev/null; then fail "a Squad Lead home must refuse arm"; fi
  pass "arm registers a trusted check only on a primary home"
}

test_check_wakes_on_a_lead_without_current_owner_rules() {
  local d out
  d=$(setup rules)
  printf '# Owner rules\n\n## 2026-10-30 - keep moving\n' > "$d/main/data/owner-rules.md"
  mkdir -p "$d/leads/quiet/data" "$d/leads/dead/data"
  printf '# Owner rules\n' > "$d/leads/quiet/data/owner-rules.md"
  cp "$d/main/data/owner-rules.md" "$d/leads/dead/data/owner-rules.md"
  out=$(hb "$d" check)
  assert_contains "$out" "fleet heartbeat: gappy.owner-rules MISSING" "a lead without the owner rules must wake Main"
  assert_contains "$out" "fleet heartbeat: quiet.owner-rules STALE" "a lead with a stale copy must wake Main"
  assert_not_contains "$out" "dead.owner-rules" "a current copy must stay silent"
  cp "$d/main/data/owner-rules.md" "$d/leads/quiet/data/owner-rules.md"
  assert_contains "$(hb "$d" check)" "fleet heartbeat: quiet.owner-rules CURRENT again" "a converged copy must report recovery"
  pass "check wakes Main on a lead without current owner rules"
}

test_rows_give_every_home_one_verdict
test_an_open_wait_is_a_gap_and_filled_lanes_are_moving
test_check_wakes_on_a_gap_refires_and_reports_recovery_once
test_arm_registers_a_check_the_watcher_trusts_only_on_a_primary_home
test_check_wakes_on_a_lead_without_current_owner_rules
