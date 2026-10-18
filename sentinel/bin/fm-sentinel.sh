#!/usr/bin/env bash
# fm-sentinel.sh - add-on entry point for the Firstmate restart sentinel.
# The sentinel is not copied here: the Firstmate checkout owns bin/fm-sentinel.sh,
# and this wrapper runs that script with the same arguments, so Firstmate
# updates apply with no merge and no copy to drift.
# Usage: FM_HOME=<home> [FM_CODE_ROOT=<checkout>] fm-sentinel.sh tick|loop|reconcile|unit
# FM_CODE_ROOT defaults to FM_HOME, the checkout a home runs from.
set -u

CODE_ROOT=${FM_CODE_ROOT:-${FM_HOME:-}}
SENTINEL="$CODE_ROOT/bin/fm-sentinel.sh"
if [ -z "$CODE_ROOT" ] || [ ! -x "$SENTINEL" ]; then
  echo "fm-sentinel: no Firstmate checkout with bin/fm-sentinel.sh; set FM_CODE_ROOT" >&2
  exit 2
fi
exec "$SENTINEL" "$@"
