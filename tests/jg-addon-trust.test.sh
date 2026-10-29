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
