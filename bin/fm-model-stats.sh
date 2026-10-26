#!/usr/bin/env bash
# fm-model-stats.sh - thin shim for the fleet per-model statistics reader, which lives in this repository's addons/.
#
# The reader is the fleet-stats add-on (fleet-stats/bin/fm-model-stats.sh, importing
# fm_stats_lib from that same folder); this shim only resolves the add-ons
# directory and execs it with FM_BIN pointing at this fork's bin/, the same
# contract as the fm-dashboard.sh shim.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOME_DIR="${FM_HOME:-$CODE_ROOT}"
# shellcheck source=bin/fm-addons-dir-lib.sh
. "$SCRIPT_DIR/fm-addons-dir-lib.sh"
ADDONS_DIR=$(fm_addons_dir "$HOME_DIR")
TARGET="$ADDONS_DIR/fleet-stats/bin/fm-model-stats.sh"
if [ ! -f "$TARGET" ]; then
  echo "fm-model-stats: the add-ons are missing (set FM_ADDONS_DIR): looked for $TARGET" >&2
  exit 1
fi
FM_BIN="$SCRIPT_DIR" FM_HOME="$HOME_DIR" exec "$TARGET" "$@"
