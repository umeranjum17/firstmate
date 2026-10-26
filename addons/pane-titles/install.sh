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
# Install readable worker/lead pane titles through the home launch-env hook. Usage: install.sh [--dry-run] <jg-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1/config" ] || { echo 'usage: install.sh [--dry-run] <jg-home>' >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-pane-titles
HOOK=$FMH/config/launch-env-hook
SHIM=$(printf '#!/usr/bin/env bash\nexport JG_PANE_TITLES_HOME=%q\nexec %q/launch-env-hook "$@"\n' "$DEST" "$DEST")
if [ -e "$HOOK" ] && [ "$(cat "$HOOK")" != "$SHIM" ] && [ -e "$DEST/previous-launch-env-hook" ]; then
  echo "install.sh: refusing to replace an existing chained hook at $HOOK" >&2; exit 1
fi
if [ "$DRY" -eq 1 ]; then
  echo "would install: $DEST/launch-env-hook"
  [ ! -e "$HOOK" ] || [ "$(cat "$HOOK")" = "$SHIM" ] || echo "would chain existing hook: $HOOK"
  echo "would write: $HOOK"
  echo 'dry run: nothing written'
  exit 0
fi
mkdir -p "$DEST" "$FMH/config"
if [ -e "$HOOK" ] && [ "$(cat "$HOOK")" != "$SHIM" ]; then
  cp -pL "$HOOK" "$DEST/previous-launch-env-hook"
elif [ ! -e "$HOOK" ] && [ ! -e "$DEST/previous-launch-env-hook" ]; then
  : > "$DEST/previous-launch-env-hook.absent"
fi
install -m 755 "$SRC/launch-env-hook" "$DEST/launch-env-hook.tmp"
mv "$DEST/launch-env-hook.tmp" "$DEST/launch-env-hook"
printf '%s\n' "$SHIM" > "$HOOK.tmp"
chmod 700 "$HOOK.tmp"
mv "$HOOK.tmp" "$HOOK"
echo "installed: readable pane titles for $FMH"
