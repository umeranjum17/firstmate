#!/usr/bin/env bash
# Behavior tests for bin/fm-dashboard.sh: build the pages from a small fixture
# fleet through the real script, the real fleet snapshot and the real tasks-axi,
# with stub herdr, quota-axi and gh on PATH, then read each page's visible text
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

# A fleet of Main, one active lead (zephyrine) and one parked lead (beta).
# Lanes: Main has 2 building, 1 validating, 1 blocked, 1 on a decision, 1 finished,
# 1 waiting; zephyrine has 1 building; parked beta has 1 building that no total counts.
# Plan: Main 6 from config/lane-caps, every other home 3 from config/lane-target.
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
- [x] m-old - Landed long ago (repo: alpha) (kind: ship) (merged 2026-07-10)
EOF
  cat > "$z/data/backlog.md" <<EOF
## Queued
- [ ] z-ready - Start the zephyrine thing (repo: alpha) (kind: ship) (since $today)
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
  # One account that runs out in 5 hours, before its week resets in 3 days; one that cannot be read.
  python3 - "$home/quota.json" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone as z
t = lambda h: (datetime.now(z.utc) + timedelta(hours=h)).strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump({'schemaVersion': 5, 'providers': [
  {'provider': 'claude', 'plan': 'max', 'state': {'status': 'fresh'},
   'windows': [{'id': 'week', 'label': 'week', 'resetsAt': t(72), 'percentRemaining': 30, 'pace': {'reservePercentPoints': -40}}],
   'quotaSemantics': {'effectiveAvailability': [{'scope': 'all_models', 'runway': {
     'status': 'projected_exhaustion', 'projectedExhaustedAt': t(5), 'limitingWindowId': 'week', 'projectionConfidence': 'established'}}]}},
  {'provider': 'cursor', 'plan': 'Free', 'state': {'status': 'error', 'stale': True, 'error': 'sign_in_required'}, 'windows': []}]},
  open(sys.argv[1], 'w'))
PY
  cat > "$stubs/quota-axi" <<EOF
#!/bin/sh
[ -e "$home/quota.fail" ] && { echo 'quota-axi: no network' >&2; exit 1; }
cat "$home/quota.json"
EOF
  # GitHub answers each bounded day search from a fixed list of merges: two today, one yesterday.
  git init -q "$home/projects/alpha" && git -C "$home/projects/alpha" remote add origin https://github.com/acme/alpha.git
  printf '%s\tLand the first fix\n%s\tLand the second fix\n%s\tYesterday fix\n' "$(iso 0)" "$(iso 0)" "$(iso 24)" > "$home/merges.tsv"
  cat > "$stubs/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$home/gh.calls"
[ -e "$home/gh.fail" ] && { echo 'HTTP 403: API rate limit exceeded' >&2; exit 1; }
exec python3 - "$home/merges.tsv" "\$*" <<'PY'
import json, re, sys
a, b = re.search(r'merged:(\S+)\.\.(\S+)', sys.argv[2]).groups()
items = [dict(id=n, number=n, title=t, html_url=f'https://github.com/acme/alpha/pull/{n}',
              repository_url='https://api.github.com/repos/acme/alpha', pull_request={'merged_at': at})
         for n, (at, t) in enumerate((l.rstrip('\n').split('\t') for l in open(sys.argv[1])), 1) if a <= at <= b]
print(json.dumps([{'total_count': len(items), 'incomplete_results': False, 'items': items}]))
PY
EOF
  # No device or emulator unless a test adds one, and no heavy-job slice to ask.
  printf '#!/bin/sh\nprintf "List of devices attached\\n\\n"\n' > "$stubs/adb"
  printf '#!/bin/sh\nexit 1\n' > "$stubs/pgrep"
  printf '#!/bin/sh\necho "no user bus" >&2\nexit 1\n' > "$stubs/systemctl"
  mkdir -p "$home/locks"
  chmod +x "$stubs/herdr" "$stubs/quota-axi" "$stubs/gh" "$stubs/adb" "$stubs/pgrep" "$stubs/systemctl"
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
  for p in index index.home flow quota backlog backlog.home measure; do
    [ -s "$d/$p.html" ] || fail "no $p page"
    ! grep -Eq '<script|https?://[^"]*\.(css|js)"' "$d/$p.html" || fail "$p is not self-contained"
  done
  # Lanes group by what to do and sum to the open total; slow spots name a number and an age.
  has "$d/index.html" "Nothing needs you. Slow spots" "1 waiting 7 /6 1 2 zephyrine" "1 building 1 /3 1 0" \
    "Blocked or waiting on a decision 1 blocked · 1 on a decision 2" "Finished, not landed" \
    "Producing 3 building · 1 validating 4" "Open lanes 2 + 1 + 4 + 1 = 8" \
    "beta is parked by the captain and left out of every total." \
    "Stuck blocked or on a decision 2 2 h" "Held held - Main must triage 1" "Quota Claude runs out 1 in"
  # The busy parts sum to the busy total, and the denominator is every running Herdr agent
  # outside parked homes (6 listed, 1 in parked beta), not the lane plan of 9.
  running=$(jq '[.result.agents[] | select(.pane_id != "pane-b-stale")] | length' "$home/herdr.json")
  [ "$running" = 5 ] || fail "fixture should list 5 running agents outside parked homes, has $running"
  has "$d/backlog.html" "Busy now 1 + 1 + 1 + 1 = 4" "the groups list all $running running agents"
  # Grouped by home, the same lanes sum to the same total.
  has "$d/index.home.html" "Open lanes 7 + 1 = 8" "Main 1 blocked · 1 on a decision 7 Blocked, needs help 1" "zephyrine 1 building 1"
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

test_sub_pages_show_flow_quota_backlog_and_method() {
  local home d
  home=$(make_home pages)
  d="$home/state/dashboard"
  build "$home"
  has "$d/flow.html" "2 landed so far today" "Yesterday's full day: 1 landed" \
    "Latest landings · GitHub" "Land the first fix" "Land the second fix" "Fleet ≥ 4 2"
  has "$d/quota.html" "Claude runs out first" "Claude · 1 lead, 8 workers" "week 70% used" \
    "1 account cannot be read or is empty." "Cursor sign in required" "even pace 30%"
  has "$d/backlog.html" "Queued 4 = Ready 2 + Held 1 + Waiting on another item 1" \
    "1 item held; oldest" "Wait for the captain's call" "needs his call" \
    "Open lanes 2 + 1 + 4 + 1 = 8" "Busy now 1 + 1 + 1 + 1 = 4" "4 busy: 1 lead + 1 Main + 1 worker + 1 other." \
    "Lane settings plan 9 lanes; 8 are open." "Fleet 8 9 2" "Main 6" \
    "Oldest validation or CI wait: 20 min (m-ci, Main)"
  has "$d/backlog.home.html" "Queued" "Main 3" "zephyrine 1" "Open lanes 7 + 1 = 8"
  has "$d/measure.html" "The pages rebuild every 60 s" "3 lanes per home from config/lane-target; config/lane-caps overrides (9 in all)" \
    "Parked homes left out of every total: beta" "beta is parked but has 1 item marked in flight" \
    "Fleet retro no schedule in any record this page reads"
  pass "Flow, Quota, Backlog and Method pages show their numbers with windows and sums"
}

test_each_failed_source_shows_unknown_and_why() {
  local home d
  home=$(make_home failing)
  d="$home/state/dashboard"
  build "$home"
  touch "$home/herdr.fail" "$home/quota.fail" "$home/gh.fail"
  # The quota reading is too old to reuse as current, but young enough to show with its time.
  python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c["at"]-=200; json.dump(c,open(p,"w"))' "$d/.quota.json"
  # GitHub's cache for today is past its 5 minutes, so the failed search falls back to the merge record.
  python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); [e.__setitem__("at", e["at"]-400) for e in c["days"].values()]; json.dump(c,open(p,"w"))' "$d/.merged.json"
  printf 'home\tmerged\tfirst_pass\tbuild_hours\nmain\t%s\t1\t2\n' "$(iso 0)" > "$home/data/metrics/prs.tsv"
  build "$home"
  has "$d/flow.html" "landings merge record as of" "1 landed so far today"
  has "$d/flow.html" "P50 2 h" "P85 2 h"
  has "$d/quota.html" "Claude runs out first"
  has "$d/measure.html" "herdr agent list herdr: server not running" "quota-axi quota-axi: no network; showing the reading from" \
    "GitHub landings HTTP 403: API rate limit exceeded"
  # With no reading to reuse and no merge record, the numbers say unknown, never zero.
  rm "$d/.quota.json" "$home/data/metrics/prs.tsv"
  build "$home"
  has "$d/quota.html" "Quota unknown. unknown: quota-axi: no network"
  has "$d/flow.html" "– landed so far today" "Landings unknown."
  lacks "$d/flow.html" "0 landed so far today"
  # A home whose backlog cannot be read makes the queue unknown, and names the home.
  printf '#!/bin/sh\necho "tasks-axi: backlog unreadable" >&2\nexit 1\n' > "$home/stubs/tasks-axi"
  chmod +x "$home/stubs/tasks-axi"
  build "$home"
  has "$d/backlog.html" "Queued work unknown." "main: tasks-axi: backlog unreadable" "At least 0 items held; the backlog of Main, zephyrine is unknown." "Agents unknown."
  has "$d/measure.html" "backlog main: tasks-axi: backlog unreadable"
  lacks "$d/backlog.html" "Queued 0" "No item is held" "0 busy"
  pass "each failed source shows unknown and why, reuses a dated reading where one exists, and never guesses zero"
}

test_github_searches_each_day_once_and_today_again_after_five_minutes() {
  local home d
  home=$(make_home github)
  d="$home/state/dashboard"
  build "$home"
  [ "$(wc -l < "$home/gh.calls")" -eq 7 ] || fail "not one search per day of 7: $(cat "$home/gh.calls")"
  grep -q 'q=owner:acme is:pr is:merged merged:20[0-9-]*T[0-9:]*Z\.\.20[0-9-]*T[0-9:]*59Z' "$home/gh.calls" \
    || fail "unexpected search: $(cat "$home/gh.calls")"
  build "$home"
  [ "$(wc -l < "$home/gh.calls")" -eq 7 ] || fail "a rebuild inside 5 minutes searched again"
  python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); [e.__setitem__("at", e["at"]-400) for e in c["days"].values()]; json.dump(c,open(p,"w"))' "$d/.merged.json"
  build "$home"
  [ "$(wc -l < "$home/gh.calls")" -eq 8 ] || fail "after 5 minutes not only today was searched again: $(cat "$home/gh.calls")"
  has "$d/flow.html" "2 landed so far today"
  pass "GitHub is searched once per finished day and today again after 5 minutes"
}

test_the_filing_log_counts_new_items_exactly() {
  local home d today
  home=$(make_home filing)
  d="$home/state/dashboard"
  today=$(date +%F)
  build "$home"
  # Items already queued when the log starts have only their filing day: a floor.
  has "$d/flow.html" "4 filed, at least." "0 items first seen today."
  printf -- '- [ ] m-new - A brand new thing (repo: alpha) (kind: ship) (since %s)\n' "$today" >> "$home/mates/zephyrine/data/backlog.md"
  build "$home"
  has "$d/flow.html" "1 item first seen today." "A brand new thing zephyrine"
  # Once the log covers today, today's count is exact.
  python3 -c 'import sys,time
p=sys.argv[1]; rows=open(p).read().split("\n",1); t=int(time.mktime(time.strptime(time.strftime("%Y-%m-%d"),"%Y-%m-%d"))) - 86400
open(p,"w").write(f"# since {t} last {int(time.time())}\thome\tid\tfirst_seen\ttitle\n"+rows[1])' "$d/filed.tsv"
  build "$home"
  has "$d/flow.html" "5 filed."
  lacks "$d/flow.html" "filed, at least"
  pass "the filing log records first-seen times, and filed counts are floors until the log covers the day"
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
    "Free memory 10.0 GB of 64 GB" "Memory pressure 12%" "the 10 s share is 40% or more (now 4%)" "Heavy jobs 8.0 GB of 32 GB" "hard limit 38 GB" \
    "Gradle builds 2 of 2" "Emulators 1 of 2" "Memory heavy jobs wait"
  has "$d/index.home.html" "Main 1 Emulator test-avd" "No holder 1 Phone Pixel 9" "Devices 1 + 1 = 2"
  [ "$(sort -u "$home/adb.calls")" = "devices -l" ] || fail "adb was asked more than the device list: $(cat "$home/adb.calls")"
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

test_pull_requests_show_validation_runs_and_checks_from_local_records() {
  local home d now
  home=$(make_home prs)
  d="$home/state/dashboard" now=$(date +%s)
  mkdir -p "$home/wt/ci" "$home/wt/done" "$home/wt/green" "$home/data/m-done" "$home/data/m-green"
  fm_write_meta "$home/state/m-ci.meta" "kind=ship" "worktree=$home/wt/ci" "herdr_pane_id=pane-m-ci"
  fm_write_meta "$home/state/m-done.meta" "kind=ship" "worktree=$home/wt/done" "herdr_pane_id=pane-m-done"
  lane "$home" m-green ship "done [at=$((now - 600))]: PR https://github.com/acme/alpha/pull/10 ready"
  fm_write_meta "$home/state/m-green.meta" "kind=ship" "worktree=$home/wt/green" "herdr_pane_id=pane-m-green"
  # no-mistakes answers per copy: m-ci waits on CI, the others have no run on their branch.
  cat > "$home/stubs/no-mistakes" <<'EOF'
#!/bin/sh
[ "$*" = "axi status" ] || { echo "unexpected: $*" >&2; exit 2; }
[ -e "$FM_NM_FAIL" ] && { echo "error: daemon not reachable" >&2; exit 1; }
case "$PWD" in
*/ci) printf 'run:\n  id: "r1"\n  status: running\n  pr: "https://github.com/acme/alpha/pull/9"\n  active_steps[1]{step,status,active_for,round_active_for,last_activity,agent_pid,round}:\n    ci,running,2h18m,2h18m,"quiet","",starting\nbranch_sync:\n  pipeline:\n    status: running\n' ;;
*) printf 'current_branch: x\nruns_on_current_branch: 0\n' ;;
esac
EOF
  chmod +x "$home/stubs/no-mistakes"
  printf '{"records":[{"url":"https://github.com/acme/alpha/pull/8","checked_at":"%s","observation":{"checks":[{"name":"lint","status":"completed","conclusion":"success"},{"name":"test","status":"completed","conclusion":"failure"}]}}]}\n' \
    "$(iso 1)" > "$home/data/m-done/contributions.json"
  printf '{"records":[{"url":"https://github.com/acme/alpha/pull/10","checked_at":"%s","observation":{"checks":[{"name":"test","status":"completed","conclusion":"success"}]}}]}\n' \
    "$(iso 0)" > "$home/data/m-green/contributions.json"
  build "$home" FM_NM_FAIL="$home/nm.fail"
  has "$d/backlog.html" "3 pull requests or validations; 1 failing." \
    "Checks or validation failing 1" "m-done Main · checks failing" \
    "Validating or waiting on CI 1" "m-ci Main · waiting on CI for 2 h 18 min" \
    "Green, waiting to land 1" "m-green Main · checks green" \
    "Pull requests and validations open 1 + 1 + 1 = 3" "Longest CI wait now: 2 h 18 min (m-ci, Main), from no-mistakes."
  grep -q 'href="https://github.com/acme/alpha/pull/9"' "$d/backlog.html" || fail "validation run's PR not linked"
  has "$d/backlog.home.html" "Pull requests and validations open 3"
  has "$d/index.html" "Failing PRs with failing checks 1" "CI wait PRs on CI over 1 h 1 2 h 18 min" \
    "1 failing 1 validating or on CI 1 green, to land"
  # A validation status that cannot be read says unknown and why, and the checks still come from the records;
  # a finished lane whose checks are still running is not green yet.
  touch "$home/nm.fail"
  printf '{"records":[{"url":"https://github.com/acme/alpha/pull/10","checked_at":"%s","observation":{"checks":[{"name":"test","status":"in_progress","conclusion":null}]}}]}\n' \
    "$(iso 0)" > "$home/data/m-green/contributions.json"
  build "$home" FM_NM_FAIL="$home/nm.fail"
  has "$d/backlog.html" "Validation run unknown: 3 of 3 lanes: error: daemon not reachable" "No pull request is waiting on CI now." "m-done Main · checks failing" \
    "m-green Main · checks running" "Pull requests and validations open 1 + 2 = 3"
  lacks "$d/backlog.html" "Green, waiting to land"
  has "$d/measure.html" "no-mistakes axi status 3 of 3 lanes: error: daemon not reachable" "a CI wait over 1 h is a slow spot"
  lacks "$d/index.html" "PRs on CI over"
  pass "pull requests group by checks and validation, with CI wait from no-mistakes, and an unreadable run shows unknown"
}

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
import sys, urllib.request, urllib.error
def get(u, cookie=None):
    rq = urllib.request.Request(u, headers={'Cookie': cookie} if cookie else {})
    try:
        with urllib.request.urlopen(rq, timeout=120) as r: return r.status, r.read().decode(), r.headers.get('Set-Cookie') or ''
    except urllib.error.HTTPError as e: return e.code, '', ''
base = sys.argv[1]
for path, want in (('', 'Nothing needs you.'), ('flow', 'Latest landings'), ('quota', 'runs out first'),
                   ('backlog', 'Held for the captain'), ('measure', 'How each number is measured.')):
    code, body, _ = get(base + path)
    print(path or '/', code, want in body)
code, body, cookie = get(base + 'backlog?group=home')
print('group', code, 'fm_group=home' in cookie, '7 + 1 = <b>8</b>' in body)
code, body, _ = get(base, 'fm_group=home')
print('cookie', code, '7 + 1 = <b>8</b>' in body)
for path in ('state/', 'index.home.html', '../data/backlog.md', 'data/backlog.md'):
    print(path, get(base + path)[0])
PY
)
  [ "$got" = "$(printf '%s\n' '/ 200 True' 'flow 200 True' 'quota 200 True' 'backlog 200 True' 'measure 200 True' \
    'group 200 True True' 'cookie 200 True' 'state/ 404' 'index.home.html 404' '../data/backlog.md 404' 'data/backlog.md 404')" ] \
    || fail "serve answers were not the five pages, the remembered grouping, then 404s: $got"
  # An old page is answered at once, as it is, while a rebuild runs behind it.
  printf '<p>old page<!--age--></p>\n' > "$home/state/dashboard/index.html"
  touch -d '-5 minutes' "$home/state/dashboard/index.html"
  got=$(python3 -c 'import sys, urllib.request; print(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode())' "$url")
  case "$got" in *"old page · updated 3"[0-9][0-9]" s ago"*) ;; *) fail "an old page was not answered at once: $got" ;; esac
  for _ in $(seq 1 1200); do grep -q 'old page' "$home/state/dashboard/index.html" || break; sleep 0.1; done
  grep -q 'Nothing needs you' "$home/state/dashboard/index.html" || fail "the background rebuild did not replace the old page"
  kill "$SERVE_PID" 2>/dev/null; SERVE_PID=
  pass "serve answers the five pages at once, remembers ?group in a cookie, rebuilds an old page itself, and 404s every other path"
}

test_fleet_past_twenty_mates_keeps_every_lead_row() {
  local home d i mdir
  home=$(make_home many)
  d="$home/state/dashboard"
  # Mate homes must live outside the active home; empty ones read as
  # "Records need tidy-up", one row each, when the snapshot reads them.
  for i in $(seq -w 1 25); do
    mdir="$TMP_ROOT/mate$i"
    mkdir -p "$mdir/state" "$mdir/data"
    printf -- '- mate%s - domain %s (home: %s; scope: work; projects: alpha; added 2026-07-11)\n' \
      "$i" "$i" "$mdir" >> "$home/data/secondmates.md"
  done
  build "$home"
  has "$d/index.html" "mate25"
  python3 - "$d/index.html" <<'PY' || fail "the 25th mate lost its lead state"
import html, re, sys
text = re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', ' ', open(sys.argv[1]).read())))
for mate in ('mate01', 'mate25'):
    i = text.find(mate)
    assert i >= 0, mate
    assert 'Records need tidy-up' in text[i:i + 200], mate
PY
  pass "a fleet past twenty mates keeps every lead row"
}

test_overview_answers_the_four_questions_with_sums_that_add_up
test_sub_pages_show_flow_quota_backlog_and_method
test_fleet_past_twenty_mates_keeps_every_lead_row
test_each_failed_source_shows_unknown_and_why
test_github_searches_each_day_once_and_today_again_after_five_minutes
test_the_filing_log_counts_new_items_exactly
test_devices_and_machine_come_from_read_only_probes
test_pull_requests_show_validation_runs_and_checks_from_local_records
test_serve_answers_each_page_and_remembers_the_grouping
