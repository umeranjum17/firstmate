#!/usr/bin/env bash
# Behavior tests for bin/jg-reaper-lib.sh - the deterministic stale test-browser reaper and
# the machine load alarm. A process is stopped only when all three conditions hold, so this
# pins the matrix over real stub processes where a real SIGTERM lands: a day-old orphaned
# browser in a fleet temp root is stopped, and the same browser when fresh, under the
# captain's own profile, or with a live owning worker is left alone. Then its stop log and
# fleet event, the off switch, the real /proc scanner, and the load alarm.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

home=$(jg_test_tmproot jg-browser-reaper)
state=$home/home/state config=$home/home/config roots=$home/tmp
mkdir -p "$state" "$config" "$roots/jg-stale/chrome"
export JG_HOME=$home/home JG_STATE_OVERRIDE=$state JG_CONFIG_OVERRIDE=$config JG_TEST_SEAM=1
# shellcheck source=/dev/null
. "$ROOT/bin/jg-wake-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/jg-reaper-lib.sh"
log=$state/browser-reaper.log table=$home/ps.tsv
export JG_REAPER_PS=$table
printf '%s\n' "$roots" >"$config/reaper-roots"

# Every stub this suite starts, so a failure cannot leave a process holding a pipe open;
# tests/lib.sh owns the temp-root cleanup this chains to.
pids=()
cleanup() { local p; if [ "${#pids[@]}" -gt 0 ]; then for p in "${pids[@]}"; do kill -9 "$p" 2>/dev/null || true; done; fi; jg_test_cleanup; }
trap cleanup EXIT INT TERM
wakes() { [ -f "$JG_WAKE_QUEUE" ] && wc -l <"$JG_WAKE_QUEUE" | tr -d ' ' || printf '0\n'; }
alive() { kill -0 "$1" 2>/dev/null; }
row() { printf '%s\t%s\t%s\tchrome\t%s\n' "$1" "$2" "$3" "${4:-$roots/jg-stale/chrome}"; }

# A pid that has exited and been reaped: the worker that owned the folder, gone.
bash -c 'exit 0' &
dead=$!
wait "$dead" 2>/dev/null || true
[ ! -d "/proc/$dead" ] || fail "fixture: $dead is still alive"

sleep 60 >/dev/null 2>&1 & stop=$! pids+=("$stop")
sleep 60 >/dev/null 2>&1 & fresh=$! pids+=("$fresh")
sleep 60 >/dev/null 2>&1 & captain=$! pids+=("$captain")
sleep 60 >/dev/null 2>&1 & owned=$! pids+=("$owned")
{
  row "$stop" 90000 "$dead"
  row "$fresh" 60 "$dead"
  row "$captain" 90000 "$dead" "$HOME/.config/chromium/Default"
  row "$owned" 90000 "$$"
} >"$table"
before=$(wakes)
jg_reaper_sweep; sleep 0.2
alive "$stop" && fail "a day-old orphaned browser in a fleet temp root must be stopped"
pass "a day-old orphaned browser in a fleet temp root is stopped"
for kept in "$fresh" "$captain" "$owned"; do
  alive "$kept" || fail "the fresh, captain-profile and live-worker browsers must all be left alone"
done
pass "the fresh, captain-profile and live-worker browsers are left alone"
assert_grep "stopped pid=$stop age=90000s profile=$roots/jg-stale/chrome" "$log" "the stop log names pid, age and profile"
assert_grep "owning-worker-gone" "$log" "the stop log names the reason"
assert_no_grep "pid=$captain" "$log" "the captain's own profile never reaches the log"
assert_equals "$((before + 1))" "$(wakes)" "a sweep that stopped something posts exactly one fleet event"
assert_grep "browser reaper stopped 1 stale test browsers" "$JG_WAKE_QUEUE" "the fleet event names the stop count"
assert_equals "check browser-reaper" "$(tail -1 "$JG_WAKE_QUEUE" | cut -f3,4 | tr '\t' ' ')" "the fleet event is a check row keyed browser-reaper"
kill "$fresh" "$captain" "$owned" 2>/dev/null || true

# Nothing eligible, then the off switch through the public entry point.
{ row "$$" 90000 "$$"; row "$$" 10 "$dead"; } >"$table"
before=$(wakes)
jg_reaper_sweep
assert_equals "$before" "$(wakes)" "a sweep that stopped nothing posts no event"
sleep 60 >/dev/null 2>&1 & off=$! pids+=("$off")
row "$off" 90000 "$dead" >"$table"
: >"$config/reaper-off"
jg_reaper_tick; sleep 0.2
alive "$off" || fail "config/reaper-off must stop every stop"
pass "config/reaper-off leaves even an eligible browser alone"
rm -f "$config/reaper-off"; jg_reaper_tick; sleep 0.2
alive "$off" && fail "the tick must run the sweep once reaper-off is gone"

# The real scanner: a live process whose own argv carries the profile token.
unset JG_REAPER_PS
bash -c 'while :; do sleep 1; done' jg-reaper-real --user-data-dir="$roots/jg-real/chrome" >/dev/null 2>&1 &
real=$! pids+=("$real")
sleep 0.3
real_row=$(jg_reaper_table | awk -F'\t' -v p="$real" '$1 == p')
assert_contains "$real_row" "$roots/jg-real/chrome" "the real scanner reads --user-data-dir from argv"
real_age=$(cut -f2 <<<"$real_row")
case $real_age in '' | *[!0-9]*) fail "the real scanner reports a numeric age (got '$real_age')" ;; esac
[ "$real_age" -lt 60 ] || fail "the real scanner reports the process age (got ${real_age}s)"
pass "the real scanner reports each process age and profile"

kill "$real" 2>/dev/null || true

# The load alarm: one sample is not an episode; ten minutes of them is one wake.
printf '999.0 900.0 800.0 1/1 42\n' >"$home/load-high"
printf '0.10 0.10 0.10 1/1 42\n' >"$home/load-low"
export JG_REAPER_LOADAVG=$home/load-high JG_REAPER_PS=$table
{
  for _ in 1 2 3; do row "$$" 90000 "$dead"; done
  printf '%s\t90000\t%s\tnode\t%s\n' "$$" "$dead" "$roots/jg-stale/chrome"
} >"$table"
before=$(wakes); jg_reaper_load_alarm
assert_present "$state/.browser-reaper-load" "a load above the limit starts an episode"
assert_equals "$before" "$(wakes)" "the first high sample raises nothing"
printf '%s\n' "$(($(date +%s) - 700))" >"$state/.browser-reaper-load"; jg_reaper_load_alarm
assert_equals "$((before + 1))" "$(wakes)" "ten minutes above the limit posts exactly one wake"
assert_grep "machine load 999.0" "$JG_WAKE_QUEUE" "the load event names the load"
assert_grep "chrome 3 (oldest" "$JG_WAKE_QUEUE" "the load event names the top process group by count and age"
jg_reaper_load_alarm; assert_equals "$((before + 1))" "$(wakes)" "one wake per episode, not one per sample"
JG_REAPER_LOADAVG=$home/load-low jg_reaper_load_alarm
assert_absent "$state/.browser-reaper-load" "a load back under the limit ends the episode"
pass "the load alarm raises one wake per ten-minute episode"

printf 'PASS jg-browser-reaper\n'
