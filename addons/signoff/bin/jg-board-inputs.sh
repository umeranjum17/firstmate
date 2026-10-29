#!/usr/bin/env bash
# Relay every captain input on a sign-off board to its owner and mark how far it got.
#
# Usage: jg-board-inputs.sh relay <board.json>
#
# The keyed-answer adapter relays only the answers to this home's own hold cards.
# This relays the rest: report verdicts, part comments, text replies and button
# answers on any other card. Each input newer than JG_BOARD_INPUT_MAX_AGE seconds
# (default 7 days) goes once to the owner of its card: the Juggernaut task named by
# the card's filer (or its config/engage-owners binding) through the task inbox,
# else Main through `jg-inbox.sh note`. Then:
#   Delivered  `sign-off-axi feedback <card> --delivered` once the owner has it.
#   Read       `--read` once the owner moved it to handled (inbox) or acked the note.
#   Replied    the owner's own `feedback --reply`, a required step of handling; the
#              message carries the command. Read but not replied by the deadline escalates too.
# An input still unread after JG_BOARD_INPUT_ESCALATE_SECS (default 1800) sends
# Main one `jg-inbox.sh note`. Events are appended to state/signoff-inputs:
#   sent<TAB>id<TAB>card<TAB>owner<TAB>ref<TAB>epoch | read<TAB>id | escalated<TAB>id
# sign-off-axi older than 0.6.1 (no feedback command) still relays, without marks.
set -uo pipefail

CODE_ROOT="${JG_CODE_ROOT:-${JG_HOME:-}}"
[ -f "$CODE_ROOT/bin/jg-task-inbox-lib.sh" ] || { echo "jg-board-inputs: set JG_CODE_ROOT to a Juggernaut checkout" >&2; exit 2; }
JG_HOME="${JG_HOME:-$CODE_ROOT}"
STATE=${JG_STATE_OVERRIDE:-"$JG_HOME/state"}
CONFIG=${JG_CONFIG_OVERRIDE:-"$JG_HOME/config"}
SIGNOFF=${SIGN_OFF_CLI:-sign-off-axi}
# shellcheck source=/dev/null
. "$CODE_ROOT/bin/jg-task-inbox-lib.sh"
# shellcheck source=signoff/bin/jg-signoff-feedback-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/jg-signoff-feedback-lib.sh"
LOG=$STATE/signoff-inputs
NOW=${JG_BOARD_INPUT_NOW:-$(date +%s)}
MAX_AGE=${JG_BOARD_INPUT_MAX_AGE:-604800}
ESCALATE=${JG_BOARD_INPUT_ESCALATE_SECS:-1800}

[ "${1-}" = relay ] && [ -f "${2-}" ] || { echo 'usage: jg-board-inputs.sh relay <board.json>' >&2; exit 2; }
board=$2
stem=${board%.json}
mkdir -p "$STATE"; touch "$LOG"
prefix=jg-$(printf '%s' "$JG_HOME" | cksum | awk '{printf "%08x", $1}')-

owner_of() {  # <filer> -> task id when it has a live record, else empty (Main)
  local task=$1
  [ -z "$task" ] || ! [ -f "$CONFIG/engage-owners" ] || task=$(awk -F '\t' -v f="$1" '$1 == f { t = $2 } END { print t ? t : f }' "$CONFIG/engage-owners")
  [[ $task =~ ^[A-Za-z0-9._-]{1,128}$ ]] && [ -f "$STATE/$task.meta" ] \
    && ! grep -Eq '^(done|failed|cancelled|finished) \[at=[0-9]+\]:' "$STATE/$task.status" 2>/dev/null && printf '%s' "$task"
}

mark() { jg_signoff_feedback "$@" >/dev/null 2>&1 || true; }  # exit 3 (old sign-off) is fine

main_note() {  # <request-id> <text> -> note id
  "$CODE_ROOT/bin/jg-inbox.sh" note --request-id "$1" --json -- "$2" >/dev/null 2>&1 || true
  tr -d '\r\n' < "$STATE/inbox/.requests/$1" 2>/dev/null
}

is_read() {  # <owner> <ref>
  if [ "$1" = main ]; then [ -f "$STATE/inbox/handled/$2.note" ]; else [ -f "${2%/*}/handled/${2##*/}" ]; fi
}

deliver() {  # <input-json>
  local in=$1 id key filer owner msg ref
  id=$(jq -r .id <<<"$in"); key=$(jq -r .key <<<"$in")
  grep -q "^sent"$'\t'"$id"$'\t' "$LOG" && return 0
  filer=$(awk -F '\t' -v k="$key" '$1 == k { print $2; exit }' <<<"$owners") || true
  [ -n "$filer" ] || [ -n "$(awk -F '\t' -v k="$key" '$1 == k' <<<"$owners")" ] || return 0  # card gone from the board
  owner=$(owner_of "$filer")
  msg="Sign-off input $id on card $key ($(jq -r .kind <<<"$in")$(jq -r 'if .part != "" then ", part " + .part else "" end' <<<"$in")): $(jq -r .text <<<"$in")
Handling this includes the reply, posted on the same card BEFORE you move this message to handled:
sign-off-axi feedback $key $board --reply \"<short reply>\""
  if [ -n "$owner" ]; then
    ref=$(jg_task_inbox_write_idempotent "$STATE" "$owner" "$msg") && [ -n "$ref" ] || return 0
    jg_task_inbox_ring "$(jg_backend_of_meta "$STATE/$owner.meta")" "$(jg_backend_target_of_meta "$STATE/$owner.meta")" "$ref" "jg-$owner" || true
  else
    owner=main
    ref=$(main_note "signoff-input-$id" "$msg"); [ -n "$ref" ] || return 0
  fi
  mark "$key" "$board" --delivered
  printf 'sent\t%s\t%s\t%s\t%s\t%s\n' "$id" "$key" "$owner" "$ref" "$NOW" >> "$LOG"
}

owners=$("$SIGNOFF" list "$board" --json 2>/dev/null | jq -r '.decisions[] | [.key, (.filer // "")] | @tsv') || owners=''
[ -n "$owners" ] || exit 0

{
  jq -c '{id, key, kind: (if .verdict then "report verdict" else "part comment" end), part: (.part // ""), text: (.verdict // .text // ""), at}' "$stem.annotations.jsonl" 2>/dev/null
  jq -c 'select(.answer != null) | {id: (.key + "@" + .at), key, kind: (if .answer == "text" then "text reply" else "button answer" end), part: "", text: ((.label // .answer) + (if .note then ": " + .note else "" end)), at}' "$stem.answers.jsonl" 2>/dev/null
} | jq -c --arg p "$prefix" --argjson now "$NOW" --argjson age "$MAX_AGE" \
      'select((.key | startswith($p) | not) and .text != "" and ((.at | fromdateiso8601) >= $now - $age))' 2>/dev/null \
  | while IFS= read -r input; do deliver "$input"; done

# Read marks and the unread escalation, from the append-only log.
while IFS=$'\t' read -r ev id key owner ref at; do
  [ "$ev" = sent ] || continue
  if grep -q "^read"$'\t'"$id\$" "$LOG"; then
    # Read but never answered on the board: tell Main once.
    if [ $((NOW - at)) -ge "$ESCALATE" ] && ! grep -q "^escalated"$'\t'"$id\$" "$LOG" \
       && ! grep -q "\"op\":\"reply\".*\"key\":\"$key\"" "$stem.trail.jsonl" 2>/dev/null; then
      main_note "signoff-input-$id-unreplied" "Board input $id on card $key was read by $owner but has no reply on the board after $(((NOW - at) / 60)) min." >/dev/null
      printf 'escalated\t%s\n' "$id" >> "$LOG"
    fi
    continue
  fi
  if is_read "$owner" "$ref"; then
    mark "$key" "$board" --read; printf 'read\t%s\n' "$id" >> "$LOG"
  elif [ $((NOW - at)) -ge "$ESCALATE" ] && ! grep -q "^escalated"$'\t'"$id\$" "$LOG"; then
    main_note "signoff-input-$id-unread" "Board input $id on card $key sat unread for $(((NOW - at) / 60)) min with $owner. Check on it." >/dev/null
    printf 'escalated\t%s\n' "$id" >> "$LOG"
  fi
done < <(cat "$LOG")
