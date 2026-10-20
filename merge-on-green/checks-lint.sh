#!/usr/bin/env bash
# Run done-done's pinned merge-gate lint, or the Firstmate lint when the pinned CLI is unavailable.
# Usage: FM_HOME=<home> checks-lint.sh <PR URL | report file> <evidence folder>
set -u
[ "$#" -eq 2 ] && [ -n "${FM_HOME:-}" ] || { echo "usage: FM_HOME=<home> checks-lint.sh <PR URL | report file> <evidence folder>" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
case "$1" in https://*) source=$1 ;; *) source=$(cd "$(dirname "$1")" && printf '%s/%s\n' "$PWD" "$(basename "$1")") ;; esac
evidence=$(cd "$(dirname "$2")" && printf '%s/%s\n' "$PWD" "$(basename "$2")")
LEGACY=${FM_LEGACY_CHECKS_LINT:-${FM_MAIN_HOME:-$HOME/firstmate}/config/fm-checks-lint.sh}
DD_HOME=$FM_HOME/data/done-done-lint
DD=(npx --yes --quiet --package=done-done-axi@0.4.5 done-done)
if [ -n "${FM_DONE_DONE_BIN:-}" ]; then DD=("$FM_DONE_DONE_BIN"); fi

# Pin the released CLI: older installed done-done binaries do not have the config keys.
if ! command -v "${DD[0]}" >/dev/null 2>&1 || ! "${DD[@]}" lint --help 2>/dev/null | grep -q 'checks.generated_paths:'; then
  exec "$LEGACY" "$source" "$evidence"
fi

mkdir -p "$DD_HOME" "$FM_HOME/data" || exit 2
d=$(mktemp -d) || exit 2
trap 'rm -rf -- "$d"' EXIT
# Lint reads repo config and verify-skill presence from cwd. Keep its config isolated from the real checkout.
cp "$SRC/.done-done.yaml" "$d/.done-done.yaml"
repo=$(printf '%s' "$source" | sed -nE 's#https://github\.com/[^/]+/([^/]+)/pull/.*#\1#p')
skills=${FM_HOME}/projects/${repo}/.agents/skills
if [ -d "$skills" ]; then mkdir -p "$d/.agents" && ln -s "$skills" "$d/.agents/skills"; fi
set +e
out=$(cd "$d" && DONE_DONE_HOME="$DD_HOME" "${DD[@]}" lint "$source" "$evidence" 2>&1)
rc=$?
row=$(tail -n 1 "$DD_HOME/lint.log" 2>/dev/null || true)
logged_src=$(printf '%s' "$row" | cut -f2)
head=$(printf '%s' "$row" | cut -f3)
verdict=$(printf '%s' "$row" | cut -f4)
why=$(printf '%s' "$row" | cut -f5-)
[ "$logged_src" = "$source" ] || { echo "checks-lint: FAIL: done-done produced no matching lint record: $out"; exit 1; }
mkdir -p "$FM_HOME/data"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$source" "$head" "$verdict" "$why" >> "$FM_HOME/data/checks-gate.log"
receipt_verdict=FAIL
[ "$rc" -ne 0 ] || receipt_verdict=PASS
if [ "$rc" -eq 0 ]; then
  printf 'checks-lint: PASS: %s\n' "$why"
else
  printf 'checks-lint: FAIL: %s\n' "${why:-$out}"
fi
# Match the legacy lint's completion-receipt side effect for either verdict.
for meta in "$FM_HOME"/state/*.meta; do
  [ -f "$meta" ] && grep -Fxq "pr=$source" "$meta" || continue
  task=${meta##*/}; task=${task%.meta}
  helper=${FM_ADDONS_DIR:-$(cd "$SRC/.." && pwd -P)}/receipts/bin/fm-run-receipt.sh
  if [ -x "$helper" ]; then
    report=$(mktemp) || exit 1
    printf 'checks-lint %s %s head %s: %s\n' "$receipt_verdict" "$source" "$head" "${why:-$out}" > "$report"
    worktree=$(awk -F= '$1 == "worktree" { value = $2 } END { print value }' "$meta")
    receipt=$(env FM_HOME="$FM_HOME" "$helper" "$task" "$receipt_verdict" "$report" "${worktree:-$FM_HOME}" 2>&1); receipt_rc=$?
    [ "$receipt_rc" -eq 0 ] || echo "checks-lint: receipt not published: ${receipt:-fm-run-receipt.sh failed}" >&2
    rm -f -- "$report"
  fi
  break
done
exit "$rc"
