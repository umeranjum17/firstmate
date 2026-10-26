#!/usr/bin/env bash
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
. "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh"
# jg-secondmate-report.sh - optional helper to append a correlated parent report.
#
# A secondmate answering a marked from-firstmate request must report on the
# parent status channel with the request's corr=<id> token. This helper makes
# that easy, but correctness must not depend on using it: a plain echo of a
# status line that includes the same corr token is equally valid
# (bin/jg-pending-reply-lib.sh).
#
# The write destination is mechanical: this helper never takes a status path.
# It resolves the parent channel through jg_parent_channel_destination
# (bin/jg-parent-channel-lib.sh): a local mate writes the parent home's
# state/<id>.status, and a remote mate writes this home's
# state/parent-replies.status. Call it from the secondmate home with FM_HOME
# set to that home.
#
# Usage:
#   jg-secondmate-report.sh <verb> <corr_id> <note...>
#   jg-secondmate-report.sh --doc <verb> <corr_id> <doc-path> <note...>
#
# Examples:
#   jg-secondmate-report.sh done abcdef0123456789 "audit clean"
#   jg-secondmate-report.sh --doc done abcdef0123456789 data/x/report.md "see report"
#
# An optional firstmate-addons status-wait-check add-on (${FM_ADDONS_DIR:-<home>/projects/firstmate-addons}/status-wait-check/status-wait-check)
# receives <verb> <note> before the append and owns the wait rules. Its output is shown and a nonzero
# exit refuses the report with exit 2; an absent add-on is a no-op.
set -eu

CALLER_FM_HOME=${FM_HOME:-}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-pending-reply-lib.sh
. "$SCRIPT_DIR/jg-pending-reply-lib.sh"
# shellcheck source=bin/jg-parent-channel-lib.sh
. "$SCRIPT_DIR/jg-parent-channel-lib.sh"
# shellcheck source=bin/jg-question-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-question-lib.sh" \
  || { echo "error: the question rule needs $SCRIPT_DIR/jg-question-lib.sh beside this script" >&2; exit 1; }

jg_secondmate_report_status_blocked_wait() {  # <verb> <text>
  local hook="${FM_ADDONS_DIR:-${CALLER_FM_HOME}/projects/firstmate-addons}/status-wait-check/status-wait-check"
  [ -x "$hook" ] || return 0
  local out rc=0
  out=$("$hook" "$1" "$2" 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || exit 2
}

usage() {
  cat <<'EOF' >&2
Usage:
  jg-secondmate-report.sh <verb> <corr_id> <note...>
  jg-secondmate-report.sh --doc <verb> <corr_id> <doc-path> <note...>
EOF
  exit 2
}

DOC_MODE=0
if [ "${1:-}" = "--doc" ]; then
  DOC_MODE=1
  shift
fi

[ $# -ge 2 ] || usage
VERB=$1
CORR=$2
shift 2
if [ "$DOC_MODE" = 1 ]; then
  [ $# -ge 1 ] && [ -n "$1" ] || usage
else
  [ $# -ge 1 ] && [ -n "$*" ] || usage
fi

case "$CORR" in
  corr=*) CORR=${CORR#corr=} ;;
esac
case "$CORR" in
  [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
  *)
    echo "error: corr_id must be 16 hex characters (got '$CORR')" >&2
    exit 1
    ;;
esac

HOME_DIR=$CALLER_FM_HOME
case "$HOME_DIR" in
  '')
    echo "error: FM_HOME is required so the helper can resolve the parent channel" >&2
    exit 1
    ;;
esac
STATE_DIR="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"

DESTINATION=
DEST_RC=0
DESTINATION=$(jg_parent_channel_destination "$HOME_DIR" "$STATE_DIR") || DEST_RC=$?
if [ "$DEST_RC" -ne 0 ] || [ -z "$DESTINATION" ]; then
  echo "error: cannot resolve the parent channel from this home (not a seeded secondmate?)" >&2
  exit 1
fi
mkdir -p "$(dirname "$DESTINATION")" 2>/dev/null || true
if [ ! -d "$(dirname "$DESTINATION")" ]; then
  echo "error: cannot create parent directory for status file '$DESTINATION'" >&2
  exit 1
fi

token=$(jg_pending_reply_corr_token "$CORR")
if [ "$DOC_MODE" = 1 ]; then
  DOC_PATH=$1
  shift
  NOTE=$*
  jg_question_flag_reply "$NOTE"
  jg_secondmate_report_status_blocked_wait "$VERB" "$NOTE"
  if [ -n "$NOTE" ]; then
    printf -v line '%s [%s]: %s (%s via-helper)' "$VERB" "$token" "$NOTE" "$DOC_PATH"
  else
    printf -v line '%s [%s]: %s (via-helper)' "$VERB" "$token" "$DOC_PATH"
  fi
else
  NOTE=$*
  jg_question_flag_reply "$NOTE"
  jg_secondmate_report_status_blocked_wait "$VERB" "$NOTE"
  printf -v line '%s [%s]: %s (via-helper)' "$VERB" "$token" "$NOTE"
fi
printf '%s\n' "$(status_stamp_line "$line")" >> "$DESTINATION"
