#!/usr/bin/env bash
# Durable per-task scratch-directory record: state/<id>.scratch.
# Usage: fm-scratch.sh register <task-id> <dir>   record one scratch directory
#        fm-scratch.sh list <task-id>             print the recorded directories that are safe to reap
# A task registers every temporary directory it creates beyond the spawn-owned
# /tmp/fm-<id> root (a mktemp -d, a cache or emulator folder) so bin/fm-teardown.sh
# can reap exactly those paths once the landed-work test passes, even when the
# session that created them is gone. The record is one literal absolute path per
# line; nothing is ever matched by glob or pattern.
# A path is accepted only when it is absolute, free of glob characters and
# "."/".." components, a real directory (not a symlink), owned by this user, at
# least two components deep, and neither $HOME, an ancestor of $HOME, nor a
# direct child of $HOME. register refuses anything else; list drops anything
# else with a warning, so a hand-edited record cannot widen a delete.
# bin/fm-teardown.sh owns the remaining guards (firstmate home, repo, state and
# data are never reaped) and the removal itself.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# Print the refusal reason and fail when <dir> is not a safe scratch directory.
scratch_path_refusal() {
  local dir=$1 home parent
  case "$dir" in
    /*) ;;
    *) echo "not an absolute path" >&2; return 1 ;;
  esac
  case "$dir" in
    *[*?[]*|*']'*|*$'\n'*|*//*|*/|*/./*|*/.|*/../*|*/..)
      echo "contains a glob character, newline, empty or dot component" >&2; return 1 ;;
  esac
  [ -d "$dir" ] && [ ! -L "$dir" ] || { echo "not a real directory" >&2; return 1; }
  [ -O "$dir" ] || { echo "not owned by this user" >&2; return 1; }
  parent=${dir%/*}
  [ -n "$parent" ] || { echo "too shallow" >&2; return 1; }
  home=$(cd "$HOME" 2>/dev/null && pwd -P) || home=${HOME%/}
  case "$home/" in
    "$dir"/*) echo "is HOME or an ancestor of HOME" >&2; return 1 ;;
  esac
  [ "$parent" != "$home" ] || { echo "is a direct child of HOME" >&2; return 1; }
}

usage() {
  echo "usage: fm-scratch.sh register <task-id> <dir> | list <task-id>" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
CMD=$1 ID=$2
fm_pr_task_id_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
RECORD="$STATE/$ID.scratch"

case "$CMD" in
  register)
    [ "$#" -eq 3 ] || usage
    DIR=$3
    reason=$(scratch_path_refusal "$DIR" 2>&1) \
      || { echo "error: refusing to register scratch directory $DIR: $reason" >&2; exit 1; }
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
    [ ! -L "$RECORD" ] || { echo "error: scratch record is a symlink" >&2; exit 1; }
    if [ -f "$RECORD" ] && grep -qxF -- "$DIR" "$RECORD"; then
      printf 'registered: %s\n' "$DIR"
      exit 0
    fi
    ( umask 077; printf '%s\n' "$DIR" >> "$RECORD" ) || exit 1
    printf 'registered: %s\n' "$DIR"
    ;;
  list)
    [ "$#" -eq 2 ] || usage
    [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || exit 0
    while IFS= read -r DIR || [ -n "$DIR" ]; do
      [ -n "$DIR" ] || continue
      [ -e "$DIR" ] || [ -L "$DIR" ] || continue
      if reason=$(scratch_path_refusal "$DIR" 2>&1); then
        printf '%s\n' "$DIR"
      else
        echo "warning: skipping recorded scratch directory $DIR for $ID: $reason" >&2
      fi
    done < "$RECORD"
    ;;
  *) usage ;;
esac
