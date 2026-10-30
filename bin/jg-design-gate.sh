#!/usr/bin/env bash
# The design gate: every rule is a shell check on recorded files; nothing here calls a model.
# Usage: jg-design-gate.sh size <worktree> <base-branch> <head>
#        jg-design-gate.sh handroll <task-id> [--task-home <home>]
#
# Size rule: a change is a small tweak, free to be hand-rolled, when its UI files
# (.html .htm .css .scss .sass .less .svg .jsx .tsx .vue .svelte .astro) change at most
# 40 lines, added plus deleted, against the merge base, and it adds no new UI file.
# Past that it is design work, as is every task briefed `--design-call yes`.
# `size` prints `design|tweak <ui-lines> <new-ui-files>` and exits 2 when it cannot measure.
#
# bin/jg-merge-gate-lib.sh's jg_dod_design_gate runs the rule on both merge paths:
# design work merges only with a PASS completion receipt for the head that carries
# `first-draft receipt: <ref>`, and a small tweak that touches any UI line merges only
# with a hand-roll approval. A change with no UI line needs neither.
# `handroll` writes that approval: it measures the task's work copy HEAD, refuses past
# the size rule, and writes <task home state>/design-approvals/<task-id>.handroll.json.
# Only the task's own home (its lead) or Main writes it, and it refuses a caller with
# JG_TASK_ID set: the worker that asks never approves its own work. The gate measures
# the size again at merge, so an approval never covers a change that grew past the rule.
# --task-home names the home that owns the task when Main approves a lead's task.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jg_dod_meta_value() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }
# shellcheck source=bin/jg-merge-gate-lib.sh
. "$SCRIPT_DIR/jg-merge-gate-lib.sh"

die() { echo "jg-design-gate: $*" >&2; exit 1; }
cmd=${1:-}; [ "$#" -gt 0 ] && shift
case $cmd in
  size)
    [ "$#" -eq 3 ] || die "usage: size <worktree> <base-branch> <head>"
    jg_design_size "$@"; exit $?
    ;;
  handroll) ;;
  *) die "usage: size|handroll (see the header)" ;;
esac
[ -n "${JG_HOME:-}" ] || die "JG_HOME must name this home"
ID=${1:-}; [ "$#" -gt 0 ] && shift
case $ID in ''|-*|*/*) die "usage: handroll <task-id> [--task-home <home>]" ;; esac
TASK_HOME=$JG_HOME
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] && [ "$1" = --task-home ] || die "unknown or incomplete flag $1"
  TASK_HOME=$2; shift 2
done
[ -z "${JG_TASK_ID:-}" ] || die "handroll refused: the worker that asks (task $JG_TASK_ID) never approves; its lead or Main does"
MAIN=$(jg_design_main_home "$JG_HOME") || die "cannot find the main home from $JG_HOME"
[ "$JG_HOME" = "$TASK_HOME" ] || [ "$MAIN" = "$JG_HOME" ] || die "handroll refused: only $TASK_HOME's lead or Main approves a hand-roll"
if [ "$TASK_HOME" = "$JG_HOME" ]; then TSTATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}; else TSTATE=$TASK_HOME/state; fi
wt=$(jg_dod_meta_value "$TSTATE/$ID.meta" worktree)
head=$(git -C "${wt:-/nonexistent}" rev-parse HEAD 2>/dev/null) || die "cannot read the work copy of $ID from $TSTATE/$ID.meta"
size=$(jg_design_size "$wt" "$(jg_dod_meta_value "$TSTATE/$ID.meta" base_branch)" "$head") || die "cannot measure the UI change of $ID"
case $size in design*) die "handroll refused: $ID changes ${size#design } (UI lines, new UI files), past the small-tweak size; it needs first-draft" ;; esac
mkdir -p "$TSTATE/design-approvals" || die "cannot write $TSTATE/design-approvals"
jq -n --arg id "$ID" --arg h "$head" --arg sz "$size" --arg by "$JG_HOME" --argjson now "$(date +%s)" \
  '{schema: 1, task: $id, head: $h, size: $sz, by: $by, at: $now}' > "$TSTATE/design-approvals/$ID.handroll.json" || die "cannot write the hand-roll approval"
echo "hand-roll approved: $ID ($size)"
