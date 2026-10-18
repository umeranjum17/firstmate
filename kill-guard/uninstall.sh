#!/usr/bin/env bash
# Remove the fleet kill guard: only its PreToolUse hook from ~/.claude/settings.json (backed up first), then the
# installed rule, the pi and OpenCode adapters and the pi adapter's disabled/ copy. Idempotent. Usage: uninstall.sh [--dry-run]
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: uninstall.sh [--dry-run]" >&2; exit 2; }
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-kill-guard
SETTINGS=$HOME/.claude/settings.json
STAMP=$(date +%s)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

if [ -s "$SETTINGS" ] && jq -e '[.hooks.PreToolUse[]?.hooks[]? | (.command // "") | select(contains("fm-kill-guard/guard.mjs"))] | length > 0' "$SETTINGS" >/dev/null; then
  jq '.hooks.PreToolUse = [.hooks.PreToolUse[] | .hooks |= map(select((.command // "") | contains("fm-kill-guard/guard.mjs") | not)) | select(.hooks | length > 0)]' \
    "$SETTINGS" > "$TMP/settings.json"
  diff -u --label "$SETTINGS (before)" --label "$SETTINGS (after)" "$SETTINGS" "$TMP/settings.json" || true
  if [ "$DRY" -eq 0 ]; then
    cp -p "$SETTINGS" "$SETTINGS.bak-kill-guard-$STAMP"
    cat "$TMP/settings.json" > "$SETTINGS.tmp-$STAMP" && mv "$SETTINGS.tmp-$STAMP" "$SETTINGS"
  fi
fi

for f in "$DEST/guard.mjs" "$DEST/disabled/fm-kill-guard.ts" "$HOME/.pi/agent/extensions/fm-kill-guard.ts" "$HOME/.config/opencode/plugins/fm-kill-guard.js"; do
  if [ -e "$f" ]; then
    echo "remove: $f"
    [ "$DRY" -eq 1 ] || rm -f -- "$f"
  fi
done
[ "$DRY" -eq 1 ] || { rmdir "$DEST/disabled" 2>/dev/null || true; rmdir "$DEST" 2>/dev/null || true; }
[ "$DRY" -eq 0 ] || echo "dry run: nothing written"
