# Tickets sync

Run `FM_HOME=<fleet-home> bash tickets-sync/install.sh` from merged main to register the existing watcher's poll; `--dry-run` writes nothing.
Requires Python 3.11+, tasks-axi, sign-off-axi and Firstmate's backlog libraries; the board comes from `config/fleet-board`.
Backlogs stay read-only: archive headings are normalized in retained copies under `state/tickets-sync/` before tasks-axi reads them.
Open work and seven days of completed work are backfilled by stable home/item hashes; closed items get 100%, active items 17%, and queued work 0%.
Parked homes and held items stay On hold; completion clears hold.
Captain asks are epic roots; `parent: <item id>` confirms hierarchy, `parent: upkeep` alone means System, and unconfirmed items sit under Needs a parent.
Each poll uses a field-hash ledger and a 20-second cursor budget; `sync.py --audit` runs the full ticket list separately.
Public titles cap at 160 characters: names may be abbreviated and excess links counted; release/state use the suffix, and existing cards need their producer to set `--ticket`.
Each real project name gets the dashboard's own local image (`fleet-dashboard/fm-dashboard/icons`) through `sign-off-axi project --icon`, only when it passes `identify` or the XML parser and the registry hash differs; missing or broken images are named once, when their state changes.
