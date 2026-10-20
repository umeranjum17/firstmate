#!/usr/bin/env bash
# Turn on the owner rules in one firstmate home: write config/owner-rules, which brief-inherit's
# brief seam reads. Idempotent. Usage: install.sh [--dry-run] <fm-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1/config" ] || { echo "usage: install.sh [--dry-run] <fm-home>" >&2; exit 2; }
f=$(cd "$1" && pwd -P)/config/owner-rules
if [ "$DRY" -eq 1 ]; then echo "would write: $f"; echo "dry run: nothing written"; exit 0; fi
printf '%s\n' 'owner-rules add-on installed: brief-inherit runs owner-rules/bin/fm-owner-rules-lib.sh at brief creation' > "$f"
