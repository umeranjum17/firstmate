#!/usr/bin/env bash
# Real tasks-axi -> installed watcher check -> real sign-off-axi, in isolated homes.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${FM_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/tickets-sync.XXXXXX")
trap 'echo "retained fixture and normalized archives: $work"' EXIT
fork=${FM_TEST_FORK:-$HOME/firstmate}
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff
export FM_HOME=$work/main
mkdir -p "$HOME" "$FM_HOME"/{data,config,state} "$work/parked/data"
ln -s "$fork/bin" "$FM_HOME/bin"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$FM_HOME/config/fleet-board"
printf '%s\n' "- parked - Umer project (home: $work/parked; scope: demo)" > "$FM_HOME/data/secondmates.md"
printf 'parked\n' > "$FM_HOME/config/parked-homes"
printf '[markdown]\npath="data/backlog.md"\narchive="data/done-archive.md"\ndone_keep=0\n' > "$FM_HOME/.tasks.toml"
cp "$FM_HOME/.tasks.toml" "$work/parked/.tasks.toml"
(cd "$FM_HOME"; tasks-axi add parent '[captain-ask] Umer release' --repo alpha --priority 1 >/dev/null
 tasks-axi 'done' parent --no-prune >/dev/null
 tasks-axi add long "Umer 🚢 $(printf 'long title %.0s' {1..30})" --repo alpha --priority 1 --body $'release: next\nhttps://github.com/example/alpha/pull/123\nhttps://github.com/example/alpha/pull/456' >/dev/null
 tasks-axi add upkeep 'Umer maintenance' --repo alpha --priority 2 --body 'parent: upkeep' >/dev/null
 tasks-axi add held 'Umer paused item' --repo alpha --priority 1 --body 'parent: missing' >/dev/null
 tasks-axi hold held --reason 'Umer parked this item' --kind parked >/dev/null
 tasks-axi add child 'Umer settings' --repo alpha --priority 0 --body $'release: next\nparent: parent' >/dev/null)
sed -i "/^- \[x\] parent /s/$(date +%F)/2000-01-01/g" "$FM_HOME/data/backlog.md"
(cd "$work/parked"; tasks-axi add parent 'Umer paused project' --repo beta --priority 2 >/dev/null)
printf '\n## Done\n- [x] recent - Umer shipped feature (repo: alpha) (done %s)\n- [x] old - Umer historical work (repo: alpha) (done 2000-01-01)\n' "$(date +%F)" >> "$FM_HOME/data/backlog.md"
git init -q "$FM_HOME/projects/alpha"
git -C "$FM_HOME/projects/alpha" remote add origin https://github.com/example/alpha-app.git
source_before=$(sha256sum "$FM_HOME/data/backlog.md" "$work/parked/data/backlog.md")
bash "$root/tickets-sync/install.sh" --dry-run
test ! -d "$XDG_DATA_HOME/fm-tickets-sync"
bash "$root/tickets-sync/install.sh"
env -u FM_HOME "$FM_HOME/state/tickets-sync.check.sh"
ticket_id() { printf 'fm-%s\n' "$(printf '%s' "$1" | sha256sum | cut -c1-32)"; }
child=$(ticket_id main/child) parent=$(ticket_id main/parent) parked=$(ticket_id parked/parent)
sign-off-axi ticket "$work/board.json" --json > "$work/first.json" || { cat "$work/first.json"; exit 1; }
jq -e '.tickets | length == 10 and all(.[]; (.title | length) <= 160)'  "$work/first.json"
jq -e --arg id "$child" --arg parent "$parent" '.tickets[] | select(.id == $id) | .parent == $parent and .priority == "P0" and .asked == true and (.title | contains("next"))' "$work/first.json"
jq -e --arg id "$parked" '.tickets[] | select(.id == $id) | .hold == true' "$work/first.json"
jq -e --arg id "$(ticket_id main/held)" '[.tickets[] | select(.id == $id and .hold == true)] | length == 1' "$work/first.json"
jq -e --arg root "$parent" --arg upkeep "$(ticket_id main/upkeep)" '.tickets | any(.[]; .id == $root and .asked and (.parent // "") == "") and all(.[]; .asked or .id == $upkeep or (.title | startswith("Upkeep")))' "$work/first.json"
jq -e --arg held "$(ticket_id main/held)" '.tickets as $all | $all[] | select(.id == $held) | .project == "alpha-app" and (.parent as $p | any($all[]; .id == $p and (.title | startswith("Needs a parent"))))' "$work/first.json"
before=$(sha256sum "$work/board.tickets.jsonl")
mv "$FM_HOME/state/tickets-sync"/published-*.json "$FM_HOME/state/tickets-sync/ledger-before-restart"
"$FM_HOME/state/tickets-sync.check.sh"
test "$before" = "$(sha256sum "$work/board.tickets.jsonl")"
test "$source_before" = "$(sha256sum "$FM_HOME/data/backlog.md" "$work/parked/data/backlog.md")"
(cd "$FM_HOME"; tasks-axi 'done' child --pr https://github.com/example/alpha/pull/1 >/dev/null)
"$FM_HOME/state/tickets-sync.check.sh"
sign-off-axi ticket "$work/board.json" --id "$child" --json > "$work/closed.json"
jq -e '.ticket | .progress == 100 and .hold == false and (.title | contains("https://github.com/example/alpha/pull/1"))' "$work/closed.json"
before=$(sha256sum "$work/board.tickets.jsonl")
"$FM_HOME/state/tickets-sync.check.sh"
test "$before" = "$(sha256sum "$work/board.tickets.jsonl")"
sign-off-axi ticket "$work/board.json" --id "$parent" --json | jq -e '.ticket.progress == 100'
echo 'PASS: completed sync stays idempotent; epic progress rolls up from its child'
