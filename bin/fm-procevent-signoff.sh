#!/usr/bin/env bash
# sign-off adapter for the generic process-to-event runner: captain answers
# given on a sign-off board come in, and captain holds go out as board cards.
#
# Usage:
#   fm-procevent-signoff.sh arm
#   fm-procevent-signoff.sh retire
#   fm-procevent-signoff.sh enabled
#   fm-procevent-signoff.sh raise <task-id> <title> <reason> <done|release>
#   fm-procevent-signoff.sh poll [--timeout <secs>]
#   fm-procevent-signoff.sh answers <result-file>
#   fm-procevent-signoff.sh relisten
#   fm-procevent-signoff.sh source-id
#
# arm        Opt this home in: check that sign-off-axi runs, bind the source to
#            the keyed-answer intake (bin/fm-captain-hold.sh bind), and register
#            the `signoff` source with bin/fm-procevent.sh. Nothing here runs
#            until a home arms it, so an unarmed home behaves exactly as before.
# retire     Opt out: retire the registration and drop the binding.
# enabled    Exit 0 only while the source is registered in this home.
# raise      Called by `fm-captain-hold.sh hold` after a hold is recorded. While
#            enabled it raises one board card keyed by the task id, with the
#            hold reason as its `about` and the given close mode; otherwise it is
#            a silent no-op. A failure exits nonzero with sign-off's own output;
#            the caller warns and keeps the hold.
# poll       The blocking child the runner executes; never run it in a
#            conversational turn. It prints one line per deliverable answer,
#            `<task-id>\t<answer>\t<label>\t<close>\t<at>`, and exits 0. With
#            nothing deliverable it blocks in `sign-off-axi wait` for up to
#            --timeout seconds (600 by default) and exits 75 with no output, the
#            runner's clean empty wait, so `relisten` polls again.
# answers    This adapter's half of the keyed-answer contract in
#            bin/fm-procevent.sh: print `<task-id>\t<answer>\t<label>\t<close>`
#            for each captured line and record it as delivered.
#
# An answer is deliverable only when its key is a task this home still holds
# for the captain (`fm-captain-hold.sh open --identity`), it was saved at or
# after that hold's `Captain hold set:` stamp, and this key and save time were
# not already delivered. The open hold is the cursor: an answer saved while no
# poll ran is still found on the next round, an old answer never resolves a
# re-held task, and an intake that refuses an answer does not wake the fleet on
# every round. Answers on the same board from other agents are never read as
# Firstmate's. What an answer DOES is owned by the keyed-answer intake in
# bin/fm-captain-hold.sh; this adapter maps nothing and closes nothing.
#
# sign-off-axi runs from PATH when installed and otherwise through
# `npx -y sign-off-axi`. Cards and answers use sign-off's default board
# (~/.sign-off/decisions.json), the one `sign-off-axi open` shows.
# ponytail: one default board per machine; add a board option when a home needs its own.
# sign-off-axi has no command to withdraw a card, so a hold answered through
# another channel leaves its card waiting on the board.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

SOURCE_ID=signoff
DELIVERED="$STATE/signoff-delivered"
# How long a round rests after sign-off-axi could not wait at all (no board yet,
# nothing waiting, or the tool failing), so an idle home does not spin.
IDLE_REST=30

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

signoff() {
  if command -v sign-off-axi >/dev/null 2>&1; then
    sign-off-axi "$@"
  else
    npx -y sign-off-axi "$@"
  fi
}

cmd_enabled() { [ -f "$(fm_procevent_registry_dir "$STATE")/$SOURCE_ID.source" ]; }

cmd_arm() {
  local out
  out=$(signoff --version 2>&1) \
    || die "sign-off-axi does not run here (install it, or check npx): $out"
  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$SOURCE_ID" >/dev/null || die "could not bind $SOURCE_ID to the keyed-answer intake"
  "$SCRIPT_DIR/fm-procevent.sh" register signoff "$SOURCE_ID" -- "$SCRIPT_DIR/fm-procevent-signoff.sh" poll || exit 1
  printf 'armed: %s\nsign-off-axi: %s\n' "$SOURCE_ID" "$out"
}

cmd_retire() {
  "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID" || exit 1
  "$SCRIPT_DIR/fm-captain-hold.sh" unbind "$SOURCE_ID" >/dev/null || exit 1
}

cmd_raise() {
  [ "$#" -eq 4 ] || usage
  local out
  cmd_enabled || return 0
  out=$(signoff raise --key "$1" --title "$2" --about "$3" --close "$4" 2>&1) || {
    printf 'sign-off-axi raise failed: %s\n' "$out" >&2
    return 1
  }
  case "$out" in
    *"already answered"*)
      printf 'sign-off already holds an answered card under %s; this hold has no live card\n' "$1" >&2
      return 1
      ;;
  esac
  printf 'sign-off card on the board for %s\n' "$1" >&2
}

# Print every deliverable answer as `key\tanswer\tlabel\tclose\tat`.
deliverable() {
  local json key answer label close at identity
  json=$(signoff answers --json 2>/dev/null) || return 0
  printf '%s\n' "$json" \
    | jq -r 'to_entries[] | [.key, .value.answer, .value.label, .value.close, .value.at] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r key answer label close at; do
        fm_procevent_source_id_valid "$key" && [ -n "$answer" ] && [ -n "$at" ] || continue
        [ ! -f "$DELIVERED" ] || ! grep -qxF "$key"$'\t'"$at" "$DELIVERED" || continue
        identity=$("$SCRIPT_DIR/fm-captain-hold.sh" open "$key" --identity 2>/dev/null) || continue
        [[ ! "$at" < "${identity%%#*}" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$answer" "$label" "$close" "$at"
      done
}

cmd_poll() {
  local timeout=600 found start
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout) timeout=${2-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  case "$timeout" in ''|*[!0-9]*) die "--timeout needs whole seconds" ;; esac
  found=$(deliverable)
  if [ -z "$found" ]; then
    start=$SECONDS
    if ! signoff wait --json --timeout "$timeout" >/dev/null 2>&1 && [ $((SECONDS - start)) -lt "$timeout" ]; then
      sleep "$IDLE_REST"
    fi
    found=$(deliverable)
  fi
  [ -n "$found" ] || exit 75
  printf '%s\n' "$found"
}

cmd_answers() {
  local file=${1-} key answer label close at
  [ -f "$file" ] || die "result file does not exist: $file"
  while IFS=$'\t' read -r key answer label close at; do
    fm_procevent_source_id_valid "$key" && [ -n "$answer" ] && [ -n "$at" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$key" "$answer" "$label" "$close"
    printf '%s\t%s\n' "$key" "$at" >> "$DELIVERED"
  done < "$file"
}

case "${1-}" in
  arm) shift; cmd_arm "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  enabled) shift; cmd_enabled ;;
  raise) shift; cmd_raise "$@" ;;
  poll) shift; cmd_poll "$@" ;;
  answers) shift; cmd_answers "$@" ;;
  relisten) exit 0 ;;
  source-id) printf '%s\n' "$SOURCE_ID" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
