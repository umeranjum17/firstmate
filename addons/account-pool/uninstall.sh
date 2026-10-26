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
# account-pool uninstall.sh - the add-on holds no state outside its checkout. Without it the hook lines
# are no-ops and workers launch on the ambient account; config/account-pool and the pool folder are the
# operator's and stay. Usage: uninstall.sh <jg-home>
echo "account-pool: nothing to remove. Delete ${JG_ADDONS_DIR:-${1:-<jg-home>}/projects/firstmate-addons}/account-pool to turn the pool off."
