#!/usr/bin/env bash
set -uo pipefail
E=/home/umer/.no-mistakes/evidence/01M4CT545F00ZMBN7DDRKETEBP
ORIGINAL_HOME=$HOME
R=$(mktemp -d "$PWD/.lab.XXXXXX")
export FM_HERDR_LAB_STATE_DIR="$R/lab" FM_HERDR_LAB_FLEET_HOME="$ORIGINAL_HOME"
export HOME="$R/home"
mkdir -p "$HOME"
export XDG_CONFIG_HOME="${R##*/}/c" XDG_DATA_HOME="${R##*/}/d" XDG_STATE_HOME="${R##*/}/s"
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_SESSION HERDR_WORKSPACE_ID HERDR_TAB_ID FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
S=fm-lab-m1
cleanup() { bin/fm-herdr-lab.sh teardown "$S"; rm -rf "$R"; }
trap cleanup EXIT
printf 'Candidate: '; git rev-parse HEAD
printf 'Relative repository-local XDG directory: %s\n' "$XDG_CONFIG_HOME"
if bin/fm-herdr-lab.sh provision "$S"; then
  bin/fm-herdr-lab.sh run "$S" status --json
  printf '\nLAB_READY\n'
  bin/fm-lab-home.sh create "$R/fleet"
  export FM_HOME="$R/fleet" HERDR_SESSION="$S" FM_BACKEND=herdr
  touch "$FM_HOME/config/supervision-host"
  printf 'herdr\n' > "$FM_HOME/config/backend"
  printf 'manual\n' > "$FM_HOME/config/backlog-backend"
  mkdir -p "$FM_HOME/wt" "$FM_HOME/proc/pressure"
  printf 'MemTotal: 67108864 kB\nMemAvailable: 31457280 kB\nSwapTotal: 33554432 kB\nSwapFree: 33554432 kB\n' > "$FM_HOME/proc/meminfo"
  printf 'some avg10=25 avg60=0 avg300=0 total=1\n' > "$FM_HOME/proc/pressure/memory"
  export FM_HOST_MEMORY_PROC="$FM_HOME/proc" FM_HOST_MEMORY_CGROUP_ROOT="$FM_HOME/no-cgroup"
  bin/fm-herdr-lab.sh run "$S" workspace create --cwd "$FM_HOME/wt" --label firstmate --no-focus > "$E/lab-workspace-current.json"
  pane=$(jq -r '.result.root_pane.pane_id' "$E/lab-workspace-current.json")
  bin/fm-herdr-lab.sh viewer start "$S" || exit 1
  printf -v prep 'export HOME=%q FM_HOME=%q; printf "lab worker environment ready\\n"' "$ORIGINAL_HOME" "$FM_HOME"
  bin/fm-herdr-lab.sh run "$S" pane run "$pane" "$prep"
  bin/fm-herdr-lab.sh run "$S" pane wait-output "$pane" --regex 'lab worker environment ready' --timeout 10000
  bin/fm-herdr-lab.sh run "$S" agent start memory-worker --kind claude --pane "$pane" --timeout 60000
  bin/fm-herdr-lab.sh run "$S" pane read "$pane" --source visible > "$E/lab-worker-current.json"
  bin/fm-herdr-lab.sh run "$S" agent list --json
  printf '\nWORKER_SETUP_COMPLETED; inspect worker evidence before claiming any journey\n'
else
  bin/fm-herdr-lab.sh run "$S" status --json
  printf '\nnot proven: Herdr lab provision failed before worker setup\n'
fi
