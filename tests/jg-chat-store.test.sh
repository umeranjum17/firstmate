#!/usr/bin/env bash
# tests/jg-chat-store.test.sh - the fleet chat store keeps the captain's threads
# and the fleet's own events in the order they happened, and a captain's message
# moves sent -> read -> replied -> done along the agent path (bin/jg-chat.sh).
#
# The replay rows are real. tests/fixtures/chat-replay.tsv is ten steer and
# status records copied verbatim from this home's state/comms-feed.jsonl on
# 31 Oct 2026 (at, room, from, to, kind, recorded state, text), and
# tests/fixtures/chat-comments.tsv is the two comments the captain really filed:
# his Prometheus metric words on the tools-stack-six-report card, and his Luna
# review words recorded at data/pipeline-minimax-route/answer.md.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-chat-store)
CHAT="$ROOT/bin/jg-chat.sh"
FIX="$ROOT/tests/fixtures"

setup() { # <name> -> echoes the case dir
  local d=$TMP_ROOT/$1
  mkdir -p "$d/home/state" "$d/home/config" "$d/home/data"
  printf 'kind=ship\n' > "$d/home/state/w1.meta"
  printf 'kind=squad_lead\nhome=%s/home\n' "$d" > "$d/home/state/lead1.meta"
  printf '%s\n' "$d"
}

run() { # <case-dir> <command...>
  local d=$1
  shift
  env JG_HOME="$d/home" JG_ROOT_OVERRIDE="$ROOT" JG_STATE_OVERRIDE="$d/home/state" \
    JG_DATA_OVERRIDE="$d/home/data" "$@" 2>&1
}

store() { # <case-dir> [<jq-filter>] -> compact JSON
  run "$1" "$CHAT" log --json | jq -c -s "${2:-.}"
}

field() { # <case-dir> [<jq-filter>] -> the raw value, unquoted
  run "$1" "$CHAT" log --json | jq -r -s "${2:-.}"
}

test_a_replay_reads_in_the_recorded_order_with_its_threads_and_statuses() {
  local d rows=() i kind status out order expected at channel from to text
  d=$(setup replay)
  while IFS= read -r line; do rows+=("$line"); done < "$FIX/chat-replay.tsv"
  [ "${#rows[@]}" -eq 10 ] || fail "the replay fixture is not ten recorded messages"
  # Recorded last to first on purpose: the reader owns the order, not arrival.
  i=${#rows[@]}
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    IFS=$(printf '\t') read -r at channel from to kind status text <<< "${rows[$i]}"
    case "$kind" in
      steer) kind=agent ;;
      status) kind=status ;;
      *) fail "the replay carries an unexpected source kind: $kind" ;;
    esac
    # A steer's recorded state is what the agent's inbox really showed: unread
    # means the captain's message is still waiting, handled means it was read.
    case "$status" in
      unread) status=sent ;;
      handled) status='read' ;;
      -) status=- ;;
    esac
    JG_CHAT_AT=$at run "$d" "$CHAT" note "$channel" "$from" "$to" "$kind" "$status" "$text" ||
      fail "the store refused a recorded message: $line"
  done

  out=$(run "$d" "$CHAT" log --json) || fail "the reader failed: $out"
  assert_equals 10 "$(printf '%s' "$out" | jq -s 'length')" \
    "the store does not carry all ten recorded messages"
  order=$(printf '%s' "$out" | jq -r '.thread' | paste -sd, -)
  expected=$(cut -f2 "$FIX/chat-replay.tsv" | paste -sd, -)
  assert_equals "$expected" "$order" "the reader does not replay the rooms in recorded order"
  # The two unread steers are the ones the agents had not read yet, and no
  # status or wake row claims a reply is owed.
  assert_equals 2 "$(printf '%s' "$out" | jq -s '[.[] | select(.status == "sent")] | length')" \
    "an unread recorded steer is not waiting in the store"
  assert_equals 2 "$(printf '%s' "$out" | jq -s '[.[] | select(.status == "read")] | length')" \
    "a handled recorded steer is not marked read"
  assert_equals 6 "$(printf '%s' "$out" | jq -s '[.[] | select(.status == null)] | length')" \
    "a status line or fleet event claims a reply is owed"
  pass "ten recorded steers and status lines replay in order, in their rooms, with their own statuses"
}

test_a_captain_message_moves_sent_read_replied() {
  local d out seq
  d=$(setup captain)
  # No backend answers for task:w1 here, so the send fails - and the message is
  # recorded before delivery, exactly as a send record is, so it survives.
  out=$(JG_CHAT_AT=1793400000 run "$d" "$CHAT" send task:w1 "check the parser") &&
    fail "a send to an endpoint that cannot answer reported success"
  assert_contains "$out" 'recorded, but delivery to the agent failed' \
    "a failed delivery is not reported as recorded-but-undelivered"
  assert_equals sent "$(field "$d" '.[0].status')" "the captain's message is not waiting in the store"
  assert_equals "task:w1" "$(field "$d" '.[0].thread')" "a worker's message is not in its own room"
  # The KPI tag stays automatic: the message is the captain's intervention, so
  # the turn-end guard asks for its tag exactly as it does for a typed ask.
  seq=$(run "$d" "$ROOT/bin/jg-overwatch-kpi.sh" pending | cut -f1)
  assert_equals 1 "$seq" "the captain's chat message did not become an untagged intervention"

  out=$(run "$d" "$CHAT" read task:w1)
  assert_contains "$out" 'check the parser' "the agent's turn read nothing"
  assert_equals read "$(field "$d" '.[0].status')" "reading did not move the message to read"
  assert_contains "$(store "$d" '.[0].status_at')" '"read":' "reading was not stamped with its time"

  run "$d" "$CHAT" reply task:w1 "parser reproduced" >/dev/null
  assert_equals replied "$(field "$d" '.[0].status')" "the answer did not move the message to replied"
  assert_equals agent "$(field "$d" '.[1].kind')" "the answer is not a row of its own"
  assert_contains "$(store "$d" '.[0]')" '"reply_at":' "the reply is not attached to the message it answers"
  pass "a captain message is sent, read, and answered from the agent path"
}

test_the_two_real_captain_comments_carry_their_element_and_run_to_done() {
  local d at on link owner target text row
  d=$(setup comments)
  while IFS=$(printf '\t') read -r at on link owner target text; do
    # The board path records the response once and delivers nothing itself.
    JG_CHAT_AT=$at run "$d" "$CHAT" respond --on "$on" --link "$link" --owner "$owner" \
      "$target" "$text" >/dev/null || fail "the board path could not record the response on $on"
    row=$(store "$d" "[.[] | select(.on == \"$on\")] | first")
    assert_contains "$row" "\"text\":\"$text\"" "the captain's words on $on are not recorded verbatim"
    assert_contains "$row" "\"link\":\"$link\"" "the comment on $on lost the element's link"
    assert_contains "$row" "\"owner\":\"$owner\"" "the comment on $on lost the agent assigned to it"
    assert_equals sent "$(printf '%s' "$row" | jq -r '.status')" "the comment on $on does not start unread"
    assert_equals comment "$(printf '%s' "$row" | jq -r '.act')" "a plain comment is not recorded as one"
    assert_equals 1 "$(field "$d" "[.[] | select(.on == \"$on\")] | length")" \
      "the element $on produced more than one event"
    run "$d" "$CHAT" read task:"$target" >/dev/null
    run "$d" "$CHAT" mark working task:"$target" >/dev/null
    run "$d" "$CHAT" reply task:"$target" "on it" >/dev/null
    run "$d" "$CHAT" mark 'done' task:"$target" >/dev/null
    assert_equals 'done' "$(field "$d" "[.[] | select(.on == \"$on\")] | first | .status")" \
      "the comment on $on did not run sent -> read -> working -> replied -> done"
    # pending exits 1 when nothing is untagged: a board response is not counted
    # a second time as a fresh intervention.
    assert_equals 1 "$(run "$d" "$ROOT/bin/jg-overwatch-kpi.sh" pending >/dev/null 2>&1; echo $?)" \
      "a recorded board response was counted as a new captain intervention"
    assert_equals "sent,read,working,replied,done" \
      "$(field "$d" "[.[] | select(.on == \"$on\")] | first | .status_at | keys_unsorted | join(\",\")")" \
      "the comment on $on did not stamp every state it passed through"
  done < "$FIX/chat-comments.tsv"
  pass "both real captain comments carry their element, link and owner, and reach done"
}

test_each_response_kind_is_recorded_with_what_he_did_there() {
  local d act out
  d=$(setup acts)
  for act in approve refine reject answer; do
    run "$d" "$CHAT" respond --act "$act" --on "card-$act" main "his words" >/dev/null ||
      fail "the store refused an $act response"
    assert_equals "$act" "$(field "$d" "[.[] | select(.on == \"card-$act\")] | first | .act")" \
      "an $act response lost what the captain did"
  done
  out=$(run "$d" "$CHAT" respond --act invented --on card main "no") &&
    fail "an unknown response kind was accepted"
  assert_contains "$out" '--act takes comment, approve, refine, reject, or answer' \
    "an unknown response kind is not refused by name"
  out=$(run "$d" "$CHAT" respond --act approve main "no element") &&
    fail "a response kind without an element was accepted"
  assert_contains "$out" '--act needs --on' "a response kind without an element is not refused"
  pass "approve, refine, reject and answer each land as one event with what he did there"
}

test_the_page_reads_one_message_record_per_response() {
  local d out
  d=$(setup view)
  run "$d" "$CHAT" respond --act approve --on card-a --owner muxr --subject "Ship the chat backend" \
    muxr "yes, ship it" >/dev/null || fail "the store refused a response with a subject"
  run "$d" "$CHAT" respond --act comment --on card-b main "no subject on this one" >/dev/null
  out=$(run "$d" "$CHAT" log --view message)
  assert_equals 2 "$(printf '%s' "$out" | jq -s 'length')" "the message view is not one record per message"
  assert_equals approve "$(printf '%s' "$out" | jq -r -s '.[0].kind')" \
    "the message view does not name what the captain did as its kind"
  assert_equals "Ship the chat backend" "$(printf '%s' "$out" | jq -r -s '.[0].subject')" \
    "the message view lost the subject the response is about"
  assert_equals card-b "$(printf '%s' "$out" | jq -r -s '.[1].subject')" \
    "a response with no subject does not fall back to its element"
  assert_equals 0 "$(printf '%s' "$out" | jq -s '[.[] | select(.subject == null or .subject == "")] | length')" \
    "a message record left its subject blank"
  pass "the page reads one message record per response, with its kind and a subject that is never blank"
}

test_the_nudge_reports_an_unread_message_and_asks_the_lead_once() {
  local d out
  d=$(setup nudge)
  JG_CHAT_AT=1793400000 run "$d" "$CHAT" send task:w1 "read me" >/dev/null
  out=$(run "$d" "$CHAT" nudge --after 60)
  assert_contains "$out" 'unread ' "an unread message past the limit is not reported"
  assert_contains "$out" 'read me' "the nudge does not name the message"
  out=$(run "$d" "$CHAT" nudge --after 60 --send) &&
    fail "the nudge escalated without a lead endpoint to reach"
  assert_equals 1 "$(field "$d" 'length')" "the nudge changed the message it reports"
  pass "an unread captain message is reported past the limit and escalation is attempted once"
}

test_a_lead_speaks_in_its_own_room_not_a_worker_room() {
  local d
  d=$(setup rooms)
  run "$d" "$CHAT" note lead1 lead1 - wake - "stale: lead1" || fail "the store refused a lead event"
  run "$d" "$CHAT" note task:w1 w1 - status - "PR ready" || fail "the store refused a worker event"
  assert_equals lead1 "$(field "$d" '.[0].thread')" "a lead's event is not in the lead's own room"
  assert_equals "task:w1" "$(field "$d" '.[1].thread')" "a worker's event is not in the task room"
  assert_equals main "$(field "$d" '.[0].to')" "a fleet event is not addressed to this home's lead"
  pass "threads are the captain's: one per lead, one per worker task, plus #fleet"
}

test_a_delivered_steer_lands_on_the_fleet_thread_without_a_second_scan() {
  local d out
  d=$(setup steer)
  mkdir -p "$d/fakebin"
  # A tmux that accepts the doorbell and renders an empty composer.
  cat > "$d/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n' ;;
  capture-pane) printf '\342\225\255\342\224\200\342\224\200\342\225\256\n\342\224\202    \342\224\202\n\342\225\260\342\224\200\342\224\200\342\225\257\n' ;;
  list-windows) printf 'jg-w1\n' ;;
esac
exit 0
SH
  chmod +x "$d/fakebin/tmux"
  jg_write_meta "$d/home/state/w1.meta" "window=sess:jg-w1" kind=ship harness=claude
  out=$(PATH="$d/fakebin:$PATH" JG_SEND_SETTLE=0 run "$d" "$ROOT/bin/jg-send.sh" w1 "rebase on main") ||
    fail "the steer was not delivered: $out"
  out=$(run "$d" "$CHAT" log '#fleet' --json)
  assert_contains "$out" '"thread":"#fleet"' "a delivered steer did not land on the fleet thread"
  assert_contains "$out" '"from":"main"' "the fleet steer is not from this home's lead"
  assert_contains "$out" '"to":"w1"' "the fleet steer does not name the agent it reached"
  assert_contains "$out" '"text":"rebase on main"' "the fleet steer does not carry what was said"
  # The same call site rule for a wake that reaches the lead: written where the
  # wake queue row is written, not by a scan of it.
  run "$d" bash -c ". '$ROOT/bin/jg-wake-lib.sh'; jg_wake_append check w1 'check: PR ready'" ||
    fail "the wake could not be recorded"
  out=$(run "$d" "$CHAT" log '#fleet' --json)
  assert_contains "$out" '"kind":"wake"' "a wake that reached the lead is missing from the fleet thread"
  assert_contains "$out" '"from":"w1"' "the fleet wake does not name the task it concerns"
  pass "a delivered steer and a wake each write their own fleet row at the call site that recorded it"
}

test_a_replay_reads_in_the_recorded_order_with_its_threads_and_statuses
test_a_captain_message_moves_sent_read_replied
test_the_two_real_captain_comments_carry_their_element_and_run_to_done
test_each_response_kind_is_recorded_with_what_he_did_there() {
  local d act out
  d=$(setup acts)
  for act in approve refine reject answer; do
    run "$d" "$CHAT" respond --act "$act" --on "card-$act" main "his words" >/dev/null ||
      fail "the store refused an $act response"
    assert_equals "$act" "$(field "$d" "[.[] | select(.on == \"card-$act\")] | first | .act")" \
      "an $act response lost what the captain did"
  done
  out=$(run "$d" "$CHAT" respond --act invented --on card main "no") &&
    fail "an unknown response kind was accepted"
  assert_contains "$out" '--act takes comment, approve, refine, reject, or answer' \
    "an unknown response kind is not refused by name"
  out=$(run "$d" "$CHAT" respond --act approve main "no element") &&
    fail "a response kind without an element was accepted"
  assert_contains "$out" '--act needs --on' "a response kind without an element is not refused"
  pass "approve, refine, reject and answer each land as one event with what he did there"
}

test_the_page_reads_one_message_record_per_response() {
  local d out
  d=$(setup view)
  run "$d" "$CHAT" respond --act approve --on card-a --owner muxr --subject "Ship the chat backend" \
    muxr "yes, ship it" >/dev/null || fail "the store refused a response with a subject"
  run "$d" "$CHAT" respond --act comment --on card-b main "no subject on this one" >/dev/null
  out=$(run "$d" "$CHAT" log --view message)
  assert_equals 2 "$(printf '%s' "$out" | jq -s 'length')" "the message view is not one record per message"
  assert_equals approve "$(printf '%s' "$out" | jq -r -s '.[0].kind')" \
    "the message view does not name what the captain did as its kind"
  assert_equals "Ship the chat backend" "$(printf '%s' "$out" | jq -r -s '.[0].subject')" \
    "the message view lost the subject the response is about"
  assert_equals card-b "$(printf '%s' "$out" | jq -r -s '.[1].subject')" \
    "a response with no subject does not fall back to its element"
  assert_equals 0 "$(printf '%s' "$out" | jq -s '[.[] | select(.subject == null or .subject == "")] | length')" \
    "a message record left its subject blank"
  pass "the page reads one message record per response, with its kind and a subject that is never blank"
}

test_the_nudge_reports_an_unread_message_and_asks_the_lead_once
test_the_page_reads_one_message_record_per_response
test_each_response_kind_is_recorded_with_what_he_did_there
test_a_lead_speaks_in_its_own_room_not_a_worker_room
test_a_delivered_steer_lands_on_the_fleet_thread_without_a_second_scan
