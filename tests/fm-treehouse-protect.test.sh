#!/usr/bin/env bash
# Behavior tests for bin/fm-treehouse-protect.py, the pre-allocation lease step
# that both spawn and secondmate seeding run before `treehouse get --lease`.
#
# A recorded task copy that Treehouse no longer tracks as usable (missing from
# its state, marked destroying, or no longer a git worktree) must be skipped
# with one warning naming the task and path, never abort allocation for the
# whole repo. Every other copy still gets leased, and the skipped copy is left
# exactly as it was.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROTECT="$ROOT/bin/fm-treehouse-protect.py"
TMP_ROOT=$(fm_test_tmproot fm-treehouse-protect)

# make_pool <case> : repo at <case>/repo, pool at <case>/pool with healthy slot 1,
# and a meta store at <case>/state. Echoes nothing; sets CASE_DIR, REPO, POOL, STATE.
make_pool() {
  CASE_DIR="$TMP_ROOT/$1"
  REPO="$CASE_DIR/repo"
  POOL="$CASE_DIR/pool"
  STATE="$CASE_DIR/state"
  fm_git_init_commit "$REPO"
  mkdir -p "$POOL/1" "$STATE"
  git -C "$REPO" worktree add -q "$POOL/1/repo" -b slot-1
  fm_write_meta "$STATE/task-1.meta" "worktree=$POOL/1/repo" "project=$REPO" "kind=ship"
}

# add_slot <n> <entry-json>: add a recorded worktree under the pool with the
# given treehouse-state entry JSON (empty string means no state entry).
add_slot() {
  local n=$1 entry=$2
  mkdir -p "$POOL/$n"
  git -C "$REPO" worktree add -q "$POOL/$n/repo" -b "slot-$n"
  fm_write_meta "$STATE/task-$n.meta" "worktree=$POOL/$n/repo" "project=$REPO" "kind=ship"
  SLOT_ENTRIES+=("$entry")
}

# write_state: writes treehouse-state.json from the slot entries collected so far.
write_state() {
  python3 -I - "$POOL/treehouse-state.json" "$POOL" "${SLOT_ENTRIES[@]}" <<'PY'
import json, sys
out, pool, *entries = sys.argv[1:]
worktrees = []
for raw in entries:
    if raw:
        worktrees.append(json.loads(raw))
json.dump({"worktrees": worktrees}, open(out, "w"))
PY
}

# protect_run: runs the protect step over the case's state dir.
protect_run() {
  python3 -I "$PROTECT" "$REPO" "$STATE" >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"
}

# entry_field <n> <field>: prints a field of slot n's treehouse-state entry.
entry_field() {
  python3 -I - "$POOL/treehouse-state.json" "$POOL/$1/repo" "$2" <<'PY'
import json, sys
state, path, field = sys.argv[1:]
for entry in json.load(open(state))["worktrees"]:
    if entry["path"] == path:
        print(json.dumps(entry.get(field)))
        break
else:
    print("absent")
PY
}

SLOT_ENTRIES=()

test_healthy_copy_is_leased_without_warning() {
  make_pool healthy
  SLOT_ENTRIES=('{"path":"'"$POOL/1/repo"'","leased":false}')
  write_state
  protect_run || fail "protect refused a healthy recorded copy: $(cat "$CASE_DIR/stderr")"
  [ "$(entry_field 1 leased)" = true ] || fail "healthy recorded copy was not leased"
  [ "$(entry_field 1 lease_holder)" = '"task-1"' ] || fail "lease holder was not the recording task"
  [ ! -s "$CASE_DIR/stderr" ] || fail "healthy copy produced a warning: $(cat "$CASE_DIR/stderr")"
  pass "a healthy recorded copy is leased with no warning"
}

test_copy_missing_from_treehouse_state_is_skipped() {
  make_pool missing
  SLOT_ENTRIES=('{"path":"'"$POOL/1/repo"'","leased":false}')
  add_slot 2 ''
  write_state
  protect_run || fail "a copy missing from Treehouse state aborted allocation: $(cat "$CASE_DIR/stderr")"
  assert_contains "$(cat "$CASE_DIR/stderr")" "task-2" "the warning did not name the skipped task"
  assert_contains "$(cat "$CASE_DIR/stderr")" "$POOL/2/repo" "the warning did not name the skipped path"
  [ "$(entry_field 1 leased)" = true ] || fail "the healthy copy was not leased beside a missing one"
  [ "$(entry_field 2 leased)" = absent ] || fail "a copy missing from state was given a state entry"
  pass "a copy missing from Treehouse state is skipped with a warning and allocation continues"
}

test_destroying_copy_is_skipped() {
  make_pool destroying
  SLOT_ENTRIES=('{"path":"'"$POOL/1/repo"'","leased":false}')
  add_slot 2 '{"path":"'"$POOL/2/repo"'","destroying":true}'
  write_state
  protect_run || fail "a destroying copy aborted allocation: $(cat "$CASE_DIR/stderr")"
  assert_contains "$(cat "$CASE_DIR/stderr")" "task-2" "the warning did not name the destroying task"
  [ "$(entry_field 1 leased)" = true ] || fail "the healthy copy was not leased beside a destroying one"
  [ "$(entry_field 2 destroying)" = true ] || fail "the destroying entry was rewritten"
  [ "$(entry_field 2 leased)" != true ] || fail "a destroying copy was leased"
  pass "a destroying copy is skipped with a warning and the healthy copy is still leased"
}

test_copy_that_is_no_longer_a_worktree_is_skipped() {
  make_pool notworktree
  SLOT_ENTRIES=('{"path":"'"$POOL/1/repo"'","leased":false}')
  add_slot 2 '{"path":"'"$POOL/2/repo"'","leased":false}'
  printf 'gitdir: %s\n' "$CASE_DIR/gone" > "$POOL/2/repo/.git"
  write_state
  protect_run || fail "a copy that is no longer a git worktree aborted allocation: $(cat "$CASE_DIR/stderr")"
  assert_contains "$(cat "$CASE_DIR/stderr")" "task-2" "the warning did not name the unusable task"
  assert_contains "$(cat "$CASE_DIR/stderr")" "$POOL/2/repo" "the warning did not name the unusable path"
  [ "$(entry_field 1 leased)" = true ] || fail "the healthy copy was not leased beside an unusable one"
  [ "$(entry_field 2 leased)" = false ] || fail "an unusable copy was leased"
  pass "a copy that is no longer a git worktree is skipped with a warning and allocation continues"
}

test_duplicate_owner_still_refuses() {
  make_pool duplicate
  SLOT_ENTRIES=('{"path":"'"$POOL/1/repo"'","leased":false}')
  write_state
  fm_write_meta "$STATE/task-dup.meta" "worktree=$POOL/1/repo" "project=$REPO" "kind=ship"
  protect_run && fail "two records naming one copy were not refused"
  assert_contains "$(cat "$CASE_DIR/stderr")" "recorded by both" "the duplicate refusal did not name the conflict"
  pass "two records naming one copy still refuse allocation"
}

test_healthy_copy_is_leased_without_warning
test_copy_missing_from_treehouse_state_is_skipped
test_destroying_copy_is_skipped
test_copy_that_is_no_longer_a_worktree_is_skipped
test_duplicate_owner_still_refuses

echo "# all fm-treehouse-protect tests passed"
