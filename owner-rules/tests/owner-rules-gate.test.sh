#!/usr/bin/env bash
# owner-rules merge-gate e2e: the config/merge-gate that install.sh writes, run with the args fm-pr-merge.sh passes.
# Usage: owner-rules/tests/owner-rules-gate.test.sh
# Proves one refusal (no receipt) and one clean pass (a stubbed sealed clean done-done run at the head), plus the
# screen: none exemption, the chained previous gate, and the no-op once uninstalled. No forge, no done-done.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/owner-rules-gate.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }

home=$work/home; mkdir -p "$home/config" "$home/data/lane/.done-done/runs" "$work/bin"
pr=https://github.com/umeranjum17/firstmate-addons/pull/9 head=abc123
# gh stub: the PR body is whatever is in $work/body.
printf '#!/bin/sh\ncat "%s/body" 2>/dev/null\n' "$work" > "$work/bin/gh"; chmod +x "$work/bin/gh"
# A previous gate that records it ran.
printf '#!/bin/sh\necho "prev gate ran: $*"\n' > "$home/config/merge-gate"; chmod +x "$home/config/merge-gate"
cat > "$work/bin/sign-off-axi" <<'STUB'
#!/usr/bin/env bash
[ "$1" = post ] || exit 2
shift; board=$1; shift
while [ "$1" != --from ]; do shift; done
card=$2
jq --slurpfile c "$card" '.items += [($c[0] + {type:"evidence",filer:"firstmate-merge"})]' "$board" > "$board.tmp" && mv "$board.tmp" "$board"
STUB
chmod +x "$work/bin/sign-off-axi"
printf '{"schema":1,"answers_only":false,"items":[]}\n' > "$work/board.json"
# shellcheck disable=SC2119,SC2120
gate() { PATH=$work/bin:$PATH FM_HOME=$home FM_FLEET_BOARD=${3:-$work/board.json} "$home/config/merge-gate" lane - "${1:-$head}" "${2:-$pr}" 2>&1; printf 'rc=%s\n' "$?"; }
run=$home/data/lane/.done-done/runs/r1.json
seal() { printf '{"schema":1,"exit":0,"dirty":false,"commit":"%s","files":["a.png"],"run_id":"r1"}\n' "$1" > "$run"; }

"$addons/owner-rules/install.sh" "$home" >/dev/null
is "installed: previous gate moved aside" "$([ -x "$home/config/merge-gate.pre-owner-rules" ] && echo yes)" yes
"$addons/owner-rules/install.sh" "$home" >/dev/null && ok "install is idempotent" || no "second install failed"

REFUSAL="owner-rules: no passed-proof receipt for $pr; run the done-done check and post the evidence to the sign-off Evidence tab first"
is "refusal: no receipt" "$(gate)" "$REFUSAL
rc=1"
seal other; is "refusal: a run at a different head" "$(gate | tail -1)" "rc=1"
seal "$head"; printf '{"schema":1,"exit":0,"dirty":true,"commit":"%s","files":["a"],"run_id":"r1"}\n' "$head" > "$run"
is "refusal: a dirty run" "$(gate | tail -1)" "rc=1"
seal "$head"
LINT="owner-rules: no checks-lint PASS for $pr at $head; run FM_HOME=$home config/fm-checks-lint.sh $pr <evidence folder> first"
is "refusal: receipt but no checks-lint row" "$(gate)" "$LINT
rc=1"
log=$home/data/checks-gate.log
printf 't\t%s\tother\tpass\tok\nt\t%s\t%s\tfail\tno\n' "$pr" "$pr" "$head" > "$log"
is "refusal: lint row for another head, or failed" "$(gate | tail -1)" "rc=1"
printf 't\t%s\t%s\tpass\tok\n' "$pr" "$head" >> "$log"
is "refusal: receipt and lint but missing board card" "$(gate | tail -1)" "rc=1"
cardkey=merge-umeranjum17-firstmate-addons-pull-9
jq --arg k "$cardkey" --arg h "$head" '.items += [{kind:"evidence",type:"evidence",filer:"firstmate-merge",key:$k,run:{commit:$h}}]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
is "pass: receipt, lint, and card then previous gate" "$(gate)" "prev gate ran: lane - $head $pr
rc=0"
for fields in '{"run":{"commit":"abc123"}}' '{"evidence":{"commit":"abc123"}}'; do
  jq --argjson fields "$fields" --arg k "$cardkey" '.items = [{kind:"evidence",key:$k} + $fields]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
  is "pass: card commit field $fields" "$(gate | tail -1)" "rc=0"
done
for fields in '{}' '{"run":{"commit":"wrong"}}' '{"evidence":{"commit":"wrong"}}' '{"run":{"commit":"abc123"},"evidence":{"commit":"wrong"}}'; do
  jq --argjson fields "$fields" --arg k "$cardkey" '.items = [{kind:"evidence",key:$k} + $fields]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
  is "refusal: invalid card commit fields $fields" "$(gate | tail -1)" "rc=1"
done
jq --arg k "$cardkey" --arg h "$head" '.items = [{kind:"evidence",key:$k,run:{commit:$h}}]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
rm -f "$run"; printf 'screen: none\n' > "$work/body"
printf '{"schema":1,"answers_only":false,"items":[]}\n' > "$work/board.json"
is "refusal: screen: none without receipt refuses" "$(gate | tail -1)" "rc=1"
seal "$head"
jq -n '{schema:1,answers_only:false,items:[]}' > "$work/board.json"
is "pass: screen: none and receipt auto-posts text card" "$(gate)" "merge-card: posted text-only $cardkey evidence card
prev gate ran: lane - $head $pr
rc=0"
jq -e --arg k "$cardkey" '.items | any(.[]; .key==$k and .kind=="evidence" and .media==null and .run.commit!=null)' "$work/board.json" >/dev/null && ok "auto-post: text-only receipt card exists" || no "auto-post: text-only receipt card missing"
printf '{"schema":1,"answers_only":false,"items":[]}\n' > "$work/board.json"
is "refusal: unreadable board refuses" "$(gate "$head" "$pr" "$work/missing-board" | tail -1)" "rc=1"
rm -f "$log"; is "refusal: screen: none still needs lint" "$(gate | tail -1)" "rc=1"
rm -f "$work/body"

"$addons/owner-rules/uninstall.sh" "$home" >/dev/null
is "uninstalled: no receipt is fine again" "$(gate)" "prev gate ran: lane - $head $pr
rc=0"

[ "$fails" -eq 0 ] && echo "PASS owner-rules-gate" || { echo "FAIL owner-rules-gate: $fails"; exit 1; }
