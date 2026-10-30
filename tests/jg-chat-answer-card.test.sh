#!/usr/bin/env bash
# tests/jg-chat-answer-card.test.sh - a captain's chat answer is recorded on its board
# card (jg-question-card.sh answer) and a turn that ends with the card still waiting
# is flagged by the turn-end guard, in Main and lead homes alike. No model call.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-chat-answer-card)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
jg_git_identity fmtest fmtest@example.invalid
KEY=use-the-repo-card
WORDS="yes, go ahead and use the repo card"

setup() {  # <name> -> case dir with a board holding one open card, a fake sign-off-axi, a home
  local d=$TMP_ROOT/$1
  mkdir -p "$d/state" "$d/fakebin" "$d/so/.sign-off" "$d/bin"
  printf '{"schema":2,"items":[{"key":"%s","close":"done"}]}\n' "$KEY" > "$d/so/.sign-off/decisions.json"
  : > "$d/so/.sign-off/decisions.answers.jsonl"
  cat > "$d/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
cmd=$1; shift
board=$SIGN_OFF_HOME/.sign-off/decisions.json
log=${board%.json}.answers.jsonl
case "$cmd" in
  answers) jq -s 'reduce .[] as $a ({}; .[$a.key] = ($a | del(.key)))' "$log" ;;
  list) jq -c --slurpfile a <(jq -s 'map(.key)' "$log") '{decisions: [.items[] | select(.key as $k | ($a[0] | index($k)) | not) | {key}]}' "$board" ;;
esac
SH
  chmod +x "$d/fakebin/sign-off-axi"
  git init -q "$d"
  git -C "$d" commit -q --allow-empty -m init
  : > "$d/AGENTS.md"
  cp "$ROOT"/bin/*.sh "$d/bin/"
  mkdir -p "$d/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$d/docs/supervision-protocols"
  printf '%s\n' "$d"
}

transcript() {  # <case-dir> -> a transcript where the captain answered the posted question in chat
  local t=$1/transcript.jsonl
  {
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Use the repo card? Card: %s"}]}}\n' "$KEY"
    printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$WORDS"
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done, moving on."}]}}\n'
  } > "$t"
  printf '%s\n' "$t"
}

run_card() {  # <case-dir> args...
  local d=$1
  shift
  env PATH="$d/fakebin:$PATH" JG_HOME="$d" SIGN_OFF_HOME="$d/so" HOME="$d/home" "$d/bin/jg-question-card.sh" "$@" 2>&1
}

run_guard() {  # <case-dir> <transcript>
  local d=$1
  printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$2" \
    | env PATH="$d/fakebin:$PATH" CLAUDECODE=1 JG_HOME="$d" SIGN_OFF_HOME="$d/so" bash "$d/bin/jg-turnend-guard.sh" 2>&1
}

test_answer_records_his_words_on_the_card() {
  local d out
  d=$(setup answer)
  out=$(run_card "$d" answer "$KEY" --words "$WORDS") || fail "answer was refused: $out"
  assert_contains "$out" "answered: $KEY" "answer did not report the card"
  assert_equals "$WORDS" "$(jq -r .answer "$d/so/.sign-off/decisions.answers.jsonl")" "his words are not on the card"
  assert_equals "" "$(run_card "$d" keys)" "the card still reads as open"
  run_card "$d" answer "$KEY" --words "again" > /dev/null && fail "an already answered card was answered again"
  d=$(setup answer-refuse)
  run_card "$d" answer ghost-card --words x > /dev/null && fail "an unknown card was answered"
  run_card "$d" answer "$KEY" > /dev/null && fail "an answer with no words was accepted"
  pass "jg-question-card answer records his exact words on the open card and refuses an unknown card or empty words"
}

test_answer_reaches_a_routed_lead_and_does_not_wake_main_for_an_unrouted_one() {
  local d out
  d=$(setup route)
  printf 'kind=squad_lead\n' > "$d/state/lead1.meta"
  mkdir -p "$d/state/board-routes"
  printf 'lead=lead1\ndecision=%s\n' "$KEY" > "$d/state/board-routes/$KEY"
  run_card "$d" answer "$KEY" --words "$WORDS" > /dev/null || fail "answer failed"
  out=$(env PATH="$d/fakebin:$PATH" JG_HOME="$d" SIGN_OFF_HOME="$d/so" JG_SEND_SETTLE=0 "$d/bin/jg-board-answers.sh" check 2>&1)
  assert_contains "$out" "$KEY" "the check never saw the chat answer on the routed card"
  d=$(setup unrouted)
  : > "$d/state/.board-answers-seen"
  run_card "$d" answer "$KEY" --words "$WORDS" > /dev/null || fail "answer failed"
  out=$(env PATH="$d/fakebin:$PATH" JG_HOME="$d" SIGN_OFF_HOME="$d/so" "$d/bin/jg-board-answers.sh" check 2>&1)
  assert_equals "" "$out" "an unrouted chat answer woke Main with its own words"
  pass "a chat answer is carried to the owning lead and does not wake Main for an unrouted card"
}

test_guard_flags_a_chat_answer_while_the_card_waits() {
  local d t out status
  d=$(setup guard-main)
  t=$(transcript "$d")
  out=$(run_guard "$d" "$t"); status=$?
  expect_code 2 "$status" "the guard let a turn end with the answered card still waiting"
  assert_contains "$out" "HE ANSWERED IN CHAT" "the banner is missing"
  assert_contains "$out" "jg-question-card.sh answer $KEY" "the banner names no path to the card"
  out=$(run_guard "$d" "$t"); status=$?
  expect_code 0 "$status" "the same answer was flagged twice and would wedge the turn"
  run_card "$d" answer "$KEY" --words "$WORDS" > /dev/null
  rm -f "$d/state/.chat-answer-flagged"
  out=$(run_guard "$d" "$t"); status=$?
  expect_code 0 "$status" "the guard flagged a card that is already answered"
  pass "jg-turnend-guard: flags a turn ending after a chat answer while its card waits, once, and is silent once answered"
}

test_guard_flags_a_lead_home() {
  local d t out status
  d=$(setup guard-lead)
  printf 'sm-test-1\n' > "$d/.jg-squad-lead-home"
  t=$(transcript "$d")
  out=$(run_guard "$d" "$t"); status=$?
  expect_code 2 "$status" "the guard skipped a lead home"
  assert_contains "$out" "HE ANSWERED IN CHAT" "the lead home banner is missing"
  pass "jg-turnend-guard: the chat-answer flag covers a lead home"
}

test_guard_ignores_a_card_he_was_never_asked() {
  local d t out status
  d=$(setup guard-unrelated)
  t=$d/transcript.jsonl
  {
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Working on it."}]}}\n'
    printf '{"type":"user","message":{"role":"user","content":"ok thanks"}}\n'
  } > "$t"
  out=$(run_guard "$d" "$t"); status=$?
  expect_code 0 "$status" "the guard flagged a message that answers no posted card: $out"
  pass "jg-turnend-guard: a human message after a reply that cites no open card is not flagged"
}

test_answer_records_his_words_on_the_card
test_answer_reaches_a_routed_lead_and_does_not_wake_main_for_an_unrouted_one
test_guard_flags_a_chat_answer_while_the_card_waits
test_guard_flags_a_lead_home
test_guard_ignores_a_card_he_was_never_asked
