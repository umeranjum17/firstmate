#!/usr/bin/env bash
# jg-jev-mem-guard.sh - host memory guard; usage and contract: bin/jg-jev-mem-guard.py header.
# Without python3 the host is not measurable here, which admits and records nothing.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  for _jg_f in legacy_of legacy_product record_ok label_ok marker parent_marker claims_root; do
    eval "jg_compat_$_jg_f() { return 1; }"
  done
  unset _jg_f
fi
unset _jg_d
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v python3 >/dev/null 2>&1 || { printf 'UNKNOWN\thost memory is not measurable here (python3 is not installed)\n'; exit 0; }
exec python3 "$SCRIPT_DIR/jg-jev-mem-guard.py" "$@"
