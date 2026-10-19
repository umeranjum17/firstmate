#!/usr/bin/env bash
# account-pool: drive the fm-spawn hook lines (the exact form a Kun fm-spawn.sh carries) against a
# stub byokit-accounts and a throwaway config. Add-on present = the pool pick lands in the launch
# line and record; add-on absent = every hook line is a silent no-op (Kun behavior).
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
w=$(mktemp -d "${TMPDIR:-/tmp}/account-pool-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
mkdir -p "$w/config" "$w/folder" "$w/bin" "$w/empty" "$w/pool"
printf 'state=%s\ncommand=%s\n' "$w/pool" "$w/bin/byokit-accounts" > "$w/config/account-pool"
printf 'fm_run_timed() { shift; "$@"; }\n' > "$w/bin/fm-timeout-lib.sh"
printf '#!/usr/bin/env bash\necho %s\n' "'{\"ok\":true,\"id\":\"acct1\",\"set\":{\"CLAUDE_CONFIG_DIR\":\"$w/folder\"},\"unset\":[\"ANTHROPIC_API_KEY\"]}'" > "$w/bin/byokit-accounts"
chmod +x "$w/bin/byokit-accounts"
# The hook lines at their call sites, in fm-spawn.sh order.
cat > "$w/fake-spawn.sh" <<'FAKE'
CONFIG=$TEST_CONFIG HARNESS=claude WORKER_ACCOUNT= LAUNCH=claude SPAWN_ACCOUNT=
SCRIPT_DIR=$TEST_BIN
shell_quote() { printf '%q' "$1"; }
_fm_ap=${FM_ADDONS_DIR:-${FM_HOME:-$SCRIPT_DIR/..}/projects/firstmate-addons}/account-pool/bin/fm-account-pool-lib.sh; { [ -r "$_fm_ap" ] && . "$_fm_ap"; } || fm_account_hook() { :; }
[ -z "${TEST_RAW:-}" ] || fm_account_hook raw-launch "$CONFIG" || exit 1
fm_account_hook spawn-pick "$HARNESS" "$CONFIG" "$WORKER_ACCOUNT" || exit 1
[ -z "${CLAUDE_CONFIG_DIR:-}" ] || LAUNCH="CLAUDE_CONFIG_DIR=$(shell_quote "$CLAUDE_CONFIG_DIR") $LAUNCH"
fm_account_hook launch-prefix "$HARNESS" "$WORKER_ACCOUNT"
fm_account_hook spawn-line
fm_account_hook record-line
echo "launch=$LAUNCH spawn_account=$SPAWN_ACCOUNT"
FAKE
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
run() { # run <addons-dir> [args...]: sets out and rc
  local a=$1; shift
  out=$(env -i PATH="$PATH" HOME="$w" TMPDIR="$w" FM_ADDONS_DIR="$a" TEST_BIN="$w/bin" TEST_CONFIG="$w/config" \
    TEST_RAW="${TEST_RAW:-}" bash "$w/fake-spawn.sh" "$@" 2>&1); rc=$?
}

run "$addons"
is "present: the pick lands in the launch line, spawned line and record" "$rc|$out" "0|account=acct1
launch=env -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR=$w/folder claude spawn_account= account=acct1"
TEST_RAW=1 run "$addons";                      is "present: a raw launch is refused while the pool exists" "$rc" 1
run "$w/empty";                                is "absent: every hook line is a silent no-op" "$rc|$out" "0|launch=claude spawn_account="
TEST_RAW=1 run "$w/empty";                     is "absent: a raw launch is not refused" "$rc" 0
[ "$fails" -eq 0 ]
