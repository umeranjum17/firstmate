# Tickets sync

Run `FM_HOME=<fleet-home> bash tickets-sync/install.sh` from merged main to register the existing watcher's poll; `--dry-run` writes nothing.
Requires Python 3.11+, gh-axi, tasks-axi, sign-off-axi and Firstmate's backlog libraries; the board comes from `config/fleet-board`.
Backlogs stay read-only: archive headings are normalized in retained copies under `state/tickets-sync/` before tasks-axi reads them.
Open work and seven days of completed work are backfilled by stable home/item hashes; lane status and linked GitHub PR state supply queued (0), building (30), review/CI (65), merging (90), and done (100) progress.
Parked homes and held items stay On hold; completion clears hold.
Captain asks are epic roots; `parent: <item id>` confirms hierarchy, `parent: upkeep` alone means System, and unconfirmed items sit under Needs a parent.
Each poll uses a field-hash ledger and a 20-second cursor budget; `sync.py --audit` runs the full ticket list separately.
Public titles cap at 160 characters: names may be abbreviated and excess links counted; release/state use the suffix, and existing cards need their producer to set `--ticket`.
Each real project name gets the dashboard's own local image (`fleet-dashboard/fm-dashboard/icons`) through `sign-off-axi project --icon`, only when it passes `identify` or the XML parser and the registry hash differs; missing or broken images are named once, when their state changes.
Backlog completion, merged delivery PRs, and explicit `status: superseded|cancelled` notes or terminal lane events close tickets; URLs in free-form notes do not imply completion.
Use `sync.py --reconcile` to finish every registered home without the watcher budget; GitHub failures name their cause and stop the sync, and open PR state is refreshed after five minutes.
For an authorized board-only cancellation or supersession, use `sync.py --close HOME/ITEM --reason superseded|cancelled --reconcile`; the decision is retained in the sync state's `closures.json`, without editing the source backlog.
Explicit board completion survives a sync-state reset so a stale backlog cannot reopen cancelled work.
Parents retain sign-off's child roll-up; stage words and stale-event age require sign-off's display contract.
