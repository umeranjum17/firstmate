#!/usr/bin/env bash
# jg-flow.sh - thin shim for the fleet flow reader, which lives in this repository's addons/.
#
# The reader is the fleet-flow add-on (fleet-flow/bin/jg-flow.sh); this shim only
# resolves the add-ons directory and execs it with JG_BIN pointing at this fork's
# bin/, so the add-on runs the fork's helper libraries. JG_HOME is passed through
# unchanged; the add-on script's header owns usage and output.
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
# shellcheck source=bin/jg-addons-dir-lib.sh
. "$SCRIPT_DIR/jg-addons-dir-lib.sh"
ADDONS_DIR=$(jg_addons_dir "$HOME_DIR")
TARGET="$ADDONS_DIR/fleet-flow/bin/jg-flow.sh"
if [ ! -f "$TARGET" ]; then
  echo "jg-flow: the add-ons are missing (set JG_ADDONS_DIR): looked for $TARGET" >&2
  exit 1
fi
JG_BIN="$SCRIPT_DIR" exec "$TARGET" "$@"
