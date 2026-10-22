#!/usr/bin/env bash
# The sign-off adapter, driven through the process-event runner in a throwaway
# HOME with the process-event claim root redirected. Section A uses a stub
# sign-off-axi and a stub keyed-answer intake: a transient intake failure is
# offered again until the intake takes it, and a task held again after an
# answered card gets a live card of its own. Section B runs the real arm, hold
# and keyed-answer intake on a beads-backed home: a hold raises its card with the
# right title, reason and close, a dated deferral raises none, and the reserved
# reconcile answer is refused for good, acked once, and leaves the hold open.
set -u

# The Firstmate checkout owns tests/lib.sh; FM_CODE_ROOT names that checkout.
CODE_ROOT=${FM_CODE_ROOT:-}
[ -n "$CODE_ROOT" ] && [ -f "$CODE_ROOT/tests/lib.sh" ] \
  || { echo "skip: set FM_CODE_ROOT to a Firstmate checkout"; exit 0; }
ADAPTER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/fm-procevent-signoff.sh"
# shellcheck source=/dev/null
. "$CODE_ROOT/tests/lib.sh"

if ! command -v jq >/dev/null 2>&1; then echo "skip: jq not found"; exit 0; fi

TMP_ROOT=$(fm_test_tmproot fm-procevent-signoff)
export HOME="$TMP_ROOT/home" XDG_DATA_HOME="$TMP_ROOT/xdg-data" \
  XDG_CONFIG_HOME="$TMP_ROOT/xdg-config" TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$TMPDIR"

ROOTCOPY="$TMP_ROOT/root"
mkdir -p "$ROOTCOPY"
cp -R "$ROOT/bin" "$ROOTCOPY/bin"

FAKEBIN="$TMP_ROOT/fake-bin"
FM_HOME_DIR="$TMP_ROOT/fmhome"
mkdir -p "$FAKEBIN" "$FM_HOME_DIR/state"
export SIGNOFF_BOARD="$TMP_ROOT/board.json" HOLD_FILE="$TMP_ROOT/hold" \
  INTAKE_LOG="$TMP_ROOT/intake.log" INTAKE_RC="$TMP_ROOT/intake.rc"
printf '{}\n' > "$SIGNOFF_BOARD"
printf '0' > "$INTAKE_RC"

cat > "$FAKEBIN/sign-off-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) echo 'sign-off-axi stub' ;;
  raise)
    shift
    key='' title='' about='' close='' askref='' why='' yes='' no='' rec='' recwhy='' dflt=''
    while [ "$#" -gt 1 ]; do
      case "$1" in
        --key) key=$2 ;;
        --title) title=$2 ;;
        --about) about=$2 ;;
        --close) close=$2 ;;
        --ask-ref) askref=$2 ;;
        --why) why=$2 ;;
        --outcome) case "$2" in yes=*) yes=$2 ;; no=*) no=$2 ;; esac ;;
        --recommend) rec=$2 ;;
        --recommend-reason) recwhy=$2 ;;
        --default) dflt=$2 ;;
      esac
      shift 2
    done
    if [ -z "$askref" ]; then
      echo "VALIDATION_ERROR: a new Decide card needs a captain ask reference. Pass --ask-ref <captain-message-id-or-hold-id>"
      exit 1
    fi
    case "$title" in *\?) ;; *) echo 'VALIDATION_ERROR: --title must be a question ending in "?"'; exit 1 ;; esac
    [ "$(wc -w <<<"$title")" -le 12 ] || { echo 'VALIDATION_ERROR: Write one plain question, 12 words or fewer; put the rest in --why'; exit 1; }
    for need in why yes no rec recwhy dflt; do
      [ -n "${!need}" ] || { echo "VALIDATION_ERROR: key $key: --$need is required"; exit 1; }
    done
    if jq -e --arg k "$key" '.[$k].answer != null' "$SIGNOFF_BOARD" >/dev/null; then
      echo 'already answered'
      exit 0
    fi
    jq --arg k "$key" --arg t "$title" --arg a "$about" --arg c "$close" --arg r "$askref" \
      '.[$k] = {answer: null, label: "", close: $c, at: null, title: $t, about: $a, ask_ref: $r}' \
      "$SIGNOFF_BOARD" > "$SIGNOFF_BOARD.tmp" && mv "$SIGNOFF_BOARD.tmp" "$SIGNOFF_BOARD"
    echo raised
    ;;
  answers) jq -c 'with_entries(select(.value.answer != null))' "$SIGNOFF_BOARD" ;;
  wait) exit 0 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/sign-off-axi"

cat > "$ROOTCOPY/bin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  open) [ -f "$HOLD_FILE" ] || exit 1; cat "$HOLD_FILE" ;;
  answers) cat >> "$INTAKE_LOG"; exit "$(cat "$INTAKE_RC")" ;;
  binding) echo origin ;;
  bind) exit 0 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$ROOTCOPY/bin/fm-captain-hold.sh"

adapter() {
  PATH="$FAKEBIN:$PATH" FM_CODE_ROOT="$ROOTCOPY" FM_HOME="$FM_HOME_DIR" \
    FM_STATE_OVERRIDE="$FM_HOME_DIR/state" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" \
    "$ADAPTER" "$@"
}

runner() {
  PATH="$FAKEBIN:$PATH" FM_CODE_ROOT="$ROOTCOPY" FM_HOME="$FM_HOME_DIR" \
    FM_STATE_OVERRIDE="$FM_HOME_DIR/state" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" \
    "$ROOTCOPY/bin/fm-procevent.sh" "$@"
}

hold_as() { printf '%s\n' "$1" > "$HOLD_FILE"; }

answer_card() {  # <key> <answer> <at>
  jq --arg k "$1" --arg a "$2" --arg at "$3" '.[$k] += {answer: $a, label: "", close: "done", at: $at}' \
    "$SIGNOFF_BOARD" > "$SIGNOFF_BOARD.tmp" && mv "$SIGNOFF_BOARD.tmp" "$SIGNOFF_BOARD"
}

delivered() { cat "$FM_HOME_DIR/state/signoff-delivered" 2>/dev/null || true; }

runner register signoff signoff -- "$ADAPTER" poll >/dev/null 2>&1 \
  || fail "could not register the sign-off source for the runner"
hold_as '2026-10-12T10:00:00Z#0'
adapter raise T1 'Ship T1' 'needs a call' release >/dev/null 2>&1 || fail "first hold raised no card"
first=$(jq -r 'keys[0]' "$SIGNOFF_BOARD")
answer_card "$first" 'use the cheap plan' '2026-10-12T10:05:00Z'
rm -f "$HOLD_FILE"
hold_as '2026-10-12T11:00:00Z#0'
adapter raise T1 'Ship T1' 'needs a call again' release >/dev/null 2>&1 \
  || fail "a task held again after an answered card got no live card"
[ "$(jq 'keys | length' "$SIGNOFF_BOARD")" = 2 ] || fail "the re-hold did not add its own card"
second=$(jq -r --arg k "$first" 'keys[] | select(. != $k)' "$SIGNOFF_BOARD")
answer_card "$second" 'use the other plan' '2026-10-12T11:05:00Z'
out=$(adapter poll 2>/dev/null) || fail "poll found no answer for the re-held task"
[ "$(printf '%s\n' "$out" | jq -s 'length')" = 1 ] || fail "poll offered more than the new answer: $out"
[ "$(printf '%s\n' "$out" | jq -r .answer)" = 'use the other plan' ] \
  || fail "poll offered the earlier card's answer: $out"
jq -e 'to_entries | all(.value.ask_ref == "T1" and (.value.title == "Ship T1?"))' "$SIGNOFF_BOARD" >/dev/null \
  || fail "a raised card lacks the hold task id as its ask reference: $(cat "$SIGNOFF_BOARD")"
pass "a task held again after an answered card gets a live card of its own, each raised with the hold id as --ask-ref"

rm -f "$HOLD_FILE" "$SIGNOFF_BOARD" "$FM_HOME_DIR/state/signoff-delivered"
printf '{}\n' > "$SIGNOFF_BOARD"
long_title='Capture account planner for the TakeOne live proof run with the spare MiniMax key today'
long_reason='Let TakeOne use the MiniMax key for its live proof run, given that the planner needs a paid account and nobody has approved the spend yet?'
hold_as '2026-10-12T11:30:00Z#0'
adapter raise TQ "$long_title" "$long_reason" release >/dev/null 2>&1 || fail "a long reason and long title raised no card"
hold_as '2026-10-12T11:40:00Z#0'
adapter raise TQ "$long_title" 'Let TakeOne use the MiniMax key for its live proof?' release >/dev/null 2>&1 \
  || fail "a re-hold with a short question raised no card"
jq -e --arg r "$long_reason" '[.[]] as $c | ($c | length) == 2
  and ($c | map(select(.title == "Capture account planner for the TakeOne live proof run with the spare?")) | length) == 1
  and ($c | map(select(.title == "Let TakeOne use the MiniMax key for its live proof?")) | length) == 1
  and ($c | map(select(.about == $r)) | length) == 1' "$SIGNOFF_BOARD" >/dev/null \
  || fail "the card question did not follow the 12-word rule: $(cat "$SIGNOFF_BOARD")"
pass "the card question is the hold reason when it is one short question, else the title cut to 12 words; a re-hold uses its new reason"

rm -f "$HOLD_FILE" "$SIGNOFF_BOARD" "$FM_HOME_DIR/state/signoff-delivered"
printf '{}\n' > "$SIGNOFF_BOARD"
hold_as '2026-10-12T12:00:00Z#0'
adapter raise T2 'Ship T2' 'needs a call' "done" >/dev/null 2>&1 || fail "hold T2 raised no card"
key=$(jq -r 'keys[0]' "$SIGNOFF_BOARD")
answer_card "$key" 'ship it' '2026-10-12T12:05:00Z'

printf '1' > "$INTAKE_RC"
out=$(runner start signoff 2>&1) || true
[ -z "$(delivered)" ] || fail "an answer the intake failed on was marked delivered"
case "$out" in *"answers-fed: signoff"*) fail "a failed intake was reported as fed" ;; esac
printf '0' > "$INTAKE_RC"
out=$(runner start signoff 2>&1) || true
case "$out" in *"answers-fed: signoff"*) : ;; *) fail "the answer was not offered again and fed: $out" ;; esac
delivered | grep -qF "T2" || fail "an accepted answer was not acknowledged"
pass "an answer the intake fails on is offered again through the runner until the intake takes it"

hold_as '2026-10-12T13:00:00Z#0'
adapter raise T3 'Ship T3' 'needs a call' "done" >/dev/null 2>&1 || fail "hold T3 raised no card"
key3=$(jq -r --arg k "$key" 'keys[] | select(. != $k)' "$SIGNOFF_BOARD")
answer_card "$key3" 'not for the captain' '2026-10-12T13:05:00Z'
printf '3' > "$INTAKE_RC"
: > "$INTAKE_LOG"
out=$(runner start signoff 2>&1) || true
case "$out" in *"answers-fed: signoff"*) : ;; *) fail "a permanently skipped answer was not acknowledged: $out" ;; esac
delivered | grep -qF "T3" || fail "a permanently skipped answer was not recorded as delivered"
[ -z "$(adapter poll 2>/dev/null)" ] || fail "a permanently skipped answer was offered again"
printf '0' > "$INTAKE_RC"
pass "a batch whose every skip is permanent is acknowledged and not offered again"

TASKS_AXI_BIN=$(command -v tasks-axi 2>/dev/null || :)

# Own minimal beads fixture: the upstream copy lives inside a test body, not in a
# sourceable helper, so no upstream function is shared here. Keep this small.
beads_probe() {
  local base="$TMP_ROOT/beads-probe"
  mkdir -p "$base/home" && git init -q "$base/graph" || return 1
  (cd "$base/graph" && bd init) >/dev/null 2>&1 || return 1
  printf 'backend = "beads"\n[beads]\npath = "%s/graph/.beads"\nbinary = "bd"\nprefix = "fm"\n' "$base" > "$base/home/fixture/users/user-008"
  (cd "$base/home" && tasks-axi list) >/dev/null 2>&1
}

if [ -z "$TASKS_AXI_BIN" ] || ! command -v bd >/dev/null 2>&1 || ! beads_probe; then
  pass "skipped the real-hold section: no beads-capable tasks-axi and bd on this machine"
  echo "all fm-procevent-signoff tests passed"
  exit 0
fi

make_beads_home() {  # <name>; prints the fixture home
  local base="$TMP_ROOT/$1" home graph
  home="$base/home"
  graph="$base/fm"
  mkdir -p "$home/data" "$home/config" "$home/projects" "$home/state" "$graph"
  git init -q "$graph"
  (cd "$graph" && bd init) >"$base.init.log" 2>&1 || fail "fixture bd init failed for $1"
  printf 'backend = "beads"\n[beads]\npath = "%s/.beads"\nbinary = "bd"\nprefix = "fm"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' "$graph" > "$home/.tasks.toml"
  printf "%s\n" "$home"
}

real_env() {  # <home> <command args...>; the real adapter, hold, runner and intake
  local home=$1
  shift
  PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_CODE_ROOT="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROCEVENT_CLAIM_ROOT="$home/claims" "$@"
}

fm_fake_exit0 "$FAKEBIN" tmux treehouse no-mistakes gh gh-axi
real_home=$(make_beads_home real)
SIGNOFF_BOARD="$real_home/board.json"
export SIGNOFF_BOARD
printf '{}\n' > "$SIGNOFF_BOARD"
(cd "$real_home" && BEADS_ACTOR=fixture tasks-axi add fm-sample-work "Gated work") >/dev/null 2>&1 \
  || fail "could not create the existing work item"
real_env "$real_home" "$ADAPTER" arm >/dev/null \
  || fail "the real sign-off adapter did not arm"

board_count() { jq 'length' "$SIGNOFF_BOARD"; }
card_for() { jq -r --arg t "$1" 'to_entries[] | select(.value.title == $t) | .key' "$SIGNOFF_BOARD"; }

real_env "$real_home" "$ROOT/bin/fm-captain-hold.sh" hold fm-sample-q \
  --title "Pick the route" --reason "Which route?" >/dev/null \
  || fail "the captain question was not held"
real_env "$real_home" "$ROOT/bin/fm-captain-hold.sh" hold fm-sample-work \
  --title "Gated work" --reason "captain approves the work" >/dev/null \
  || fail "the existing work item was not held"
before=$(board_count)
real_env "$real_home" "$ROOT/bin/fm-captain-hold.sh" hold fm-sample-later \
  --title "Deferred call" --reason "revisit later" --until 2026-12-01 >/dev/null \
  || fail "the dated deferral was not held"
[ "$(board_count)" = "$before" ] || fail "a dated deferral raised a card: $(cat "$SIGNOFF_BOARD")"

q=$(card_for "Which route?")
[ -n "$q" ] || fail "the held question raised no card: $(cat "$SIGNOFF_BOARD")"
jq -e --arg k "$q" '.[$k] | .about == "Which route?" and .close == "done"' "$SIGNOFF_BOARD" >/dev/null \
  || fail "the question card lost its reason or close: $(cat "$SIGNOFF_BOARD")"
w=$(card_for "Gated work?")
[ -n "$w" ] || fail "the held existing work item raised no card: $(cat "$SIGNOFF_BOARD")"
jq -e --arg k "$w" '.[$k] | .about == "captain approves the work" and .close == "release"' "$SIGNOFF_BOARD" >/dev/null \
  || fail "the work card lost its reason or close: $(cat "$SIGNOFF_BOARD")"
pass "a new question raises a done card and an existing work item a release card, each with its title and reason; a dated deferral raises none"

jq --arg k "$q" '.[$k] += {answer: "reconcile", label: "", close: "done", at: "2026-10-12T23:00:00Z"}' \
  "$SIGNOFF_BOARD" > "$SIGNOFF_BOARD.tmp" && mv "$SIGNOFF_BOARD.tmp" "$SIGNOFF_BOARD"
out=$(real_env "$real_home" "$ROOT/bin/fm-procevent.sh" start signoff 2>&1) || true
case "$out" in *"answers-fed: signoff"*) : ;; *) fail "a permanently refused answer was not acknowledged: $out" ;; esac
[ "$(grep -c 'refused: fm-sample-q' <<<"$out")" = 1 ] || fail "the refusal was not reported exactly once: $out"
show=$(cd "$real_home" && BEADS_ACTOR=fixture tasks-axi show fm-sample-q --full 2>&1)
case "$show" in *"held: yes"*) : ;; *) fail "a refused reconcile answer released the hold: $show" ;; esac
grep -qF 'fm-sample-q' "$real_home/state/signoff-delivered" || fail "the refused answer was not recorded as delivered"
[ -z "$(real_env "$real_home" "$ADAPTER" poll 2>/dev/null)" ] \
  || fail "the refused answer was offered again"
pass "a permanently refused reserved answer is acked once, reported once, and leaves its hold open"

echo "all fm-procevent-signoff tests passed"
