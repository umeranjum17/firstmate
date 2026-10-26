#!/usr/bin/env bash
# Behavior tests for the bin/jg-model-stats.sh and bin/jg-skill-stats.sh shims:
# each execs its firstmate-addons fleet-stats reader with JG_BIN pointing at
# this fork's bin/, and fails clearly when the add-ons checkout is absent.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-stats-shim)

# A fake add-ons checkout records the args it received and the JG_BIN it saw.
make_fake_addons() {  # <name>; prints the fake JG_ADDONS_DIR
  local dir="$TMP_ROOT/$1" reader
  for reader in jg-model-stats.sh jg-skill-stats.sh; do
    mkdir -p "$dir/fleet-stats/bin"
    cat > "$dir/fleet-stats/bin/$reader" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$JG_BIN" > "$FAKE_OUT/fmbin"
printf '%s\n' "$JG_HOME" > "$FAKE_OUT/fmhome"
printf '%s\n' "$@" > "$FAKE_OUT/args"
SH
    chmod +x "$dir/fleet-stats/bin/$reader"
  done
  printf '%s\n' "$dir"
}

addons=$(make_fake_addons present)
for reader in jg-model-stats jg-skill-stats; do
  shim="$ROOT/bin/$reader.sh"
  out="$TMP_ROOT/out-$reader"
  mkdir -p "$out"

  # The fake add-on receives the shim's args and JG_BIN naming this fork's bin/.
  env -u JG_HOME FAKE_OUT="$out" JG_ADDONS_DIR="$addons" "$shim" --json --now 1700000000 >"$out/stdout" 2>"$out/stderr"
  [ "$(cat "$out/args")" = "--json
--now
1700000000" ] || fail "$reader fake add-on got wrong args: $(cat "$out/args")"
  [ "$(cat "$out/fmbin")" = "$ROOT/bin" ] || fail "$reader JG_BIN was '$(cat "$out/fmbin")', want '$ROOT/bin'"
  [ "$(cat "$out/fmhome")" = "$ROOT" ] || fail "$reader with JG_HOME unset passed JG_HOME '$(cat "$out/fmhome")', want '$ROOT'"

  # A missing add-ons checkout exits 1 and names JG_ADDONS_DIR on stderr.
  status=0
  JG_ADDONS_DIR="$TMP_ROOT/nowhere" "$shim" --json >"$out/stdout-missing" 2>"$out/stderr-missing" || status=$?
  [ "$status" -eq 1 ] || fail "$reader shim exit with no add-ons was $status, want 1"
  grep -q "JG_ADDONS_DIR" "$out/stderr-missing" || fail "$reader missing-checkout stderr never names JG_ADDONS_DIR: $(cat "$out/stderr-missing")"
done

# With JG_ADDONS_DIR unset, the shims default to $JG_HOME/projects/firstmate-addons.
mkdir -p "$TMP_ROOT/fakehome/projects/firstmate-addons"
cp -R "$addons/fleet-stats" "$TMP_ROOT/fakehome/projects/firstmate-addons/"
mkdir -p "$TMP_ROOT/out-default"
env -u JG_ADDONS_DIR FAKE_OUT="$TMP_ROOT/out-default" JG_HOME="$TMP_ROOT/fakehome" "$ROOT/bin/jg-skill-stats.sh" --json >"$TMP_ROOT/out-default/stdout" 2>"$TMP_ROOT/out-default/stderr"
[ "$(cat "$TMP_ROOT/out-default/args")" = "--json" ] || fail "default-dir add-on got wrong args: $(cat "$TMP_ROOT/out-default/args")"
[ "$(cat "$TMP_ROOT/out-default/fmbin")" = "$ROOT/bin" ] || fail "default-dir JG_BIN was '$(cat "$TMP_ROOT/out-default/fmbin")', want '$ROOT/bin'"
[ "$(cat "$TMP_ROOT/out-default/fmhome")" = "$TMP_ROOT/fakehome" ] || fail "default-dir JG_HOME was '$(cat "$TMP_ROOT/out-default/fmhome")', want '$TMP_ROOT/fakehome'"

pass "jg-model-stats and jg-skill-stats shims delegate with JG_BIN and fail clearly without add-ons"
