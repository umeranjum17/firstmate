#!/usr/bin/env bash
# Integration: run the real bin/fm-task-outcome.sh over isolated durable task
# records and read the appended outcome row the way the stats reader does.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-outcome)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
SCRIPTS="$ROOT/bin"

record() {  # <id> [--force]
  FM_HOME="$HOME_DIR" bash "$SCRIPTS/fm-task-outcome.sh" "$@"
}

row_for() {  # <id>: the task-outcome data row, or empty
  awk -F'\t' -v id="$1" 'NR > 1 && $2 == id { print }' "$HOME_DIR/data/metrics/task-outcomes.tsv"
}

meta() {  # <id> <lines...>
  local id=$1
  shift
  mkdir -p "$HOME_DIR/state"
  printf '%s\n' "$@" > "$HOME_DIR/state/$id.meta"
}

# 1. A landed ship with a relaunch that changed model: both incarnations, in order.
meta rl-ship "kind=ship" "project=/home/x/projects/acme" "harness=claude" "model=claude-opus-5-5" "effort=medium" \
  "spawn_gen=s1700000200.9.abc" "pr=https://github.com/acme/app/pull/7"
printf '1700000000\tclaude\tclaude-opus-5-5\tmedium\n1700000500\tpi\topencode-go/muse-spark-1.3-contributor\thigh\n' \
  > "$HOME_DIR/state/rl-ship.models"
record rl-ship
line=$(row_for rl-ship)
[ -n "$line" ] || fail "no outcome row for a landed ship"
IFS=$'\t' read -r h t k p models started ended outcome pr <<EOF
$line
EOF
assert_equals main "$h" "home name"
assert_equals rl-ship "$t" "task id"
assert_equals ship "$k" "kind"
assert_equals acme "$p" "project basename"
assert_equals 'claude:claude-opus-5-5:medium;pi:opencode-go/muse-spark-1.3-contributor:high' "$models" "every incarnation in order"
assert_equals 1700000000 "$started" "spawn time is the first launch"
assert_equals merged "$outcome" "a non-forced teardown of landed work is merged"
assert_equals 'https://github.com/acme/app/pull/7' "$pr" "PR URL recorded"
case "$ended" in '' | *[!0-9]*) fail "end time is not a unix stamp: $ended" ;; esac
pass "landed ship records its full model history in order"

# 2. Discarded with a failed last status: failed wins over closed.
meta rl-failed "kind=ship" "harness=pi" "model=opencode-go/deepseek-v4.1-flash" "effort=medium" "pr=https://github.com/acme/app/pull/8"
printf 'failed [at=1700000100]: checks broke\n' > "$HOME_DIR/state/rl-failed.status"
record rl-failed --force
assert_contains "$(row_for rl-failed)" $'\tfailed\t' "a failed last status is recorded as failed"

# 3. Discarded with a PR and no failure: closed without merge.
meta rl-closed "kind=ship" "harness=pi" "model=muse" "effort=medium" "pr=https://github.com/acme/app/pull/9"
printf 'working [at=1700000100]: building\n' > "$HOME_DIR/state/rl-closed.status"
record rl-closed --force
assert_contains "$(row_for rl-closed)" $'\tclosed\t' "a discarded task with a PR is closed"

# 4. Discarded with no PR: cancelled.
meta rl-cancel "kind=ship" "harness=pi" "model=muse" "effort=medium"
record rl-cancel --force
assert_contains "$(row_for rl-cancel)" $'\tcancelled\t' "a discarded task with no PR is cancelled"

# 5. Scout report.
meta rl-scout "kind=scout" "harness=claude" "model=claude-opus-5-5" "effort=high"
record rl-scout
assert_contains "$(row_for rl-scout)" $'\tscout\t' "a scout records its report outcome"

# 6. No history file: fall back to the record's final model and spawn_gen epoch.
meta rl-legacy "kind=ship" "harness=claude" "model=claude-opus-5-5" "effort=xhigh" "spawn_gen=s1700000300.7.def" "pr=https://github.com/acme/app/pull/10"
record rl-legacy
line=$(row_for rl-legacy)
assert_contains "$line" $'claude:claude-opus-5-5:xhigh' "fallback uses the record's final model"
assert_contains "$line" $'\t1700000300\t' "fallback reads the spawn_gen epoch"

# 7. A secondmate retirement is not a task: nothing is appended.
meta rl-secondmate "kind=secondmate" "harness=pi" "model=muse" "effort=medium"
before=$(wc -l < "$HOME_DIR/data/metrics/task-outcomes.tsv")
record rl-secondmate
after=$(wc -l < "$HOME_DIR/data/metrics/task-outcomes.tsv")
assert_equals "$before" "$after" "a secondmate retirement appends nothing"

# 8. Missing record is a silent no-op, not a failure.
record rl-absent || fail "a missing record should not fail"
assert_equals "$after" "$(wc -l < "$HOME_DIR/data/metrics/task-outcomes.tsv")" "a missing record appends nothing"

# 9. The header is written once, and every data row has its columns.
assert_equals 'home	task	kind	project	models	started	ended	outcome	pr' "$(head -n 1 "$HOME_DIR/data/metrics/task-outcomes.tsv")" "one header row"
assert_equals "$(awk -F'\t' 'NR > 1 { print NF }' "$HOME_DIR/data/metrics/task-outcomes.tsv" | sort -u)" "9" "every row has nine columns"
pass "discard, scout, fallback and skip paths all record correctly"
