#!/usr/bin/env bash
# merge-card e2e: the real script, a stub done-done placed earlier on PATH, and a
# task folder holding a retained PNG and a Checks block that names it bare, as
# PR 24's did. Like the real one, the stub resolves each evidence name against
# --citation-base, else its cwd (the work copy), and fails a missing file. It
# runs in six modes: newer (accepts --citation-base like 0.3.1), older (rejects
# it like 0.3.0, so merge-card must resolve the names itself, for a PR body read
# through a stub gh and for a checks.md with an absolute and a missing name),
# liar (claims 0.3.1 and the flag, then rejects it, so the verdict must name the
# real reason),
# inconclusive (the proof does not hold up), nomedia (a pass that cites no
# proof file) and noclaim (a pass with media but no claim). Pass + media posts
# one evidence card titled with the claim; every gap posts nothing, prints one
# gap line and exits 0, and no run ever posts a report card. The recorded
# verdict, the invocation the stub saw, and whether the card's media resolves are
# asserted in each mode. Needs bash, jq, base64, cmp and sort -V on PATH; nothing
# is posted anywhere and no real tool outside this directory is touched.
set -u

here=$(cd "$(dirname "$0")" && pwd) || exit 1
[ -f "$here/../merge-card" ] || { echo "not ok - $here/../merge-card is missing"; exit 1; }
work=$(mktemp -d /var/tmp/merge-card-e2e.XXXXXX) || exit 1
trap 'rm -rf "$work"' EXIT

home=$work/home
wt=$work/wt
mkdir -p "$home/data" "$wt" "$work/bin"

# The retained proof: a real 1x1 PNG in the task folder, as a Checks block cites it.
shot=$work/shot.png
base64 -d > "$shot" <<'PNG' || exit 1
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
PNG

fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { # is <name> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi
}
holds() { # holds <name> <file>
  if [ -f "$2" ]; then ok "$1"; else no "$1: $2 is missing"; fi
}

# The stub done-done: MODE picks which done-done it emulates, and every argv line
# is logged so the test can prove which invocation merge-card chose.
cat > "$work/bin/done-done" <<'STUB' || exit 1
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DD_LOG"
case $1 in
  --version) case $MODE in older) echo 0.3.0 ;; *) echo 0.3.1 ;; esac; exit 0 ;;
esac
[ "${1:-}" = check ] || exit 0 # signoff: this checkout has no run record
if [ "${2:-}" = --help ]; then
  echo "usage: done-done check --from <file | - | PR URL> [--claim-id <id>] [--judge]"
  case $MODE in newer | liar) echo "  --citation-base <dir>  resolve relative evidence names from <dir>" ;; esac
  exit 0
fi
src='' base='' flag=0
while [ $# -gt 0 ]; do
  case $1 in
    --from) src=$2; shift 2 ;;
    --citation-base) flag=1 base=$2; shift 2 ;;
    --judge) # done-done 0.4.1: a route is required, so a bare flag is ambiguous
      case ${2:-} in "" | --*) jq -n '{error: "Option --judge argument is ambiguous"}'; exit 2 ;; esac
      shift 2 ;;
    *) shift ;;
  esac
done
case $MODE in
  newer | inconclusive | nomedia | noclaim) ;;
  *)
    if [ "$flag" = 1 ]; then
      jq -n '{error: "Unknown option \u0027--citation-base\u0027."}'
      exit 2
    fi ;;
esac
# The Checks evidence names as done-done reads them, each resolved and checked to exist.
ev=() missing=()
case $src in
  -) body=$(cat) ;;
  http*) body=$(gh pr view "$src" --json body | jq -r .body) ;;
  *) body=$(cat -- "$src") ;;
esac
for n in $(printf '%s\n' "$body" | sed -n 's/^evidence: *//p' | tr ',' ' '); do
  case $n in /*) ;; *) [ -z "$base" ] || n=$base/$n ;; esac
  ev+=("$n")
  [ -f "$n" ] || missing+=("$n: missing (ENOENT)")
done
if [ ${#missing[@]} -gt 0 ]; then
  jq -n '{result:"fail",claim:"a stopped worker moves to the next live route",evidence:$ARGS.positional[:1],findings:($ARGS.positional[1:] | map({level:"fail",why:.}))}' --args "${ev[0]}" "${missing[@]}"
  exit 1
fi
case $MODE in
  inconclusive)
    jq -n '{result:"inconclusive",claim:"a stopped worker moves to the next live route",evidence:[]}'
    exit 3 ;;
  nomedia)
    jq -n '{result:"pass",claim:"a stopped worker moves to the next live route",evidence:[]}' ;;
  noclaim)
    jq -n '{result:"pass",evidence:$ARGS.positional}' --args "${ev[@]}" ;;
  *)
    jq -n '{result:"pass",claim:"a stopped worker moves to the next live route",evidence:$ARGS.positional}' --args "${ev[@]}" ;;
esac
STUB

# The stub gh: a PR's Checks body and branch, as `gh pr view --json body,headRefName` gives them.
cat > "$work/bin/gh" <<'STUB' || exit 1
#!/usr/bin/env bash
case " $* " in *" --jq .headRefOid "*) printf '%s\n' "${GH_HEAD:-}"; exit 0 ;; esac
case " $* " in *" --jq .body "*) cat "$GH_BODY"; exit 0 ;; esac
jq -n --rawfile body "$GH_BODY" '{body: $body, headRefName: "fm/older"}'
STUB

# The stub sign-off-axi: capture the card and the media copied beside it, and
# log every invocation so the test can prove a gap never reached a post call.
cat > "$work/bin/sign-off-axi" <<'STUB' || exit 1
#!/usr/bin/env bash
# Like sign-off-axi 0.5.3: evidence is posted one at a time (a --from --replace feed of evidence is
# refused), a key it holds takes only the same message again, and dismiss keeps the card (archived).
if [ "${1:-}" = restore ]; then
  jq --arg k "$2" '.items |= map(if .key == $k then .dismissed=false else . end)' "$3" > "$3.tmp" && mv "$3.tmp" "$3"
  exit 0
fi
if [ "${1:-}" = dismiss ]; then
  printf 'dismiss %s\n' "$2" >>"$SO_LOG"
  jq --arg k "$2" '.items |= map(if .key == $k then .dismissed=true else . end)' "$3" > "$3.tmp" && mv "$3.tmp" "$3"
  exit 0
fi
if [ "${1:-}" = list ]; then
  jq '{board:"fixture",decisions:[.items[]? | {key,dismissed,evidence:(.run // .evidence)}]}' "$2"
  exit 0
fi
[ "${1:-}" = post ] || exit 0
printf '%s\n' "$*" >>"$SO_LOG"
board=$2
from='' replace=0
while [ $# -gt 0 ]; do
  if [ "$1" = --from ]; then from=$2; shift 2; elif [ "$1" = --replace ]; then replace=1; shift; else shift; fi
done
[ -n "$from" ] || exit 0
if [ "$replace" = 1 ]; then echo "feed.json: items[0]: evidence is posted one at a time, not in a --from file"; exit 2; fi
if [ -f "$board" ] && jq -e --slurpfile c "$from" 'any(.items[]?; .key == $c[0].key)' "$board" >/dev/null; then
  echo "key already holds a different message"; exit 2
fi
case "$from" in /tmp/*) echo "refusing temporary card path: $from" >&2; exit 1 ;; esac
if jq -e '.run? and ((.run.outcome // "") == "")' "$from" >/dev/null; then echo 'run.outcome must be text'; exit 2; fi
if jq -e '(.about | length) > 500 or (.run.outcome | length) > 1000' "$from" >/dev/null; then echo 'about/run field exceeds contract limit'; exit 2; fi
rm -rf "$SO_CAPTURE"
cp -r "$(dirname "$from")" "$SO_CAPTURE"
if [ -f "$board" ]; then
  jq --slurpfile c "$from" '.items += [($c[0] + {type:"evidence",filer:"firstmate-merge",dismissed:false})]' "$board" > "$board.tmp"
  mv "$board.tmp" "$board"
fi
STUB
chmod +x "$work/bin/done-done" "$work/bin/sign-off-axi" "$work/bin/gh"

head_c=e2ehead0000000000000000000000000000000000
: >"$work/so.log"
export SO_LOG=$work/so.log

run_check_and_post() { # run_check_and_post <task-id> [<pr-url>] (<mode> is already exported)
  PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" check "$1" "$wt" "$head_c" "${2:--}"
  PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" "$1" "$wt" "$head_c" "${2:--}"
}

checks() { # checks <task-id> <evidence>: the task folder's Checks block
  mkdir -p "$home/data/$1"
  printf '## Checks\n\noutcome: a stopped worker moves to the next live route\nrepro: n/a\nproof: no verify skill\nevidence: %s\n' "$2" >"$home/data/$1/checks.md"
}

# A newer done-done: the flag is passed, the verdict's evidence already resolved,
# and the card carries the PNG.
MODE=newer DD_LOG=$work/args.log SO_CAPTURE=$work/card-newer
export MODE DD_LOG SO_CAPTURE
checks newer shot.png && cp "$shot" "$home/data/newer/shot.png"
: >"$DD_LOG"
run_check_and_post newer
is "newer: recorded verdict" "$(jq -r .verdict "$home/data/newer/merge-card.json")" pass
if grep -q -- '--citation-base' "$DD_LOG"; then ok "newer: --citation-base passed"; else no "newer: --citation-base passed"; fi
is "newer: evidence as the stub cited it" "$(jq -c .check.evidence "$home/data/newer/merge-card.json")" '["'"$home/data/newer/shot.png"'"]'
holds "newer: card captured" "$work/card-newer/card.json"
is "newer: handoff card is outside /tmp" "$(case "$(grep -- '--from ' "$SO_LOG" | tail -n 1)" in /tmp/*) echo tmp ;; *) echo persistent ;; esac)" persistent
holds "newer: media persisted in task folder" "$home/data/newer/merge-card-media/1.png"
is "newer: card kind" "$(jq -r .kind "$work/card-newer/card.json")" evidence
is "newer: card title is the claim" "$(jq -r .title "$work/card-newer/card.json")" "a stopped worker moves to the next live route"
is "newer: card media" "$(jq -c .media "$work/card-newer/card.json")" '["1.png"]'
if [ -f "$work/card-newer/1.png" ] && cmp -s "$work/card-newer/1.png" "$shot"; then ok "newer: card media resolves to the retained PNG"; else no "newer: card media is not the retained PNG"; fi

# post --claim-id: the named claim reaches `done-done check` and the check re-runs over the gate's
# record; without the flag no claim id is passed. A throwaway board keeps the earlier card out of it.
: >"$DD_LOG"
PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board-claim.json" newer "$wt" "$head_c" - >/dev/null 2>&1
if grep -q -- '--claim-id' "$DD_LOG"; then no "claim id: none passed without the flag"; else ok "claim id: none passed without the flag"; fi
: >"$DD_LOG"
PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board-claim.json" --claim-id fd-studio-hide-brief newer "$wt" "$head_c" - >/dev/null 2>&1
if grep -q -- '^check .* --claim-id fd-studio-hide-brief' "$DD_LOG"; then ok "claim id: post passes it to done-done check"; else no "claim id: post passes it to done-done check: $(cat "$DD_LOG")"; fi

# A 0.3.0 done-done on PR 24's shape: the PR body names the PNG bare, the file
# is in the task folder, the flag is never passed, and merge-card hands done-done
# the block with the name resolved there, so the card still carries the PNG.
MODE=older DD_LOG=$work/args.log SO_CAPTURE=$work/card-older GH_BODY=$work/pr-body.md
export MODE DD_LOG SO_CAPTURE GH_BODY
checks older shot.png && mv "$home/data/older/checks.md" "$GH_BODY" && cp "$shot" "$home/data/older/shot.png"
: >"$DD_LOG"
run_check_and_post older https://github.com/example/demo/pull/24
is "older: PR branch is the claim id" "$(grep -c -- '--from - --claim-id fm/older' "$DD_LOG")" 1
is "older: recorded verdict" "$(jq -r .verdict "$home/data/older/merge-card.json")" pass
if grep -q -- '--citation-base' "$DD_LOG"; then no "older: --citation-base was passed to a 0.3.0 done-done"; else ok "older: --citation-base never passed"; fi
is "older: relative citation resolved against the task folder" "$(jq -c .check.evidence "$home/data/older/merge-card.json")" '["'"$home/data/older/shot.png"'"]'
holds "older: card captured" "$work/card-older/card.json"
is "older: card kind" "$(jq -r .kind "$work/card-older/card.json")" evidence
is "older: card title is the claim" "$(jq -r .title "$work/card-older/card.json")" "a stopped worker moves to the next live route"
is "older: card media" "$(jq -c .media "$work/card-older/card.json")" '["1.png"]'
if [ -f "$work/card-older/1.png" ] && cmp -s "$work/card-older/1.png" "$shot"; then ok "older: card media resolves to the retained PNG"; else no "older: card media is not the retained PNG"; fi

# A 0.3.0 done-done with an absolute name, kept as it is, and a bare name the task
# folder lacks, reported missing at its resolved path.
MODE=older DD_LOG=$work/args.log SO_CAPTURE=$work/card-absolute
export MODE DD_LOG SO_CAPTURE
checks absolute "$shot"
run_check_and_post absolute
is "absolute: recorded verdict" "$(jq -r .verdict "$home/data/absolute/merge-card.json")" pass
is "absolute: evidence unchanged" "$(jq -c .check.evidence "$home/data/absolute/merge-card.json")" '["'"$shot"'"]'
if [ -f "$work/card-absolute/1.png" ] && cmp -s "$work/card-absolute/1.png" "$shot"; then ok "absolute: card media resolves to the PNG"; else no "absolute: card media is not the PNG"; fi
# The passed-test receipt: a sealed clean done-done run at the merged head goes on the card; a failed run, or no run record, adds none.
mk_run() { # mk_run <task-id> <run-id> <exit>: a done-done run record at head_c, listing its shot
  mkdir -p "$home/data/$1/.done-done/runs"
  jq -n --arg id "$2" --arg c "$head_c" --argjson e "$3" \
    '{schema:1, run_id:$id, commit:$c, dirty:false, exit:$e, files:[{path:"\($id)/shot.png"}]}' \
    >"$home/data/$1/.done-done/runs/$2.json"
}
mk_run receipt 20261020T000000Z-receipt0001 0
checks receipt shot.png && cp "$shot" "$home/data/receipt/shot.png"
MODE=newer DD_LOG=$work/args.log SO_CAPTURE=$work/card-receipt
export MODE DD_LOG SO_CAPTURE
run_check_and_post receipt
mk_run failedrun 20261020T000000Z-failedrun0001 1
checks failedrun shot.png && cp "$shot" "$home/data/failedrun/shot.png"
SO_CAPTURE=$work/card-failedrun
export SO_CAPTURE
run_check_and_post failedrun
is "receipt: card carries the clean run" "$(jq -c .run "$work/card-receipt/card.json")" "$(jq -cn --arg c "$head_c" '{run_id:"20261020T000000Z-receipt0001", commit:$c, outcome:"a stopped worker moves to the next live route", repro:"see the merge note", proof:"done-done run 20261020T000000Z-receipt0001", evidence:"shot.png"}')"
# Non-screen-free receipt cards retain the existing outcome text.
# A sealed clean run in done-done's own evidence root (a throwaway DONE_DONE_HOME, the real done-done) is accepted
# for its head with no task folder run; one at another head is refused.
if command -v done-done >/dev/null; then
  git init -q "$home" # FM_HOME is a Firstmate checkout; done-done answers from inside a repo
  mkdir -p "$work/ddhome/evidence/app/.done-done/runs"
  jq -n --arg c "$head_c" '{schema:1, run_id:"20261020T000000Z-default0001", commit:$c, dirty:false, exit:0, files:[{path:"x/shot.png"}]}' \
    >"$work/ddhome/evidence/app/.done-done/runs/20261020T000000Z-default0001.json"
  dd_receipt() { DONE_DONE_HOME=$work/ddhome FM_HOME=$home "$here/../merge-card" receipt norun "$1" >/dev/null 2>&1; echo $?; }
  is "default root: run at the head is accepted" "$(dd_receipt "$head_c")" 0
  is "default root: run at another head is refused" "$(dd_receipt otherhead)" 1
else
  ok "default root: skipped, no done-done on PATH"
fi
is "failed run: card carries no receipt" "$(jq -c 'has("run")' "$work/card-failedrun/card.json")" false
is "no run record: card carries no receipt" "$(jq -c 'has("run")' "$work/card-newer/card.json")" false
checks gone gone.png
PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" check gone "$wt" "$head_c" -
is "gone: recorded verdict" "$(jq -r .verdict "$home/data/gone/merge-card.json")" fail
is "gone: missing at its resolved path" "$(jq -r '.check.findings[0].why' "$home/data/gone/merge-card.json")" "$home/data/gone/gone.png: missing (ENOENT)"

# A done-done that lies: the flag is passed and rejected, so the verdict names the
# real reason instead of a bare exit code.
MODE=liar DD_LOG=$work/args.log SO_CAPTURE=$work/card-liar
export MODE DD_LOG SO_CAPTURE
checks liar shot.png && cp "$shot" "$home/data/liar/shot.png"
: >"$DD_LOG"
PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" check liar "$wt" "$head_c" -
is "liar: verdict names the real reason" "$(jq -r .verdict "$home/data/liar/merge-card.json")" "not checked: installed done-done 0.3.1 rejects --citation-base"

# No done-done on PATH at all: the verdict still names why nothing was checked.
checks missing shot.png
PATH="/usr/bin:/bin" FM_HOME=$home "$here/../merge-card" check missing "$wt" "$head_c" -
is "missing: verdict names the real reason" "$(jq -r .verdict "$home/data/missing/merge-card.json")" "not checked: done-done: command not found"

# A gap posts nothing: no card, no sign-off call, one gap line, exit 0.
# run_gap <task-id> <capture-dir>: the stub mode is already exported.
run_gap() {
  local before after out rc
  rm -rf "$2"
  before=$(wc -l < "$SO_LOG")
  out=$(PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" "$1" "$wt" "$head_c" - 2>&1) || rc=$?
  rc=${rc:-0}
  after=$(wc -l < "$SO_LOG")
  is "$1: post exits 0" "$rc" 0
  case $out in
    *"merge-card: no evidence card for merge-$head_c"*": "*"; the lane owner must fix the proof"*)
      ok "$1: gap line names the merge and the lane owner" ;;
    *) no "$1: gap line missing or misshapen: [$out]" ;;
  esac
  if [ -e "$2" ]; then no "$1: no card posted"; else ok "$1: no card posted"; fi
  is "$1: sign-off never called" "$after" "$before"
}

# An inconclusive proof posts no card.
MODE=inconclusive DD_LOG=$work/args.log SO_CAPTURE=$work/card-gap-inconclusive
export MODE DD_LOG SO_CAPTURE
checks gap-inconclusive shot.png && cp "$shot" "$home/data/gap-inconclusive/shot.png"
run_gap gap-inconclusive "$work/card-gap-inconclusive"

# A pass with no proof media posts no card.
MODE=nomedia DD_LOG=$work/args.log SO_CAPTURE=$work/card-gap-nomedia
export MODE DD_LOG SO_CAPTURE
checks gap-nomedia ""
run_gap gap-nomedia "$work/card-gap-nomedia"

# A pass with media but no claim posts no card.
MODE=noclaim DD_LOG=$work/args.log SO_CAPTURE=$work/card-gap-noclaim
export MODE DD_LOG SO_CAPTURE
checks gap-noclaim shot.png && cp "$shot" "$home/data/gap-noclaim/shot.png"
run_gap gap-noclaim "$work/card-gap-noclaim"

# A screen-free merge posts a text-only Evidence card only with a sealed clean receipt.
MODE=newer DD_LOG=$work/args.log SO_CAPTURE=$work/card-internal
export MODE DD_LOG SO_CAPTURE
checks internal shot.png && printf 'screen: none\n' >> "$home/data/internal/checks.md" && cp "$shot" "$home/data/internal/shot.png"
printf '{"schema":1,"answers_only":false,"items":[]}\n' > "$work/board.json"
mk_run internal 20261020T000000Z-internal0001 0
mkdir -p "$home/data/internal/20261020T000000Z-internal0001"
printf 'command proof line one\ncommand proof line two\n' > "$home/data/internal/20261020T000000Z-internal0001/stdout.log"
jq --arg cmd 'printf captured output' '.command=$cmd | .files=[{path:"20261020T000000Z-internal0001/stdout.log"}]' "$home/data/internal/.done-done/runs/20261020T000000Z-internal0001.json" > "$work/run.json" && mv "$work/run.json" "$home/data/internal/.done-done/runs/20261020T000000Z-internal0001.json"
jq '.check.claim="" | .check.evidence=[]' "$home/data/internal/merge-card.json" > "$work/internal-record.json" && mv "$work/internal-record.json" "$home/data/internal/merge-card.json"
: >"$DD_LOG"
so_before=$(wc -l < "$SO_LOG")
out=$(PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" internal "$wt" "$head_c" - 2>&1); rc=$?
is "internal: post exits 0" "$rc" 0
case $out in *"posted text-only merge-$head_c evidence card"*) ok "internal: short text evidence card posted" ;; *) no "internal: text card confirmation missing: [$out]" ;; esac
is "internal: sign-off called once" "$(wc -l < "$SO_LOG")" "$((so_before + 1))"
if grep -q '^check ' "$DD_LOG"; then no "internal: done-done check never run"; else ok "internal: done-done check never run"; fi
holds "internal: card captured" "$work/card-internal/card.json"
is "internal: card has no media" "$(jq -c 'has("media")' "$work/card-internal/card.json")" false
is "internal: card carries receipt" "$(jq -r '.run.run_id' "$work/card-internal/card.json")" 20261020T000000Z-internal0001
is "internal: missing claim uses Checks outcome" "$(jq -r '.run.outcome' "$work/card-internal/card.json")" "a stopped worker moves to the next live route"
is "internal: missing citation uses Checks evidence" "$(jq -r '.run.evidence' "$work/card-internal/card.json")" shot.png
is "internal: output excerpt is shown" "$(jq -r .about "$work/card-internal/card.json" | grep -c 'command proof line')" 2
is "internal: command and exit code are shown" "$(jq -r .about "$work/card-internal/card.json" | grep -c 'exit code 0')" 1
# A capture beyond the text field cap is called out rather than silently clipped.
jq '.items=[]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
checks longoutput shot.png && printf 'screen: none\n' >> "$home/data/longoutput/checks.md" && cp "$shot" "$home/data/longoutput/shot.png"
mk_run longoutput 20261020T000000Z-longoutput0001 0
mkdir -p "$home/data/longoutput/20261020T000000Z-longoutput0001"
python3 -c 'print("x" * 700)' > "$home/data/longoutput/20261020T000000Z-longoutput0001/stdout.log"
jq '.files=[{path:"20261020T000000Z-longoutput0001/stdout.log"}]' "$home/data/longoutput/.done-done/runs/20261020T000000Z-longoutput0001.json" > "$work/run.json" && mv "$work/run.json" "$home/data/longoutput/.done-done/runs/20261020T000000Z-longoutput0001.json"
SO_CAPTURE=$work/card-longoutput
export SO_CAPTURE
PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" longoutput "$wt" "$head_c" - >/dev/null
holds "long output: card captured" "$work/card-longoutput/card.json"
is "long output: visible truncation note" "$(jq -r .about "$work/card-longoutput/card.json" | grep -c 'output truncated, full run 20261020T000000Z-longoutput0001')" 1
is "long output: field stays within contract" "$(jq -e '.about | length <= 500' "$work/card-longoutput/card.json")" true
jq '.items=[]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
checks nocapture shot.png && printf 'screen: none\n' >> "$home/data/nocapture/checks.md" && cp "$shot" "$home/data/nocapture/shot.png"
mk_run nocapture 20261020T000000Z-nocapture0001 0
SO_CAPTURE=$work/card-nocapture
export SO_CAPTURE
PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" nocapture "$wt" "$head_c" - >/dev/null
is "no capture: receipt-only text remains" "$(jq -r .about "$work/card-nocapture/card.json")" 'No user-visible screen; sealed done-done receipt attached.'
so_before=$(wc -l < "$SO_LOG")
PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" internal "$wt" "$head_c" - >/dev/null
is "internal: repeat post is deduped" "$(wc -l < "$SO_LOG")" "$so_before"

# A dismissed card stays archived and the new card goes up beside it; an identical live card remains deduped.
key=merge-$head_c
jq -n --arg k "$key" '{schema:1,answers_only:false,items:[{key:$k,type:"evidence",kind:"evidence",filer:"firstmate-merge",dismissed:true,title:"dismissed placeholder"}]}' > "$work/board.json"
MODE=newer DD_LOG=$work/args.log SO_CAPTURE=$work/card-dismissed
export MODE DD_LOG SO_CAPTURE
checks dismissed shot.png && cp "$shot" "$home/data/dismissed/shot.png"
mk_run dismissed 20261020T000000Z-dismissed0001 0
PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" dismissed "$wt" "$head_c" - >/dev/null
is "dismissed: card posted beside the archived one" "$(jq -r '.items[1].title' "$work/board.json")" "a stopped worker moves to the next live route"
is "dismissed: archived card kept" "$(jq -r '.items[0] | "\(.key) \(.dismissed)"' "$work/board.json")" "$key true"
so_before=$(wc -l < "$SO_LOG")
PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" dismissed "$wt" "$head_c" - >/dev/null
is "live same-key card is deduped" "$(wc -l < "$SO_LOG")" "$so_before"

# One card per PR: a new head replaces the old card (newest proof kept), another PR gets its own, repeats dedupe.
pr=https://github.com/o/r/pull/12
head_c=firsthead0000000000000000000000000000000000
checks follows shot.png && cp "$shot" "$home/data/follows/shot.png"
mk_run follows 20261020T000000Z-follows0001 0
printf '{"schema":1,"answers_only":false,"items":[]}\n' > "$work/board.json"
MODE=newer DD_LOG=$work/args.log SO_CAPTURE=$work/card-follows
export MODE DD_LOG SO_CAPTURE
PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" follows "$wt" "$head_c" "$pr" >/dev/null
# A card an older merge-card filed under a head-suffixed key goes with the replacement.
jq '.items += [(.items[0] | .key += "-oldhead00000" | .run.commit = "oldhead")]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
head_c=secondhead0000000000000000000000000000000000
mk_run follows 20261020T000000Z-follows0002 0
PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" follows "$wt" "$head_c" "$pr" >/dev/null
# The real sign-off-axi refuses a --from --replace feed of evidence and a changed message under a held key (see the stub).
is "new head: exactly one live card for the PR" "$(jq -r '[.items[] | select(.dismissed != true) | .run.run_id] | join(",")' "$work/board.json")" 20261020T000000Z-follows0002
is "new head: old cards archived, history kept" "$(jq -r '[.items[] | select(.dismissed == true) | .run.run_id] | length' "$work/board.json")" 2
is "new head: first card keeps the PR key" "$(jq -r '.items[0].key' "$work/board.json")" merge-o-r-pull-12
if grep -q -- '--replace' "$SO_LOG"; then no "new head: posted through --replace"; else ok "new head: posted one at a time"; fi
so_before=$(wc -l < "$SO_LOG")
PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" follows "$wt" "$head_c" "$pr" >/dev/null
is "new head: repeat post dedupes" "$(wc -l < "$SO_LOG")" "$so_before"
PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" follows "$wt" "$head_c" https://github.com/o/r/pull/13 >/dev/null
is "two PRs: two live cards" "$(jq -r '[.items[] | select(.dismissed != true) | .key | sub("-[0-9a-f]{12}$"; "")] | sort | join(",")' "$work/board.json")" "merge-o-r-pull-12,merge-o-r-pull-13"

# A screen-free PR's card is titled with its repo and PR number.
GH_BODY=$work/titled-body.md
export GH_BODY
checks titled shot.png && printf 'screen: none\n' >> "$home/data/titled/checks.md" && cp "$shot" "$home/data/titled/shot.png" && cp "$home/data/titled/checks.md" "$GH_BODY"
mk_run titled 20261020T000000Z-titled0001 0
jq '.items=[]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
SO_CAPTURE=$work/card-titled
export SO_CAPTURE
PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" titled "$wt" "$head_c" https://github.com/o/muxr/pull/1012 >/dev/null
is "internal title names repo and PR" "$(jq -r .title "$work/card-titled/card.json")" "muxr #1012: internal change passed its checks"
GH_BODY=$work/pr-body.md

# A merge hook passes head `-` for a PR: a screen-free PR still finds its sealed run at the PR head, from gh.
GH_BODY=$work/headdash-body.md
export GH_BODY
checks headdash shot.png && printf 'screen: none\n' >> "$home/data/headdash/checks.md" && cp "$shot" "$home/data/headdash/shot.png" && cp "$home/data/headdash/checks.md" "$GH_BODY"
mk_run headdash 20261020T000000Z-headdash0001 0
jq '.items=[]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
SO_CAPTURE=$work/card-headdash
export SO_CAPTURE
out=$(GH_HEAD=$head_c PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" headdash "$wt" - https://github.com/o/r/pull/77 2>&1); rc=$?
is "head dash: post exits 0" "$rc" 0
is "head dash: card carries the PR head's run" "$(jq -r .run.run_id "$work/card-headdash/card.json" 2>/dev/null)" 20261020T000000Z-headdash0001
out=$(GH_HEAD="" PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" headdash "$wt" - https://github.com/o/r/pull/78 2>&1); rc=$?
is "head dash: an unresolvable head fails" "$rc" 1
case $out in *"cannot resolve the head of https://github.com/o/r/pull/78"*) ok "head dash: error names the PR" ;; *) no "head dash: error missing: [$out]" ;; esac
GH_BODY=$work/pr-body.md

# The gate refuses a PR merge with no checks-lint PASS row for its head.
MODE=newer DD_LOG=$work/args.log SO_CAPTURE=$work/card-lint
export MODE DD_LOG SO_CAPTURE
checks lint shot.png && cp "$shot" "$home/data/lint/shot.png"
gate_rc() { PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" gate lint "$wt" "$head_c" https://github.com/o/r/pull/1 >/dev/null 2>&1; echo $?; }
rm -f "$home/data/checks-gate.log"
is "gate: no PASS row is refused" "$(gate_rc)" 1
printf 't\thttps://github.com/o/r/pull/1\totherhead\tpass\t1 evidence files\n' > "$home/data/checks-gate.log"
is "gate: PASS row for another head is refused" "$(gate_rc)" 1
printf 't\thttps://github.com/o/r/pull/1\t%s\tfail\tx\n' "$head_c" >> "$home/data/checks-gate.log"
is "gate: FAIL row for the head is refused" "$(gate_rc)" 1
printf 't\thttps://github.com/o/r/pull/1\t%s\tpass\t1 evidence files\n' "$head_c" >> "$home/data/checks-gate.log"
is "gate: PASS row for the head is allowed" "$(gate_rc)" 0
PATH="$work/bin:$PATH" FM_HOME=$home "$here/../merge-card" post --board "$work/board.json" lint "$wt" "$head_c" https://github.com/o/r/pull/1 >/dev/null 2>&1
is "post: the card logged its evidence folder on the head's row" "$(grep -c "$head_c	card	evidence folder $home/data/lint" "$home/data/checks-gate.log")" 1

# No run anywhere posted, or even asked for, a report card.
if grep -q -- '--kind report' "$SO_LOG"; then
  no "never any report kind: sign-off saw --kind report"
else
  ok "never any report kind on the wire"
fi
for c in "$work"/card-*/card.json; do
  [ -f "$c" ] || continue
  if [ "$(jq -r .kind "$c")" = report ]; then no "never any report kind: $c"; else ok "never any report kind: $(basename "$(dirname "$c")")"; fi
  if jq -e 'has("filed")' "$c" >/dev/null; then no "no filed field: $c"; else ok "no filed field: $(basename "$(dirname "$c")")"; fi
done

if [ "$fails" -eq 0 ]; then
  echo "merge-card e2e: all assertions held"
else
  echo "merge-card e2e: $fails assertion(s) failed"
  exit 1
fi
