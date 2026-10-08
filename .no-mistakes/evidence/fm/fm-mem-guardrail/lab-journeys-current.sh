#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=/home/umer/.no-mistakes/evidence/01M4CT545F00ZMBN7DDRKETEBP
ORIGINAL_HOME=$HOME ORIGINAL_PATH=$PATH
R=$(mktemp -d "$PWD/.lab.XXXXXX")
export FM_HERDR_LAB_STATE_DIR="$R/lab" FM_HERDR_LAB_FLEET_HOME="$ORIGINAL_HOME"
export HOME="$R/home"
mkdir -p "$HOME"
export XDG_CONFIG_HOME="${R##*/}/c" XDG_DATA_HOME="${R##*/}/d" XDG_STATE_HOME="${R##*/}/s"
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_SESSION HERDR_WORKSPACE_ID HERDR_TAB_ID FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
S=fm-lab-m2
watcher=
cleanup() {
  if [ -n "$watcher" ]; then kill -TERM "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true; fi
  PATH="$ORIGINAL_PATH" "$ROOT/bin/fm-herdr-lab.sh" teardown "$S"
  rm -rf "$R"
}
trap cleanup EXIT
lab() { PATH="$ORIGINAL_PATH" "$ROOT/bin/fm-herdr-lab.sh" run "$S" "$@"; }
printf 'Candidate: '; git rev-parse HEAD
bin/fm-herdr-lab.sh provision "$S"
bin/fm-lab-home.sh create "$R/fleet"
export FM_HOME="$R/fleet" HERDR_SESSION="$S" FM_BACKEND=herdr
printf 'herdr\n' > "$FM_HOME/config/backend"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'claude\n' > "$FM_HOME/config/secondmate-harness"
touch "$FM_HOME/config/supervision-host"
mkdir -p "$FM_HOME/wt" "$FM_HOME/proc/pressure" "$FM_HOME/data/build" "$R/bin"
git -C "$FM_HOME/wt" init -q
printf 'Lab task: preserve the working tree.\n' > "$FM_HOME/data/build/brief.md"
export FM_HOST_MEMORY_PROC="$FM_HOME/proc" FM_HOST_MEMORY_CGROUP_ROOT="$FM_HOME/no-cgroup"
printf 'MemTotal: 67108864 kB\nMemAvailable: 31457280 kB\nSwapTotal: 33554432 kB\nSwapFree: 33554432 kB\n' > "$FM_HOME/proc/meminfo"
printf 'some avg10=25 avg60=0 avg300=0 total=1\n' > "$FM_HOME/proc/pressure/memory"
lab workspace create --cwd "$FM_HOME/wt" --label firstmate --no-focus > "$R/workspace.json"
ws=$(jq -r '.result.workspace.workspace_id' "$R/workspace.json")
lab tab create --workspace "$ws" --cwd "$FM_HOME/wt" --label fm-build --no-focus > "$R/build.json"
pane=$(jq -r '.result.root_pane.pane_id' "$R/build.json")
tab=$(jq -r '.result.tab.tab_id' "$R/build.json")
bin/fm-herdr-lab.sh viewer start "$S"
printf -v prep 'export HOME=%q FM_HOME=%q; printf "lab worker ready\\n"' "$ORIGINAL_HOME" "$FM_HOME"
lab pane run "$pane" "$prep"
lab pane wait-output "$pane" --regex 'lab worker ready' --timeout 10000
lab agent start memory-worker --kind claude --pane "$pane" --timeout 60000 || true
lab pane read "$pane" --source visible > "$E/lab-journey-worker-before.txt"
lab agent get memory-worker > "$E/lab-agent-before.json"
# Route every Herdr call from production scripts through the guarded helper.
cat > "$R/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "${2:-}" = "$LAB_SESSION" ] || exit 9; shift 2 ;;
    --session=*) exit 9 ;;
    *) args+=("$1"); shift ;;
  esac
done
if [ "${args[0]:-}" = --version ]; then exec env PATH="$LAB_ORIGINAL_PATH" "$LAB_REAL_HERDR" --version; fi
exec env PATH="$LAB_ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "${args[@]}"
SH
chmod +x "$R/bin/herdr"
export LAB_SESSION="$S" LAB_ORIGINAL_PATH="$ORIGINAL_PATH" LAB_REAL_HERDR="$(command -v herdr)" LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
export PATH="$R/bin:$ORIGINAL_PATH"
printf 'kind=ship\nendpoint_task_id=build\nharness=claude\nbackend=herdr\nwindow=%s:%s\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\nworktree=%s\nproject=%s\n' "$S" "$pane" "$S" "$ws" "$tab" "$pane" "$FM_HOME/wt" "$FM_HOME/wt" > "$FM_HOME/state/build.meta"
cp "$FM_HOME/state/build.meta" "$R/before.meta"
printf '\n=== Relaunch under synthetic WAIT pressure ===\n'
set +e
bin/fm-control.sh build relaunch --note 'Test pressure refusal preserves this agent.' > "$E/lab-relaunch-current.txt" 2>&1
rc=$?
set -e
printf 'relaunch exit=%s\n' "$rc"
cat "$E/lab-relaunch-current.txt"
test "$rc" -eq 1
grep -q 'refused before its agent was touched' "$E/lab-relaunch-current.txt"
cmp "$R/before.meta" "$FM_HOME/state/build.meta"
lab agent get memory-worker > "$E/lab-agent-after.json"
lab pane read "$pane" --source visible > "$E/lab-journey-worker-after.txt"
python3 - "$E/lab-agent-before.json" "$E/lab-agent-after.json" <<'PY'
import json,sys
before=json.load(open(sys.argv[1]))['result']['agent']
after=json.load(open(sys.argv[2]))['result']['agent']
for key in ('agent_id','pane_id','pid','process_id','session_id'):
    if key in before: assert before[key]==after[key], (key,before,after)
for key in ('state','status'):
    if key in before: assert before[key]==after[key], (before,after)
print('The same recognized Claude agent remains in the same state after refusal.')
PY
printf '\n=== Dead secondmate recovery under WAIT ===\n'
lab tab create --workspace "$ws" --cwd "$FM_HOME" --label fm-mate --no-focus > "$R/mate.json"
mp=$(jq -r '.result.root_pane.pane_id' "$R/mate.json")
mt=$(jq -r '.result.tab.tab_id' "$R/mate.json")
mkdir -p "$FM_HOME/mate/state"
printf 'kind=secondmate\nendpoint_task_id=mate\nharness=claude\nbackend=herdr\nwindow=%s:%s\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\nhome=%s\n' "$S" "$mp" "$S" "$ws" "$mt" "$mp" "$FM_HOME/mate" > "$FM_HOME/state/mate.meta"
FM_POLL=1 FM_HOST_MEMORY_SECS=1 FM_SECONDMATE_LIVENESS_SECS=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 bin/fm-watch.sh > "$E/lab-watch-current.txt" 2> "$E/lab-watch-current.err" & watcher=$!
for ((i=0;i<100;i++)); do grep -q 'memory admission deferred' "$FM_HOME/state/.watch-triage.log" 2>/dev/null && break; sleep 0.1; done
cat "$FM_HOME/state/.watch-triage.log"
grep -q 'memory admission deferred' "$FM_HOME/state/.watch-triage.log"
test ! -e "$FM_HOME/state/.secondmate-relaunch-mate"
lab pane get "$mp"
printf 'Secondmate shell endpoint survived; no recovery attempt ledger was created.\n'
kill -TERM "$watcher"; wait "$watcher" || true; watcher=
cp "$FM_HOME/state/.watch-triage.log" "$E/lab-recovery-pressure-current.txt"
printf '\n=== Remaining proofs ===\n'
printf 'not proven: interrupt of an actively working Claude agent; startup requires trust approval that writes user-level configuration outside the worktree.\n'
printf 'not proven: restored primary/lead supervision after a Herdr restart; the permitted primary never advanced past that trust prompt.\n'
