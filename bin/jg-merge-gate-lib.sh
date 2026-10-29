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
# jg_dod_design_gate is the first-draft design-call gate both merge paths call:
# a task recorded design_call=yes (bin/jg-brief.sh --design-call) merges only when
# its completion receipt (state/<id>.run-receipt.json, the receipts add-on's record)
# binds the candidate head with verdict PASS and its evidence carries a
# `first-draft receipt: <ref>` line. design_call=no passes; a record with no
# design_call (an older task) warns and counts as no.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
# The hooks also get FM_HOME (the pre-rename name) because installed add-on hooks and done-done's merge-gate still read it; delete with the S10 shim.
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
  out=$(jg_run_timed "$seconds" env JG_HOME="$2" FM_HOME="$2" "$gate" "$3" "${worktree:--}" "$5" "$6" 2>&1) || rc=$?
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
  out=$(jg_run_timed "$seconds" env JG_HOME="$2" FM_HOME="$2" "$hook" "$3" "${worktree:--}" "$5" "$6" 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || echo "post-merge hook failed (exit $rc); the merge stands"
  return 0
}

jg_dod_design_gate() {  # <state> <id> <meta> <candidate-head>
  local state=$1 id=$2 meta=$3 head=$4 call receipt
  [ -n "$state" ] && [ -n "$id" ] && [ -f "$meta" ] || return 0
  call=$(jg_dod_meta_value "$meta" design_call)
  case $call in
    no) return 0 ;;
    '') echo "warning: $id has no design call recorded (an older brief); counting it as design_call=no" >&2; return 0 ;;
    yes) ;;
    *) echo "merge refused: design call for $id is malformed ('$call'); expected yes or no"; return 1 ;;
  esac
  receipt="$state/$id.run-receipt.json"
  if [ -f "$receipt" ] && [ ! -L "$receipt" ] && command -v jq >/dev/null 2>&1 \
    && jq -se --arg task "$id" --arg head "$head" '
      length == 1 and (.[0] | .task == $task and .head == $head and .verdict == "PASS" and
      (.evidence | type == "string" and test("(^|\n)first-draft receipt: [^[:space:]]")))
    ' "$receipt" >/dev/null 2>&1; then
    return 0
  fi
  echo "merge refused: $id is a design task (first-draft: yes) and its completion receipt for this head has no 'first-draft receipt: <ref>' evidence line; produce the design with first-draft and republish the receipt"
  return 1
}

# jg_dod_nav_gate is the no-silent-removal gate for a UI change (bin/jg-brief.sh
# --ui-change). A task recorded ui_change=yes merges only when its PR body (or, for a
# local-only landing, its commit messages) carries a `Nav before: a, b, c` line and a
# `Nav after: ...` line, and every item of before is still in after unless a
# `Removed by captain words: <quote>` line is present. ui_change=no passes; a record
# with no ui_change (an older task) warns and counts as no. A shell check decides.
jg_dod_nav_gate() {  # <id> <meta> <text>
  local id=$1 meta=$2 text=$3 call before after item removed=''
  [ -n "$id" ] && [ -f "$meta" ] || return 0
  call=$(jg_dod_meta_value "$meta" ui_change)
  case $call in
    no) return 0 ;;
    '') echo "warning: $id has no UI change recorded (an older brief); counting it as ui_change=no" >&2; return 0 ;;
    yes) ;;
    *) echo "merge refused: UI change for $id is malformed ('$call'); expected yes or no"; return 1 ;;
  esac
  _jg_nav_line() {  # <label>: the last `<label>: <value>` line of the text, value only
    printf '%s\n' "$text" | tr -d '\r' | sed -n -E "s/^[[:space:]]*([-*][[:space:]]+)?$1:[[:space:]]*(.*[^[:space:]])[[:space:]]*\$/\\2/Ip" | tail -1
  }
  before=$(_jg_nav_line 'Nav before'); after=$(_jg_nav_line 'Nav after')
  if [ -z "$before" ] || [ -z "$after" ]; then
    echo "merge refused: $id is a UI change and its PR body has no 'Nav before: <items>' and 'Nav after: <items>' lines listing the menus, tabs and screens"
    return 1
  fi
  _jg_nav_items() { printf '%s\n' "$1" | tr ';,' '\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | sed '/^$/d' | tr '[:upper:]' '[:lower:]'; }
  while IFS= read -r item; do
    _jg_nav_items "$after" | grep -qxF -- "$item" || removed="$removed${removed:+, }$item"
  done < <(_jg_nav_items "$before")
  [ -n "$removed" ] || return 0
  if [ -n "$(_jg_nav_line 'Removed by captain words')" ]; then return 0; fi
  echo "merge refused: $id is a UI change and its PR body drops from Nav before ($removed) with no 'Removed by captain words: <quote>' line; a UI change never removes an existing menu, tab or screen unless the captain's own words ask for it"
  return 1
}
