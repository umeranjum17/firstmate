#!/usr/bin/env bash
# tests/jg-project-mode.test.sh - the delivery-route default (bin/jg-project-mode.sh):
# a project nobody registered ships as a direct pull request, while a registered
# line keeps the posture its owner wrote, a typo and a legacy bracket-less line
# included.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-project-mode)
MODE="$ROOT/bin/jg-project-mode.sh"

mode_of() {  # <home> <project> -> the "<mode> <yolo>" line
  JG_HOME="$1" JG_DATA_OVERRIDE="$1/data" "$MODE" "$2" 2>/dev/null
}

test_an_unregistered_project_defaults_to_a_direct_pr() {
  local home=$TMP_ROOT/unregistered
  mkdir -p "$home/data"
  assert_equals "direct-PR off" "$(mode_of "$home" anything)" "a home with no registry must default to a direct PR"
  printf -- '- known [local-only] - a registered project (added 2026-10-30)\n' > "$home/data/projects.md"
  assert_equals "direct-PR off" "$(mode_of "$home" stranger)" "a project missing from the registry must default to a direct PR"
  pass "an unregistered project defaults to a direct PR"
}

test_a_registered_posture_is_never_lowered() {
  local home=$TMP_ROOT/registered
  mkdir -p "$home/data"
  {
    printf -- '- strict [no-mistakes] - registered for the pipeline (added 2026-10-30)\n'
    printf -- '- legacy - registered before modes existed (added 2026-10-30)\n'
    printf -- '- typo [no-mistake] - a misspelled mode (added 2026-10-30)\n'
  } > "$home/data/projects.md"
  assert_equals "no-mistakes off" "$(mode_of "$home" strict)" "a registered no-mistakes project changed route"
  assert_equals "no-mistakes off" "$(mode_of "$home" legacy)" "a legacy bracket-less line lost its gate"
  assert_equals "no-mistakes off" "$(mode_of "$home" typo)" "a misspelled mode silently dropped the gate"
  pass "a registered posture is never lowered by the default"
}

test_an_unregistered_project_defaults_to_a_direct_pr
test_a_registered_posture_is_never_lowered
