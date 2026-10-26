#!/usr/bin/env bash
# jg-send from-juggernaut marker for squad_lead targets.
#
# A squad_lead is itself a juggernaut, so a request relayed to it lands in its own
# chat - which the main juggernaut never reads (the only channel back is the terse
# status file). jg-send therefore prepends a from-juggernaut marker
# (bin/jg-marker-lib.sh) when, and only when, the resolved target is a task
# selector whose meta records kind=squad_lead, so the squad_lead can recognize
# the request and route its reply via the status path. The marker now travels
# inside the durable inbox record's body (the payload is never typed; only the
# doorbell is). These tests pin that behavior hermetically (stubbed tmux, no
# real agent):
#   1. Exact-id and stable-label kind=squad_lead selectors prepend the marker
#      to the recorded steer, never to the typed doorbell.
#   2. Exact-id and stable-label ordinary operator selectors stay unmarked.
#   3. Explicit endpoints stay unmarked and typed, with or without local meta.
#   4. The --key path never carries the marker and never enqueues a record.
#   5. Direct captain text stays unmarked, and already-marked text is idempotent.
#   6. The marker is the label plus terminal-safe U+2063 INVISIBLE SEPARATOR.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/jg-marker-lib.sh"

SEND="$ROOT/bin/jg-send.sh"

TMP_ROOT=$(jg_test_tmproot jg-send-marker)

# A fake tmux that (a) records the literal text of every `send-keys -l` to
# JG_SEND_LOG and (b) lets jg-send's submit path reach a clean "empty" verdict.
# display-message yields a numeric cursor_y; capture-pane returns an empty
# bordered composer so jg_tmux_composer_state reads "empty" (submit landed) on the
# first Enter. Only the literal (-l) text is logged; Enter retries and --key sends
# are not, so the log holds exactly what was typed into the composer.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$JG_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <home> <send-log> -- <jg-send args...>
# Runs jg-send.sh with the stubs on PATH against the given home (which holds
# state/<id>.meta). JG_ROOT_OVERRIDE points at the same non-repo home so
# jg-guard's tangle check stays silent; guard noise goes to stderr (discarded).
# JG_SEND_SETTLE=0 keeps the run fast. Truncates the log first; returns jg-send's
# exit code.
run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    JG_ROOT_OVERRIDE="$home" JG_HOME="$home" JG_SEND_LOG="$log" JG_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

# setup_home <name> -> echoes a fresh home dir with an empty state/.
setup_home() {
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# The exact enqueued text of one inbox record, read through the production
# owner (bin/jg-task-inbox-lib.sh). Command substitution strips trailing
# newlines, so byte-exact trailing assertions read the raw record instead.
record_body() {  # <record-path>
  bash -c '. "$1"; jg_task_inbox_body "$2"' _ "$ROOT/bin/jg-task-inbox-lib.sh" "$1"
}

test_squad_lead_target_is_marked() {
  local dir fb log home rc got corr
  dir="$TMP_ROOT/sm"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm)
  jg_write_squad_lead_meta "$home/state/domain.meta" "$home" "sess:jg-domain"
  run_send "$fb" "$home" "$log" "jg-domain" "audit the build"; rc=$?
  expect_code 0 "$rc" "send to a squad_lead target should succeed"
  got=$(record_body "$home/state/domain.inbox/001.msg")
  case "$got" in
    "$JG_FROMFIRST_MARK"corr=[a-f0-9][a-f0-9]*) : ;;
    *) fail "squad_lead send: the recorded steer should be marker+corr+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  case "$got" in
    *audit\ the\ build) : ;;
    *) fail "squad_lead send lost the request body"$'\n'"$got" ;;
  esac
  case "$(cat "$log")" in
    *"$JG_FROMFIRST_MARK"*) fail "the marker must ride the record, never the typed doorbell" ;;
  esac
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-pending-reply-lib.sh"
  corr=$(jg_pending_reply_extract_corr "$got")
  [ -f "$(jg_pending_reply_path "$home/state" "$corr")" ] \
    || fail "marked squad_lead send should create a parent pending-reply record"
  pass "jg-send: a kind=squad_lead target gets the from-juggernaut marker and corr prepended"
}

test_exact_squad_lead_task_id_is_marked() {
  local dir fb log home rc got already_marked corr
  dir="$TMP_ROOT/sm-exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm-exact)
  jg_write_squad_lead_meta "$home/state/domain.meta" "$home" "sess:jg-domain"
  run_send "$fb" "$home" "$log" "domain" "audit the build"; rc=$?
  expect_code 0 "$rc" "send to an exact squad_lead task id should succeed"
  got=$(record_body "$home/state/domain.inbox/001.msg")
  case "$got" in
    "$JG_FROMFIRST_MARK"corr=[a-f0-9]*) : ;;
    *) fail "exact squad_lead send: the recorded steer should be marker+corr+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-pending-reply-lib.sh"
  corr=$(jg_pending_reply_extract_corr "$got")
  # Resend with the same corr already present: embed is idempotent for that corr.
  already_marked="${JG_FROMFIRST_MARK}corr=${corr} already routed"
  run_send "$fb" "$home" "$log" "domain" "$already_marked"; rc=$?
  expect_code 0 "$rc" "send of already-marked exact-id content should succeed"
  got=$(record_body "$home/state/domain.inbox/002.msg")
  case "$got" in
    "${JG_FROMFIRST_MARK}corr=${corr} already routed") : ;;
    *) fail "exact squad_lead send altered already-correlated content"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -tx1)" ;;
  esac
  pass "jg-send: an exact kind=squad_lead task id is marked with corr exactly once"
}

test_operator_target_is_not_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/crew"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home crew)
  jg_write_meta "$home/state/build.meta" \
    "window=sess:jg-build" "worktree=$home/wt" "project=$home/p" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
  run_send "$fb" "$home" "$log" "jg-build" "fix the test"; rc=$?
  expect_code 0 "$rc" "send to a stable-label operator target should succeed"
  got=$(record_body "$home/state/build.inbox/001.msg")
  [ "$got" = "fix the test" ] \
    || fail "stable-label operator send: expected bare recorded text, got marker or other"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  run_send "$fb" "$home" "$log" "build" "fix the exact test"; rc=$?
  expect_code 0 "$rc" "send to an exact-id operator target should succeed"
  got=$(record_body "$home/state/build.inbox/002.msg")
  [ "$got" = "fix the exact test" ] \
    || fail "exact-id operator send: expected bare recorded text, got marker or other"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  pass "jg-send: exact-id and stable-label kind=ship selectors are sent unmarked"
}

test_explicit_window_is_not_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home explicit)
  # An explicit endpoint is not a task selector, so even matching squad_lead
  # metadata must not make jg-send guess the caller's intent and mark it.
  jg_write_squad_lead_meta "$home/state/win.meta" "$home" "other:win"
  run_send "$fb" "$home" "$log" "other:win" "ping"; rc=$?
  expect_code 0 "$rc" "send to an explicit window with matching meta should succeed"
  got=$(cat "$log")
  [ "$got" = "ping" ] \
    || fail "explicit session:window send with meta: expected bare text, got marker"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"

  home=$(setup_home explicit-no-meta)
  run_send "$fb" "$home" "$log" "outside:window" "outside ping"; rc=$?
  expect_code 0 "$rc" "send to an explicit window with no local meta should succeed"
  got=$(cat "$log")
  [ "$got" = "outside ping" ] \
    || fail "explicit session:window send without meta: expected bare text, got marker"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  pass "jg-send: explicit endpoints stay unmarked with or without local metadata"
}

test_key_path_is_not_marked() {
  local dir fb log home rc
  dir="$TMP_ROOT/key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home key)
  jg_write_squad_lead_meta "$home/state/domain.meta" "$home" "sess:jg-domain"
  run_send "$fb" "$home" "$log" "jg-domain" --key Escape; rc=$?
  expect_code 0 "$rc" "--key send to a squad_lead should succeed"
  [ ! -s "$log" ] \
    || fail "--key path logged a literal send (marker leaked into a keypress)"$'\n'"--- bytes ---"$'\n'"$(od -An -c "$log")"
  [ ! -d "$home/state/domain.inbox" ] \
    || fail "--key path must never enqueue an inbox record"
  pass "jg-send: the --key path carries no marker (no literal text is typed)"
}

test_marker_is_label_plus_invisible_separator() {
  local separator hex
  separator=$(printf '\342\201\243')
  [ "$JG_FROMFIRST_MARK" = "[jg-from-juggernaut]$separator" ] \
    || fail "marker is not the expected label + U+2063 sequence"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$JG_FROMFIRST_MARK" | od -An -tx1)"
  hex=$(printf '%s' "$JG_FROMFIRST_MARK" | od -An -tx1 | tr -d ' \n')
  case "$hex" in
    *e281a3) : ;;
    *) fail "marker does not end in UTF-8 U+2063 bytes e2 81 a3; bytes were: $hex" ;;
  esac
  jg_message_from_juggernaut "${JG_FROMFIRST_MARK}do the work" \
    || fail "detector should recognize a marked message"
  jg_message_from_juggernaut "do the work" \
    && fail "direct captain input must remain unmarked"
  jg_message_from_juggernaut "[jg-from-juggernaut]do the work" \
    && fail "detector must reject the label without U+2063"
  pass "jg-send: the marker is '[jg-from-juggernaut]' + terminal-safe U+2063, while direct captain text stays unmarked"
}

test_marker_transformation_is_idempotent() {
  local once twice
  jg_message_mark_from_juggernaut "do the work" once
  jg_message_mark_from_juggernaut "$once" twice
  [ "$once" = "$twice" ] \
    || fail "already-marked content was double-prefixed"$'\n'"--- once ---"$'\n'"$(printf '%s' "$once" | od -An -tx1)"$'\n'"--- twice ---"$'\n'"$(printf '%s' "$twice" | od -An -tx1)"
  [ "$once" = "${JG_FROMFIRST_MARK}do the work" ] \
    || fail "marker transformation did not prefix bare content exactly once"
  pass "jg-marker: from-juggernaut transformation is idempotent"
}

test_marked_send_preserves_trailing_newlines() {
  local dir fb log home rc payload corr expected actual expected_message
  dir="$TMP_ROOT/sm-trailing-newlines"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm-trailing-newlines)
  jg_write_squad_lead_meta "$home/state/domain.meta" "$home" "sess:jg-domain"
  payload=$'audit the build\n\n'
  run_send "$fb" "$home" "$log" "domain" "$payload"; rc=$?
  expect_code 0 "$rc" "marked send with trailing newlines should succeed"
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-pending-reply-lib.sh"
  corr=$(jg_pending_reply_extract_corr "$(record_body "$home/state/domain.inbox/001.msg")")
  [ -n "$corr" ] || fail "marked send should embed a corr id"
  jg_pending_reply_embed_corr "$payload" "$corr" expected_message
  expected="$dir/expected.body"
  actual="$dir/actual.body"
  printf '%s' "$expected_message" > "$expected"
  record_body "$home/state/domain.inbox/001.msg" > "$actual"
  cmp -s "$expected" "$actual" \
    || fail "the marked record did not preserve trailing newline bytes exactly"
  pass "jg-send: marked squad_lead payload preserves trailing newline bytes in its record"
}

test_squad_lead_target_is_marked
test_exact_squad_lead_task_id_is_marked
test_operator_target_is_not_marked
test_explicit_window_is_not_marked
test_key_path_is_not_marked
test_marker_is_label_plus_invisible_separator
test_marker_transformation_is_idempotent
test_marked_send_preserves_trailing_newlines
