#!/usr/bin/env bash
# tests/jg-licence-check.test.sh - an adopted dependency's licence must be on the home's allowlist.
#
# The failure is a copyleft or undeclared licence entering a manifest unnoticed, so the check must pass an
# allowed licence silently and report both a licence outside the allowlist and one it cannot find.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK=$(jg_test_tmproot jg-licence-check)
repo=$WORK/repo
allowlist=$WORK/allowlist
mkdir -p "$repo"
printf 'MIT\nApache-2.0\nBSD-2-Clause\nBSD-3-Clause\nISC\n' >"$allowlist"
licence() { JG_HOME=$WORK/home "$ROOT/bin/jg-licence-check.sh" --root "$repo" --allowlist "$allowlist"; }
lock() { printf '{"lockfileVersion":3,"packages":{%s}}\n' "$1" >"$repo/package-lock.json"; }

printf '{"dependencies":{"plain":"1.0.0"},"devDependencies":{"dual":"2.0.0"}}\n' >"$repo/package.json"
lock '"node_modules/plain":{"license":"MIT"},"node_modules/dual":{"license":"(MIT OR Apache-2.0)"}'
out=$(licence) || fail "the check must exit 0"
[ -z "$out" ] || fail "an allowed licence must print nothing, got: $out"

printf '{"dependencies":{"plain":"1.0.0","copyleft":"3.0.0","mystery":"4.0.0"}}\n' >"$repo/package.json"
lock '"node_modules/plain":{"license":"MIT"},"node_modules/copyleft":{"license":"AGPL-3.0"}'
printf 'requests==2.0.0\n' >"$repo/requirements.txt"
out=$(licence) || fail "a reported licence must still exit 0"
assert_contains "$out" "outside-allowlist $repo/package.json copyleft AGPL-3.0" "a licence outside the allowlist is reported"
assert_contains "$out" "unknown-licence $repo/package.json mystery" "a dependency with no declared licence is reported unknown"
assert_contains "$out" "unknown-licence $repo/requirements.txt requests" "a requirement carries no licence, so it is unknown"
assert_not_contains "$out" plain "an allowed dependency is never reported"
assert_contains "$out" "licence-check: 4 dependencies checked, 3 reported" "the summary counts every dependency and finding"

pass "jg-licence-check.sh: allowed licences pass, outside-allowlist and unknown licences are reported"
