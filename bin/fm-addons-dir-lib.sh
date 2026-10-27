#!/usr/bin/env bash
# fm-addons-dir-lib.sh - the one owner of where a checkout finds its add-ons.
#
# The add-ons live in this repository's tracked `addons/`. A home that predates that fold still carries the
# clone at `<home>/projects/firstmate-addons`, so resolution is a chain, never one path:
#   1. `FM_ADDONS_DIR` when set: the operator override, and what every test fixture pins.
#   2. the in-repo `addons/` beside this checkout (this library's own parent directory).
#   3. the pre-fold clone, with `<home>` the caller's home argument, else `FM_HOME`, else this checkout.
# That order keeps a live home working before, during and after the move; callers pass the home they mean,
# because a secondmate home resolves its own base.
#
# Sourced, not executed:  . "$SCRIPT_DIR/fm-addons-dir-lib.sh"; dir=$(fm_addons_dir "$FM_HOME")

_FM_ADDONS_LIB_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

fm_addons_dir() { # fm_addons_dir [home]: print the add-ons directory this checkout should use.
  if [ -n "${FM_ADDONS_DIR:-}" ]; then
    printf '%s\n' "$FM_ADDONS_DIR"
  elif [ -d "$_FM_ADDONS_LIB_ROOT/addons" ]; then
    printf '%s\n' "$_FM_ADDONS_LIB_ROOT/addons"
  else
    printf '%s\n' "${1:-${FM_HOME:-$_FM_ADDONS_LIB_ROOT}}/projects/firstmate-addons"
  fi
}

fm_addon_path() { # fm_addon_path [home] <path inside the add-ons directory>: print one add-on file's path.
  local home=$1 path=$2
  printf '%s/%s\n' "$(fm_addons_dir "$home")" "$path"
}
