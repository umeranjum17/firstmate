#!/usr/bin/env bash
set -eu
ROOT=$PWD
D="$ROOT/.editor-validation"
E=/home/umer/.no-mistakes/evidence/01M4CGFX7T2337R85W85XNDB65
ORIGINAL_PATH=$PATH
SOCKET="$ROOT/.et"
mkdir -p "$D/tools-tmux" "$D/user" "$D/tmp"
export HOME="$D/user" TMPDIR="$D/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SESSION TMUX TMUX_PANE
cleanup() { rc=$?; trap - EXIT; /usr/bin/tmux -S "$SOCKET" kill-server || rc=1; exit "$rc"; }
trap cleanup EXIT
cat > "$D/tools-tmux/tmux" <<EOF
#!/bin/sh
exec /usr/bin/tmux -S '$SOCKET' "\$@"
EOF
chmod +x "$D/tools-tmux/tmux"
export PATH="$D/tools-tmux:$ORIGINAL_PATH"
tmux -f /dev/null new-session -d -s lab-control -x 120 -y 40 -c "$ROOT" 'bash --noprofile --norc'
export TMUX="$(tmux display-message -p '#{socket_path},#{pid},0')" FM_HOME="$D/home" FM_SPAWN_NO_GUARD=1
[ -f "$FM_HOME/.fm-lab-home" ] || "$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
cat > "$D/git-journey.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
exec </dev/null
printf 'editors=%s|%s stdin-tty=' "$GIT_EDITOR" "$GIT_SEQUENCE_EDITOR"
if test -t 0; then echo yes; else echo no; fi
git config user.name 'Editor Lab'; git config user.email 'editor@example.invalid'
printf 'base\n' > conflict.txt; git add conflict.txt; git commit -qm base
BASE=$(git rev-parse HEAD)
git checkout -qb "topic-$$"
printf 'topic\n' > conflict.txt; git commit -qam topic
git checkout -qb "upstream-$$" "$BASE"
printf 'upstream\n' > conflict.txt; git commit -qam upstream
git checkout -q "topic-$$"
if git rebase "upstream-$$"; then echo 'expected conflict missing'; exit 1; fi
printf 'resolved\n' > conflict.txt; git add conflict.txt
timeout 10 git rebase --continue
printf 'REBASE_CONTINUE_COMPLETED=%s\n' "$(git log -1 --format=%s)"
printf 'sequence\n' > sequence.txt; git add sequence.txt; git commit -qm sequence
timeout 10 git rebase -i HEAD~2
printf 'INTERACTIVE_REBASE_COMPLETED=%s\n' "$(git log -1 --format=%s)"
test ! -d "$(git rev-parse --git-path rebase-merge)"
EOF
chmod +x "$D/git-journey.sh"
cat > "$D/hostile-editor" <<EOF
#!/bin/sh
echo editor-invoked >> "$E/editor-invocations.log"
exit 89
EOF
chmod +x "$D/hostile-editor"
export GIT_EDITOR="$D/hostile-editor" GIT_SEQUENCE_EDITOR="$D/hostile-editor"
mkdir -p "$D/project"
git -C "$D/project" init -q
git -C "$D/project" -c user.name=Lab -c user.email=lab@example.invalid commit --allow-empty -qm initial
for setting in ordinary filtered; do
  id="editor-$setting"
  [ "$setting" != filtered ] || touch "$FM_HOME/config/launch-env-allowlist"
  "$ROOT/bin/fm-brief.sh" "$id" project --scout --herdr-lab
  python3 - "$FM_HOME/data/$id/brief.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().replace('{TASK}', 'Confirm Git completes without an editor.').replace('{FIRSTMATE_SPEC}', 'Run the bounded Git journey and report.')
open(p,'w').write(s)
PY
  timeout 110 "$ROOT/bin/fm-spawn.sh" "$id" "$D/project" "cd . && bash '$D/git-journey.sh' > '$E/$setting-git.log' 2>&1; echo \$? > '$E/$setting-exit.txt'" --scout --backend tmux
  for n in $(seq 1 100); do [ ! -f "$E/$setting-exit.txt" ] || break; sleep .2; done
  test "$(< "$E/$setting-exit.txt")" = 0
  echo "$setting git journey exit=0"
  tmux capture-pane -p -t "lab-control:fm-$id" > "$E/$setting-tmux.txt"
done
timeout 110 "$ROOT/bin/fm-spawn.sh" editor-ordinary --relaunch --harness pi
pane_pid=$(tmux display-message -p -t lab-control:fm-editor-ordinary '#{pane_pid}')
python3 - "$pane_pid" "$E/pi-relaunch-env.json" <<'PY'
import os, sys, json, time
root=int(sys.argv[1]); found=None
for _ in range(100):
    queue=[root]
    while queue:
        pid=queue.pop()
        try:
            queue.extend(map(int,open(f'/proc/{pid}/task/{pid}/children').read().split()))
            cmd=open(f'/proc/{pid}/cmdline','rb').read().replace(b'\0',b' ').decode()
            if 'node' not in cmd or ('pi' not in cmd and 'coding-agent' not in cmd): continue
            env=dict(x.split(b'=',1) for x in open(f'/proc/{pid}/environ','rb').read().split(b'\0') if b'=' in x)
            found={'pid':pid,'command':cmd,'GIT_EDITOR':env.get(b'GIT_EDITOR',b'').decode(),'GIT_SEQUENCE_EDITOR':env.get(b'GIT_SEQUENCE_EDITOR',b'').decode()}
        except (OSError, ValueError): pass
    if found: break
    time.sleep(.2)
assert found, 'no real Pi process observed after relaunch'
assert found['GIT_EDITOR']==found['GIT_SEQUENCE_EDITOR']=='true', found
open(sys.argv[2],'w').write(json.dumps(found,indent=2)+'\n')
print('real Pi relaunch environment:', json.dumps(found))
PY
tmux capture-pane -p -t lab-control:fm-editor-ordinary > "$E/pi-relaunch-tmux.txt"
