#!/usr/bin/env bash
# Behavior tests for the fm-spawn.sh config/spawn-gate pre-spawn gate.
#
# The gate runs for fresh ship and scout spawns only, before anything is
# created: a refusing gate stops the spawn with its own output, an absent gate
# changes nothing, and secondmate spawns never run it. Passing cases fail fast
# at the missing-brief check (secondmate at the home check), which is reached
# before any tmux/treehouse side effect, so the tests create no windows or
# worktrees.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-gate)
export FM_BACKEND=tmux

# A fresh temp firstmate home per case. projects/<name> is a git fixture so
# path resolution reaches the missing-brief check; data/ holds no brief, so a
# spawn that passes the gate fails there without side effects.
make_home() {
  local home=$1
  mkdir -p "$home/data" "$home/config" "$home/projects/none"
  git -C "$home/projects/none" init -q || fail "could not initialize project fixture"
}

run_spawn_home() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_HOME="$home" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# An absent gate changes nothing: the ship spawn sails past the gate point and
# fails at the missing-brief check with no gate text.
test_gate_absent_passes() {
  local home=$TMP_ROOT/absent out status
  make_home "$home"
  out=$(run_spawn_home "$home" nope-gate-absent-z1 projects/none --mode no-mistakes --yolo off --harness 'true worker')
  status=$?
  [ "$status" -ne 0 ] || fail "ship spawn with missing brief should exit non-zero"
  printf '%s\n' "$out" | grep -F 'has no brief' >/dev/null \
    || fail "absent-gate spawn did not reach the missing-brief check: $out"
  printf '%s\n' "$out" | grep -F 'config/spawn-gate' >/dev/null \
    && fail "absent gate left a trace in the output: $out"
  pass "absent gate passes the spawn through to the missing-brief check"
}

# A refusing gate stops a scout spawn with its own text, runs with FM_HOME set
# and the task id as its argument, and creates nothing.
test_refusing_gate_blocks_scout() {
  local home=$TMP_ROOT/refuse out status
  make_home "$home"
  cat >"$home/config/spawn-gate" <<'EOF'
#!/bin/sh
printf 'FM_HOME=%s id=%s\n' "$FM_HOME" "$1" >> "$FM_HOME/gate-seen.log"
echo "lane cap reached: 2 of 2 open"
exit 1
EOF
  chmod +x "$home/config/spawn-gate"
  out=$(run_spawn_home "$home" nope-gate-refuse-z2 projects/none --scout --harness 'true worker')
  status=$?
  [ "$status" -ne 0 ] || fail "gate-refused spawn should exit non-zero"
  printf '%s\n' "$out" | grep -F 'lane cap reached: 2 of 2 open' >/dev/null \
    || fail "refused spawn did not print the gate output: $out"
  printf '%s\n' "$out" | grep -F 'spawn refused by config/spawn-gate' >/dev/null \
    || fail "refused spawn did not name the gate: $out"
  grep -F "FM_HOME=$home id=nope-gate-refuse-z2" "$home/gate-seen.log" >/dev/null \
    || fail "gate did not receive FM_HOME and the task id"
  [ ! -e "$home/state/nope-gate-refuse-z2.meta" ] \
    || fail "refused spawn created a task record"
  [ ! -e "$home/state" ] || [ -z "$(ls -A "$home/state")" ] \
    || fail "refused spawn created state: $(ls "$home/state")"
  pass "refusing gate blocks the scout with its text and creates nothing"
}

# An allowing gate lets the spawn through to the missing-brief check.
test_allowing_gate_passes() {
  local home=$TMP_ROOT/allow out status
  make_home "$home"
  printf '#!/bin/sh\nexit 0\n' >"$home/config/spawn-gate"
  chmod +x "$home/config/spawn-gate"
  out=$(run_spawn_home "$home" nope-gate-allow-z3 projects/none --scout --harness 'true worker')
  status=$?
  [ "$status" -ne 0 ] || fail "spawn with missing brief should exit non-zero"
  printf '%s\n' "$out" | grep -F 'has no brief' >/dev/null \
    || fail "allowed spawn did not reach the missing-brief check: $out"
  pass "allowing gate passes the spawn through to the missing-brief check"
}

# A secondmate spawn never runs the gate, even a refusing one: it sails past
# the gate point and fails at the secondmate home check instead.
test_secondmate_ignores_refusing_gate() {
  local home=$TMP_ROOT/secondmate out status
  make_home "$home"
  cat >"$home/config/spawn-gate" <<'EOF'
#!/bin/sh
echo "gate ran" >> "$FM_HOME/gate-seen.log"
echo "lane cap reached: 2 of 2 open"
exit 1
EOF
  chmod +x "$home/config/spawn-gate"
  out=$(run_spawn_home "$home" mate-gate-z4 / --secondmate --harness 'true worker')
  status=$?
  [ "$status" -ne 0 ] || fail "secondmate spawn with a root home should exit non-zero"
  printf '%s\n' "$out" | grep -F 'cannot be the filesystem root' >/dev/null \
    || fail "secondmate spawn did not reach its home check: $out"
  printf '%s\n' "$out" | grep -F 'lane cap reached' >/dev/null \
    && fail "secondmate spawn ran the refusing gate"
  [ ! -e "$home/gate-seen.log" ] \
    || fail "secondmate spawn executed the gate"
  pass "secondmate spawn ignores the refusing gate"
}

# A host under memory pressure refuses every launch kind before anything is
# created, records why in state/admission-refused, and a calm host lets the same
# spawn through and clears the record.
test_host_memory_pressure_refuses_launches() {
  local home=$TMP_ROOT/memory proc out status
  make_home "$home"
  proc=$home/proc
  mkdir -p "$proc/pressure"
  printf 'MemTotal: 67108864 kB\nMemAvailable: 31457280 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$proc/meminfo"
  printf 'some avg10=42.00 avg60=30.00 avg300=10.00 total=1\n' > "$proc/pressure/memory"
  out=$(FM_HOST_MEMORY_PROC=$proc run_spawn_home "$home" nope-mem-z5 projects/none --scout --harness 'true worker')
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn under memory pressure should be refused"
  assert_contains "$out" "host memory under pressure: pressure at or above 35%" "the refusal names the pressure"
  assert_contains "$out" "task nope-mem-z5 stays queued" "the refusal says the task stays queued"
  assert_contains "$(cat "$home/state/admission-refused")" $'\tnope-mem-z5\thost memory under pressure' \
    "the refusal is recorded for the queue views"
  [ ! -e "$home/state/nope-mem-z5.meta" ] || fail "a refused spawn created a task record"
  out=$(FM_HOST_MEMORY_PROC=$proc run_spawn_home "$home" mate-mem-z6 / --secondmate --harness 'true worker')
  assert_contains "$out" "task mate-mem-z6 stays queued" "a secondmate launch is refused too"
  printf 'some avg10=1.00 avg60=1.00 avg300=1.00 total=1\n' > "$proc/pressure/memory"
  out=$(FM_HOST_MEMORY_PROC=$proc run_spawn_home "$home" nope-mem-z5 projects/none --scout --harness 'true worker')
  assert_contains "$out" "has no brief" "a calm host lets the spawn through"
  [ ! -e "$home/state/admission-refused" ] || fail "an admitted spawn left the refusal record behind"
  pass "host memory pressure refuses every launch kind and records why"
}

test_gate_absent_passes
test_refusing_gate_blocks_scout
test_allowing_gate_passes
test_secondmate_ignores_refusing_gate
test_host_memory_pressure_refuses_launches
