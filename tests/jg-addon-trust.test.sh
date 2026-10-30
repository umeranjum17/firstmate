#!/usr/bin/env bash
# An add-on file resolved outside the checkout (JG_ADDONS_DIR) must be owned by the current user and not
# group- or world-writable; a refused file behaves like an absent add-on with one stderr line. One refused
# file proves it at each load style: source (jg-dod-lib), exec (jg-flow), and the path lookup itself.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK=$(jg_test_tmproot jg-addon-trust)
addons="$WORK/addons"
mkdir -p "$addons/fleet-flow/bin" "$addons/merge-card/bin"
printf '#!/bin/sh\necho flow-ran\n' > "$addons/fleet-flow/bin/jg-flow.sh"
printf 'JG_TRUST_SOURCED=1\n' > "$addons/merge-card/bin/jg-merge-hooks-lib.sh"
chmod 755 "$addons/fleet-flow/bin/jg-flow.sh"
chmod 644 "$addons/merge-card/bin/jg-merge-hooks-lib.sh"

run_flow() { JG_HOME="$WORK/home" JG_ADDONS_DIR="$addons" "$ROOT/bin/jg-flow.sh" 2>&1; }
src_hooks() {
  JG_HOME="$WORK/home" JG_ADDONS_DIR="$addons" bash -c \
    '. "$1/bin/jg-addons-dir-lib.sh"; p=$(jg_addon_path "$JG_HOME" merge-card/bin/jg-merge-hooks-lib.sh); [ ! -r "$p" ] || . "$p"; echo "sourced=${JG_TRUST_SOURCED:-0}"' _ "$ROOT" 2>&1
}

[ "$(run_flow)" = flow-ran ] || fail "an owner-only-writable add-on must still run"
src_hooks | grep -q '^sourced=1$' || fail "an owner-only-writable add-on must still be sourced"

chmod 777 "$addons/fleet-flow/bin/jg-flow.sh"; chmod 666 "$addons/merge-card/bin/jg-merge-hooks-lib.sh"
out=$(run_flow) && fail "a world-writable add-on must not run"
case $out in *refusing*) ;; *) fail "refusal gave no stderr line: $out" ;; esac
out=$(src_hooks)
case $out in *sourced=0*refusing*|*refusing*sourced=0*) ;; *) fail "world-writable add-on was sourced or silent: $out" ;; esac

chmod 775 "$addons/fleet-flow/bin/jg-flow.sh"
run_flow | grep -q refusing || fail "a group-writable add-on must be refused"

pass "jg-addons-dir-lib.sh: an add-on outside the checkout that others can write is refused as absent"

# A home that still carries the retired pre-fold clone (fm- names only) must resolve jg- add-ons from the
# checkout's own addons/; only a checkout without addons/ falls back to the clone.
resolve() {  # <checkout> <home>: where the wait ladder library resolves
  # shellcheck disable=SC2016 # single quotes are deliberate: the inner shell expands them.
  env -u JG_ADDONS_DIR JG_HOME="$2" bash -c \
    '. "$1/bin/jg-compat.sh"; . "$1/bin/jg-addons-dir-lib.sh"; jg_addon_path "$JG_HOME" wait-timers/bin/jg-wait-timers-lib.sh' _ "$1" 2>&1
}
co="$WORK/checkout"
mkdir -p "$co/bin" "$co/addons/wait-timers/bin" "$WORK/oldhome/projects/firstmate-addons/wait-timers/bin"
cp "$ROOT/bin/jg-compat.sh" "$ROOT/bin/jg-addons-dir-lib.sh" "$co/bin/"
: > "$co/addons/wait-timers/bin/jg-wait-timers-lib.sh"
: > "$WORK/oldhome/projects/firstmate-addons/wait-timers/bin/fm-wait-timers-lib.sh"
got=$(resolve "$co" "$WORK/oldhome")
[ "$got" = "$co/addons/wait-timers/bin/jg-wait-timers-lib.sh" ] || fail "a checkout with addons/ must not resolve into the retired clone: $got"
rm -rf -- "$WORK/checkout/addons"
got=$(resolve "$co" "$WORK/oldhome")
[ "$got" = "$WORK/oldhome/projects/firstmate-addons/wait-timers/bin/jg-wait-timers-lib.sh" ] || fail "a checkout without addons/ must still use the clone: $got"

pass "jg-compat.sh: the retired add-on clone never hides a checkout's own addons/"
