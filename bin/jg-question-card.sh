#!/usr/bin/env bash
# jg-question-card.sh - post the board card for a question to the owner, then
# print its key so the reply can cite it.
#
# Usage:
#   jg-question-card.sh post --ask-ref <ref> --title "<one question>" [sign-off-axi raise flags...]
#   jg-question-card.sh post --board <decisions.json> ... (the same flags)
#   jg-question-card.sh post --route <lead> [--decision-key <slug>] ... (the same flags)
#   jg-question-card.sh keys
#
# The owner's rule (2026-10-25): "if you ask questions as well make sure they
# are posted, posting questions will be stricter way of working". A question to
# him must exist as a board card, and a chat-only question is a violation.
# bin/jg-turnend-guard.sh flags a reply that ends in a question while no open
# card is cited, and its banner points here.
#
# post   Post the question through sign-off-axi (this command re-implements none
#        of its question standard, options, outcomes or board rules - pass its
#        own flags through: --why, --outcome yes=..., --recommend, --default,
#        --option, --silent-by, --filer, ...), then print the card key alone on
#        stdout. Everything sign-off-axi prints goes to stderr. It refuses
#        without --title and --ask-ref, because a new Decide card needs both.
#        When the identical question is already open under a key, that key is
#        printed instead of posting a second card.
#        --route <lead> names the lead (a task id in this home) that owns the
#        question; the board-answers check (bin/jg-board-answers.sh) then sends
#        the answer straight to that lead and closes its decision <slug>
#        (default: the card key). Cards Main files for a lead name it. Neither
#        flag reaches sign-off-axi.
# keys   Print the key of every card still open on the board.
#
# The board is the one sign-off-axi reads: the explicit --board file, else the
# board sign-off-axi's own walk finds. Nothing here stores a private copy.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker_ok() { [ "${1-}" = JUGGERNAUT_OP ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-question-lib.sh
. "$SCRIPT_DIR/jg-question-lib.sh"
# shellcheck source=bin/jg-board-link-lib.sh
. "$SCRIPT_DIR/jg-board-link-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'jg-question-card: %s\n' "$1" >&2; exit 1; }

require_signoff() {
  jg_question_signoff_available \
    || die "sign-off-axi is not on PATH; install it from https://github.com/umeranjum17/sign-off"
  command -v jq >/dev/null 2>&1 || die "jq is required to read the board"
}

# Split --board out of the pass-through arguments: sign-off-axi takes the board
# file as its positional argument, before every flag.
split_board() {
  BOARD=''
  ROUTE=''
  DECISION_KEY=''
  ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --board)
        shift
        [ $# -gt 0 ] || die "--board needs a value"
        BOARD=$1
        ;;
      --route)
        shift
        [ $# -gt 0 ] || die "--route needs a lead task id"
        ROUTE=$1
        ;;
      --decision-key)
        shift
        [ $# -gt 0 ] || die "--decision-key needs a key"
        DECISION_KEY=$1
        ;;
      *) ARGS+=("$1") ;;
    esac
    shift
  done
}

has_flag() {  # <flag>  -> 0 when the remaining arguments carry it
  local want=$1 arg
  for arg in ${ARGS[@]+"${ARGS[@]}"}; do
    [ "$arg" = "$want" ] && return 0
  done
  return 1
}

flag_value() {  # <flag> -> the value that follows it
  local want=$1 i=0
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    if [ "${ARGS[$i]}" = "$want" ]; then
      printf '%s\n' "${ARGS[$((i + 1))]:-}"
      return 0
    fi
    i=$((i + 1))
  done
  return 0
}

cmd_post() {
  local title ask_ref before after key board out link rc=0
  split_board "$@"
  require_signoff
  title=$(flag_value --title)
  ask_ref=$(flag_value --ask-ref)
  [ -n "$title" ] || die "refused: post needs --title \"<the one question>\"; it is the card's title"
  [ -n "$ask_ref" ] || die "refused: post needs --ask-ref <the owner message or hold this question answers>; sign-off-axi requires it for a new Decide card"

  [ -z "$DECISION_KEY" ] || [ -n "$ROUTE" ] || die "refused: --decision-key only closes a lead's decision, so it needs --route <lead>"
  # Check the lead first: a refused route must not leave an unrouted card behind.
  [ -z "$ROUTE" ] || [ -f "${JG_STATE_OVERRIDE:-${JG_HOME:-/nonexistent}/state}/$ROUTE.meta" ] \
    || die "refused: --route '$ROUTE' is not a task recorded in this home (is JG_HOME set?)"
  before=$(jg_question_open_keys)
  if [ -n "$BOARD" ]; then
    out=$(sign-off-axi raise "$BOARD" ${ARGS[@]+"${ARGS[@]}"} 2>&1) || rc=$?
  else
    out=$(sign-off-axi raise ${ARGS[@]+"${ARGS[@]}"} 2>&1) || rc=$?
  fi
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || die "sign-off-axi refused the card (exit $rc); fix the flag it named and post again"

  after=$(jg_question_open_keys)
  key=$(comm -13 <(printf '%s\n' "$before" | sed '/^$/d' | LC_ALL=C sort) \
                <(printf '%s\n' "$after" | sed '/^$/d' | LC_ALL=C sort) | head -1)
  if [ -z "$key" ]; then
    key=$(printf '%s\n' "$after" | sed '/^$/d' | head -1)
    [ -n "$key" ] || die "sign-off-axi accepted the card but the board shows no open card; run sign-off-axi status and report this"
  fi
  [ -z "$ROUTE" ] || "$SCRIPT_DIR/jg-board-answers.sh" route "$key" "$ROUTE" "$DECISION_KEY" >&2 \
    || die "the card $key is posted but its route to $ROUTE was not recorded; run jg-board-answers.sh route $key $ROUTE"
  printf '%s\n' "$key"
  link=$(jg_board_link decide "$key") && printf 'link: %s\n' "$link" >&2
  return 0
}

cmd_keys() {
  require_signoff
  jg_question_open_keys
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  post) cmd_post "$@" ;;
  keys) cmd_keys ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
