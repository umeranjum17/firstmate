#!/usr/bin/env bash
# Behavior tests for the host memory guard (bin/fm-jev-mem-guard.sh): its
# verdicts and recorded samples against a fixture proc tree, the owner mapping
# that names the largest consumers by task, and the watcher tick that turns an
# ALERT into exactly one wake per episode.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

GUARD="$ROOT/bin/fm-jev-mem-guard.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-mem-guard)

# fake_host <proc> <available-gb> <pressure-avg10> [swap-used-gb]
fake_host() {
  local proc=$1 swap_used=${4:-0}
  mkdir -p "$proc/pressure"
  printf 'MemTotal:       67108864 kB\nMemAvailable:   %s kB\nSwapTotal:      33554432 kB\nSwapFree:       %s kB\n' \
    "$(($2 * 1048576))" "$((33554432 - swap_used * 1048576))" > "$proc/meminfo"
  printf 'some avg10=%s avg60=1.00 avg300=1.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' "$3" \
    > "$proc/pressure/memory"
}

# fake_pid <proc> <pid> <name> <rss-gb> <cwd> [FM_TASK_ID]
fake_pid() {
  local dir="$1/$2"
  mkdir -p "$dir"
  printf 'Name:\t%s\nVmRSS:\t%s kB\nVmSwap:\t0 kB\n' "$3" "$(($4 * 1048576))" > "$dir/status"
  ln -s "$5" "$dir/cwd"
  if [ -n "${6:-}" ]; then printf 'PATH=/bin\0FM_TASK_ID=%s\0' "$6" > "$dir/environ"; else printf 'PATH=/bin\0' > "$dir/environ"; fi
}

# A home with one ship task, one lead, and processes owned by the task (by
# working directory and, for a daemon outside it, by FM_TASK_ID), by the lead,
# and by nothing Firstmate records.
make_fleet() {
  local case=$1
  mkdir -p "$case/state" "$case/wt/sub" "$case/mate/state"
  fm_write_meta "$case/state/big-build.meta" kind=ship "worktree=$case/wt"
  fm_write_meta "$case/state/sm1.meta" kind=secondmate "home=$case/mate"
  fake_pid "$case/proc" 101 node 9 "$case/wt/sub"
  fake_pid "$case/proc" 102 java 5 / big-build
  fake_pid "$case/proc" 103 claude 2 "$case/mate"
  fake_pid "$case/proc" 104 llama 6 /
}

test_verdicts_samples_and_owners() {
  local case=$TMP_ROOT/verdicts out rc tsv
  case=$TMP_ROOT/verdicts tsv=$case/state/host-memory.tsv
  make_fleet "$case"
  fake_host "$case/proc" 40 2.5 1
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --record "$tsv" --state-dir "$case/state")
  assert_equals $'OK\tpressure 2% (10 s average), 40.0 GB available, 1.0 GB swap used' "$out" "calm host"
  fake_host "$case/proc" 30 24 3
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --record "$tsv" --state-dir "$case/state")
  assert_equals $'WAIT\tpressure 24% (10 s average), 30.0 GB available, 3.0 GB swap used; pressure at or above 20%' "$out" \
    "pressure past the wait threshold makes new agents wait"
  fake_host "$case/proc" 5 41.2 16
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --record "$tsv" --state-dir "$case/state")
  assert_equals $'ALERT\tpressure 41% (10 s average), 5.0 GB available, 16.0 GB swap used; pressure at or above 35%; available memory below 6 GB; largest: task big-build (main) 14.0 GB in 2 processes, llama pid 104 6.0 GB, lead sm1 2.0 GB' "$out" \
    "an alert names the largest consumers by task, lead, or process"
  [ "$(wc -l < "$tsv" | tr -d ' ')" -eq 3 ] || fail "three samples should be recorded: $(cat "$tsv")"
  assert_equals $'5242880\t16777216\t41.20\tALERT' "$(tail -n 1 "$tsv" | cut -f2-)" "the sample row carries available kB, swap kB, pressure, verdict"
  # Thresholds come from the one config file; a broken one is refused with its line.
  printf '# tighter host\nalert_pressure=50\nalert_available_gb=1\nwait_pressure = 10\n' > "$case/host-memory"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --config "$case/host-memory")
  assert_contains "$out" "pressure at or above 10%" "config thresholds replace the defaults"
  printf 'alert_pressure=lots\n' > "$case/host-memory"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --config "$case/host-memory" 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "an invalid config must exit 2, got $rc: $out"
  assert_contains "$out" "line 1: 'alert_pressure=lots'" "the invalid line is named"
  # Not measurable: no verdict is invented and nothing is recorded.
  out=$(FM_HOST_MEMORY_PROC="$case/none" "$GUARD" --record "$tsv")
  assert_contains "$out" "UNKNOWN" "an unmeasurable host reads unknown"
  [ "$(wc -l < "$tsv" | tr -d ' ')" -eq 3 ] || fail "an unmeasurable sample was recorded"
  pass "verdicts, recorded samples, and owner mapping follow the host"
}

# One watcher run against the case; legs that must wake exit on their own.
watch_leg() {
  local case=$1 tag=$2
  env PATH="$case/fakebin:$PATH" FM_HOME="$case" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case/state" \
    FM_CREW_STATE_BIN="$case/fakebin/fm-crew-state.sh" TMUX='' FM_BACKEND=tmux \
    FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_SECS=1 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$case/watch-$tag.out" 2> "$case/watch-$tag.err" &
  LEG_PID=$!
}

drain_and_ack() {
  local state="$1/state" seq gen
  FM_HOME="$1" FM_STATE_OVERRIDE="$state" "$DRAIN" > /dev/null 2> "$1/drain.err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\).*$/\1/p' "$1/drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\).*$/\1/p' "$1/drain.err")
  [ -n "$seq" ] && [ -n "$gen" ] || return 0
  FM_HOME="$1" FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" > /dev/null 2>&1 || true
}

# wait_rows <tsv> <n>: wait up to 30 s for the watcher to have recorded n samples.
wait_rows() {
  local i=0
  while [ "$(wc -l < "$1" 2>/dev/null || echo 0)" -lt "$2" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  [ "$(wc -l < "$1")" -ge "$2" ] || fail "the watcher did not record sample $2: $(cat "$1" "${1%/state/*}"/watch-*.out)"
}

test_watcher_wakes_once_per_alert_episode() {
  local case out
  case=$(make_case alert)
  make_fleet "$case"
  fake_host "$case/proc" 5 41.2 16
  watch_leg "$case" alert
  wait_for_exit "$LEG_PID" 300 || fail "the watcher did not wake on a memory alert: $(cat "$case/watch-alert.err")"
  out=$(cat "$case/watch-alert.out")
  assert_contains "$out" "check: host memory ALERT: pressure 41% (10 s average)" "the alert wake names the pressure"
  assert_contains "$out" "largest: task big-build (main) 14.0 GB in 2 processes" "the alert wake names the largest task"
  [ "$(grep -c $'\tcheck\thost-memory\t' "$case/state/.wake-queue")" -eq 1 ] \
    || fail "the alert was not queued durably exactly once: $(cat "$case/state/.wake-queue")"
  [ -s "$case/state/host-memory.tsv" ] || fail "the watcher did not record the sample"

  # Still under alert: the episode is latched, so the next watcher stays quiet.
  drain_and_ack "$case"
  watch_leg "$case" latched
  wait_rows "$case/state/host-memory.tsv" 3
  is_live_non_zombie "$LEG_PID" || fail "a latched alert woke again: $(cat "$case/watch-latched.out")"
  kill -TERM "$LEG_PID" 2>/dev/null; wait_for_exit "$LEG_PID" 50 >/dev/null || true

  # An OK sample ends the episode; the next alert wakes again.
  fake_host "$case/proc" 40 2
  drain_and_ack "$case"
  watch_leg "$case" calm
  wait_rows "$case/state/host-memory.tsv" "$(( $(wc -l < "$case/state/host-memory.tsv") + 1 ))"
  kill -TERM "$LEG_PID" 2>/dev/null; wait_for_exit "$LEG_PID" 50 >/dev/null || true
  [ ! -e "$case/state/.host-memory-alerted" ] || fail "an OK sample did not clear the alert latch: $(tail -n 3 "$case/state/host-memory.tsv")"
  fake_host "$case/proc" 5 41.2 16
  drain_and_ack "$case"
  watch_leg "$case" again
  wait_for_exit "$LEG_PID" 300 || fail "a new alert episode did not wake"
  assert_contains "$(cat "$case/watch-again.out")" "check: host memory ALERT" "the second episode wakes"
  pass "the watcher samples memory and wakes once per alert episode, naming the largest task"
}

test_verdicts_samples_and_owners
test_watcher_wakes_once_per_alert_episode
