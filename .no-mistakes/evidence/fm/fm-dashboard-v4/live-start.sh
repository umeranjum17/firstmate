#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
H="$ROOT/.dashboard-validation/home"
E=/home/umer/.no-mistakes/evidence/01M4CT4VSY7GX5EKERSEYBBPJ5
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND
for c in awk basename bash cat chmod cut date dirname env flock grep head jq mkdir mv node nohup perl pgrep python3 readlink realpath rm sed sleep sort stat systemctl tail timeout tr wc tasks-axi; do
 p=$(command -v "$c" || true); [ -z "$p" ] || ln -sf "$p" ".dashboard-validation/path/$c"
done
export FM_HOME="$H" HOME="$H" PATH="$ROOT/.dashboard-validation/path"
export ANDROID_HOME="$H/no-sdk" ANDROID_SDK_ROOT="$H/no-sdk" FM_DEVICE_LOCK_DIR="$H/locks"
mkdir -p "$H/locks"
printf -- '- lead - UI validation (home: %s; scope: validation; projects: demo)\n' "$H/mates/lead" > "$H/data/secondmates.md"
printf 'main 4\nlead 3\n' > "$H/config/lane-caps"
: > "$E/live-operations.log"
for home in "$H" "$H/mates/lead"; do
 export FM_HOME="$home"
 bash "$ROOT/bin/fm-tasks-axi.sh" add release "$( [ "$home" = "$H" ] && echo Main || echo Lead ) release approval" --kind ship --repo demo --json >> "$E/live-operations.log"
 bash "$ROOT/bin/fm-tasks-axi.sh" hold release --reason "$( [ "$home" = "$H" ] && echo 'Approve evidence=/home/u/x/main-release.json' || echo 'Choose lead rollout' )" --kind captain --json >> "$E/live-operations.log"
done
export FM_HOME="$H"
bash "$ROOT/bin/fm-tasks-axi.sh" add ready 'Prepare dashboard rollout' --kind ship --repo demo --json >> "$E/live-operations.log"
bash "$ROOT/bin/fm-tasks-axi.sh" add vendor 'Obtain vendor credentials' --kind ship --repo demo --json >> "$E/live-operations.log"
bash "$ROOT/bin/fm-tasks-axi.sh" hold vendor --reason 'waiting for vendor credentials' --kind external --json >> "$E/live-operations.log"
printf 'ask-layout\t%s\tChoose rollout window\t\n' "$(date +%s)" > "$H/data/captain-asks.tsv"
printf 'kind=ship\nproject=demo\nharness=claude\nmodel=existing\n' > "$H/state/rollout.meta"
printf 'blocked [at=%s]: missing evidence=/home/u/x/report.md\n' "$(($(date +%s)-7200))" > "$H/state/rollout.status"
nohup bash "$ROOT/bin/fm-dashboard.sh" serve --bind 127.0.0.1 --port 0 > "$ROOT/.dashboard-validation/server.log" 2>&1 < /dev/null &
echo $! > "$ROOT/.dashboard-validation/server.pid"
