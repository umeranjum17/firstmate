#!/usr/bin/env bash
# Tracked shell entrypoint for local and jg-on extension binding commands.
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
set -eu
set -o pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if [ "${1:-}" = remote-bind ]; then
  [ "$#" -ge 4 ] || { printf 'usage: %s remote-bind <squad-lead-id> <package-root> <bind-options...>\n' "$0" >&2; exit 2; }
  route=$2
  package_root=$3
  shift 3
  "$SCRIPT_DIR/jg-extension.mjs" pack-transfer "$package_root" \
    | "$SCRIPT_DIR/jg-on.sh" --stdin "$route" jg-extension.sh receive-transfer-bind "$@"
  exit $?
fi
exec "$SCRIPT_DIR/jg-extension.mjs" "$@"
