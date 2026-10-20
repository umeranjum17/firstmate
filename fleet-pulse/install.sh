#!/usr/bin/env bash
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] || { echo 'usage: install.sh [--dry-run] <home>' >&2; exit 2; }
home=$(cd "$1" && pwd -P)
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/bin/chat-tsv.py
dest=$home/bin/chat-tsv.py
if [ "$DRY" -eq 1 ]; then echo "would install $src -> $dest"; exit 0; fi
mkdir -p "$home/bin"
install -m 755 "$src" "$dest"
echo "installed: $dest (schedule it periodically with FM_HOME=$home)"
