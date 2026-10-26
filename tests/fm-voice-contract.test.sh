#!/usr/bin/env bash
# Regression guard for the shipped voice contract in AGENTS.md section 9.
#
# The contract retired the nautical no-op reply and the sailing seasoning that
# carried it. A retired phrase creeping back onto any tracked surface is a
# contract regression, not a style preference, so it fails here rather than
# waiting for a reader to notice the distro speaking in two voices.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Assembled so this guard's own source is not itself one of the hits it looks for.
RETIRED="ship""shape"
CURRENT_NOOP_REPLY="Reply exactly \`Captain, standing by.\`"

hits=$(cd "$ROOT" && git grep -I -n -F -e "$RETIRED" -- . || true)
[ -z "$hits" ] || fail "retired voice phrase is still tracked: $hits"
pass "no tracked surface carries the retired nautical reply"

grep -Fq "$CURRENT_NOOP_REPLY" "$ROOT/AGENTS.md" \
  || fail "AGENTS.md no longer states the no-op reply in the current voice"
pass "AGENTS.md still states the no-op reply the voice contract adopted"
