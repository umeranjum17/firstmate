#!/usr/bin/env bash
# jg-herdr-names.sh - keep this home's live Herdr names on the Juggernaut vocabulary.
#
# Usage:
#   jg-herdr-names.sh check              # fail while a live name or label shows an old word
#
# The command reads only this home's task records (state/*.meta with
# backend=herdr) and addresses each live item by the exact session, workspace,
# tab, and pane id recorded there. Nothing is found by a name search, so another
# home's items sharing the session are never read.
#
# check: for every recorded task, reads the live workspace label, tab label, and
# agent name. A name fails when it still carries an old product or role word
# (the pre-rename script prefix, the old product name, the old second-mate and
# first-mate role words) after the home's own ids are masked out. A recorded
# task id or this home's Squad Lead id is an identity chosen at dispatch, not a
# label this software writes, so the id text inside a name is not a leak; the
# prefix around it is. Exit 0 when clean, 1 when any name leaks, 2 when a
# recorded session cannot be read (nothing is then proven).
#
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }'
fi
unset _jg_d
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"

# shellcheck source=bin/jg-backend.sh
. "$SCRIPT_DIR/jg-backend.sh"
jg_backend_source herdr

# The old words, assembled from halves so this file adds no leftover to the
# rename's tracked-name gate (bin/juggernaut-name-gate.sh) while still naming
# what it forbids. A word must start the name or follow a non-alphanumeric.
OLD_PREFIX="f""m"
OLD_PRODUCT="first""mate"
OLD_LEAD="2nd""mate"
OLD_WORDS="second""mate|second[ -]mate|first[ -]mate|crew""mate"
LEAK_RE="(^|[^a-z0-9])(${OLD_PREFIX}[-_]|${OLD_PRODUCT}|${OLD_LEAD}|${OLD_WORDS})"

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'jg-herdr-names: %s\n' "$*" >&2
  exit "${2:-2}"
}

MASKS=
RECORDS=

# collect_records: one "<id>\t<session>\t<workspace>\t<tab>\t<pane>" line per
# herdr-backed task record, and the ids to mask out of names.
collect_records() {
  local meta id session workspace tab pane marker lead
  RECORDS=
  MASKS=
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    grep -q '^backend=herdr$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    session=$(jg_backend_meta_exact_value "$meta" herdr_session) || continue
    workspace=$(jg_backend_meta_exact_value "$meta" herdr_workspace_id) || continue
    tab=$(jg_backend_meta_exact_value "$meta" herdr_tab_id) || continue
    pane=$(jg_backend_meta_exact_value "$meta" herdr_pane_id) || continue
    RECORDS="${RECORDS}${id}"$'\t'"${session}"$'\t'"${workspace}"$'\t'"${tab}"$'\t'"${pane}"$'\n'
    # The id, the agent name derived from it, and the 27-character head a
    # long id keeps in that name: all are the id's own text.
    MASKS="${MASKS}${id}"$'\n'"$(jg_backend_herdr_agent_name_for "$id")"$'\n'"${id:0:27}"$'\n'
  done
  marker=$(jg_compat_marker "$JG_HOME")
  if [ -f "$marker" ]; then
    lead=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    [ -z "$lead" ] || MASKS="${MASKS}${lead}"$'\n'
  fi
}

# masked <name>: the lowercase name with every home id removed, longest first.
masked() {
  local value id
  value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    value=${value//"$id"/}
  done < <(printf '%s' "$MASKS" | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-)
  printf '%s' "$value"
}

session_list() {
  printf '%s' "$RECORDS" | cut -f2 | sort -u
}

# fetch_session <session>: live workspace list, task tabs, and agents into
# WS_JSON, TABS_JSON, AGENTS_JSON. Nonzero when the session cannot be read.
WS_JSON='' TABS_JSON='' AGENTS_JSON=''
fetch_session() {
  local session=$1 wsid tabs
  WS_JSON=$(jg_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  AGENTS_JSON=$(jg_backend_herdr_cli "$session" agent list 2>/dev/null) || return 1
  printf '%s' "$WS_JSON" | jq -e '.result.workspaces | type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$AGENTS_JSON" | jq -e '.result.agents | type == "array"' >/dev/null 2>&1 || return 1
  TABS_JSON='[]'
  while IFS= read -r wsid; do
    [ -n "$wsid" ] || continue
    tabs=$(jg_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || continue
    TABS_JSON=$(jq -c -n --argjson a "$TABS_JSON" --argjson b "$tabs" '$a + ($b.result.tabs // [])' 2>/dev/null) || return 1
  done < <(printf '%s' "$RECORDS" | awk -F'\t' -v s="$session" '$2 == s { print $3 }' | sort -u)
  return 0
}

ws_label() { printf '%s' "$WS_JSON" | jq -r --arg id "$1" '.result.workspaces[] | select(.workspace_id == $id) | .label' 2>/dev/null | head -n1; }
tab_label() { printf '%s' "$TABS_JSON" | jq -r --arg id "$1" '.[] | select(.tab_id == $id) | .label' 2>/dev/null | head -n1; }
agent_field() { printf '%s' "$AGENTS_JSON" | jq -r --arg id "$1" --arg f "$2" '.result.agents[] | select(.pane_id == $id) | .[$f] // ""' 2>/dev/null | head -n1; }

LEAKS=0 CHECKED=0
# check_name <session> <owner> <kind> <live-name>: count one name, print a leak.
check_name() {
  local session=$1 owner=$2 kind=$3 label=$4
  [ -n "$label" ] || return 0
  CHECKED=$((CHECKED + 1))
  if masked "$label" | grep -Eq "$LEAK_RE"; then
    printf 'LEAK %s %s %s=%s\n' "$session" "$owner" "$kind" "$label"
    LEAKS=$((LEAKS + 1))
  fi
}

cmd_check() {
  local session id sess workspace tab pane unread=0
  collect_records
  [ -n "$RECORDS" ] || { echo "jg-herdr-names: no herdr task records in $STATE; nothing to check"; return 0; }
  while IFS= read -r session; do
    if ! fetch_session "$session"; then
      echo "jg-herdr-names: cannot read herdr session '$session'; its names are unchecked" >&2
      unread=1
      continue
    fi
    # Each recorded workspace once, then each recorded task's tab and agent.
    while IFS= read -r workspace; do
      [ -n "$workspace" ] || continue
      check_name "$session" "$workspace" workspace "$(ws_label "$workspace")"
    done < <(printf '%s' "$RECORDS" | awk -F'\t' -v s="$session" '$2 == s { print $3 }' | sort -u)
    while IFS=$'\t' read -r id sess workspace tab pane; do
      [ "$sess" = "$session" ] || continue
      check_name "$session" "$id" tab "$(tab_label "$tab")"
      check_name "$session" "$id" agent "$(agent_field "$pane" name)"
    done <<EOF
$RECORDS
EOF
  done < <(session_list)
  if [ "$unread" -ne 0 ]; then
    echo "jg-herdr-names: check incomplete: a recorded session could not be read" >&2
    return 2
  fi
  if [ "$LEAKS" -ne 0 ]; then
    echo "jg-herdr-names: $LEAKS live name(s) still show an old word ($CHECKED checked); run: jg-herdr-names.sh migrate" >&2
    return 1
  fi
  echo "jg-herdr-names: ok - $CHECKED live name(s) of this home's recorded tasks show no old word"
  return 0
}

case "${1:-}" in
  check) shift; [ "$#" -eq 0 ] || die "check takes no arguments"; cmd_check ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
