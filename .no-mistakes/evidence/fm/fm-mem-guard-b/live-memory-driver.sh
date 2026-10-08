#!/usr/bin/env bash
set -eu
E=/home/umer/.no-mistakes/evidence/01M4D9TDDSH7WEDXV3YZH1FMZD
LAB=$(mktemp -d "$PWD/l.XXXX")
WP=''
cleanup() { for f in watch.out watch.err state/.host-memory-sampler.log; do [ ! -f "$LAB/$f" ] || cp "$LAB/$f" "$E/live-$(basename "$f")"; done; [ -z "$WP" ] || { kill "$WP" 2>/dev/null || true; wait "$WP" 2>/dev/null || true; }; TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
export FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" FM_BACKEND=tmux
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_HOST_MEMORY_PROC FM_HOST_MEMORY_CGROUP_ROOT
printf 'wait_pressure=0\nalert_pressure=100\nalert_available_gb=0\n' > "$LAB/config/host-memory"
echo '=== Measured real host, refuse new local agents using configured WAIT threshold ==='
bin/fm-jev-mem-guard.sh --config "$LAB/config/host-memory" --record "$LAB/state/host-memory.tsv"
for kind in ship scout secondmate; do
 args=(memory-$kind projects/none --harness claude)
 case "$kind" in ship) args+=(--mode no-mistakes --yolo off);; scout) args+=(--scout);; secondmate) args+=(--secondmate);; esac
 rc=0; bin/fm-spawn.sh "${args[@]}" > "$LAB/$kind.out" 2>&1 || rc=$?
 echo "$kind exit=$rc"; cat "$LAB/$kind.out"
 grep -q 'stays queued until host memory eases' "$LAB/$kind.out"
 test ! -e "$LAB/state/memory-$kind.meta"
 cat "$LAB/state/admission-refused"
done
echo '=== Start actual Claude in private 120x40 tmux primary; refuse relaunch before touching it ==='
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -n fm-live-primary -x 120 -y 40 -c "$PWD" -e "FM_HOME=$LAB" claude
sleep 8
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary > "$E/claude-primary.txt"
cat "$E/claude-primary.txt"
mkdir -p "$LAB/data/live-primary"
printf 'lab task, do not execute work\n' > "$LAB/data/live-primary/brief.md"
printf 'kind=ship\nharness=claude\nbackend=tmux\nwindow=primary:fm-live-primary\nworktree=%s\nproject=%s\n' "$PWD" "$PWD" > "$LAB/state/live-primary.meta"
cp "$LAB/state/live-primary.meta" "$LAB/meta.before"
BEFORE=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-panes -t primary -F '#{pane_pid} #{pane_dead}')
rc=0; bin/fm-control.sh live-primary relaunch --note 'lab refusal proof only' > "$LAB/relaunch.out" 2>&1 || rc=$?
echo "relaunch exit=$rc"; cat "$LAB/relaunch.out"
grep -q 'refused before its agent was touched' "$LAB/relaunch.out"
cmp "$LAB/meta.before" "$LAB/state/live-primary.meta"
AFTER=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-panes -t primary -F '#{pane_pid} #{pane_dead}')
test "$BEFORE" = "$AFTER"; echo "same live pane before/after: $AFTER"
rm "$LAB/state/live-primary.meta"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$LAB/config/host-memory"
echo '=== Admission clears refusal after relaxing thresholds against same actual host ==='
bin/fm-jev-mem-guard.sh --config "$LAB/config/host-memory" --admit memory-scout --state "$LAB/state"
test ! -e "$LAB/state/admission-refused"
echo 'admission exit=0, durable refusal removed'
echo '=== Independent real sampler retries failed durable wake publication ==='
printf 'alert_pressure=0\n' > "$LAB/config/host-memory"
mkdir "$LAB/state/.wake-queue.seq"
FM_HOST_MEMORY_SECS=1 FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 bin/fm-watch.sh > "$LAB/watch.out" 2> "$LAB/watch.err" & WP=$!
for i in {1..100}; do test ! -f "$LAB/state/host-memory.tsv" || test "$(wc -l < "$LAB/state/host-memory.tsv")" -lt 2 || break; sleep .1; done
test ! -e "$LAB/state/.host-memory-alerted"
echo 'publication unavailable: actual ALERT sample, no committed alert latch'
cat "$LAB/state/host-memory.tsv"
wait "$WP"; WP=''
rmdir "$LAB/state/.wake-queue.seq"
FM_HOST_MEMORY_SECS=1 FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 bin/fm-watch.sh > "$LAB/watch.out" 2> "$LAB/watch.err" & WP=$!
for i in {1..100}; do test ! -s "$LAB/state/.host-memory-alerted" || break; sleep .1; done
test -s "$LAB/state/.host-memory-alerted"
cat "$LAB/state/.wake-queue"
cat "$LAB/state/host-memory-interrupts.tsv"
wait "$WP"; WP=''
cat "$LAB/watch.out"
grep -q 'host memory ALERT' "$LAB/watch.out"
grep -q 'automatic interrupt skipped' "$LAB/state/.wake-queue"
echo 'successful retry: durable ALERT wake surfaced by real watcher; foreign top consumer not interrupted'
echo '=== New real ALERT episode retains its own wake while prior episode remains queued ==='
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$LAB/config/host-memory"
FM_HOST_MEMORY_SECS=1 FM_POLL=1 bin/fm-watch.sh > "$LAB/watch.out" 2> "$LAB/watch.err" & WP=$!
wait "$WP"; WP=''
test ! -e "$LAB/state/.host-memory-alerted"
printf 'alert_pressure=0\n' > "$LAB/config/host-memory"
FM_HOST_MEMORY_SECS=1 FM_POLL=1 bin/fm-watch.sh > "$LAB/watch.out" 2> "$LAB/watch.err" & WP=$!
wait "$WP"; WP=''
test "$(awk -F '\t' '$3=="check" && $4=="host-memory" {n++} END {print n+0}' "$LAB/state/.wake-queue")" -eq 2
cat "$LAB/state/.wake-queue"
echo 'two retained durable wakes for two episodes; old episode did not suppress new publication'
echo '=== Build end-user memory dashboard from recorded actual samples and actual admission refusal ==='
rc=0; bin/fm-jev-mem-guard.sh --config "$LAB/config/host-memory" --admit memory-dashboard-proof --state "$LAB/state" || rc=$?
test "$rc" -eq 1
bin/fm-dashboard.sh build
cp "$LAB/state/dashboard/index.html" "$E/memory-dashboard.html"
cp "$LAB/state/dashboard/data.json" "$E/memory-dashboard-data.json"
echo 'all isolated checks passed; cleanup removes primary, sampler and lab home'
