#!/usr/bin/env bash
# Completion-receipt acceptance and brief/meta helpers, sourced by the fork's
# bin/fm-dod-lib.sh, fm-spawn.sh and fm-promote.sh through an optional add-on
# source. Needs the fork libs the caller already loaded (fm_dod_meta_value,
# fm_pr_head_valid). Absent add-on = kun behavior (callers guard with declare -F).
# bin/fm-run-receipt.sh in this add-on is the publisher.

# Completion receipts are task-owned state/<id>.run-receipt.json records.
# schema=1 binds task, mode, spawn_gen and exact candidate head to PASS or FAIL,
# with a nonempty evidence body (commands, outcomes and relevant limitations).
# bin/fm-run-receipt.sh publishes them atomically; evidence is embedded so the
# proof survives deletion of temporary logs and the disposable worktree.
# receipt_required=1 is set only for briefs carrying Completion receipt: required.
# Older records need no absent receipt, but ANY present receipt must validate:
# explicit FAIL, malformed, stale incarnation/head and empty proof all refuse.
# This is evidence supplied by the worker, not a replacement for forge checks,
# no-mistakes validation or merge authority. Both landing entrypoints consume
# the same gate against the exact head they will submit to the merge command.
fm_dod_receipt_accept() {  # <state> <id> <meta> <candidate-head>
  local state=$1 id=$2 meta=$3 head=$4 receipt required mode gen count
  [ -n "$state" ] && [ -n "$id" ] && [ -f "$meta" ] || return 0
  receipt="$state/$id.run-receipt.json"
  required=$(fm_dod_meta_value "$meta" receipt_required)
  count=$(awk -F= '$1 == "receipt_required" { n++ } END { print n+0 }' "$meta") || return 1
  if [ "$count" -gt 1 ] || { [ "$count" -eq 1 ] && [ "$required" != 1 ]; }; then
    echo "completion receipt requirement malformed for $id"
    return 1
  fi
  if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
    [ "$required" != 1 ] && return 0
    echo "completion receipt missing for $id"
    return 1
  fi
  mode=$(fm_dod_meta_value "$meta" mode)
  gen=$(fm_dod_meta_value "$meta" spawn_gen)
  if fm_pr_head_valid "$head" && [ -f "$receipt" ] && [ ! -L "$receipt" ] && command -v jq >/dev/null 2>&1 \
    && jq -se --arg task "$id" --arg mode "$mode" --arg gen "$gen" --arg head "$head" '
      length == 1 and (.[0] | .schema == 1 and .task == $task and .mode == $mode and
      .spawn_gen == $gen and .head == $head and .verdict == "PASS" and
      (.evidence | type == "string" and test("[^[:space:]]")) and
      (.at | type == "number" and . > 0))
    ' "$receipt" >/dev/null 2>&1; then
    return 0
  fi
  echo "completion receipt refused for $id: FAIL, mismatched candidate/incarnation, malformed or absent evidence"
  return 1
}


# The brief's receipt contract for ship modes: <task-id>.
fm_receipts_brief() {  # <id>
  local receipt_home_q receipt_tool_q
  receipt_home_q=$(printf '%q' "${FM_HOME:-${FM_ROOT:-}}")
  receipt_tool_q=$(printf '%q' "${FM_ADDONS_DIR:-${FM_HOME:-${FM_ROOT:-}}/projects/firstmate-addons}/receipts/bin/fm-run-receipt.sh")
  cat <<EOF
Completion receipt: required
Before the final ready report (after validation in no-mistakes mode), write a nonempty evidence file containing commands run, results and limitations, then run \`FM_HOME=$receipt_home_q $receipt_tool_q $1 PASS <evidence-file>\` from the clean candidate checkout.
Use FAIL when verification failed; never label failed or unperformed checks PASS.
The evidence file may be a task-owned temporary file outside your worktree; that write and the helper's completion-receipt write into its supervising state directory are authorized.
Regenerate the receipt after any candidate change, including validation fixes or a rebase.
EOF
}

# Meta line for a spawn: prints receipt_required=1 for a ship task whose brief
# asks for receipts, or whose relaunch meta already carried it.
fm_receipts_inherit() {  # <kind> <brief> [<relaunch-meta>]
  [ "$1" = ship ] || return 0
  if grep -qx 'Completion receipt: required' "$2" \
    || { [ -n "${3:-}" ] && [ -f "$3" ] && grep -qx 'receipt_required=1' "$3"; }; then
    echo 'receipt_required=1'
  fi
}

# Promotion: replace any stale requirement in the temp meta with the live one.
fm_receipts_promote() {  # <tmp-meta>
  local tmp=$1
  grep -v '^receipt_required=' "$tmp" > "$tmp.rr" || true
  echo 'receipt_required=1' >> "$tmp.rr"
  mv "$tmp.rr" "$tmp"
}
