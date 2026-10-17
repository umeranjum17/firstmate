#!/usr/bin/env bash
# Integration check for bin/fm-mem-gate.sh, run with stub commands, fixture memory files and private lock dirs.
# Usage: fm-mem-gate.test.sh [gate-script]   exit 0 = PASS. Never starts a real emulator or Gradle build.
# 1. (lock-deadlock regression) an emulator job that waits for an emulator slot must not hold the host
#    lock while it sleeps, so a Gradle job with room gets through.
# 2. (wrapper-resolution regression: more emulators than the cap) a job behind known wrappers (flock, timeout,
#    nice, ionice, env, bash/sh -c) is still held at the emulator or Gradle cap, and starts when there is a slot.
G=${1:-$(dirname "$(readlink -f "$0")")/../bin/fm-mem-gate.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run" "$T/run2" "$T/proc/pressure"
cat > "$T/bin/emulator" <<'STUB'
#!/bin/sh
echo "$0 $*" >> "$MARK"
STUB
cp "$T/bin/emulator" "$T/bin/gradlew"
# pgrep answers the gate's two counts: Gradle builds (-cf 'appname=gradle[w]') and emulators (-c '^qemu-system').
cat > "$T/bin/pgrep" <<'STUB'
#!/bin/sh
case "$*" in *gradle*) echo "${STUB_BUILDS:-0}";; *) echo "${STUB_EMUS:-0}";; esac
STUB
printf '#!/bin/sh\nexit 1\n' > "$T/bin/systemd-run"  # no fm-heavy.slice scope in the test; the gate falls back to nice
chmod +x "$T"/bin/*
echo 'MemAvailable:   67108864 kB' > "$T/proc/meminfo"  # 64 GB free and no pressure: only a cap can hold a job
echo 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0' > "$T/proc/pressure/memory"
export PATH=$T/bin:$PATH XDG_RUNTIME_DIR=$T/run FM_MEM_GATE_PROC=$T/proc MARK=$T/ran FM_MEM_MIN_GB=0
fail=0

FM_EMU_MAX=0 setsid "$G" "$T/bin/emulator" 2>/dev/null & w=$!
sleep 2
FM_GRADLE_MAX=99 timeout 25 "$G" "$T/bin/gradlew" 2>/dev/null; rc=$?
kill -- -$w 2>/dev/null; wait $w 2>/dev/null
[ $rc = 0 ] && echo "PASS lock not held while waiting" || { echo "FAIL rc=$rc (Gradle job stuck behind the waiting emulator job)"; fail=1; }
# That started Gradle job leaves a 30 s holder on its host lock; the wrapper checks use their own lock dir.
export XDG_RUNTIME_DIR=$T/run2

held() {  # <want in the waiting line> <command...>: at the cap the gate waits and never starts the job
  want=$1; shift; rm -f "$MARK"
  timeout 3 "$G" "$@" >/dev/null 2>"$T/err"
  if [ ! -e "$MARK" ] && grep -q "waiting.*$want" "$T/err"; then echo "PASS held: $*"
  else echo "FAIL not held at the cap ($want): $*"; sed 's/^/  /' "$T/err" "$MARK" 2>/dev/null; fail=1; fi
}
STUB_EMUS=2 held 'emulators 2' flock "$T/job.lock" timeout 60 bash -c "emulator -avd pairfail -no-window"
STUB_EMUS=2 held 'emulators 2' flock -w 10 "$T/job.lock" -c "env ANDROID_AVD_HOME=$T emulator -avd x"
STUB_BUILDS=1 held 'builds 1' nice -n 5 ionice -c2 -n7 env -u X JAVA_OPTS=-Xmx1g timeout -k 5 600 sh -ec "exec ./gradlew assembleDebug"

started() {  # <command...>: with a free slot the job runs through its wrappers
  rm -f "$MARK"
  timeout 10 "$G" "$@" >/dev/null 2>"$T/err"
  if [ -s "$MARK" ]; then echo "PASS started: $*"; else echo "FAIL not started: $*"; sed 's/^/  /' "$T/err"; fail=1; fi
}
# Last: a started emulator or Gradle job leaves a 30 s holder on the host lock, which would stall a later check.
# shellcheck disable=SC2016  # $MARK expands in the job's own shell
STUB_EMUS=2 started timeout 60 bash -c 'echo emulator-5554 > "$MARK"'  # an emulator serial in args is not an emulator
STUB_EMUS=1 started flock "$T/job.lock" timeout 60 bash -c "emulator -avd pairfail -no-window"

[ $fail = 0 ] && echo PASS || echo FAIL
[ $fail = 0 ]
