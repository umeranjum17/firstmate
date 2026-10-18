#!/usr/bin/env bash
# Remove only this guard's Claude hook and runtime adapters. Usage: uninstall.sh [--dry-run]
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: uninstall.sh [--dry-run]" >&2; exit 2; }
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-read-guard
if [ -s "$HOME/.claude/settings.json" ] && jq -e '[.hooks.PreToolUse[]?.hooks[]? | (.command // "") | select(contains("fm-read-guard/guard.mjs"))] | length > 0' "$HOME/.claude/settings.json" >/dev/null; then
  jq '.hooks.PreToolUse = [.hooks.PreToolUse[] | .hooks |= map(select((.command // "") | contains("fm-read-guard/guard.mjs") | not)) | select(.hooks | length > 0)]' "$HOME/.claude/settings.json" > "$HOME/.claude/settings.json.tmp"
  [ "$DRY" -eq 1 ] || mv "$HOME/.claude/settings.json.tmp" "$HOME/.claude/settings.json"
fi
for f in "$DEST/guard.mjs" "$HOME/.pi/agent/extensions/fm-read-guard.ts" "$HOME/.config/opencode/plugins/fm-read-guard.js"; do
  [ ! -e "$f" ] || { echo "remove: $f"; [ "$DRY" -eq 1 ] || rm -f -- "$f"; }
done
[ "$DRY" -eq 1 ] || rmdir "$DEST" 2>/dev/null || true
