#!/usr/bin/env bash
# Install or update the lead sleep guard (OpenCode adapter and rule only). Idempotent. Usage: install.sh [--dry-run]
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: install.sh [--dry-run]" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-lead-sleep-guard
STAMP=$(date +%s)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
put() {
  local target=$1 new=$2
  if [ -e "$target" ] && cmp -s "$target" "$new"; then echo "unchanged: $target"; return; fi
  if [ -e "$target" ]; then diff -u "$target" "$new" || true; else echo "new: $target"; fi
  [ "$DRY" -eq 0 ] || return 0
  mkdir -p "$(dirname "$target")"
  if [ -e "$target" ]; then cp -p "$target" "$target.bak-lead-sleep-guard-$STAMP"; fi
  cp "$new" "$target.tmp-$STAMP" && mv "$target.tmp-$STAMP" "$target"
}
put "$DEST/guard.mjs" "$SRC/guard.mjs"
if [ -d "$HOME/.config/opencode" ]; then
  sed "s|__GUARD__|$DEST/guard.mjs|" "$SRC/opencode-plugin.js" > "$TMP/opencode-plugin.js"
  put "$HOME/.config/opencode/plugins/jg-lead-sleep-guard.js" "$TMP/opencode-plugin.js"
else echo "skipped: opencode (not installed)"; fi
[ "$DRY" -eq 0 ] || echo "dry run: nothing written"
