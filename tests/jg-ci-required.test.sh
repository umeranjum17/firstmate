#!/usr/bin/env bash
# tests/jg-ci-required.test.sh - the CI required verdict for the macOS lane.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
verdict() {  # <macos result> <want exit>
  local needs rc
  needs=$(printf '{"invariants":{"result":"success"},"lint":{"result":"success"},"tests-portable-parallel-1":{"result":"success"},"tests-portable-parallel-2":{"result":"success"},"tests-portable-serial":{"result":"success"},"tests-herdr":{"result":"success"},"macos-stock-bash":{"result":"%s"}}' "$1")
  JG_CI_NEEDS=$needs JG_CI_BEHAVIOR=true "$ROOT/bin/jg-ci-required.sh" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "$2" ]; then echo "ok - macos $1 -> $rc"; else echo "not ok - macos $1 -> $rc, want $2"; fail=1; fi
}
verdict success 0
verdict cancelled 0
verdict failure 1
verdict skipped 1
exit "$fail"
