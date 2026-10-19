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
work=$(mktemp -d) || exit 1
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
jq -n --rawfile body "$GH_BODY" '{body: $body, headRefName: "fm/older"}'
STUB

# The stub sign-off-axi: capture the card and the media copied beside it, and
# log every invocation so the test can prove a gap never reached a post call.
cat > "$work/bin/sign-off-axi" <<'STUB' || exit 1
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SO_LOG"
[ "${1:-}" = post ] || exit 0
from=''
while [ $# -gt 0 ]; do
  if [ "$1" = --from ]; then from=$2; shift 2; else shift; fi
done
[ -n "$from" ] || exit 0
rm -rf "$SO_CAPTURE"
cp -r "$(dirname "$from")" "$SO_CAPTURE"
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
is "newer: card kind" "$(jq -r .kind "$work/card-newer/card.json")" evidence
is "newer: card title is the claim" "$(jq -r .title "$work/card-newer/card.json")" "a stopped worker moves to the next live route"
is "newer: card media" "$(jq -c .media "$work/card-newer/card.json")" '["1.png"]'
if [ -f "$work/card-newer/1.png" ] && cmp -s "$work/card-newer/1.png" "$shot"; then ok "newer: card media resolves to the retained PNG"; else no "newer: card media is not the retained PNG"; fi

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
