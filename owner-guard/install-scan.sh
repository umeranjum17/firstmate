#!/usr/bin/env bash
# Install or update the owner-details daily scan: copy scan-check to
# ${XDG_DATA_HOME:-~/.local/share}/fm-owner-guard-scan/scan-check, write the
# home's state/owner-details-scan.check.sh as a one-line shim that execs it
# (mode 700, the old file kept as .bak-owner-guard-scan-<stamp> when it
# differs), and register the check with the home's bin/fm-check-register.sh.
# Idempotent. Usage: install-scan.sh [--dry-run] [<home>] (the home defaults
# to FM_HOME, else FM_MAIN_HOME, else ~/firstmate)
set -euo pipefail
dry=0
if [ "${1:-}" = --dry-run ]; then dry=1; shift; fi
FMH=${1:-${FM_HOME:-${FM_MAIN_HOME:-$HOME/firstmate}}}
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/scan-check
dest=${XDG_DATA_HOME:-$HOME/.local/share}/fm-owner-guard-scan/scan-check
check=$FMH/state/owner-details-scan.check.sh
shim=$(printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$dest")
if [ "$dry" = 1 ]; then
  echo "dry-run: would copy $src -> $dest, write $check as a shim to it (mode 700) and register the owner-details-scan check"
  exit 0
fi
mkdir -p "${dest%/*}" "$FMH/state"
install -m 755 "$src" "$dest"
if [ "$(cat "$check" 2>/dev/null)" != "$shim" ]; then
  bak=$check.bak-owner-guard-scan-$(date +%s)
  [ ! -e "$check" ] || { cp -p "$check" "$bak"; echo "backup: $bak"; }
  printf '%s\n' "$shim" > "$check"
fi
chmod 700 "$check"
if [ -x "$FMH/bin/fm-check-register.sh" ]; then
  env -u FM_STATE_OVERRIDE "$FMH/bin/fm-check-register.sh" owner-details-scan
fi
echo "installed $dest; $check execs it"
