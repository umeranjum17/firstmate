#!/usr/bin/env bash
# tests/jg-send-dormant-lead.test.sh - a steer to a stopped or dormant Squad Lead
# records the message first and returns in seconds (bin/jg-send.sh).
#
# A dormant lead is stopped with no open work and relaunched by the next routed
# send. The relaunch is not instant - bin/jg-control.sh relaunch waits for the
# replacement agent to come up - so a send that waited with it hung for minutes,
# and a caller that gave up first (three timed-out attempts, no record) lost the
# message entirely. These cases pin the contract that fixes it:
#   1. A send to a dormant lead returns within 10 seconds and the record exists
#      BEFORE the lead is up; the relaunch still happens, asynchronously.
#   2. An agent that never becomes ready (a relaunch that cannot produce a live
#      endpoint) still leaves the record standing, and the send still exits 0.
#   3. A stopped lead with no dormant record is woken by nothing and still gets
#      its durable record quickly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/jg-send.sh"
TMP_ROOT=$(jg_test_tmproot jg-send-dormant-lead)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
# Long enough that a send which waited for the relaunch would pass the 10s bound
# the contract allows; short enough to leave no long-lived stray process.
RELAUNCH_SECS=25
NOWAIT_BOUND=10

# The relaunch is a fake jg-control: it logs the call and then takes as long as a
# real relaunch does (waiting for the replacement agent to report alive).
make_fakeroot() { # <dir>
  mkdir -p "$1/bin"
  cat > "$1/bin/jg-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$FAKE_CONTROL_LOG"
[ "${FAKE_CONTROL_FAIL:-0}" = 1 ] && exit 1
sleep "$FAKE_CONTROL_SECS"
SH
  chmod +x "$1/bin/jg-control.sh"
}

# A tmux stub whose pane is simply gone: no window, so the doorbell reports the
# endpoint dead instead of typing into whatever else owns that name.
make_stubs() { # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows | list-panes) exit 0 ;;
  has-session) exit 1 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'
    exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

setup_case() { # <name> -> echoes the case dir holding a main home + lead home
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/main/state" "$dir/main/config" "$dir/main/data" \
    "$dir/lead/data" "$dir/lead/state"
  make_fakeroot "$dir/fakeroot"
  make_stubs "$dir"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/lead/data/backlog.md"
  printf '1\n' > "$dir/main/config/squad-lead-dormant-secs"
  jg_write_meta "$dir/main/state/lead.meta" \
    "kind=squad_lead" "home=$dir/lead" "harness=claude" "backend=tmux" \
    "window=juggernaut:jg-lead"
  : > "$dir/control.log"
  printf '%s\n' "$dir"
}

# run_send <case-dir> [extra env...] -> "<elapsed seconds> <exit code>"
run_send() {
  local dir=$1 start rc
  shift
  : > "$dir/control.log"
  start=$(date +%s)
  env PATH="$dir/fakebin:$PATH" JG_BACKEND=tmux JG_ROOT_OVERRIDE="$dir/fakeroot" \
    JG_HOME="$dir/main" JG_STATE_OVERRIDE="$dir/main/state" \
    FAKE_CONTROL_LOG="$dir/control.log" FAKE_CONTROL_SECS=$RELAUNCH_SECS \
    JG_SEND_SETTLE=0 ${1+"$@"} \
    "$SEND" lead "relaunch and take this work" >/dev/null 2>"$dir/send.err"
  rc=$?
  printf '%s %s\n' $(( $(date +%s) - start )) "$rc"
}

first_record() { # <case-dir> -> the task's first inbox record, if any
  set -- "$1"/main/state/lead.inbox/*.msg
  [ -f "$1" ] || return 1
  printf '%s\n' "$1"
}

# The wake is detached, so its evidence lands after the send returns.
wait_for_relaunch() { # <case-dir> -> 0 once the control plane was called
  local dir=$1 i=0
  while [ "$i" -lt 200 ]; do
    grep -q "^lead relaunch$" "$dir/control.log" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

record_body() { # <record>
  bash -c '. "$1"; jg_task_inbox_body "$2"' _ "$ROOT/bin/jg-task-inbox-lib.sh" "$1"
}

test_dormant_lead_send_records_first_and_returns_fast() {
  local d out elapsed rc rec
  d=$(setup_case dormant)
  printf 'dormant 2 %s\n' "$(date +%s)" > "$d/main/state/.squad-lead-dormant-lead"
  out=$(run_send "$d")
  elapsed=${out% *}
  rc=${out#* }
  expect_code 0 "$rc" "a steer to a dormant lead records the message and succeeds: $(cat "$d/send.err")"
  [ "$elapsed" -lt "$NOWAIT_BOUND" ] ||
    fail "the send waited ${elapsed}s for a relaunch; it must return within ${NOWAIT_BOUND}s"
  rec=$(first_record "$d") || fail "the steer to a dormant lead was never recorded"
  assert_contains "$(record_body "$rec")" "relaunch and take this work" \
    "the recorded message carries the steer"
  wait_for_relaunch "$d" || fail "the dormant lead was never woken: $(cat "$d/control.log" 2>/dev/null)"
  pass "jg-send dormant lead: the record lands first and the send returns in ${elapsed}s"
}

test_agent_that_never_becomes_ready_keeps_the_record() {
  local d out elapsed rc rec
  d=$(setup_case no-ready)
  printf 'dormant 2 %s\n' "$(date +%s)" > "$d/main/state/.squad-lead-dormant-lead"
  # The relaunch starts and cannot produce a live endpoint at all.
  out=$(run_send "$d" FAKE_CONTROL_FAIL=1)
  elapsed=${out% *}
  rc=${out#* }
  expect_code 0 "$rc" \
    "an unreachable lead is still a durable delivery: $(cat "$d/send.err")"
  [ "$elapsed" -lt "$NOWAIT_BOUND" ] ||
    fail "the send waited ${elapsed}s on an agent that never comes up"
  rec=$(first_record "$d") || fail "the record was dropped when the agent did not come up"
  assert_contains "$(record_body "$rec")" "relaunch and take this work" \
    "the recorded message survives an unreachable agent"
  assert_contains "$(cat "$d/send.err")" "$rec" \
    "the send names the durable record as the delivery outcome"
  pass "jg-send dormant lead: a lead that never becomes ready still owns the record"
}

test_stopped_lead_without_a_dormant_record_is_fast_too() {
  local d out elapsed rc rec
  d=$(setup_case stopped)
  # A plain stopped lead: exited, never walked through the dormant sweep.
  printf '%s\n' "$(date +%s)" > "$d/main/state/lead.exit"
  out=$(run_send "$d")
  elapsed=${out% *}
  rc=${out#* }
  expect_code 0 "$rc" "a steer to a stopped lead records and succeeds: $(cat "$d/send.err")"
  [ "$elapsed" -lt "$NOWAIT_BOUND" ] ||
    fail "the send to a stopped lead took ${elapsed}s"
  rec=$(first_record "$d") || fail "the steer to a stopped lead was never recorded"
  assert_equals "$(cat "$d/control.log" 2>/dev/null)" "" \
    "a stopped lead that is not dormant is not relaunched by the send path"
  pass "jg-send stopped lead: the record lands and the send returns in ${elapsed}s"
}

test_dormant_lead_send_records_first_and_returns_fast
test_agent_that_never_becomes_ready_keeps_the_record
test_stopped_lead_without_a_dormant_record_is_fast_too
