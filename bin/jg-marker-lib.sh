#!/usr/bin/env bash
# jg-marker-lib.sh - compatibility entry point for from-juggernaut routing.
#
# bin/jg-operational-input.sh owns current operational-input construction,
# parsing, marker bytes, and the established from-juggernaut compatibility
# carrier. Existing callers source this path so they do not need a flag-day
# migration. No side effects on source. set -u / set -e safe.

_JG_MARKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-operational-input.sh
. "$_JG_MARKER_LIB_DIR/jg-operational-input.sh"
unset _JG_MARKER_LIB_DIR

# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  for _jg_f in legacy_of legacy_product record_ok label_ok marker parent_marker claims_root; do
    eval "jg_compat_$_jg_f() { return 1; }"
  done
  unset _jg_f
fi
unset _jg_d
