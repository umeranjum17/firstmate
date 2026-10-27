#!/usr/bin/env bash
# Behavior test for bin/juggernaut-axi (slice 1): status and tickets, TOON by
# default with --json parity, the juggernaut-axi.v1 contract, bounds with disclosed
# omissions, and refusal of unknown commands and bad arguments.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

AXI="$ROOT/bin/juggernaut-axi"
TMP_ROOT=$(fm_test_tmproot juggernaut-axi)
HOME_DIR=$TMP_ROOT/home
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
cat > "$HOME_DIR/data/backlog.md" <<'MD'
## In flight
- [ ] ship-task - Ship the thing (repo: firstmate) (kind: ship) (since 2026-07-11)

## Queued
- [ ] live-gate - Real queued work blocked-by: ship-task (repo: firstmate) (kind: ship)
- [ ] other-gate - Work elsewhere (repo: other) (kind: scout)

## Done
- [x] done-a - Landed thing (repo: firstmate) (kind: ship) (merged 2026-07-10)
MD
export FM_HOME=$HOME_DIR FM_ROOT_OVERRIDE=$TMP_ROOT/fixture-root
mkdir -p "$FM_ROOT_OVERRIDE"

[ -x "$AXI" ] || fail "bin/juggernaut-axi is missing or not executable"

json=$("$AXI" tickets --json) || fail "tickets --json failed"
assert_equals juggernaut-axi.v1 "$(jq -r .schema <<<"$json")" "tickets schema is versioned"
assert_equals 4 "$(jq -r .count <<<"$json")" "all four tickets counted"
assert_equals "ship-task" "$(jq -r '.tickets[1].blocked_by' <<<"$json")" "blocker projected"

toon=$("$AXI" tickets) || fail "tickets (TOON) failed"
assert_contains "$toon" "schema: juggernaut-axi.v1" "TOON carries the schema"
assert_contains "$toon" "tickets[4]{id,title,state,repo,kind,blocked_by}:" "TOON tabular tickets"

filtered=$("$AXI" tickets --repo other --json) || fail "repo filter failed"
assert_equals "other-gate" "$(jq -r '.tickets[0].id' <<<"$filtered")" "repo filter applies"

limited=$("$AXI" tickets --limit 2 --json) || fail "limit failed"
assert_equals 2 "$(jq -r '.tickets | length' <<<"$limited")" "limit bounds rows"
assert_equals 2 "$(jq -r '.omitted[0].count' <<<"$limited")" "omitted rows are counted"

status=$("$AXI" status --json) || fail "status --json failed"
assert_equals juggernaut-axi.v1 "$(jq -r .schema <<<"$status")" "status schema is versioned"
assert_equals status "$(jq -r .view <<<"$status")" "status view"
assert_contains "$("$AXI" status)" "view: status" "status TOON renders"

"$AXI" bogus >/dev/null 2>&1 && fail "unknown command must fail"
"$AXI" tickets --state nope >/dev/null 2>&1 && fail "bad --state must fail"
"$AXI" tickets --limit 0 >/dev/null 2>&1 && fail "bad --limit must fail"
assert_contains "$("$AXI" --version)" "juggernaut-axi" "--version prints"
pass "juggernaut-axi status and tickets"
