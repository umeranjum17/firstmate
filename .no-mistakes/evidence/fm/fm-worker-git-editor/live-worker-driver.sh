#!/usr/bin/env bash
set -eu
ROOT=/home/umer/.no-mistakes/worktrees/bde6b4035eae/01M4CND652NW53MP2VDN56N9SD
E=/home/umer/.no-mistakes/evidence/01M4CND652NW53MP2VDN56N9SD
cd "$ROOT"
L="$ROOT/.lv"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_SOCKET_PATH HERDR_SESSION
cleanup() { TMUX_TMPDIR="$L/t" tmux -L fm-lab kill-server 2>/dev/null || true; chmod -R u+w "$L" 2>/dev/null || true; rm -rf "$L"; }
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
TMUX_TMPDIR="$L/t" tmux -L fm-lab new-session -d -s firstmate -x 120 -y 40 -c "$ROOT" 'bash --noprofile --norc'
tmux -L fm-lab set-option -g default-shell /bin/bash
tmux -L fm-lab set-option -g default-command 'bash --noprofile --norc'
export TMUX="$L/t/tmux-$(id -u)/fm-lab,$(tmux -L fm-lab display-message -p '#{pid}'),0"
tmux -L fm-lab set-environment -g GIT_EDITOR "$L/poison"
tmux -L fm-lab set-environment -g GIT_SEQUENCE_EDITOR "$L/poison"
export GIT_EDITOR="$L/poison" GIT_SEQUENCE_EDITOR="$L/poison"
for setting in absent enabled; do
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
 FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh "$id" "$L/p" --mode local-only --yolo off "bash '$L/probe.sh' '$E/live-$setting.log'" > "$E/spawn-$setting.log" 2>&1
 for i in $(seq 1 50); do
   if [ -f "$E/live-$setting.log" ] && grep -q WORKER_GIT_COMPLETED "$E/live-$setting.log"; then break; fi
   sleep 0.2
 done
 grep -q WORKER_GIT_COMPLETED "$E/live-$setting.log"
 pane=$(awk -F= '$1=="window" {print substr($0,8)}' "$FM_HOME/state/$id.meta")
 tmux -L fm-lab capture-pane -p -S -200 -t "$pane" > "$E/pane-$setting.txt"
 printf 'LIVE PASS %s\n' "$setting"
 # Relaunch the deliberately already-stopped raw worker through its public launch interface.
 FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh "$id" --relaunch --harness "bash '$L/probe.sh' '$E/live-$setting-relaunch.log'" > "$E/relaunch-$setting.log" 2>&1
 for i in $(seq 1 50); do
   if [ -f "$E/live-$setting-relaunch.log" ] && grep -q WORKER_GIT_COMPLETED "$E/live-$setting-relaunch.log"; then break; fi
   sleep 0.2
 done
 grep -q WORKER_GIT_COMPLETED "$E/live-$setting-relaunch.log"
 printf 'LIVE PASS %s relaunch\n' "$setting"
done
test ! -f "$L/user/editor-invoked"
printf 'Hostile editor never invoked; four real worker Git journeys completed.\n'
