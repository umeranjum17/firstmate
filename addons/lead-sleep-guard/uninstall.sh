#!/usr/bin/env bash
# Remove the lead sleep guard: the installed rule and the OpenCode adapter. Idempotent. Usage: uninstall.sh [--dry-run]
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: uninstall.sh [--dry-run]" >&2; exit 2; }
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-lead-sleep-guard
for f in "$DEST/guard.mjs" "$HOME/.config/opencode/plugins/jg-lead-sleep-guard.js"; do
  if [ -e "$f" ]; then
    echo "remove: $f"
    [ "$DRY" -eq 1 ] || rm -f -- "$f"
  fi
done
[ "$DRY" -eq 1 ] || rmdir "$DEST" 2>/dev/null || true
[ "$DRY" -eq 0 ] || echo "dry run: nothing written"
