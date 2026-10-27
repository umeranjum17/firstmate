#!/usr/bin/env bash
# Behavior tests for the bin/fm-model-stats.sh and bin/fm-skill-stats.sh shims: each execs its fleet-stats reader
# with FM_BIN pointing at this fork's bin/, resolves the in-repo addons/ before the pre-fold clone at
# $FM_HOME/projects/firstmate-addons, and fails clearly when neither is there.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-addons-dir-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-stats-shim)

# Fake readers record the tag they were written under, the FM_BIN and FM_HOME they saw, and their args.
write_fake_addons() {  # write_fake_addons <addons-dir> <tag>
  local reader
  for reader in fm-model-stats.sh fm-skill-stats.sh; do
    mkdir -p "$1/fleet-stats/bin"
    cat > "$1/fleet-stats/bin/$reader" <<SH
#!/usr/bin/env bash
printf '%s\n' "$2" > "\$FAKE_OUT/tag"
printf '%s\n' "\$FM_BIN" > "\$FAKE_OUT/fmbin"
printf '%s\n' "\$FM_HOME" > "\$FAKE_OUT/fmhome"
printf '%s\n' "\$@" > "\$FAKE_OUT/args"
SH
    chmod +x "$1/fleet-stats/bin/$reader"
  done
}

# A checkout of this repository's shims with, or without, its own addons/ beside bin/.
write_checkout() {  # write_checkout <dir> [--with-addons <tag>]
  local reader
  mkdir -p "$1/bin"
  for reader in fm-model-stats fm-skill-stats; do cp "$ROOT/bin/$reader.sh" "$1/bin/$reader.sh"; done
  cp "$LIB" "$1/bin/fm-addons-dir-lib.sh"
  [ "${2:-}" = --with-addons ] && write_fake_addons "$1/addons" "$3"
  return 0
}

write_fake_addons "$TMP_ROOT/explicit-addons" explicit
for reader in fm-model-stats fm-skill-stats; do
  shim="$ROOT/bin/$reader.sh"
  out="$TMP_ROOT/out-$reader"
  mkdir -p "$out"

  # The fake add-on receives the shim's args and FM_BIN naming this fork's bin/.
  env -u FM_HOME FAKE_OUT="$out" FM_ADDONS_DIR="$TMP_ROOT/explicit-addons" "$shim" --json --now 1700000000 >"$out/stdout" 2>"$out/stderr"
  [ "$(cat "$out/tag")" = explicit ] || fail "$reader FM_ADDONS_DIR did not win"
  [ "$(cat "$out/args")" = "--json
--now
1700000000" ] || fail "$reader fake add-on got wrong args: $(cat "$out/args")"
  [ "$(cat "$out/fmbin")" = "$ROOT/bin" ] || fail "$reader FM_BIN was '$(cat "$out/fmbin")', want '$ROOT/bin'"
  [ "$(cat "$out/fmhome")" = "$ROOT" ] || fail "$reader with FM_HOME unset passed FM_HOME '$(cat "$out/fmhome")', want '$ROOT'"

  # A missing add-ons directory exits 1 and names FM_ADDONS_DIR on stderr.
  status=0
  FM_ADDONS_DIR="$TMP_ROOT/nowhere" "$shim" --json >"$out/stdout-missing" 2>"$out/stderr-missing" || status=$?
  [ "$status" -eq 1 ] || fail "$reader shim exit with no add-ons was $status, want 1"
  grep -q "FM_ADDONS_DIR" "$out/stderr-missing" || fail "$reader missing-add-ons stderr never names FM_ADDONS_DIR: $(cat "$out/stderr-missing")"
done

# With FM_ADDONS_DIR unset and both present, the in-repo addons/ wins over the clone.
write_checkout "$TMP_ROOT/both" --with-addons in-repo
write_fake_addons "$TMP_ROOT/home-both/projects/firstmate-addons" clone
mkdir -p "$TMP_ROOT/out-both"
env -u FM_ADDONS_DIR FAKE_OUT="$TMP_ROOT/out-both" FM_HOME="$TMP_ROOT/home-both" "$TMP_ROOT/both/bin/fm-skill-stats.sh" --json >"$TMP_ROOT/out-both/stdout" 2>"$TMP_ROOT/out-both/stderr"
[ "$(cat "$TMP_ROOT/out-both/tag" 2>/dev/null)" = in-repo ] || fail "the clone ran while the in-repo addons/ existed"
[ "$(cat "$TMP_ROOT/out-both/args")" = "--json" ] || fail "in-repo add-on got wrong args: $(cat "$TMP_ROOT/out-both/args")"
[ "$(cat "$TMP_ROOT/out-both/fmbin")" = "$TMP_ROOT/both/bin" ] || fail "in-repo FM_BIN was '$(cat "$TMP_ROOT/out-both/fmbin")', want '$TMP_ROOT/both/bin'"
[ "$(cat "$TMP_ROOT/out-both/fmhome")" = "$TMP_ROOT/home-both" ] || fail "in-repo FM_HOME was '$(cat "$TMP_ROOT/out-both/fmhome")', want '$TMP_ROOT/home-both'"

# A checkout with no addons/ still resolves the clone, so a live home keeps working before the move.
write_checkout "$TMP_ROOT/clone-only"
write_fake_addons "$TMP_ROOT/home-clone/projects/firstmate-addons" clone
mkdir -p "$TMP_ROOT/out-clone"
env -u FM_ADDONS_DIR FAKE_OUT="$TMP_ROOT/out-clone" FM_HOME="$TMP_ROOT/home-clone" "$TMP_ROOT/clone-only/bin/fm-model-stats.sh" --json >"$TMP_ROOT/out-clone/stdout" 2>"$TMP_ROOT/out-clone/stderr"
[ "$(cat "$TMP_ROOT/out-clone/tag" 2>/dev/null)" = clone ] || fail "the clone did not answer for a checkout with no addons/"
[ "$(cat "$TMP_ROOT/out-clone/fmbin")" = "$TMP_ROOT/clone-only/bin" ] || fail "clone FM_BIN was '$(cat "$TMP_ROOT/out-clone/fmbin")', want '$TMP_ROOT/clone-only/bin'"

pass "fm-model-stats and fm-skill-stats shims delegate with FM_BIN, prefer the in-repo add-ons, and still resolve the clone"
