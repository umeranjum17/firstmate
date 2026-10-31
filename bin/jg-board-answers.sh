#!/usr/bin/env bash
# jg-board-answers.sh - carry each board answer to the lead that needs it, as a
# standing watcher check, so no answer waits on Main reading it.
#
# Usage:
#   jg-board-answers.sh route <card-key> <lead> [<decision-key>]
#   jg-board-answers.sh [check|poll]
#   jg-board-answers.sh arm | disarm
#
# route  Record that <lead> (a task id in this home) owns the card; written by
#        `jg-question-card.sh post --route <lead> [--decision-key <slug>]`. The
#        decision key defaults to the card key.
# check  One deterministic pass, no model. Two sources, in this order.
#
#        STORE FIRST. Every captain response recorded through
#        bin/jg-chat.sh respond - the page's path - is a row in
#        state/chat.jsonl carrying the element it is on, the response text and
#        the agent assigned to answer it. A row still `sent` wakes that agent
#        itself and moves to `read` on delivery, so no board path can silence a
#        wake and the owner's own `reply` moves it on to `replied`. This is why
#        the check watches the store, never one answers file.
#
#        BOARD SECOND, the transitional ingest for decisions raised through
#        jg-question-card: read the board's answers through sign-off-axi, then
#        for each:
#          ROUTED: send the lead one marked answer line (card key, answer, time,
#            card link) with bin/jg-send.sh, closing the lead's open decision
#            key with --resolve-key (a squad_lead with no open key gets a
#            fire-and-forget line); Main gets one `info:` line. A failed send is
#            retried each pass and reported once. When the lead moves that
#            record to its inbox's handled/ (the acknowledgement), the card is
#            archived (dismiss, done-elsewhere).
#          UNROUTED: print one line, full answer text first; the watcher turns
#            it into a wake for Main. Reported once; answers already on the
#            board at the first pass are recorded, not reported.
# arm    Write state/board-answers.check.sh, bind it with jg-check-register.sh,
#        and run one pass. disarm removes the shim and its trust binding.
#        A board that cannot be read while the check is armed says so once, by
#        naming the path it resolved, instead of returning quietly: a moved board
#        is a reporting failure, not a quiet home.
# State: state/board-routes/<card-key>, state/.board-answers-seen,
#        state/.board-answers-unreadable (the last read failure already reported).
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
ROUTES="$STATE/board-routes"
SEEN="$STATE/.board-answers-seen"
BOARD_UNREADABLE="$STATE/.board-answers-unreadable"
SHIM="$STATE/board-answers.check.sh"
CHAT="$SCRIPT_DIR/jg-chat.sh"
STORE="$STATE/chat.jsonl"
# shellcheck source=bin/jg-compat.sh
. "$SCRIPT_DIR/jg-compat.sh"
# shellcheck source=bin/jg-question-lib.sh
. "$SCRIPT_DIR/jg-question-lib.sh"
# shellcheck source=bin/jg-board-link-lib.sh
. "$SCRIPT_DIR/jg-board-link-lib.sh"
# shellcheck source=bin/jg-classify-lib.sh
. "$SCRIPT_DIR/jg-classify-lib.sh"
die() { printf 'jg-board-answers: %s\n' "$1" >&2; exit "${2:-1}"; }
key_ok() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
rget() { sed -n "s/^$2=//p" "$ROUTES/$1" 2>/dev/null | tail -1; }
rput() { printf '%s=%s\n' "$2" "$3" >> "$ROUTES/$1"; }
say() { printf '%s\n' "${1:0:400}"; }

cmd_route() {
  local key=${1-} lead=${2-} dk=${3-}
  { key_ok "$key" && key_ok "$lead"; } || die "route needs a card key and a lead task id" 2
  [ -z "$dk" ] || key_ok "$dk" || die "invalid decision key '$dk'" 2
  [ -f "$STATE/$lead.meta" ] || die "refused: '$lead' is not a task recorded in this home"
  mkdir -p "$ROUTES" || die "cannot create $ROUTES"
  printf 'lead=%s\ndecision=%s\n' "$lead" "${dk:-$key}" > "$ROUTES/$key" || die "cannot record the route for $key"
}

deliver() {  # <key> <lead> <decision> <text> <delivery-id>; 0 = recorded in the lead's inbox
  local key=$1 lead=$2 dk=$3 text=$4 id=$5 args=()
  if [ -n "$dk" ] && status_open_decisions "$STATE/$lead.status" 2>/dev/null | grep -q "^$dk"$'\t'; then
    args=(--resolve-key "$dk")
  elif jg_compat_meta_is_squad_lead "$STATE/$lead.meta"; then
    args=(--fire-and-forget "$id")
  fi
  JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-send.sh" "$lead" ${args[@]+"${args[@]}"} "$text" 2>&1
}

# One line per distinct condition, so a check pass does not repeat itself.
board_note() { # <signature> <line>
  local sig=$1 prev
  prev=$(cat "$BOARD_UNREADABLE" 2>/dev/null)
  [ "$prev" = "$sig" ] && return 0
  mkdir -p "${BOARD_UNREADABLE%/*}" 2>/dev/null && printf '%s\n' "$sig" > "$BOARD_UNREADABLE"
  say "$2"
}

board_readable() { rm -f -- "$BOARD_UNREADABLE" 2>/dev/null || true; }

# The store is the source of truth for a response: a captain row that
# is still `sent` wakes the agent it names, from the row, and moves to `read` on
# delivery. The agent's own answer moves it on to `replied` (bin/jg-chat.sh).
store_pass() {
  local thread to at text on act owner link lead dk id msg out once='' report=''
  [ -f "$STORE" ] || return 0
  while IFS=$(printf '\t') read -r thread to at text on act owner link; do
    [ -n "$on" ] || continue
    lead=$(rget "$on" lead)
    [ -n "$lead" ] || lead=$to
    key_ok "$lead" || continue
    [ -f "$STATE/$lead.meta" ] || continue
    dk=$(rget "$on" decision)
    id=$(printf '%s' "$on|$at" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)
    msg="board-response [act=$act key=$on at=$at]: the captain ${act}ed \"$text\"${owner:+ (owner $owner)}${link:+ | $link}. Move this record to handled/ to acknowledge; no other reply is owed."
    if out=$(deliver "$on" "$lead" "$dk" "$msg" "$id"); then
      "$CHAT" mark-row "$thread" "$at" read >/dev/null 2>&1 ||
        report="${report}$(say "the response on $on reached $lead but the store row could not be marked read")"$'\n'
      report="${report}$(say "info: captain $act on $on went to $lead; nothing for Main to do")"$'\n'
    elif [ "$(rget "$on" failed)" != "$at" ]; then
      rput "$on" failed "$at"
      report="${report}$(say "captain $act on $on could not reach $lead (retrying each pass): ${out//$'\n'/ }")"$'\n'
    fi
    once=1
  done < <(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$CHAT" log --view message 2>/dev/null |
    jq -r 'select(.from == "captain" and .on != null and .status == "sent")
      | [.thread, .to, (.at | tostring), .text, .on, .kind, (.owner // ""), (.link // "")] | map(tostring | gsub("[\n\r\t]"; " ")) | join("\u001f")' 2>/dev/null |
    tr '\037' '\t')
  [ -n "$once" ] || return 0
  printf '%s' "$report"
}

cmd_check() {
  local json board key answer label note at lead dk link text id out first=0 report=''
  local store_report
  store_report=$(store_pass)
  [ -z "$store_report" ] || printf '%s' "$store_report"
  if ! jg_question_signoff_available; then
    board_note no-tool "board answers cannot be read: sign-off-axi is not on PATH, so a board response recorded outside the store wakes nobody"
    return 0
  fi
  board=$(jg_question_board)
  if [ -z "$board" ] || [ ! -f "$board" ]; then
    board_note "no-board:${board:--}" "board answers cannot be read: no board at '${board:-<none>}', so a board response recorded outside the store wakes nobody"
    return 0
  fi
  json=$(sign-off-axi answers "$board" --json 2>/dev/null) || {
    board_note "read-failed:$board" "board answers cannot be read from '$board': sign-off-axi answers failed"
    return 0
  }
  board_readable
  [ -f "$SEEN" ] || { first=1; : > "$SEEN"; }
  mkdir -p "$ROUTES"
  while IFS=$'\037' read -r key at answer label note; do
    key_ok "$key" && [ -n "$at" ] && [ -n "$answer" ] || continue
    link=$(JG_HOME="$JG_HOME" jg_board_link answered "$key" 2>/dev/null)
    lead=$(rget "$key" lead)
    if [ -z "$lead" ]; then
      case "$key" in jg-*) continue ;; esac
      grep -qxF "$key"$'\t'"$at" "$SEEN" && continue
      printf '%s\t%s\n' "$key" "$at" >> "$SEEN"
      [ "$first" = 1 ] && continue
      report="${report}$(say "$answer${label:+ ($label)}${note:+ - $note} | board answer on $key at $at, not routed to a lead${link:+ | $link}")"$'\n'
      continue
    fi
    if [ "$(rget "$key" answered)" != "$at" ]; then
      dk=$(rget "$key" decision)
      id=$(printf '%s' "$key|$at" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)
      text="board-answer [key=$key at=$at]: the captain answered \"$answer\"${label:+ ($label)}${note:+ - note: $note}.${link:+ Card: $link.} Move this record to handled/ to acknowledge; no other reply is owed."
      if out=$(deliver "$key" "$lead" "$dk" "$text" "$id"); then
        rput "$key" answered "$at"
        report="${report}$(say "info: board answer \"$answer\" on $key went to $lead; nothing for Main to do")"$'\n'
      elif [ "$(rget "$key" failed)" != "$at" ]; then
        rput "$key" failed "$at"
        report="${report}$(say "board answer \"$answer\" on $key could not reach $lead (retrying each pass): ${out//$'\n'/ }")"$'\n'
      fi
    elif [ -z "$(rget "$key" archived)" ] && grep -qsF "board-answer [key=$key at=$at]" "$STATE/$lead.inbox/handled/"*.msg; then
      sign-off-axi dismiss "$key" ${board:+"$board"} --reason done-elsewhere >/dev/null 2>&1 && rput "$key" archived 1
    fi
  done < <(printf '%s\n' "$json" | jq -r 'to_entries[] | select(.value.answer != null and .value.at != null)
    | [.key, .value.at, .value.answer, (.value.label // ""), (.value.note // "")] | map(tostring | gsub("[\n\r\t\u001f]"; " ")) | join("\u001f")' 2>/dev/null)
  [ -z "$report" ] || printf '%s' "$report"
}

cmd_arm() {
  local tmp
  tmp=$(umask 077; mktemp "$STATE/.jg-board-answers.XXXXXX") || die "cannot write the check shim"
  { printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec %q check\n' "$JG_HOME" "$SCRIPT_DIR/jg-board-answers.sh" > "$tmp" \
    && chmod 0700 "$tmp" && mv -f -- "$tmp" "$SHIM"; } || { rm -f -- "$tmp"; die "cannot write the check shim"; }
  JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-register.sh" board-answers || die "cannot register the check"
  cmd_check > /dev/null
  printf 'armed: board-answers\n'
}

case "${1:-check}" in
  route) shift; cmd_route "$@" ;;
  check|poll) cmd_check ;;
  arm) cmd_arm ;;
  disarm) rm -f -- "$SHIM" "$STATE/board-answers.check-trust"; printf 'disarmed: board-answers\n' ;;
  *) die "unknown command: $1" 2 ;;
esac
