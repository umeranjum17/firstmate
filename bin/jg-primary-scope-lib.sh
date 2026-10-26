#!/usr/bin/env bash
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
. "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh"
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine juggernaut primary home.
# This file is sourced by hook entrypoints and has no side effects on source.
# jg_primary_root_matches is split out so a caller can confirm primary-home
# identity before its gitignored state dir exists, such as to create it.

# Return 0 when $1 carries a genuine squad-lead-home marker.
jg_root_is_squad_lead_home() {
  local marker id LC_ALL=C
  marker=$(jg_compat_marker "$1") || return 1
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when $1 is a genuine primary root, regardless of whether its state
# dir exists yet. A valid squad_lead marker force-includes a linked squad_lead
# home. Otherwise only a plain checkout is primary, never a linked task
# worktree.
jg_primary_root_matches() {
  local root=$1 git_dir git_common_dir
  if ! jg_root_is_squad_lead_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
}

# Return 0 when $1 is a genuine primary root whose effective state dir $2
# already exists.
jg_primary_scope_matches() {
  local root=$1 state=$2
  jg_primary_root_matches "$root" && [ -d "$state" ]
}
