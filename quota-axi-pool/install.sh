#!/usr/bin/env bash
# Install as ~/.local/bin/quota-axi; record prior quota-axi as upstream. Usage: install.sh [--dry-run]
set -euo pipefail
dry=0; [ "${1:-}" = --dry-run ] && dry=1
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/bin/quota-axi-pool
[ -f "$src" ] || { echo "install.sh: missing $src" >&2; exit 1; }
dest_dir=${XDG_DATA_HOME:-$HOME/.local/share}/fm-quota-axi-pool
dest=$dest_dir/quota-axi-pool; link=$HOME/.local/bin/quota-axi; upstream_file=$dest_dir/upstream
current=; command -v quota-axi >/dev/null 2>&1 && current=$(command -v quota-axi)
saved=; [ -r "$upstream_file" ] && saved=$(head -n 1 "$upstream_file")
real=
if [ -n "$current" ]; then
  cur_real=$(readlink -f "$current" 2>/dev/null || printf '%s\n' "$current")
  dest_real=$(readlink -f "$dest" 2>/dev/null || printf '%s\n' "$dest")
  if [ "$cur_real" = "$dest_real" ] || [ "$current" = "$link" ]; then real=${saved:-}; else real=$current; fi
fi
[ -n "$real" ] || real=${saved:-}
if [ "$dry" = 1 ]; then
  echo "dry-run: copy $src -> $dest; link $link; upstream=${real:-unset}"; exit 0
fi
mkdir -p "$dest_dir" "$(dirname "$link")"
install -m 755 "$src" "$dest"
[ -n "$real" ] && [ -x "$real" ] && printf '%s\n' "$real" >"$upstream_file"
ln -sfn "$dest" "$link"
echo "installed $dest; linked $link (upstream=${real:-unset})"
