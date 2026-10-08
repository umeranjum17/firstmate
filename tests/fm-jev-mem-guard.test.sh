#!/usr/bin/env bash
# Behavior tests for the host memory guard (bin/fm-jev-mem-guard.sh): its
# verdicts and recorded samples against a fixture proc tree, the owner mapping
# that names the largest consumers by task, and admission publication.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

GUARD="$ROOT/bin/fm-jev-mem-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-mem-guard)
export FM_HOST_MEMORY_CGROUP_ROOT="$TMP_ROOT/no-cgroup"

# fake_host <proc> <available-gb> <pressure-avg10> [swap-used-gb]
fake_host() {
  local proc=$1 swap_used=${4:-0}
  mkdir -p "$proc/pressure"
  printf 'MemTotal:       67108864 kB\nMemAvailable:   %s kB\nSwapTotal:      33554432 kB\nSwapFree:       %s kB\n' \
    "$(($2 * 1048576))" "$((33554432 - swap_used * 1048576))" > "$proc/meminfo"
  printf 'some avg10=%s avg60=1.00 avg300=1.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' "$3" \
    > "$proc/pressure/memory"
}

# fake_pid <proc> <pid> <name> <rss-gb> <cwd> [FM_TASK_ID]
fake_pid() {
  local dir="$1/$2"
  mkdir -p "$dir"
  printf 'Name:\t%s\nVmRSS:\t%s kB\nVmSwap:\t0 kB\n' "$3" "$(($4 * 1048576))" > "$dir/status"
  ln -s "$5" "$dir/cwd"
  if [ -n "${6:-}" ]; then printf 'PATH=/bin\0FM_TASK_ID=%s\0' "$6" > "$dir/environ"; else printf 'PATH=/bin\0' > "$dir/environ"; fi
}

# A home with one ship task, one lead, and processes owned by the task (by
# working directory and a path-qualified FM_TASK_ID), by the lead,
# and by nothing Firstmate records.
make_fleet() {
  local case=$1
  mkdir -p "$case/state" "$case/wt/sub" "$case/mate/state"
  fm_write_meta "$case/state/big-build.meta" kind=ship "worktree=$case/wt"
  fm_write_meta "$case/state/sm1.meta" kind=secondmate "home=$case/mate"
  fake_pid "$case/proc" 101 node 9 "$case/wt/sub"
  fake_pid "$case/proc" 102 java 5 "$case/wt" big-build
  fake_pid "$case/proc" 103 claude 2 "$case/mate"
  fake_pid "$case/proc" 104 llama 6 /
}

test_verdicts_samples_and_owners() {
  local case=$TMP_ROOT/verdicts out rc tsv
  case=$TMP_ROOT/verdicts tsv=$case/state/host-memory.tsv
  make_fleet "$case"
  fake_host "$case/proc" 40 2.5 1
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --record "$tsv" --state-dir "$case" "$case/state")
  assert_equals $'OK\tpressure 2% (10 s average), 40.0 GB available, 1.0 GB swap used; cgroup pressure unreadable; host-only classification' "$out" "calm host"
  fake_host "$case/proc" 30 24 3
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --record "$tsv" --state-dir "$case" "$case/state")
  assert_equals $'WAIT\tpressure 24% (10 s average), 30.0 GB available, 3.0 GB swap used; cgroup pressure unreadable; host-only classification; pressure at or above 20%' "$out" \
    "pressure past the wait threshold makes new agents wait"
  fake_host "$case/proc" 5 41.2 16
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --record "$tsv" --state-dir "$case" "$case/state")
  assert_equals $'ALERT\tpressure 41% (10 s average), 5.0 GB available, 16.0 GB swap used; cgroup pressure unreadable; host-only classification; pressure at or above 35%; available memory below 6 GB; largest: task big-build (main) 14.0 GB in 2 processes, llama pid 104 6.0 GB, lead sm1 2.0 GB' "$out" \
    "an alert names the largest consumers by task, lead, or process"
  [ "$(wc -l < "$tsv" | tr -d ' ')" -eq 3 ] || fail "three samples should be recorded: $(cat "$tsv")"
  assert_equals $'5242880\t16777216\t41.20\tALERT' "$(tail -n 1 "$tsv" | cut -f2-)" "the sample row carries available kB, swap kB, pressure, verdict"
  # Thresholds come from the one config file; a broken one is refused with its line.
  printf '# tighter host\nalert_pressure=50\nalert_available_gb=1\nwait_pressure = 10\n' > "$case/host-memory"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --config "$case/host-memory")
  assert_contains "$out" "pressure at or above 10%" "config thresholds replace the defaults"
  printf 'alert_pressure=lots\n' > "$case/host-memory"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --config "$case/host-memory" 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "an invalid config must exit 2, got $rc: $out"
  assert_contains "$out" "line 1: 'alert_pressure=lots'" "the invalid line is named"
  # Not measurable: no verdict is invented and nothing is recorded.
  out=$(FM_HOST_MEMORY_PROC="$case/none" "$GUARD" --record "$tsv")
  assert_contains "$out" "UNKNOWN" "an unmeasurable host reads unknown"
  [ "$(wc -l < "$tsv" | tr -d ' ')" -eq 3 ] || fail "an unmeasurable sample was recorded"
  pass "verdicts, recorded samples, and owner mapping follow the host"
}

test_cgroup_pressure() {
  local case=$TMP_ROOT/cgroup out rc group=user.slice/user-123.slice/user@123.service/app.slice/herdr-server.service
  fake_host "$case/proc" 40 2
  mkdir -p "$case/proc/self" "$case/cgroup/$group" "$case/state"
  printf '0::/%s/child\n' "$group" > "$case/proc/self/cgroup"
  printf 'some avg10=58.88 avg60=0 avg300=0 total=1\n' > "$case/cgroup/$group/memory.pressure"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --record "$case/state/sample")
  assert_contains "$out" $'ALERT\tpressure 59%' "cgroup pressure dominates a calm host"
  assert_contains "$out" 'host 2%, cgroup 59%' "the independent measurements are visible"
  assert_equals '58.88' "$(cut -f4 "$case/state/sample")" "the recorded pressure is the worse signal"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD" --admit build --state "$case/state"); rc=$?
  [ "$rc" -eq 1 ] || fail "critical cgroup pressure admitted work: $out"
  rm "$case/cgroup/$group/memory.pressure"
  mkdir -p "$case/cgroup/user.slice/user-123.slice"
  printf 'some avg10=24 avg60=0 avg300=0 total=1\n' > "$case/cgroup/user.slice/user-123.slice/memory.pressure"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD")
  assert_contains "$out" $'WAIT\tpressure 24%' "the parent user slice is measured when the unit is unreadable"
  rm "$case/cgroup/user.slice/user-123.slice/memory.pressure"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" FM_HOST_MEMORY_CGROUP_ROOT="$case/cgroup" "$GUARD")
  assert_contains "$out" 'host-only classification' "unreadable cgroup pressure is explicit"
  pass "cgroup pressure participates in classification and admission"
}

test_home_qualified_owners() {
  local case=$TMP_ROOT/owners out
  make_fleet "$case"
  fake_host "$case/proc" 5 41
  fake_pid "$case/proc" 107 foreign 25 "$TMP_ROOT/independent-home/wt" big-build
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --state-dir "$case" "$case/state" --owned-top-task "$case/state")
  assert_contains "$out" 'foreign pid 107 25.0 GB, task big-build (main) 14.0 GB in 2 processes' "a unique visible ID still requires recorded path ownership"
  assert_equals '' "${out##*$'\t'}" "an independent home's matching ID cannot authorize control"
  fm_write_meta "$case/state/big-build.meta" kind=ship "worktree=$case/wt" "tasktmp=${case}-tmp"
  rm "$case/proc/107/cwd"
  ln -s "${case}-tmp" "$case/proc/107/cwd"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --state-dir "$case" "$case/state" --owned-top-task "$case/state")
  assert_contains "$out" "foreign pid 107 25.0 GB" "a temp path outside the explicit home is not a worktree"
  assert_equals '' "${out##*$'\t'}" "an external temp path cannot authorize control"
  rm -r "$case/proc/107"
  fm_write_meta "$case/mate/state/big-build.meta" kind=ship "worktree=$case/mate/wt"
  mkdir -p "$case/mate/wt"
  fake_pid "$case/proc" 105 java 20 "$case/mate/wt" big-build
  fake_pid "$case/proc" 106 node 10 "$case/mate" big-build
  rm "$case/proc/102/cwd"
  ln -s "$case/wt" "$case/proc/102/cwd"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --state-dir "$case" "$case/state" --state-dir "$case/mate" "$case/mate/state" --owned-top-task "$case/state")
  assert_contains "$out" 'task big-build (sm1) 30.0 GB in 2 processes, task big-build (main) 14.0 GB in 2 processes' "equal task IDs remain separate owners"
  assert_equals '' "${out##*$'\t'}" "a foreign top task cannot be interrupted by this home"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --state-dir "$case" "$case/state" --state-dir "$case/mate" "$case/mate/state" --owned-top-task "$case/mate/state")
  assert_equals big-build "${out##*$'\t'}" "the owning home receives its exact task ID"
  printf 'Name:\tpi\nVmRSS:\t41943040 kB\nVmSwap:\t0 kB\n' > "$case/proc/103/status"
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --state-dir "$case" "$case/state" --state-dir "$case/mate" "$case/mate/state" --owned-top-task "$case/state")
  assert_equals sm1 "${out##*$'\t'}" "a lead is controlled only through its parent-owned task record"
  pass "task ownership stays home-qualified through grouping and control selection"
}

test_homes_without_ordinary_tasks() {
  local case=$TMP_ROOT/home-fallback mode out
  mkdir -p "$case/mate/state"
  fake_host "$case/proc" 5 41
  fake_pid "$case/proc" 101 pi 9 "$case"
  fake_pid "$case/proc" 102 claude 9 "$case"
  fake_pid "$case/proc" 103 pi 10 "$case/mate"
  fake_pid "$case/proc" 104 claude 10 "$case/mate"
  fake_pid "$case/proc" 105 java 15 "$TMP_ROOT/unowned-a"
  fake_pid "$case/proc" 106 node 14 "$TMP_ROOT/unowned-b"
  for mode in missing empty secondmate remote; do
    case "$mode" in
      empty) mkdir -p "$case/state" ;;
      secondmate) fm_write_meta "$case/state/sm1.meta" kind=secondmate "home=$case/mate" ;;
      remote) fm_write_meta "$case/state/sm1.meta" kind=secondmate remote_host=other "home=$case/mate" ;;
    esac
    out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --state-dir "$case" "$case/state" --state-dir "$case/mate" "$case/mate/state" --owned-top-task "$case/state")
    assert_contains "$out" 'lead main 18.0 GB in 2 processes' "$mode home aggregates supervisors into the top three"
    if [ "$mode" = secondmate ]; then
      assert_equals sm1 "${out##*$'\t'}" "secondmate-only state retains parent-owned control"
      out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --state-dir "$case/mate" "$case/mate/state" --state-dir "$case" "$case/state" --owned-top-task "$case/mate/state")
      assert_contains "$out" 'largest: lead sm1 20.0 GB in 2 processes, lead main 18.0 GB in 2 processes' "empty child state preserves the parent owner"
      assert_equals '' "${out##*$'\t'}" "child fallback cannot authorize parent-owned control"
      out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --state-dir "$case" "$case/state" --state-dir "$case/mate" "$case/mate/state" --owned-top-task "$case/state")
      assert_equals sm1 "${out##*$'\t'}" "parent ownership is independent of argument order"
    else
      assert_equals '' "${out##*$'\t'}" "$mode fallback does not authorize task control"
    fi
  done
  pass "explicit homes aggregate without ordinary tasks and preserve parent ownership"
}

test_remote_records_do_not_own_local_processes() {
  local case=$TMP_ROOT/remote-owners home wt out
  home=$case/main wt=$case/pool/build
  mkdir -p "$home/state" "$wt/sub"
  fm_write_meta "$home/state/big-build.meta" kind=ship "worktree=$wt"
  fm_write_meta "$home/state/a-remote.meta" kind=secondmate remote_host=other "home=$wt"
  fm_write_meta "$home/state/b-remote.meta" kind=ship remote_host=other "worktree=$wt"
  fm_write_meta "$home/state/c-remote.meta" kind=secondmate remote_host=other "home=$home"
  fake_host "$case/proc" 5 41
  fake_pid "$case/proc" 101 node 9 "$wt/sub"
  fake_pid "$case/proc" 102 java 5 "$wt" big-build
  out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --state-dir "$home" "$home/state" --owned-top-task "$home/state")
  assert_contains "$out" 'largest: task big-build (main) 14.0 GB in 2 processes' \
    "remote task paths and lead homes cannot steal tagged or untagged local processes"
  assert_equals big-build "${out##*$'\t'}" "the local task remains the interrupt target"
  pass "remote records never own local processes or label local homes"
}

test_finite_thresholds() {
  local case=$TMP_ROOT/thresholds key value out rc
  fake_host "$case/proc" 30 25
  for key in wait_pressure alert_pressure wait_available_gb alert_available_gb; do
    for value in nan inf -inf; do
      printf '%s=%s\n' "$key" "$value" > "$case/config"
      out=$(FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --config "$case/config" 2>&1); rc=$?
      [ "$rc" -eq 2 ] || fail "$key=$value should be invalid, got $rc: $out"
    done
  done
  pass "all thresholds reject non-finite numbers"
}

test_atomic_admission_publication() {
  local case=$TMP_ROOT/concurrent-admission first second rc1 rc2
  fake_host "$case/proc" 30 25
  mkdir -p "$case/hook" "$case/barrier" "$case/state"
  cat > "$case/hook/sitecustomize.py" <<'PY'
import os
import time

original_replace = os.replace

def replace(src, dst, *args, **kwargs):
    if os.fspath(dst) == os.environ.get("FM_TEST_ADMISSION_DEST"):
        barrier = os.environ["FM_TEST_ADMISSION_BARRIER"]
        with open(os.path.join(barrier, str(os.getpid())), "w"):
            pass
        for _ in range(200):
            if len(os.listdir(barrier)) == 2:
                break
            time.sleep(0.01)
        else:
            raise TimeoutError("the parallel publisher did not reach replacement")
    return original_replace(src, dst, *args, **kwargs)

os.replace = replace
PY
  env PYTHONPATH="$case/hook" FM_TEST_ADMISSION_DEST="$case/state/admission-refused" FM_TEST_ADMISSION_BARRIER="$case/barrier" \
    FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --admit build-a --state "$case/state" > "$case/a.out" 2> "$case/a.err" &
  first=$!
  env PYTHONPATH="$case/hook" FM_TEST_ADMISSION_DEST="$case/state/admission-refused" FM_TEST_ADMISSION_BARRIER="$case/barrier" \
    FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --admit build-b --state "$case/state" > "$case/b.out" 2> "$case/b.err" &
  second=$!
  wait "$first"; rc1=$?
  wait "$second"; rc2=$?
  [ "$rc1" -eq 1 ] && [ "$rc2" -eq 1 ] || fail "parallel refusals lost their pressure result: $(cat "$case/"*.err)"
  [ ! -s "$case/a.err" ] && [ ! -s "$case/b.err" ] || fail "parallel refusals raised an error"
  assert_contains "$(cat "$case/a.out" "$case/b.out")" 'pressure at or above 20%' "both launches report pressure"
  python3 - "$case/state" <<'PY' || fail "the public refusal record was not published intact"
import os
import sys

state = sys.argv[1]
with open(os.path.join(state, "admission-refused")) as f:
    epoch, task, reason = f.read().rstrip("\n").split("\t")
assert epoch.isdigit() and task in ("build-a", "build-b")
assert reason.startswith("host memory under pressure:")
assert os.listdir(state) == ["admission-refused"]
PY
  fake_host "$case/proc" 40 2
  FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --admit build-a --state "$case/state" & first=$!
  FM_HOST_MEMORY_PROC="$case/proc" "$GUARD" --admit build-b --state "$case/state" & second=$!
  wait "$first"; rc1=$?
  wait "$second"; rc2=$?
  [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ ! -e "$case/state/admission-refused" ] || fail "parallel healthy admissions did not clear the refusal record"
  pass "parallel admission publications and clearing are independent"
}

test_verdicts_samples_and_owners
test_cgroup_pressure
test_home_qualified_owners
test_homes_without_ordinary_tasks
test_remote_records_do_not_own_local_processes
test_finite_thresholds
test_atomic_admission_publication
