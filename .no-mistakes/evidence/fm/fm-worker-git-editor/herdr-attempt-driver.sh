#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/home/umer/.no-mistakes/evidence/01M4CGFX7T2337R85W85XNDB65
D="$ROOT/.editor-validation"
ORIGINAL_PATH=$PATH
export FM_HERDR_LAB_STATE_DIR="$D/herdr" FM_HERDR_LAB_ISOLATED_XDG=0
export XDG_CONFIG_HOME="$ROOT/.ec" XDG_DATA_HOME="$ROOT/.ed" XDG_STATE_HOME="$ROOT/.es"
SESSION=fm-lab-e
HELPER="$ROOT/bin/fm-herdr-lab.sh"
cleanup() { rc=$?; trap - EXIT; PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION" >> "$E/live.log" 2>&1 || rc=1; exit "$rc"; }
trap cleanup EXIT
mkdir -p "$D/tools" "$D/user" "$D/tmp" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
export FM_HERDR_LAB_FLEET_HOME="$HOME" HOME="$D/user"
"$HELPER" provision "$SESSION"
export TMPDIR="$D/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
"$ROOT/bin/fm-lab-home.sh" create "$D/home"
cat > "$D/tools/herdr" <<EOF
#!/usr/bin/env bash
set -eu
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ] || exit 98
args=("\${args[@]:0:\$((n-2))}")
exec env PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$D/tools/herdr"
export PATH="$D/tools:$ORIGINAL_PATH" FM_HOME="$D/home" HERDR_SESSION="$SESSION"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID TMUX TMUX_PANE
export FM_SPAWN_NO_GUARD=1 GIT_EDITOR="$D/hostile-editor" GIT_SEQUENCE_EDITOR="$D/hostile-editor"
cat > "$D/hostile-editor" <<EOF
#!/bin/sh
echo editor-invoked >> "$E/editor-invocations.log"
exit 89
EOF
chmod +x "$D/hostile-editor"
cat > "$D/git-journey.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
exec </dev/null
printf 'editors=%s|%s stdin-tty=' "$GIT_EDITOR" "$GIT_SEQUENCE_EDITOR"
if test -t 0; then echo yes; else echo no; fi
git config user.name 'Editor Lab'
git config user.email 'editor@example.invalid'
printf 'base\n' > conflict.txt
git add conflict.txt; git commit -qm base
BASE=$(git rev-parse HEAD)
git checkout -qb topic
printf 'topic\n' > conflict.txt; git commit -qam topic
git checkout -qb upstream "$BASE"
printf 'upstream\n' > conflict.txt; git commit -qam upstream
git checkout -q topic
if git rebase upstream; then echo 'expected conflict missing'; exit 1; fi
printf 'resolved\n' > conflict.txt; git add conflict.txt
timeout 10 git rebase --continue
printf 'REBASE_CONTINUE_COMPLETED=%s\n' "$(git log -1 --format=%s)"
printf 'sequence\n' > sequence.txt; git add sequence.txt; git commit -qm sequence
timeout 10 git rebase -i HEAD~2
printf 'INTERACTIVE_REBASE_COMPLETED=%s\n' "$(git log -1 --format=%s)"
test ! -d .git/rebase-merge
EOF
chmod +x "$D/git-journey.sh"
mkdir -p "$D/project"
git -C "$D/project" init -q
git -C "$D/project" -c user.name=Lab -c user.email=lab@example.invalid commit --allow-empty -qm initial
for setting in ordinary filtered; do
  id="editor-$setting"
  [ "$setting" != filtered ] || touch "$FM_HOME/config/launch-env-allowlist"
  "$ROOT/bin/fm-brief.sh" "$id" project --scout --herdr-lab
  python3 - "$FM_HOME/data/$id/brief.md" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('{TASK}', 'Confirm Git completes without an editor.').replace('{FIRSTMATE_SPEC}', 'Run the bounded Git journey and report.')
open(p,'w').write(s)
PY
  timeout 100 "$ROOT/bin/fm-spawn.sh" "$id" "$D/project" "cd . && bash '$D/git-journey.sh' > '$E/$setting-git.log' 2>&1; echo \$? > '$E/$setting-exit.txt'" --scout --backend herdr
  for n in $(seq 1 100); do [ ! -f "$E/$setting-exit.txt" ] || break; sleep .2; done
  test "$(< "$E/$setting-exit.txt")" = 0
  echo "$setting git journey exit=0"
  pane=$(awk -F= '$1=="herdr_pane_id" {print substr($0,index($0,"=")+1)}' "$FM_HOME/state/$id.meta")
  env PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" pane capture "$pane" > "$E/$setting-pane.json"
done
