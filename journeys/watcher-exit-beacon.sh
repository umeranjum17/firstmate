#!/usr/bin/env bash
# done-done journey: the real watcher, armed the way a home arms it, ends a cycle on an actionable
# signal. The liveness read a lead's supervision check uses must still call the home supervised
# once the 60 s hand-off stamp has aged out, and a replacement must not inherit that beacon.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export JG_HOME=$T JG_STATE_OVERRIDE=$T/state JG_POLL=0.2 JG_SIGNAL_GRACE=0 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999
S=$T/state
BEAT=$S/.last-watcher-beat
mkdir -p "$S"
log() { printf '%s\n' "$*" | tee -a "$OUT/beacon-ages.txt"; }
fail() { log "FAIL: $*"; exit 1; }
: > "$OUT/beacon-ages.txt"
# shellcheck source=/dev/null
. "$REPO/bin/jg-wake-lib.sh"
# shellcheck source=/dev/null
. "$REPO/bin/jg-supervision-lib.sh"
age() { if [ -e "$BEAT" ]; then echo "$(jg_path_age "$BEAT")s"; else echo absent; fi; }
fresh() { jg_supervision_status "$S" 300 >/dev/null 2>&1; echo "$JG_SUP_WATCHER_FRESH"; }
touch -t "$(date -d "@$(( $(date +%s) - 600 ))" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$(( $(date +%s) - 600 ))" +%Y%m%d%H%M.%S)" "$BEAT"
printf 'x\n' > "$S/job.meta"
log "previous cycle's beacon age: $(age)"
printf 'done: first scan event\n' > "$S/task.status"
"$REPO/bin/jg-watch-arm.sh" > "$T/arm.out" 2>&1 || true
grep -q '^signal:' "$T/arm.out" || fail "the watcher did not end its cycle on the signal: $(cat "$T/arm.out")"
rm -f "$S/.last-watcher-handoff"
log "after the actionable exit, hand-off stamp aged out: beacon age $(age), supervised=$(fresh)"
[ "$(fresh)" = true ] || fail "the home reads as unsupervised after an actionable exit"
jq -n '{target:{version:"jg-watch.sh from this branch"},
  start:"a home whose previous watcher cycle left a 10 minute old beacon, with one task signal waiting",
  steps:["the watcher is armed and ends its cycle on the task signal","the hand-off stamp ages out","the supervision read is taken"],
  result:"the home still reads as supervised after the actionable exit"}' > "$OUT/steps.json"
log PASS
