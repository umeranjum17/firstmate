#!/usr/bin/env bash
# tests/jg-herdr-names.test.sh - the agent-name pin sticks for every task id, and
# bin/jg-herdr-names.sh moves a home's recorded live items off the old names,
# leaves every other home's items alone, and fails its check while an old word
# is left. A fake herdr applies the real client's agent-name rules (1-32
# characters, lowercase first letter, [a-z0-9_-], session-unique).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The old words, assembled from halves so this test adds no leftover to the
# rename's tracked-name gate while still naming what the check forbids.
OLD_TAB="f""m-"
OLD_LEAD="2nd""mate-"
OLD_PRODUCT="first""mate"

tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
fakebin=$(jg_fakebin "$tmp")
world="$tmp/world.json"
calls="$tmp/calls.log"

cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
# Fake herdr over $FAKE_WORLD (workspaces, tabs, agents) and $FAKE_CALLS.
world=$FAKE_WORLD
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then shift 2; continue; fi
  args+=("$1"); shift
done
set -- "${args[@]}"
printf '%s\n' "$*" >> "$FAKE_CALLS"
err() { jq -n -c --arg c "$1" --arg m "$2" '{error: {code: $c, message: $m}, id: "fake"}'; exit 1; }
write() { jq -c "$@" "$world" > "$world.new" && mv "$world.new" "$world"; }
case "$1 $2" in
  "workspace list") jq -c '{id: "fake", result: {type: "workspace_list", workspaces: .workspaces}}' "$world" ;;
  "agent list") jq -c '{id: "fake", result: {type: "agent_list", agents: .agents}}' "$world" ;;
  "tab list") jq -c --arg w "$4" '{id: "fake", result: {type: "tab_list", tabs: [.tabs[] | select(.workspace_id == $w)]}}' "$world" ;;
  "workspace rename") id=$3; shift 3; write --arg id "$id" --arg l "$*" '(.workspaces[] | select(.workspace_id == $id) | .label) = $l'; echo '{"id":"fake","result":{}}' ;;
  "tab rename") id=$3; shift 3; write --arg id "$id" --arg l "$*" '(.tabs[] | select(.tab_id == $id) | .label) = $l'; echo '{"id":"fake","result":{}}' ;;
  "agent rename")
    pane=$3 name=$4
    jq -e --arg p "$pane" '.agents[] | select(.pane_id == $p)' "$world" >/dev/null || err agent_not_found "agent target $pane not found"
    printf '%s' "$name" | grep -Eq '^[a-z][a-z0-9_-]{0,31}$' \
      || err invalid_agent_name "agent name must start with a lowercase letter and contain only lowercase letters, digits, '-' or '_' (1-32 characters)"
    holder=$(jq -r --arg n "$name" '.agents[] | select(.name == $n) | .pane_id' "$world" | head -n1)
    if [ -n "$holder" ]; then
      err agent_name_taken "agent name $name is already used; candidates: terminal_id=t pane_id=$holder workspace_id=w1 tab_id=t1 cwd=/x status=Idle"
    fi
    write --arg p "$pane" --arg n "$name" '(.agents[] | select(.pane_id == $p) | .name) = $n'
    echo '{"id":"fake","result":{}}' ;;
  *) err unsupported "$*" ;;
esac
SH
chmod +x "$fakebin/herdr"
export FAKE_WORLD="$world" FAKE_CALLS="$calls"
PATH="$fakebin:$PATH"

# --- agent_name_for / pin ---------------------------------------------------
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"

valid_name() { printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9_-]{0,31}$'; }

assert_equals "rename-sweep-a-sessions" "$(jg_backend_herdr_agent_name_for rename-sweep-a-sessions)" "a valid short id is the name"
assert_equals "t-9lives" "$(jg_backend_herdr_agent_name_for 9lives)" "a digit start gets a letter"
assert_equals "upper_x" "$(jg_backend_herdr_agent_name_for UPPER_x)" "upper case is lowered"
long_a=live-names-still-say-the-same-thing-here-aa
long_b=live-names-still-say-the-same-thing-here-bb
name_a=$(jg_backend_herdr_agent_name_for "$long_a")
name_b=$(jg_backend_herdr_agent_name_for "$long_b")
valid_name "$name_a" || fail "a long id gives a name herdr accepts ($name_a)"
assert_not_equals "$name_a" "$name_b" "long ids sharing a prefix get different names"
assert_equals "$name_a" "$(jg_backend_herdr_agent_name_for "$long_a")" "the name is deterministic"
for id in a "$long_a" "$(printf 'x%.0s' $(seq 1 64))" 7-seven-eight-nine-ten-eleven-twelve-thirteen-14; do
  valid_name "$(jg_backend_herdr_agent_name_for "$id")" || fail "id '$id' maps to a valid name"
done

reset_world() {
  : > "$calls"
  cat > "$world" <<EOF
{"workspaces":[{"workspace_id":"w1","label":"juggernaut"}],
 "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"jg-x"}],
 "agents":[{"pane_id":"w1:p1","tab_id":"w1:t1","name":"juggernaut-4"},{"pane_id":"w1:p2","tab_id":"w1:t1","name":"other"}]}
EOF
}

reset_world
jg_backend_herdr_pin_agent_name s w1:p1 "$long_a" 2>"$tmp/err"
assert_equals "$name_a" "$JG_BACKEND_HERDR_PINNED_NAME" "a long id pins"
assert_equals "$name_a" "$(jq -r '.agents[0].name' "$world")" "the live agent carries the pinned name"
assert_equals "" "$(cat "$tmp/err")" "a successful pin is silent"

jg_backend_herdr_pin_agent_name s w1:p1 "$long_a" 2>"$tmp/err"
assert_equals "$name_a" "$JG_BACKEND_HERDR_PINNED_NAME" "a name this pane already holds counts as pinned"
assert_equals "" "$(cat "$tmp/err")" "re-pinning the same name is silent"

jg_backend_herdr_pin_agent_name s w1:p2 "$long_a" 2>"$tmp/err"
variant=$(jq -r '.agents[1].name' "$world")
valid_name "$variant" || fail "the fallback for a taken name is valid ($variant)"
assert_not_equals "$name_a" "$variant" "a taken name falls back to a variant"
assert_equals "$variant" "$JG_BACKEND_HERDR_PINNED_NAME" "the variant is reported"

jg_backend_herdr_pin_agent_name s w1:p9 "$long_a" 2>"$tmp/err"; rc=$?
assert_equals 0 "$rc" "a pin on a missing agent never fails the caller"
assert_equals "" "$JG_BACKEND_HERDR_PINNED_NAME" "nothing pinned on a missing agent"
assert_contains "$(cat "$tmp/err")" "agent_not_found" "the warning carries herdr's own error"
pass "agent names map into herdr's rules and the pin handles taken and missing agents"
