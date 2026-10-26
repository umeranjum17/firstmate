#!/usr/bin/env bash
# fm-model-gate-lib.sh - model-gate add-on: fm_model_gate_hook, the entry point a harness launch calls before it starts
# anything. Sourced from $FM_ADDONS_DIR/model-gate/bin/; a home without the add-on keeps only no-op hook lines.
# A provider the allow-list does not name is not limited, so this only ever refuses a model the list constrains.
#
# Hook point, in Firstmate core rather than this repo - bin/fm-spawn.sh, beside the account-pool hook it already has:
#   source (after the account-pool source block, ~line 724):
#     _fm_mg=${FM_ADDONS_DIR:-${FM_HOME:-$SCRIPT_DIR/..}/projects/firstmate-addons}/model-gate/bin/fm-model-gate-lib.sh
#     if [ -r "$_fm_mg" ]; then . "$_fm_mg" || { printf 'error: the model-gate add-on at %s failed to load\n' "$_fm_mg" >&2; exit 1; }
#     else fm_model_gate_hook() { :; }; fi
#   call (right after `fm_account_hook spawn-validate || exit 1`, ~line 943, where $MODEL is parsed):
#     fm_model_gate_hook spawn-validate || exit 1

# fm_model_gate_check <provider> <model>: 0 allowed, or no gate reachable; 2 refused with the gate's one line on stderr.
fm_model_gate_check() {
  local gate=${FM_MODEL_GATE:-} rc=0
  [ -n "$gate" ] || gate=$(command -v fm-model-gate 2>/dev/null) || return 0
  "$gate" check "$1" "$2" >&2 || rc=$?
  case $rc in
  0) return 0 ;;
  1) return 2 ;;
  esac
  printf 'model-gate: the gate at %s could not check %s/%s (exit %s); launch not blocked\n' "$gate" "$1" "$2" "$rc" >&2
  return 0
}

fm_model_gate_hook() { # <event> [args]
  case ${1:-} in spawn-validate) ;; *) return 0 ;; esac
  local model=${MODEL:-}
  case $model in */*) ;; *) return 0 ;; esac # no provider segment: nothing this gate can read
  fm_model_gate_check "${model%%/*}" "$model"
}
