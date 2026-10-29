#!/usr/bin/env bash
# A provisioned home is a clone of this repository, so it gets Calm (Stealth) only if the
# tracked links to the Claude mod and its skill resolve inside that clone (docs/calm.md).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-calm-home-links)
home=$TMP_ROOT/home
git clone -q --no-hardlinks "$ROOT" "$home" || fail "clone of the repository failed"

mod=$home/.claude/mods/juggernaut-calm
for link in "$home/.agents/skills/juggernaut-calm" "$home/.claude/skills/juggernaut-calm"; do
  [ -f "$link/.claude-plugin/plugin.json" ] || fail "$link does not resolve to the Calm mod"
  [ "$(cd -P "$link" && pwd)" = "$(cd -P "$mod" && pwd)" ] || fail "$link resolves outside the mod"
done
pass "a provisioned home links the Calm mod through both skill directories"

module=$(sed -n 's/.*"modules": *\["\([^"]*\)"\].*/\1/p' "$mod/hooks/hooks.json")
[ -n "$module" ] && [ -f "$mod/hooks/$module" ] || fail "hooks.json names no loadable module"
for ext in "$home"/.pi/extensions/lib/jg-calm-preservation.ts "$home"/.pi/extensions/lib/jg-calm-working-ship-sprite.ts; do
  [ -f "$ext" ] || fail "Pi Calm link $ext dangles"
done
pass "the hooks module and the Pi links into the mod resolve"
