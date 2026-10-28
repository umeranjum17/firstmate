#!/usr/bin/env bash
# fm-ci-scope.sh - the single owner of CI path scoping.
#
# Reads changed repository paths on stdin, as `git diff --name-only` prints
# them, and prints `behavior=true|false` for a workflow to append to
# $GITHUB_OUTPUT: true when the lint and behavior lanes are needed.
#
#   git diff --name-only <base> <head> | fm-ci-scope.sh
#   fm-ci-scope.sh --full    # a diff CI could not read
#
# The classification is an allowlist of paths that cannot change executable
# behavior; everything else, including any path this script does not recognize,
# needs the full suite. Cheap paths
# are media assets anywhere, top-level markdown other than AGENTS.md and
# CLAUDE.md, LICENSE/NOTICE, and docs/ except its two executable subtrees
# (docs/examples/ fixtures, docs/supervision-protocols/ session instructions).
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# True when one path cannot change executable behavior.
fm_ci_scope_cheap_path() {
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

fm_ci_scope_main() {
  local seen=false cheap=true path line
  case ${1:-} in
    --full) printf 'behavior=true\n'; return 0 ;;
    -h|--help) sed -n '2,15{s/^# \{0,1\}//;p;}' "$SELF_DIR/fm-ci-scope.sh"; return 0 ;;
    '') ;;
    *) printf 'fm-ci-scope.sh: unknown argument %s\n' "$1" >&2; return 2 ;;
  esac
  while IFS= read -r line; do
    path=${line%$'\r'}
    [ -n "$path" ] || continue
    seen=true
    fm_ci_scope_cheap_path "$path" || cheap=false
  done
  # A change list CI could not read is not evidence of a harmless change.
  if [ "$seen" = true ] && [ "$cheap" = true ]; then
    printf 'behavior=false\n'
  else
    printf 'behavior=true\n'
  fi
}

fm_ci_scope_main "$@"
