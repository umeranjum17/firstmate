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
mkdir -p "$home/data/task-one"
printf 'the firstmate asked a secondmate\n' > "$home/data/note.md"
printf 'the crewmate said fm-x\n' > "$home/data/task-one/report.txt"
printf 'bin/fm-send.sh FM_HOME=x\n' > "$home/config/post-merge"
bash "$root/bin/jg-migrate.sh" --home "$home" --check > "$scratch/classified" 2>&1 \
  || { echo 'check stopped on free text or a compat-resolved name' >&2; exit 1; }
printf 'fm-unknown: value\n' > "$home/state/unknown.status"
printf 'fm-also-unknown: value\n' > "$home/state/unknown2.status"
if bash "$root/bin/jg-migrate.sh" --home "$home" --check > "$scratch/unknown" 2>&1; then
  echo 'check accepted an unclassified record' >&2
  exit 1
else
  code=$?
  [ "$code" = 3 ] || { echo "unknown record exit was $code, not 3" >&2; exit 1; }
  grep -q 'state/unknown.status' "$scratch/unknown" || { echo 'check did not list unknown.status' >&2; exit 1; }
  grep -q 'state/unknown2.status' "$scratch/unknown" || { echo 'check stopped before unknown2.status' >&2; exit 1; }
fi
printf 'jg-migrate integration passed\n'
