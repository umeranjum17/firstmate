#!/usr/bin/env bash
# fm-ci-required.sh - the single merge-gate verdict for ci.yml's `CI required`.
#
# FM_CI_NEEDS is GitHub's toJSON(needs), FM_CI_BEHAVIOR the invariants job's
# scope verdict, and FM_CI_SKIP_MACOS the fork's macOS opt-out. A behavior
# change needs every lane passed, with macOS skipped only under that opt-out; a
# documentation change needs the lanes deliberately skipped. Anything else
# refuses, so a path filter can never become a silent skip.
#
#   FM_CI_NEEDS='{"invariants":{"result":"success"},...}' FM_CI_BEHAVIOR=true \
#     bin/fm-ci-required.sh
set -eu

FM_CI_REQUIRED_LANES='lint tests-portable-parallel-1 tests-portable-parallel-2 tests-portable-serial tests-herdr'

fm_ci_required_die() { printf 'error: %s\n' "$*" >&2; exit 1; }

fm_ci_required_result() {
  printf '%s' "${FM_CI_NEEDS:-}" | jq -er --arg job "$1" '.[$job].result // "missing"'
}

fm_ci_required_main() {
  local want lane result bad=''
  case ${1:-} in
    -h|--help) sed -n '2,8{s/^# \{0,1\}//;p;}' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-ci-required.sh"; return 0 ;;
    '') ;;
    *) fm_ci_required_die "unknown argument $1" ;;
  esac
  command -v jq >/dev/null 2>&1 || fm_ci_required_die "jq is required to read the needed-job results"
  printf '%s' "${FM_CI_NEEDS:-}" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || fm_ci_required_die "the needed-job results are not a JSON object"
  case ${FM_CI_BEHAVIOR:-} in
    true) want=success ;;
    false) want=skipped ;;
    *) fm_ci_required_die "the scope verdict is '${FM_CI_BEHAVIOR:-}', so CI cannot say which lanes this change needed" ;;
  esac
  # The scope verdict is always needed: without it no lane verdict counts.
  [ "$(fm_ci_required_result invariants)" = success ] || bad="$bad invariants=not-passed"
  # shellcheck disable=SC2086  # the lane list is a deliberate word split
  for lane in $FM_CI_REQUIRED_LANES macos-stock-bash; do
    result=$(fm_ci_required_result "$lane") || result=unreadable
    if [ "$want" = skipped ]; then
      case $result in failure|cancelled) bad="$bad $lane=$result" ;; esac
    elif [ "$lane" = macos-stock-bash ] && [ "$result" = skipped ] && [ "${FM_CI_SKIP_MACOS:-}" = 1 ]; then
      :
    elif [ "$result" != success ]; then
      bad="$bad $lane=$result"
    fi
  done
  [ -z "$bad" ] || fm_ci_required_die "this change is not verifiable:$bad"
  printf 'verified: every job this %s change needed ran and passed\n' \
    "$([ "$want" = success ] && printf behavior || printf documentation)"
}

fm_ci_required_main "$@"
