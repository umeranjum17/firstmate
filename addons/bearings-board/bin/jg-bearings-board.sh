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
# jg-bearings-board.sh - runs the Bearings board from the Firstmate checkout, unchanged.
#
# Commands:
#   build <data.json> [args...]   run the checkout's build with every argument
#   path [args...]                run the checkout's path with every argument
#
# JG_CODE_ROOT names the Firstmate checkout (defaults to JG_HOME). Nothing is copied
# from the checkout: its own bin/jg-bearings-board.sh does the work and receives every
# argument. The exec sets JG_BEARINGS_BOARD_WRAPPER so a checkout wired back to this
# wrapper fails instead of recursing. install.sh wires this wrapper into a home;
# uninstall.sh removes it.
set -eu

fail() { printf 'jg-bearings-board: %s\n' "$*" >&2; exit 1; }

usage() {
  printf 'usage: jg-bearings-board.sh build <data.json> [args...] | path\n' >&2
  exit 2
}

checkout_board() {
  local root="${JG_CODE_ROOT:-${JG_HOME:-}}"
  [ -z "${JG_BEARINGS_BOARD_WRAPPER:-}" ] || fail "the checkout's bin/jg-bearings-board.sh is this wrapper: refusing to recurse"
  [ -n "$root" ] || fail "set JG_CODE_ROOT to the Firstmate checkout"
  [ -x "$root/bin/jg-bearings-board.sh" ] || fail "no bin/jg-bearings-board.sh under $root"
  printf '%s/bin/jg-bearings-board.sh\n' "$root"
}

build() {
  local upstream
  [ "$#" -ge 1 ] || usage
  upstream=$(checkout_board)
  exec env JG_BEARINGS_BOARD_WRAPPER=1 "$upstream" build "$@"
}

case "${1-}" in
  build) shift; build "$@" ;;
  path) shift; upstream=$(checkout_board); exec env JG_BEARINGS_BOARD_WRAPPER=1 "$upstream" path "$@" ;;
  *) usage ;;
esac
