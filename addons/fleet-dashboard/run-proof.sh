#!/usr/bin/env bash
# Proof journey: render the real Insights "Why work waits now" card at 390px from real fleet data.
# DASH_HOME is a Juggernaut home to read; FLOW_JSON is a saved real `jg-flow.sh --json --capacity` run of it
# (a saved run keeps the proof repeatable while the live records move); JG_BIN is a Juggernaut bin/.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
: "${DASH_HOME:?}" "${FLOW_JSON:?}" "${JG_BIN:?}" "${DONE_DONE_EVIDENCE_ROOT:?}"
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
for f in "$JG_BIN"/*; do ln -s "$f" "$tmp/${f##*/}"; done
rm -- "$tmp/jg-flow.sh"
printf '#!/bin/bash\ncat %q\n' "$FLOW_JSON" >"$tmp/jg-flow.sh"
export JG_BIN=$tmp JG_HOME=$DASH_HOME
bash "$here/jg-dashboard.sh" build >/dev/null
timeout 240 bash "$here/jg-dashboard.sh" serve --port 0 >"$tmp/serve.log" 2>&1 &
url=
for _ in $(seq 50); do
  url=$(sed -n 's|^serving \(http[^ ]*\)|\1|p' "$tmp/serve.log")
  [ -z "$url" ] || break
  sleep 0.2
done
[ -n "$url" ] || { cat "$tmp/serve.log" >&2; exit 1; }
chrome-devtools-axi open "${url}#/insights" >/dev/null
chrome-devtools-axi resize 390 2500 >/dev/null
sleep 4
chrome-devtools-axi eval '(() => { const h = [...document.querySelectorAll("h2")].find(e => e.textContent.includes("Why work waits")); return JSON.stringify({ open: document.querySelectorAll(".i-stat")[4].innerText, card: h.parentElement.innerText }) })()' >"$DONE_DONE_EVIDENCE_ROOT/card.txt"
chrome-devtools-axi screenshot "$DONE_DONE_EVIDENCE_ROOT/after.png" >/dev/null
chrome-devtools-axi stop >/dev/null
