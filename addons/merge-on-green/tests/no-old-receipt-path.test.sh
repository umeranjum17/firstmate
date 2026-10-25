#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/home/state" "$tmp/home/data/task" "$tmp/addons/receipts/bin"
printf 'worktree=%s\n' "$tmp/worktree" > "$tmp/home/state/task.meta"
printf 'invalid report\n' > "$tmp/report.txt"
cat > "$tmp/addons/receipts/bin/fm-run-receipt.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$4" >> "$PUBLISH_LOG"
EOF
chmod +x "$tmp/addons/receipts/bin/fm-run-receipt.sh"
set +e
FM_HOME="$tmp/home" FM_ADDONS_DIR="$tmp/addons" PUBLISH_LOG="$tmp/published" \
  python3 "$ROOT/merge-on-green/fm-checks-lint.sh" "$tmp/report.txt" "$tmp/home/data/task" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo 'FAIL: invalid report unexpectedly passed lint' >&2; exit 1; }
grep -q '^task|FAIL|' "$tmp/published" || { echo 'FAIL: lint caller did not invoke the configured receipt publisher' >&2; exit 1; }
bash "$ROOT/merge-on-green/tests/checks-lint-parity.test.sh"
