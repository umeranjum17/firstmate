#!/usr/bin/env bash
# Eval case 5 (deterministic): every old skill name and old command name still reaches the new one.
# done-done journey; run through `done-done run evals-old-names`.
# shellcheck source=journeys/evals/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO" || exit 1
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/jg-eval.XXXXXX")  # a JG_HOME that is not the captain's; HOME stays real, so no tool shim re-resolves

skill_alias() {  # an old skill dir must name a new skill dir that exists
  local old=$1 new
  # shellcheck disable=SC2016  # the backticks are literal text in the alias skill
  new=$(sed -n 's/.*Load the `\([a-z-]*\)` skill.*/\1/p' ".agents/skills/$old/SKILL.md" | head -1)
  [ -n "$new" ] && [ -f ".agents/skills/$new/SKILL.md" ] && echo "/$old -> /$new"
}
command_alias() {  # an old command must run the new one: same output, same exit
  local old=$1 new=${1/fm-/jg-}
  [ "$(JG_HOME=$SCRATCH bash "bin/$old" --list-families 2>/dev/null)" = "$(JG_HOME=$SCRATCH bash "bin/$new" --list-families 2>/dev/null)" ] && echo "$old == $new"
}

for f in $(grep -l 'Load the `' .agents/skills/*/SKILL.md); do
  old=${f%/SKILL.md}; old=${old##*/}
  check "skill $old" skill_alias "$old"
done
check "command fm-test-run.sh" command_alias fm-test-run.sh
# An old FM_* variable still reaches the new JG_* reader.
check "variable FM_HOME" bash -c "FM_HOME=$SCRATCH bash bin/jg-test-run.sh --list-families"
rm_scratch
steps "$(git rev-parse --short HEAD)" "a juggernaut checkout that has renamed its skills, commands and variables" \
  "each old skill, command and variable name still resolves to its new name" \
  "Read every alias skill and open the new skill it names" \
  "Run the old command and the new command and compare" \
  "Set the old FM_HOME variable and run the new script"
