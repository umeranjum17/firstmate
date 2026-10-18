#!/usr/bin/env bash
# End to end: install into a throwaway HOME, then drive the hooks and adapters. Only this test's sleeps and fakes are signalled.
# shellcheck disable=SC2016 # the cases are literal commands
set -euo pipefail; unset FM_TASK_ID FM_TASK_INBOX FM_HOME
ADDON=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d); PIDS=()
cleanup() { for p in "${PIDS[@]}"; do pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done; rm -rf -- "$T"; }
trap cleanup EXIT
mkdir -p "$T/home/fixture/users/user-001" "$T/home/fixture/users/user-007/agent" "$T/home/fixture/users/user-003/opencode" "$T/bin"
echo '{"env":{"KEEP":"1"},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other-hook"}]}]}}' > "$T/home/fixture/users/user-001/settings.json"
fail=0; ok() { echo "ok: $*"; }; no() { echo "FAIL: $*"; fail=1; }
inst() { env -u XDG_DATA_HOME HOME="$T/home" "$ADDON/install.sh"; }

inst >/dev/null && inst > "$T/re.out" && [ "$(grep -c '^unchanged: ' "$T/re.out")" -eq 4 ] && ok "reinstall changes nothing" || no "reinstall not idempotent"
jq -e '([.hooks.PreToolUse[].hooks[].command] | index("other-hook") == 0) and .env.KEEP == "1"' "$T/home/fixture/users/user-001/settings.json" >/dev/null && ok "claude settings merged" || no "claude settings merge"

cat > "$T/adapters.mjs" <<'EOF'
process.argv[1] = "/$bunfs/root/pi"; // the compiled pi binary's entry path, which is not on disk
const file = process.argv[2], hooks = {}, pi = file.endsWith(".ts"), mod = await import(file);
if (pi) { mod.default({ on: (n, h) => (hooks[n] = h) }); console.log((await hooks.tool_call({ toolName: "bash", input: { command: "kill 1" } })).reason); }
else { Object.assign(hooks, await mod.FmKillGuard({})); await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "kill 1" } }).catch((e) => console.log(e.message)); }
EOF
for a in "pi:$T/home/fixture/users/user-007/agent/extensions/fm-kill-guard.ts" "opencode:$T/home/fixture/users/user-003/opencode/plugins/fm-kill-guard.js"; do
  out=$(node "$T/adapters.mjs" "${a#*:}" 2>/dev/null || true); [[ "$out" == *"PID 1 (init)"* ]] && ok "${a%%:*} adapter blocks kill 1" || no "${a%%:*} adapter: $out"
done
if command -v pi >/dev/null; then # the real compiled pi, normal HOME: rpc mode loads extensions and exits at stdin EOF
  timeout 60 pi -ne -e "$T/home/fixture/users/user-007/agent/extensions/fm-kill-guard.ts" --mode rpc </dev/null >/dev/null 2>"$T/pi.err" && ok "installed pi loads the extension" || no "pi: $(head -c 300 "$T/pi.err")"
else echo "skip: pi not on PATH"; fi
HOOK=$(jq -r '.hooks.PreToolUse[].hooks[] | select(.command | contains("fm-kill-guard")) | .command' "$T/home/fixture/users/user-001/settings.json")

fake() {
  printf '#!/bin/bash\nsleep 300; true\n' > "$T/bin/$1"; chmod +x "$T/bin/$1"
  "$T/bin/$1" "${@:2}" >/dev/null 2>&1 & FAKE=$!; PIDS+=("$FAKE")
  for _ in $(seq 100); do [ "$(cat "/proc/$FAKE/comm" 2>/dev/null)" = "$1" ] && break; sleep 0.05; done
}
fake systemd --user; SYSD=$FAKE; fake herdr server; HERDR=$FAKE
sleep 300 & C=$!; sleep 300 & S=$!; PIDS+=("$C" "$S")

hook() {
  jq -n --arg c "$2" '{tool_input:{command:$c}}' > "$T/in.json"
  if err=$(node "$T/home/fixture/users/user-004/share/fm-kill-guard/guard.mjs" --caller "$1" < "$T/in.json" 2>&1 >/dev/null); then rc=0; else rc=$?; fi
}
block() { hook "$1" "$2"; [ "$rc" -eq 2 ] && [[ "$err" == *"BLOCKED by the fleet kill guard"* && "$err" == *"$3"* ]] && ok "blocked: $2" || no "not blocked: $2 (rc=$rc) $err"; }
allow() { hook "$1" "$2"; [ "$rc" -eq 0 ] && ok "allowed: $2" || no "blocked: $2 ($err)"; }
retry() { hook "$$" "$1"; [ "$rc" -eq 2 ] && [[ "$err" == *"run kill again with the literal number"* && "$err" != *"block is final"* ]] && ok "asks for the PID: $1" || no "no retry message: $1 (rc=$rc) $err"; }

block "$$" "sh -c 'kill -KILL 1'" 'PID 1 (init)'
block "$$" 'ionice -c3 kill 1' 'PID 1 (init)'
block "$$" "kill $SYSD" 'the systemd user manager'
block "$$" "kill $HERDR" 'the herdr server'
block "$$" 'pkill herd' 'the herdr server'
block "$$" "pkill 'h[[:lower:]]rdr'" 'cannot be resolved'
block "$$" 'killall /usr/bin/herdr' 'cannot be resolved'
block "$$" 'kill -9 -1' 'cannot be resolved'
block "$$" 'xargs kill' 'come from xargs'
block "$$" 'sudo -u root kill -9 1' 'PID 1 (init)'
block "$$" 'timeout -s KILL 5 kill 1' 'PID 1 (init)'
block "$$" "echo \"\$(printf ')'; kill -9 1)\"" 'PID 1 (init)'
block "$$" $'bash <<EOF\nkill -9 1\nEOF' 'PID 1 (init)'
block "$$" $'echo $((1<<2))\nkill -9 1' 'PID 1 (init)'
block "$$" $'echo $((1 << n))\nkill -9 1' 'PID 1 (init)'
block "$$" 'function f { kill -9 1; }; f' 'PID 1 (init)'
block "$$" "env -S 'kill -9 1'" 'PID 1 (init)'
block "$$" 'f(){ kill -9 1; }; f' 'PID 1 (init)'
block "$$" 'diff <(kill 1) /dev/null' 'PID 1 (init)'
block "$$" 'kill>/dev/null 1' 'PID 1 (init)'
block "$$" '../bin/kill 1' 'PID 1 (init)'
block "$C" "kill $S" 'which this task did not start'
allow "$$" "kill $C"
allow "$$" "kill $C 2>/dev/null"
allow "$$" 'diff <(echo hi) /dev/null'
allow "$$" 'grep -r kill src'
allow "$$" "git commit -m 'stop \`kill 1\` leak'"
allow "$$" 'sudo -u root nohup server'
allow "$$" $'git commit -m "$(cat <<\'EOF\'\nkill stale lanes\nEOF\n)"'
retry 'kill "$p"'
retry 'kill $!'
retry 'kill -9 %1'
retry 'echo $(kill -9 $(pgrep -x herdr))'
retry 'kill `cat server.pid` 2>/dev/null'
block "$$" 'kill $p; kill 1' 'PID 1 (init)'
block "$$" 'kill $p 1' 'PID 1 (init)'
block "$$" 'fm-send lane "stop it with `kill -9 1`"' 'PID 1 (init)'
block "$$" $'cat <<EOF\n$(kill -9 1)\nEOF' 'PID 1 (init)'
allow "$$" "fm-send lane 'after Main'\"'\"'s install: \`kill \"\$p\"\` and \`kill 1\` are refused'"
allow "$$" 'fm-send lane "stop it with \`kill -9 1\`"'
allow "$$" 'git commit -m "guard: kill 1; pkill herdr stay refused"'
allow "$$" $'gh pr create --title t --body "$(cat <<\'EOF\'\nRefuses `kill 1` and $(kill 1)\nEOF\n)"'
allow "$$" $'cat > stop.sh <<\'EOF\'\nkill 1\nEOF'

printf 'not json' | node "$T/home/fixture/users/user-004/share/fm-kill-guard/guard.mjs" --caller "$$" 2> "$T/err" && rc=0 || rc=$?
[ "$rc" -eq 2 ] && [[ "$(cat "$T/err")" == *"BLOCKED by the fleet kill guard"* ]] && ok "unparseable hook input blocks" || no "unparseable hook input allowed"

hook "$$" 'kill 1'; sh -c "$HOOK" < "$T/in.json" 2>"$T/err" && rc=0 || rc=$?
[ "$rc" -eq 2 ] && [[ "$(cat "$T/err")" == *"PID 1 (init)"* ]] && ok "installed hook blocks kill 1" || no "installed hook did not block kill 1"
ln -s "$T/home/fixture/users/user-004/share" "$T/link"; jq -n '{tool_input:{command:"kill -9 1"}}' | node "$T/link/fm-kill-guard/guard.mjs" --caller "$$" 2> "$T/err" && rc=0 || rc=$?
[ "$rc" -eq 2 ] && [[ "$(cat "$T/err")" == *"PID 1 (init)"* ]] && ok "symlinked install blocks kill -9 1" || no "symlinked install allowed kill -9 1"

un() { env -u XDG_DATA_HOME HOME="$T/home" "$ADDON/uninstall.sh" "$@"; }
G=$T/home/fixture/users/user-004/share/fm-kill-guard; mkdir -p "$G/disabled"; cp "$T/home/fixture/users/user-007/agent/extensions/fm-kill-guard.ts" "$G/disabled/"
cp "$T/home/fixture/users/user-001/settings.json" "$T/before.json"; un --dry-run >/dev/null
cmp -s "$T/before.json" "$T/home/fixture/users/user-001/settings.json" && [ -e "$G/guard.mjs" ] && [ -e "$G/disabled/fm-kill-guard.ts" ] && ok "uninstall --dry-run writes nothing" || no "uninstall --dry-run wrote"
un >/dev/null && set -- "$T"/home/fixture/users/user-001/settings.json.bak-kill-guard-* && jq -e '[.hooks.PreToolUse[].hooks[].command] == ["other-hook"] and .env.KEEP == "1"' "$T/home/fixture/users/user-001/settings.json" >/dev/null &&
  cmp -s "$T/before.json" "${!#}" && ok "uninstall drops only the kill-guard hook, with a backup" || no "uninstall settings"
[ ! -e "$G" ] && [ ! -e "$T/home/fixture/users/user-007/agent/extensions/fm-kill-guard.ts" ] && [ ! -e "$T/home/fixture/users/user-003/opencode/plugins/fm-kill-guard.js" ] && ok "uninstall removes the rule and adapters" || no "uninstall left files"
[ -z "$(un)" ] && ok "uninstall again changes nothing" || no "uninstall not idempotent"

[ "$fail" -eq 0 ] && echo "kill-guard e2e: all passed" || { echo "kill-guard e2e: FAILED"; exit 1; }
