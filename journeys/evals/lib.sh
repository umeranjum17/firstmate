#!/usr/bin/env bash
# Shared glue for the behaviour-eval journeys: the repo root, the evidence folder done-done
# hands each run, a scratch home that is never the captain's, and the step record done-done wants.
set -u
# shellcheck disable=SC2034  # REPO and failed are read by the journeys that source this
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
failed=0

# scratch_home: a throwaway HOME for the run; the caller removes it with rm_scratch.
# It lives on disk, not in /tmp: a real install is hundreds of megabytes and /tmp is memory.
scratch_home() {
  mkdir -p "${JG_EVAL_SCRATCH:=$HOME/.cache/juggernaut-evals}"
  SCRATCH=$(mktemp -d "$JG_EVAL_SCRATCH/run.XXXXXX")
  export HOME=$SCRATCH TMPDIR=$SCRATCH/tmp XDG_DATA_HOME=$SCRATCH/.local/share XDG_CONFIG_HOME=$SCRATCH/.config XDG_CACHE_HOME=$SCRATCH/.cache
  mkdir -p "$TMPDIR"
}
rm_scratch() { rm -rf -- "${SCRATCH:?}"; }

# check <label> <command...>: run it, keep its output as evidence, count a failure.
check() {
  local label=$1; shift
  if "$@" >"$OUT/${label// /-}.log" 2>&1; then echo "pass: $label"; else echo "FAIL: $label"; failed=1; fi
}

# steps <app version> <start> <result> <step...>: write steps.json; exit 1 when a check failed.
steps() {
  python3 - "$OUT/steps.json" "$@" <<'PY'
import json, sys
out, version, start, result, *steps = sys.argv[1:]
json.dump({"target": {"version": version}, "start": start, "steps": steps, "result": result}, open(out, "w"), indent=2)
PY
  exit "$failed"
}
