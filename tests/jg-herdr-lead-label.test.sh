#!/usr/bin/env bash
# tests/jg-herdr-lead-label.test.sh - a squad_lead home's herdr workspace is
# written as "lead-<id>", and a live workspace still labeled "2ndmate-<id>"
# is found as that home's own.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"

home=$(mktemp -d); trap 'rm -rf -- "$home"' EXIT
JG_HOME=$home
printf 'alpha\n' > "$home/$JG_BACKEND_HERDR_SQUAD_LEAD_MARKER"

assert_equals "lead-alpha" "$(jg_backend_herdr_workspace_label)" "new label is written"
assert_equals "2ndmate-alpha" "$(jg_backend_herdr_workspace_legacy_label)" "legacy label is derived"

jg_backend_herdr_cli() {
  printf '%s' '{"result":{"workspaces":[{"workspace_id":"w1","label":"juggernaut"},{"workspace_id":"w2","label":"2ndmate-alpha"},{"workspace_id":"w3","label":"lead-alpha"},{"workspace_id":"w4","label":"lead-beta"}]}}'
}
assert_equals $'w2\nw3' "$(jg_backend_herdr_workspace_find_all s)" "old and new labels both match"

assert_equals "task-x" "$(jg_backend_herdr_projection_concise_task_label lead-alpha/task-x)" "new owner prefix stripped"
assert_equals "task-x" "$(jg_backend_herdr_projection_concise_task_label 2ndmate-alpha/task-x)" "old owner prefix stripped"

rm -f "$home/$JG_BACKEND_HERDR_SQUAD_LEAD_MARKER"
assert_equals "juggernaut" "$(jg_backend_herdr_workspace_label)" "primary label unchanged"
assert_equals "" "$(jg_backend_herdr_workspace_legacy_label)" "primary has no legacy label"
pass "lead-<id> written, 2ndmate-<id> still read"
