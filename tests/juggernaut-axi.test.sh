#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# Behavior test for bin/juggernaut-axi (slice 1): status and tickets, TOON by
# default with --json parity, the juggernaut-axi.v1 contract, bounds with disclosed
# omissions, and refusal of unknown commands and bad arguments.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

AXI="$ROOT/bin/juggernaut-axi"
TMP_ROOT=$(jg_test_tmproot juggernaut-axi)
HOME_DIR=$TMP_ROOT/home
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
cat > "$HOME_DIR/data/backlog.md" <<'MD'
## In flight
- [ ] ship-task - Ship the thing (repo: juggernaut) (kind: ship) (since 2026-07-11)

## Queued
- [ ] live-gate - Real queued work blocked-by: ship-task (repo: juggernaut) (kind: ship)
- [ ] other-gate - Work elsewhere (repo: other) (kind: scout)

## Done
- [x] done-a - Landed thing (repo: juggernaut) (kind: ship) (merged 2026-07-10)
MD
export JG_HOME=$HOME_DIR JG_ROOT_OVERRIDE=$TMP_ROOT/fixture-root
mkdir -p "$JG_ROOT_OVERRIDE"

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
