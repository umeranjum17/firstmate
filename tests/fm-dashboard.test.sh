#!/usr/bin/env bash
# Behavior tests for bin/fm-dashboard.sh: build the pages from a small fixture
# fleet through the real script and the real tasks-axi, with stub herdr,
# quota-axi and device probes on PATH, then read each page's visible text
# the way a person would, and over `serve`.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# A page's visible text, one space between words.
page_text() {  # <page>
  python3 - "$1" <<'PY'
import html, re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'<(style|title)>.*?</\1>', ' ', s, flags=re.S)
print(re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', ' ', s))))
PY
}

has() {  # <page> <want>...: every phrase is in the page's visible text
  local page=$1 text want
  shift
  text=$(page_text "$page")
  for want in "$@"; do
    case "$text" in *"$want"*) ;; *) fail "$(basename "$page") lacks '$want': $text" ;; esac
  done
}

lacks() {  # <page> <phrase>...
  local page=$1 text bad
  shift
  text=$(page_text "$page")
  for bad in "$@"; do
    case "$text" in *"$bad"*) fail "$(basename "$page") shows '$bad': $text" ;; esac
  done
}

iso() {  # <hours ago> -> UTC ISO time
  python3 -c 'import sys; from datetime import datetime, timedelta, timezone as z
print((datetime.now(z.utc) - timedelta(hours=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"
}

lane() {  # <home> <task> <kind> <status line>...: a lane record whose last status line sets its state
  local home=$1 task=$2 kind=$3
  shift 3
  fm_write_meta "$home/state/$task.meta" "kind=$kind" "project=alpha" "harness=claude" "model=model-a" "herdr_pane_id=pane-$task"
  printf '%s\n' "$@" > "$home/state/$task.status"
}

summary() {  # <home> <state> <epoch> [json fields]: the summary a home publishes about itself
  printf '{"schema":"fm-secondmate-home-summary.v1","home":"%s","state":"%s","generated_epoch":%s%s}\n' "$1" "$2" "$3" "${4:+,$4}" > "$1/state/home-summary.json"
}

# A fleet of Main, one active lead (zephyrine) and one parked lead (beta).
# Lanes: Main has 2 building, 1 validating, 1 blocked, 1 on a decision, 1 finished,
# 1 waiting; zephyrine has 1 building; parked beta has 1 building that no total counts.
# Plan: Main 6 from config/lane-caps, every other home 3 from config/lane-target.
# Landed and closed today: one item each in Main and zephyrine; a day ago, 4 lanes were stuck.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" now today z b stubs
  now=$(date +%s) today=$(date +%F)
  z="$home/mates/zephyrine" b="$home/mates/beta" stubs="$home/stubs"
  mkdir -p "$home/data/metrics" "$home/state" "$home/config" "$z/data" "$z/state" "$b/data" "$b/state" "$stubs"
  printf -- '- zephyrine - made-up domain (home: %s; scope: made-up work; projects: alpha; added 2026-07-11)\n- beta - parked domain (home: %s; scope: parked; projects: alpha; added 2026-07-11)\n' \
    "$z" "$b" > "$home/data/secondmates.md"
  printf 'beta  # parked by the captain\n' > "$home/config/parked-homes"
  printf '3\n' > "$home/config/lane-target"
  printf 'main 6\n' > "$home/config/lane-caps"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] m-build - Build the main thing (repo: alpha) (kind: ship) (since $today)

## Queued
- [ ] m-ready - Start the ready thing (repo: alpha) (kind: ship) (since $today)
- [ ] m-held - Wait for the captain's call (repo: alpha) (kind: ship) (since 2026-10-01) (hold: needs his call) (hold-kind: captain)
- [ ] m-after - After the ready thing blocked-by: m-ready (repo: alpha) (kind: ship) (since $today)

## Done
- [x] m-shipped - Ship the main thing (repo: alpha) (kind: ship) (merged $today)
- [x] m-old - Landed long ago (repo: alpha) (kind: ship) (merged 2026-07-10)
EOF
  # The archive repeats an item still in the backlog; it counts once.
  printf -- '- [x] m-shipped - Ship the main thing (repo: alpha) (kind: ship) (merged %s)\n' "$today" > "$home/data/done-archive.md"
  cat > "$z/data/backlog.md" <<EOF
## Queued
- [ ] z-ready - Start the zephyrine thing (repo: alpha) (kind: ship) (since $today)

## Done
- [x] z-shipped - Ship the zephyrine thing (repo: alpha) (kind: ship) (merged $today)
EOF
  cat > "$b/data/backlog.md" <<EOF
## In flight
- [ ] b-stale - A parked home's stale lane (repo: alpha) (kind: ship) (since 2026-10-01)
EOF
  lane "$home" m-build ship "working [at=$((now - 600))]: building"
  lane "$home" m-resume ship "blocked [at=$((now - 900))]: tests fail" "resolved [at=$((now - 300))]: back on it"
  lane "$home" m-ci ship "paused [at=$((now - 1200))]: waiting for CI checks https://github.com/acme/alpha/pull/9"
  lane "$home" m-stuck ship "blocked [at=$((now - 7200))]: cannot reach the build server"
  lane "$home" m-ask ship "needs-decision [at=$((now - 3600))] [key=scope]: which layout"
  lane "$home" m-done ship "done [at=$((now - 1800))]: PR https://github.com/acme/alpha/pull/8 checks green"
  lane "$home" m-wait scout "paused [at=$((now - 2400))]: waiting for the vendor's reply"
  lane "$z" z-build ship "working [at=$((now - 60))]: building"
  lane "$b" b-stale ship "working [at=$((now - 60))]: building"
  fm_write_meta "$home/state/zephyrine.meta" "kind=secondmate" "harness=claude" "model=lead-model" "herdr_pane_id=pane-lead"
  summary "$home" no_active_work "$now" '"endpoints":[{"id":"zephyrine","endpoint":{"exists":true,"agent_alive":"alive"}}]'
  summary "$z" active_child_work "$now"
  # Merges: zephyrine's on Main's channel for it, Main's own in its fleet ledger, which starts 2 days ago.
  printf 'done [key=merged-z-shipped] [at=%s]: merged z-shipped https://github.com/acme/alpha/pull/5\n' "$((now - 120))" > "$home/state/zephyrine.status"
  printf '{"ts":%s,"event":"ledger.started"}\n{"ts":%s,"event":"task.merged","task":"m-shipped","pr":"https://github.com/acme/alpha/pull/4"}\n' \
    "$((now - 172800))" "$((now - 60))" > "$home/state/fleet-ledger.jsonl"
  mkdir -p "$home/state/dashboard"
  printf '%s\t5\t4\t0\n' "$((now - 86400))" > "$home/state/dashboard/history.tsv"
  # Quota: Codex runs out in 2 h, before its 5-hour window resets in 4 h; Claude has room.
  printf '{"schemaVersion":6,"providers":[{"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"5h","label":"5 hours","percentRemaining":20,"resetsAt":"%s"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","runway":{"status":"projected_exhaustion","projectedExhaustedAt":"%s","limitingWindowId":"5h"}}]}},{"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"7d","label":"7 days","percentRemaining":90,"resetsAt":"%s"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","runway":{"status":"through_reset"}}]}}]}\n' \
    "$(iso -4)" "$(iso -2.05)" "$(iso -72)" > "$home/quota.json"
  jq --argjson at "$now" '{at:$at,data:.}' "$home/quota.json" > "$home/state/dashboard/.quota.json"
  printf '#!/bin/sh\necho called > "%s/quota.called"\nexit 1\n' "$home" > "$stubs/quota-axi"
  # Agents: a busy lead, a busy Main, one busy and one idle worker, one busy unknown agent, and a parked-home worker.
  cat > "$home/herdr.json" <<EOF
{"result":{"agents":[
 {"agent":"claude","agent_status":"working","cwd":"$z","pane_id":"pane-lead","name":"lead"},
 {"agent":"claude","agent_status":"working","cwd":"$home","pane_id":"pane-main","name":"main"},
 {"agent":"claude","agent_status":"working","cwd":"/wt/1","pane_id":"pane-m-build","name":"w1"},
 {"agent":"claude","agent_status":"idle","cwd":"/wt/2","pane_id":"pane-m-ask","name":"w2"},
 {"agent":"codex","agent_status":"working","cwd":"/elsewhere/odd-job","pane_id":"pane-x","name":"odd-job"},
 {"agent":"claude","agent_status":"working","cwd":"/wt/3","pane_id":"pane-b-stale","name":"w3"}]}}
EOF
  cat > "$stubs/herdr" <<EOF
#!/bin/sh
[ -e "$home/herdr.fail" ] && { echo 'herdr: server not running' >&2; exit 1; }
cat "$home/herdr.json"
EOF
  # No device or emulator unless a test adds one, and no heavy-job slice to ask.
  printf '#!/bin/sh\nprintf "List of devices attached\\n\\n"\n' > "$stubs/adb"
  printf '#!/bin/sh\nexit 1\n' > "$stubs/pgrep"
  printf '#!/bin/sh\necho "no user bus" >&2\nexit 1\n' > "$stubs/systemctl"
  mkdir -p "$home/locks"
  chmod +x "$stubs/herdr" "$stubs/adb" "$stubs/pgrep" "$stubs/systemctl" "$stubs/quota-axi"
  printf '%s\n' "$home"
}

build() {  # <home> [env...]: build with the fixture's stubs first on PATH
  local home=$1 out
  shift
  out=$(env PATH="$home/stubs:$PATH" FM_HOME="$home" FM_DEVICE_LOCK_DIR="$home/locks" "$@" "$DASH" build 2>&1) || fail "build failed: $out"
  [ "$out" = "$home/state/dashboard/index.html" ] || fail "build did not print the page path: $out"
}

test_overview_answers_the_four_questions_with_sums_that_add_up() {
  local home d now
  home=$(make_home overview)
  d="$home/state/dashboard"
  build "$home"
  for p in index backlog backlog.home measure; do
    [ -s "$d/$p.html" ] || fail "no $p page"
    ! grep -Eq '<script|https?://[^"]*\.(css|js)"' "$d/$p.html" || fail "$p is not self-contained"
  done
  # Chips name each spot with a number and an age; tiles compare with yesterday and the sample a day ago.
  has "$d/index.html" "Nothing needs you. ✕ 2 stuck 2 h ▲ 1 to land 30 min ▲ 1 held for triage 7 d ▲ 1 idle with ready work today" \
    "Landed today at least 2" "Closed 7 d 2 +2" "Lanes open 8 of 9 +3 3 building · 1 free" "Stuck 2 -2 1 blocked · oldest 2 h" \
    "Quota runs out 2 h" "Codex before its reset" "Codex out" "Claude resets"
  # Each lane is in one state and each queued item has one reason, summing to their totals.
  has "$d/index.html" "Blocked 1 2 h" "On a decision 1 1 h" "Finished, not landed 1 30 min" "Validating or CI 1 20 min" \
    "Waiting on other 1 40 min" "Building 3 10 min" "Queued 1 + 1 + 1 + 0 + 1 = 4" \
    "Ship the main thing Main" "Ship the zephyrine thing zephyrine" "Main 7 of 6 1 at least 1 1 zephyrine 1 of 3 1 at least 1 1" \
    "beta is parked by the captain and left out of every total."
  # The busy parts sum to the busy total, and the denominator is every running Herdr agent
  # outside parked homes (6 listed, 1 in parked beta), not the lane plan of 9.
  running=$(jq '[.result.agents[] | select(.pane_id != "pane-b-stale")] | length' "$home/herdr.json")
  [ "$running" = 5 ] || fail "fixture should list 5 running agents outside parked homes, has $running"
  has "$d/backlog.html" "Busy now 1 + 1 + 1 + 1 = 4" "the groups list all $running running agents"
  lacks "$d/index.html" "A parked home's stale lane" "w3"
  # Main's ask list is the only thing in the hero; held items are a slow spot, never "Waiting on you".
  now=$(date +%s)
  printf 'first\t%s\tApprove the release\thttps://example.invalid/release\nsecond\t%s\tChoose a date\t\n' \
    "$((now - 7200))" "$((now - 3600))" > "$home/data/captain-asks.tsv"
  build "$home"
  has "$d/index.html" "2 things need you. Approve the release 2 h Choose a date 1 h"
  grep -q 'href="https://example.invalid/release"' "$d/index.html" || fail "ask URL not linked"
  # A blank row, or one without an id or text, is not an ask; a real ask with a bad time still counts.
  printf '\nbad row\n\t%s\tNo id\t\nfourth\t%s\t\t\nfifth\tsoon\tFix the time\t\n' "$now" "$now" >> "$home/data/captain-asks.tsv"
  build "$home"
  has "$d/index.html" "3 things need you." "Approve the release" "Choose a date" "Ask record needs correction"
  lacks "$d/index.html" "No id" "4 things need you." "5 things need you."
  has "$d/measure.html" "data/captain-asks.tsv row 4 skipped: no id or text" "row 5 skipped: no id or text" \
    "row 6 skipped: no id or text" "data/captain-asks.tsv malformed row 7"
  pass "the overview answers each question, and lanes, agents and groups sum to their totals"
}

test_backlog_and_method_pages_show_their_numbers() {
  local home d
  home=$(make_home pages)
  d="$home/state/dashboard"
  build "$home"
  has "$d/backlog.html" "Queued 4 = Ready 2 + Held 1 + Waiting on another item 1" \
    "1 item held; oldest" "Wait for the captain's call" "needs his call" \
    "Open lanes 2 + 1 + 4 + 1 = 8" "Busy now 1 + 1 + 1 + 1 = 4" "4 busy: 1 lead + 1 Main + 1 worker + 1 other." \
    "Lane settings plan 9 lanes; 8 are open." "Fleet 8 9 2" "Main 6" \
    "Oldest validation or CI wait: 20 min (m-ci, Main)"
  has "$d/backlog.home.html" "Queued" "Main 3" "zephyrine 1" "Open lanes 7 + 1 = 8"
  has "$d/backlog.html" "Plan per home from the lane settings (Main 6); every other home 3."
  has "$d/measure.html" "every 60 s" "Parked homes are left out (beta)." "beta is parked but has 1 item marked in flight" \
    "Landed Counts pull requests the fleet recorded as merged, each once" "Every source was read."
  pass "Backlog and Method pages show their numbers with windows and sums"
}

test_each_failed_source_shows_unknown_and_why() {
  local home d
  home=$(make_home failing)
  d="$home/state/dashboard"
  build "$home"
  touch "$home/herdr.fail"
  # A home whose backlog cannot be read makes the queue unknown, and names the home.
  printf '#!/bin/sh\necho "tasks-axi: backlog unreadable" >&2\nexit 1\n' > "$home/stubs/tasks-axi"
  chmod +x "$home/stubs/tasks-axi"
  build "$home"
  has "$d/measure.html" "herdr agent list herdr: server not running"
  has "$d/backlog.html" "Queued work unknown." "main: tasks-axi: backlog unreadable" "At least 0 items held; the backlog of Main, zephyrine is unknown." "Agents unknown."
  has "$d/measure.html" "backlog main: tasks-axi: backlog unreadable"
  lacks "$d/backlog.html" "Queued 0" "No item is held" "0 busy"
  jq '.at -= 600' "$d/.quota.json" > "$home/q.json" && mv "$home/q.json" "$d/.quota.json"
  build "$home"
  has "$d/index.html" "Quota runs out unknown"
  has "$d/measure.html" "quota-axi no recent local quota reading"
  [ ! -e "$home/quota.called" ] || fail "page build collected quota"
  jq -e '.since == null and .last == null' "$d/filed.json" >/dev/null || fail "failed backlog read advanced filing coverage"
  rm "$d/.quota.json" "$home/mates/zephyrine/state/home-summary.json"
  build "$home"
  has "$d/index.html" "Quota runs out unknown" "▲ 1 lead to check" "zephyrine State unknown"
  has "$d/measure.html" "home summary zephyrine: No such file or directory"
  lacks "$d/index.html" "Codex"
  pass "each failed source shows unknown and why, and never guesses zero"
}

test_devices_and_machine_come_from_read_only_probes() {
  local home d proc locks bin key at nopath
  home=$(make_home probes)
  d="$home/state/dashboard"
  proc="$home/proc" locks="$home/locks" bin="$home/stubs"
  mkdir -p "$proc/pressure" "$proc/900" "$proc/800" "$locks" "$home/projects/wt"
  fm_write_meta "$home/state/m-build.meta" "kind=ship" "worktree=$home/projects/wt" "herdr_pane_id=pane-m-build"
  printf 'MemTotal:       67108864 kB\nMemAvailable:   10485760 kB\n' > "$proc/meminfo"
  printf 'some avg10=3.50 avg60=8.00 avg300=12.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$proc/pressure/memory"
  printf 'Name:\tqemu-system-x86\nVmRSS:\t 4194304 kB\n' > "$proc/900/status"
  printf '900 (qemu-system-x86) S 800 900 1\n' > "$proc/900/stat"
  printf '800 (flock) S 1 800 1\n' > "$proc/800/stat"
  : > "$locks/fm-phone-PHONE1.lock"
  : > "$locks/fm-phone-muxr-emu.lock"
  # The kernel lists a held flock by device and inode; only the emulator lock is held.
  key=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{os.major(s.st_dev):02x}:{os.minor(s.st_dev):02x}:{s.st_ino}")' "$locks/fm-phone-muxr-emu.lock")
  printf '1: FLOCK  ADVISORY  WRITE 800 %s 0 EOF\n' "$key" > "$proc/locks"
  at=$(iso 0.17)
  printf '%s PHONE1 acquired pid=700 waited=0s cwd=/tmp/fm-m-build\n%s PHONE1 released pid=700 rc=0\n%s muxr-emu acquired pid=800 waited=0s cwd=%s\n' \
    "$at" "$at" "$at" "$home/projects/wt/app" > "$locks/fm-device-lock.log"
  cat > "$bin/adb" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$home/adb.calls"
[ -e "$home/adb.fail" ] && { echo 'error: daemon not running' >&2; exit 1; }
printf 'List of devices attached\nPHONE1 device usb:1-1 product:p model:Pixel_9 device:d transport_id:1\nemulator-5554 device product:sdk model:sdk transport_id:2\n\n'
EOF
  cat > "$bin/pgrep" <<'EOF'
#!/bin/sh
case "$*" in
  "-a ^qemu-system") echo '900 /opt/emulator/qemu-system-x86_64 -netdelay none -avd test-avd -port 5554' ;;
  "-cf appname=gradle[w]") echo 2 ;;
  *) exit 1 ;;
esac
EOF
  cat > "$bin/systemctl" <<EOF
#!/bin/sh
[ -e "$home/systemctl.fail" ] && { echo 'Failed to connect to bus' >&2; exit 1; }
printf 'MemoryCurrent=8589934592\nMemoryHigh=34359738368\nMemoryMax=40802189312\n'
EOF
  chmod +x "$bin/adb" "$bin/pgrep" "$bin/systemctl"
  build "$home" FM_DASHBOARD_PROC="$proc" FM_DEVICE_LOCK_DIR="$locks"
  has "$d/index.html" "In use 1" "Free 1" "Devices 1 + 1 = 2" \
    "Phone Pixel 9 Free · last used by Main 10 min ago · PHONE1 · USB" \
    "Emulator test-avd In use by Main · 10 min · emulator-5554 · 4.0 GB in use" \
    "Free memory 10.0 GB of 64 GB" "Memory pressure 4% share of the last 10 s" "Heavy jobs 8.0 GB of 32 GB" "hard limit 38 GB" \
    "Gradle builds 2 of 2" "Emulators 1 of 2" "✕ 10 GB free, heavy jobs wait" "▲ 2/2 Gradle builds at cap"
  [ "$(sort -u "$home/adb.calls")" = "devices -l" ] || fail "adb was asked more than the device list: $(cat "$home/adb.calls")"
  # Memory pressure is one number, the gate's 10 s share, in the chip and the card alike.
  printf 'MemTotal:       67108864 kB\nMemAvailable:   20971520 kB\n' > "$proc/meminfo"
  printf 'some avg10=45.00 avg60=8.00 avg300=12.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$proc/pressure/memory"
  build "$home" FM_DASHBOARD_PROC="$proc" FM_DEVICE_LOCK_DIR="$locks"
  has "$d/index.html" "✕ 45% memory pressure, heavy jobs wait" "Memory pressure 45%"
  lacks "$d/index.html" "12%"
  # Each failed probe says unknown and why; nothing is guessed as zero.
  touch "$home/adb.fail" "$home/systemctl.fail"
  rm "$proc/meminfo" "$proc/locks"
  build "$home" FM_DASHBOARD_PROC="$proc" FM_DEVICE_LOCK_DIR="$locks"
  has "$d/index.html" "unknown - adb: error: daemon not running" \
    "Free memory unknown: $proc/meminfo: No such file or directory" "Heavy jobs unknown: Failed to connect to bus" \
    "unknown - device locks: $proc/locks: No such file or directory"
  lacks "$d/index.html" "0 devices connected" "Free memory 0"
  # A server whose PATH lacks adb still finds it in the Android SDK, and says not found only when neither has it.
  rm "$home/adb.fail"
  mkdir -p "$home/sdk/platform-tools"
  mv "$bin/adb" "$home/sdk/platform-tools/adb"
  # PATH keeps every tool but adb: a directory holding adb is replaced by links to its other files.
  mkdir -p "$home/noadb"
  nopath=$bin$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r p; do
    if [ -x "$p/adb" ]; then find "$p" -maxdepth 1 ! -name adb ! -type d -exec ln -s {} "$home/noadb/" \; 2>/dev/null; printf ':%s' "$home/noadb"
    else printf ':%s' "$p"; fi; done)
  build "$home" PATH="$nopath" ANDROID_HOME="$home/sdk" FM_DASHBOARD_PROC="$proc" FM_DEVICE_LOCK_DIR="$locks"
  has "$d/index.html" "Phone Pixel 9"
  build "$home" PATH="$nopath" HOME="$home" ANDROID_HOME= ANDROID_SDK_ROOT= FM_DASHBOARD_PROC="$proc" FM_DEVICE_LOCK_DIR="$locks"
  has "$d/index.html" "unknown - adb: adb not found"
  pass "devices and machine come from read-only probes, name each holder's home, and say unknown with the reason"
}

SERVE_PID=
trap '[ -z "$SERVE_PID" ] || kill "$SERVE_PID" 2>/dev/null; fm_test_cleanup' EXIT

test_serve_answers_each_page_and_remembers_the_grouping() {
  local home url got
  home=$(make_home served)
  PATH="$home/stubs:$PATH" FM_HOME="$home" FM_DEVICE_LOCK_DIR="$home/locks" "$DASH" serve --port 0 > "$home/serve.out" 2> "$home/serve.err" &
  SERVE_PID=$!
  for _ in $(seq 1 100); do
    url=$(sed -n 's/^serving //p' "$home/serve.out")
    [ -n "$url" ] && break
    kill -0 "$SERVE_PID" 2>/dev/null || fail "serve exited: $(cat "$home/serve.err")"
    sleep 0.1
  done
  [ -n "$url" ] || fail "serve never reported its address: $(cat "$home/serve.err")"
  case "$url" in http://127.0.0.1:*/) ;; *) fail "serve did not default to loopback: $url" ;; esac
  got=$(python3 - "$url" <<'PY'
import json, re, sys, urllib.request, urllib.error
def get(u, cookie=None):
    rq = urllib.request.Request(u, headers={'Cookie': cookie} if cookie else {})
    try:
        with urllib.request.urlopen(rq, timeout=120) as r: return r.status, r.read().decode(), r.headers.get('Set-Cookie') or ''
    except urllib.error.HTTPError as e: return e.code, '', ''
base = sys.argv[1]
with urllib.request.urlopen(base + 'data.json', timeout=120) as r:
    assert r.headers.get_content_type() == 'application/json'
    data = json.load(r)
assert data['build_duration_seconds'] >= 0 and data['build_time']
m = data['metrics']
assert m['lanes']['value'] == 8 and m['lanes']['status'] == 'exact'
assert m['free_lanes']['value'] == 1 and m['ready']['value'] == 2
assert m['landed']['value'] == 2 and m['landed']['status'] == 'lower_bound'
assert m['closed']['value'] == 2 and m['filed']['status'] == 'lower_bound'
assert len(data['lanes']) == 8 and len(data['homes']) == 2
assert data['held_items'][0]['reason'] == 'needs his call'
for metric in m.values():
    assert metric['status'] in ('exact', 'lower_bound', 'unknown')
    assert all(k in metric for k in ('value', 'reason', 'source', 'window', 'cutoff', 'read_at'))
    if metric['status'] == 'unknown': assert metric['value'] is None and metric['reason']
with urllib.request.urlopen(urllib.request.Request(base + 'data.json', method='HEAD')) as r:
    assert r.headers.get_content_type() == 'application/json' and r.read() == b''
    assert int(r.headers['Content-Length']) > 0
for path, want in (('', 'Nothing needs you.'), ('backlog', 'Held for the captain'), ('measure', 'How each number is measured.')):
    code, body, _ = get(base + path)
    print(path or '/', code, want in body)
code, body, cookie = get(base + 'backlog?group=home')
print('group', code, 'fm_group=home' in cookie, '7 + 1 = <b>8</b>' in body)
code, body, _ = get(base + 'backlog', 'fm_group=home')
print('cookie', code, '7 + 1 = <b>8</b>' in body)
code, body, _ = get(base + 'measure')
print('ages', '<!--' not in body, re.search(r'last read \d+\u00a0s ago', body) is not None)
for path in ('flow', 'state/', 'index.home.html', '../data/backlog.md', 'data/backlog.md'):
    print(path, get(base + path)[0])
PY
)
  [ "$got" = "$(printf '%s\n' '/ 200 True' 'backlog 200 True' 'measure 200 True' \
    'group 200 True True' 'cookie 200 True' 'ages True True' 'flow 404' 'state/ 404' 'index.home.html 404' '../data/backlog.md 404' 'data/backlog.md 404')" ] \
    || fail "serve answers were not the three pages, the remembered grouping, then 404s: $got"
  # An old page is answered at once, as it is, while a rebuild runs behind it.
  printf '<p>old page<!--age--></p>\n' > "$home/state/dashboard/index.html"
  touch -d '-5 minutes' "$home/state/dashboard/index.html"
  got=$(python3 -c 'import sys, urllib.request; print(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode())' "$url")
  case "$got" in *'<span class="age bad">updated 5'*'min ago'*) ;; *) fail "an old page was not answered at once, marked old: $got" ;; esac
  for _ in $(seq 1 1200); do grep -q 'old page' "$home/state/dashboard/index.html" || break; sleep 0.1; done
  grep -q 'Nothing needs you' "$home/state/dashboard/index.html" || fail "the background rebuild did not replace the old page"
  kill "$SERVE_PID" 2>/dev/null; SERVE_PID=
  pass "serve answers the three pages at once with their ages, remembers ?group in a cookie, rebuilds an old page itself, and 404s every other path"
}

test_fleet_past_twenty_mates_keeps_every_lead_row() {
  local home d i mdir
  home=$(make_home many)
  d="$home/state/dashboard"
  # Mate homes live outside the active home; each reads its own summary, one row each:
  # mate24's is an hour old and Main's view says mate25 is not running.
  now=$(date +%s)
  for i in $(seq -w 1 25); do
    mdir="$TMP_ROOT/mate$i"
    mkdir -p "$mdir/state" "$mdir/data"
    printf -- '- mate%s - domain %s (home: %s; scope: work; projects: alpha; added 2026-07-11)\n' \
      "$i" "$i" "$mdir" >> "$home/data/secondmates.md"
    summary "$mdir" unknown "$([ "$i" = 24 ] && echo $((now - 3600)) || echo "$now")"
  done
  summary "$home" no_active_work "$now" '"endpoints":[{"id":"mate25","endpoint":{"exists":false}}]'
  build "$home"
  has "$d/index.html" "✕ 1 lead down" "mate24 Silent 1 h" "mate25 Not running"
  python3 - "$d/index.html" <<'PY' || fail "a mate past the twentieth lost its lead state"
import html, re, sys
homes = open(sys.argv[1]).read().split('<div class="hrs">', 1)[1]
text = re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', ' ', homes)))
for mate in ('mate01', 'mate23'):
    i = text.find(mate)
    assert i >= 0, mate
    assert 'Runtime unknown' in text[i:i + 200], text[i:i + 200]
PY
  pass "a fleet past twenty mates keeps every lead row"
}

test_review_evidence_boundaries() {
  local home d z now today key
  home=$(make_home review)
  d="$home/state/dashboard" z="$home/mates/zephyrine"
  now=$(date +%s) today=$(date +%F)
  printf 'backend = "markdown"\n[markdown]\narchive = "data/custom-done.md"\n' > "$home/.tasks.toml"
  printf -- '- [x] archived - Archived completion (done %s)\n' "$today" > "$home/data/custom-done.md"
  lane "$home" m-ci ship "blocked [at=$now] [key=checks]: CI failed: approve config/release.json instead of config/staging.json https://github.com/acme/alpha/pull/22"
  python3 - "$home/data/backlog.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('needs his call', 'Approve config/release.json instead of config/staging.json'))
PY
  summary "$home" no_active_work "$((now - 3600))" '"endpoints":[{"id":"zephyrine","endpoint":{"exists":false}}]'
  rm "$home/state/zephyrine.status"
  mkdir "$home/state/zephyrine.status"
  build "$home"
  has "$d/index.html" "Closed 7 d 3" "Landed today at least 1" "Recorded merges only; some may be missing." "In: filed, always at least" \
    "CI failed: approve release.json instead of staging.json PR 22"
  lacks "$d/index.html" "Not running" "lead down" "config/release.json" "https://github.com/acme/alpha/pull/22" "Landed today 1"
  for p in backlog backlog.home; do
    has "$d/$p.html" "CI failed: approve release.json instead of staging.json PR 22" "Approve release.json instead of staging.json"
    lacks "$d/$p.html" "config/release.json" "[key=checks]"
  done
  has "$d/measure.html" "always at least: recording can be disabled" "always at least: items filed and closed between readings"
  jq '.providers = [{provider:"cursor",state:{status:"fresh"},quotaSemantics:{status:"unknown"}},{provider:"copilot",state:{status:"auth_required"}}]' "$home/quota.json" |
    jq --argjson at "$now" '{at:$at,data:.}' > "$d/.quota.json"
  build "$home"
  has "$d/index.html" "Quota runs out unknown" "Cursor unknown" "Copilot unknown"
  lacks "$d/index.html" "Quota runs out none" "lasts"
  jq '.providers = [.providers[0] + {accountKey:"work"}, .providers[0] + {accountKey:"personal",quotaSemantics:{effectiveAvailability:[{scope:"all_models",runway:{status:"through_reset"}}]}}]' "$home/quota.json" |
    jq --argjson at "$now" '{at:$at,data:.}' > "$d/.quota.json"
  build "$home"
  has "$d/index.html" "Codex · work before its reset" "Codex · work out" "Codex · personal resets"
  summary "$home" no_active_work "$now" '"endpoints":[]'
  printf '{"result":{"agents":[]}}\n' > "$home/herdr.json"
  build "$home"
  has "$d/index.html" "zephyrine Runtime unknown"
  lacks "$d/index.html" "lead down"
  summary "$home" no_active_work "$now" '"endpoints":[{"id":"zephyrine","endpoint":{"exists":false}}]'
  build "$home"
  has "$d/index.html" "zephyrine Not running" "lead down"
  printf -- '- zephyrine - remote (host: distant; root: /srv; home: %s; scope: work; projects: alpha; added 2026-07-11)\n' "$z" > "$home/data/secondmates.md"
  key=$(printf 'zephyrine\ndistant\n%s\n' "$z" | sha256sum | cut -d' ' -f1)
  mkdir "$home/state/secondmate-summary-cache"
  jq '.state="externally_held" | .hold_classifier_schema="fm-captain-hold-buckets.v1"' "$z/state/home-summary.json" > "$home/state/secondmate-summary-cache/$key.json"
  build "$home"
  has "$d/index.html" "zephyrine Waiting on someone else" "Closed 7 d unknown" "Out: unknown"
  lacks "$d/index.html" "Not running" "Start the zephyrine thing" "Ship the zephyrine thing"
  rm "$home/state/secondmate-summary-cache/$key.json"
  build "$home"
  has "$d/index.html" "zephyrine State unknown"
  printf 'backend = "beads"\n' > "$home/.tasks.toml"
  build "$home"
  has "$d/index.html" "Closed 7 d unknown" "Out: unknown"
  [ ! -e "$home/quota.called" ] || fail "page build collected quota"
  pass "dashboard preserves lower bounds, route ownership, configured archives, runway uncertainty and wait reasons"
}

test_incomplete_lanes_and_moved_filings() {
  local home d z before after now real_tasks
  home=$(make_home coverage)
  d="$home/state/dashboard" z="$home/mates/zephyrine" now=$(date +%s)
  lane "$home" m-ci ship "blocked [at=$now]: CI evidence=/home/u/x/report.md ref:https://github.com/acme/alpha/pull/22"
  build "$home"
  before=$(jq '.metrics.filed.daily[-1].value' "$d/data.json")
  tasks-axi mv m-ready m-after --file "$home/data/backlog.md" --to "$z/data/backlog.md" >/dev/null || fail "task move failed"
  build "$home"
  after=$(jq '.metrics.filed.daily[-1].value' "$d/data.json")
  [ "$before" = "$after" ] || fail "moving tasks overcounted filings: $before -> $after"
  has "$d/index.html" "evidence=report.md ref:PR 22"
  lacks "$d/index.html" "evidence=/home/u" "ref:https://"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" list --limit 10000 --fields held,hold_kind,hold_reason,blocked,created,closed > "$home/backend.toon" || fail "backlog fixture failed"
  printf 'backend = "beads"\n' > "$home/.tasks.toml"
  real_tasks=$(command -v tasks-axi)
  # shellcheck disable=SC2016 # the single-quoted stub expands when it runs
  printf '#!/bin/sh\n[ "$PWD" = "%s" ] || exec "%s" "$@"\n[ -z "${TASKS_AXI_FILE:-}" ] || exit 1\necho called > "%s/backend.called"\ncat "%s/backend.toon"\n' "$home" "$real_tasks" "$home" "$home" > "$home/stubs/tasks-axi"
  chmod +x "$home/stubs/tasks-axi"
  build "$home"
  [ -e "$home/backend.called" ] || fail "non-markdown listing was skipped"
  has "$d/backlog.html" "Wait for the captain's call" "needs his call"
  jq -e '.metrics.ready.status == "exact" and .metrics.closed.status == "unknown"' "$d/data.json" >/dev/null || fail "backend coverage was lost"
  rm "$home/.tasks.toml" "$home/stubs/tasks-axi"
  mkdir -p "$home/mates/missing/data"
  printf '## Queued\n- [ ] missing-ready - Missing home ready (since %s)\n' "$(date +%F)" > "$home/mates/missing/data/backlog.md"
  printf -- '- missing - domain (home: %s; scope: work; projects: alpha; added 2026-07-11)\n' "$home/mates/missing" >> "$home/data/secondmates.md"
  build "$home"
  has "$d/index.html" "Lanes open at least 8" "Stuck at least 2" "free unknown" "Ready, capacity unknown 1" "unknown of 3"
  lacks "$d/index.html" "All flowing" "missing 0 of 3"
  has "$d/backlog.html" "at least 8 lanes open" "Fleet at least 8" "missing unknown 3"
  has "$d/backlog.home.html" "missing unknown"
  jq -e '.metrics.lanes.status == "lower_bound" and .metrics.stuck.status == "lower_bound" and .metrics.free_lanes.status == "unknown" and ([.homes[] | select(.home == "missing")][0].lanes.value == null)' "$d/data.json" >/dev/null || fail "missing lane coverage looks exact"
  printf -- '- zephyrine - remote (host: distant; root: /srv; home: %s; scope: work; projects: alpha; added 2026-07-11)\n' "$z" > "$home/data/secondmates.md"
  build "$home"
  has "$d/index.html" "Lanes open at least 7" "unknown of 3"
  jq -e '[.homes[] | select(.home == "zephyrine")][0] | .lanes.status == "unknown" and .free_lanes.value == null' "$d/data.json" >/dev/null || fail "remote lane capacity was inferred"
  : > "$home/data/secondmates.md"
  printf '## Queued\n' > "$home/data/backlog.md"
  rm "$home/state"/m-*.meta "$home/state"/m-*.status
  mkdir "$home/state/unreadable.meta"
  build "$home"
  has "$d/index.html" "Lanes open at least 0" "free unknown"
  lacks "$d/index.html" "All flowing" "Ready, a lane is free 1"
  pass "moved filings count once and unavailable lanes retain unknown capacity across HTML and JSON"
}

test_new_lane_and_unwritten_archive_stay_exact() {
  local home d before
  home=$(make_home fresh)
  d="$home/state/dashboard"
  printf 'backend = "markdown"\n[markdown]\narchive = "data/custom-done.md"\n' > "$home/.tasks.toml"
  build "$home"
  before=$(jq '.metrics.lanes.value' "$d/data.json")
  fm_write_meta "$home/state/m-new.meta" "kind=ship" "project=alpha" "herdr_pane_id=pane-m-new"
  build "$home"
  jq -e --argjson n "$((before + 1))" '.metrics.lanes.value == $n and .metrics.lanes.status == "exact" and .metrics.closed.status == "exact" and .metrics.closed.value > 0' "$d/data.json" >/dev/null ||
    fail "a lane with no status line or an archive not yet written made a number unknown: $(jq -c '.metrics.lanes, .metrics.closed | del(.daily)' "$d/data.json")"
  has "$d/index.html" "Closed 7 d 2"
  pass "a lane with no status line yet and an archive not yet written keep their numbers exact"
}

test_new_lane_and_unwritten_archive_stay_exact
test_incomplete_lanes_and_moved_filings
test_review_evidence_boundaries
test_overview_answers_the_four_questions_with_sums_that_add_up
test_backlog_and_method_pages_show_their_numbers
test_fleet_past_twenty_mates_keeps_every_lead_row
test_each_failed_source_shows_unknown_and_why
test_devices_and_machine_come_from_read_only_probes
test_serve_answers_each_page_and_remembers_the_grouping
