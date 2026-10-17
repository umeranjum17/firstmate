#!/usr/bin/env bash
# Behavior tests for bearings-board/bin/fm-bearings-board.sh run against a
# throwaway Firstmate home: fail-closed payload validation, template injection
# round-trip, bind-before-arm, the reopen path for a session the captain ended,
# landed-card hygiene, the reconcile choice, and the rendered milestone fields.
# The home's lifecycle helpers and lavish-axi are stubs, so nothing real starts.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/board-render-harness.mjs"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/bearings-board-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

# Stub helpers the board drives from its home's bin/. Each one records what it
# was asked in order.log, so a test can prove bind came before arm.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/bin" "$home/fakebin" "$home/lavish" "$home/state"
  cat > "$home/bin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
# A task in closed/ is no longer an open captain call; `bind` is recorded.
home=$(cd "$(dirname "$0")/.." && pwd)
case "${1-}" in
  open) [ -e "$home/closed/$2" ] && exit 1; exit 0 ;;
  bind) printf 'bind %s\n' "$2" >> "$home/order.log" ;;
  *) exit 2 ;;
esac
SH
  cat > "$home/bin/fm-procevent-lavish.sh" <<'SH'
#!/usr/bin/env bash
# The board's source is live once armed; retire drops the old generation.
home=$(cd "$(dirname "$0")/.." && pwd)
case "${1-}" in
  source-id) printf 'bearings-board\n' ;;
  arm) printf 'arm\n' >> "$home/order.log"; : > "$home/owner" ;;
  retire) printf 'retire\n' >> "$home/order.log"; rm -f "$home/owner" ;;
  *) exit 2 ;;
esac
SH
  cat > "$home/bin/fm-procevent.sh" <<'SH'
#!/usr/bin/env bash
# `list` prints the registered source with its owner; `reconcile` starts one.
home=$(cd "$(dirname "$0")/.." && pwd)
case "${1-}" in
  list)
    printf 'SOURCE KIND OWNER\n'
    [ ! -e "$home/owner" ] || printf 'bearings-board board live\n'
    ;;
  reconcile) printf 'reconcile\n' >> "$home/order.log"; : > "$home/owner" ;;
  *) exit 2 ;;
esac
SH
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Shapes as lavish-axi reports them: opening a session the captain ended exits 0
# with status user-ended and leaves it unlisted. --reopen restores it unless the
# refuse-reopen marker is set.
state=${LAVISH_STATE:?}
case "${1-}" in
  --version) printf '0.1.61\n'; exit 0 ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    if [ -s "$state/open" ]; then
      while IFS= read -r listed; do
        [ -n "$listed" ] || continue
        printf '  %s,open,"http://127.0.0.1:4387/session/0123456789abcdef",0\n' "$listed"
      done < "$state/open"
    fi
    exit 0 ;;
esac
file=$1 reopen=0
for arg in "$@"; do [ "$arg" != --reopen ] || reopen=1; done
real=$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")
if [ -e "$state/user-ended" ] && { [ "$reopen" = 0 ] || [ -e "$state/refuse-reopen" ]; }; then
  printf 'session:\n  file: %s\n  status: user-ended\n' "$real"
  exit 0
fi
rm -f "$state/user-ended"
printf '%s\n' "$real" > "$state/open"
printf 'session:\n  file: %s\n  status: %s\n' "$real" "$([ "$reopen" = 1 ] && echo reopened || echo opened)"
SH
  chmod +x "$home"/bin/*.sh "$home/fakebin/lavish-axi"
  printf '%s\n' "$home"
}

# Run the board against <home> with its stubs first on PATH.
run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" LAVISH_STATE="$home/lavish" "$BOARD" "$@"
}

captain_ends_session() {  # <home>
  : > "$1/lavish/user-ended"
  rm -f "$1/lavish/open"
}

board_of() { printf '%s/.lavish/bearings-board.html\n' "$1"; }

# The payload the board receives: a decision card, a merge card, one row of each
# kind, a project strip entry with milestones, and a string that tries to end
# the data block early.
valid_payload() {  # <home>
  local data="$1/payload.json"
  cat > "$data" <<'JSON'
{
  "schema": "fm-bearings-board.v1",
  "home": "sample-home",
  "generated": "2026-10-17T09:00:00Z",
  "prs_live": false,
  "projects": [{"repo": "sample", "release_goal": "Ship the board", "release_date": "2026-10-30",
    "health": "G", "merges_today": 2, "wip_count": 3, "board_url": "https://board.example.test/sample"}],
  "captains_call": [
    {"key": "decide-rollout", "type": "decision", "repo": "sample", "title": "Roll out the board?",
     "about": "a string that tries </script> to end the data block",
     "options": [{"value": "yes", "label": "Yes"}, {"value": "no", "label": "No"}],
     "default_if_silent": "no", "decide_by": "2026-10-20", "asked_at": "2026-10-17",
     "reversible": true, "evidence_url": "evidence/rollout.png"},
    {"key": "merge-board", "type": "merge", "repo": "sample", "title": "Merge the board PR",
     "options": [{"value": "merge", "label": "Merge"}], "risk": "low"}
  ],
  "underway": [{"id": "task-1", "repo": "sample", "name": "Board milestones", "state": "working",
    "doing": "wiring the add-on", "kind": "coding", "target": "Oct 30", "range": "Oct 17-30",
    "age": "2d", "health": "Y", "evidence_url": "https://evidence.example.test/shot.png"}],
  "landed": [{"id": "task-0", "repo": "sample", "what": "Shipped the strip", "owner": "lead",
    "pr_url": "https://github.com/example/sample/pull/1"}],
  "charted": [{"id": "next-1", "repo": "sample", "title": "Next item", "reason": "queued",
    "dispatchable": true, "filed": "2026-10-16"}]
}
JSON
  printf '%s\n' "$data"
}

# The payload as the built page carries it, pulled out the way the board's own
# round-trip check reads it.
extract_payload() {  # <board>
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$1" | sed '1d;$d'
}

test_path_is_home_scoped_and_needs_fm_home() {
  local home
  home=$(make_home path)
  [ "$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$BOARD" path)" = "$(board_of "$home")" ] \
    || fail "the board path is not the stable home-scoped location"
  if env -u FM_HOME "$BOARD" path >/dev/null 2>&1; then
    fail "the board ran without FM_HOME"
  fi
  if FM_HOME="$TMP_ROOT/no-such-home" "$BOARD" path >/dev/null 2>&1; then
    fail "the board ran against a directory with no Firstmate helpers"
  fi
  pass "path is home-scoped and refuses to run without a Firstmate home"
}

test_malformed_payloads_are_refused_and_the_board_is_left_alone() {
  local home data board before mutation
  home=$(make_home malformed)
  data=$(valid_payload "$home")
  run_board "$home" build "$data" >/dev/null 2>&1 || fail "the valid payload did not build"
  board=$(board_of "$home")
  before=$(cksum < "$board")

  printf 'not json' > "$home/bad.json"
  run_board "$home" build "$home/bad.json" >/dev/null 2>&1 && fail "a non-JSON payload was accepted"
  for mutation in \
    '.schema = "other.v0"' \
    '.captains_call[0].key = ("k" * 129)' \
    '.captains_call[0].options[0].value = "not a slug"' \
    '.captains_call[0].options += [{"value": "reconcile", "label": "Reconcile"}]' \
    '.captains_call[0].default_if_silent = "maybe"' \
    '.captains_call[0].reversible = "yes"' \
    '.captains_call[0].evidence_url = "../escape.png"' \
    '.underway[0] |= del(.name)' \
    '.underway[0] |= del(.repo)' \
    '.landed[0].pr_url = "http://example.test/pull/1"' \
    '.charted[0].filed = "2026-13-40"' \
    '.projects[0].health = "Z"' \
    '.charted[0].dispatchable = "yes"'
  do
    jq "$mutation" "$data" > "$home/bad.json" || fail "the mutation did not apply: $mutation"
    if run_board "$home" build "$home/bad.json" >/dev/null 2>&1; then
      fail "a payload with $mutation was accepted"
    fi
    [ "$(cksum < "$board")" = "$before" ] || fail "a refused payload changed the board: $mutation"
  done
  pass "malformed payloads are refused and the built board is left as it was"
}

test_build_injects_the_payload_binds_then_arms() {
  local home data board out payload
  home=$(make_home inject)
  data=$(valid_payload "$home")
  out=$(run_board "$home" build "$data") || fail "a valid payload did not build: $out"
  board=$(board_of "$home")
  payload=$(extract_payload "$board")
  printf '%s' "$payload" | jq -e '.schema == "fm-bearings-board.v1"' >/dev/null \
    || fail "the built board does not carry a readable payload"
  grep -q '</script>' <(printf '%s' "$payload") && fail "the payload closed its data block early"
  printf '%s\n' "$out" | grep -qx 'bound: bearings-board' || fail "the build did not report its binding"
  printf '%s\n' "$out" | grep -qx 'armed: bearings-board' || fail "the build did not report arming"
  [ "$(cat "$home/order.log")" = "$(printf 'bind bearings-board\narm')" ] \
    || fail "the source was not bound before it was armed: $(cat "$home/order.log")"
  pass "build injects the payload, binds the source, then arms it"
}

test_every_decision_card_carries_reconcile_once_and_no_other_card_does() {
  local home data payload
  home=$(make_home reconcile)
  data=$(valid_payload "$home")
  run_board "$home" build "$data" >/dev/null || fail "the build failed"
  payload=$(extract_payload "$(board_of "$home")")
  printf '%s' "$payload" | jq -e '
    ([.captains_call[] | select(.type == "decision") | [.options[].value] | index("reconcile")] | all(. != null))
    and ([.captains_call[] | select(.type == "merge") | [.options[].value] | index("reconcile")] == [null])
  ' >/dev/null || fail "reconcile was not injected exactly where it belongs"
  pass "every decision card carries the reconcile choice, and no other card does"
}

test_a_decision_whose_subject_already_landed_is_dropped() {
  local home data err payload
  home=$(make_home landed)
  data=$(valid_payload "$home")
  jq '.landed += [{"id": "decide-rollout", "repo": "sample", "what": "Rolled out", "owner": "lead"}]' \
    "$data" > "$home/landed.json"
  err=$(run_board "$home" build "$home/landed.json" 2>&1 >/dev/null) || fail "the build failed: $err"
  printf '%s\n' "$err" | grep -q '^dropped-landed-card: decide-rollout ' \
    || fail "the dropped card was not named on stderr: $err"
  payload=$(extract_payload "$(board_of "$home")")
  printf '%s' "$payload" | jq -e '[.captains_call[].key] | index("decide-rollout") == null' >/dev/null \
    || fail "a card whose subject already landed was still shown"
  pass "a decision whose subject already landed is dropped and named"
}

test_a_decision_no_longer_open_is_dropped_and_an_open_one_stays() {
  local home data err payload
  home=$(make_home closed)
  data=$(valid_payload "$home")
  mkdir -p "$home/closed"
  : > "$home/closed/decide-rollout"
  err=$(run_board "$home" build "$data" 2>&1 >/dev/null) || fail "the build failed: $err"
  printf '%s\n' "$err" | grep -q '^dropped-landed-card: decide-rollout ' \
    || fail "a card that is no longer an open call was not dropped"
  payload=$(extract_payload "$(board_of "$home")")
  printf '%s' "$payload" | jq -e '[.captains_call[].key] == ["merge-board"]' >/dev/null \
    || fail "the card that is still an open call was dropped, or the wrong one was"
  pass "a decision that is no longer an open call is dropped, and an open one stays"
}

test_a_session_the_captain_ended_is_reopened_before_arming() {
  local home data out
  home=$(make_home reopen)
  data=$(valid_payload "$home")
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"
  captain_ends_session "$home"
  : > "$home/order.log"
  out=$(run_board "$home" build "$data") || fail "the rebuild refused a recoverable ended session: $out"
  printf '%s\n' "$out" | grep -qx 'session: reopened' || fail "the rebuild did not reopen the session"
  [ "$(cat "$home/order.log")" = "$(printf 'retire\nbind bearings-board\narm')" ] \
    || fail "the reopened session was not retired and re-armed in order: $(cat "$home/order.log")"
  pass "a session the captain ended is reopened, its old source retired, and a fresh source armed"
}

test_build_refuses_to_arm_when_the_session_stays_ended() {
  local home data out
  home=$(make_home stays-ended)
  data=$(valid_payload "$home")
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"
  captain_ends_session "$home"
  : > "$home/lavish/refuse-reopen"
  : > "$home/order.log"
  out=$(run_board "$home" build "$data" 2>&1) && fail "the build armed a poll on an ended session: $out"
  [ ! -s "$home/order.log" ] || fail "the build bound or armed a session that stayed ended: $(cat "$home/order.log")"
  pass "build refuses to arm a poll on a session that stays ended"
}

test_rebuild_refreshes_in_place_without_arming_twice() {
  local home data board out
  home=$(make_home rebuild)
  data=$(valid_payload "$home")
  board=$(board_of "$home")
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"
  out=$(run_board "$home" build "$data") || fail "the rebuild failed: $out"
  printf '%s\n' "$out" | grep -qx 'already-armed: bearings-board' \
    || fail "the rebuild did not report the existing registration"
  [ "$(grep -c '^arm$' "$home/order.log")" = 1 ] || fail "the rebuild armed the source again"
  [ "$(grep -c '^board:' <<< "$out")" = 1 ] || fail "the rebuild did not name its board"
  [ -s "$board" ] || fail "the rebuild left no board"
  pass "a rebuild refreshes the board in place and does not arm the source twice"
}

test_a_template_without_exactly_one_data_slot_is_refused() {
  local home data
  home=$(make_home no-slot)
  data=$(valid_payload "$home")
  printf '<html>no slot here</html>\n' > "$home/no-slot.html"
  if FM_BEARINGS_BOARD_TEMPLATE="$home/no-slot.html" run_board "$home" build "$data" >/dev/null 2>&1; then
    fail "a template with no data slot was accepted"
  fi
  [ ! -e "$(board_of "$home")" ] || fail "a template with no data slot still wrote a board"
  pass "build refuses a template without exactly one data slot"
}

# Render the built board under the DOM shim and check what it shows: the
# milestone fields on the strip and the cards, and the image thumbnail.
test_milestone_fields_render_on_the_strip_and_the_cards() {
  local home data out
  home=$(make_home render)
  data=$(valid_payload "$home")
  run_board "$home" build "$data" >/dev/null || fail "the build failed"
  out=$(node "$HARNESS" "$(board_of "$home")") || fail "the built board could not be rendered"
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null || fail "the board rendered its error state: $out"
  printf '%s' "$out" | jq -e '
    .projects[0].goal == "Ship the board"
    and .projects[0].date == "release 2026-10-30"
    and .projects[0].board[0].href == "https://board.example.test/sample"
    and (.underway[0].badges | map(.text) | index("at risk") != null)
    and .underway[0].thumbs[0].src == "https://evidence.example.test/shot.png"
    and .calls[0].thumbs[0].src == "evidence/rollout.png"
  ' >/dev/null || fail "the milestone fields or image evidence did not render: $out"
  pass "milestone fields render on the strip and the cards, and image evidence shows"
}

# A repo that arrives as a path renders as its last segment everywhere a repo
# name is shown, so no home path reaches the captain; a plain name is untouched.
test_a_repo_given_as_a_home_path_shows_only_its_last_segment() {
  local home data out
  home=$(make_home repo-label)
  data=$(valid_payload "$home")
  jq '.projects[0].repo = "/home/you/sample/"
    | .captains_call[0].repo = "/homes/you/sample"
    | .underway[0] |= del(.age)
    | .underway[0].repo = "/home/you/sample"
    | .landed[0].repo = "/home/you/sample"
    | .charted[0].repo = "/home/you/sample"' "$data" > "$home/paths.json"
  run_board "$home" build "$home/paths.json" >/dev/null || fail "the build failed"
  out=$(node "$HARNESS" "$(board_of "$home")") || fail "the built board could not be rendered"
  printf '%s' "$out" | jq -e '
    .projects[0].repo == "sample"
    and .calls[0].repo == "sample"
    and (.underway[0].sub | endswith(" · sample"))
    and .landed[0].sub == "sample · lead"
    and .charted[0].sub == "queued · sample"
  ' >/dev/null || fail "a repo given as a home path was not reduced to its last segment: $out"
  pass "a repo given as a home path shows only its last segment"
}

test_path_is_home_scoped_and_needs_fm_home
test_malformed_payloads_are_refused_and_the_board_is_left_alone
test_build_injects_the_payload_binds_then_arms
test_every_decision_card_carries_reconcile_once_and_no_other_card_does
test_a_decision_whose_subject_already_landed_is_dropped
test_a_decision_no_longer_open_is_dropped_and_an_open_one_stays
test_a_session_the_captain_ended_is_reopened_before_arming
test_build_refuses_to_arm_when_the_session_stays_ended
test_rebuild_refreshes_in_place_without_arming_twice
test_a_template_without_exactly_one_data_slot_is_refused
test_milestone_fields_render_on_the_strip_and_the_cards
test_a_repo_given_as_a_home_path_shows_only_its_last_segment
