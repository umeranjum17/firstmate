#!/usr/bin/env bash
# Behavior tests for the bin/jg-dashboard.sh shim: it execs the
# firstmate-addons fleet-dashboard add-on with JG_BIN pointing at this
# fork's bin/, and fails clearly when the add-ons checkout is absent.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIM="$ROOT/bin/jg-dashboard.sh"
TMP_ROOT=$(jg_test_tmproot jg-dashboard-shim)

# A fake add-ons checkout records the args it received and the JG_BIN it saw.
make_fake_addons() {  # <name>; prints the fake JG_ADDONS_DIR
  local dir="$TMP_ROOT/$1" target="$TMP_ROOT/$1/fleet-dashboard/jg-dashboard.sh"
  mkdir -p "$TMP_ROOT/$1/fleet-dashboard"
  cat > "$target" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$JG_BIN" > "$FAKE_OUT/fmbin"
printf '%s\n' "$@" > "$FAKE_OUT/args"
SH
  chmod +x "$target"
  printf '%s\n' "$dir"
}

# The fake add-on receives the shim's args and JG_BIN naming this fork's bin/.
addons=$(make_fake_addons present)
mkdir -p "$TMP_ROOT/out-present"
FAKE_OUT="$TMP_ROOT/out-present" JG_ADDONS_DIR="$addons" "$SHIM" build --port 1 >"$TMP_ROOT/out-present/stdout" 2>"$TMP_ROOT/out-present/stderr"
[ -f "$TMP_ROOT/out-present/args" ] || fail "fake add-on never ran"
[ "$(cat "$TMP_ROOT/out-present/args")" = "build
--port
1" ] || fail "fake add-on got wrong args: $(cat "$TMP_ROOT/out-present/args")"
[ "$(cat "$TMP_ROOT/out-present/fmbin")" = "$ROOT/bin" ] || fail "JG_BIN was '$(cat "$TMP_ROOT/out-present/fmbin")', want '$ROOT/bin'"

# A missing add-ons checkout exits 1 and names JG_ADDONS_DIR on stderr.
mkdir -p "$TMP_ROOT/out-missing"
status=0
JG_ADDONS_DIR="$TMP_ROOT/nowhere" "$SHIM" build >"$TMP_ROOT/out-missing/stdout" 2>"$TMP_ROOT/out-missing/stderr" || status=$?
[ "$status" -eq 0 ] && fail "shim succeeded with no add-ons checkout"
[ "$status" -eq 1 ] || fail "shim exit was $status, want 1"
grep -q "JG_ADDONS_DIR" "$TMP_ROOT/out-missing/stderr" || fail "missing-checkout stderr never names JG_ADDONS_DIR: $(cat "$TMP_ROOT/out-missing/stderr")"

# With JG_ADDONS_DIR unset, the shim defaults to $JG_HOME/projects/firstmate-addons.
mkdir -p "$TMP_ROOT/fakehome/projects/firstmate-addons/fleet-dashboard"
cp "$addons/fleet-dashboard/jg-dashboard.sh" "$TMP_ROOT/fakehome/projects/firstmate-addons/fleet-dashboard/jg-dashboard.sh"
mkdir -p "$TMP_ROOT/out-default"
env -u JG_ADDONS_DIR FAKE_OUT="$TMP_ROOT/out-default" JG_HOME="$TMP_ROOT/fakehome" "$SHIM" serve >"$TMP_ROOT/out-default/stdout" 2>"$TMP_ROOT/out-default/stderr"
[ "$(cat "$TMP_ROOT/out-default/args")" = "serve" ] || fail "default-dir add-on got wrong args: $(cat "$TMP_ROOT/out-default/args")"
[ "$(cat "$TMP_ROOT/out-default/fmbin")" = "$ROOT/bin" ] || fail "default-dir JG_BIN was '$(cat "$TMP_ROOT/out-default/fmbin")', want '$ROOT/bin'"

pass "jg-dashboard shim delegates with JG_BIN and fails clearly without add-ons"
