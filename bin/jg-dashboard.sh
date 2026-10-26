#!/usr/bin/env bash
# jg-dashboard.sh - thin shim for the fleet dashboard, which lives in juggernaut-addons.
#
# The dashboard moved to the juggernaut-addons repository
# (fleet-dashboard/jg-dashboard.sh plus its fleet-dashboard/jg-dashboard/ app);
# this shim only resolves that checkout and execs it with JG_BIN pointing at
# this fork's bin/, so the add-on runs the fork's helper scripts.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
[ ! -r "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh" ] || . "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh"
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
