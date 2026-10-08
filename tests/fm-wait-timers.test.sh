#!/usr/bin/env bash
# Real watcher/drain/parent-channel journey; only the terminal API is a fixture.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-wait-timers)
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

cycle() {
  local rc=0 seq gen
  env HOME="$dir/home" XDG_CONFIG_HOME="$dir/home/config" TMPDIR="$dir/tmp" \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_BUSY_TURN_MAX_SECS=999999 \
    FM_STALE_ESCALATE_SECS=999999 FM_WAIT_ALERT_SECS=2 FM_WAIT_ESCALATE_SECS=4 \
    "$WATCH" > "$dir/out" 2> "$dir/err" &
  pid=$!
  wait_for_exit "$pid" 70 || rc=$?
  case "$rc" in 0|124) ;; *) fail "watcher failed: $(cat "$dir/err")" ;; esac
  cat "$dir/out" >> "$dir/events"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$DRAIN" > "$dir/drain" 2> "$dir/ack"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$dir/ack")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$dir/ack")
  [ -z "$seq" ] || FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" >/dev/null
}

for verb in blocked needs-decision; do
  dir=$(make_case "$verb")
  mkdir -p "$dir/home/config" "$dir/tmp" "$dir/config" "$dir/parent/state"
  printf 'lead\n' > "$dir/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$dir/parent" > "$dir/.fm-secondmate-parent"
  channel="$dir/parent/state/lead.status"
  if [ "$verb" = needs-decision ]; then
    printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=fixture\n' > "$dir/.fm-secondmate-parent"
    channel="$dir/state/parent-replies.status"
  fi
  printf 'kind=ship\nbackend=tmux\nwindow=fake:1\n' > "$dir/state/lane.meta"
  printf '%s [at=%s] [key=wait]: external condition until 2099-01-01T00:00Z\n' "$verb" "$(date +%s)" > "$dir/state/lane.status"
  cycle
  if [ "$verb" = blocked ]; then
    IFS=$'\t' read -r sig since owner parent key < "$dir/state/.waiting-timers/lane"
    printf '%s\t%s\t0\t0\t%s\n' "$sig" "$((since - 900))" "$key" > "$dir/state/.waiting-timers/lane"
  fi
  cycle
  if [ "$verb" = blocked ]; then
    [ ! -s "$channel" ] || fail 'restart escalated before owner response interval'
    IFS=$'\t' read -r sig since owner parent key < "$dir/state/.waiting-timers/lane"
    [ "$owner" -gt 1 ] || fail 'owner delivery timestamp missing'
  fi
  grep -q 'check: waiting-state lane .*level=owner' "$dir/events" || fail "$verb did not alert its owner"
  cycle
  grep -q 'blocked .*waiting-timer-overdue: lane' "$channel" || fail "$verb did not escalate to parent"
  cycle
  [ "$(grep -c 'level=owner' "$dir/events")" -eq 1 ] || fail "$verb repeated its owner alert"
  [ "$(grep -c '^blocked ' "$channel")" -eq 1 ] || fail "$verb repeated parent escalation"
  printf 'resolved [key=wait]: condition cleared\nworking: resumed\n' >> "$dir/state/lane.status"
  cycle
  grep -q '^resolved .*waiting-timer-cleared:' "$channel" || fail "$verb left parent escalation open"
  printf '%s [key=wait]: another condition\n' "$verb" >> "$dir/state/lane.status"
  cycle
  cycle
  [ "$(grep -c 'level=owner' "$dir/events")" -eq 2 ] || fail "$verb did not re-arm"
  if [ "$verb" = blocked ]; then
    cycle
    rm "$dir/state/lane.meta"
    cycle
    [ "$(grep -c '^resolved .*waiting-timer-cleared:' "$channel")" -eq 2 ] || fail 'removed task left parent report open'
  fi
  pass "$verb owner alert, parent escalation, deduplication, resolution and re-arm"
done

# Native blocked wins over a working log and survives unrelated status churn.
dir=$(make_case herdr)
mkdir -p "$dir/home/config" "$dir/tmp" "$dir/config"
printf 'kind=secondmate\nharness=opencode\nbackend=herdr\nwindow=fixture:w1:p1\n' > "$dir/state/lane.meta"
printf 'working: running\n' > "$dir/state/lane.status"
printf 'blocked\n' > "$dir/native"
cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = 'agent list' ]; then
  printf '{"result":{"agents":[{"pane_id":"w1:p1","agent_status":"%s"},{"pane_id":"foreign:pane","agent_status":"blocked"}]}}\n' "$(cat "$FM_HOME/native")"
else
  exit 1
fi
SH
chmod +x "$dir/fakebin/herdr"
cycle
printf 'working: more output\n' >> "$dir/state/lane.status"
cycle
cycle
[ "$(grep -c 'level=owner' "$dir/events")" -eq 1 ] || fail 'native blocked timer was reset by output or repeated'
grep -q 'herdr-blocked' "$dir/events" || fail 'native blocked did not override working'
! grep -q 'foreign:pane' "$dir/events" || fail 'foreign pane was monitored'
printf 'working\n' > "$dir/native"
cycle
printf 'blocked\n' > "$dir/native"
cycle
cycle
[ "$(grep -c 'level=owner' "$dir/events")" -eq 2 ] || fail 'native blocked did not re-arm'
printf 'working\n' > "$dir/native"
printf 'blocked [key=waiting-timer-child]: waiting-timer-overdue: child is waiting\n' >> "$dir/state/lane.status"
cycle
cycle
[ "$(grep -c 'level=owner' "$dir/events")" -eq 2 ] || fail 'child report was mistaken for the lead waiting'
pass 'lead native blocked overrides log, ignores foreign panes, re-arms, and excludes child reports'

printf 'kind=secondmate\nharness=cursor\nbackend=herdr\nwindow=fixture:w1:p1\n' > "$dir/state/lane.meta"
printf 'blocked\n' > "$dir/native"
printf 'working: healthy Cursor\n' > "$dir/state/lane.status"
cycle
[ ! -e "$dir/state/.waiting-timers/lane" ] || fail 'Cursor native blocked admitted'
printf 'blocked [key=cursor-wait]: real dependency\n' >> "$dir/state/lane.status"
cycle
cycle
grep -q 'waiting-state lane (blocked' "$dir/events" || fail 'Cursor declaration not monitored'
pass 'Cursor ignores native blocked but retains declaration monitoring'

cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = 'agent list' ]; then sleep 30; else exit 1; fi
SH
start=$(date +%s)
FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
  PATH="$dir/fakebin:$PATH" FM_BACKEND_HERDR_READ_TIMEOUT=1 \
  "$WATCH" > "$dir/timeout-out" 2> "$dir/timeout-err" &
pid=$!
rc=0
wait_for_exit "$pid" 80 || rc=$?
[ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] || fail 'stalled native lookup did not fail within bound'
[ "$(( $(date +%s) - start ))" -lt 8 ] || fail 'native timeout exceeded bound'
grep -q 'waiting-state timer check failed' "$dir/timeout-err" || fail 'native failure diagnostic missing'
pass 'native agent-list lookup is bounded'
