#!/usr/bin/env bash
# jg-role.sh - report and check this home's juggernaut role.
#
# Usage:
#   bin/jg-role.sh report
#   bin/jg-role.sh check <project-dir> [upstream-consent <scope>]
#
#   report   prints one line: jg-role: <user|maintainer> [<scope>] (<source>)
#            and, when a malformed or unverified input forced a closed result,
#            " - <narrow reason>". The default with no config is plain
#            "jg-role: user (default)". bin/jg-session-start.sh emits this line in the
#            startup digest; it makes no network or gh call.
#
#   check    evaluates the self-repository publication gate for a task whose
#            project is <project-dir>: exits 0 and prints
#            "authorized: <authority>" when this home may run a publication
#            contract there, exits 1 and prints "refused: <reason>" when it may
#            not, and exits 2 with "not a self-repository task" when the task
#            project is not juggernaut's own repository (the boundary does not
#            apply). The optional `upstream-consent <scope>` argument is the
#            recorded per-task consent a dispatcher captured.
#
# bin/jg-role-lib.sh owns the schema summary and mechanics;
# docs/configuration.md "Juggernaut role" owns the operator-facing schema.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
[ ! -r "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh" ] || . "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh"
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"

# shellcheck source=bin/jg-role-lib.sh
. "$SCRIPT_DIR/jg-role-lib.sh"

case ${1:-} in
report)
  jg_role_resolve "$JG_HOME" "$CONFIG"
  line="jg-role: $JG_ROLE"
  [ -z "$JG_ROLE_SCOPE" ] || line="$line $JG_ROLE_SCOPE"
  case $JG_ROLE_SOURCE in
  local) line="$line (local)" ;;
  inherited) line="$line (inherited)" ;;
  absent)
    if [ -z "$JG_ROLE_DIAG" ]; then
      line="$line (default)"
    fi
    ;;
  esac
  [ -z "$JG_ROLE_DIAG" ] || line="$line - $JG_ROLE_DIAG"
  printf '%s\n' "$line"
  ;;
check)
  proj=${2:-}
  [ -n "$proj" ] || {
    echo "usage: bin/jg-role.sh check <project-dir> [upstream-consent <scope>]" >&2
    exit 1
  }
  consent=
  if [ "${3:-}" = upstream-consent ]; then
    consent=${4:-}
  fi
  if jg_role_gate_self_publish "$JG_HOME" "$CONFIG" "$proj" "$JG_ROOT" "$consent"; then
    printf 'authorized: %s\n' "$JG_ROLE_PUB_AUTHORITY"
    exit 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 2 ]; then
    printf 'not a self-repository task\n'
    exit 2
  fi
  printf 'refused: %s\n' "$JG_ROLE_PUB_DENIAL"
  exit 1
  ;;
-h | --help | help)
  sed -n '3,25p' "$0"
  ;;
*)
  sed -n '3,25p' "$0" >&2
  exit 1
  ;;
esac
