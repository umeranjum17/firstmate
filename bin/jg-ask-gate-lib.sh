#!/usr/bin/env bash
# jg-ask-gate-lib.sh - which board asks may reach the captain, and the refusal.
#
# The captain's leash (2026-10-30): on "When it matters" his board carries only
# asks that are a must; every other ask is refused here and becomes an Overwatch
# decision record (bin/jg-board-gate.sh route) that Main answers. sign-off-axi
# owns the board and the leash setting (`leash:` in the config.yaml beside the
# board: ask, matters its default, or act), so this file only reads it. Sourced
# by bin/jg-question-card.sh, bin/jg-procevent-signoff.sh and bin/jg-captain-hold.sh.

JG_ASK_MUST_CATEGORIES='money credential-login physical-device discard-unlanded public-release security rule-change design-pick'

# shellcheck source=bin/jg-question-lib.sh
command -v jg_question_board >/dev/null 2>&1 \
  || . "${BASH_SOURCE[0]%/*}/jg-question-lib.sh"

jg_ask_categories_words() {
  printf '%s\n' "$JG_ASK_MUST_CATEGORIES" | sed 's/ /, /g'
}

jg_ask_category_ok() {  # <category>
  [ -n "${1-}" ] || return 1
  case " $JG_ASK_MUST_CATEGORIES " in *" $1 "*) return 0 ;; esac
  return 1
}

# The leash as sign-off-axi applies it: ask, matters or act.
jg_ask_leash() {  # [<board file>]
  local board=${1-} cfg='' v=''
  [ -n "$board" ] || board=$(jg_question_board)
  [ -z "$board" ] || cfg=${board%/*}/config.yaml
  [ -z "$cfg" ] || [ ! -f "$cfg" ] \
    || v=$(sed -n 's/^leash:[[:space:]]*//p' "$cfg" 2>/dev/null | tail -1 | tr -d "\"'[:space:]")
  case "$v" in ask|matters|act) printf '%s\n' "$v" ;; *) printf 'matters\n' ;; esac
}

# The must category a card carries in its detail field, or nothing.
jg_ask_card_category() {  # <detail text>
  local d=${1-}
  case "$d" in *must:*) d=${d##*must:} ;; *) return 0 ;; esac
  d=${d# }; d=${d%% *}
  jg_ask_category_ok "$d" && printf '%s\n' "$d"
  return 0
}

# Print why this ask cannot go on the board and return 1, or return 0 to post it.
# A named but unknown category is always refused, so the count stays honest.
jg_ask_gate_refusal() {  # <category-or-empty> [<board file>]
  local cat=${1-}
  if [ -n "$cat" ]; then
    jg_ask_category_ok "$cat" && return 0
    printf 'refused: %s is not a must category; a must is one of: %s\n' "$cat" "$(jg_ask_categories_words)"
    return 1
  fi
  [ "$(jg_ask_leash "${2-}")" = matters ] || return 0
  printf 'refused: the board leash is when it matters, so a board ask needs a must category: %s\n' "$(jg_ask_categories_words)"
  printf 'not a must? Decide it yourself and record "Main decided" with bin/jg-board-gate.sh decided; it never reaches his board.\n'
  return 1
}
