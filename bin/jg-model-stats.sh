#!/usr/bin/env bash
# jg-model-stats.sh - thin shim for the fleet per-model statistics reader, which lives in juggernaut-addons.
#
# The reader moved to the juggernaut-addons repository (fleet-stats/bin/jg-model-stats.sh,
# importing jg_stats_lib from that same folder); this shim only resolves that
# checkout and execs it with JG_BIN pointing at this fork's bin/, the same
# contract as the jg-dashboard.sh shim.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
[ ! -r "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh" ] || . "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh"
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOME_DIR="${JG_HOME:-$CODE_ROOT}"
ADDONS_DIR="${JG_ADDONS_DIR:-$HOME_DIR/projects/juggernaut-addons}"
TARGET="$ADDONS_DIR/fleet-stats/bin/jg-model-stats.sh"
if [ ! -f "$TARGET" ]; then
  echo "jg-model-stats: juggernaut-addons checkout not found (set JG_ADDONS_DIR): looked for $TARGET" >&2
  exit 1
fi
JG_BIN="$SCRIPT_DIR" JG_HOME="$HOME_DIR" exec "$TARGET" "$@"
