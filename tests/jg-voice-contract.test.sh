#!/usr/bin/env bash
# Regression guard for the shipped voice contract in AGENTS.md section 9.
#
# The contract retired the nautical no-op reply and the sailing seasoning that
# carried it. A retired phrase creeping back onto any tracked surface is a
# contract regression, not a style preference, so it fails here rather than
# waiting for a reader to notice the distro speaking in two voices.
#
# It also holds the captain-facing default sentence shape: the contract's own
# examples must stay short, active and free of internal terms. The check is a
# word count and a small term list, so it costs no model call and no network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Assembled so this guard's own source is not itself one of the hits it looks for.
RETIRED="ship""shape"
CURRENT_NOOP_REPLY="Reply exactly \`Captain, standing by.\`"
STE_DEFAULT='Simplified Technical English by default'
MAX_SENTENCE_WORDS=20
# The internal terms a captain would never read in a plain outcome, kept short
# on purpose: this is a floor against jargon creeping into the examples, not a
# full mirror of the contract's translation list.
BANNED_INTERNAL_TERMS='worktree|teardown|harness|backend|operator|fail-closed|fail-open|validation-state'

hits=$(cd "$ROOT" && git grep -I -n -F -e "$RETIRED" -- . || true)
[ -z "$hits" ] || fail "retired voice phrase is still tracked: $hits"
pass "no tracked surface carries the retired nautical reply"

grep -Fq "$CURRENT_NOOP_REPLY" "$ROOT/AGENTS.md" \
  || fail "AGENTS.md no longer states the no-op reply in the current voice"
pass "AGENTS.md still states the no-op reply the voice contract adopted"

grep -Fq "$STE_DEFAULT" "$ROOT/AGENTS.md" \
  || fail "AGENTS.md no longer states the captain-facing Simplified Technical English default"
pass "AGENTS.md states the captain-facing sentence-shape default"

examples=$(awk '/^Squad voice examples\.$/{seen=1; next} seen && /^## /{exit} seen && /^- "/{print}' "$ROOT/AGENTS.md")
[ -n "$examples" ] || fail "AGENTS.md carries no squad voice examples block"

long=$(printf '%s\n' "$examples" | awk -v max="$MAX_SENTENCE_WORDS" '
  {
    line = $0
    sub(/^- "/, "", line)
    sub(/"$/, "", line)
    sentences = split(line, parts, /[.!?] /)
    for (i = 1; i <= sentences; i++) {
      words = split(parts[i], word, /[ \t]+/)
      if (words > max) print words " words: " parts[i]
    }
  }')
[ -z "$long" ] || fail "captain-facing example sentence is longer than $MAX_SENTENCE_WORDS words: $long"
pass "every captain-facing example sentence stays within $MAX_SENTENCE_WORDS words"

jargon=$(printf '%s\n' "$examples" | grep -Eio "$BANNED_INTERNAL_TERMS" || true)
[ -z "$jargon" ] || fail "captain-facing example names an internal term: $jargon"
pass "no captain-facing example names an internal term"
