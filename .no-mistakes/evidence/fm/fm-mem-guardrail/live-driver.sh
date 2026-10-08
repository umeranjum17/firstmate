#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=/home/umer/.no-mistakes/evidence/01M4CT545F00ZMBN7DDRKETEBP
LAB=$(mktemp -d "$PWD/.gate-test-tmp/live.XXXXXX")
watcher=
cleanup() {
  if [ -n "$watcher" ]; then kill -TERM "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true; fi
  rm -rf "$LAB"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_HOST_MEMORY_PROC FM_HOST_MEMORY_CGROUP_ROOT FM_GATE_REFUSE_BYPASS
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'tmux\n' > "$LAB/config/backend"
printf 'wait_pressure=0\nalert_pressure=1000\nwait_available_gb=0\nalert_available_gb=0\n' > "$LAB/config/host-memory"
mkdir -p "$LAB/projects/demo"
git -C "$LAB/projects/demo" init -q
{
 echo '=== Real host measurement and persisted sample ==='
 bin/fm-jev-mem-guard.sh --record "$LAB/state/host-memory.tsv" --state-dir "$LAB" "$LAB/state"
 echo '=== Fresh scout admission refuses before an endpoint exists ==='
 set +e
 bin/fm-spawn.sh live-admission projects/demo --scout --harness claude
 rc=$?
 set -e
 echo "spawn exit=$rc"
 test "$rc" -eq 1
 test -s "$LAB/state/admission-refused"
 test ! -e "$LAB/state/live-admission.meta"
 printf 'refusal record: '; cat "$LAB/state/admission-refused"
 echo '=== Raising thresholds admits the same task and clears refusal ==='
 printf 'wait_pressure=1000\nalert_pressure=1000\nwait_available_gb=0\nalert_available_gb=0\n' > "$LAB/config/host-memory"
 bin/fm-jev-mem-guard.sh --config "$LAB/config/host-memory" --admit live-admission --state "$LAB/state"
 test ! -e "$LAB/state/admission-refused"
 echo 'admission exit=0; refusal record removed'
} > "$E/live-admission.log" 2>&1
cat > "$LAB/state/slow.check.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/check-entered"
while [ ! -e "$FM_HOME/check-release" ]; do sleep 0.1; done
SH
chmod 700 "$LAB/state/slow.check.sh"
bin/fm-check-register.sh slow > "$E/live-check-registration.log"
FM_BACKEND=tmux TMUX='' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 bin/fm-watch.sh > "$E/live-watch.log" 2> "$E/live-watch.stderr" &
watcher=$!
for i in {1..100}; do [ ! -e "$LAB/check-entered" ] || break; sleep 0.1; done
test -e "$LAB/check-entered"
# An actual /proc measurement triggers ALERT by supported thresholds, not fake sensor data.
printf 'wait_pressure=0\nalert_pressure=0\nwait_available_gb=0\nalert_available_gb=0\n' > "$LAB/config/host-memory.next"
mv "$LAB/config/host-memory.next" "$LAB/config/host-memory"
for i in {1..150}; do [ ! -s "$LAB/state/.wake-queue" ] || break; sleep 0.1; done
test -e "$LAB/state/.host-memory-alerted"
test -s "$LAB/state/.wake-queue"
kill -0 "$watcher"
cp "$LAB/state/host-memory.tsv" "$E/live-samples.tsv"
cp "$LAB/state/host-memory-interrupts.tsv" "$E/live-interrupts.tsv"
cp "$LAB/state/.wake-queue" "$E/live-wake-queue.tsv"
{
 echo '=== Independent sampler while public custom check remains blocked ==='
 echo 'watcher is still alive; check-release does not exist'
 cat "$LAB/state/host-memory.tsv"
 cat "$LAB/state/host-memory-interrupts.tsv"
 cat "$LAB/state/.wake-queue"
} > "$E/live-sampling.log"
: > "$LAB/check-release"
for i in {1..100}; do kill -0 "$watcher" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$watcher" 2>/dev/null; then echo 'watcher did not deliver queued alert' >&2; exit 1; fi
wait "$watcher"
watcher=
test ! -e "$LAB/state/.host-memory-sampler.pid"
echo 'watcher exited after delivering memory alert; owned sampler pid record removed' >> "$E/live-sampling.log"
# Real generated unit consumer: neither install nor enable any host service.
SPACE="$LAB/Space Home"
mkdir -p "$SPACE"
FM_HOME="$SPACE" bin/fm-sentinel.sh unit > "$E/sentinel-space.service"
systemd-analyze verify "$E/sentinel-space.service" > "$E/sentinel-verify.log" 2>&1
printf 'Live CLI checks completed; disposable home removed by EXIT trap.\n'
