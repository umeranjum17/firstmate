#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
home=$scratch/home
mkdir -p "$home"/{config,state,data}
printf 'FM_MODEL=claude-haiku-5-5\n' > "$home/config/crew"
printf 'fm-open-decision: waiting\nnote: unread status line\n' > "$home/state/task.status"
printf 'projects/firstmate-addons\n' > "$home/data/records"
cp -a "$home" "$scratch/before"
bash "$root/bin/jg-migrate.sh" --home "$home" --check > "$scratch/check"
grep -q 'config/crew' "$scratch/check"
bash "$root/bin/jg-migrate.sh" --home "$home" --apply
bash "$root/bin/jg-migrate.sh" --home "$home" --verify
grep -q 'JG_MODEL=claude-haiku-5-5' "$home/config/crew"
grep -q 'jg-open-decision: waiting' "$home/state/task.status"
grep -q 'note: unread status line' "$home/state/task.status"
grep -q 'projects/juggernaut-addons' "$home/data/records"
bash "$root/bin/jg-migrate.sh" --home "$home" --rollback
diff -r "$scratch/before" "$home"
if bash "$root/bin/jg-migrate.sh" --home "$home" --verify; then
  echo 'verify accepted rolled-back legacy records' >&2
  exit 1
fi
printf 'fm-unknown: value\n' > "$home/state/unknown.status"
if bash "$root/bin/jg-migrate.sh" --home "$home" --check > "$scratch/unknown" 2>&1; then
  echo 'check accepted an unclassified record' >&2
  exit 1
else
  code=$?
  [ "$code" = 3 ] || { echo "unknown record exit was $code, not 3" >&2; exit 1; }
fi
printf 'jg-migrate integration passed\n'
