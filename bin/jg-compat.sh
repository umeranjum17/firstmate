#!/usr/bin/env bash
# jg-compat.sh - the rename's single compatibility layer (slice S1).
#
# SHIM, deleted by slice S10 together with every caller's source line, every
# bin/fm-*.sh alias, and the legacy readers below. Nothing new may depend on it.
#
# It exists so one fleet can be half-migrated safely:
#   1. environment - an old FM_* name still resolves where the new JG_* name is
#      unset, so a shell profile, a systemd unit, a pane, or a generated
#      per-lane extension that still exports the old names keeps working.
#      Sourcing this file runs that pass; it is idempotent.
#   2. the add-ons checkout - a home that has not migrated still keeps its
#      add-on clones under projects/firstmate-addons. jg_compat_addons_dir
#      names whichever of the two directories exists.
#   3. record readers - schema ids, endpoint labels, the operational input
#      marker and the second-mate home marker accept the old spelling while
#      homes are migrated. Each helper names the exact legacy value it accepts,
#      so an old spelling can never be inferred from a new one that merely
#      looks similar.
#
# Sourced by every bin/ script immediately after its shebang. It must stay
# bash 3.2 compatible (macOS stock bash runs it) and safe under set -eu.

# --- 1. environment aliases -------------------------------------------------
# The old prefix still wins only where the new name is unset, so a migrated
# home that exports JG_* is never overridden by a stale FM_* in the environment.
jg_compat_env_aliases() {
  local old new value
  for old in $(compgen -v FM_ 2>/dev/null || true); do
    new="JG_${old#FM_}"
    eval "[ -n \"\${$new+set}\" ]" && continue
    eval "value=\${$old}"
    export "$new=$value"
  done
  return 0
}
jg_compat_env_aliases
unset -f jg_compat_env_aliases

# --- 2. the add-ons checkout ------------------------------------------------
# <root> is the home whose projects/ directory holds the add-on clones. Prints
# the new directory when it exists, the pre-rename one when only that exists,
# and the new path otherwise (so an error still names the expected location).
jg_compat_addons_dir() {  # <root>
  local root=${1:-} new old
  [ -n "$root" ] || return 0
  new="$root/projects/juggernaut-addons"
  old="$root/projects/firstmate-addons"
  if [ -d "$new" ]; then
    printf '%s\n' "$new"
  elif [ -d "$old" ]; then
    printf '%s\n' "$old"
  else
    printf '%s\n' "$new"
  fi
}

# --- 3. record readers ------------------------------------------------------
# <actual> <current> [<legacy>...]: true when a live record carries the current
# spelling or one of the legacy spellings it replaced. Callers pass the legacy
# value explicitly, so migration is a list, never a guess.
jg_compat_record_ok() {
  local actual=${1-} current=${2-} legacy
  shift 2 || true
  [ "$actual" = "$current" ] && return 0
  for legacy in "$@"; do
    [ -n "$legacy" ] && [ "$actual" = "$legacy" ] && return 0
  done
  return 1
}

# Endpoint and workspace labels: fm-<task-id> was the pre-rename form of
# jg-<task-id>. Both are live at once while panes and journals outlive the
# update, so a matcher must accept either spelling of the same task.
jg_compat_label_ok() {  # <actual> <expected>
  local actual=${1-} expected=${2-}
  [ -n "$actual" ] && [ -n "$expected" ] || return 1
  [ "$actual" = "$expected" ] && return 0
  case "$expected" in
  jg-*) [ "$actual" = "fm-${expected#jg-}" ] && return 0 ;;
  esac
  case "$actual" in
  jg-*) [ "$expected" = "fm-${actual#jg-}" ] && return 0 ;;
  esac
  return 1
}

# The operational-input marker was "\u2063FIRSTMATE_OP: ". A supervisor and a
# worker can be on different sides of the update for a while, so both markers
# are recognised; the new spelling is written from now on.
jg_compat_marker_ok() {  # <marker-text>
  case "${1-}" in
  JUGGERNAUT_OP | FIRSTMATE_OP) return 0 ;;
  esac
  return 1
}

# The second-mate home marker files and their schema line. A home that has not
# been migrated still carries the old names, so readers try both.
jg_compat_home_marker_paths() {  # <home>
  printf '%s\n' "$1/.jg-squad-lead-home" "$1/.fm-secondmate-home"
}

jg_compat_parent_marker_paths() {  # <home>
  printf '%s\n' "$1/.jg-squad-lead-parent" "$1/.fm-secondmate-parent"
}
