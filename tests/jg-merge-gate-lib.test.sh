#!/usr/bin/env bash
# The core merge adapters hand config/merge-gate and config/post-merge their home
# under JG_HOME and under FM_HOME (the pre-rename name installed hooks still read).
# Each hook here reads FM_HOME the way the merge-card hook does and refuses to run
# without it, with only JG_HOME set in the caller's environment.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

root=$(jg_test_tmproot merge-gate-lib) || fail "no fixture root"
home=$root/home
mkdir -p "$home/config" "$home/state"
printf 'worktree=%s\n' "$root" > "$home/state/task.meta"
jg_dod_meta_value() { sed -n "s/^$2=//p" "$1" | tail -1; }
# shellcheck source=bin/jg-merge-gate-lib.sh
. "$ROOT/bin/jg-merge-gate-lib.sh"
unset FM_HOME
export JG_HOME=$home

for kind in merge-gate post-merge; do
  cat > "$home/config/$kind" <<HOOK
#!/usr/bin/env bash
echo "$kind: \${FM_HOME:?$kind: FM_HOME is not set} jg=\$JG_HOME"
HOOK
  chmod +x "$home/config/$kind"
done

out=$(jg_dod_merge_gate "$home/config" "$home" task "$home/state/task.meta" abc -) \
  || fail "merge gate refused with only JG_HOME set: $out"
assert_equals "merge-gate: $home jg=$home" "$out" "merge gate saw the home under both names"
pass "merge gate receives FM_HOME from JG_HOME"

out=$(jg_merge_post_hook "$home/config" "$home" task "$home/state/task.meta" abc - 2>&1)
assert_equals "post-merge: $home jg=$home" "$out" "post-merge hook saw the home under both names"
assert_not_contains "$out" "FM_HOME is not set" "post-merge hook lost FM_HOME"
pass "post-merge hook receives FM_HOME from JG_HOME and exits 0"
