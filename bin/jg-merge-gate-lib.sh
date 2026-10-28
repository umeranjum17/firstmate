#!/usr/bin/env bash
# Sourced merge adapters owned by core, so a home's config/merge-gate and
# config/post-merge are honoured whether or not any add-on is installed.
# Usage: . bin/jg-merge-gate-lib.sh
#
# Both are no-ops when the home has no such file. jg_dod_merge_gate runs
# config/merge-gate and refuses the merge when it exits nonzero; the two merge
# paths call it before every landing. jg_merge_post_hook runs config/post-merge
# after a recorded merge and never changes that merge's outcome. The merge-card
# add-on defines the same two functions for homes that install it; core owning a
# copy is what makes them fire without it. Callers supply jg_dod_meta_value;
# jg_run_timed and jg_timed_out come from bin/jg-timeout-lib.sh, sourced here.
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
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
set -u

# shellcheck source=bin/jg-timeout-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/jg-timeout-lib.sh"

jg_dod_merge_gate() {  # <config-dir> <home> <id> <meta> <candidate-head> <pr-url|->
  local gate=$1/merge-gate worktree out seconds=${JG_MERGE_GATE_TIMEOUT:-600} rc=0
  [ -e "$gate" ] || [ -L "$gate" ] || return 0
  [ -x "$gate" ] || { echo "merge refused: $gate is not executable"; return 1; }
  case $seconds in ''|0*|*[!0-9]*)
    echo "merge refused: JG_MERGE_GATE_TIMEOUT must be a positive number of seconds"; return 1 ;;
  esac
  worktree=$(jg_dod_meta_value "$4" worktree)
  out=$(jg_run_timed "$seconds" env JG_HOME="$2" "$gate" "$3" "${worktree:--}" "$5" "$6" 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  [ "$rc" -ne 0 ] || return 0
  if jg_timed_out "$rc"; then
    echo "merge refused: merge gate timed out after ${seconds}s or exited $rc"
    return 1
  fi
  echo "merge refused by config/merge-gate (exit $rc)"
  return 1
}

jg_merge_post_hook() {  # <config-dir> <home> <id> <meta> <head|-> <pr-url|->
  local hook=$1/post-merge worktree out rc=0 seconds=${JG_POST_MERGE_TIMEOUT:-120}
  [ -e "$hook" ] || [ -L "$hook" ] || return 0
  [ -x "$hook" ] || { echo "post-merge hook skipped: $hook is not executable"; return 0; }
  case $seconds in ''|0*|*[!0-9]*) seconds=120 ;; esac
  worktree=$(sed -n 's/^worktree=//p' "$4" 2>/dev/null | tail -1)
  out=$(jg_run_timed "$seconds" env JG_HOME="$2" "$hook" "$3" "${worktree:--}" "$5" "$6" 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || echo "post-merge hook failed (exit $rc); the merge stands"
  return 0
}
