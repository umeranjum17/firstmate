#!/usr/bin/env bash
# jg-board-gate.sh - what a refused board ask leaves behind, and Main's answer.
#
# Usage:
#   jg-board-gate.sh route --title "<the ask>" [--filer <id>] [--ref <id>]
#
# The captain's leash (2026-10-30): "asking when it matters is not working at
# all - it's asking random questions that should go to overwatch not to my
# board". bin/jg-ask-gate-lib.sh owns the category list and the refusal; this
# script owns where a refused ask goes instead.
# route turns it into an Overwatch decision record in $DATA/overwatch-decisions.md,
# says "Main decided", and prints `overwatch: <record-id> <path>`.
# Environment: JG_HOME and JG_DATA_OVERRIDE as in other bin/ scripts.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
RECORDS="$DATA/overwatch-decisions.md"

die() { printf 'jg-board-gate: %s\n' "$1" >&2; exit "${2:-1}"; }
clean_line() { printf '%s' "${1-}" | tr '\n\r\t' '   '; }

route_record() {  # <title> <filer> <ref> -> prints the record id
  local title id
  title=$(clean_line "$1")
  id="owd-$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%s' "$title" | cksum | awk '{printf "%08x", $1}')"
  [ ! -f "$RECORDS" ] || ! grep -qxF "## $id" "$RECORDS" || { printf '%s\n' "$id"; return 0; }
  mkdir -p "$DATA" || return 1
  {
    printf '\n## %s\n' "$id"
    printf -- '- Ask: %s\n' "$title"
    printf -- '- Asked by: %s\n' "$(clean_line "${2:-unknown}")"
    [ -z "${3-}" ] || printf -- '- Ask ref: %s\n' "$(clean_line "$3")"
    printf -- '- Must category: none\n'
    printf -- '- Main decided: open - Main answers this; the record carries what Main decided\n'
  } >> "$RECORDS" || return 1
  printf '%s\n' "$id"
}

cmd_route() {
  local title='' filer='' ref='' id
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1-} ;;
      --filer) shift; filer=${1-} ;;
      --ref) shift; ref=${1-} ;;
      *) die "route: unknown flag $1" 2 ;;
    esac
    shift
  done
  [ -n "$title" ] || die 'route needs --title "<the ask>"' 2
  id=$(route_record "$title" "$filer" "$ref") || die "cannot write $RECORDS"
  printf 'overwatch: %s %s\n' "$id" "$RECORDS"
}

case "${1:-}" in
  route) shift; cmd_route "$@" ;;
  -h|--help|help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 2 ;;
  *) die 'usage: route (see the header)' 2 ;;
esac
