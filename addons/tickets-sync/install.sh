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
# Usage: JG_HOME=<fleet home> install.sh [--dry-run]
#
# Installs the sync, its writer and the two watcher checks it owns, and
# registers both checks. The sync check publishes work as tickets; the stale
# check writes nothing and prints one line per board ticket whose state
# disagrees with its PR and backlog item, or that no home's work accounts for,
# so its stdout is a Main wake and its silence means the board is true.
set -euo pipefail
src=$(cd "$(dirname "$0")/.." && pwd -P)
dest=${XDG_DATA_HOME:-$HOME/.local/share}/jg-tickets-sync
: "${JG_HOME:?set JG_HOME to the fleet home with data/squad_leads.md}"
if [ "${1:-}" = --dry-run ]; then echo "would install $dest and register tickets-sync and tickets-stale"; exit; fi
[ "$#" = 0 ] || { echo 'usage: install.sh [--dry-run]' >&2; exit 2; }
mkdir -p "$dest/tickets-sync" "$dest/fleet-dashboard" "$JG_HOME/state"
install -m 755 "$src/tickets-sync/"{sync,ticket}.py "$dest/tickets-sync/"
install -m 644 "$src/tickets-sync/"{lane,hierarchy}.py "$dest/tickets-sync/"
install -m 644 "$src/fleet-dashboard/task_rows.py" "$dest/fleet-dashboard/task_rows.py"
mkdir -p "$dest/fleet-dashboard/jg-dashboard/icons"; cp -f "$src"/fleet-dashboard/jg-dashboard/icons/* "$dest/fleet-dashboard/jg-dashboard/icons/"
printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec python3 %q 2>&1\n' "$JG_HOME" "$dest/tickets-sync/sync.py" > "$JG_HOME/state/tickets-sync.check.sh"
printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec python3 %q --check 2>&1\n' "$JG_HOME" "$dest/tickets-sync/sync.py" > "$JG_HOME/state/tickets-stale.check.sh"
chmod 700 "$JG_HOME/state/tickets-sync.check.sh" "$JG_HOME/state/tickets-stale.check.sh"
env -u JG_STATE_OVERRIDE "$JG_HOME/bin/jg-check-register.sh" tickets-sync
env -u JG_STATE_OVERRIDE "$JG_HOME/bin/jg-check-register.sh" tickets-stale
