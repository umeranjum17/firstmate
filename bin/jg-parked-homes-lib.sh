# shellcheck shell=bash disable=SC2034
# jg-parked-homes-lib.sh - thin shim for the parked-homes reader, which lives
# in juggernaut-addons (parked-homes/bin/jg-parked-homes-lib.sh).
#
# The parked-home rule - a parked squad_lead home gets no message, steer,
# answer, nudge or relaunch, and no config push - is add-on policy; this shim
# only resolves that checkout and sources its reader. Every supervision
# producer gates through the predicates it defines. When the add-on checkout
# is absent (no JG_ADDONS_DIR, nothing at $JG_HOME/projects/juggernaut-addons)
# every predicate answers "not parked", so each gate is a no-op and behavior
# is unchanged.

_JG_PARKED_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_JG_PARKED_ADDONS="${JG_ADDONS_DIR:-${JG_HOME:-$_JG_PARKED_LIB_DIR/..}/projects/juggernaut-addons}"
jg_parked_refuse_meta() { return 0; }
jg_parked_skip_meta() { return 1; }
if [ -f "$_JG_PARKED_ADDONS/parked-homes/bin/jg-parked-homes-lib.sh" ]; then
  # shellcheck source=/dev/null
  # shellcheck source=bin/jg-parked-homes-lib.sh
  . "$_JG_PARKED_ADDONS/parked-homes/bin/jg-parked-homes-lib.sh"
fi
