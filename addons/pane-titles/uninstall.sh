#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  eval "[ -n \"\${$_jg_new+set}\" ]" && continue
  eval "_jg_val=\${_jg_old}"
  export "$_jg_new=$_jg_val"
done
unset _jg_old _jg_new _jg_val 2>/dev/null || true
# Remove pane titles and restore the launch-env hook this add-on chained. Usage: uninstall.sh [--dry-run] <jg-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1/config" ] || { echo 'usage: uninstall.sh [--dry-run] <jg-home>' >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-pane-titles
HOOK=$FMH/config/launch-env-hook
SHIM=$(printf '#!/usr/bin/env bash\nexport JG_PANE_TITLES_HOME=%q\nexec %q/launch-env-hook "$@"\n' "$DEST" "$DEST")
if [ ! -f "$HOOK" ] || [ "$(cat "$HOOK")" != "$SHIM" ]; then
  if [ ! -e "$DEST" ]; then echo 'already removed: readable pane titles'; exit 0; fi
  echo "uninstall.sh: preserving unrecognized hook at $HOOK" >&2; exit 1
fi
[ "$DRY" -eq 1 ] && { echo "would restore chained hook and remove $DEST"; exit 0; }
if [ -f "$DEST/previous-launch-env-hook" ]; then
  cp -p "$DEST/previous-launch-env-hook" "$HOOK.tmp"
  mv "$HOOK.tmp" "$HOOK"
elif [ -f "$DEST/previous-launch-env-hook.absent" ]; then
  rm -f -- "$HOOK"
else
  echo "uninstall.sh: missing previous-hook record at $DEST" >&2; exit 1
fi
rm -f -- "$DEST/launch-env-hook" "$DEST/previous-launch-env-hook" "$DEST/previous-launch-env-hook.absent"
rmdir "$DEST" 2>/dev/null || true
echo "removed: readable pane titles for $FMH"
