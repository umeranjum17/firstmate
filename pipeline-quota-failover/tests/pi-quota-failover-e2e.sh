#!/usr/bin/env bash
# pi-quota-failover e2e: the real wrapper against a stub pi on PATH in a
# throwaway HOME, driven with the exact argv shape no-mistakes builds
# (--model <m> --thinking <e> --mode json --no-session, prompt on stdin).
# The stub's zai/glm-5.3-flash route answers with the fleet's real quota
# error surface (pi exits 0, the error rides in the stream as errorMessage,
# 429 "You've reached your 5-hour usage limit"); claude-bridge/claude-haiku-5-5
# answers normally, or with claude-bridge's Claude subscription-limit surface
# when STUB_HAIKU_DEAD is set. Asserts on the default chain: one glm attempt,
# then one Haiku 5.5 attempt, the successful Haiku stream on stdout, failover
# logged with timings, and the whole call under 10s; a quota-dead Haiku after
# glm ends in the terminal "quota exhausted" line, exit 1. Also covers:
# non-quota (401) passthrough byte-for-byte, pinned-model passthrough, a
# --session resume dropping the session on failover, quota-dead markers (written
# on a quota error, the model skipped while fresh, tried again once expired,
# cleared by an answer), plain passthrough keeping stdin flowing, and install.sh's key-level config edit in a throwaway config.
set -u

here=$(cd "$(dirname "$0")" && pwd) || exit 1
wrapper=$here/../pi-quota-failover
[ -f "$wrapper" ] || { echo "not ok - $wrapper is missing"; exit 1; }

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
home=$work/home stub=$work/bin log=$work/pqf.log
mkdir -p "$home" "$stub"

fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }
# out_has <name> <pattern>: matches against $OUT
out_has() { if printf '%s' "$OUT" | grep -q -- "$2"; then ok "$1"; else no "$1: output lacks [$2]"; fi; }
# out_count <name> <pattern> <want>: counts in $OUT
out_count() { local got; got=$(printf '%s' "$OUT" | grep -c -- "$2") || got=0; is "$1" "$got" "$3"; }
# log_has <name> <pattern>
log_has() { if grep -q -- "$2" "$log" 2>/dev/null; then ok "$1"; else no "$1: $log lacks [$2]"; fi; }
# err_has <name> <file> <pattern>
err_has() { if grep -q -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1: $2 lacks [$3]"; fi; }

# The stub pi: a quota-dead glm route (real 429 usage-limit surface, exit 0),
# a Haiku 5.5 route that is healthy unless STUB_HAIKU_DEAD, and a route that
# echoes the requested model for passthrough checks. Each call's argv is one
# line in $STUB_ARGV.
cat >"$stub/pi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_ARGV"
model=''
prev=''
for a in "$@"; do
  [ "$prev" = "--model" ] && model=$a
  prev=$a
done
printf '%s\n' '{"type":"session","id":"s-1"}'
printf '%s\n' "{\"type\":\"attempt\",\"model\":\"$model\"}"
case $model in
  zai/glm-5.3-flash*)
    printf '%s\n' '{"type":"message_update","errorMessage":"429: {\"message\":\"You'"'"'ve reached your 5-hour usage limit for your plan. Your limit resets at 2026-10-17\"}"}'
    exit 0 ;;
  claude-bridge/claude-haiku-5-5)
    if [ -n "${STUB_HAIKU_DEAD:-}" ]; then
      printf '%s\n' '{"type":"message_update","errorMessage":"Claude rate limit (five_hour) — resets 6:30:00 PM: You'"'"'re out of extra usage · resets 6:30pm"}'
      exit 0
    fi
    printf '%s\n' "{\"type\":\"message_end\",\"role\":\"assistant\",\"model\":\"$model\",\"content\":\"PONG\"}"
    exit 0 ;;
  bad/always-429)
    printf '%s\n' '{"type":"message_update","errorMessage":"429: {\"type\":\"GoUsageLimitError\",\"message\":\"Go usage limit exceeded\"}"}'
    exit 0 ;;
  bad/http401)
    printf '%s\n' '{"type":"message_update","errorMessage":"401: {\"code\":\"401\",\"message\":\"token expired or incorrect\"}"}'
    exit 0 ;;
  *)
    printf '%s\n' "{\"type\":\"message_end\",\"role\":\"assistant\",\"model\":\"$model\",\"content\":\"PONG\"}"
    exit 0 ;;
esac
STUB
chmod +x "$stub/pi"

export PI_QUOTA_FAILOVER_REAL_PI="$stub/pi"
export PI_QUOTA_FAILOVER_LOG="$log" STUB_ARGV=$work/argv
export HOME="$home" XDG_STATE_HOME="$work/state"
PATH="$stub:$PATH"
prompt='Reply with the single word PONG.'
# Quota-dead markers: cleared before journeys that need every model tried.
dead=$work/state/pi-quota-failover-dead
nodead() { rm -f -- "$dead"/*; }
# age_of <model>: seconds since its marker, or "none".
age_of() { local at; read -r _ at 2>/dev/null <"$dead/${1//\//%}" && echo $(($(date +%s) - at)) || echo none; }
backdate() { printf '%s %s\n' "$1" $(($(date +%s) - 3601)) >"$dead/${1//\//%}"; }
fresh() { local a; a=$(age_of "$2"); if [ "$a" != none ] && [ "$a" -lt 5 ]; then ok "$1"; else no "$1: marker age [$a]"; fi; }

is "default chain is GLM, then Haiku 5.5" "$(PI_QUOTA_FAILOVER_PRINT_CHAIN=1 "$wrapper" </dev/null)" \
  "zai/glm-5.3-flash claude-bridge/claude-haiku-5-5"

# 1. Quota failover: glm dead -> Haiku 5.5 answers, one attempt each.
t0=$(date +%s%3N)
OUT=$(printf '%s' "$prompt" | "$wrapper" --model zai/glm-5.3-flash --thinking medium --mode json --no-session 2>"$work/err1")
rc=$?
t1=$(date +%s%3N)
is "failover exits 0" "$rc" "0"
out_has "stdout is the Haiku 5.5 stream" '"model":"claude-bridge/claude-haiku-5-5"'
out_count "no glm attempt delivered" '"model":"zai/glm-5.3-flash"' 0
out_count "no error event delivered" 'errorMessage' 0
log_has "failover logged with timing" "moving to claude-bridge/claude-haiku-5-5"
log_has "log names the failed model" 'model=zai/glm-5.3-flash quota-error'
log_has "log names the quota cause" "usage limit"
if [ "$(grep -c 'quota-error' "$log")" = 1 ]; then ok "exactly one failed attempt (no same-model retry)"; else no "wrong attempt count in log"; fi
if [ $((t1 - t0)) -lt 10000 ]; then ok "failover took $((t1 - t0))ms (< 10s)"; else no "failover took $((t1 - t0))ms, expected < 10s"; fi

# 2. Non-quota failure passes through untouched (pi's real 401 surface, exit 0).
OUT=$(printf '%s' "$prompt" | "$wrapper" --model bad/http401 --mode json --no-session 2>"$work/err2")
is "401 passthrough exits 0" "$?" "0"
out_has "401 stream untouched" "token expired or incorrect"
log_has "no failover for non-quota" "moving to claude-bridge"

# 3. A model outside the chain passes through untouched (pinned profile case).
OUT=$(printf '%s' "$prompt" | "$wrapper" --model kimi/k2 --mode json --no-session 2>"$work/err3")
is "pinned-model passthrough exits 0" "$?" "0"
out_has "pinned stream untouched" '"model":"kimi/k2"'
if [ "$(grep -c 'moving to' "$log")" = 1 ]; then ok "still one failover line total"; else no "unexpected extra failover lines"; fi

# 4. A resumed session is dropped on the failover attempt only.
nodead
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | "$wrapper" --model zai/glm-5.3-flash --mode json --session 01234567-89ab-cdef-0123-456789abcdef 2>"$work/err4")
is "session failover exits 0" "$?" "0"
out_has "failover stream is Haiku 5.5" '"model":"claude-bridge/claude-haiku-5-5"'
is "first attempt keeps the session" "$(sed -n 1p "$STUB_ARGV")" \
  "--model zai/glm-5.3-flash --mode json --session 01234567-89ab-cdef-0123-456789abcdef"
is "failover attempt drops the session" "$(sed -n 2p "$STUB_ARGV")" \
  "--model claude-bridge/claude-haiku-5-5 --mode json"

# 5. Default chain exhausted (glm, then a quota-dead Haiku 5.5): each model
#    once, terminal "quota exhausted", exit 1.
: >"$log"
nodead
OUT=$(printf '%s' "$prompt" | STUB_HAIKU_DEAD=1 "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err5")
rc=$?
is "exhausted chain exits 1" "$rc" "1"
err_has "terminal line present" "$work/err5" "quota exhausted"
if [ -z "$OUT" ]; then ok "no error stream delivered on exhaustion"; else no "stdout should be empty on exhaustion"; fi
if [ "$(grep -c 'quota-error' "$log")" = 2 ]; then ok "each chain model attempted once"; else no "wrong attempt count in log: $(grep -c 'quota-error' "$log")"; fi
log_has "glm attempt logged" 'model=zai/glm-5.3-flash quota-error'
log_has "Haiku 5.5 Claude-limit attempt logged" 'model=claude-bridge/claude-haiku-5-5 quota-error.*Claude rate limit'
log_has "exhaustion logged" "no model left in the chain"

# 5b. Each quota error left a marker holding the model and the time.
fresh "glm marker written" zai/glm-5.3-flash
fresh "Haiku marker written" claude-bridge/claude-haiku-5-5
is "marker names the model" "$(cut -d' ' -f1 "$dead/zai%glm-5.3-flash")" "zai/glm-5.3-flash"

# 5c. Every model inside its window: no pi call at all, terminal line, exit 1.
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err5c")
is "all-skipped chain exits 1" "$?" "1"
err_has "all-skipped terminal line" "$work/err5c" "quota exhausted"
is "no pi call while every marker is fresh" "$(wc -l <"$STUB_ARGV")" "0"
log_has "skip logged with its window" 'model=zai/glm-5.3-flash skipped: quota error [0-9]*s ago (skip window 3600s)'

# 5d. glm fresh, Haiku's window over: glm is skipped, Haiku runs first with the
#     session dropped, and its answer clears its marker.
backdate claude-bridge/claude-haiku-5-5
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | "$wrapper" --model zai/glm-5.3-flash --mode json --session 01234567-89ab-cdef-0123-456789abcdef 2>"$work/err5d")
is "skipped-glm call exits 0" "$?" "0"
out_has "skipped-glm call answers from Haiku" '"model":"claude-bridge/claude-haiku-5-5"'
is "glm skipped: one pi call, Haiku, no session" "$(cat "$STUB_ARGV")" "--model claude-bridge/claude-haiku-5-5 --mode json"
is "Haiku answer cleared its marker" "$(age_of claude-bridge/claude-haiku-5-5)" "none"

# 5e. glm's window over: glm is tried again first, and its new quota error
#     renews the marker.
backdate zai/glm-5.3-flash
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | "$wrapper" --model zai/glm-5.3-flash --mode json --no-session 2>"$work/err5e")
is "expired-marker call exits 0" "$?" "0"
is "expired glm tried again first" "$(sed -n 1p "$STUB_ARGV")" "--model zai/glm-5.3-flash --mode json --no-session"
fresh "glm marker renewed" zai/glm-5.3-flash

# 6. Plain passthrough keeps stdin flowing (prompt reaches the real pi).
OUT=$(printf '%s' "$prompt" | "$wrapper" --model muse-spark-1.3-contributor --mode json --no-session)
is "plain passthrough exits 0" "$?" "0"
out_has "prompt reached pi" "PONG"

# 6b. A profile set to a later chain model fails over to the earlier ones in
# chain order (B2: Muse first, GLM backup), the requested model tried once.
: >"$log"
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_CHAIN='deepseek/deepseek-v4.1-flash bad/always-429 muse-spark-1.3-contributor' "$wrapper" --model bad/always-429 --mode json --no-session 2>"$work/err6b")
is "requested-first failover exits 0" "$?" "0"
out_has "earlier chain model answers" '"model":"deepseek/deepseek-v4.1-flash"'
out_count "later chain model not tried" '"model":"muse' 0
log_has "moves to the earlier chain model" 'model=bad/always-429 quota-error.*moving to deepseek/deepseek-v4.1-flash'
if [ "$(grep -c 'quota-error' "$log")" = 1 ]; then ok "requested model attempted once"; else no "wrong attempt count in log"; fi

# 7. Host-memory gate: runs before pi with no command, its output kept off the stream; a gate still waiting at the
#    bound lets pi start anyway with one log line.
cat >"$stub/gate" <<'GATE'
#!/bin/sh
[ $# -eq 0 ] && echo "gate ran" >>"$GATE_LOG" && echo "fm-mem-gate: waiting" && sleep "${GATE_SLEEP:-0}"
GATE
chmod +x "$stub/gate"
export GATE_LOG=$work/gate.log
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_GATE="$stub/gate" "$wrapper" --model muse-spark-1.3-contributor --mode json --no-session 2>"$work/err7")
is "gated call exits 0" "$?" "0"
is "gate ran once, with no command" "$(cat "$work/gate.log" 2>/dev/null)" "gate ran"
out_has "gated prompt reached pi" "PONG"
out_count "gate output kept off the stream" "fm-mem-gate" 0
OUT=$(printf '%s' "$prompt" | GATE_SLEEP=5 PI_QUOTA_FAILOVER_GATE="$stub/gate" PI_QUOTA_FAILOVER_GATE_SECS=1 "$wrapper" --model muse-spark-1.3-contributor --mode json --no-session 2>"$work/err7b")
is "bounded gate wait still runs pi" "$?" "0"
out_has "pi answered after the bound" "PONG"
log_has "bound logged" "memory gate still waiting after 1s; starting pi anyway"

# 8. install.sh: key-level config edit in a throwaway config, never printing it.
cfg=$work/config.yaml
printf '# no-mistakes global configuration\nagent: pi\nagent_config:\n  pi:\n    model: zai/glm-5.3-flash\n' >"$cfg"
python3 -c 'import yaml' 2>/dev/null || { echo "not ok - python3-yaml missing; skipping install tests"; exit "$fails"; }
if "$here/../install.sh" --dry-run --config "$cfg" --home "$work/share" >"$work/dry" 2>&1; then
  ok "install dry-run exits 0"
else
  no "install dry-run failed"
fi
err_has "dry-run announces the key edit" "$work/dry" "would add key agent_path_override.pi"
before=$(md5sum "$cfg" | cut -d' ' -f1)
if "$here/../install.sh" --config "$cfg" --home "$work/share" >"$work/inst" 2>&1; then
  ok "install exits 0"
else
  no "install failed: $(cat "$work/inst")"
fi
if [ "$before" != "$(md5sum "$cfg" | cut -d' ' -f1)" ]; then ok "config changed"; else no "config unchanged"; fi
if python3 - "$cfg" <<'EOF'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
assert c['agent_path_override']['pi'].endswith('/pi-quota-failover'), c
assert c['agent_config']['pi']['model'] == 'zai/glm-5.3-flash'
assert c['agent'] == 'pi'
EOF
then ok "config parses; only the new key added"; else no "config edit broke YAML"; fi
if "$here/../install.sh" --config "$cfg" --home "$work/share" >/dev/null 2>&1; then
  ok "second install is idempotent"
else
  no "second install failed"
fi
if "$here/../install.sh" --restore --config "$cfg" --home "$work/share" >/dev/null 2>&1; then
  ok "restore exits 0"
else
  no "restore failed"
fi
if python3 -c 'import sys,yaml; c=yaml.safe_load(open(sys.argv[1])); assert "agent_path_override" not in c; assert c["agent"] == "pi"' "$cfg"; then
  ok "restore removed only the added key"
else
  no "restore left the key behind or broke the config"
fi
ls "$cfg".bak-pqf-* >/dev/null 2>&1 && ok "backup written" || no "no backup file"

echo
if [ "$fails" = 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
