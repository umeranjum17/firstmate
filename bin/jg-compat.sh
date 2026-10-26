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
  local old new
  for old in $(compgen -v FM_ 2>/dev/null || true); do
    new="JG_${old#FM_}"
    declare -p "$new" >/dev/null 2>&1 && continue
    export "$new=${!old}"
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

# The squad-lead home marker files and their schema line. A home that has not
# been migrated still carries the old names, so every reader and writer asks
# for the path rather than assuming the new spelling.
jg_compat_marker() {  # <home>
  local home=${1-} new old
  [ -n "$home" ] || return 0
  new="$home/.jg-squad-lead-home"
  old="$home/.fm-secondmate-home"
  if [ ! -e "$new" ] && [ -e "$old" ]; then printf '%s\n' "$old"; else printf '%s\n' "$new"; fi
}

jg_compat_parent_marker() {  # <home>
  local home=${1-} new old
  [ -n "$home" ] || return 0
  new="$home/.jg-squad-lead-parent"
  old="$home/.fm-secondmate-parent"
  if [ ! -e "$new" ] && [ -e "$old" ]; then printf '%s\n' "$old"; else printf '%s\n' "$new"; fi
}

# The pre-rename spelling of a current identifier, derived from it rather than
# listed: jg- becomes fm-, and a nested-supervisor word becomes its old word.
# Readers use it to accept a record written before the rename.
jg_compat_legacy_of() {  # <current spelling>
  local value=${1-}
  value=${value/#jg-/fm-}
  value=${value//squad-lead/secondmate}
  printf '%s\n' "$value"
}

# The same text with the product token in its pre-rename spelling. The
# operational-input marker is the one wire value a supervisor and a worker can
# be on opposite sides of mid-update, so its reader accepts both spellings.
jg_compat_legacy_product() {  # <text>
  local legacy=FIRSTMATE
  printf '%s\n' "${1//JUGGERNAUT/$legacy}"
}

# The XDG claims root for process-event sources: prefer the directory a home
# already uses, so a claim registered before the rename is still found and the
# same source is never armed twice under two roots.
jg_compat_claims_root() {  # <new-root>
  local new=${1-} old
  [ -n "$new" ] || return 0
  old=${new//\/juggernaut\//\/firstmate\/}
  if [ ! -d "$new" ] && [ -d "$old" ]; then printf '%s\n' "$old"; else printf '%s\n' "$new"; fi
}

# The add-ons checkout a home already has. Exported here so every caller's
# ${JG_ADDONS_DIR:-<home>/projects/juggernaut-addons} default resolves to the
# directory that exists, without touching each of the 23 call sites.
if [ -z "${JG_ADDONS_DIR-}" ]; then
  _jg_addons_root=${JG_HOME:-$(cd "${BASH_SOURCE[0]%/*}/.." 2>/dev/null && pwd)}
  if [ -n "${_jg_addons_root-}" ] && [ -d "$_jg_addons_root/projects/firstmate-addons" ] \
    && [ ! -d "$_jg_addons_root/projects/juggernaut-addons" ]; then
    JG_ADDONS_DIR="$_jg_addons_root/projects/firstmate-addons"
    export JG_ADDONS_DIR
  fi
  unset _jg_addons_root
fi
