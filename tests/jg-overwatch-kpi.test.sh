#!/usr/bin/env bash
# Behavioral regressions for the Overwatch KPI (bin/jg-overwatch-kpi.sh): each
# typed captain message is recorded, the turn-end guard refuses once to end a
# turn while the newest one is untagged, and a feedback or micromanagement tag
# needs a link to code work on this Juggernaut repository.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KPI="$ROOT/bin/jg-overwatch-kpi.sh"
GUARD="$ROOT/bin/jg-turnend-guard.sh"
TMP_ROOT=$(jg_test_tmproot jg-overwatch-kpi)
jg_git_identity fmtest fmtest@example.invalid

make_home() {  # <dir>
  mkdir -p "$1/bin" "$1/state" "$1/config"
  git init -q -b main "$1"
  git -C "$1" remote add origin https://github.com/acme/juggernaut.git
  : > "$1/AGENTS.md"
}

in_home() {  # <dir> <command...>
  local home=$1
  shift
  JG_ROOT_OVERRIDE="$home" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" "$@"
}

submit() {  # <dir> <prompt>
  jq -cn --arg p "$2" '{hook_event_name: "UserPromptSubmit", prompt_id: "p", prompt: $p}' \
    | in_home "$1" "$KPI" hook claude
}

stop() {  # <dir> -> the guard's exit status
  printf '{"session_id":"s"}' | in_home "$1" "$GUARD" >/dev/null 2>"$1/guard.err"
}

test_hook_records_only_typed_captain_messages() {
  local home="$TMP_ROOT/hook" off="$TMP_ROOT/hook-off"
  make_home "$home"
  submit "$home" "why is the export PR still not open?"
  submit "$home" "$(printf '\342\201\243JUGGERNAUT_OP: v1 watcher: signal: demo.status')"
  submit "$home" '<task-notification>rewake</task-notification>'
  assert_equals 1 "$(wc -l < "$home/data/overwatch-kpi.jsonl" | tr -d ' ')" \
    "the hook recorded fleet machinery as a captain message"
  assert_equals "1	why is the export PR still not open?" "$(in_home "$home" "$KPI" pending)" \
    "the typed message is not the pending one"
  make_home "$off"
  printf 'off\n' > "$off/config/overwatch-kpi"
  submit "$off" "scripted lab prompt"
  [ ! -e "$off/data/overwatch-kpi.jsonl" ] || fail "a home with the KPI off still recorded a prompt"
  pass "the hook records a typed captain message and drops fleet machinery and opted-out homes"
}

test_guard_refuses_an_untagged_message_once() {
  local home="$TMP_ROOT/guard" rc
  make_home "$home"
  stop "$home"; rc=$?
  assert_equals 0 "$rc" "a home with no captain message was blocked"
  submit "$home" "status?"
  stop "$home"; rc=$?
  assert_equals 2 "$rc" "an untagged captain message let the turn end"
  grep -q 'CAPTAIN MESSAGE NOT TAGGED' "$home/guard.err" || fail "the block did not name the rule: $(cat "$home/guard.err")"
  grep -q 'Message: status?' "$home/guard.err" || fail "the block did not quote the message"
  stop "$home"; rc=$?
  assert_equals 0 "$rc" "the same message was charged twice, which can wedge a harness"
  submit "$home" "file a ticket to add CSV export"
  stop "$home"; rc=$?
  assert_equals 2 "$rc" "a second untagged message was not flagged"
  in_home "$home" "$KPI" tag new-work >/dev/null || fail "tagging new work failed"
  in_home "$home" "$KPI" pending >/dev/null && fail "a tagged message is still pending"
  submit "$home" "yes, merge it"
  in_home "$home" "$KPI" tag decision-answer >/dev/null || fail "tagging a decision answer failed"
  stop "$home"; rc=$?
  assert_equals 0 "$rc" "a tagged message still blocked the turn end"
  pass "the guard refuses once per untagged captain message and clears once it is tagged"
}

test_a_miss_needs_a_link_to_code_work() {
  local home="$TMP_ROOT/link" rc link
  make_home "$home"
  submit "$home" "stop asking me to merge red PRs"
  in_home "$home" "$KPI" tag praise >/dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "an unknown kind was accepted"
  for link in '' data/learnings.md learnings.md https://github.com/acme/other/pull/4 \
    https://github.com/acme/juggernaut/pull/4abc; do
    in_home "$home" "$KPI" tag feedback "$link" >/dev/null 2>&1; rc=$?
    assert_equals 2 "$rc" "feedback linked to '$link' was accepted"
  done
  in_home "$home" "$KPI" pending >/dev/null || fail "a refused tag still cleared the message"
  in_home "$home" "$KPI" tag feedback https://github.com/acme/juggernaut/pull/41 >/dev/null \
    || fail "feedback linked to a PR on this repository was refused"
  in_home "$home" "$KPI" pending >/dev/null && fail "a linked miss is still pending"
  git -C "$home" remote add lab git@gitlab.example:team/tools/jug.git
  submit "$home" "is it done yet?"
  in_home "$home" "$KPI" tag micromanagement https://gitlab.example/team/tools/jug/-/merge_requests/7 >/dev/null \
    || fail "micromanagement linked to a merge request on an ssh remote was refused"
  assert_equals micromanagement "$(jq -rs 'map(select(.tag == 2)) | last | .kind' "$home/data/overwatch-kpi.jsonl")" \
    "the tag did not land on the newest message"
  pass "a miss is refused without a code link and accepted with a PR or MR on this repository"
}

test_hook_records_only_typed_captain_messages
test_guard_refuses_an_untagged_message_once
test_a_miss_needs_a_link_to_code_work
