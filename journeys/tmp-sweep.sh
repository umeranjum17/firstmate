#!/usr/bin/env bash
# done-done journey: drive the real bin/jg-tmp-sweep.sh against a disposable folder standing in for
# /tmp (dry run, real run, inode check) and the sentinel tick that calls it, and write the transcript
# into the evidence folder.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-tmp-sweep}.log
T=$(mktemp -d)
R=$T/tmp
mkdir -p "$R/tmp.stale/sub" "$R/tmp.fresh" "$R/claude-1000/old-session" "$R/plan-other"
touch "$R/tmp.stale/sub/f" "$R/claude-accounts.stale" "$R/claude-1000/old-session/f" "$R/plan-other/f"
touch -d '5 days ago' "$R/tmp.stale/sub/f" "$R/tmp.stale/sub" "$R/tmp.stale" "$R/claude-accounts.stale" \
  "$R/claude-1000/old-session/f" "$R/claude-1000/old-session" "$R/plan-other/f" "$R/plan-other"
{
  echo "== inode check"; "$REPO/bin/jg-tmp-sweep.sh" check --root "$R" --warn-pct 0; echo "exit $? (1 = at or over the threshold)"
  echo "== dry run"; "$REPO/bin/jg-tmp-sweep.sh" sweep --root "$R"
  echo "== listing after dry run"; (cd "$R" && find . | sort)
  echo "== real run"; "$REPO/bin/jg-tmp-sweep.sh" sweep --apply --root "$R"
  echo "== listing after real run"; (cd "$R" && find . | sort)
  echo "== behavior test"; bash "$REPO/tests/jg-tmp-sweep.test.sh" 2>&1
} >"$LOG" 2>&1
st=0
[ ! -e "$R/tmp.stale" ] && [ ! -e "$R/claude-accounts.stale" ] && [ ! -e "$R/claude-1000/old-session" ] || st=1
[ -d "$R/tmp.fresh" ] && [ -d "$R/claude-1000" ] && [ -e "$R/plan-other/f" ] || st=1
grep -q '^not ok' "$LOG" && st=1
[ "$(grep -c '^ok - ' "$LOG")" -ge 4 ] || st=1
cat "$LOG"
find "$T" -type d -exec chmod u+rwx {} + 2>/dev/null
rm -rf -- "$T"
exit "$st"
