#!/usr/bin/env bash
# The sign-off adapter's behavior against a stub sign-off-axi and a stub
# keyed-answer intake, in a throwaway HOME with the process-event claim root
# redirected: a task held again after an answered card gets a live card of its
# own, and an answer the intake refuses is offered again on the next round.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-procevent-signoff)
export HOME="$TMP_ROOT/home" XDG_DATA_HOME="$TMP_ROOT/xdg-data" \
  XDG_CONFIG_HOME="$TMP_ROOT/xdg-config" TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$TMPDIR"

ROOTCOPY="$TMP_ROOT/root"
mkdir -p "$ROOTCOPY"
cp -R "$ROOT/bin" "$ROOTCOPY/bin"

FAKEBIN="$TMP_ROOT/fakebin"
FM_HOME_DIR="$TMP_ROOT/fmhome"
mkdir -p "$FAKEBIN" "$FM_HOME_DIR/state/procevent"
: > "$FM_HOME_DIR/state/procevent/signoff.source"
export SIGNOFF_BOARD="$TMP_ROOT/board.json" HOLD_FILE="$TMP_ROOT/hold" \
  INTAKE_LOG="$TMP_ROOT/intake.log" INTAKE_RC="$TMP_ROOT/intake.rc"
printf '{}\n' > "$SIGNOFF_BOARD"
printf '0' > "$INTAKE_RC"

cat > "$FAKEBIN/sign-off-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) echo 'sign-off-axi stub' ;;
  raise)
    key=$3
    if jq -e --arg k "$key" '.[$k].answer != null' "$SIGNOFF_BOARD" >/dev/null; then
      echo 'already answered'
      exit 0
    fi
    jq --arg k "$key" '.[$k] = {answer: null, label: "", close: "", at: null}' "$SIGNOFF_BOARD" \
      > "$SIGNOFF_BOARD.tmp" && mv "$SIGNOFF_BOARD.tmp" "$SIGNOFF_BOARD"
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
  bind) exit 0 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$ROOTCOPY/bin/fm-captain-hold.sh"

adapter() {
  PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOTCOPY" FM_HOME="$FM_HOME_DIR" \
    FM_STATE_OVERRIDE="$FM_HOME_DIR/state" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" \
    "$ROOTCOPY/bin/fm-procevent-signoff.sh" "$@"
}

hold_as() { printf '%s\n' "$1" > "$HOLD_FILE"; }

answer_card() {  # <key> <answer> <at>
  jq --arg k "$1" --arg a "$2" --arg at "$3" '.[$k] = {answer: $a, label: "", close: "done", at: $at}' \
    "$SIGNOFF_BOARD" > "$SIGNOFF_BOARD.tmp" && mv "$SIGNOFF_BOARD.tmp" "$SIGNOFF_BOARD"
}

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
pass "a task held again after an answered card gets a live card of its own"

cap="$TMP_ROOT/capture"
deliver_round() {  # <intake-rc>; the runner's feed: answers into the intake, then ack only on exit 0
  printf '%s' "$1" > "$INTAKE_RC"
  adapter poll > "$cap" 2>/dev/null || return 75
  adapter answers "$cap" | "$ROOTCOPY/bin/fm-captain-hold.sh" answers origin --source test >/dev/null 2>&1 \
    && adapter ack "$cap"
}

rm -f "$HOLD_FILE" "$SIGNOFF_BOARD"
printf '{}\n' > "$SIGNOFF_BOARD"
hold_as '2026-10-12T12:00:00Z#0'
adapter raise T2 'Ship T2' 'needs a call' done >/dev/null 2>&1 || fail "hold T2 raised no card"
key=$(jq -r 'keys[0]' "$SIGNOFF_BOARD")
answer_card "$key" 'ship it' '2026-10-12T12:05:00Z'

deliver_round 1 || true
[ ! -s "$FM_HOME_DIR/state/signoff-delivered" ] || fail "an answer the intake refused was marked delivered"
adapter poll > "$cap" 2>/dev/null || fail "an answer the intake refused is not offered again"
[ "$(jq -r .answer < "$cap")" = 'ship it' ] || fail "the refused answer was not offered again"

deliver_round 0 || fail "an answer the intake accepted did not complete the round"
[ -s "$FM_HOME_DIR/state/signoff-delivered" ] || fail "an accepted answer was not acknowledged"
adapter poll > "$cap" 2>/dev/null
[ "$?" = 75 ] || fail "an acknowledged answer was offered again"
pass "an answer the intake refuses is offered again until the intake accepts it"

echo "all fm-procevent-signoff tests passed"
