#!/usr/bin/env bash
# done-done journey: the watcher's own hold-release and stale-ask ticks against a scratch home with the
# real tasks-axi backlog. A past-dated hold is released and its wake queued, a future-dated and a captain
# hold stay held, a 6h-old blocked line raises the stale-ask wake once, and a reason naming an upcoming
# date without --until is refused at hold time.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${DONE_DONE_EVIDENCE_ROOT:?run through done-done}"
T=$(mktemp -d)
mkdir -p "$T/data" "$T/state" "$T/config"
cp "$REPO/.tasks.toml" "$T/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$T/data/backlog.md"
export JG_TASK_PRIORITY_CHECK=/nonexistent JG_ROOT_OVERRIDE="$REPO" JG_HOME="$T" \
  JG_STATE_OVERRIDE="$T/state" JG_DATA_OVERRIDE="$T/data" JG_CONFIG_OVERRIDE="$T/config"
unset TASKS_AXI_FILE
day() { perl -MPOSIX -e 'print strftime("%Y-%m-%d", gmtime(time + 86400 * $ARGV[0]))' -- "$1"; }
ta() { "$REPO/bin/jg-tasks-axi.sh" "$@"; }
fails=0
main() {
  check() {  # <label> <command...>
    local label=$1; shift
    if "$@"; then echo "PASS $label"; else echo "FAIL $label"; fails=$((fails + 1)); fi
  }
  for id in due later cap; do ta add "$id" "task $id" --priority 1 >/dev/null; done
  ta hold due --reason reset --kind future --until "$(day -1)" >/dev/null
  ta hold later --reason reset --kind future --until "$(day 5)" >/dev/null
  "$REPO/bin/jg-captain-hold.sh" hold cap --reason "pick one" --until "$(day 5)" >/dev/null
  printf 'blocked [at=%s]: hung run\n' "$(( $(date +%s) - 6 * 3600 ))" > "$T/state/old.status"
  echo "--- a future date in a hold reason without --until"
  out=$(ta hold later --reason "wait for the reset on $(day 3)" --kind future 2>&1); rc=$?
  echo "$out"
  check "refused with exit 2" [ "$rc" = 2 ]
  echo "--- both watcher ticks, run once"
  ticks=$(JG_CHECK_INTERVAL=1 JG_HEARTBEAT=1 bash -c '. "$1"
    if hold_release_tick; then jg_wake_append check hold-release "$HOLD_RELEASE_REASON" && echo "hold-release: $HOLD_RELEASE_REASON"; fi
    if stale_ask_tick; then jg_wake_append check stale-ask "$STALE_ASK_REASON" && sweep_asks_record && echo "stale-ask: $STALE_ASK_REASON"; fi' _ "$REPO/bin/jg-watch.sh" 2>&1)
  echo "$ticks"
  check "the hold-release wake names the past-dated task" grep -q "hold-release: .*hold released: due " <<<"$ticks"
  check "the stale-ask wake names the old blocked line" grep -q "stale-ask: .*old blocked 6h" <<<"$ticks"
  check "the wake queue holds both wakes" [ "$(grep -c 'hold-release\|stale-ask' "$T/state/.wake-queue")" = 2 ]
  echo "--- holds after the tick"
  ta list --state queued --fields held,hold_kind
  check "the future-dated hold is still held" [ "$(ta show later | sed -n 's/^  held: //p')" = yes ]
  check "the captain hold is still held" [ "$(ta show cap | sed -n 's/^  held: //p')" = yes ]
  check "the past-dated hold is released" [ "$(ta show due | sed -n 's/^  held: //p')" != yes ]
  echo "--- second tick pass"
  sleep 1
  again=$(JG_CHECK_INTERVAL=1 JG_HEARTBEAT=1 bash -c '. "$1"; hold_release_tick && echo hold; stale_ask_tick && echo ask' _ "$REPO/bin/jg-watch.sh" 2>&1)
  check "nothing fires twice" [ -z "$again" ]
  cp "$T/state/.wake-queue" "$DONE_DONE_EVIDENCE_ROOT/${RUN_ID:-run}.wake-queue" 2>/dev/null || true
  [ "$fails" -eq 0 ] || { echo "$fails checks failed"; exit 1; }
  echo "all checks passed"
}
main 2>&1 | tee "$DONE_DONE_EVIDENCE_ROOT/${RUN_ID:-run}.log"
exit "${PIPESTATUS[0]}"
