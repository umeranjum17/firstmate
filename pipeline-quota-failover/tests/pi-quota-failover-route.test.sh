#!/usr/bin/env bash
# pi-quota-failover route test: the real wrapper against a stub pi and a stub
# quota-axi in a throwaway HOME, with the exact argv shape no-mistakes builds
# (--model <m> --mode json --no-session, prompt on stdin). It pins the
# persisted pipeline route:
#   - the default chain is one route, Claude Haiku through claude-bridge;
#   - a call pinned to that route runs it, and a call pinned to a model outside
#     the chain runs the chain route and never the pinned model;
#   - an openrouter/* route takes the deepseek idle limit (300 s by default),
#     not the short generic one, so a slow answer is not killed;
#   - with an account pool, a bridge call runs on the pool's pick, a Claude
#     limit rests that account and the same route answers on the next one, and
#     with every account rested the call ends "quota exhausted" without ever
#     running on the default login.
# Nothing real is called: no pi, no network, no config. Needs bash, jq,
# timeout and pgrep.
set -u

here=$(cd "$(dirname "$0")" && pwd) || exit 1
wrapper=$here/../pi-quota-failover
[ -f "$wrapper" ] || { echo "not ok - $wrapper is missing"; exit 1; }

# The pipeline route: Claude Haiku through claude-bridge, subscription accounts only.
route=claude-bridge/claude-haiku-5-5
or=openrouter/deepseek/deepseek-v4.1-flash-1017:floor

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
# log_has <name> <pattern>
log_has() { if grep -q -- "$2" "$log" 2>/dev/null; then ok "$1"; else no "$1: $log lacks [$2]"; fi; }

# The stub pi: 'pi list' (the wrapper's extension lookup) prints nothing, so
# the call carries only pi's built-in extensions. A model call answers PONG,
# unless the model is $STUB_SILENT, which stays silent for the idle watchdog.
cat >"$stub/pi" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = list ] && exit 0
printf '%s\n' "$*" >>"$STUB_ARGV"
model=''
prev=''
for a in "$@"; do
  [ "$prev" = "--model" ] && model=$a
  prev=$a
done
[ "$model" = "${STUB_SILENT:-}" ] && { sleep 600; exit 0; }
[ "$1" = --help ] || printf '%s\n' "${CLAUDE_CONFIG_DIR:-default-login}" >>"$STUB_ACCOUNTS"
printf '%s\n' '{"type":"session","id":"s-1"}'
# Only a named account folder listed in STUB_LIMITED answers the limit; a call with no account folder never does.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [[ " ${STUB_LIMITED:-} " = *" ${CLAUDE_CONFIG_DIR##*/} "* ]]; then
  printf '%s\n' '{"type":"message_end","stopReason":"error","errorMessage":"Claude rate limit (five_hour) resets in 3h: You are out of usage"}'
  exit 0
fi
printf '%s\n' "{\"type\":\"message_end\",\"role\":\"assistant\",\"model\":\"$model\",\"content\":\"PONG\"}"
exit 0
STUB
chmod +x "$stub/pi"

# The stub quota-axi: every provider it is asked about is available, so the
# route is never skipped by the pre-check.
cat >"$stub/quota-axi" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_QUOTA_LOG"
p=''
prev=''
for a in "$@"; do
  [ "$prev" = "--provider" ] && p=$a
  prev=$a
done
printf '{"providers":[{"provider":"%s","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","runway":{"status":"known"}}]}}]}\n' "$p"
STUB
chmod +x "$stub/quota-axi"

# The stub pool (config/account-pool's command): accounts a then b, each a folder; a rested account is skipped.
cat >"$stub/pool" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_POOL_LOG"
all="$*" state=${all##*--state }
case $1 in
  rest) [ -z "${STUB_REST_REFUSE:-}" ] || { echo 'error: rest requires low quota with a future reset' >&2; exit 1; }
        mkdir -p "$state/rested" && touch "$state/rested/$2" && echo '{"ok":true}' ;;
  pick) for id in a b; do [ -e "$state/rested/$id" ] && continue
          printf '{"ok":true,"id":"%s","set":{"CLAUDE_CONFIG_DIR":"%s"},"unset":["ANTHROPIC_API_KEY"]}\n' "$id" "$STUB_POOL_DIR/$id"; exit 0; done
        echo '{"ok":false,"reason":"every Claude account is resting"}'; exit 1 ;;
esac
STUB
chmod +x "$stub/pool"
mkdir -p "$work/pool/a" "$work/pool/b" "$work/poolstate"
printf 'command=%s\nstate=%s\n' "$stub/pool" "$work/poolstate" >"$work/account-pool"

# The runner has no login folder set; neither does this test, so a local run matches CI.
unset CLAUDE_CONFIG_DIR
export PI_QUOTA_FAILOVER_REAL_PI="$stub/pi" STUB_ACCOUNTS=$work/accounts STUB_POOL_LOG=$work/pool.log STUB_POOL_DIR=$work/pool
export PI_QUOTA_FAILOVER_LOG="$log" STUB_ARGV=$work/argv STUB_QUOTA_LOG=$work/quota.log
export HOME="$home" XDG_STATE_HOME="$work/state"
PATH="$stub:$PATH"
# The credit probe is one more pi call per run; it has its own journey in the
# e2e test, so it is off here.
export PI_QUOTA_FAILOVER_PROBE=0
prompt='Reply with the single word PONG.'

# 1. The default chain is the persisted pipeline route, one route and only it.
is "default chain is Claude Haiku through claude-bridge" "$(PI_QUOTA_FAILOVER_PRINT_CHAIN=1 "$wrapper" </dev/null)" "$route"

# 2. A call pinned to the config's route runs that route.
: >"$STUB_ARGV"
: >"$STUB_QUOTA_LOG"
OUT=$(printf '%s' "$prompt" | env -u PI_QUOTA_FAILOVER_CHAIN "$wrapper" --model "$route" --mode json --no-session 2>"$work/err2")
is "call on the config's route exits 0" "$?" "0"
out_has "the config's route answers" "\"model\":\"$route\""
is "one pi call" "$(wc -l <"$STUB_ARGV")" "1"
is "quota-axi asked for the route's provider" "$(grep -c -- '--provider claude-bridge ' "$STUB_QUOTA_LOG")" "1"
if grep -q 'skipped' "$log" 2>/dev/null; then no "the route was skipped by the quota pre-check"; else ok "the route is not skipped by the quota pre-check"; fi

# 3. A call pinned to a model outside the chain runs the chain route and never
#    the pinned model: the config's route is the route that runs.
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | env -u PI_QUOTA_FAILOVER_CHAIN "$wrapper" --model openai-codex/gpt-6-luna --mode json --no-session 2>"$work/err3")
is "off-chain pin exits 0" "$?" "0"
out_has "off-chain pin lands on the pipeline route" "\"model\":\"$route\""
is "the pinned model never runs" "$(grep -c 'openai-codex' "$STUB_ARGV")" "0"

# 4. An openrouter/* route takes the deepseek idle limit, not the generic one:
#    4 s of silence survives the generic 1 s limit and is killed by the route's
#    own 5 s limit, then the next chain route answers the same call.
: >"$log"
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | STUB_SILENT="$or" PI_QUOTA_FAILOVER_IDLE_SECS=1 PI_QUOTA_FAILOVER_DEEPSEEK_IDLE_SECS=5 \
  PI_QUOTA_FAILOVER_CHAIN="$or $route" "$wrapper" --model "$or" --mode json --no-session 2>"$work/err4")
is "silent openrouter route exits 0" "$?" "0"
out_has "the next chain route answers" '"model":"claude-bridge/claude-haiku-5-5"'
log_has "the openrouter route is killed by its own limit" "no output for 5s"
if grep -q 'no output for 1s' "$log"; then no "the openrouter route was killed by the generic limit"; else ok "the openrouter route is not killed by the generic limit"; fi

# 5. The same route under the generic limit is killed by it, so the limit is
#    the route's own and not a fixed number.
: >"$log"
: >"$STUB_ARGV"
OUT=$(printf '%s' "$prompt" | STUB_SILENT="$or" PI_QUOTA_FAILOVER_IDLE_SECS=1 PI_QUOTA_FAILOVER_DEEPSEEK_IDLE_SECS=1 \
  PI_QUOTA_FAILOVER_CHAIN="$or $route" "$wrapper" --model "$or" --mode json --no-session 2>"$work/err5")
is "silent openrouter route under a 1 s own limit exits 0" "$?" "0"
log_has "the openrouter route is killed by the 1 s own limit" "no output for 1s"

# 6. With an account pool, the bridge call runs on the pool's pick; account a answers a Claude limit, so a is rested
#    and the same route answers on account b in the same call, with no quota marker for the route.
: >"$log"; : >"$STUB_ARGV"; : >"$STUB_ACCOUNTS"
OUT=$(printf '%s' "$prompt" | STUB_LIMITED=a PI_QUOTA_FAILOVER_ACCOUNT_POOL=$work/account-pool ANTHROPIC_API_KEY=x \
  "$wrapper" --model "$route" --mode json --no-session 2>"$work/err6")
is "a limit on one account still answers" "$?" "0"
out_has "the same route answers" "\"model\":\"$route\""
is "first account a, then b, never the default login" "$(sed 's|.*/||' "$STUB_ACCOUNTS" | paste -sd, -)" "a,b"
is "account a is rested in the pool" "$(grep -c '^rest a ' "$work/pool.log")" "1"
log_has "the move is logged" "quota-error on account a .*same route on account b"
is "no quota marker for the route" "$(find "$work/state" -path "*pi-quota-failover-dead/*" | wc -l)" "0"

# 6b. The pool refuses the rest (its own reading does not show the account low) and picks the same account again:
#     the call ends, but no route marker is written, so the next call goes back to the pool's pick.
rm -rf "$work/poolstate/rested"; : >"$log"; : >"$STUB_ACCOUNTS"
OUT=$(printf '%s' "$prompt" | STUB_LIMITED=a STUB_REST_REFUSE=1 PI_QUOTA_FAILOVER_ACCOUNT_POOL=$work/account-pool \
  "$wrapper" --model "$route" --mode json --no-session 2>"$work/err6b")
is "a refused rest with no other pick fails the call" "$?" "1"
log_has "the pool's refusal is logged" "did not rest account a: error: rest requires low quota"
is "and no route marker is written" "$(find "$work/state" -path "*pi-quota-failover-dead/*" | wc -l)" "0"

# 7. Every account answers a limit: each is rested, the call ends with the terminal "quota exhausted", and nothing
#    runs on the default login. The next call finds no account and runs nothing.
rm -rf "$work/poolstate/rested"; : >"$log"; : >"$STUB_ACCOUNTS"
OUT=$(printf '%s' "$prompt" | STUB_LIMITED='a b' PI_QUOTA_FAILOVER_ACCOUNT_POOL=$work/account-pool "$wrapper" --model "$route" --mode json --no-session 2>"$work/err7")
is "every account limited fails" "$?" "1"
log_has "the chain ends quota exhausted" "quota exhausted on every model"
is "an account limit writes no route marker" "$(find "$work/state" -path "*pi-quota-failover-dead/*" | wc -l)" "0"
is "both accounts tried, never the default login" "$(sed 's|.*/||' "$STUB_ACCOUNTS" | paste -sd, -)" "a,b"
rm -rf "$work/state/pi-quota-failover-dead"; : >"$STUB_ACCOUNTS"
OUT=$(printf '%s' "$prompt" | PI_QUOTA_FAILOVER_ACCOUNT_POOL=$work/account-pool "$wrapper" --model "$route" --mode json --no-session 2>"$work/err8")
is "with every account rested the call fails" "$?" "1"
is "and runs nothing, not even on the default login" "$(wc -l <"$STUB_ACCOUNTS")" "0"
log_has "the pool's reason is logged" "every Claude account is resting"

echo
if [ "$fails" = 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
