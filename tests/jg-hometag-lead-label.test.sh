#!/usr/bin/env bash
# tests/jg-hometag-lead-label.test.sh - a squad_lead home's cmux and zellij
# title tag is written as "lead-<id>-<hash>", and a live title still tagged
# "2ndmate-<id>-<hash>" is found as that home's own.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

home=$(mktemp -d); trap 'rm -rf -- "$home"' EXIT
export JG_HOME=$home
printf 'alpha\n' > "$home/.jg-squad-lead-home"

# shellcheck source=bin/backends/cmux.sh
. "$ROOT/bin/backends/cmux.sh"
# shellcheck source=bin/backends/zellij.sh
. "$ROOT/bin/backends/zellij.sh"
JG_HOME=$home

new=$(jg_backend_hometag)
old=$(jg_backend_hometag legacy)
case "$new" in lead-alpha-*) ;; *) fail "new tag is lead-alpha-<hash>, got $new" ;; esac
assert_equals "2ndmate-${new#lead-}" "$old" "legacy tag differs only in the prefix"

jg_backend_cmux_cli() {
  printf '{"workspaces":[{"id":"w1","title":"jg-%s-t1"},{"id":"w2","title":"jg-%s-t2"},{"id":"w3","title":"jg-other-t3"}]}' "$new" "$old"
}
jg_backend_cmux_surface_id_for_workspace() { printf 's-%s' "$1"; }
assert_equals $'w1:s-w1\tjg-t1\nw2:s-w2\tjg-t2' "$(jg_backend_cmux_list_live)" "cmux lists new and old titles"

jg_backend_zellij_session_exists() { return 0; }
jg_backend_zellij_pane_for_tab() { printf 'p%s' "$2"; }
jg_backend_zellij_cli() {
  printf '[{"tab_id":1,"name":"jg-%s-t1"},{"tab_id":2,"name":"jg-%s-t2"},{"tab_id":3,"name":"jg-other-t3"}]' "$new" "$old"
}
assert_equals $'s:p1\tjg-t1\ns:p2\tjg-t2' "$(jg_backend_zellij_list_live s)" "zellij lists new and old titles"
jg_backend_zellij_tab_matches_label s 2 jg-t2 || fail "zellij old-tagged tab matches its label"
jg_backend_zellij_tab_matches_label s 3 jg-t3 && fail "zellij other home's tab must not match"

rm -f "$home/.jg-squad-lead-home"
assert_equals "juggernaut-${new##*-}" "$(jg_backend_hometag)" "primary tag unchanged"
pass "lead-<id> tag written, 2ndmate-<id> still read"
