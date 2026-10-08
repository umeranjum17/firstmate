#!/usr/bin/env bash
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMUX_BIN=$(command -v tmux) || exit 1
command -v tasks-axi >/dev/null || exit 1
world=$(mktemp -d "$ROOT/.fm-wait-e2e.XXXXXX")
sock="fm-wait-e2e-$$"
watch_pid=''
cleanup() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL: real tmux wait journey (exit %s)\n' "$rc"
    for file in out err events drain ack hold-identity state/.waiting-timers/held-lane parent/state/lead.status; do
      [ ! -f "$world/$file" ] || { printf '\n%s:\n' "$file"; cat "$world/$file"; }
    done
  fi
  [ -z "$watch_pid" ] || kill "$watch_pid" 2>/dev/null || :
  [ -z "$watch_pid" ] || wait "$watch_pid" 2>/dev/null || :
  "$TMUX_BIN" -L "$sock" kill-server 2>/dev/null || :
  rm -rf "$world"
}
trap cleanup EXIT
mkdir -p "$world"/{state,data,config,home,tmp,fakebin,parent/state}
printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$TMUX_BIN" "$sock" > "$world/fakebin/tmux"
chmod +x "$world/fakebin/tmux"
export HOME="$world/home" XDG_CONFIG_HOME="$world/home/config" TMPDIR="$world/tmp"
export PATH="$world/fakebin:$PATH" FM_HOME="$world" FM_STATE_OVERRIDE="$world/state" FM_DATA_OVERRIDE="$world/data" FM_CONFIG_OVERRIDE="$world/config"
export FM_ROOT_OVERRIDE="$world" FM_TMUX_SESSION=firstmate FM_SESSION=firstmate
printf 'tmux\n' > "$world/config/backend"
printf 'lead\n' > "$world/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$world/parent" > "$world/.fm-secondmate-parent"
cp "$ROOT/.tasks.toml" "$world/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$world/data/backlog.md"
(cd "$world" && tasks-axi add held-lane 'deliberately paused lane' --file data/backlog.md)
tmux new-session -d -s firstmate -n fm-held-lane 'sleep 300'
printf 'window=firstmate:fm-held-lane\nkind=ship\nharness=pi\nbackend=tmux\nworktree=%s\n' "$world" > "$world/state/held-lane.meta"
cycle() {
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_HOME_SUMMARY_INTERVAL=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_WAIT_ALERT_SECS=2 FM_WAIT_ESCALATE_SECS=4 \
    bash "$ROOT/bin/fm-watch.sh" > "$world/out" 2> "$world/err" &
  watch_pid=$!
  for unused in 1 2 3 4 5 6 7 8; do
    kill -0 "$watch_pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$watch_pid" 2>/dev/null; then
    kill "$watch_pid"
    wait "$watch_pid" || :
  else
    wait "$watch_pid" || { cat "$world/err"; exit 1; }
  fi
  watch_pid=''
  cat "$world/out" >> "$world/events"
  bash "$ROOT/bin/fm-wake-drain.sh" > "$world/drain" 2> "$world/ack"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$world/ack")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$world/ack")
  [ -z "$seq" ] || bash "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null
}
printf 'paused: validation until 2099-01-01T00:00Z\n' > "$world/state/held-lane.status"
cycle
[ ! -e "$world/state/.waiting-timers/held-lane" ] || { echo 'future pause admitted'; exit 1; }
! grep -q 'waiting-state' "$world/events" || exit 1
printf 'paused: validation until 2000-01-01T00:00Z\n' >> "$world/state/held-lane.status"
cycle
cycle
grep -q 'waiting-state held-lane (paused' "$world/events" || exit 1
[ ! -s "$world/parent/state/lead.status" ] || { echo 'pause escalated to Main'; exit 1; }
bash "$ROOT/bin/fm-captain-hold.sh" hold held-lane --reason test
bash "$ROOT/bin/fm-captain-hold.sh" open held-lane --identity > "$world/hold-identity"
[ -s "$world/hold-identity" ] || exit 1
: > "$world/events"
for round in 1 2 3; do cycle; done
! grep -E 'waiting-state|^stale:|stopped|possible wedge' "$world/events" || { echo 'held item alarmed'; exit 1; }
[ ! -e "$world/state/.waiting-timers/held-lane" ] || exit 1
! grep -q 'waiting-timer-overdue' "$world/parent/state/lead.status" || exit 1
echo 'PASS: real tmux watcher honours pause deadline, owner-only pause and active captain hold'
