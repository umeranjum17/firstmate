#!/usr/bin/env bash
# quota-failover e2e: the real script against a fixture home (one stub lib
# symlinked under the four names it sources, stub quota-axi and opencode on
# PATH). The fixture is the 15 Oct ~21:55Z step-5-preview-free incident: a
# lead whose pinned route answers its one-line test with a 429, and a worker
# whose screen shows a limit on a second dead route. One pass must move both
# to the live candidate, pass the dead routes over, and drop them from
# crew-dispatch.json; a second pass with the routes answering again must
# restore them and move nothing. Needs bash, jq, flock, timeout, sed and stat
# on PATH; no real tool or home is touched.
set -u

here=$(cd "$(dirname "$0")" && pwd) || exit 1
[ -f "$here/../quota-failover" ] || { echo "not ok - $here/../quota-failover is missing"; exit 1; }
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
home=$work/home stub=$work/bin
mkdir -p "$home/state" "$home/config" "$home/bin" "$stub"

fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }
has() { if grep -q -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1: $2 lacks [$3]"; fi; }
count() { local got; got=$(grep -c -- "$3" "$2" 2>/dev/null) || got=0; is "$1" "$got" "$4"; }

# The fixture's firstmate surface: one stub lib (screens are state/<id>.screen,
# an fm-control relaunch clears the task's screen and status), the two exec'd
# scripts, and the CLI stubs.
awk -v w="$work" '
  /^#--- / { file = w "/" substr($0, 6); next }
  file { print > file }
' <<'STUBS' || exit 1
#--- home/bin/fm-stub-lib.sh
# shellcheck shell=bash
fm_meta_get() { [ -f "$1" ] || return 0; sed -n "s|^$2=||p" "$1" | tail -n 1; }
fm_backend_of_meta() { echo fixture; }
fm_backend_target_of_meta() { fm_meta_get "$1" endpoint_task_id; }
fm_backend_visible_capture() { [ -f "$FM_HOME/state/$2.screen" ] && cat "$FM_HOME/state/$2.screen"; return 0; }
fm_busy_classify_meta() { echo 'idle no-busy-record'; }
fm_busy_record_read() { echo ''; }
FM_QUOTA_ROW_JQ='def quota_lane($harness; $model): ""; def quota_row($snapshot; $provider; $lane): null;'
fm_quota_json_valid() { jq -e '.schemaVersion == 5 and (.providers | type) == "array"' >/dev/null 2>&1; }
fm_quota_single_provider_for_harness() { return 1; }
fm_parent_channel_report() { printf '%s\n' "$3" >>"$1/state/parent-channel.log"; }
#--- home/bin/fm-crew-state.sh
#!/usr/bin/env bash
echo 'state: working · source: fixture'
#--- home/bin/fm-control.sh
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FM_HOME/state/fm-control.log"
[ "${2:-}" = relaunch ] || exit 0
id=${1:-}
rm -f "$FM_HOME/state/$id.screen"
date +%s >"$FM_HOME/state/$id.status"
#--- bin/opencode
#!/usr/bin/env bash
# Every model answers PONG except the two dead routes, which answer the
# 15 Oct 429, "Upstream request failed: Rate limit exceeded".
case $* in
  *step-5-preview-free*) [ "${OC_STEP5:-dead}" = dead ] || { echo PONG; exit 0; } ;;
  *gpt-5.6-luna*) [ "${OC_LUNA:-dead}" = dead ] || { echo PONG; exit 0; } ;;
  *) echo PONG; exit 0 ;;
esac
echo 'ERROR: 429 Upstream request failed: Rate limit exceeded'
exit 1
#--- bin/quota-axi
#!/usr/bin/env bash
echo '{"schemaVersion":5,"providers":[]}'
STUBS
for lib in fm-backend.sh fm-busy-lib.sh fm-quota-axi-lib.sh fm-parent-channel-lib.sh; do
  ln -s fm-stub-lib.sh "$home/bin/$lib" || exit 1
done
chmod +x "$home/bin/fm-crew-state.sh" "$home/bin/fm-control.sh" "$stub/opencode" "$stub/quota-axi"

# Step 5 ranked first (as on 15 Oct), a second dead route, then the live ones.
cat >"$home/config/crew-dispatch.json" <<'JSON' || exit 1
{"rules": [{"when": "free preview models first", "use": [
  {"harness": "opencode", "model": "opencode-go/step-5-preview-free"},
  {"harness": "opencode", "model": "openai-codex/gpt-5.6-luna"},
  {"harness": "opencode", "model": "opencode-go/mimo-v2.6-flash"}]}],
 "default": [{"harness": "opencode", "model": "opencode-go/deepseek-v4.1-flash"}]}
JSON

# lead1 (a secondmate) sits on the 429 route with a clean screen: only the
# pinned-route provider-error test can move it. w1 sits on the second dead
# route with the usage-limit text on its screen.
printf 'endpoint_task_id=lead1\nharness=opencode\nmodel=opencode-go/step-5-preview-free\nkind=secondmate\nspawn_gen=s0.lead1\n' \
  >"$home/state/lead1.meta" || exit 1
printf 'endpoint_task_id=w1\nharness=opencode\nmodel=openai-codex/gpt-5.6-luna\nkind=crewmate\nspawn_gen=s0.w1\n' \
  >"$home/state/w1.meta" || exit 1
printf '%s\n' "You've hit your usage limit for your plan; try again in 3h" >"$home/state/w1.screen"

log=$home/state/quota-failover.log ctl=$home/state/fm-control.log
dead=$home/state/quota-failover-dead.json disp=$home/config/crew-dispatch.json
run() { # one watcher pass, with the knobs the fixture needs
  PATH="$stub:$PATH" FM_HOME=$home QUOTA_FAILOVER_PROBE_SECS=0 \
    QUOTA_FAILOVER_RETEST_SECS=${RETEST_SECS:-1800} "$here/../quota-failover" "$home"
}

run

has "pass1: the lead moved to the live candidate" "$log" \
  'lead1: switched opencode opencode-go/step-5-preview-free -> opencode opencode-go/mimo-v2.6-flash'
has "pass1: the screen-stopped worker moved to the live candidate" "$log" \
  'w1: switched opencode openai-codex/gpt-5.6-luna -> opencode opencode-go/mimo-v2.6-flash'
has "pass1: the dead 429 route was passed over, not chosen for a move" "$log" \
  'passed over opencode-go/step-5-preview-free is out of dispatch'
count "pass1: two relaunches onto the live candidate" "$ctl" \
  ' relaunch --harness opencode --model opencode-go/mimo-v2.6-flash ' 2
is "pass1: the dead routes are gone from new dispatch" \
  "$(grep -Eo 'step-5-preview-free|gpt-5.6-luna' "$disp" 2>/dev/null | sort -u | paste -sd, -)" ""

# The routes answer again: one pass restores them to dispatch and moves
# nothing back.
OC_STEP5=alive OC_LUNA=alive RETEST_SECS=0 run

count "pass2: no further moves" "$ctl" ' relaunch ' 2
is "pass2: the dead list is empty" "$(jq -c . "$dead")" '[]'
is "pass2: every route is back in dispatch" \
  "$(jq -r '.rules[0].use[].model' "$disp" | sort | paste -sd, -)" \
  "openai-codex/gpt-5.6-luna,opencode-go/mimo-v2.6-flash,opencode-go/step-5-preview-free"

if [ "$fails" -eq 0 ]; then
  echo "quota-failover e2e: all assertions held"
else
  echo "quota-failover e2e: $fails assertion(s) failed"
  exit 1
fi
