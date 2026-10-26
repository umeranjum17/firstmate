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
# Retire the watcher's check and trust from a home, or with --all from every home install.sh --all reaches and remove the copy.
# Usage: uninstall.sh [--all] <jg-home>
set -euo pipefail
ALL=
[ "${1:-}" = --all ] && { ALL=--all; shift; }
[ "$#" -eq 1 ] && [ -d "$1/state" ] || { echo "usage: uninstall.sh [--all] <jg-home>" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-quota-failover
while IFS=$'\t' read -r name home; do
  [ -x "$home/bin/jg-check-unregister.sh" ] || { echo "skipped: $name: $home has no bin/jg-check-unregister.sh" >&2; continue; }
  env -u JG_STATE_OVERRIDE JG_HOME="$home" "$home/bin/jg-check-unregister.sh" quota-failover-watch >/dev/null
  echo "uninstalled: $name: quota-failover-watch from $home"
done < <("$SRC/install.sh" ${ALL:+--all} --list "$1")
[ -z "$ALL" ] || {
  rm -f -- "$DEST/quota-failover/quota-failover" "$DEST/quota-failover/check.sh" "$DEST/parked-homes/bin/jg-parked-homes-lib.sh" \
    "$DEST/account-pool/bin/jg-account-pool-lib.sh" "$DEST/account-pool/bin/jg-pool-claude-env.sh"
  rmdir -- "$DEST/quota-failover" "$DEST/parked-homes/bin" "$DEST/parked-homes" "$DEST/account-pool/bin" "$DEST/account-pool" "$DEST" \
    2>/dev/null || true
}
