#!/usr/bin/env bash
# fm-flow.sh - thin shim for the fleet flow reader, which lives in this repository's addons/.
#
# The reader is the fleet-flow add-on (fleet-flow/bin/fm-flow.sh); this shim only
# resolves the add-ons directory and execs it with FM_BIN pointing at this fork's
# bin/, so the add-on runs the fork's helper libraries. FM_HOME is passed through
# unchanged; the add-on script's header owns usage and output.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOME_DIR="${FM_HOME:-$CODE_ROOT}"
# shellcheck source=bin/fm-addons-dir-lib.sh
. "$SCRIPT_DIR/fm-addons-dir-lib.sh"
ADDONS_DIR=$(fm_addons_dir "$HOME_DIR")
TARGET="$ADDONS_DIR/fleet-flow/bin/fm-flow.sh"
if [ ! -f "$TARGET" ]; then
  echo "fm-flow: the add-ons are missing (set FM_ADDONS_DIR): looked for $TARGET" >&2
  exit 1
fi
FM_BIN="$SCRIPT_DIR" exec "$TARGET" "$@"
