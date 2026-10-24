#!/usr/bin/env bash
# key-in-env-check e2e: the real check against a fixture home and real fixture processes
# (a key-holding parent with a child worker in a task worktree, and a key-free worker).
# Proves the hit names pid, home, task, variable and topmost parent, a canary value never
# reaches any output or file, a repeat run is silent and a changed set wakes again.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
bin=${KEY_IN_ENV_BIN:-$here/../key-in-env-check}
[ -x "$bin" ] || { echo "not ok - $bin is missing"; exit 1; }
work=$(mktemp -d) || exit 1
pids=()
# shellcheck disable=SC2317,SC2329 # runs through the EXIT trap
cleanup() { # only the fixture processes this test started: their children first, then the roots
  for p in "${pids[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  rm -rf -- "$work"
}
trap cleanup EXIT
fail=0
ok() { echo "ok - $1"; }
no() { echo "not ok - $1"; fail=1; }

canary=CANARY-$$-$RANDOM-sk-or-v1-deadbeef
home=$work/pool/1/firstmate
mkdir -p "$home/state" "$work/wt-a" "$work/wt-b"
printf 'worktree=%s\nendpoint_task_id=task-a\n' "$work/wt-a" > "$home/state/task-a.meta"
export FM_HOME=$home FM_KEY_HOMES=$home

# Fixture trees run under setsid with an empty environment so nothing real (the live fleet's
# keys, the test shell's own parents) is picked up; FM_KEY_TREES scopes the scan to them.
# tree A: a parent holding the key that runs a child worker in the task worktree (key inherited).
# tree B: a worker with no key.
root() { # root <pidfile> <cwd> <env assignment or -> <exec command...>
  local pf=$1 cwd=$2 asg=$3; shift 3
  # shellcheck disable=SC2016 # the script is for the inner bash
  setsid -f env -i PATH="$PATH" bash -c 'echo $$ > "$1"; cd "$2"; shift 2; [ "$1" = - ] || export "$1"; shift; exec "$@"' _ "$pf" "$cwd" "$asg" "$@" </dev/null >/dev/null 2>&1
  for _ in $(seq 100); do [ -s "$pf" ] && break; sleep 0.1; done
  [ -s "$pf" ] || { echo "not ok - fixture root did not start"; exit 1; }
  pids+=("$(cat "$pf")")
}
root "$work/a.pid" "$work/wt-a" "OPENROUTER_API_KEY=$canary" bash -c 'sleep 300 & wait'
root "$work/b.pid" "$work/wt-b" - sleep 300
sleep 1
export FM_KEY_TREES=${pids[0]},${pids[1]}
child=$(pgrep -P "${pids[0]}" sleep | head -n 1)

run() { "$bin" >"$work/out" 2>"$work/err"; }
run
inc=$home/state/key-in-env.incidents
line=$(awk -F'\t' -v p="$child" '$1==p' "$inc")
IFS=$'\t' read -r _ h t v top <<<"$line"
[ -n "$line" ] && ok "child worker listed" || no "child worker missing from $inc"
case "$h" in */1) ok "home attributed ($h)" ;; *) no "home is '$h'" ;; esac
[ "$t" = task-a ] && ok "task attributed" || no "task is '$t'"
[ "$v" = OPENROUTER_API_KEY ] && ok "variable named" || no "variable is '$v'"
[ "$top" = "bash(${pids[0]})" ] && ok "topmost parent named ($top)" || no "topmost is '$top'"
grep -q "key-in-env: " "$work/out" && grep -q "task-a" "$work/out" && ok "wake line printed" || no "no wake line"

run
[ ! -s "$work/out" ] && ok "second run silent (de-duplicated)" || no "second run woke again"

# the key-free process in wt-b is never listed
[ "$(wc -l < "$inc")" -eq 2 ] && ok "key-free process not listed" || no "key-free process listed"

# a new carrier changes the set
root "$work/c.pid" "$work/wt-b" "ANTHROPIC_API_KEY=$canary" sleep 301
export FM_KEY_TREES=$FM_KEY_TREES,${pids[2]}
run
grep -q "key-in-env: " "$work/out" && ok "changed set wakes again" || no "changed set stayed silent"

# a custom pattern list narrows the match
FM_KEY_PATTERNS='NOTHING_*' run
[ ! -s "$inc" ] && ok "custom pattern list empties the match" || no "custom patterns ignored"
unset FM_KEY_PATTERNS

# the canary value is nowhere in anything the check wrote or printed
if grep -rqF -- "$canary" "$work/out" "$work/err" "$home" 2>/dev/null; then no "canary value leaked"; else ok "canary value absent from output, errors, incident file and state"; fi
kill -0 "${pids[0]}" 2>/dev/null && ok "no process signalled" || no "fixture daemon died"

exit "$fail"
