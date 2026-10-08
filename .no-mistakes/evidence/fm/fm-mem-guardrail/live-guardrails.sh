#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/home/umer/.no-mistakes/evidence/01M4CT545F00ZMBN7DDRKETEBP
mkdir -p .validation
LAB=$(mktemp -d "$PWD/.validation/fm-lab.XXXXXX")
watcher=''
cleanup() { [ -z "$watcher" ] || { kill -TERM "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true; }; rm -rf "$LAB"; }
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_HOST_MEMORY_PROC FM_HOST_MEMORY_CGROUP_ROOT
export FM_HOME="$LAB" HERDR_SESSION=fm-lab-memory-proof
printf 'wait_pressure=0\nalert_pressure=101\nwait_available_gb=0\nalert_available_gb=0\n' > "$LAB/config/host-memory"
for kind in ship scout secondmate; do
  case "$kind" in ship) args=(guard-ship "$PWD" --mode local-only --yolo off);; scout) args=(guard-scout "$PWD" --scout);; secondmate) args=(guard-mate --secondmate);; esac
  set +e
  bin/fm-spawn.sh "${args[@]}" > "$LAB/$kind.out" 2>&1
  rc=$?
  set -e
  printf '\n=== real host admission: %s rc=%s ===\n' "$kind" "$rc"
  cat "$LAB/$kind.out"
  [ "$rc" -eq 1 ]
  grep -q 'stays queued until host memory eases' "$LAB/$kind.out"
  [ ! -e "$LAB/state/${args[0]}.meta" ]
  cat "$LAB/state/admission-refused"
done
printf 'wait_pressure=101\nalert_pressure=101\nwait_available_gb=0\nalert_available_gb=0\n' > "$LAB/config/host-memory"
bin/fm-jev-mem-guard.sh --config "$LAB/config/host-memory" --admit guard-ship --state "$LAB/state"
[ ! -e "$LAB/state/admission-refused" ]
printf '\n=== healthy admission clears refusal ===\n'
bin/fm-jev-mem-guard.sh --record "$E/live-host-sample.tsv" --state-dir "$LAB" "$LAB/state"
cat > "$LAB/state/slow.check.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/entered"
while [ ! -e "$FM_HOME/release" ]; do sleep 0.1; done
SH
chmod 700 "$LAB/state/slow.check.sh"
bin/fm-check-register.sh slow
FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 bin/fm-watch.sh > "$LAB/watcher.out" 2> "$LAB/watcher.err" & watcher=$!
for ((i=0;i<100;i++)); do [ ! -e "$LAB/entered" ] || break; sleep 0.1; done
[ -e "$LAB/entered" ]
printf 'wait_pressure=0\nalert_pressure=0\nwait_available_gb=0\nalert_available_gb=0\n' > "$LAB/config/host-memory"
for ((i=0;i<150;i++)); do grep -q $'\tcheck\thost-memory\t' "$LAB/state/.wake-queue" 2>/dev/null && break; sleep 0.1; done
grep -q $'\tcheck\thost-memory\t' "$LAB/state/.wake-queue"
kill -0 "$watcher"
printf '\n=== real host sampler ALERT while supervision check blocks ===\n'
cat "$LAB/state/host-memory.tsv" "$LAB/state/host-memory-interrupts.tsv" "$LAB/state/.wake-queue"
cp "$LAB/state/host-memory.tsv" "$E/live-sampler.tsv"
cp "$LAB/state/host-memory-interrupts.tsv" "$E/live-interrupt-decision.tsv"
python3 - "$LAB/state/host-memory.tsv" <<'PY'
import sys
rows=[line.rstrip().split('\t') for line in open(sys.argv[1])]
assert len(rows)>=2 and rows[-1][-1]=='ALERT'
assert 8 <= int(rows[1][0])-int(rows[0][0]) <= 13, rows
PY
: > "$LAB/release"
for ((i=0;i<100;i++)); do kill -0 "$watcher" 2>/dev/null || break; sleep 0.1; done
wait "$watcher"; watcher=''
cat "$LAB/watcher.out" "$LAB/watcher.err"
printf '\n=== real systemd unit output: home with spaces ===\n'
mkdir -p "$LAB/Fleet Home"
FM_HOME="$LAB/Fleet Home" bin/fm-sentinel.sh unit > "$E/fm-sentinel.service"
systemd-analyze verify "$E/fm-sentinel.service"
cat "$E/fm-sentinel.service"
printf '\n=== dashboard generated from real host and sampler state ===\n'
bin/fm-jev-mem-guard.sh --config "$LAB/config/host-memory" --admit dashboard-proof --state "$LAB/state" || [ "$?" -eq 1 ]
bin/fm-dashboard.sh build
cp "$LAB/state/dashboard/index.html" "$E/dashboard.html"
printf '\nLive driver completed; disposable home removed by trap.\n'
