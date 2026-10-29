#!/usr/bin/env bash
# End-to-end tests for holds and unanswered asks that clear themselves:
# the hold-time date and --waits-on rules, the hold release sweep (date gate,
# task, PR and key refs, captain holds untouched), and the stale-ask sweep.
set -u
# An installed task-priority add-on must not change unrelated cases.
export JG_TASK_PRIORITY_CHECK=/nonexistent

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/jg-hold-sweep.sh"
TMP_ROOT=$(jg_test_tmproot jg-hold-sweep)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
unset TASKS_AXI_FILE TASKS_AXI_BACKEND JG_ROOT_OVERRIDE JG_DATA_OVERRIDE JG_STATE_OVERRIDE JG_CONFIG_OVERRIDE

HOME_DIR=
day() {  # <offset-days> -> UTC YYYY-MM-DD
  perl -MPOSIX -e 'print strftime("%Y-%m-%d", gmtime(time + 86400 * $ARGV[0]))' -- "$1"
}

make_home() {  # <name>; sets HOME_DIR with a fake gh that reports $GH_STATE
  HOME_DIR="$TMP_ROOT/$1"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/fakebin"
  jg_test_tasks_toml "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  cat > "$HOME_DIR/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${GH_STATE:-OPEN}"
SH
  chmod +x "$HOME_DIR/fakebin/gh"
}

run() {  # <script> <args...>
  local script=$1
  shift
  PATH="$HOME_DIR/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$HOME_DIR" \
    JG_STATE_OVERRIDE="$HOME_DIR/state" JG_DATA_OVERRIDE="$HOME_DIR/data" \
    JG_CONFIG_OVERRIDE="$HOME_DIR/config" "$script" "$@" 2>&1
}
ta() { run "$ROOT/bin/jg-tasks-axi.sh" "$@"; }
add() { ta add "$1" "task $1" --priority 1 >/dev/null || fail "add $1"; }
held_kind() { ta show "$1" | sed -n 's/^  hold_kind: //p' | tr -d '"'; }

test_hold_time_rules() {
  local out rc=0
  make_home hold-time
  add a
  out=$(ta hold a --reason "wait for the reset on $(day 3)" --kind future) || rc=$?
  expect_code 2 "$rc" "a future date in the reason without --until"
  assert_contains "$out" "pass --until $(day 3)" "the refusal must name the exact fix"
  assert_equals "-" "$(held_kind a)" "a refused hold must not be recorded"
  ta hold a --reason "reset was $(day -3)" --kind future >/dev/null || fail "a past date in the reason was refused"
  ta unhold a >/dev/null
  ta hold a --reason "wait for the reset on $(day 3)" --kind future --until "$(day 3)" >/dev/null \
    || fail "a dated reason with --until was refused"
  rc=0
  out=$(run "$ROOT/bin/jg-captain-hold.sh" hold cap --title "call" --reason "decide by $(day 2)") || rc=$?
  expect_code 2 "$rc" "captain hold with a future date and no --until"
  assert_contains "$out" "pass --until $(day 2)" "the captain hold refusal must name the exact fix"
  pass "a future date in a hold reason needs --until, for plain and captain holds"
}

test_waits_on_rules() {
  local out rc
  make_home waits-on-rules
  add a; add b
  rc=0; out=$(ta hold b --reason r --kind captain --waits-on task:a) || rc=$?
  expect_code 2 "$rc" "--waits-on on a captain hold"
  rc=0; out=$(ta hold b --reason r --kind external --waits-on task:ghost) || rc=$?
  expect_code 2 "$rc" "--waits-on naming no task"
  rc=0; out=$(ta hold b --reason r --kind external --waits-on nonsense) || rc=$?
  expect_code 2 "$rc" "--waits-on with a malformed ref"
  assert_contains "$out" "task:<id>, pr:<https url>, or key:" "the refusal must list the ref forms"
  ta hold b --reason "needs a" --kind external --waits-on task:a >/dev/null || fail "valid --waits-on refused"
  assert_contains "$(ta show b)" "[waits-on=task:a]" "the ref must be stored with the hold"
  pass "--waits-on is validated and stored with the hold"
}

test_date_gate_releases_and_wakes() {
  local out rc=0
  make_home date-gate
  add due; add later; add cap
  ta hold due --reason "reset" --kind future --until "$(day -1)" >/dev/null || fail "hold due"
  ta hold later --reason "reset" --kind future --until "$(day 5)" >/dev/null || fail "hold later"
  run "$ROOT/bin/jg-captain-hold.sh" hold cap --reason "pick one" --until "$(day -1)" >/dev/null || fail "hold cap"
  out=$(run "$SWEEP" holds) || rc=$?
  expect_code 0 "$rc" "sweep with a date gate that has arrived"
  assert_contains "$out" "due (its --until date $(day -1) arrived)" "the wake must name the released task and why"
  assert_not_contains "$out" "later" "a gate in the future must stay held"
  assert_not_contains "$out" "cap" "a captain hold must never be released by date"
  assert_equals "-" "$(held_kind due)" "the released hold must be cleared"
  assert_equals "future" "$(held_kind later)" "the future gate must be kept"
  assert_equals "captain" "$(held_kind cap)" "the captain hold must be kept"
  rc=0; run "$SWEEP" holds >/dev/null || rc=$?
  expect_code 1 "$rc" "a second sweep must find nothing new"
  pass "a date gate releases and wakes once, and captain holds are left alone"
}

test_task_ref_releases_when_it_closes() {
  local out rc=0
  make_home task-ref
  add dep; add work
  ta hold work --reason "needs dep" --kind external --waits-on task:dep >/dev/null || fail "hold work"
  run "$SWEEP" holds >/dev/null || rc=$?
  expect_code 1 "$rc" "sweep while the dependency is open"
  ta start dep >/dev/null
  ta "done" dep >/dev/null || fail "close dep"
  out=$(run "$SWEEP" holds) || fail "sweep after the dependency closed: $out"
  assert_contains "$out" "work (task:dep closed)" "the wake must name the released task and ref"
  assert_contains "$(ta ready)" "work" "the released task must be dispatchable"
  pass "a hold waiting on a task releases and wakes when that task closes"
}

test_pr_and_key_refs() {
  local out rc=0
  make_home pr-key-ref
  add p; add k
  ta hold p --reason "needs pr" --kind external --waits-on pr:https://example.test/o/r/pull/1 >/dev/null || fail "hold p"
  ta hold k --reason "needs key" --kind external --waits-on key:api-shape >/dev/null || fail "hold k"
  GH_STATE=OPEN run "$SWEEP" holds >/dev/null || rc=$?
  expect_code 1 "$rc" "sweep while the PR is open and the key unresolved"
  printf 'blocked [key=api-shape] [at=%s]: stuck\n' "$(date +%s)" > "$HOME_DIR/state/x.status"
  rc=0; run "$SWEEP" holds >/dev/null || rc=$?
  expect_code 1 "$rc" "an open key must keep the hold"
  printf 'resolved [key=api-shape] [at=%s]: decided\n' "$(date +%s)" >> "$HOME_DIR/state/x.status"
  out=$(GH_STATE=MERGED run "$SWEEP" holds) || fail "sweep after both refs closed: $out"
  assert_contains "$out" "p (pr:https://example.test/o/r/pull/1 closed)" "the merged PR must release its hold"
  assert_contains "$out" "k (key:api-shape closed)" "the resolved key must release its hold"
  pass "PR and key refs release their holds when they close"
}

test_stale_asks() {
  local out rc=0 now
  make_home stale-asks
  now=$(date +%s)
  {
    printf 'blocked [at=%s]: hung run\n' "$((now - 5 * 3600))"
  } > "$HOME_DIR/state/old.status"
  printf 'needs-decision [key=q1] [at=%s]: pick a or b\nresolved [key=q1] [at=%s]: a\n' \
    "$((now - 9 * 3600))" "$((now - 8 * 3600))" > "$HOME_DIR/state/answered.status"
  printf 'blocked [at=%s]: just now\n' "$now" > "$HOME_DIR/state/fresh.status"
  printf 'blocked: no stamp\n' > "$HOME_DIR/state/unstamped.status"
  printf 'needs-decision [key=captain-hold-t-1] [at=%s]: held for the captain\n' "$((now - 9 * 3600))" \
    > "$HOME_DIR/state/relay.status"
  out=$(run "$SWEEP" asks) || fail "stale ask sweep found nothing: $out"
  assert_contains "$out" "old blocked 5h: hung run" "the old unanswered block must be flagged"
  assert_not_contains "$out" "answered" "an answered ask must not be flagged"
  assert_not_contains "$out" "fresh" "a recent ask must not be flagged"
  assert_not_contains "$out" "unstamped" "an ask of unknown age must not be flagged"
  assert_not_contains "$out" "relay" "a captain-held relay stays with the captain"
  assert_contains "$out" "decide each now" "the wake must tell Overwatch to decide or escalate"
  run "$SWEEP" asks --record >/dev/null || fail "record failed"
  run "$SWEEP" asks >/dev/null || rc=$?
  expect_code 1 "$rc" "a raised ask must stay quiet until the next window"
  printf '2' > "$HOME_DIR/config/stale-ask-hours"
  rm -f "$HOME_DIR/state/.stale-ask-raised"
  out=$(run "$SWEEP" asks) || fail "a 2h threshold found nothing"
  assert_contains "$out" "over 2h" "config/stale-ask-hours must set the threshold"
  pass "an unanswered blocked or needs-decision line is flagged once per window"
}

test_closing_a_task_resolves_its_parent_hold() {
  local parent mate channel
  make_home closed-parent
  parent=$HOME_DIR
  mate="$TMP_ROOT/closed-mate"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/fakebin"
  jg_test_tasks_toml "$mate/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$mate/data/backlog.md"
  printf 'closed-mate\n' > "$mate/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$mate/.jg-squad-lead-parent"
  channel="$parent/state/closed-mate.status"
  HOME_DIR=$mate
  add gone
  run "$ROOT/bin/jg-captain-hold.sh" hold gone --reason "pick one" >/dev/null || fail "hold gone"
  assert_grep "needs-decision [key=captain-hold-gone-1]" "$channel" "the hold did not reach the parent channel"
  ta "done" gone >/dev/null || fail "close gone"
  assert_grep "resolved [key=captain-hold-gone-1]" "$channel" "closing the task left its parent decision open"
  pass "closing a captain-held task resolves its decision on the parent channel"
}

test_closed_task_is_not_shown_as_decision() {
  local out
  make_home closed-view
  add wk
  ta start wk >/dev/null
  printf 'window=jg:wk\nworktree=%s/nowt\nproject=%s/p\nharness=codex\nkind=ship\nmode=ship\nspawn_gen=g1\n' \
    "$HOME_DIR" "$HOME_DIR" > "$HOME_DIR/state/wk.meta"
  printf 'needs-decision [key=q1] [at=1000]: pick a or b\nneeds-decision [key=captain-hold-wk-1] [at=1000]: held\n' \
    > "$HOME_DIR/state/wk.status"
  ta "done" wk >/dev/null || fail "close wk"
  out=$(run "$ROOT/bin/jg-fleet-snapshot.sh" --squad-lead-home-summary | jq -c '[.. | objects | select(has("decisions_open")) | .decisions_open | length] | add')
  assert_equals "0" "$out" "a closed task still counted as an open decision"
  pass "the fleet view does not count a closed task's decisions"
}

test_hold_time_rules
test_waits_on_rules
test_date_gate_releases_and_wakes
test_task_ref_releases_when_it_closes
test_pr_and_key_refs
test_stale_asks
test_closing_a_task_resolves_its_parent_hold
test_closed_task_is_not_shown_as_decision
