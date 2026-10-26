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
# Retire the backlog-lock-reclaim check from one firstmate home (its check and trust binding), then remove the installed
# copy. Idempotent. Usage: uninstall.sh <jg-home>
set -euo pipefail
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-unregister.sh" ] || { echo "usage: uninstall.sh <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-backlog-lock-reclaim
env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-unregister.sh" backlog-lock-reclaim
rm -f -- "$DEST/backlog-lock-reclaim.check.sh"
rmdir -- "$DEST" 2>/dev/null || true
echo "uninstalled: backlog-lock-reclaim from $FMH"
