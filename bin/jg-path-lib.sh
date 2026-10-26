#!/usr/bin/env bash
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
. "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh"
# jg-path-lib.sh - fork-free pathname helpers with no source-time side effects,
# so read-only callers can load them without any library's state setup.
#
# Each assigns <output-variable> exactly what `$(dirname -- <path>)` or
# `$(basename -- <path>)` would: POSIX component rules, and the command
# substitution's removal of trailing newlines.

jg_dirname_to() {  # <output-variable> <path>
  local jg_path=$2
  case "$jg_path" in
    '') jg_path=. ;;
    *[!/]*)
      jg_path=${jg_path%"${jg_path##*[!/]}"}
      case "$jg_path" in
        */*)
          jg_path=${jg_path%/*}
          jg_path=${jg_path%"${jg_path##*[!/]}"}
          [ -n "$jg_path" ] || jg_path=/
          ;;
        *) jg_path=. ;;
      esac
      ;;
    *) jg_path=/ ;;
  esac
  while [ "${jg_path%$'\n'}" != "$jg_path" ]; do jg_path=${jg_path%$'\n'}; done
  printf -v "$1" '%s' "$jg_path"
}

jg_basename_to() {  # <output-variable> <path>
  local jg_path=$2
  case "$jg_path" in
    '') ;;
    *[!/]*) jg_path=${jg_path%"${jg_path##*[!/]}"}; jg_path=${jg_path##*/} ;;
    *) jg_path=/ ;;
  esac
  while [ "${jg_path%$'\n'}" != "$jg_path" ]; do jg_path=${jg_path%$'\n'}; done
  printf -v "$1" '%s' "$jg_path"
}
