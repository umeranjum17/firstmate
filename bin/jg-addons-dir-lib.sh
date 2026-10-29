#!/usr/bin/env bash
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
unset _jg_d
# jg-addons-dir-lib.sh - the one owner of where a checkout finds its add-ons.
#
# The add-ons live in this repository's tracked `addons/`. A home that predates that fold still carries the
# clone at `<home>/projects/juggernaut-addons`, so resolution is a chain, never one path:
#   1. `JG_ADDONS_DIR` when set: the operator override, and what every test fixture pins.
#   2. the in-repo `addons/` beside this checkout (this library's own parent directory).
#   3. the pre-fold clone, with `<home>` the caller's home argument, else `JG_HOME`, else this checkout.
# That order keeps a live home working before, during and after the move; callers pass the home they mean,
# because a squad_lead home resolves its own base.
#
# Sourced, not executed:  . "$SCRIPT_DIR/jg-addons-dir-lib.sh"; dir=$(jg_addons_dir "$JG_HOME")

_JG_ADDONS_LIB_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

jg_addons_dir() { # jg_addons_dir [home]: print the add-ons directory this checkout should use.
  if [ -n "${JG_ADDONS_DIR:-}" ]; then
    printf '%s\n' "$JG_ADDONS_DIR"
  elif [ -d "$_JG_ADDONS_LIB_ROOT/addons" ]; then
    printf '%s\n' "$_JG_ADDONS_LIB_ROOT/addons"
  else
    printf '%s\n' "${1:-${JG_HOME:-$_JG_ADDONS_LIB_ROOT}}/projects/juggernaut-addons"
  fi
}

jg_addon_trusted() { # jg_addon_trusted <path>: 0 unless the file resolves outside the checkout and is not ours-only-writable.
  # The in-repo addons/ is as trusted as bin/; the override and the pre-fold clone must be owned by the
  # current user and not group- or world-writable. An absent file passes: there is nothing to refuse.
  local p=$1
  case $p in "$_JG_ADDONS_LIB_ROOT/addons/"*) return 0 ;; esac
  [ -e "$p" ] || return 0
  [ -n "$(find -L "$p" -maxdepth 0 -user "$(id -u)" ! -perm -g=w ! -perm -o=w 2>/dev/null)" ]
}

jg_addon_path() { # jg_addon_path [home] <path inside the add-ons directory>: print one add-on file's path, or nothing when refused.
  local home=$1 path=$2 full
  full=$(jg_addons_dir "$home")/$path
  if jg_addon_trusted "$full"; then
    printf '%s\n' "$full"
  else
    echo "jg-addons: refusing $full: not owned by the current user or writable by group/others; treating the add-on as absent" >&2
  fi
  return 0
}
