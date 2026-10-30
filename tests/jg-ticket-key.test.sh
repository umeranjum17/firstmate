#!/usr/bin/env bash
# Behavior tests for bin/jg-ticket-key.sh and its wrapper hooks in bin/jg-tasks-axi.sh:
# a retired number is never reused, a key resolves to its slug and the slug to its key,
# and the backfill is deterministic.
set -u
export JG_TASK_PRIORITY_CHECK=/nonexistent

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/jg-tasks-axi.sh"
KEYTOOL="$ROOT/bin/jg-ticket-key.sh"
TMP_ROOT=$(jg_test_tmproot jg-ticket-key)
unset TASKS_AXI_FILE TASKS_AXI_BACKEND JG_HOME JG_ROOT_OVERRIDE JG_DATA_OVERRIDE JG_STATE_OVERRIDE JG_CONFIG_OVERRIDE

if ! command -v tasks-axi >/dev/null 2>&1; then
  echo "skip: tasks-axi not found; ticket key cases not run"
  exit 0
fi

make_home() {  # <name>; prints the case directory
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/code" "$dir/hm/data" "$dir/hm/state" "$dir/hm/config"
  jg_test_tasks_toml "$dir/code/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/hm/data/backlog.md"
  : > "$dir/hm/config/backlog-intake-loose"
  printf 'JG\n' > "$dir/hm/config/ticket-prefix"
  printf '%s\n' "$dir"
}
run() {  # <case-dir> <wrapper args...>
  local dir=$1
  shift
  (cd "$dir/code" && JG_HOME="$dir/hm" JG_ROOT_OVERRIDE="$dir/code" "$WRAPPER" "$@")
}
keytool() {  # <case-dir> <args...>
  local dir=$1
  shift
  JG_HOME="$dir/hm" "$KEYTOOL" "$@"
}

test_counter_never_reuses_a_number() {
  local dir out
  dir=$(make_home counter)
  run "$dir" add t-a "first" >/dev/null || fail "add failed"
  run "$dir" add t-b "second" >/dev/null || fail "add failed"
  assert_equals "JG-1" "$(keytool "$dir" key-of t-a)" "first ticket key"
  assert_equals "JG-2" "$(keytool "$dir" key-of t-b)" "second ticket key"
  run "$dir" "done" t-b --no-prune >/dev/null || fail "close failed"
  run "$dir" rm t-a >/dev/null || fail "delete failed"
  run "$dir" add t-c "third" >/dev/null || fail "add failed"
  out=$(keytool "$dir" key-of t-c)
  assert_equals "JG-3" "$out" "a closed or deleted ticket's number was reused"
  printf 'JG\t1\n' > "$dir/hm/data/ticket-counters.tsv"
  run "$dir" add t-d "fourth" >/dev/null || fail "add failed"
  assert_equals "JG-4" "$(keytool "$dir" key-of t-d)" "a stale counter let a taken number out"
  pass "the key counter never reuses a number, even after a close, a delete or a stale counter"
}

test_key_collision_is_refused() {
  local dir out rc=0
  dir=$(make_home collision)
  run "$dir" add t-a "first" >/dev/null || fail "add failed"
  out=$(keytool "$dir" assign t-a)
  assert_equals "JG-1" "$out" "assigning a keyed ticket again must return its key"
  assert_equals "1" "$(wc -l < "$dir/hm/data/ticket-keys.tsv" | tr -d ' ')" "a second assign stored the key twice"
  rm "$dir/hm/config/ticket-prefix"
  keytool "$dir" assign t-z >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "assign with no registered prefix"
  printf 'toolong\n' > "$dir/hm/config/ticket-prefix"
  rc=0
  keytool "$dir" assign t-z >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "assign with a prefix that is not 2-4 capital letters"
  pass "a key is never stored twice and a bad or missing prefix is refused"
}

test_alias_resolves_both_ways() {
  local dir
  dir=$(make_home alias)
  run "$dir" add t-a "[feature] alias target" --kind ship --body "summary line" >/dev/null || fail "add failed"
  assert_contains "$(run "$dir" show JG-1)" "id: t-a" "show by key did not reach the slug"
  assert_contains "$(run "$dir" show t-a)" "key: JG-1" "show by slug did not print its key"
  assert_equals "t-a" "$(keytool "$dir" resolve JG-1)" "key did not resolve to the slug"
  assert_equals "t-a" "$(keytool "$dir" resolve t-a)" "slug did not resolve to itself"
  assert_contains "$(run "$dir" list --keys)" "JG-1  t-a," "list --keys did not put the key first"
  assert_not_contains "$(run "$dir" list)" "JG-1" "plain list changed its machine format"
  pass "a key and its slug address the same ticket in both directions"
}

test_backfill_is_deterministic() {
  local dir a b
  dir=$(make_home backfill)
  cat > "$dir/hm/data/backlog.md" <<'BL'
## In flight
- [ ] zeta-2 - [feature] Later one (priority: 1) (since 2026-10-02)
  Captain, 2 Oct: "make it quick"

  Fix: do it.
- [ ] alpha-1 - [feature] Older one (priority: 1) (since 2026-10-01)
  plain reason line
- [ ] beta-1 - [feature] Same day as alpha (priority: 1) (since 2026-10-01)
  other reason

## Queued

## Done
BL
  keytool "$dir" sync || fail "sync failed"
  a=$(cat "$dir/hm/data/ticket-keys.tsv")
  assert_equals "$(printf 'JG-1\talpha-1\nJG-2\tbeta-1\nJG-3\tzeta-2')" "$a" "keys did not follow creation order"
  rm "$dir/hm/data/ticket-keys.tsv" "$dir/hm/data/ticket-counters.tsv"
  keytool "$dir" sync || fail "second sync failed"
  b=$(cat "$dir/hm/data/ticket-keys.tsv")
  assert_equals "$a" "$b" "the same backlog gave different keys"
  pass "backfill orders by creation date, gives the same keys twice"
}

test_counter_never_reuses_a_number
test_key_collision_is_refused
test_alias_resolves_both_ways
test_backfill_is_deterministic
