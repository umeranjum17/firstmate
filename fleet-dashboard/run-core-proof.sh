#!/usr/bin/env bash
# Core journey: the fleet dashboard shows live fleet state in a real browser at a phone width.
# Seeds a throwaway Firstmate home (agent lanes, a landed task, queued and held tasks), serves this
# checkout's dashboard against that seed, opens it in headless Chrome at 390px, and writes the Board
# (lanes) and Insights (queue reasons) as text and screenshots to $DONE_DONE_EVIDENCE_ROOT.
# The seed is the only home read: no real fleet, no credentials, no live writes.
# FM_BIN names the Firstmate bin/ whose helper scripts the build runs (default: ~/firstmate/bin); the
# queue reasons come from this checkout's fleet-flow reader, which the build reaches through FM_ADDONS_DIR.
set -euo pipefail
: "${DONE_DONE_EVIDENCE_ROOT:?}"
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
FM_BIN=${FM_BIN:-$HOME/firstmate/bin}
[ -f "$FM_BIN/fm-tasks-axi.sh" ] || { echo "run-core-proof: FM_BIN has no fm-tasks-axi.sh: $FM_BIN" >&2; exit 1; }
home=$(mktemp -d)
bin=$home/bin
session=core-journey-$$
srv_pid=
cleanup() {
  CHROME_DEVTOOLS_AXI_SESSION=$session chrome-devtools-axi stop >/dev/null 2>&1 || true
  [ -z "$srv_pid" ] || kill "$srv_pid" 2>/dev/null || true
  rm -rf -- "$home"
}
trap cleanup EXIT

# One agent lane: state/<task>.meta, and a .status whose last line sets the lane's state.
lane() {  # <task> <kind> <status line>...
  local task=$1 kind=$2
  shift 2
  printf 'kind=%s\nproject=alpha\nharness=claude\nmodel=model-a\nherdr_pane_id=pane-%s\n' "$kind" "$task" > "$home/state/$task.meta"
  printf '%s\n' "$@" > "$home/state/$task.status"
}

seed() {
  local now today held_day
  now=$(date +%s) today=$(date +%F) held_day=$(date -d '7 days ago' +%F)
  mkdir -p "$home"/{data,state,config,stubs,locks,proc/pressure} "$bin"
  printf '3\n' > "$home/config/lane-target"
  printf 'main 6\n' > "$home/config/lane-caps"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] m-build - Build the main thing (repo: alpha) (kind: ship) (since $today)
- [ ] m-ci - Get the layout pull request through CI (repo: alpha) (kind: ship) (since $today)
- [ ] m-stuck - Publish the release from the build server (repo: alpha) (kind: ship) (since $today)
- [ ] m-ask - Choose the layout for the new screen (repo: alpha) (kind: ship) (since $today)

## Queued
- [ ] m-ready - Start the ready thing (repo: alpha) (kind: ship) (since $today)
- [ ] m-held - Wait for the captain's call (repo: alpha) (kind: ship) (since $held_day) (hold: needs his call) (hold-kind: captain)
- [ ] m-after - After the ready thing blocked-by: m-ready (repo: alpha) (kind: ship) (since $today)

## Done
- [x] m-shipped - Ship the main thing (repo: alpha) (kind: ship) (merged $today)
EOF
  lane m-build ship "working [at=$((now - 600))]: building the main thing"
  lane m-ci ship "paused [at=$((now - 1200))]: waiting for CI checks https://github.com/acme/alpha/pull/9"
  lane m-stuck ship "blocked [at=$((now - 7200))]: cannot reach the build server"
  lane m-ask ship "needs-decision [at=$((now - 3600))] [key=scope]: which layout"
  printf '{"ts":%s,"event":"ledger.started"}\n{"ts":%s,"event":"task.merged","task":"m-shipped","pr":"https://github.com/acme/alpha/pull/4"}\n' \
    "$((now - 172800))" "$((now - 60))" > "$home/state/fleet-ledger.jsonl"
  # What herdr reports for each lane's pane.
  cat > "$home/herdr.json" <<EOF
{"result":{"agents":[
 {"agent":"claude","agent_status":"working","cwd":"/wt/1","pane_id":"pane-m-build","name":"m-build"},
 {"agent":"claude","agent_status":"idle","cwd":"/wt/2","pane_id":"pane-m-ci","name":"m-ci"},
 {"agent":"claude","agent_status":"blocked","cwd":"/wt/3","pane_id":"pane-m-stuck","name":"m-stuck"},
 {"agent":"claude","agent_status":"idle","cwd":"/wt/4","pane_id":"pane-m-ask","name":"m-ask"}]}}
EOF
  # Stubs keep the dashboard off the real herdr, quota, device and service state.
  printf '#!/bin/sh\ncat "%s/herdr.json"\n' "$home" > "$home/stubs/herdr"
  printf '#!/bin/sh\nexit 1\n' > "$home/stubs/quota-axi"
  printf '#!/bin/sh\nprintf "List of devices attached\\n\\n"\n' > "$home/stubs/adb"
  # shellcheck disable=SC2016 # the single-quoted stub expands when it runs
  printf '#!/bin/sh\n[ "$1" = "-cf" ] && { echo 0; exit 0; }\nexit 1\n' > "$home/stubs/pgrep"
  printf '#!/bin/sh\nprintf "MemoryCurrent=0\\nMemoryHigh=34359738368\\nMemoryMax=40802189312\\n"\n' > "$home/stubs/systemctl"
  chmod +x "$home"/stubs/*
  printf 'MemTotal: 67108864 kB\nMemAvailable: 33554432 kB\n' > "$home/proc/meminfo"
  printf 'some avg10=0.00\n' > "$home/proc/pressure/memory"
  : > "$home/proc/locks"
  # The Firstmate helpers the build runs, linked in.
  for f in "$FM_BIN"/*; do ln -s "$f" "$bin/${f##*/}"; done
}

dash() {  # <build|serve> [args]: the dashboard against the seed home, with the stubs first on PATH
  env PATH="$home/stubs:$PATH" HOME="$home" FM_HOME="$home" FM_BIN="$bin" FM_ADDONS_DIR="$root" \
    FM_DEVICE_LOCK_DIR="$home/locks" FM_DASHBOARD_PROC="$home/proc" FM_MAC_HOST= \
    bash "$here/fm-dashboard.sh" "$@"
}

seed
dash build >/dev/null
dash serve --port 0 >"$home/serve.log" 2>&1 &
srv_pid=$!
url=
for _ in $(seq 100); do
  url=$(sed -n 's/^serving //p' "$home/serve.log" 2>/dev/null || true)
  [ -z "$url" ] || break
  kill -0 "$srv_pid" 2>/dev/null || { cat "$home/serve.log" >&2; exit 1; }
  sleep 0.2
done
[ -n "$url" ] || { cat "$home/serve.log" >&2; exit 1; }

export CHROME_DEVTOOLS_AXI_SESSION=$session
chrome-devtools-axi open "$url" >/dev/null
chrome-devtools-axi resize 390 844 >/dev/null
chrome-devtools-axi wait "m-stuck" >/dev/null
chrome-devtools-axi eval 'JSON.stringify({ viewport: innerWidth, text: document.body.innerText })' >"$DONE_DONE_EVIDENCE_ROOT/board.txt"
chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/board-390.png" >/dev/null
chrome-devtools-axi open "${url}#/insights" >/dev/null
chrome-devtools-axi wait "Why work waits" >/dev/null
sleep 2
chrome-devtools-axi eval 'JSON.stringify({ viewport: innerWidth, text: document.body.innerText })' >"$DONE_DONE_EVIDENCE_ROOT/queue.txt"
chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/queue-390.png" >/dev/null

# The page must show each seeded lane and each queue reason, not just render.
for want in m-stuck m-ask m-ci m-build "Main decides"; do
  grep -qF -- "$want" "$DONE_DONE_EVIDENCE_ROOT/board.txt" || { echo "run-core-proof: Board lacks '$want'" >&2; exit 1; }
done
for want in "Why work waits now" "Blocked · own note" "Lead reply" "Held"; do
  grep -qF -- "$want" "$DONE_DONE_EVIDENCE_ROOT/queue.txt" || { echo "run-core-proof: Insights lacks '$want'" >&2; exit 1; }
done

# The steps and result the check judges the captures against.
python3 - "$DONE_DONE_EVIDENCE_ROOT/steps.json" "$(git -C "$root" rev-parse --short HEAD)" <<'PY'
import json, sys
steps = {
    "target": {"version": sys.argv[2]},
    "start": "A seeded Firstmate home: four agent lanes, one landed task, three queued tasks, served by this checkout's dashboard",
    "steps": [
        "Open the fleet dashboard in headless Chrome at 390px",
        "Read the Board: each lane with its title and state",
        "Open Insights: the queue and wait reasons",
    ],
    "result": "The Board lists m-stuck, m-ask, m-ci and m-build with their titles and states; Insights shows Why work waits now with the Blocked, Lead reply and Held groups",
}
with open(sys.argv[1], "w") as f:
    json.dump(steps, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
