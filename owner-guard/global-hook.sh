#!/usr/bin/env bash
# fm-owner-guard global hook template (install.sh stamps one copy per hook
# name, replacing __NAME__). Runs the owner-details guard first (__NAME__
# runs it only for pre-commit and pre-push), then chains the previous global
# hooks dir's hook and the repository's own hook, so repos with their own
# hooks keep working. Never touches repo-local core.hooksPath. Pre-push
# replays git's ref lines to every chained hook on stdin.
set -u -o pipefail
unset CDPATH
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
NAME=__NAME__
PREV=$(cat "$HERE/prev-hooks-path" 2>/dev/null || true)
if [ "$NAME" = pre-commit ]; then
  "$HERE/owner-guard" pre-commit "$@" || exit $?
elif [ "$NAME" = pre-push ]; then
  INPUT=$(cat)
  if [ -n "$INPUT" ]; then
    printf '%s\n' "$INPUT" | "$HERE/owner-guard" pre-push "$@" || exit $?
  else
    "$HERE/owner-guard" pre-push "$@" || exit $?
  fi
fi
chain() { # chain <hookfile> [args...]: run it when executable and not this wrapper.
  local f=$1
  shift
  [ -n "$f" ] && [ -f "$f" ] && [ -x "$f" ] || return 0
  [ "$f" != "$HERE/hooks/$NAME" ] || return 0
  if [ "$NAME" = pre-push ] && [ -n "${INPUT:-}" ]; then
    printf '%s\n' "$INPUT" | "$f" "$@" || exit $?
  else
    "$f" "$@" || exit $?
  fi
}
[ -n "$PREV" ] && [ -d "$PREV" ] && chain "$PREV/$NAME" "$@"
COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
[ -n "$COMMON" ] && chain "$COMMON/hooks/$NAME" "$@"
exit 0
