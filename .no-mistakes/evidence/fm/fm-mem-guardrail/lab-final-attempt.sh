#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=/home/umer/.no-mistakes/evidence/01M4CT545F00ZMBN7DDRKETEBP
ORIGINAL_HOME=$HOME ORIGINAL_PATH=$PATH
R=$(mktemp -d "$PWD/.lab-final.XXXXXX")
S=fm-lab-m3
export FM_HERDR_LAB_STATE_DIR="$R/lab" FM_HERDR_LAB_FLEET_HOME="$ORIGINAL_HOME"
export HOME="$R/home" CLAUDE_CONFIG_DIR="$R/claude"
export XDG_CONFIG_HOME="${R##*/}/c" XDG_DATA_HOME="${R##*/}/d" XDG_STATE_HOME="${R##*/}/s"
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_SESSION HERDR_WORKSPACE_ID HERDR_TAB_ID FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
mkdir -m 700 "$HOME" "$CLAUDE_CONFIG_DIR"
watcher=
phase=provision
interrupt_result='not proven: lab setup did not complete'
restart_result='not proven: lab setup did not complete'
cleanup() {
  rc=$?
  if [ -n "$watcher" ]; then kill -TERM "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true; fi
  PATH="$ORIGINAL_PATH" "$ROOT/bin/fm-herdr-lab.sh" teardown "$S" > "$E/lab-final-cleanup.log" 2>&1 || rc=1
  python3 - "$E/lab-final-results.json" "$interrupt_result" "$restart_result" "$phase" "$rc" <<'PY'
import json,sys
json.dump(dict(interruption=sys.argv[2],restart=sys.argv[3],last_phase=sys.argv[4],exit_code=int(sys.argv[5])),open(sys.argv[1],'w'),indent=2)
PY
  rm -rf "$R"
}
trap cleanup EXIT
lab() { PATH="$ORIGINAL_PATH" "$ROOT/bin/fm-herdr-lab.sh" run "$S" "$@"; }
bin/fm-herdr-lab.sh provision "$S"
bin/fm-lab-home.sh create "$R/fleet"
export FM_HOME="$R/fleet" HERDR_SESSION="$S" FM_BACKEND=herdr
printf 'herdr\n' > "$FM_HOME/config/backend"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
touch "$FM_HOME/config/supervision-host"
mkdir -p "$FM_HOME/wt" "$FM_HOME/proc/pressure" "$FM_HOME/data/build" "$R/bin"
git -C "$FM_HOME/wt" init -q
printf 'Lab task: no project changes.\n' > "$FM_HOME/data/build/brief.md"
# Copy only authentication into the private store; never link writable user config.
if [ -f "$ORIGINAL_HOME/.claude/.credentials.json" ]; then
  cp "$ORIGINAL_HOME/.claude/.credentials.json" "$CLAUDE_CONFIG_DIR/.credentials.json"
  chmod 600 "$CLAUDE_CONFIG_DIR/.credentials.json"
fi
python3 - "$ORIGINAL_HOME/.claude.json" "$CLAUDE_CONFIG_DIR/.claude.json" "$FM_HOME/wt" <<'PY'
import json,sys,os
try: original=json.load(open(sys.argv[1]))
except FileNotFoundError: original={}
data={k:original[k] for k in ('oauthAccount','userID','hasCompletedOnboarding','lastOnboardingVersion','theme') if k in original}
data['hasCompletedOnboarding']=True
data['projects']={sys.argv[3]:{'hasTrustDialogAccepted':True}}
with open(sys.argv[2],'w') as f: json.dump(data,f)
os.chmod(sys.argv[2],0o600)
PY
export FM_HOST_MEMORY_PROC="$FM_HOME/proc" FM_HOST_MEMORY_CGROUP_ROOT="$FM_HOME/no-cgroup"
printf 'MemTotal: 67108864 kB\nMemAvailable: 41943040 kB\nSwapTotal: 33554432 kB\nSwapFree: 33554432 kB\n' > "$FM_HOME/proc/meminfo"
printf 'some avg10=1 avg60=0 avg300=0 total=1\n' > "$FM_HOME/proc/pressure/memory"
lab workspace create --cwd "$FM_HOME/wt" --label firstmate --no-focus > "$R/workspace.json"
ws=$(jq -r '.result.workspace.workspace_id' "$R/workspace.json")
lab tab create --workspace "$ws" --cwd "$FM_HOME/wt" --label fm-build --no-focus > "$R/build.json"
pane=$(jq -r '.result.root_pane.pane_id' "$R/build.json")
tab=$(jq -r '.result.tab.tab_id' "$R/build.json")
bin/fm-herdr-lab.sh viewer start "$S"
phase=private-config-startup
printf -v prep 'export HOME=%q CLAUDE_CONFIG_DIR=%q FM_HOME=%q DISABLE_AUTOUPDATER=1; printf "lab private config ready\\n"' "$HOME" "$CLAUDE_CONFIG_DIR" "$FM_HOME"
lab pane run "$pane" "$prep"
lab pane wait-output "$pane" --regex 'lab private config ready' --timeout 10000
lab agent start memory-worker --kind claude --pane "$pane" --timeout 60000 || true
lab pane read "$pane" --source visible > "$E/lab-final-worker-startup.txt"
lab agent get memory-worker > "$E/lab-final-agent.json"
# Read the startup interface, not implementation source, before sending a prompt.
if grep -Eqi 'trust this folder|trust the files|Please run /login|Select the text style|Choose the text style|Select login method|Choose your account|Browser didn.t open|Paste code here' "$E/lab-final-worker-startup.txt"; then
  interrupt_result='not proven: private Claude config still requires interactive startup; see lab-final-worker-startup.txt'
  restart_result='not proven: no qualified primary/lead baseline before restart; private Claude startup remains blocked'
  exit 0
fi
phase=working-turn
lab pane send-keys "$pane" 'Use Bash to run sleep 120 now. Do not modify files or run any other command.' Enter
working=0
for ((i=0;i<40;i++)); do
  lab pane read "$pane" --source visible > "$E/lab-final-worker-working.txt"
  if grep -Eqi 'Running|Thinking|esc to interrupt|ctrl.c to interrupt' "$E/lab-final-worker-working.txt"; then working=1; break; fi
  if grep -Eqi 'Please run /login|not logged in|Invalid API key|login method|trust this folder' "$E/lab-final-worker-working.txt"; then break; fi
  sleep 1
done
if [ "$working" = 0 ]; then
  interrupt_result='not proven: no observable working Claude turn within 40 seconds; see lab-final-worker-working.txt'
  restart_result='not proven: no qualified primary/lead supervision baseline; see lab-final-worker-working.txt'
  exit 0
fi
# A working turn alone is not proof of primary/lead armed supervision.
interrupt_result='not proven: working turn observed, but interruption journey not yet completed'
restart_result='not proven: no armed primary/lead baseline; restart withheld rather than claiming recovery'
printf 'Observed a working turn; further qualification required.\n'
