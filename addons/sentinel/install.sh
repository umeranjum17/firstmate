#!/usr/bin/env bash
# Install or update the sentinel for one firstmate home: copy bin/jg-sentinel.sh to the data dir and point the jg-sentinel user unit at that copy, restarting the service in the same step.
# Idempotent: rerun it to update. Usage: install.sh [--dry-run] <jg-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -f "$1/bin/jg-control.sh" ] || { echo "usage: install.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-sentinel
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
UNIT=$UNIT_DIR/jg-sentinel.service
STAMP=$(date +%s)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

# show <target> <candidate>: print the change; return 1 when target already matches.
show() {
  if [ ! -e "$1" ]; then echo "new: $1"
  elif cmp -s "$1" "$2"; then echo "unchanged: $1"; return 1
  else diff -u --label "$1 (before)" --label "$1 (after)" "$1" "$2" || true
  fi
}

# The unit is the copy's own `unit` output, re-pointed at the installed copy and this home.
FM_HOME="$FMH" "$SRC/bin/jg-sentinel.sh" unit | sed "s|$SRC/bin/jg-sentinel.sh|$DEST/bin/jg-sentinel.sh|" > "$TMP/unit"

copy_changed=0 unit_changed=0
show "$DEST/bin/jg-sentinel.sh" "$SRC/bin/jg-sentinel.sh" && copy_changed=1 || true
show "$UNIT" "$TMP/unit" && unit_changed=1 || true
if [ "$DRY" -eq 1 ]; then
  if [ $((copy_changed + unit_changed)) -eq 0 ]; then echo "dry run: already installed, nothing to change"
  else echo "dry run: nothing written; would restart jg-sentinel.service on $DEST/bin/jg-sentinel.sh"; fi
  exit 0
fi
[ $((copy_changed + unit_changed)) -gt 0 ] || { echo "already installed for $FMH; nothing to change"; exit 0; }

mkdir -p "$DEST/bin" "$UNIT_DIR"
cp "$SRC/bin/jg-sentinel.sh" "$DEST/bin/jg-sentinel.sh.tmp-$STAMP" && chmod 755 "$DEST/bin/jg-sentinel.sh.tmp-$STAMP"
mv "$DEST/bin/jg-sentinel.sh.tmp-$STAMP" "$DEST/bin/jg-sentinel.sh"
if [ "$unit_changed" -eq 1 ]; then
  # Record the unit as it was before the first install; uninstall restores it. A unit replaced later gets a timestamped backup.
  if [ ! -e "$DEST/unit.before" ] && [ ! -e "$DEST/unit.absent" ]; then
    if [ -e "$UNIT" ]; then cp -p "$UNIT" "$DEST/unit.before"; else : > "$DEST/unit.absent"; fi
  elif [ -e "$UNIT" ]; then
    cp -p "$UNIT" "$UNIT.bak-sentinel-addon-$STAMP"
  fi
  first=0
  [ -e "$UNIT" ] || first=1
  cat "$TMP/unit" > "$UNIT.tmp-$STAMP" && mv "$UNIT.tmp-$STAMP" "$UNIT"
fi
# Restart, never stop-then-start: the service is replaced in one step, so supervision never has a gap.
systemctl --user daemon-reload
[ "${first:-0}" -eq 0 ] || systemctl --user enable jg-sentinel.service
systemctl --user restart jg-sentinel.service
echo "installed: jg-sentinel for $FMH runs $DEST/bin/jg-sentinel.sh; jg-sentinel.service restarted"
