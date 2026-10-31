#!/usr/bin/env bash
# tests/jg-chat-answer-card.test.sh - a captain's chat answer is recorded on its board
# card (jg-question-card.sh answer) and carried to the lead that owns the card.
#
# The turn-end guard no longer reads a captain message for an answer (captain
# 2026-10-31: the chat-reading answer guard is gone), so nothing here drives it.
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

run_card() {  # <case-dir> args...
  local d=$1
  shift
  env PATH="$d/fakebin:$PATH" JG_HOME="$d" SIGN_OFF_HOME="$d/so" HOME="$d/home" "$d/bin/jg-question-card.sh" "$@" 2>&1
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



test_answer_records_his_words_on_the_card
test_answer_reaches_a_routed_lead_and_does_not_wake_main_for_an_unrouted_one
