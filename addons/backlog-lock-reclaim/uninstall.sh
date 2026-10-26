#!/usr/bin/env bash
# Retire the backlog-lock-reclaim check from one firstmate home (its check and trust binding), then remove the installed
# copy. Idempotent. Usage: uninstall.sh <jg-home>
set -euo pipefail
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-unregister.sh" ] || { echo "usage: uninstall.sh <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-backlog-lock-reclaim
env -u FM_STATE_OVERRIDE FM_HOME="$FMH" "$FMH/bin/jg-check-unregister.sh" backlog-lock-reclaim
rm -f -- "$DEST/backlog-lock-reclaim.check.sh"
rmdir -- "$DEST" 2>/dev/null || true
echo "uninstalled: backlog-lock-reclaim from $FMH"
