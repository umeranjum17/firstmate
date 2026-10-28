#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031 # each case resolves inside a deliberate subshell (see below)
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# The add-on lookup chain in bin/jg-addons-dir-lib.sh: JG_ADDONS_DIR, then the in-repo addons/, then
# the pre-fold clone at <home>/projects/juggernaut-addons. A live home has to keep working before,
# during and after the move, so both orders are proved through a real consumer, not just resolved.
# shellcheck disable=SC2030,SC2031 # Every case resolves the add-ons directory inside a deliberate subshell, so the
# caller's own environment (and any ambient JG_ADDONS_DIR) stays clean between cases.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/jg-addons-dir-lib.sh"
WORK=$(jg_test_tmproot jg-addons-dir)

# A checkout that carries only this library, so a test controls what sits beside it.
make_checkout() {  # make_checkout <dir>
  mkdir -p "$1/bin"
  cp "$LIB" "$1/bin/jg-addons-dir-lib.sh"
}

# Where the library resolves, with the ambient override cleared.
resolve() {  # resolve <checkout> [home] [JG_ADDONS_DIR to pin]
  local checkout=$1 home=${2:-} pin=${3:-}
  (
    if [ -n "$pin" ]; then export JG_ADDONS_DIR=$pin; else unset JG_ADDONS_DIR; fi
    # shellcheck source=/dev/null
    . "$checkout/bin/jg-addons-dir-lib.sh"
    jg_addons_dir "$home"
  )
}

# A pre-fold clone whose reader answers with a marker no in-repo add-on can produce.
make_clone() {  # make_clone <dir>
  mkdir -p "$1/parked-homes/bin"
  printf '%s\n' 'jg_parked_homes_file() { printf "from-clone\n"; }' >"$1/parked-homes/bin/jg-parked-homes-lib.sh"
}

# What a real consumer loaded: the parked-homes shim every supervision producer gates through.
consumer_reader() {  # consumer_reader <home> [JG_ADDONS_DIR to pin]
  local home=$1 pin=${2:-}
  (
    export JG_HOME=$home
    if [ -n "$pin" ]; then export JG_ADDONS_DIR=$pin; else unset JG_ADDONS_DIR; fi
    # shellcheck source=/dev/null
    . "$ROOT/bin/jg-parked-homes-lib.sh"
    jg_parked_homes_file
  )
}

test_override_wins_over_everything() {
  local checkout=$WORK/override
  make_checkout "$checkout"
  mkdir -p "$checkout/addons" "$checkout/projects/juggernaut-addons"
  got=$(resolve "$checkout" "$WORK/home" /pinned/addons)
  [ "$got" = /pinned/addons ] || fail "JG_ADDONS_DIR did not win: $got"
  pass "an explicit JG_ADDONS_DIR wins over the in-repo copy and the clone"
}

test_in_repo_wins_when_both_exist() {
  local checkout=$WORK/both
  make_checkout "$checkout"
  mkdir -p "$checkout/addons" "$checkout/projects/juggernaut-addons"
  got=$(resolve "$checkout" "$WORK/home")
  [ "$got" = "$checkout/addons" ] || fail "the in-repo addons/ did not win: $got"
  pass "the in-repo addons/ wins while the pre-fold clone is still there"
}

test_clone_resolves_when_in_repo_absent() {
  local checkout=$WORK/clone-only home=$WORK/clone-home
  make_checkout "$checkout"
  mkdir -p "$checkout/projects/juggernaut-addons" "$home/projects/juggernaut-addons"
  got=$(resolve "$checkout")
  [ "$got" = "$checkout/projects/juggernaut-addons" ] || fail "the clone did not answer without a home: $got"
  got=$(resolve "$checkout" "$home")
  [ "$got" = "$home/projects/juggernaut-addons" ] || fail "the clone did not answer under the given home: $got"
  pass "a checkout with no addons/ still resolves the pre-fold clone, for its own home or a named one"
}

test_live_consumer_prefers_in_repo() {
  local home=$WORK/live-both
  mkdir -p "$home"
  make_clone "$home/projects/juggernaut-addons"
  got=$(consumer_reader "$home")
  [ "$got" != from-clone ] || fail "the consumer loaded the clone while the in-repo addons/ existed"
  [ -n "$got" ] || fail "the consumer loaded no parked-homes reader at all"
  pass "with both present, a live consumer reads the in-repo add-on"
}

test_live_consumer_falls_back_to_clone() {
  local home=$WORK/live-clone
  mkdir -p "$home"
  make_clone "$home/projects/juggernaut-addons"
  got=$(consumer_reader "$home" "$home/projects/juggernaut-addons")
  [ "$got" = from-clone ] || fail "the clone reader was not reachable through the consumer: $got"
  pass "before the move, the same consumer still reads the pre-fold clone"
}

test_override_wins_over_everything
test_in_repo_wins_when_both_exist
test_clone_resolves_when_in_repo_absent
test_live_consumer_prefers_in_repo
test_live_consumer_falls_back_to_clone
