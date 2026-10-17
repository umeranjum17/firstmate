#!/usr/bin/env bash
# Install or update the owner-details guard: copy owner-guard to
# ${XDG_DATA_HOME:-~/.local/share}/fm-owner-guard, record the home, keep the
# home's config/owner-details-patterns private (mode 600, never created
# and never overwritten), chain pre-commit and pre-push through the
# git-identity hooks dir, and point the user's global core.hooksPath at the
# guard's own hooks dir so plain-shell commits and pushes are checked too
# (every wrapper then chains the previous global hooks dir and the
# repository's own hook). Idempotent; never touches repo-local
# core.hooksPath. Usage: install.sh [--dry-run] <fm-home> |
# install.sh --uninstall [<fm-home>]
set -euo pipefail
DRY=0 UNINST=0
while [ "$#" -gt 0 ]; do
  case "$1" in
  --dry-run) DRY=1; shift ;;
  --uninstall) UNINST=1; shift ;;
  *) break ;;
  esac
done
if [ "$UNINST" -eq 0 ]; then
  [ "$#" -eq 1 ] && [ -d "$1/config" ] || { echo "usage: install.sh [--dry-run] <fm-home> | install.sh --uninstall [<fm-home>]" >&2; exit 2; }
  FMH=$(cd "$1" && pwd -P)
elif [ "$#" -gt 1 ]; then
  echo "usage: install.sh [--dry-run] <fm-home> | install.sh --uninstall [<fm-home>]" >&2; exit 2
fi
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-owner-guard
GDEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-git-identity
GHOOKS=$DEST/hooks
PREVF=$DEST/prev-hooks-path
# Same client-side hook names git-identity chains: this dir becomes the
# hooks dir git consults, so a missing name would skip the repo's own hook.
HOOK_NAMES='applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg
post-commit pre-rebase post-checkout post-merge pre-push post-rewrite pre-auto-gc sendemail-validate'
CURGLOBAL=$(git config --global --get --type=path core.hooksPath 2>/dev/null || true)

install_global() { # Write one wrapper per hook name; adopt the global hooksPath, keeping the old value chained.
  mkdir -p "$GHOOKS"
  # shellcheck disable=SC2086
  for name in $HOOK_NAMES; do
    sed "s/__NAME__/$name/g" "$SRC/global-hook.sh" >"$GHOOKS/$name"
    chmod 755 "$GHOOKS/$name"
  done
  if [ "$CURGLOBAL" = "$GHOOKS" ]; then
    echo "kept: global core.hooksPath already $GHOOKS"
  else
    if [ -n "$CURGLOBAL" ]; then
      printf '%s\n' "$CURGLOBAL" >"$PREVF"
      echo "kept: previous global core.hooksPath recorded ($CURGLOBAL)"
    else
      rm -f "$PREVF"
    fi
    git config --global core.hooksPath "$GHOOKS"
    echo "installed: global core.hooksPath=$GHOOKS"
  fi
}

uninstall_global() { # Drop our wrappers; give the global hooksPath back to the recorded previous value.
  if [ "$CURGLOBAL" = "$GHOOKS" ]; then
    if [ -s "$PREVF" ]; then
      git config --global core.hooksPath "$(cat "$PREVF")"
      echo "restored: global core.hooksPath=$(cat "$PREVF")"
    else
      git config --global --unset core.hooksPath
      echo "restored: global core.hooksPath unset (nothing before)"
    fi
  else
    echo "kept: global core.hooksPath is not ours (${CURGLOBAL:-unset}); leaving it"
  fi
  # shellcheck disable=SC2086
  for name in $HOOK_NAMES; do rm -f "$GHOOKS/$name"; done
  rmdir "$GHOOKS" 2>/dev/null || true
  rm -f "$PREVF"
  echo "uninstalled: global guard hooks removed"
}

if [ "$UNINST" -eq 1 ]; then
  if [ "$DRY" -eq 1 ]; then
  if [ "$CURGLOBAL" = "$GHOOKS" ]; then
    if [ -s "$PREVF" ]; then
      echo "would restore: global core.hooksPath to $(cat "$PREVF")"
    else
      echo "would unset: global core.hooksPath (nothing before)"
    fi
  else
    echo "would keep: global core.hooksPath (${CURGLOBAL:-unset}, not ours)"
  fi
    echo "would remove: $GHOOKS/<name> wrappers and $PREVF"
    echo "dry run: nothing written"
    exit 0
  fi
  uninstall_global
  exit 0
fi
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
  echo "would write: $GHOOKS/<name>, one wrapper each: $HOOK_NAMES"
  echo "would set: global core.hooksPath=$GHOOKS (previous: ${CURGLOBAL:-none})"
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
install_global
