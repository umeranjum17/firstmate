#!/usr/bin/env bash
# Behavior tests for difficulty tiers in bin/jg-dispatch-resolve.sh.
#
# One case per tier proves the tier's own ordered list is the only source of
# candidates, one case proves a rule without a tier keeps the pre-tier profile
# line, and one case proves a rule tier the file never configures is refused.
#
# The network and quota boundaries are fakes on PATH: the fake curl answers the
# rule Choice named by FAKE_PICK and the fake quota-axi prints a schema-5
# snapshot, so the real resolver runs end to end with no call.
# docs/configuration.md "Difficulty tiers" owns the schema these cases pin.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

RESOLVE="$ROOT/bin/jg-dispatch-resolve.sh"
TMP_ROOT=$(jg_test_tmproot jg-dispatch-resolve-tiers)
trap jg_test_cleanup EXIT

HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
FIXTURE="$TMP_ROOT/quota.json"
BRIEF="$TMP_ROOT/brief.md"
RULES_FILE="$TMP_ROOT/rules.json"
mkdir -p "$HOME_DIR/config" "$FAKEBIN"

cat > "$BRIEF" <<'EOF'
# Task
## Captain's intent
Route a small, well understood edit.
## Juggernaut spec
1. Edit one file.
EOF

# claude 80% at spendPriority -1.1111 and codex 20% at -0.8333: codex outranks
# claude, so a tier list holding both always picks its codex profile and the
# chosen model identifies the tier that supplied it.
cat > "$FIXTURE" <<'JSON'
{"schemaVersion": 5, "providers": [
  {"provider": "claude", "quotaSemantics": {"status": "known", "effectiveAvailability": [
    {"scope": "all_models", "status": "known", "effectivePercentRemaining": 80,
     "selection": {"spendPriority": -1.1111}, "runway": {"status": "projected_exhaustion"}}]}},
  {"provider": "codex", "quotaSemantics": {"status": "known", "effectiveAvailability": [
    {"scope": "all_models", "status": "known", "effectivePercentRemaining": 20,
     "selection": {"spendPriority": -0.8333}, "runway": {"status": "projected_exhaustion"}}]}}
]}
JSON

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
cat "$JG_TEST_QUOTA_FIXTURE"
SH

# Answers the rule Choice named by FAKE_PICK: every option is listed so the
# resolver's sum and key checks pass and the answer clears the 0.6 floor.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
  -o) out=${2-}; shift 2 ;;
  *) shift ;;
  esac
done
cat >/dev/null 2>&1 || true
[ -n "$out" ] || exit 0
jq -n --arg choice "${FAKE_PICK:-rule_1}" --argjson n "${FAKE_RULES:-1}" '
  (["default"] + [range(1; $n + 1) | "rule_\(.)"]) as $keys |
  ($keys | length) as $count |
  {model: "jev-fake",
   answers: {rule: {choice: $choice, confidence: 0.9,
     probabilities: ($keys | map({key: ., value: (if . == $choice then 0.9 else (0.1 / ($count - 1)) end)}) | from_entries)}},
   usage: {input_tokens: 11, output_tokens: 7}}' >"$out"
printf '200'
SH
chmod +x "$FAKEBIN/curl" "$FAKEBIN/quota-axi"

# One rule per tier plus one untiered rule, and a tier map whose every list is
# the only place its models are named.
cat > "$RULES_FILE" <<'JSON'
{
  "tiers": {
    "easy": [
      { "harness": "claude", "model": "easy-claude" },
      { "harness": "codex", "model": "easy-codex" }
    ],
    "standard": [
      { "harness": "claude", "model": "standard-claude" },
      { "harness": "codex", "model": "standard-codex" }
    ],
    "hard": [
      { "harness": "codex", "model": "hard-codex" }
    ],
    "frontier": [
      { "harness": "claude", "model": "frontier-claude" },
      { "harness": "codex", "model": "frontier-codex" }
    ]
  },
  "rules": [
    { "when": "A rote mechanical edit.", "tier": "easy" },
    { "when": "An ordinary single-file change.", "tier": "standard" },
    { "when": "A risky multi-file refactor.", "tier": "hard" },
    { "when": "An unfamiliar architecture with no room for error.", "tier": "frontier" },
    { "when": "A change routed by its own profile.", "use": { "harness": "claude", "model": "untiered-claude", "effort": "medium" } }
  ],
  "default": [
    { "harness": "claude", "model": "default-claude" }
  ]
}
JSON
cp "$RULES_FILE" "$HOME_DIR/config/crew-dispatch.json"

resolve() {  # <picked-rule>; the resolver's TOON block, or its stderr on refusal
  TYPESAFE_API_KEY=test-key JG_HOME="$HOME_DIR" JG_TEST_QUOTA_FIXTURE="$FIXTURE" \
    FAKE_PICK="$1" FAKE_RULES=5 PATH="$FAKEBIN:$PATH" \
    "$RESOLVE" "$BRIEF" 2>&1
}

# Each tier: the block names the tier, the picked model is that tier's own
# highest-spendPriority profile, no other tier's model appears, and the
# candidate count is exactly the length of that tier's ordered list.
assert_tier_route() {  # <tier> <rule-index> <candidate-count>
  local tier=$1 rule=$2 candidates=$3 out line wrong
  out=$(resolve "rule_$rule") || fail "$tier: the resolver refused to run: $out"
  line=$(printf '%s\n' "$out" | grep -F '  profile: ' || :)
  assert_contains "$out" "status: clear" "$tier: the resolver did not resolve the tiered rule"
  assert_contains "$out" "  tier: $tier" "$tier: the block does not name the tier it came from"
  assert_contains "$line" "--model '$tier-codex'" "$tier: the profile line does not name the tier's chosen model"
  assert_contains "$line" "(tier $tier)" "$tier: the profile line does not name the tier beside the model"
  assert_contains "$out" "candidate: codex:$tier-codex  tier=$tier" "$tier: the scorecard does not show the tier beside the model"
  assert_equals "$candidates" "$(printf '%s\n' "$out" | grep -cF '  candidate: ')" \
    "$tier: the resolver did not take exactly the tier's own ordered list"
  while IFS= read -r wrong; do
    [ -n "$wrong" ] || continue
    assert_not_contains "$line" "$wrong" "$tier: the profile line named a model from another tier"
  done <<< "$(jq -r --arg t "$tier" '.tiers | to_entries[] | select(.key != $t) | .value[] | .model' "$RULES_FILE")"
}

test_each_tier_routes_from_its_own_ordered_list() {
  assert_tier_route easy 1 2
  assert_tier_route standard 2 2
  assert_tier_route hard 3 1
  assert_tier_route frontier 4 2
  pass "each tier resolves only the candidates its own ordered list declares, and names its tier"
}

# A rule with no tier keeps the pre-tier route: its own use profile, no tier
# anywhere in the block, and the same profile line shape as before tiers existed.
test_untiered_rule_keeps_todays_behaviour() {
  local out
  out=$(resolve rule_5) || fail "untiered: the resolver refused to run: $out"
  assert_contains "$out" "status: clear" "untiered: the resolver did not resolve the rule"
  assert_contains "$out" "  note: rule matched" "untiered: the rule match note changed"
  assert_equals "  profile: --harness 'claude' --model 'untiered-claude' --effort 'medium'" \
    "$(printf '%s\n' "$out" | grep -F '  profile: ')" "untiered: the profile line changed"
  assert_not_contains "$out" "(tier " "untiered: the profile line grew a tier annotation"
  assert_not_contains "$out" "  tier:" "untiered: the block grew a tier line"
  assert_contains "$out" "candidate: claude:untiered-claude  provider=claude" \
    "untiered: the candidate line changed"
  pass "a rule without a tier keeps its own use profile and the unchanged profile line"
}

# A tier a rule names but the file never configures is refused as a
# configuration error instead of silently routing to another tier.
test_unconfigured_rule_tier_is_refused() {
  local out rc
  printf '%s\n' '{ "rules": [ { "when": "Anything.", "tier": "frontier" } ] }' \
    > "$HOME_DIR/config/crew-dispatch.json"
  set +e
  out=$(resolve rule_1)
  rc=$?
  set -e
  assert_equals 2 "$rc" "an unconfigured rule tier must exit 2, not resolve"
  assert_contains "$out" "each rule tier needs a tiers entry: frontier" \
    "the refusal does not name the unconfigured tier"
  pass "a rule tier the file never configures is refused as a configuration error"
}

test_each_tier_routes_from_its_own_ordered_list
test_untiered_rule_keeps_todays_behaviour
test_unconfigured_rule_tier_is_refused
