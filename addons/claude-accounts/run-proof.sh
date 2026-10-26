#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  eval "[ -n \"\${$_jg_new+set}\" ]" && continue
  eval "_jg_val=\${_jg_old}"
  export "$_jg_new=$_jg_val"
done
unset _jg_old _jg_new _jg_val 2>/dev/null || true
# run-proof.sh: the Claude accounts proof for done-done. Runs the real reader against the real muxr
# registry (folder paths go to quota-axi; nothing inside a login folder is opened) into a throwaway
# home, serves the real dashboard from that home and captures the Overview at phone width with
# `done-done look`, plus the fixture test. JG_BIN names a Juggernaut checkout's bin/ (the dashboard's helpers).
# The captured reading keeps account names and percentages only, never a folder.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
export JG_BIN=${JG_BIN:?set JG_BIN to a Juggernaut checkout bin/}
work=$(mktemp -d)
pid=
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null; rm -rf -- "$work"' EXIT
mkdir -p "$evidence" "$work/home/state"
export JG_HOME=$work/home

bash "$repo/claude-accounts/tests/claude-accounts.test.sh" >"$evidence/test.txt" 2>&1
"$repo/claude-accounts/bin/claude-accounts-quota.sh" >/dev/null
jq 'del(.accounts[].folder)' "$JG_HOME/state/claude-accounts.json" >"$evidence/reading.json"

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
bash "$repo/fleet-dashboard/jg-dashboard.sh" serve --bind 127.0.0.1 --port "$port" >"$work/serve.log" 2>&1 &
pid=$!
until curl -sf "http://127.0.0.1:$port/" >/dev/null; do sleep 1; done
done-done look "http://127.0.0.1:$port/#/overview" --out "$evidence/overview-390.png"
# The look step only sees the first screen; the whole Overview at the same width shows the card itself.
chrome=${DONE_DONE_CHROME:-$(command -v chromium || command -v google-chrome-stable)}
"$chrome" --headless --no-sandbox --user-data-dir="$work/chrome" --window-size=390,2600 --virtual-time-budget=4000 \
  --screenshot="$evidence/overview-full-390.png" "http://127.0.0.1:$port/#/overview" >/dev/null 2>&1
echo "run-proof: reading, test output and the 390px Overview are in $evidence"
