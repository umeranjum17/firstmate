#!/usr/bin/env bash
set -eu
ROOT=/home/umer/.no-mistakes/worktrees/bde6b4035eae/01M4CND652NW53MP2VDN56N9SD
E=/home/umer/.no-mistakes/evidence/01M4CND652NW53MP2VDN56N9SD
cd "$ROOT"
L="$ROOT/.hv"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_SOCKET_PATH HERDR_SESSION
export BASE_PATH="$PATH" FM_HERDR_LAB_STATE_DIR="$L/state" FM_HERDR_LAB_ISOLATED_XDG=0 FM_HERDR_LAB_FLEET_HOME="$HOME"
export HERDR_SESSION=fm-lab-e
cleanup() {
 PATH="$BASE_PATH" bin/fm-herdr-lab.sh teardown "$HERDR_SESSION" > "$E/herdr-teardown.log" 2>&1 || return 1
 chmod -R u+w "$L" 2>/dev/null || true
 rm -rf "$L"
}
trap cleanup EXIT
mkdir -p "$L/user" "$L/t" "$L/p"
git -C "$L/p" init -qb main
bin/fm-lab-home.sh create "$L/home"
export FM_HOME="$L/home" HOME="$L/user" SHELL=/bin/bash TMUX_TMPDIR="$L/t"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'max_trees = 3\nroot = "./"\n' > "$L/p/treehouse.toml"
printf 'base\n' > "$L/p/conflict.txt"
git -C "$L/p" add .
git -C "$L/p" -c user.name=Lab -c user.email=lab@example.invalid commit -qm initial
cat > "$L/poison" <<'SH'
#!/bin/sh
printf 'EDITOR_WAS_INVOKED\n' >> "$HOME/editor-invoked"
exit 97
SH
chmod +x "$L/poison"
cat > "$L/probe.sh" <<'SH'
#!/bin/bash
set -eux
log=$1
exec > "$log" 2>&1 </dev/null
printf 'worker cwd=%s\nGIT_EDITOR=%s\nGIT_SEQUENCE_EDITOR=%s\n' "$PWD" "${GIT_EDITOR-unset}" "${GIT_SEQUENCE_EDITOR-unset}"
git config user.name Lab
git config user.email lab@example.invalid
git config core.editor "$HOME/../poison"
git config sequence.editor "$HOME/../poison"
printf 'base\n' > conflict.txt
git add conflict.txt
git diff --cached --quiet || git commit -qm base
base=$(git rev-parse HEAD)
branch="journey-$(date +%s%N)"
git checkout -qb "$branch"
printf 'topic\n' > conflict.txt; git commit -qam topic
git checkout -qb "upstream-$(date +%s%N)" "$base"
printf 'upstream\n' > conflict.txt; git commit -qam upstream
upstream=$(git rev-parse HEAD)
git checkout -q "$branch"
if git rebase "$upstream"; then echo 'MISSING EXPECTED CONFLICT'; exit 1; fi
printf 'resolved\n' > conflict.txt; git add conflict.txt
printf '\nRUN git rebase --continue (stdin=/dev/null)\n'
timeout 15 git rebase --continue
printf '\nRUN git rebase -i HEAD~1 (stdin=/dev/null)\n'
timeout 15 git rebase -i HEAD~1
printf 'branch=%s content=%s\n' "$(git branch --show-current)" "$(cat conflict.txt)"
test "$(cat conflict.txt)" = resolved
test ! -d "$(git rev-parse --git-path rebase-merge)"
printf '\nWORKER_GIT_COMPLETED\n'
SH
export XDG_CONFIG_HOME="$L/c" XDG_DATA_HOME="$L/d" XDG_STATE_HOME="$L/s" XDG_RUNTIME_DIR="$L/r"
mkdir -p "$L/c" "$L/d" "$L/s" "$L/r"
chmod 700 "$L/r"
PATH="$BASE_PATH" bin/fm-herdr-lab.sh provision "$HERDR_SESSION"
mkdir -p "$L/proxy"
cat > "$L/proxy/herdr" <<'PROXY'
#!/bin/bash
set -eu
if [ "${1:-}" = --version ]; then exec env PATH="$BASE_PATH" herdr --version; fi
args=()
while [ $# -gt 0 ]; do
 if [ "$1" = --session ]; then
  test "$2" = "$HERDR_SESSION" || exit 91
  shift 2
 else args+=("$1"); shift; fi
done
exec env PATH="$BASE_PATH" /home/umer/.no-mistakes/worktrees/bde6b4035eae/01M4CND652NW53MP2VDN56N9SD/bin/fm-herdr-lab.sh run "$HERDR_SESSION" "${args[@]}"
PROXY
chmod +x "$L/proxy/herdr"
export PATH="$L/proxy:$PATH" GIT_EDITOR="$L/poison" GIT_SEQUENCE_EDITOR="$L/poison"
for setting in absent; do
 id="editor-$setting"
 mkdir -p "$FM_HOME/data/$id"
 cat > "$FM_HOME/data/$id/brief.md" <<'BRIEF'
# Task
## Captain's intent
Workers must never block on a git editor.

## Firstmate spec
Run conflict continuation and an interactive rebase with no stdin.
BRIEF
 if [ "$setting" = enabled ]; then touch "$FM_HOME/config/launch-env-allowlist"; fi
 FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh "$id" "$L/p" --backend herdr --mode local-only --yolo off "bash '$L/probe.sh' '$E/herdr-live-$setting.log'" > "$E/herdr-spawn-$setting.log" 2>&1
 for i in $(seq 1 50); do
   if [ -f "$E/herdr-live-$setting.log" ] && grep -q WORKER_GIT_COMPLETED "$E/herdr-live-$setting.log"; then break; fi
   sleep 0.2
 done
 grep -q WORKER_GIT_COMPLETED "$E/herdr-live-$setting.log"
 pane=$(awk -F= '$1=="herdr_pane_id" {print substr($0,16)}' "$FM_HOME/state/$id.meta")
 bin/fm-herdr-lab.sh run "$HERDR_SESSION" pane capture "$pane" --text > "$E/herdr-pane.txt"
 printf 'LIVE PASS %s\n' "$setting"
 # Relaunch the deliberately already-stopped raw worker through its public launch interface.
 FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh "$id" --relaunch --harness "bash '$L/probe.sh' '$E/herdr-live-$setting-relaunch.log'" > "$E/herdr-relaunch-$setting.log" 2>&1
 for i in $(seq 1 50); do
   if [ -f "$E/herdr-live-$setting-relaunch.log" ] && grep -q WORKER_GIT_COMPLETED "$E/herdr-live-$setting-relaunch.log"; then break; fi
   sleep 0.2
 done
 grep -q WORKER_GIT_COMPLETED "$E/herdr-live-$setting-relaunch.log"
 printf 'LIVE PASS %s relaunch\n' "$setting"
done
test ! -f "$L/user/editor-invoked"
printf 'Hostile editor never invoked; two real Herdr worker Git journeys completed.\n'
