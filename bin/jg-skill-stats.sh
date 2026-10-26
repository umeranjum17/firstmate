#!/usr/bin/env bash
# jg-skill-stats.sh - thin shim for the fleet per-skill statistics reader, which lives in juggernaut-addons.
#
# The reader moved to the juggernaut-addons repository (fleet-stats/bin/jg-skill-stats.sh,
# importing jg_stats_lib from that same folder); this shim only resolves that
# checkout and execs it with JG_BIN pointing at this fork's bin/, the same
# contract as the jg-dashboard.sh shim.
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
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOME_DIR="${JG_HOME:-$CODE_ROOT}"
ADDONS_DIR="${JG_ADDONS_DIR:-$HOME_DIR/projects/juggernaut-addons}"
TARGET="$ADDONS_DIR/fleet-stats/bin/jg-skill-stats.sh"
if [ ! -f "$TARGET" ]; then
  echo "jg-skill-stats: juggernaut-addons checkout not found (set JG_ADDONS_DIR): looked for $TARGET" >&2
  exit 1
fi
JG_BIN="$SCRIPT_DIR" JG_HOME="$HOME_DIR" exec "$TARGET" "$@"
