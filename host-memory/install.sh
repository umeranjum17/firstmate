#!/usr/bin/env bash
# Install or update the memory gate for this user. Idempotent. Usage: install.sh [--dry-run]
# Main's config/fm-mem-gate.sh becomes a shim that execs the installed copy; this script never writes it.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: install.sh [--dry-run]" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/bin/fm-mem-gate.sh
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-host-memory/fm-mem-gate.sh
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
if cmp -s "$SRC" "$DEST"; then echo "unchanged: $DEST"
elif [ "$DRY" -eq 1 ]; then echo "would copy: $SRC -> $DEST"
else mkdir -p "${DEST%/*}"; install -m 755 "$SRC" "$DEST"; echo "copied: $SRC -> $DEST"
fi
for f in "$CONFIG/fm.slice.d/50-fm-heavy-weight.conf" "$CONFIG/fm-heavy.slice.d/50-fm-heavy-weight.conf"; do
  if [ -f "$f" ] && cmp -s "$f" <(printf '[Slice]\nCPUWeight=20\nIOWeight=20\n'); then echo "unchanged: $f"
  elif [ "$DRY" -eq 1 ]; then echo "would write: $f"
  else mkdir -p "${f%/*}"; printf '[Slice]\nCPUWeight=20\nIOWeight=20\n' >"$f"; echo "wrote: $f"; fi
done
if [ "$DRY" -eq 0 ]; then systemctl --user daemon-reload || { echo 'host-memory: systemctl --user daemon-reload failed' >&2; exit 1; }
else echo 'dry run: nothing written'; fi
