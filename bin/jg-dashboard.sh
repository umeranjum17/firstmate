#!/usr/bin/env bash
# jg-dashboard.sh - thin shim for the fleet dashboard, which lives in juggernaut-addons.
#
# The dashboard moved to the juggernaut-addons repository
# (fleet-dashboard/jg-dashboard.sh plus its fleet-dashboard/jg-dashboard/ app);
# this shim only resolves that checkout and execs it with JG_BIN pointing at
# this fork's bin/, so the add-on runs the fork's helper scripts.
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
unset _jg_d
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOME_DIR="${JG_HOME:-$CODE_ROOT}"
ADDONS_DIR="${JG_ADDONS_DIR:-$HOME_DIR/projects/juggernaut-addons}"
TARGET="$ADDONS_DIR/fleet-dashboard/jg-dashboard.sh"
if [ ! -f "$TARGET" ]; then
  echo "jg-dashboard: juggernaut-addons checkout not found (set JG_ADDONS_DIR): looked for $TARGET" >&2
  exit 1
fi
JG_BIN="$SCRIPT_DIR" exec "$TARGET" "$@"
