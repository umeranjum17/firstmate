# shellcheck shell=bash
# The single reader of the toolchain pin table (toolchain.versions, beside this repo's root).
# Usage: . bin/fm-pin-lib.sh
#
# fm_pin_file            print the table path.
# fm_pin_spec <tool>     print that row's exact spec. Nonzero when the tool has no row.
# fm_pin_version <tool>  print the version the repo verifies for that tool.
# fm_pin_npm <tool>      print the npm spec to install. Nonzero when the row is not npm-installable.
#
# Callers: bin/fm-bootstrap.sh (its install commands and every floor), bin/fm-tasks-axi-lib.sh,
# bin/fm-quota-axi-lib.sh, and the installer. Nothing here writes, and a missing table or row is a
# refusal rather than a silently assumed version. FM_PIN_FILE_OVERRIDE points at another table, which
# is how a test proves that changing one row changes what the install paths install.

FM_PIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

fm_pin_file() {
  printf '%s\n' "${FM_PIN_FILE_OVERRIDE:-$FM_PIN_ROOT/toolchain.versions}"
}

fm_pin_spec() {
  local tool=$1 file name spec
  file=$(fm_pin_file)
  [ -f "$file" ] || { echo "fm-pin-lib: no pin table at $file" >&2; return 1; }
  while read -r name spec _; do
    case "$name" in ''|'#'*) continue ;; esac
    [ "$name" = "$tool" ] || continue
    [ -n "${spec:-}" ] || break
    printf '%s\n' "$spec"
    return 0
  done < "$file"
  echo "fm-pin-lib: $tool has no row in $file" >&2
  return 1
}

fm_pin_version() {
  local spec
  spec=$(fm_pin_spec "$1") || return 1
  printf '%s\n' "${spec##*@}"
}

fm_pin_npm() {
  local spec
  spec=$(fm_pin_spec "$1") || return 1
  [[ $spec =~ ^.+@[0-9] ]] || return 1
  printf '%s\n' "$spec"
}
