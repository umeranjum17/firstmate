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
mkdir -p "$home/state/terminal-outcomes" "$home/state/t1.inbox" "$home/state/decision-bindings"
printf 'schema=fm-terminal-outcome.v1\n' > "$home/state/terminal-outcomes/t1.reported"
printf 'worker agent managed by firstmate\n' > "$home/state/t1.inbox/001.msg"
printf 'cd /home/x/.treehouse/firstmate-abc/4/firstmate/projects/p\n' > "$home/state/t1.meta"
printf 'merged a secondmate fix; bin/fm-lint.sh ran\n' > "$home/state/t1.status"
printf 'a firstmate hook\n' > "$home/state/t1.pr-poll-registration"
printf 'kind=secondmate\nwindow=fm-demo\n' > "$home/state/t2.meta"
printf 'exec /x/firstmate-1/bin/run\n' > "$home/config/launch-env-hook"
bash "$root/bin/jg-migrate.sh" --home "$home" --check > "$scratch/classified2" 2>&1 \
  || { echo 'check stopped on per-task records, host paths or status prose' >&2; cat "$scratch/classified2" >&2; exit 1; }
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
old_lead=second
old_lead+=mate
lh=$scratch/lead
mkdir -p "$lh"/{config/${old_lead}s/l1,state,data}
printf 'claude claude-haiku-5-5 low\n' > "$lh/config/${old_lead}s/l1/harness"
printf 'l1\n' > "$lh/.fm-${old_lead}-home"
printf 'schema=fm-%s-parent.v1\nroute=remote\n' "$old_lead" > "$lh/.fm-${old_lead}-parent"
printf '# main-authoritative. read-only in %s homes, must not be edited there. Ask the main first%s.\n' "$old_lead" "mate" > "$lh/data/captain-shared.md"
cp -a "$lh" "$scratch/lead-before"
bash "$root/bin/jg-migrate.sh" --home "$lh" --apply
bash "$root/bin/jg-migrate.sh" --home "$lh" --verify
grep -q '^l1$' "$lh/.jg-squad-lead-home"
grep -q '^schema=jg-squad-lead-parent.v1$' "$lh/.jg-squad-lead-parent"
grep -q 'read-only in squad_lead homes' "$lh/data/captain-shared.md"
grep -q 'main juggernaut' "$lh/data/captain-shared.md"
grep -q 'claude-haiku-5-5' "$lh/config/squad_leads/l1/harness"
[ ! -e "$lh/.fm-${old_lead}-home" ] && [ ! -e "$lh/.fm-${old_lead}-parent" ] && [ ! -e "$lh/config/${old_lead}s" ] \
  || { echo 'migrator left an old marker or pin directory' >&2; exit 1; }
bash "$root/bin/jg-migrate.sh" --home "$lh" --rollback
diff -r "$scratch/lead-before" "$lh"
printf 'jg-migrate integration passed\n'
