#!/usr/bin/env bash
# jg-lavish-guard.sh - refuse a captain-facing link on the retired Lavish port
# or a Lavish publication command, and name the surface that replaced it.
#
# Usage: jg-lavish-guard.sh [--append <file>] [<text>...]
#
# Reads the proposed text from its arguments, or from stdin when it has none,
# and exits 1 for a Lavish publication with one refusal line on stderr:
#
#   owner-rules: Lavish publication refused; use the sign-off board (sign-off-axi) instead
#
# Everything else exits 0. A grep or read error keeps its own diagnostics and
# exit code, so a broken check never passes as clean text. This is a text
# guard: it intercepts the words, never the command.
#
# --append <file> writes the accepted text to <file> unchanged and appends
# nothing when it is refused, so a caller can pipe one line through the guard
# without a second, unguarded copy of the text.
#
# This file is the one core owner of the refusal. bin/jg-squad-lead-report.sh
# runs it before a parent-channel append, and the status line bin/jg-brief.sh
# generates pipes through it, so no captain-facing status or report note can
# carry a Lavish address even when a worker types one by hand.
set -u

pattern='https?://[^/[:space:]?#]+:4387([/?#[:space:]"<>)]|$)|(^|[;&|(`]|[$][(])[[:space:]]*lavish-axi[[:space:]]+(publish([^[:alnum:]_-]|$)|[^[:space:]]*[.]html?([^[:alnum:]_-]|$))'

APPEND=''
if [ "${1-}" = --append ]; then
  [ "$#" -ge 2 ] || { echo 'error: --append needs a file' >&2; exit 2; }
  APPEND=$2
  shift 2
fi
if [ "$#" -gt 0 ]; then
  text=$(printf '%s\n' "$*")
else
  text=$(cat)
fi
grep_rc=0
printf '%s\n' "$text" | grep -Ei "$pattern" >/dev/null || grep_rc=$?
case "$grep_rc" in
  0)
    echo 'owner-rules: Lavish publication refused; use the sign-off board (sign-off-axi) instead' >&2
    exit 1
    ;;
  1) ;;
  *) exit "$grep_rc" ;;
esac
if [ -n "$APPEND" ]; then
  printf '%s\n' "$text" >> "$APPEND" || exit 1
fi
exit 0
