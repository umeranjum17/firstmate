# bearings-board

The Bearings board for a Firstmate home, as a standalone copy: the board script and its template, plus the milestone fields and evidence thumbnails the fork added on top of upstream's board. It runs against any home named by `FM_HOME`.

Dormant copy: the fork still runs its own board ([FORK-EXIT.md](../FORK-EXIT.md)). Nothing in the fork changes when you install this.

## What it adds

- **Milestones.** Optional fields that render when present and leave older payloads unchanged:
  - Projects strip: release goal and date, health, merges today, last and next release, WIP count, and a link to that home's own board (`board_url`).
  - Underway rows: target, range, age, health, and evidence.
  - Landed rows and Captain's Call cards: evidence, and for cards the default-if-silent choice, decide-by date, asked-at date, and reversible flag.
- **Evidence thumbnails.** Evidence that points at an image (`.png`, `.jpg`, `.jpeg`, `.webp`, `.gif`) renders as a lazy-loaded thumbnail that opens the full image. Any other evidence stays a plain link. Evidence may be `http(s)://` or a relative `evidence/<file>` path that the board serves beside itself.
- **Reconcile on every decision card.** The script injects the standard `reconcile` choice, so no composer has to remember it.
- **Landed-card hygiene.** A decision whose subject already landed, or that is no longer an open captain call, is dropped on rebuild and named on stderr.

The payload schema is `fm-bearings-board.v1`. The header comment of `bin/fm-bearings-board.sh` lists every field and its rule.

## Run it

Needs `jq`, `lavish-axi`, and the home's own helpers under `$FM_HOME/bin` (`fm-captain-hold.sh`, `fm-procevent.sh`, `fm-procevent-lavish.sh`).

```sh
export FM_HOME=~/firstmate                                  # the Firstmate home the board serves
bearings-board/bin/fm-bearings-board.sh build data.json     # validate, inject, establish, bind, arm
bearings-board/bin/fm-bearings-board.sh path                # the stable board path for this home
```

`build` writes the board to `$FM_HOME/.lavish/bearings-board.html` in place, so a rebuild keeps the same Lavish session. It refuses a payload that fails validation before it touches the existing board, and it refuses to arm a poll on a Lavish session that is not live.

`FM_BEARINGS_BOARD_TEMPLATE` overrides the template path. Tests use it; a home does not need it.

## Test

```sh
bash bearings-board/tests/bearings-board.test.sh
```

Needs `jq` and `node`. It builds boards in a throwaway home with stub helpers and a stub `lavish-axi`, so nothing real starts or changes.

## Not in this copy

- The fork's live-Lavish end-to-end test and its real process-event listener tests. They need the fork's full test harness.
- `bin/fm-bearings-snapshot.sh`. The board does not call it.
- The Bearings skill (`SKILL.md`), which tells the composer how to fill the payload. It stays on the fork.
