#!/usr/bin/env bash
# account-pool: drive the fm-spawn and fm-control hook lines (the exact form a Kun fm-spawn.sh and
# fm-control.sh carry) against a stub byokit-accounts and a throwaway config. Add-on present = the
# pool pick lands in the launch line and record, and relaunch --account rests and moves; add-on
# absent = every hook line is a silent no-op (Kun behavior).
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
w=$(mktemp -d "${TMPDIR:-/tmp}/account-pool-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
mkdir -p "$w/config" "$w/folder-acct1" "$w/folder-acct2" "$w/bin" "$w/empty" "$w/pool"
printf 'state=%s\ncommand=%s\n' "$w/pool" "$w/bin/byokit-accounts" > "$w/config/account-pool"
printf 'fm_run_timed() { shift; "$@"; }\n' > "$w/bin/fm-timeout-lib.sh"
# The stub pool: pick answers acct1 until it rests, then acct2, or the --prefer id; status names a
# go* account's tool opencode. Every call is logged.
cat > "$w/bin/byokit-accounts" <<'POOL'
#!/usr/bin/env bash
echo "$*" >> "$TMPDIR/pool.log"
case $1 in
  status) case $2 in go*) echo '{"tool":"opencode"}' ;; *) echo '{"tool":"claude"}' ;; esac ;;
  rest) touch "$TMPDIR/rested-$2" ;;
  pick)
    id=acct1; [ ! -e "$TMPDIR/rested-acct1" ] || id=acct2; [ "$4" != --prefer ] || id=$5
    echo "{\"ok\":true,\"id\":\"$id\",\"set\":{\"CLAUDE_CONFIG_DIR\":\"$TMPDIR/folder-$id\"},\"unset\":[\"ANTHROPIC_API_KEY\",\"CLAUDE_CODE_OAUTH_TOKEN\"]}" ;;
esac
POOL
chmod +x "$w/bin/byokit-accounts"
# The hook lines at their call sites, in fm-spawn.sh order.
cat > "$w/fake-spawn.sh" <<'FAKE'
CONFIG=$TEST_CONFIG HARNESS=claude WORKER_ACCOUNT=${TEST_PIN:-} LAUNCH=claude SPAWN_ACCOUNT= RELAUNCH=0
SCRIPT_DIR=$TEST_BIN
shell_quote() { printf '%q' "$1"; }
_fm_ap=${FM_ADDONS_DIR:-${FM_HOME:-$SCRIPT_DIR/..}/projects/firstmate-addons}/account-pool/bin/fm-account-pool-lib.sh; { [ -r "$_fm_ap" ] && . "$_fm_ap"; } || fm_account_hook() { :; }
eval "$(fm_account_hook argv "$@")"
case " $* " in *" --relaunch "*) RELAUNCH=1 ;; esac
fm_account_hook spawn-validate || exit 1
[ -z "${TEST_RAW:-}" ] || fm_account_hook raw-launch "$CONFIG" || exit 1
fm_account_hook spawn-pick "$HARNESS" "$CONFIG" "$WORKER_ACCOUNT" "${POOL_ACCOUNT_WANT:-}" || exit 1
[ -z "${CLAUDE_CONFIG_DIR:-}" ] || LAUNCH="CLAUDE_CONFIG_DIR=$(shell_quote "$CLAUDE_CONFIG_DIR") $LAUNCH"
fm_account_hook launch-prefix "$HARNESS" "$WORKER_ACCOUNT"
fm_account_hook spawn-line
fm_account_hook record-line
echo "launch=$LAUNCH spawn_account=$SPAWN_ACCOUNT args=$*"
FAKE
# fm-control.sh's lines: parse, verb check, preflight pool half, last pre-stop step, spawn args.
cat > "$w/fake-control.sh" <<'FAKE'
SCRIPT_DIR=$TEST_BIN VERB=$1 CONFIG=$TEST_CONFIG
shift
fm_worker_account_resolve() { [ -z "${TEST_PIN:-}" ] || printf 'ordinary\t\t\n'; }
_fm_ap=${FM_ADDONS_DIR:-${FM_HOME:-$SCRIPT_DIR/..}/projects/firstmate-addons}/account-pool/bin/fm-account-pool-lib.sh; { [ -r "$_fm_ap" ] && . "$_fm_ap"; } || fm_account_hook() { :; }
eval "$(fm_account_hook argv "$@")"
[ "$#" -eq 0 ] || { echo "error: unexpected argument '$1'" >&2; exit 1; }
fm_account_hook control-validate "$VERB" || exit 1
fm_account_hook relaunch-pre claude "$CONFIG" "" "$TEST_RECORDED" "" t1 || exit 1
fm_account_hook relaunch-commit claude "$CONFIG" "$TEST_RECORDED" || exit 1
spawn_args=(t1 --relaunch --harness claude)
fm_account_hook spawn-args
FM_CONTROL_RELAUNCH_TX=tx bash "$TEST_SPAWN" "${spawn_args[@]}"
FAKE
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
run() { # run <addons-dir> <script> [args...]: sets out and rc, from a fresh pool
  local a=$1 s=$2; shift 2
  rm -f "$w"/rested-*; : > "$w/pool.log"
  out=$(env -i PATH="$PATH" HOME="$w" TMPDIR="$w" FM_ADDONS_DIR="$a" TEST_BIN="$w/bin" TEST_CONFIG="$w/config" \
    TEST_RAW="${TEST_RAW:-}" TEST_PIN="${TEST_PIN:-}" TEST_RECORDED="${TEST_RECORDED-acct1}" \
    TEST_SPAWN="$w/fake-spawn.sh" bash "$w/$s" "$@" 2>&1); rc=$?
}
run1() { is "$1" "$rc|${out##*$'\n'}" "$2"; }
run2() { is "$1" "$(grep -c "$2" "$w/pool.log")" "$3"; }

run "$addons" fake-spawn.sh
is "present: the pick lands in the launch line, spawned line and record" "$rc|$out" "0|account=acct1
launch=env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR=$w/folder-acct1 claude spawn_account= account=acct1 args="
TEST_RAW=1 run "$addons" fake-spawn.sh;       is "present: a raw launch is refused while the pool exists" "$rc" 1
run "$w/empty" fake-spawn.sh;                 is "absent: every hook line is a silent no-op" "$rc|$out" "0|launch=claude spawn_account= args="
TEST_RAW=1 run "$w/empty" fake-spawn.sh;      is "absent: a raw launch is not refused" "$rc" 0

run "$addons" fake-control.sh relaunch --account next
run1 "relaunch --account next: the replacement launches on the next account, no key or token" \
  "0|launch=env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR=$w/folder-acct2 claude spawn_account= account=acct2 args=t1 --relaunch --harness claude"
run2 "relaunch --account next: the recorded account rests once, before the stop" "^rest acct1 " 1
run "$addons" fake-control.sh relaunch --account=acct2; run2 "relaunch --account <id>: nothing rests" "^rest " 0
is "relaunch --account <id>: the launch is on exactly that account" "$rc|${out##*account=}" "0|acct2 args=t1 --relaunch --harness claude"
TEST_RECORDED=go1 run "$addons" fake-control.sh relaunch --account next; run1 "relaunch --account next off an OpenCode Go account is refused" "1|error: '--account next' cannot move an account of tool 'opencode' automatically; move this worker by hand with 'bin/fm-control.sh t1 relaunch --account <id>'"
run2 "  ... and nothing rests" "^rest " 0
TEST_RECORDED='' run "$addons" fake-control.sh relaunch --account next; run1 "relaunch --account next with no recorded account is refused" "1|error: '--account next' moves the account the running worker launched on, and task t1 records none; move it with '--account <id>' instead"
TEST_PIN=1 run "$addons" fake-control.sh relaunch --account acct2; run1 "relaunch --account under a pin is refused" "1|error: this home pins claude workers to one account, and the pin wins over --account 'acct2'; change or remove the pin file, or relaunch without --account"
run "$addons" fake-control.sh exit --account next; run1 "--account on another verb is refused" "1|error: --account applies to 'relaunch' only"
run "$addons" fake-control.sh relaunch --account; run1 "--account with no value is refused" "1|error: --account requires a value"
run "$addons" fake-control.sh relaunch --account ../x; run2 "a malformed --account: the pool is never asked" "." 0
run1 "a malformed --account is refused" "1|error: --account takes 'next' or one account id, not '../x'"
run "$addons" fake-spawn.sh --account next;   run1 "a fresh launch refuses --account" "1|error: --account applies to a relaunch only; a fresh launch picks its pool account on its own"
run "$addons" fake-spawn.sh --relaunch --account next; run1 "a direct relaunch --account next is refused" "1|error: --account next rests the recorded account only in fm-control's pre-stop gate; a direct relaunch would ignore it and may re-pick the same account - use 'bin/fm-control.sh <task-id> relaunch --account next'"
run "$w/empty" fake-control.sh relaunch --account next; run1 "absent: --account stays the caller's own argument" "1|error: unexpected argument '--account'"
[ "$fails" -eq 0 ]
