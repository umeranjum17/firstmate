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

# The first-draft design gate: yes needs a PASS receipt for this head with a
# `first-draft receipt:` evidence line; no passes; a missing call warns and passes.
head=1111111111111111111111111111111111111111
rec=$home/state/task.run-receipt.json
mkmeta() { printf 'worktree=%s\n%b' "$root" "$1" > "$home/state/task.meta"; }
receipt() {  # <verdict> <head> <evidence>
  jq -n --arg v "$1" --arg h "$2" --arg e "$3" '{schema:1,task:"task",head:$h,verdict:$v,evidence:$e,at:1}' > "$rec"
}
gate() { jg_dod_design_gate "$home/state" task "$home/state/task.meta" "$head" 2>&1; }

mkmeta 'design_call=no\n'
gate >/dev/null || fail "design_call=no must pass"
pass "design gate passes a no task"

mkmeta ''
out=$(gate) || fail "missing design_call must pass: $out"
assert_contains "$out" "counting it as design_call=no" "missing call did not warn"
pass "design gate warns and passes a missing call"

mkmeta 'design_call=yes\n'
rm -f "$rec"
out=$(gate) && fail "yes task without a receipt must be refused"
assert_contains "$out" "merge refused" "no-receipt refusal"
receipt PASS "$head" "ran tests"
out=$(gate) && fail "yes task without a first-draft line must be refused"
receipt PASS "$head" $'notes\nfirst-draft receipt: fd-123'
gate >/dev/null || fail "yes task with a first-draft receipt line must pass"
receipt FAIL "$head" $'first-draft receipt: fd-123'
gate >/dev/null && fail "a FAIL receipt must be refused"
receipt PASS 2222222222222222222222222222222222222222 $'first-draft receipt: fd-123'
gate >/dev/null && fail "a receipt for another head must be refused"
mkmeta 'design_call=bogus\n'
gate >/dev/null && fail "a malformed call must be refused"
pass "design gate refuses a yes task without a bound first-draft receipt line"
