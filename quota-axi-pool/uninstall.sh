#!/usr/bin/env bash
# Remove PATH link and share dir files. Usage: uninstall.sh [--dry-run]
set -euo pipefail
dry=0; [ "${1:-}" = --dry-run ] && dry=1
dest_dir=${XDG_DATA_HOME:-$HOME/.local/share}/fm-quota-axi-pool
dest=$dest_dir/quota-axi-pool; link=$HOME/.local/bin/quota-axi; upstream_file=$dest_dir/upstream
real=; [ -r "$upstream_file" ] && real=$(head -n 1 "$upstream_file")
if [ "$dry" = 1 ]; then echo "dry-run: remove $link and $dest_dir"; exit 0; fi
if [ -L "$link" ]; then
  target=$(readlink -f "$link" 2>/dev/null || true)
  dest_real=$(readlink -f "$dest" 2>/dev/null || true)
  [ "$target" = "$dest_real" ] && rm -f -- "$link"
fi
[ -d "$dest_dir" ] && { rm -f -- "$dest" "$upstream_file"; rmdir -- "$dest_dir" 2>/dev/null || true; }
echo "uninstalled quota-axi-pool from $link"
[ -n "$real" ] && [ -x "$real" ] && echo "upstream remains at $real"
