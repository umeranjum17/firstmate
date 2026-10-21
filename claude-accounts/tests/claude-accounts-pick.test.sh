#!/usr/bin/env bash
# claude-accounts-pick: drive the account-pool add-on's own fm_account_pool_select (what fm-spawn calls)
# with config/account-pool pointing at the chooser, a fixture muxr registry and a stub quota-axi whose
# readings change per case. New workers go to the account with the most runway and switch when one runs low.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
w=$(mktemp -d "${TMPDIR:-/tmp}/claude-accounts-pick-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
mkdir -p "$w/home/fixture/users/user-017" "$w/home/fixture/users/user-010" "$w/bin" "$w/a1" "$w/a2" "$w/pool" "$w/other"
cat > "$w/registry.json" <<R
{"version":1,"accounts":[
 {"id":"one","provider":"claude","name":"One","folder":"$w/a1"},
 {"id":"two","provider":"claude","name":"Two","folder":"$w/a2"}]}
R
printf 'state=%s\ncommand=%s\n' "$w/pool" "$addons/claude-accounts/bin/claude-accounts-pick" > "$w/home/fixture/users/user-010/account-pool"
# The stub reads "<5h left> <7d left>" for each account folder from a1.q / a2.q.
cat > "$w/bin/quota-axi" <<'S'
#!/usr/bin/env bash
[ ! -e "$QDIR/limit" ] || { echo '{"providers":[{"windows":[],"state":{"error":"rate limited"}}]}'; exit 1; }
read -r h d < "$QDIR/$(basename "$CLAUDE_CONFIG_DIR").q" || exit 2
echo "{\"providers\":[{\"windows\":[{\"id\":\"five_hour\",\"percentRemaining\":$h},{\"id\":\"seven_day\",\"percentRemaining\":$d}]}]}"
S
chmod +x "$w/bin/quota-axi"
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
pick() { # [tool] [want]: sets out and rc from the pool pick
  # shellcheck disable=SC2016
  out=$(env -i PATH="$w/bin:$PATH" HOME="$w" TMPDIR="$w" QDIR="$w" FM_HOME="$w/home" FM_CLAUDE_ACCOUNTS_REGISTRY="$w/registry.json" \
    FM_CLAUDE_ACCOUNTS_FRESH=0 CODEX_HOME="$w/other" bash -c 'fm_run_timed() { shift; "$@"; }; . "$1/account-pool/bin/fm-account-pool-lib.sh"; shift; fm_account_pool_select "$@"' _ "$addons" "${1:-claude}" "$w/home/fixture/users/user-010" "${2:-}" 2>&1); rc=$?
}
q() { echo "$2" > "$w/$1.q"; }

q a1 "63 34"; q a2 "100 69"
pick; is "account 2 has the most runway: the worker goes there" "$rc|$(cut -f1,3 <<<"$out")" "0|two	$w/a2"
is "the pick unsets the credential variables by name" "$(cut -f4 <<<"$out" | tr ' ' '\n' | grep -c '^ANTHROPIC_API_KEY$')" 1
q a2 "100 3"; pick; is "account 2 runs low: new workers go to account 1" "$rc|$(cut -f1 <<<"$out")" "0|one"
# Rate limit on the vendor side: the pick still uses the last good readings.
q a1 "63 34"; q a2 "100 69"; pick; touch "$w/limit"
pick; is "a failed read keeps the last good pick" "$(cut -f1 <<<"$out")" two
rm "$w/limit"
q a2 "40 80"; pick; is "the tighter window sets the runway: account 2 (40) beats account 1 (34)" "$(cut -f1 <<<"$out")" two
q a1 "63 34"; q a2 "100 69"; pick claude one; is "--prefer an account that is fine" "$(cut -f1 <<<"$out")" one
q a2 "100 3"; pick claude two; is "--prefer a low account is refused with the cause" "$rc|${out%%:*}" "1|error"
q a1 "2 90"; pick; is "every account low: refused" "$rc|$(grep -c 'no Claude account has quota to spare' <<<"$out")" "1|1"
pick codex; is "other tools keep their ambient default" "$rc|$(cut -f1,3 <<<"$out")" "0|ambient	$w/other"

# install wires config/account-pool, is idempotent, refuses a different file; uninstall removes only its own.
rm -f "$w/home/fixture/users/user-010/account-pool"
"$addons/claude-accounts/install.sh" "$w/home" >/dev/null; is "install writes the chooser into config/account-pool" "$(sed -n 1p "$w/home/fixture/users/user-010/account-pool")" "command=$addons/claude-accounts/bin/claude-accounts-pick"
"$addons/claude-accounts/install.sh" "$w/home" >/dev/null; is "install twice is a no-op" "$?" 0
"$addons/claude-accounts/uninstall.sh" "$w/home" >/dev/null; is "uninstall removes it" "$([ -e "$w/home/fixture/users/user-010/account-pool" ] && echo kept || echo gone)" gone
printf 'state=/x\ncommand=/bin/other\n' > "$w/home/fixture/users/user-010/account-pool"
"$addons/claude-accounts/install.sh" "$w/home" >/dev/null 2>&1; is "install refuses another pool file" "$?" 1
"$addons/claude-accounts/uninstall.sh" "$w/home" >/dev/null 2>&1; is "uninstall leaves another pool file" "$?|$(grep -c other "$w/home/fixture/users/user-010/account-pool")" "1|1"

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
