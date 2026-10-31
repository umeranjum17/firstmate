#!/usr/bin/env bash
# OPA shadow replay: run the shadow comparison over recorded delete-guard decisions in a throwaway home and check
# that it appends exactly one line per record and leaves every guard behaviour alone.
# It also proves the replay eval (`--require-agreement`), the gate that says whether a rule may switch to OPA.
# Usage: opa-shadow.test.sh [recorded-log]   (default: a 13-row sample of the fleet's recorded decisions)
# OPA is taken from $OPA, then PATH. Its version and install path are recorded in the task report.
# shellcheck disable=SC2016 # the cases are literal commands, never expanded here
set -euo pipefail
ADDON=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
OPA_BIN=${OPA:-$(command -v opa || true)}
[ -x "$OPA_BIN" ] || { echo "FAIL: no opa binary (set OPA=/path/to/opa)"; exit 1; }
LOG=${1:-$ADDON/tests/fixtures/delete-guard-opa-shadow.log}

T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/state"
cp "$LOG" "$T/home/state/delete-guard.log"
fails=0
ok() { echo "ok: $*"; }; no() { echo "FAIL: $*"; fails=1; }

before=$(sha256sum "$T/home/state/delete-guard.log" | cut -d' ' -f1)
node "$ADDON/opa-shadow.mjs" "$T/home" --opa "$OPA_BIN" > "$T/run.out" 2>&1 && ok "shadow runner ran" || no "runner failed: $(cat "$T/run.out")"

records=$(wc -l < "$T/home/state/delete-guard.log")
lines=$(wc -l < "$T/home/state/opa-shadow.log" 2>/dev/null || echo 0)
[ "$lines" -eq "$records" ] && ok "one line per record ($records)" || no "line count: $lines of $records"

# Every line names the record, both decisions and a verdict that agrees with those two decisions.
bad=$(awk '!($1 ~ /^[0-9]+$/ && $2 ~ /^(block|allow)$/ && $3 ~ /^(block|allow)$/ && $4 ~ /^(agree|differ)$/ \
  && (($2 == $3) == ($4 == "agree")))' "$T/home/state/opa-shadow.log" | wc -l)
[ "$bad" -eq 0 ] && ok "every line has both decisions and a matching verdict" || no "$bad malformed line(s): $(head -2 "$T/home/state/opa-shadow.log")"

# The comparison must actually compare: a run where OPA answered nothing would report all-agree on one side.
grep -qE '^[0-9]+ block ' "$T/home/state/opa-shadow.log" && grep -qE '^[0-9]+ allow ' "$T/home/state/opa-shadow.log" \
  && ok "both shell decisions appear, so OPA was asked and answered" || no "no mixed decisions: $(head -3 "$T/home/state/opa-shadow.log")"

# Nothing is enforced from OPA: the guard's own record is byte-identical and no wake was queued.
after=$(sha256sum "$T/home/state/delete-guard.log" | cut -d' ' -f1)
[ "$before" = "$after" ] && ok "recorded decisions untouched" || no "the runner rewrote the guard log"
[ ! -e "$T/home/state/.wake-queue" ] && ok "no wake queued" || no "the runner queued a wake"

# And the guard's own decider still answers the same way after the shadow run.
verdict() { node --input-type=module -e "import { blockedDelete } from '$ADDON/guard.mjs'; process.stdout.write(blockedDelete(process.argv[1]) === null ? 'allow' : 'block')" "$1"; }
[ "$(verdict 'rm -rf "$HOME"')" = block ] && [ "$(verdict 'rm -rf ./build')" = allow ] \
  && ok "guard still decides the same before and after" || no "guard behaviour changed"

# The replay eval: one recorded decision both deciders agree on must pass, one they differ on must refuse.
# Both corpora are single rows cut from the same recorded log, so this is real recorded input either way.
agree=$(awk '$4 == "agree" { print $1; exit }' "$T/home/state/opa-shadow.log")
differ=$(awk '$4 == "differ" { print $1; exit }' "$T/home/state/opa-shadow.log")
[ -n "$agree" ] && [ -n "$differ" ] || no "the sample must hold one agreeing and one differing record"
mkdir -p "$T/agree/state" "$T/differ/state"
sed -n "${agree}p" "$LOG" > "$T/agree/state/delete-guard.log"
sed -n "${differ}p" "$LOG" > "$T/differ/state/delete-guard.log"
node "$ADDON/opa-shadow.mjs" "$T/agree" --opa "$OPA_BIN" --require-agreement >/dev/null 2>&1 \
  && ok "the replay eval passes an agreeing record and would let the rule switch" || no "the eval refused an agreeing record"
node "$ADDON/opa-shadow.mjs" "$T/differ" --opa "$OPA_BIN" --require-agreement >/dev/null 2>&1 \
  && no "the replay eval let a differing decision through" || ok "the replay eval refuses a differing record"

# A home with no recorded decisions is a refusal, not an empty success.
mkdir -p "$T/bare"
node "$ADDON/opa-shadow.mjs" "$T/bare" --opa "$OPA_BIN" >/dev/null 2>&1 && no "no-log run exited 0" || ok "a home with no record is refused"

[ "$fails" -eq 0 ] && echo PASS || { echo FAIL; exit 1; }
