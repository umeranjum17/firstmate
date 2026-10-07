#!/usr/bin/env bash
# Behavior tests for bin/fm-dashboard.sh: build the page from a tiny fixture
# home through the real script (and the real fleet snapshot), then read the
# page's visible text the way a person would, and over `serve`.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# The page's visible text, one space between words.
page_text() {  # <page>
  python3 - "$1" <<'PY'
import html, re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'<(style|title)>.*?</\1>', ' ', s, flags=re.S)
print(re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', ' ', s))))
PY
}

when() {  # <hours ago> -> UTC ISO time and the local day it falls on
  python3 -c 'import sys; from datetime import datetime, timedelta, timezone as z
t = datetime.now(z.utc) - timedelta(hours=float(sys.argv[1]))
print(t.strftime("%Y-%m-%dT%H:%M:%SZ"), t.astimezone().date())' "$1"
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1" now_ts today y_ts tab
  tab=$(printf '\t')
  read -r now_ts today < <(when 0)
  read -r y_ts _ < <(when 24)
  mkdir -p "$home/data/metrics" "$home/state" "$home/config" "$home/projects/wt"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] alpha-fix - Fix the alpha thing (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
- [ ] beta-next - Start the beta thing (repo: alpha) (kind: ship)

## Done
- [x] gamma-done - Landed gamma https://example.invalid/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-10)
EOF
  fm_write_meta "$home/state/alpha-fix.meta" "window=firstmate:fm-alpha-fix" "worktree=$home/projects/wt" \
    "project=alpha" "harness=claude" "kind=ship" "mode=no-mistakes"
  printf 'working: building\n' > "$home/state/alpha-fix.status"
  sed "s/|/$tab/g" > "$home/data/metrics/prs.tsv" <<EOF
home|pr|created|merged|hours_to_merge|first_pass|escaped
alpha|1|$now_ts|$now_ts|1.0|1|0
alpha|2|$now_ts|$now_ts|2.0|1|0
alpha|3|$now_ts|$now_ts|3.0|0|0
beta|4|$y_ts|$y_ts|4.0|0|0
EOF
  sed "s/|/$tab/g" > "$home/data/metrics/daily.tsv" <<EOF
day|home|steers|s_correct|stall_alarms|self_rings|relaunches|skill_reads
$today|alpha|4|1|2|0|1|7
$today|beta|0|0|0|0|0|5
EOF
  sed "s/|/$tab/g" > "$home/data/metrics/skills.tsv" <<EOF
day|home|skill|reads
$today|alpha|verify-alpha|7
$today|beta|pre-review-check|5
EOF
  # A pulse file whose header predates its later columns, as long-lived ones do.
  sed "s/|/$tab/g" > "$home/data/fleet-pulse.tsv" <<EOF
time|home|merged2h|working|paused|blocked
${today}T01:00|alpha|0|1|0|0|5|3|2|1.5|10|0|900
${today}T01:00|beta|0|1|0|0|2|1|1|0.4|5|0|900
EOF
  sed "s/|/$tab/g" > "$home/config/metrics-targets.tsv" <<'EOF'
# metric|op|target|owner|rule
first_pass|>=|70|each home|prove before PR
stall_alarms|<=|0|each home|watcher wakes idle leads
EOF
  # A registered home with no metrics rows at all, under a made-up name.
  mkdir -p "$home/mates/zephyrine/data" "$home/mates/zephyrine/state"
  cat > "$home/config/fm-flow-check.sh" <<'EOF'
#!/bin/sh
printf 'home\t1\t1\t0\t0\t0\t-1\n'
EOF
  chmod +x "$home/config/fm-flow-check.sh"
  printf -- '- quillwork [direct-PR] - made-up project (added 2026-07-11)\n' > "$home/mates/zephyrine/data/projects.md"
  printf -- '- zephyrine - made-up domain (home: %s; scope: made-up work; projects: other; added 2026-07-11)\n' \
    "$home/mates/zephyrine" > "$home/data/secondmates.md"
  printf -- '- alpha [no-mistakes] - fixture project (added 2026-07-11)\n' > "$home/data/projects.md"
  printf '%s\n' "$home"
}

test_the_page_answers_the_questions_with_the_fixture_numbers() {
  local home page text out want
  home=$(make_home full)
  out=$(FM_HOME="$home" "$DASH" build) || fail "build failed: $out"
  page="$home/state/dashboard/index.html"
  [ "$out" = "$page" ] || fail "build did not print the page path: $out"
  ! grep -Eq '<script|https?://[^"]*\.(css|js)' "$page" || fail "page is not self-contained"
  text=$(page_text "$page")
  for want in "Running now 1" "Finished, not landed 3" "Merged today 3 yesterday 1" "Queued and ready 4" \
    "Not automatic yet: 2 lead stalls reached Main" "12 skill reads today" "verify-alpha 7" \
    "First-pass merges 50%" "Fix the alpha thing" "Start the beta thing" "Landed gamma" \
    "zephyrine Records need tidy-up quillwork" "Main alpha"; do
    case "$text" in *"$want"*) ;; *) fail "page text lacks '$want': $text" ;; esac
  done
  ! grep -q '<details open' "$page" || fail "a work list starts open"
  grep -q '<b>zephyrine</b>' "$page" || fail "a registered home with no metrics rows has no row"
  grep -q 'class="q bad"><span>First-pass merges' "$page" || fail "a missed first-pass target is not marked as a miss"
  pass "the page answers the questions with the fixture's numbers"
}

green_pr() {  # <home> <task> <url>: a fresh observed open PR with green checks the captain could merge
  mkdir -p "$1/data/$2"
  jq -n --arg task "$2" --arg url "$3" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {schema:"fm-contributions.v1",task:$task,records:[{
      url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
      observation:{head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",state:"open",draft:false,mergeable:"mergeable",
        review_decision:"",can_merge:true,
        checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],
        reviews:[],events:[]}}]}' > "$1/data/$2/contributions.json"
}

test_totals_count_only_work_that_waits() {
  local home page text out want
  home=$(make_home live)
  # alpha-fix's own record names its project, so its PR resolves to alpha whatever the repo is called.
  printf -- '- alpha [no-mistakes +yolo] - fixture project (added 2026-07-11)\n- delta [direct-PR] - fixture project (added 2026-07-11)\n' \
    > "$home/data/projects.md"
  green_pr "$home" alpha-fix https://github.com/o/alpha-repo/pull/11
  green_pr "$home" delta-pr https://github.com/o/delta/pull/12
  green_pr "$home" ghost-pr https://github.com/o/ghost/pull/13
  printf '# parked by the captain\nbeta\n' > "$home/config/parked-homes"
  mkdir -p "$home/mates/alpha/data" "$home/mates/alpha/state"
  printf -- '- alpha - fixture domain (home: %s; scope: fixture; projects: alpha; added 2026-07-11)\n' \
    "$home/mates/alpha" >> "$home/data/secondmates.md"
  # The home's flow check reports two finished lanes for every home it is asked about.
  cat > "$home/config/fm-flow-check.sh" <<'EOF'
#!/bin/sh
[ -d "$1/data" ] || exit 1
printf 'x\t3\t1\t0\t2\t0\t-1\n'
EOF
  chmod +x "$home/config/fm-flow-check.sh"
  out=$(FM_HOME="$home" "$DASH" build) || fail "build failed: $out"
  page="$home/state/dashboard/index.html"
  text=$(page_text "$page")
  for want in "Waiting on you 0 Nothing needs you right now." \
    "Finished, not landed 6 Merged today" "Merged today 3 yesterday 0" \
    "Queued and ready 0" "Running now 1 Finished" "beta Parked"; do
    case "$text" in *"$want"*) ;; *) fail "page text lacks '$want': $text" ;; esac
  done
  ! grep -q 'pull/11' "$page" || fail "a green PR in a +yolo project waits on the captain: $text"
  grep -Eq '<tr class="parked"><th>.*<b>beta</b><span class="chip ">Parked</span></span>(<small>[^<]*</small>)?</th><td colspan="[0-9]+"></td></tr>' "$page" \
    || fail "the parked home row shows numbers"
  pass "totals leave out parked homes and self-merged PRs, and count finished lanes now"
}

test_merged_days_use_the_same_bounded_github_source() {
  local home page text out want r clone
  home=$(make_home ghlive)
  # zephyrine clones two repos and a parked home a third; the search also returns a repo no home clones.
  printf -- '- parkedmate - fixture domain (home: %s; scope: fixture; projects: held; added 2026-07-11)\n' \
    "$home/mates/parkedmate" >> "$home/data/secondmates.md"
  printf 'parkedmate\n' > "$home/config/parked-homes"
  for r in zephyrine/quillwork=https://github.com/acme/quillwork.git zephyrine/shared=git@github.com:acme/shared.git \
    parkedmate/held=https://github.com/acme/held; do
    clone="$home/mates/${r%%/*}/projects/$(basename "${r%%=*}")"
    git init -q "$clone" && git -C "$clone" remote add origin "${r#*=}"
  done
  mkdir -p "$home/bin" "$home/mates/parkedmate/state"
  cat > "$home/bin/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$home/gh.calls"
[ -e "$home/gh.fail" ] && { echo 'HTTP 403: API rate limit exceeded' >&2; exit 1; }
case "\$*" in *"merged:>="*|*"merged:<"*) echo 'expected one merged:start..end range' >&2; exit 1 ;; esac
printf '%s\n' '[{"total_count":5,"incomplete_results":false,"items":[{"id":1,"repository_url":"https://api.github.com/repos/acme/quillwork"},{"id":2,"repository_url":"https://api.github.com/repos/acme/quillwork"},{"id":3,"repository_url":"https://api.github.com/repos/acme/shared"},{"id":4,"repository_url":"https://api.github.com/repos/acme/held"},{"id":5,"repository_url":"https://api.github.com/repos/acme/other"}]}]'
EOF
  chmod +x "$home/bin/gh"
  page="$home/state/dashboard/index.html"
  out=$(PATH="$home/bin:$PATH" FM_HOME="$home" "$DASH" build) || fail "build failed: $out"
  text=$(page_text "$page")
  for want in "Merged today 3 yesterday 3 · GitHub as of" "zephyrine Records need tidy-up quillwork – – 0 – 0 – 3 "; do
    case "$text" in *"$want"*) ;; *) fail "page text lacks '$want': $text" ;; esac
  done
  [ "$(wc -l < "$home/gh.calls")" -eq 2 ] || fail "not two bounded day searches: $(cat "$home/gh.calls")"
  grep -q 'q=owner:acme is:pr is:merged merged:20[0-9-]*T[0-9:]*Z\.\.20[0-9-]*T[0-9:]*Z' "$home/gh.calls" || fail "unexpected search: $(cat "$home/gh.calls")"
  # A rebuild inside 5 minutes reuses the count and does not search, even when GitHub would fail.
  touch "$home/gh.fail"
  PATH="$home/bin:$PATH" FM_HOME="$home" "$DASH" build >/dev/null || fail "cached build failed"
  [ "$(wc -l < "$home/gh.calls")" -eq 2 ] || fail "a rebuild inside 5 minutes searched again"
  case "$(page_text "$page")" in *"Merged today 3 yesterday 3 · GitHub as of"*) ;; *) fail "the cached count was not shown" ;; esac
  # After 5 minutes a failed search falls back to prs.tsv, says how old that count is, and shows why.
  python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c["at"]-=301; json.dump(c,open(p,"w"))' \
    "$home/state/dashboard/.merged-today.json"
  touch -d "$(date +%F) 00:01" "$home/data/metrics/prs.tsv"
  PATH="$home/bin:$PATH" FM_HOME="$home" "$DASH" build >/dev/null || fail "fallback build failed"
  text=$(page_text "$page")
  for want in "Merged today 3 yesterday 1 · as of 00:01" "GitHub merged-today search : HTTP 403: API rate limit exceeded"; do
    case "$text" in *"$want"*) ;; *) fail "page text lacks '$want': $text" ;; esac
  done
  grep -q 'merged:[^ ]*\.\.[^ ]*:59Z' "$home/gh.calls" || fail "day range has no inclusive last-second boundary"
  rm -f "$home/gh.fail"
  python3 -c 'import json,sys; json.dump({"scope":json.load(open(sys.argv[1]))["scope"],"day":json.load(open(sys.argv[1]))["day"],"at":"yesterday","yesterday":[1,2]},open(sys.argv[1],"w"))' \
    "$home/state/dashboard/.merged-today.json"
  PATH="$home/bin:$PATH" FM_HOME="$home" "$DASH" build >/dev/null || fail "corrupt cache build failed"
  [ "$(wc -l < "$home/gh.calls")" -gt 4 ] || fail "a corrupt cache was trusted instead of searched again"
  case "$(page_text "$page")" in *"Merged today 3 yesterday 3 · GitHub as of"*) ;; *) fail "corrupt cache was not recomputed" ;; esac
  python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c["scope"]=c["scope"][1:]; c["homes"]={"zephyrine":777}; json.dump(c,open(p,"w"))' \
    "$home/state/dashboard/.merged-today.json"
  PATH="$home/bin:$PATH" FM_HOME="$home" "$DASH" build >/dev/null || fail "old-query cache build failed"
  case "$(page_text "$page")" in *"Merged today 3 yesterday 3 · GitHub as of"*) ;; *) fail "old two-qualifier cache was reused" ;; esac
  pass "both merge days use one bounded range, reject old-query caches, and fall back together with an explicit time"
}

test_devices_and_machine_come_from_read_only_probes() {
  local home page text want proc locks bin key at
  home=$(make_home probes)
  proc="$home/proc" locks="$home/locks" bin="$home/stubs"
  mkdir -p "$proc/pressure" "$proc/900" "$proc/800" "$locks" "$bin"
  printf 'MemTotal:       67108864 kB\nMemAvailable:   10485760 kB\n' > "$proc/meminfo"
  printf 'some avg10=3.50 avg60=1.00 avg300=0.50 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$proc/pressure/memory"
  printf 'Name:\tqemu-system-x86\nVmRSS:\t 4194304 kB\n' > "$proc/900/status"
  printf '900 (qemu-system-x86) S 800 900 1\n' > "$proc/900/stat"
  printf '800 (flock) S 1 800 1\n' > "$proc/800/stat"
  : > "$locks/fm-phone-PHONE1.lock"
  : > "$locks/fm-phone-muxr-emu.lock"
  # The kernel lists a held flock by device and inode; only the emulator lock is held.
  key=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{os.major(s.st_dev):02x}:{os.minor(s.st_dev):02x}:{s.st_ino}")' "$locks/fm-phone-muxr-emu.lock")
  printf '1: FLOCK  ADVISORY  WRITE 800 %s 0 EOF\n' "$key" > "$proc/locks"
  at=$(python3 -c 'from datetime import datetime,timedelta,timezone as z; print((datetime.now(z.utc)-timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  printf '%s PHONE1 acquired pid=700 waited=0s cwd=/tmp/fm-alpha-fix\n%s PHONE1 released pid=700 rc=0\n%s muxr-emu acquired pid=800 waited=0s cwd=%s\n' \
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
  page="$home/state/dashboard/index.html"
  PATH="$bin:$PATH" FM_HOME="$home" FM_DASHBOARD_PROC="$proc" FM_DEVICE_LOCK_DIR="$locks" "$DASH" build >/dev/null || fail "probe build failed"
  text=$(page_text "$page")
  for want in "Machine 10 GB free · pressure 4% · heavy jobs wait" "Devices 2 connected · 1 in use" \
    "Phone Pixel 9 PHONE1 · USB Free · last used by Main 10 min ago" \
    "Emulator test-avd emulator-5554 · 4.0 GB in use In use by Main · 10 min" \
    "Free memory 10.0 GB of 64 GB" "Memory pressure 4%" "Heavy jobs 8.0 GB of 32 GB" "hard limit 38 GB" \
    "Gradle builds 2 of 2" "Emulators 1 of 2"; do
    case "$text" in *"$want"*) ;; *) fail "page text lacks '$want': $text" ;; esac
  done
  [ "$(sort -u "$home/adb.calls")" = "devices -l" ] || fail "adb was asked more than the device list: $(cat "$home/adb.calls")"
  # Each failed probe says unknown and why; nothing is guessed as zero.
  touch "$home/adb.fail" "$home/systemctl.fail"
  rm "$proc/meminfo" "$proc/locks"
  PATH="$bin:$PATH" FM_HOME="$home" FM_DASHBOARD_PROC="$proc" FM_DEVICE_LOCK_DIR="$locks" "$DASH" build >/dev/null || fail "failed-probe build failed"
  text=$(page_text "$page")
  for want in "Machine pressure 4%" "Devices unknown: adb: error: daemon not running" \
    "Free memory unknown: $proc/meminfo: No such file or directory" "Heavy jobs unknown: Failed to connect to bus" \
    "unknown - device locks: $proc/locks: No such file or directory" "Emulator test-avd not listed by adb · 4.0 GB in use unknown:"; do
    case "$text" in *"$want"*) ;; *) fail "page text lacks '$want': $text" ;; esac
  done
  case "$text" in *"0 connected"*|*"Free memory 0"*) fail "a failed probe was shown as zero: $text" ;; esac
  pass "devices and machine come from read-only probes, name each holder's home, and say unknown with the reason"
}

SERVE_PID=
trap '[ -z "$SERVE_PID" ] || kill "$SERVE_PID" 2>/dev/null; fm_test_cleanup' EXIT

test_serve_answers_the_page_and_nothing_else() {
  local home url got
  home=$(make_home served)
  FM_HOME="$home" "$DASH" serve --port 0 > "$home/serve.out" 2> "$home/serve.err" &
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
def get(u):
    try:
        with urllib.request.urlopen(u, timeout=60) as r: return r.status, r.read().decode()
    except urllib.error.HTTPError as e: return e.code, ''
code, body = get(sys.argv[1])
print(code, 'Merged today' in body and 'Fleet dashboard' in body)
for path in ('state/', 'index.html/..', '../data/metrics/prs.tsv', 'data/metrics/prs.tsv'):
    print(get(sys.argv[1] + path)[0])
PY
)
  [ "$got" = "$(printf '200 True\n404\n404\n404\n404')" ] || fail "serve answers were not page-then-404s: $got"
  # An old page is answered at once, as it is, while a rebuild runs behind it.
  printf '<p>old page<!--age--></p>\n' > "$home/state/dashboard/index.html"
  touch -d '-5 minutes' "$home/state/dashboard/index.html"
  got=$(python3 -c 'import sys, urllib.request; print(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode())' "$url")
  case "$got" in *"old page · updated 3"[0-9][0-9]" s ago"*) ;; *) fail "an old page was not answered at once: $got" ;; esac
  for _ in $(seq 1 600); do grep -q 'old page' "$home/state/dashboard/index.html" || break; sleep 0.1; done
  grep -q 'Fleet dashboard' "$home/state/dashboard/index.html" || fail "the background rebuild did not replace the old page"
  kill "$SERVE_PID" 2>/dev/null; SERVE_PID=
  pass "serve returns the page with 200 at once, rebuilds an old one by itself, and 404s every other path"
}

test_missing_or_malformed_sources_hide_only_their_part() {
  local home page text out
  home=$(make_home partial)
  rm "$home/data/metrics/skills.tsv" "$home/data/fleet-pulse.tsv"
  printf 'nonsense\n1\n' > "$home/data/metrics/daily.tsv"
  printf 'alpha\n' >> "$home/data/metrics/prs.tsv"  # a cut-off appended line
  # A broken snapshot bound makes the fleet snapshot itself exit non-zero.
  out=$(FM_HOME="$home" FM_BEARINGS_LANDED=0 "$DASH" build 2>&1) || fail "a missing source failed the build: $out"
  page="$home/state/dashboard/index.html"
  text=$(page_text "$page")
  for want in "data/metrics/skills.tsv : not found" "data/fleet-pulse.tsv : not found" \
    "data/metrics/daily.tsv : malformed" "data/metrics/prs.tsv : 1 short row(s) skipped" "fleet snapshot exited 2: fm-bearings-snapshot: FM_BEARINGS_LANDED must be a positive integer" "Merged today 3 yesterday 1"; do
    case "$text" in *"$want"*) ;; *) fail "page text lacks '$want': $text" ;; esac
  done
  case "$text" in *"Waiting on you 0"*"Running now 1"*) ;; *) fail "independent tiles disappeared with the snapshot: $text" ;; esac
  pass "missing or malformed sources hide only their own part and never fail the build"
}

test_who_does_the_work_groups_lanes_by_harness_and_model() {
  local home page text out want tab now_ts old_ts
  tab=$(printf '\t')
  home=$(make_home who)
  read -r now_ts _ < <(when 0)
  read -r old_ts _ < <(when 240)
  printf 'beta\n' > "$home/config/parked-homes"
  # alpha-fix runs in main (its record exists); zephyrine's lanes ended, two of their PRs merged this week.
  sed "s/|/$tab/g" > "$home/data/metrics/prs.tsv" <<EOF
home|repo|pr|merged|first_pass
zephyrine|acme/quillwork|5|$now_ts|1
zephyrine|acme/quillwork|6|$now_ts|0
zephyrine|acme/quillwork|7|$old_ts|1
EOF
  sed "s/|/$tab/g" > "$home/data/metrics/lanes.tsv" <<EOF
first_seen|home|task|kind|project|harness|model|effort|mode|pr
2026-10-06T09:35|main|zephyrine|secondmate|-|pi|lead-model-z|medium|secondmate|
2026-10-06T09:35|main|beta|secondmate|-|pi|parked-lead|medium|secondmate|
2026-10-06T09:35|main|alpha-fix|ship|alpha|claude|model-a|medium|no-mistakes|
2026-10-06T09:35|zephyrine|qw-1|ship|quillwork|pi|model-b|medium|direct-PR|https://github.com/acme/quillwork/pull/5
2026-10-06T09:35|zephyrine|qw-2|ship|quillwork|pi|model-b|medium|direct-PR|https://github.com/acme/quillwork/pull/6
2026-10-06T09:35|zephyrine|qw-3|ship|quillwork|pi|model-b|medium|direct-PR|https://github.com/acme/quillwork/pull/7
2026-10-06T09:35|beta|b-1|ship|b|codex|parked-model|medium|direct-PR|
EOF
  out=$(FM_HOME="$home" "$DASH" build) || fail "build failed: $out"
  page="$home/state/dashboard/index.html"
  text=$(page_text "$page")
  for want in "Who does the work Worker model Running Merged, 7 days First pass" \
    "claude · model-a 1 0 –" "pi · model-b 0 2 50%" "zephyrine Records need tidy-up quillwork lead-model-z" "Recorded since 2026-10-06"; do
    case "$text" in *"$want"*) ;; *) fail "page text lacks '$want': $text" ;; esac
  done
  case "$text" in *parked-model*|*parked-lead*) fail "a parked home shows in Who does the work: $text" ;; esac
  # No lane record yet: the section says so and Missing data names the file.
  : > "$home/data/metrics/lanes.tsv"
  FM_HOME="$home" "$DASH" build >/dev/null || fail "build with an empty lane record failed"
  text=$(page_text "$page")
  for want in "Who does the work No record yet." "data/metrics/lanes.tsv : empty"; do
    case "$text" in *"$want"*) ;; *) fail "page text lacks '$want': $text" ;; esac
  done
  pass "Who does the work groups lanes by harness and model, joins merges by PR URL, and leaves out parked homes"
}

test_main_asks_and_lane_verbs_are_authoritative() {
  local home page text now task today yesterday
  home=$(make_home exact)
  read -r _ today < <(when 0)
  read -r _ yesterday < <(when 24)
  printf '%s\talpha\t6\t0\t5\t99\t3\t0\n' "$yesterday" >> "$home/data/metrics/daily.tsv"
  printf 'day\thome\n%s\talpha\n%s\talpha\n%s\tbeta\n' "$today" "$yesterday" "$yesterday" > "$home/data/metrics/rings.tsv"
  page="$home/state/dashboard/index.html"
  now=$(date +%s)
  : > "$home/data/captain-asks.tsv"
  FM_HOME="$home" "$DASH" build >/dev/null || fail "empty ask build failed"
  grep -q '<section class="asks ok" id="asks"><div class="ah"><h2>Waiting on you</h2><b class="an">0</b>' "$page" || fail "empty asks not zero and ok"
  printf 'first\t%s\tApprove Umer release\thttps://example.invalid/release\nsecond\t%s\tChoose launch date\t\n' \
    "$((now - 7200))" "$((now - 3600))" > "$home/data/captain-asks.tsv"
  # A resolved lane is working, but a still-open captain hold is not, even after working resumes.
  for task in resolved held; do
    fm_write_meta "$home/state/$task.meta" 'kind=ship'
  done
  printf 'resolved [at=%s]: ready to continue\n' "$now" > "$home/state/resolved.status"
  printf 'blocked [at=%s] [key=captain-hold-x]: decision\nworking [at=%s]: resumed\n' "$now" "$now" > "$home/state/held.status"
  FM_HOME="$home" "$DASH" build >/dev/null || fail "two ask build failed"
  text=$(page_text "$page")
  for task in 'Running now 2' 'Waiting on you 2' 'Approve Umer release 2 h' 'Choose launch date 1 h' \
    '2 stalls reached Main yesterday 5' '1 leads woken automatically yesterday 2' \
    '1 stopped leads restarted yesterday 3' '4 Main messages to leads yesterday 6'; do
    case "$text" in *"$task"*) ;; *) fail "missing $task: $text" ;; esac
  done
  grep -q 'href="https://example.invalid/release"' "$page" || fail "ask URL not linked"
  printf 'bad row\n' >> "$home/data/captain-asks.tsv"
  FM_HOME="$home" "$DASH" build >/dev/null || fail "malformed ask build failed"
  text=$(page_text "$page")
  case "$text" in *'Waiting on you 3'*'Ask record needs correction'*'malformed row 3'*) ;; *) fail "malformed row guessed or dropped: $text" ;; esac
  python3 -c 'print("huge\t" + "9"*5000 + "\tOverlong epoch\t")' >> "$home/data/captain-asks.tsv"
  FM_HOME="$home" "$DASH" build >/dev/null || fail "overlong epoch build failed"
  text=$(page_text "$page")
  case "$text" in *'Waiting on you 4'*'Ask record needs correction'*'malformed row 4'*) ;; *) fail "overlong epoch crashed or was dropped: $text" ;; esac
  # UTC yesterday 21:00 is today 01:00 in the captain's +04 local day.
  yesterday=$(TZ=Etc/GMT-4 python3 -c 'from datetime import datetime,timedelta; print((datetime.now().date()-timedelta(days=1)).isoformat())')
  printf 'home\tmerged\tfirst_pass\nalpha\t%sT21:00:00Z\t1\n' "$yesterday" > "$home/data/metrics/prs.tsv"
  TZ=Etc/GMT-4 FM_HOME="$home" "$DASH" build >/dev/null || fail "local-day build failed"
  case "$(page_text "$page")" in *'Merged today 1 yesterday 0'*) ;; *) fail "UTC date used instead of local day" ;; esac
  pass "Main asks, lane verbs, alert counts and +04 local merge days are exact from their records"
}

test_the_page_answers_the_questions_with_the_fixture_numbers
test_main_asks_and_lane_verbs_are_authoritative
test_totals_count_only_work_that_waits
test_missing_or_malformed_sources_hide_only_their_part
test_who_does_the_work_groups_lanes_by_harness_and_model
test_merged_days_use_the_same_bounded_github_source
test_serve_answers_the_page_and_nothing_else
test_devices_and_machine_come_from_read_only_probes
