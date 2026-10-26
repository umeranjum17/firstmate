#!/usr/bin/env bash
# The add-on lookup chain in bin/fm-addons-dir-lib.sh: FM_ADDONS_DIR, then the in-repo addons/, then
# the pre-fold clone at <home>/projects/firstmate-addons. A live home has to keep working before,
# during and after the move, so both orders are proved through a real consumer, not just resolved.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-addons-dir-lib.sh"
WORK=$(fm_test_tmproot fm-addons-dir)

# A checkout that carries only this library, so a test controls what sits beside it.
make_checkout() {  # make_checkout <dir>
  mkdir -p "$1/bin"
  cp "$LIB" "$1/bin/fm-addons-dir-lib.sh"
}

# Where the library resolves, with the ambient override cleared.
resolve() {  # resolve <checkout> [home] [FM_ADDONS_DIR to pin]
  local checkout=$1 home=${2:-} pin=${3:-}
  (
    if [ -n "$pin" ]; then export FM_ADDONS_DIR=$pin; else unset FM_ADDONS_DIR; fi
    # shellcheck source=/dev/null
    . "$checkout/bin/fm-addons-dir-lib.sh"
    fm_addons_dir "$home"
  )
}

# A pre-fold clone whose reader answers with a marker no in-repo add-on can produce.
make_clone() {  # make_clone <dir>
  mkdir -p "$1/parked-homes/bin"
  printf '%s\n' 'fm_parked_homes_file() { printf "from-clone\n"; }' >"$1/parked-homes/bin/fm-parked-homes-lib.sh"
}

# What a real consumer loaded: the parked-homes shim every supervision producer gates through.
consumer_reader() {  # consumer_reader <home> [FM_ADDONS_DIR to pin]
  local home=$1 pin=${2:-}
  (
    export FM_HOME=$home
    if [ -n "$pin" ]; then export FM_ADDONS_DIR=$pin; else unset FM_ADDONS_DIR; fi
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-parked-homes-lib.sh"
    fm_parked_homes_file
  )
}

test_override_wins_over_everything() {
  local checkout=$WORK/override
  make_checkout "$checkout"
  mkdir -p "$checkout/addons" "$checkout/projects/firstmate-addons"
  got=$(resolve "$checkout" "$WORK/home" /pinned/addons)
  [ "$got" = /pinned/addons ] || fail "FM_ADDONS_DIR did not win: $got"
  pass "an explicit FM_ADDONS_DIR wins over the in-repo copy and the clone"
}

test_in_repo_wins_when_both_exist() {
  local checkout=$WORK/both
  make_checkout "$checkout"
  mkdir -p "$checkout/addons" "$checkout/projects/firstmate-addons"
  got=$(resolve "$checkout" "$WORK/home")
  [ "$got" = "$checkout/addons" ] || fail "the in-repo addons/ did not win: $got"
  pass "the in-repo addons/ wins while the pre-fold clone is still there"
}

test_clone_resolves_when_in_repo_absent() {
  local checkout=$WORK/clone-only home=$WORK/clone-home
  make_checkout "$checkout"
  mkdir -p "$checkout/projects/firstmate-addons" "$home/projects/firstmate-addons"
  got=$(resolve "$checkout")
  [ "$got" = "$checkout/projects/firstmate-addons" ] || fail "the clone did not answer without a home: $got"
  got=$(resolve "$checkout" "$home")
  [ "$got" = "$home/projects/firstmate-addons" ] || fail "the clone did not answer under the given home: $got"
  pass "a checkout with no addons/ still resolves the pre-fold clone, for its own home or a named one"
}

test_live_consumer_prefers_in_repo() {
  local home=$WORK/live-both
  mkdir -p "$home"
  make_clone "$home/projects/firstmate-addons"
  got=$(consumer_reader "$home")
  [ "$got" != from-clone ] || fail "the consumer loaded the clone while the in-repo addons/ existed"
  [ -n "$got" ] || fail "the consumer loaded no parked-homes reader at all"
  pass "with both present, a live consumer reads the in-repo add-on"
}

test_live_consumer_falls_back_to_clone() {
  local home=$WORK/live-clone
  mkdir -p "$home"
  make_clone "$home/projects/firstmate-addons"
  got=$(consumer_reader "$home" "$home/projects/firstmate-addons")
  [ "$got" = from-clone ] || fail "the clone reader was not reachable through the consumer: $got"
  pass "before the move, the same consumer still reads the pre-fold clone"
}

test_override_wins_over_everything
test_in_repo_wins_when_both_exist
test_clone_resolves_when_in_repo_absent
test_live_consumer_prefers_in_repo
test_live_consumer_falls_back_to_clone
