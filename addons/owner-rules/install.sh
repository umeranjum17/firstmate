#!/usr/bin/env bash
# Turn on the owner rules in one firstmate home: write config/owner-rules, which brief-inherit's
# brief seam reads, and make config/merge-gate run bin/fm-owner-rules-gate.sh first, then the home's
# previous gate (moved aside to config/merge-gate.pre-owner-rules; uninstall moves it back). Idempotent: a
# repeat run keeps the gate when the rules already run, including behind another add-on's chain (owner-guard
# re-chains this same file), and a genuinely foreign gate still refuses rather than replace.
# Usage: install.sh [--dry-run] <fm-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1/config" ] || { echo "usage: install.sh [--dry-run] <fm-home>" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
f=$(cd "$1" && pwd -P)/config/owner-rules
MG=${f%owner-rules}merge-gate PREV=$MG.pre-owner-rules MARK='# fm-owner-rules merge gate'
if [ "$DRY" -eq 1 ]; then echo "would write: $f"; echo "would write: $MG (owner-rules gate, then the previous gate)"; echo "dry run: nothing written"; exit 0; fi
printf '%s\n' 'owner-rules add-on installed: brief-inherit runs owner-rules/bin/fm-owner-rules-lib.sh at brief creation; config/merge-gate runs owner-rules/bin/fm-owner-rules-gate.sh' > "$f"
# 0 when this gate already runs the owner-rules gate, directly or behind another add-on's chain: follow the
# chained prev= links the other installers write, bounded, so a repeat run keeps the chain it is part of
# instead of re-chaining it. That is what makes owner-guard's re-write of this file a no-op rather than an
# error, while a genuinely foreign gate still refuses below.
gate_runs_owner_rules() {  # gate_runs_owner_rules <gate file>
  local file=$1 depth=0 prev
  while [ -e "$file" ] && [ "$depth" -lt 8 ]; do
    grep -qF "$SRC/bin/fm-owner-rules-gate.sh" "$file" 2>/dev/null && return 0
    prev=$(sed -n 's/^prev=//p' "$file" 2>/dev/null | head -1)
    [ -n "$prev" ] || return 1
    file=$prev depth=$((depth + 1))
  done
  return 1
}
if [ -e "$MG" ] || [ -L "$MG" ]; then
  if grep -qxF "$MARK" "$MG" 2>/dev/null; then :
  elif gate_runs_owner_rules "$MG"; then echo "kept: $MG already runs the owner-rules gate behind another add-on's chain"
  elif [ -e "$PREV" ] || [ -L "$PREV" ]; then echo "error: $MG is not ours and $PREV exists; move one aside and rerun" >&2; exit 1
  else mv "$MG" "$PREV"; fi
fi
{
  printf '#!/usr/bin/env bash\n%s\n' "$MARK"
  printf '%q "$@" || exit $?\nprev=%q\n' "$SRC/bin/fm-owner-rules-gate.sh" "$PREV"
  cat <<'GATE'
[ -e "$prev" ] || [ -L "$prev" ] || exit 0
[ -x "$prev" ] || { echo "merge refused: $prev is not executable"; exit 1; }
exec "$prev" "$@"
GATE
} > "$MG.tmp"
chmod 755 "$MG.tmp" && mv "$MG.tmp" "$MG"
