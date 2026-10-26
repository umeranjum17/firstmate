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
# Install or update the claude-quota check for this user and point one firstmate home's state/claude-quota.check.sh
# at it through an exec shim, backing up a replaced check first, then re-register it. Idempotent.
# Usage: install.sh [--dry-run] <jg-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-register.sh" ] || { echo "usage: install.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-claude-quota
CHECK=$FMH/state/claude-quota.check.sh
SHIM=$(printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$DEST/claude-quota.check.sh")
BAK=
[ ! -e "$CHECK" ] || [ "$(cat "$CHECK")" = "$SHIM" ] || BAK=$CHECK.bak-claude-quota-$(date +%s)

if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/claude-quota.check.sh -> $DEST/claude-quota.check.sh"
  [ -z "$BAK" ] || echo "would back up: $CHECK -> $BAK"
  echo "would write: $CHECK:"
  printf '%s\n' "$SHIM" | sed 's/^/  /'
  echo "would run: $FMH/bin/jg-check-register.sh claude-quota"
  echo "dry run: nothing written"
  exit 0
fi
mkdir -p "$DEST"
install -m 755 "$SRC/claude-quota.check.sh" "$DEST/claude-quota.check.sh"
[ -z "$BAK" ] || { cp -p "$CHECK" "$BAK"; echo "backed up: $BAK"; }
printf '%s\n' "$SHIM" > "$CHECK"
chmod 700 "$CHECK"
# An JG_STATE_OVERRIDE in the caller env, even empty, would register away from FMH/state.
env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" claude-quota
echo "installed: $CHECK -> $DEST/claude-quota.check.sh"
