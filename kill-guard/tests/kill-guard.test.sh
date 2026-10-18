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
const file = process.argv[2], hooks = {}, pi = file.endsWith(".ts"), mod = await import(file);
if (pi) { mod.default({ on: (n, h) => (hooks[n] = h) }); console.log((await hooks.tool_call({ toolName: "bash", input: { command: "kill 1" } })).reason); }
else { Object.assign(hooks, await mod.FmKillGuard({})); await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "kill 1" } }).catch((e) => console.log(e.message)); }
EOF
for a in "pi:$T/home/fixture/users/user-007/agent/extensions/fm-kill-guard.ts" "opencode:$T/home/fixture/users/user-003/opencode/plugins/fm-kill-guard.js"; do
  out=$(node "$T/adapters.mjs" "${a#*:}" 2>/dev/null || true); [[ "$out" == *"PID 1 (init)"* ]] && ok "${a%%:*} adapter blocks kill 1" || no "${a%%:*} adapter: $out"
done
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

block "$$" "sh -c 'kill -KILL 1'" 'PID 1 (init)'
block "$$" 'ionice -c3 kill 1' 'PID 1 (init)'
block "$$" 'echo $(kill -9 $(pgrep -x herdr))' 'cannot be resolved'
block "$$" "kill $SYSD" 'the systemd user manager'
block "$$" "kill $HERDR" 'the herdr server'
block "$$" 'pkill herd' 'the herdr server'
block "$$" "pkill 'h[[:lower:]]rdr'" 'cannot be resolved'
block "$$" 'killall /usr/bin/herdr' 'cannot be resolved'
block "$$" 'kill -9 -1' 'cannot be resolved'
block "$$" 'xargs kill' 'come from xargs'
block "$$" $'bash <<EOF\nkill -9 1\nEOF' 'PID 1 (init)'
block "$$" $'echo $((1<<2))\nkill -9 1' 'PID 1 (init)'
block "$C" "kill $S" 'which this task did not start'
allow "$$" "kill $C"
allow "$$" "kill $C 2>/dev/null"
allow "$$" 'kill -l 99999999'
allow "$$" 'grep -r kill src'
allow "$$" $'git commit -m "$(cat <<\'EOF\'\nkill stale lanes\nEOF\n)"'

hook "$$" 'kill 1'; sh -c "$HOOK" < "$T/in.json" 2>"$T/err" && rc=0 || rc=$?
[ "$rc" -eq 2 ] && [[ "$(cat "$T/err")" == *"PID 1 (init)"* ]] && ok "installed hook blocks kill 1" || no "installed hook did not block kill 1"
ln -s "$T/home/fixture/users/user-004/share" "$T/link"; jq -n '{tool_input:{command:"kill -9 1"}}' | node "$T/link/fm-kill-guard/guard.mjs" --caller "$$" 2> "$T/err" && rc=0 || rc=$?
[ "$rc" -eq 2 ] && [[ "$(cat "$T/err")" == *"PID 1 (init)"* ]] && ok "symlinked install blocks kill -9 1" || no "symlinked install allowed kill -9 1"

[ "$fail" -eq 0 ] && echo "kill-guard e2e: all passed" || { echo "kill-guard e2e: FAILED"; exit 1; }
