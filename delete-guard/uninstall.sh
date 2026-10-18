#!/usr/bin/env bash
# Remove delete-guard's installed adapters, registered check, and Claude hook. Usage: uninstall.sh [--dry-run] <fm-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: uninstall.sh [--dry-run] <fm-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-delete-guard
SETTINGS=$HOME/.claude/settings.json
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
if [ -s "$SETTINGS" ] && jq -e '[.hooks.PreToolUse[]?.hooks[]? | (.command // "") | select(contains("fm-delete-guard/guard.mjs"))] | length > 0' "$SETTINGS" >/dev/null; then
  jq '.hooks.PreToolUse = ([.hooks.PreToolUse[]? | .hooks |= map(select((.command // "") | contains("fm-delete-guard/guard.mjs") | not)) | select(.hooks | length > 0)])' "$SETTINGS" > "$TMP/settings.json"
  if ! cmp -s "$SETTINGS" "$TMP/settings.json"; then
    echo "update: $SETTINGS"
    if [ "$DRY" -eq 0 ]; then
      stamp=$(date +%s); cp -p "$SETTINGS" "$SETTINGS.bak-delete-guard-$stamp"
      mv "$TMP/settings.json" "$SETTINGS"
    fi
  fi
fi
for f in "$HOME/.pi/agent/extensions/fm-rm-guard.ts" "$HOME/.config/opencode/plugins/fm-delete-guard.js" "$FMH/state/delete-guard.check.sh"; do
  [ ! -e "$f" ] || { echo "remove: $f"; [ "$DRY" -eq 1 ] || rm -f -- "$f"; }
done
if [ -e "$FMH/state/delete-guard.check-trust" ]; then echo "remove: $FMH/state/delete-guard.check-trust"; [ "$DRY" -eq 1 ] || rm -f -- "$FMH/state/delete-guard.check-trust"; fi
if [ -x "$FMH/bin/fm-check-unregister.sh" ]; then [ "$DRY" -eq 1 ] || env -u FM_STATE_OVERRIDE FM_HOME="$FMH" "$FMH/bin/fm-check-unregister.sh" delete-guard; fi
for f in guard.mjs check.sh home; do [ ! -e "$DEST/$f" ] || { echo "remove: $DEST/$f"; [ "$DRY" -eq 1 ] || rm -f -- "$DEST/$f"; }; done
[ "$DRY" -eq 1 ] || rmdir "$DEST" 2>/dev/null || true
[ "$DRY" -eq 0 ] || echo "dry run: nothing written"
