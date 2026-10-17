#!/usr/bin/env bash
# Install or update the owner-details guard: copy owner-guard to
# ${XDG_DATA_HOME:-~/.local/share}/fm-owner-guard, record the home, keep the
# home's config/owner-details-patterns private (mode 600, never created
# and never overwritten), and chain pre-commit and pre-push through the
# git-identity hooks dir. Idempotent. Usage: install.sh [--dry-run] <fm-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1/config" ] || { echo "usage: install.sh [--dry-run] <fm-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-owner-guard
GDEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-git-identity
PAT=$FMH/config/owner-details-patterns
REC=$(cat "$DEST/home" 2>/dev/null || true)
if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/owner-guard -> $DEST/owner-guard"
  [ -e "$PAT" ] || echo "would skip: $PAT is missing (the installer never creates it)"
  if [ ! -s "$PAT" ] && [ -n "$REC" ] && [ -s "$REC/config/owner-details-patterns" ]; then
    echo "would keep: $DEST/home (it already names a home with a patterns file this home lacks)"
  else
    echo "would write: $DEST/home ($FMH)"
  fi
  echo "would write: $GDEST/hooks.d/pre-commit/owner-guard $GDEST/hooks.d/pre-push/owner-guard"
  echo "dry run: nothing written"
  exit 0
fi
mkdir -p "$DEST"
install -m 755 "$SRC/owner-guard" "$DEST/owner-guard"
if [ -e "$PAT" ]; then
  chmod 600 "$PAT"
else
  echo "note: $PAT is missing; leaving it for the owner to create (one extended regex per line, mode 600)"
fi
if [ ! -s "$PAT" ] && [ -n "$REC" ] && [ -s "$REC/config/owner-details-patterns" ]; then
  echo "kept recorded patterns home: $FMH has no patterns file"
else
  printf '%s\n' "$FMH" >"$DEST/home"
fi
mkdir -p "$GDEST/hooks.d/pre-commit" "$GDEST/hooks.d/pre-push"
for name in pre-commit pre-push; do
  printf '#!/usr/bin/env bash\nexec %q %s "$@"\n' "$DEST/owner-guard" "$name" >"$GDEST/hooks.d/$name/owner-guard"
  chmod 755 "$GDEST/hooks.d/$name/owner-guard"
done
[ -d "$GDEST/hooks" ] || echo "note: $GDEST/hooks is missing (git-identity not installed); chaining activates when it installs"
echo "installed: $DEST/owner-guard chained into $GDEST/hooks.d (patterns: $PAT)"
