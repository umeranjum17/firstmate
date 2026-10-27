#!/usr/bin/env bash
# Slice 1 of the skill rename: each user-typed skill answers to its new name
# and, during the migration window, to its old name. An old name must be a
# working alias, that is, point at a new skill that exists.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILLS="$ROOT/.agents/skills"
PAIRS="afk:watchover quiet:radio-silence ahoy:debrief bearings:sitrep updatefirstmate:resupply stow:intel"

skill_name() { sed -n '0,/^name: /s/^name: //p' "$1/SKILL.md"; }

for pair in $PAIRS; do
  old=${pair%%:*}
  new=${pair##*:}
  [ "$(skill_name "$SKILLS/$new")" = "$new" ] || fail "new skill $new must declare name: $new"
  grep -q "^user-invocable: true" "$SKILLS/$new/SKILL.md" || fail "$new must stay user-invocable"
  grep -q "/$new" "$SKILLS/$new/SKILL.md" || fail "$new must name its own slash command"
  [ "$(skill_name "$SKILLS/$old")" = "$old" ] || fail "old name $old must still resolve during the window"
  grep -q "Load the \`$new\` skill" "$SKILLS/$old/SKILL.md" || fail "alias $old must point at $new"
  pass "/$new works and /$old still aliases it"
done
