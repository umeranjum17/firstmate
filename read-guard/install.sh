#!/usr/bin/env bash
# Install the fleet read guard for Claude, pi and OpenCode. Usage: install.sh [--dry-run]
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: install.sh [--dry-run]" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-read-guard
TMP=$(mktemp -d); trap 'rm -rf -- "$TMP"' EXIT
put() {
  local target=$1 candidate=$2
  if [ -e "$target" ] && cmp -s "$target" "$candidate"; then echo "unchanged: $target"; return; fi
  [ "$DRY" -eq 0 ] || { echo "would write: $target"; return; }
  mkdir -p "$(dirname "$target")"; cp "$candidate" "$target.tmp"; mv "$target.tmp" "$target"
}
cp "$SRC/guard.mjs" "$TMP/guard.mjs"; put "$DEST/guard.mjs" "$TMP/guard.mjs"
for a in pi-extension.ts opencode-plugin.js; do sed "s|__GUARD__|$DEST/guard.mjs|" "$SRC/$a" > "$TMP/$a"; done
[ ! -d "$HOME/.pi/agent" ] || put "$HOME/.pi/agent/extensions/fm-read-guard.ts" "$TMP/pi-extension.ts"
[ ! -d "$HOME/.config/opencode" ] || put "$HOME/.config/opencode/plugins/fm-read-guard.js" "$TMP/opencode-plugin.js"
if [ -d "$HOME/.claude" ]; then
  { [ -s "$HOME/.claude/settings.json" ] && cat "$HOME/.claude/settings.json" || echo '{}'; } |
    jq --arg cmd "node '$DEST/guard.mjs'" '
      .hooks.PreToolUse = ([.hooks.PreToolUse[]? | .hooks |= map(select((.command // "") | contains("fm-read-guard/guard.mjs") | not)) | select(.hooks | length > 0)]
      + [{matcher: "Bash|Read|Grep|Glob", hooks: [{type: "command", command: $cmd, timeout: 10}]}])' > "$TMP/settings.json"
  put "$HOME/.claude/settings.json" "$TMP/settings.json"
fi
[ "$DRY" -eq 0 ] || echo "dry run: nothing written"
