#!/usr/bin/env bash
# tests/jg-card-rules.test.sh - the captain's card rules: his board carries his
# decisions alone. A hold his own stop order created is his instruction, a stuck
# worker is Main's to unblock, and a card names no internal thing and offers two
# clear options. A card that breaks one is refused with one line naming the rule
# and never reaches the board (bin/jg-ask-gate-lib.sh, bin/jg-question-card.sh).
#
# The first rule's example is the card his phone showed him, with the number a
# placeholder: the repo's owner-details guard forbids committing his own record
# number to a public repository, and this test needs the shape, not the number.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-card-rules)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
CARD="$ROOT/bin/jg-question-card.sh"

setup() {  # <name> -> the case dir
  local d=$TMP_ROOT/$1
  mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/fakebin" "$d/so/.sign-off"
  printf '{"schema":2,"items":[]}\n' > "$d/so/.sign-off/decisions.json"
  cat > "$d/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
cmd=$1; shift
board=$SIGN_OFF_HOME/.sign-off/decisions.json
case "$cmd" in
  list) jq -c '{decisions: [.items[]]}' "$board" ;;
  raise)
    key='' title=''
    while [ "$#" -gt 0 ]; do
      case "$1" in --key) key=$2; shift ;; --title) title=$2; shift ;; esac
      shift
    done
    jq --arg k "${key:-card}" --arg t "$title" \
      '.items += [{key: $k, kind: "decision", title: $t}]' "$board" > "$board.t" && mv "$board.t" "$board"
    printf '%s\n' "${key:-card}" ;;
esac
SH
  chmod +x "$d/fakebin/sign-off-axi"
  printf 'leash: matters\n' > "$d/so/.sign-off/config.yaml"
  printf '%s\n' "$d"
}

run() {  # <case dir> <command...>
  local d=$1
  shift
  env PATH="$d/fakebin:$PATH" JG_HOME="$d/home" JG_ROOT_OVERRIDE="$d/home" \
    SIGN_OFF_HOME="$d/so" SIGNOFF_LOG="$d/signoff.log" "$@" 2>&1
}

post() {  # <case dir> [post flags...]
  local d=$1
  shift
  run "$d" "$CARD" post --ask-ref m1 --must design-pick \
    --outcome yes="It ships Friday." --outcome no="It waits a week." "$@"
}

raised() { jq -r '.items | length' "$1/so/.sign-off/decisions.json"; }

refused_by() {  # <case dir> <output> <rule> -> the first stderr line names that rule
  local d=$1 out=$2 rule=$3 first
  first=$(printf '%s\n' "$out" | head -1)
  assert_contains "$first" "refused: rule $rule" "the refusal did not name rule $rule"
  assert_equals "0" "$(raised "$d")" "a card the rules refuse still reached the captain's board"
}

test_rule1_a_captain_stop_order_is_never_a_card() {
  local d out
  d=$(setup stop)
  out=$(post "$d" --title "captain stop order Main42 holds this lane; branch preserved unmerged?" \
    --why "captain stop order Main42 holds this lane; branch preserved unmerged")
  refused_by "$d" "$out" 1
  assert_grep "- Ask: captain stop order Main42" "$d/home/data/overwatch-decisions.md" \
    "the refused hold was not recorded for Main"
  pass "rule 1: a hold the captain's own stop order created never becomes a card"
}

test_rule2_a_stuck_worker_is_never_a_card() {
  local d out
  d=$(setup stuck)
  out=$(run "$d" "$CARD" post --ask-ref waiting-byokit --key waiting-byokit-card \
    --title "Unblock stuck byokit?" --why "byokit is stuck on a plan that needs one call." \
    --outcome yes="Main clears or answers the wait now." --outcome no="It stays stuck until you steer it.")
  refused_by "$d" "$out" 2
  assert_grep "- Ask: Unblock stuck byokit?" "$d/home/data/overwatch-decisions.md" \
    "the refused stuck-worker card was not recorded for Main"
  pass "rule 2: a stuck worker is Main's to unblock and never a card"
}

test_rule3_a_card_is_one_plain_question_with_two_clear_options() {
  local d out
  d=$(setup names)
  out=$(post "$d" --title "Approve the release for Main42?")
  refused_by "$d" "$out" 3
  out=$(post "$d" --title "Ship the fix in jg-4a662adc-behaviour-evals?")
  refused_by "$d" "$out" 3
  out=$(post "$d" --title "Read the plan at data/wrapper-report.md and approve?")
  refused_by "$d" "$out" 3
  out=$(run "$d" "$CARD" post --ask-ref m1 --must design-pick --title "Pick the launch word" \
    --outcome yes="It ships Friday." --outcome no="It waits a week.")
  refused_by "$d" "$out" 3
  assert_contains "$out" "plain question" "a title that is not a question was refused for another reason"
  out=$(run "$d" "$CARD" post --ask-ref m1 --must design-pick --title "Pick the launch word?" \
    --outcome yes="It ships Friday.")
  refused_by "$d" "$out" 3
  out=$(post "$d" --title "Ship the new sign-in screen this week?" \
    --why "The screen is ready and the tests pass on every phone.")
  [ -n "$out" ] || fail "a plain product question was refused: $out"
  assert_equals "1" "$(raised "$d")" "the plain product question did not reach the board"
  pass "rule 3: a Main number, a task id and a path are refused, and a card is one question with two options"
}

test_rule4_a_refused_card_names_its_rule_in_one_line() {
  local d out lines
  d=$(setup one-line)
  out=$(post "$d" --title "captain stop order Main42 holds this lane?")
  lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  assert_equals "2" "$lines" "the refusal was not one line plus its Overwatch record: $out"
  assert_contains "$(printf '%s\n' "$out" | head -1)" "refused: rule 1," \
    "the one line did not name the rule that failed"
  pass "rule 4: a refused card is one line naming the rule, then its Overwatch record"
}

test_rule1_a_captain_stop_order_is_never_a_card
test_rule2_a_stuck_worker_is_never_a_card
test_rule3_a_card_is_one_plain_question_with_two_clear_options
test_rule4_a_refused_card_names_its_rule_in_one_line
