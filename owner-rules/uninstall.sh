#!/usr/bin/env bash
# Turn the owner rules off in one firstmate home. Usage: uninstall.sh [--dry-run] <fm-home>
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'usage: uninstall.sh [--dry-run] <fm-home>' >&2; exit 2; }
f=$(cd "$1" && pwd -P)/config/owner-rules
[ ! -e "$f" ] || { echo "remove: $f"; [ "$DRY" -eq 1 ] || rm -f -- "$f"; }
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
