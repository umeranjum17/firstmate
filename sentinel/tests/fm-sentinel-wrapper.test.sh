#!/usr/bin/env bash
# The add-on wrapper runs the Firstmate sentinel from its checkout with the same
# argv, defaults the checkout to FM_HOME, and fails clearly when none is found.
# A stub checkout stands in for Firstmate, so nothing real is started.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WRAP="$HERE/../bin/fm-sentinel.sh"
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
mkdir -p "$d/code/bin" "$d/home"
cat > "$d/code/bin/fm-sentinel.sh" <<'STUB'
#!/usr/bin/env bash
printf 'ran home=%s args=%s\n' "$FM_HOME" "$*"
STUB
chmod +x "$d/code/bin/fm-sentinel.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

out=$(FM_CODE_ROOT="$d/code" FM_HOME="$d/home" "$WRAP" reconcile) || fail "wrapper failed with FM_CODE_ROOT: $out"
[ "$out" = "ran home=$d/home args=reconcile" ] || fail "argv or FM_HOME not passed through: $out"
pass "runs the checkout's sentinel with the same argv and FM_HOME"

out=$(env -u FM_CODE_ROOT FM_HOME="$d/code" "$WRAP" tick loop) || fail "wrapper failed with FM_HOME as checkout: $out"
[ "$out" = "ran home=$d/code args=tick loop" ] || fail "FM_HOME is not the default checkout: $out"
pass "defaults the checkout to FM_HOME"

rc=0
err=$(env -u FM_CODE_ROOT FM_HOME="$d/none" "$WRAP" tick 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 2 ] || fail "missing checkout should exit 2, got $rc"
case "$err" in *"no Firstmate checkout"*) ;; *) fail "missing checkout message unclear: $err" ;; esac
pass "fails with exit 2 and a clear message when no checkout is found"
