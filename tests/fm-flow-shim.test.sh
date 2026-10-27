#!/usr/bin/env bash
# Behavior tests for the bin/fm-flow.sh shim: it execs the fleet-flow reader with FM_BIN pointing at this fork's
# bin/, it resolves the in-repo addons/ before the pre-fold clone at $FM_HOME/projects/firstmate-addons, and it
# fails clearly when neither is there.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIM="$ROOT/bin/fm-flow.sh"
LIB="$ROOT/bin/fm-addons-dir-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-flow-shim)

# A fake add-on records the tag it was written under, the FM_BIN it saw, and the args it received.
write_fake_addon() {  # write_fake_addon <addons-dir> <tag>
  mkdir -p "$1/fleet-flow/bin"
  cat > "$1/fleet-flow/bin/fm-flow.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "$2" > "\$FAKE_OUT/tag"
printf '%s\n' "\$FM_BIN" > "\$FAKE_OUT/fmbin"
printf '%s\n' "\$@" > "\$FAKE_OUT/args"
SH
  chmod +x "$1/fleet-flow/bin/fm-flow.sh"
}

# A checkout of this repository's shim with, or without, its own addons/ beside bin/.
write_checkout() {  # write_checkout <dir> [--with-addons <tag>]
  mkdir -p "$1/bin"
  cp "$SHIM" "$1/bin/fm-flow.sh"
  cp "$LIB" "$1/bin/fm-addons-dir-lib.sh"
  [ "${2:-}" = --with-addons ] && write_fake_addon "$1/addons" "$3"
  return 0
}

# 1. An explicit FM_ADDONS_DIR receives the shim's args and FM_BIN naming this fork's bin/.
write_fake_addon "$TMP_ROOT/explicit-addons" explicit
mkdir -p "$TMP_ROOT/out-explicit"
FAKE_OUT="$TMP_ROOT/out-explicit" FM_ADDONS_DIR="$TMP_ROOT/explicit-addons" "$SHIM" --json --now 100 --capacity \
  >"$TMP_ROOT/out-explicit/stdout" 2>"$TMP_ROOT/out-explicit/stderr"
[ -f "$TMP_ROOT/out-explicit/args" ] || fail "fake add-on never ran"
[ "$(cat "$TMP_ROOT/out-explicit/tag")" = explicit ] || fail "FM_ADDONS_DIR did not win"
[ "$(cat "$TMP_ROOT/out-explicit/args")" = "--json
--now
100
--capacity" ] || fail "fake add-on got wrong args: $(cat "$TMP_ROOT/out-explicit/args")"
[ "$(cat "$TMP_ROOT/out-explicit/fmbin")" = "$ROOT/bin" ] || fail "FM_BIN was '$(cat "$TMP_ROOT/out-explicit/fmbin")', want '$ROOT/bin'"

# 2. A missing add-ons directory exits 1 and names FM_ADDONS_DIR on stderr.
mkdir -p "$TMP_ROOT/out-missing"
status=0
FM_ADDONS_DIR="$TMP_ROOT/nowhere" "$SHIM" --json >"$TMP_ROOT/out-missing/stdout" 2>"$TMP_ROOT/out-missing/stderr" || status=$?
[ "$status" -eq 0 ] && fail "shim succeeded with no add-ons directory"
[ "$status" -eq 1 ] || fail "shim exit was $status, want 1"
grep -q "FM_ADDONS_DIR" "$TMP_ROOT/out-missing/stderr" || fail "missing-add-ons stderr never names FM_ADDONS_DIR: $(cat "$TMP_ROOT/out-missing/stderr")"

# 3. With FM_ADDONS_DIR unset and both present, the in-repo addons/ wins over the clone.
write_checkout "$TMP_ROOT/both" --with-addons in-repo
write_fake_addon "$TMP_ROOT/home-both/projects/firstmate-addons" clone
mkdir -p "$TMP_ROOT/out-both"
env -u FM_ADDONS_DIR FAKE_OUT="$TMP_ROOT/out-both" FM_HOME="$TMP_ROOT/home-both" "$TMP_ROOT/both/bin/fm-flow.sh" --json \
  >"$TMP_ROOT/out-both/stdout" 2>"$TMP_ROOT/out-both/stderr"
[ "$(cat "$TMP_ROOT/out-both/tag" 2>/dev/null)" = in-repo ] || fail "the clone ran while the in-repo addons/ existed"
[ "$(cat "$TMP_ROOT/out-both/args")" = "--json" ] || fail "in-repo add-on got wrong args: $(cat "$TMP_ROOT/out-both/args")"
[ "$(cat "$TMP_ROOT/out-both/fmbin")" = "$TMP_ROOT/both/bin" ] || fail "in-repo FM_BIN was '$(cat "$TMP_ROOT/out-both/fmbin")', want '$TMP_ROOT/both/bin'"

# 4. A checkout with no addons/ still resolves the clone, so a live home keeps working before the move.
write_checkout "$TMP_ROOT/clone-only"
write_fake_addon "$TMP_ROOT/home-clone/projects/firstmate-addons" clone
mkdir -p "$TMP_ROOT/out-clone"
env -u FM_ADDONS_DIR FAKE_OUT="$TMP_ROOT/out-clone" FM_HOME="$TMP_ROOT/home-clone" "$TMP_ROOT/clone-only/bin/fm-flow.sh" --json \
  >"$TMP_ROOT/out-clone/stdout" 2>"$TMP_ROOT/out-clone/stderr"
[ "$(cat "$TMP_ROOT/out-clone/tag" 2>/dev/null)" = clone ] || fail "the clone did not answer for a checkout with no addons/"
[ "$(cat "$TMP_ROOT/out-clone/fmbin")" = "$TMP_ROOT/clone-only/bin" ] || fail "clone FM_BIN was '$(cat "$TMP_ROOT/out-clone/fmbin")', want '$TMP_ROOT/clone-only/bin'"

pass "fm-flow shim delegates with FM_BIN, prefers the in-repo add-ons, and still resolves the clone"
