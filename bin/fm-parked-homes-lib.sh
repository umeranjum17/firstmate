# shellcheck shell=bash disable=SC2034
# fm-parked-homes-lib.sh - thin shim for the parked-homes reader, which lives
# in this repository's addons/ (parked-homes/bin/fm-parked-homes-lib.sh).
#
# The parked-home rule - a parked secondmate home gets no message, steer,
# answer, nudge or relaunch, and no config push - is add-on policy; this shim
# only resolves that checkout and sources its reader. Every supervision
# producer gates through the predicates it defines. When the add-on directory
# is absent (no FM_ADDONS_DIR, and neither the in-repo addons/ nor the pre-fold
# clone at $FM_HOME/projects/firstmate-addons exists) every predicate answers
# "not parked", so each gate is a no-op and behavior is unchanged.

_FM_PARKED_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-addons-dir-lib.sh
. "$_FM_PARKED_LIB_DIR/fm-addons-dir-lib.sh"
_FM_PARKED_ADDONS=$(fm_addons_dir "${FM_HOME:-$_FM_PARKED_LIB_DIR/..}")
fm_parked_refuse_meta() { return 0; }
fm_parked_skip_meta() { return 1; }
if [ -f "$_FM_PARKED_ADDONS/parked-homes/bin/fm-parked-homes-lib.sh" ]; then
  # shellcheck source=/dev/null
  # shellcheck source=bin/fm-parked-homes-lib.sh
  . "$_FM_PARKED_ADDONS/parked-homes/bin/fm-parked-homes-lib.sh"
fi
