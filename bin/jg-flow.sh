#!/usr/bin/env bash
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
. "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh"
# jg-flow.sh - thin shim for the fleet flow reader, which lives in firstmate-addons.
#
# The reader moved to the firstmate-addons repository (fleet-flow/bin/jg-flow.sh);
# this shim only resolves that checkout and execs it with JG_BIN pointing at
# this fork's bin/, so the add-on runs the fork's helper libraries. JG_HOME is
# passed through unchanged; the add-on script's header owns usage and output.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOME_DIR="${JG_HOME:-$CODE_ROOT}"
ADDONS_DIR="${JG_ADDONS_DIR:-$HOME_DIR/projects/firstmate-addons}"
TARGET="$ADDONS_DIR/fleet-flow/bin/jg-flow.sh"
if [ ! -f "$TARGET" ]; then
  echo "jg-flow: firstmate-addons checkout not found (set JG_ADDONS_DIR): looked for $TARGET" >&2
  exit 1
fi
JG_BIN="$SCRIPT_DIR" exec "$TARGET" "$@"
