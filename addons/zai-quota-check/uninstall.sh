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
# Remove the Z.AI quota check from one firstmate home. Usage: uninstall.sh [--dry-run]
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }; [ "$#" -eq 0 ] || { echo 'usage: uninstall.sh [--dry-run]' >&2; exit 2; }
JG_HOME=${JG_HOME:?set JG_HOME to the firstmate home}; f=$JG_HOME/state/zai-quota.check.sh
if [ -e "$f" ]; then
  [ -x "$JG_HOME/bin/jg-check-unregister.sh" ] || { echo "remove manually: $f" >&2; exit 1; }
  if [ "$DRY" -eq 1 ]; then echo "would run: $JG_HOME/bin/jg-check-unregister.sh zai-quota"; else env -u JG_STATE_OVERRIDE JG_HOME="$JG_HOME" "$JG_HOME/bin/jg-check-unregister.sh" zai-quota; fi
fi
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
