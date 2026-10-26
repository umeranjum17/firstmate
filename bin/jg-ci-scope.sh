#!/usr/bin/env bash
# jg-ci-scope.sh - the single owner of CI path scoping.
#
# Reads changed repository paths on stdin, as `git diff --name-only` prints
# them, and prints `behavior=true|false` for a workflow to append to
# $GITHUB_OUTPUT: true when the lint and behavior lanes are needed.
#
#   git diff --name-only <base> <head> | jg-ci-scope.sh
#   jg-ci-scope.sh --full    # a main push, or a diff CI could not read
#
# The classification is an allowlist of paths that cannot change executable
# behavior; everything else, including any path this script does not recognize,
# needs the full suite. Cheap paths
# are media assets anywhere, top-level markdown other than AGENTS.md and
# CLAUDE.md, LICENSE/NOTICE, and docs/ except its two executable subtrees
# (docs/examples/ fixtures, docs/supervision-protocols/ session instructions).
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
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }'
fi
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# True when one path cannot change executable behavior.
jg_ci_scope_cheap_path() {
  local path=$1
  case $path in
    ''|/*|../*|*/../*|*/..) return 1 ;;
    *.png|*.jpg|*.jpeg|*.gif|*.svg|*.webp|*.avif|*.ico|*.bmp|*.mp4|*.webm|*.mov) return 0 ;;
    */*) ;;
    AGENTS.md|CLAUDE.md) return 1 ;;
    *.md|LICENSE|LICENSE.*|NOTICE) return 0 ;;
    *) return 1 ;;
  esac
  case $path in
    docs/examples/*|docs/supervision-protocols/*) return 1 ;;
    docs/*) return 0 ;;
  esac
  return 1
}

jg_ci_scope_main() {
  local seen=false cheap=true path line
  case ${1:-} in
    --full) printf 'behavior=true\n'; return 0 ;;
    -h|--help) sed -n '2,15{s/^# \{0,1\}//;p;}' "$SELF_DIR/jg-ci-scope.sh"; return 0 ;;
    '') ;;
    *) printf 'jg-ci-scope.sh: unknown argument %s\n' "$1" >&2; return 2 ;;
  esac
  while IFS= read -r line; do
    path=${line%$'\r'}
    [ -n "$path" ] || continue
    seen=true
    jg_ci_scope_cheap_path "$path" || cheap=false
  done
  # A change list CI could not read is not evidence of a harmless change.
  if [ "$seen" = true ] && [ "$cheap" = true ]; then
    printf 'behavior=false\n'
  else
    printf 'behavior=true\n'
  fi
}

jg_ci_scope_main "$@"
