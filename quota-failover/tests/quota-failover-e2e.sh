#!/usr/bin/env bash
# quota-failover e2e: the real script against a fixture home (one stub lib
# symlinked under the five names it sources, stub quota-axi and opencode on
# PATH). The fixture is a step-5-preview-free incident: a
# lead whose pinned route answers its one-line test with a 429, and a worker
# whose screen shows a limit on a second dead route. One pass must move both
# to the live candidate, pass the dead routes over, and drop them from
# crew-dispatch.json; a second pass with the routes answering again must
# restore them and move nothing. Passes 3 to 7 add workers on pool
# accounts: with config/account-pool-autorelaunch present a Claude worker
# moves to the next account, a Claude worker with no next account takes the
# route move, and OpenCode Go and Codex workers only rest; with the file gone
# a Claude worker only rests, once, and rests and wakes again when the same
# account stops a new incarnation, while a pool rest that fails still wakes
# the home, once; a pool worker wedged with a clean screen still loses its
# route to the pinned probe's verdict. Needs bash, jq, flock, timeout, sed and stat
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
fm_account_pool_config() { [ ! -f "$1/account-pool" ] || printf 'byokit-accounts\t/pool\n'; }
fm_account_pool_rest() { [ "$3" = deadpool ] && { echo "pool lib broken at $(date +%s%N)" >&2; return 1; }; printf 'rest %s\n' "$3" >>"$FM_HOME/state/pool.log"; }
#--- home/bin/fm-crew-state.sh
#!/usr/bin/env bash
echo 'state: working · source: fixture'
#--- home/bin/fm-control.sh
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FM_HOME/state/fm-control.log"
[ "${2:-}" = relaunch ] || exit 0
id=${1:-}
# d1's pool has no next account ready, as fm-control answers after its rest.
[ "$id $3 $4" != "d1 --account next" ] || { echo "error: config/account-pool cannot start a claude worker: no account is ready"; exit 1; }
rm -f "$FM_HOME/state/$id.screen"
date +%s >"$FM_HOME/state/$id.status"
#--- bin/opencode
#!/usr/bin/env bash
# Every model answers PONG except the two dead routes, which answer the
# 429, "Upstream request failed: Rate limit exceeded".
case $* in
  *step-5-preview-free*) [ "${OC_STEP5:-dead}" = dead ] || { echo PONG; exit 0; } ;;
  *gpt-5.6-luna*) [ "${OC_LUNA:-dead}" = dead ] || { echo PONG; exit 0; } ;;
  *) echo PONG; exit 0 ;;
esac
echo 'ERROR: 429 Upstream request failed: Rate limit exceeded'
exit 1
#--- bin/claude
#!/usr/bin/env bash
if [ "${CLAUDE_LIMIT:-}" = yes ]; then
  echo "You've hit your usage limit for your plan; try again in 3h"
  exit 1
fi
echo PONG
#--- bin/quota-axi
#!/usr/bin/env bash
echo '{"schemaVersion":5,"providers":[]}'
STUBS
for lib in fm-backend.sh fm-busy-lib.sh fm-quota-axi-lib.sh fm-parent-channel-lib.sh fm-account-pool-lib.sh; do
  ln -s fm-stub-lib.sh "$home/bin/$lib" || exit 1
done
chmod +x "$home/bin/fm-crew-state.sh" "$home/bin/fm-control.sh" "$stub/opencode" "$stub/claude" "$stub/quota-axi"

# Step 5 ranked first, a second dead route, then the live ones.
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
is "pass1: only the probe-confirmed dead route leaves dispatch" \
  "$(grep -Eo 'step-5-preview-free|gpt-5.6-luna' "$disp" 2>/dev/null | sort -u | paste -sd, -)" "gpt-5.6-luna"

# The routes answer again: one pass restores them to dispatch and moves
# nothing back.
OC_STEP5=alive OC_LUNA=alive RETEST_SECS=0 run

count "pass2: no further moves" "$ctl" ' relaunch ' 2
is "pass2: the dead list is empty" "$(jq -c . "$dead")" '[]'
is "pass2: every route is back in dispatch" \
  "$(jq -r '.rules[0].use[].model' "$disp" | sort | paste -sd, -)" \
  "openai-codex/gpt-5.6-luna,opencode-go/mimo-v2.6-flash,opencode-go/step-5-preview-free"

# Pool workers, each stopped with the limit on its screen.
printf 'state=/pool\n' >"$home/config/account-pool"
touch "$home/config/account-pool-autorelaunch"
pool() { # <id> <harness> <model> <account> [generation]
  printf 'endpoint_task_id=%s\nharness=%s\nmodel=%s\nkind=crewmate\nspawn_gen=%s\naccount=%s\n' \
    "$1" "$2" "$3" "${5:-s0.$1}" "$4" >"$home/state/$1.meta"
  printf '%s\n' "You've hit your usage limit for your plan; try again in 3h" >"$home/state/$1.screen"
}
pool a1 claude claude-opus-4-8 c1
pool d1 claude claude-opus-4-8 c2
pool g1 opencode opencode-go/mimo-v2.6-flash go1
pool x1 codex gpt-5.5-codex cx1
pooll=$home/state/pool.log wake=$home/state/quota-failover.wake

run

has "pass3: the Claude worker moved to the next pool account" "$ctl" '^a1 relaunch --account next --note-file '
count "pass3: and took no route move" "$ctl" '^a1 relaunch --harness' 0
has "pass3: the move is logged with the old account" "$log" 'a1: moved claude claude-opus-4-8 off account c1 to the next claude account'
has "pass3: with no next account the existing route move still happens" "$ctl" \
  '^d1 relaunch --harness opencode --model opencode-go/deepseek-v4.1-flash '
count "pass3: OpenCode Go never moves accounts or routes" "$ctl" '^g1 ' 0
count "pass3: Codex never moves accounts or routes" "$ctl" '^x1 ' 0
is "pass3: Go and Codex accounts rested" "$(sort "$pooll" | paste -sd, -)" "rest cx1,rest go1"
has "pass3: the Go wake names the account and the manual command" "$wake" \
  'g1 stopped on opencode opencode-go/mimo-v2.6-flash account go1 .*bin/fm-control.sh g1 relaunch --account <id>$'
is "pass3: an account limit leaves the route in dispatch" "$(jq -c . "$dead")" '[]'

# The switch file is gone: a Claude pool worker only rests, a second pass
# rests and wakes nothing more, and a worker whose pool rest fails still
# wakes the home, once.
rm -f "$home/config/account-pool-autorelaunch" "$wake" "$pooll"
pool b1 claude claude-opus-4-8 c3
pool f1 claude claude-opus-4-8 deadpool
run
run

count "pass4: no relaunch without the switch file" "$ctl" '^b1 ' 0
count "pass4: no relaunch for the failed-rest worker either" "$ctl" '^f1 ' 0
is "pass4: the account rested once" "$(cat "$pooll")" "rest c3"
has "pass4: one log line names the account and the manual command" "$log" \
  'b1: stopped on claude claude-opus-4-8 account c3 .*bin/fm-control.sh b1 relaunch --account <id|next>$'
has "pass4: a failed rest is logged with the pool's error" "$log" \
  'f1: stopped on claude claude-opus-4-8 account deadpool .*rest failed (pool lib broken at [0-9]*), move it by hand'
has "pass4: a failed rest still wakes the home with the account named" "$wake" \
  'f1 stopped on claude claude-opus-4-8 account deadpool .*bin/fm-control.sh f1 relaunch --account <id|next>$'
count "pass4: one wake line per stopped worker" "$wake" '' 2

# The home takes the wake's advice and relaunches b1 on the same account c3;
# the new incarnation hits the limit again, and the rest and the wake happen
# once per stop, so both fire again.
pool b1 claude claude-opus-4-8 c3 s1.b1
run

is "pass5: the same account rests again for the new incarnation" "$(cat "$pooll")" "rest c3
rest c3"
count "pass5: and the wake fires again for the new stop" "$wake" 'b1 stopped' 2
count "pass5: the failed-rest wake stays at one line" "$wake" 'f1 stopped' 1

# A pool worker wedged with a clean screen on the 429 route: only the
# route-scoped pinned probe sees the outage, and it must still take the
# route out of dispatch while the worker itself rests and wakes.
printf 'endpoint_task_id=q1\nharness=opencode\nmodel=opencode-go/step-5-preview-free\nkind=crewmate\nspawn_gen=s0.q1\naccount=go9\n' \
  >"$home/state/q1.meta"
run

is "pass6: the pinned probe takes the pool worker's route out" \
  "$(jq -r '.[].model' "$dead" | paste -sd, -)" "opencode-go/step-5-preview-free"
is "pass6: and the route leaves new dispatch" \
  "$(grep -Eo 'step-5-preview-free' "$disp" 2>/dev/null | sort -u | paste -sd, -)" ""
has "pass6: the worker itself still rests and wakes" "$wake" \
  'q1 stopped on opencode opencode-go/step-5-preview-free account go9 .*bin/fm-control.sh q1 relaunch --account <id>$'

# The next pass sees q1's route as already out of dispatch instead of
# probe-detected, but the stop is the same one: nothing rests or wakes again.
run

count "pass7: the stop's changed label re-fires nothing" "$wake" 'q1 stopped' 1
is "pass7: and the out route is not rested a second time" "$(cat "$pooll")" "rest c3
rest c3
rest go9"

# Wrapper/file text is not Claude's limit banner and must not remove its route.
printf '[]\n' >"$dead"
printf '{"rules":[],"default":[{"harness":"claude","model":"claude-haiku-5-5"}]}\n' >"$disp"
printf 'endpoint_task_id=cw\nharness=claude\nmodel=claude-haiku-5-5\nkind=crewmate\nspawn_gen=s0.cw\n' >"$home/state/cw.meta"
printf 'quota exhausted' >"$home/state/cw.screen"
run
is "pass8: wrapper text leaves Haiku dispatch intact" "$(jq -r '.default[0].model' "$disp")" claude-haiku-5-5
is "pass8: wrapper text does not mark Haiku dead" "$(jq -r 'any(.[]; .model == "claude-haiku-5-5")' "$dead")" false

# The actual Claude banner is confirmed by the one-line probe before removal.
printf "%s\n" "You've hit your usage limit for your plan; try again in 3h" >"$home/state/cw.screen"
CLAUDE_LIMIT=yes run
is "pass9: confirmed Claude limit removes Haiku" "$(jq -r '.default // [] | length' "$disp")" 0
is "pass9: confirmed Claude limit is recorded out" "$(jq -r 'any(.[]; .model == "claude-haiku-5-5")' "$dead")" true

if [ "$fails" -eq 0 ]; then
  echo "quota-failover e2e: all assertions held"
else
  echo "quota-failover e2e: $fails assertion(s) failed"
  exit 1
fi
