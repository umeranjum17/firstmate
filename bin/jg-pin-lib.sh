# shellcheck shell=bash
# The single reader of the toolchain pin table (toolchain.versions, beside this repo's root).
# Usage: . bin/jg-pin-lib.sh
#
# jg_pin_file            print the table path.
# jg_pin_spec <tool>     print that row's exact spec. Nonzero when the tool has no row.
# jg_pin_version <tool>  print the version the repo verifies for that tool.
# jg_pin_npm <tool>      print the npm spec to install. Nonzero when the row is not npm-installable.
#
# Callers: bin/jg-bootstrap.sh (its install commands and every floor), bin/jg-tasks-axi-lib.sh,
# bin/jg-quota-axi-lib.sh, and the installer. Nothing here writes, and a missing table or row is a
# refusal rather than a silently assumed version. JG_PIN_FILE_OVERRIDE points at another table, which
# is how a test proves that changing one row changes what the install paths install.
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

JG_PIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

jg_pin_file() {
  printf '%s\n' "${JG_PIN_FILE_OVERRIDE:-$JG_PIN_ROOT/toolchain.versions}"
}

jg_pin_spec() {
  local tool=$1 file name spec
  file=$(jg_pin_file)
  [ -f "$file" ] || { echo "jg-pin-lib: no pin table at $file" >&2; return 1; }
  while read -r name spec _; do
    case "$name" in ''|'#'*) continue ;; esac
    [ "$name" = "$tool" ] || continue
    [ -n "${spec:-}" ] || break
    printf '%s\n' "$spec"
    return 0
  done < "$file"
  echo "jg-pin-lib: $tool has no row in $file" >&2
  return 1
}

jg_pin_version() {
  local spec
  spec=$(jg_pin_spec "$1") || return 1
  printf '%s\n' "${spec##*@}"
}

jg_pin_npm() {
  local spec
  spec=$(jg_pin_spec "$1") || return 1
  [[ $spec =~ ^.+@[0-9] ]] || return 1
  printf '%s\n' "$spec"
}
