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
# The parked-homes installer is verify-only; it writes no state to remove.
# Usage: uninstall.sh [<jg-home>]
set -euo pipefail
[ "$#" -le 1 ] || { echo 'usage: uninstall.sh [<jg-home>]' >&2; exit 2; }
if [ "$#" -eq 1 ]; then
  [ -d "$1" ] || { echo "error: home not found: $1" >&2; exit 1; }
elif [ -n "${JG_HOME:-}" ]; then
  [ -d "$JG_HOME" ] || { echo "error: home not found: $JG_HOME" >&2; exit 1; }
fi
echo 'not installed: parked-homes installer is verify-only'
