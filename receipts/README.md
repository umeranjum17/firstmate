# receipts

The completion-receipt publisher — the script that publishes one task's
candidate-bound PASS or FAIL completion receipt that guarded landing checks —
moved **verbatim** out of the supervising fork into this add-on repository.
Nothing publishes from here yet: the live flow keeps running the fork's
`bin/fm-run-receipt.sh`, and the fork-side hook that will exec into this
directory lands in a later PR. Until that swap this directory is dormant, and
every moved byte below is identical to the fork copy the live flow runs today.

## Layout

- `bin/fm-run-receipt.sh` — publishes the completion receipt for one task's
  current candidate into `state/<id>.run-receipt.json`, embedding the
  evidence file's contents in the receipt. It sources `fm-dod-lib.sh`,
  `fm-wake-lib.sh` and `fm-backlog-transition-lib.sh` from its own directory
  and serializes publication with the task control lock; those sibling
  libraries did not move, so the moved copy only runs with the fork tree
  around it (see the proof below).

## Frozen contract (identical to the fork)

- CLI: `FM_HOME=<supervising-home> fm-run-receipt.sh <task-id> PASS|FAIL
  <evidence-file> [candidate-repo]`; the candidate repo defaults to the
  current directory and `FM_HOME` must be set explicitly. `--help` prints
  usage and exits 0.
- Receipt: `state/<id>.run-receipt.json` with schema 1 fields
  `{schema:1, task, mode, spawn_gen, head, verdict, at, evidence}`, where
  `head` is the candidate repo's HEAD commit, `at` is Unix time, and
  `evidence` is the evidence file's full contents (it must be nonempty;
  the file is embedded, never stored as a pointer).
- Guards: PASS requires a clean candidate tree, and the task meta must carry
  a ship delivery mode (`local-only`, `direct-PR` or `no-mistakes`).
- Exit codes: 0 on publication (prints
  `receipt: <id> <VERDICT> head=<sha>`), 2 on usage errors (bad arguments,
  bad task id, verdict not PASS or FAIL), 1 on runtime failures (task
  metadata or evidence missing, `jq` unavailable, spawn-generation or
  atomic-transition failure, wrong mode, dirty tree on PASS).

## Provenance: byte-identical to the fork

Every moved file was compared byte for byte against its fork source at
`umeranjum17/firstmate@0689b4b9d9ab3594f846cfe07c400edfa58244bf` at move time;
the mode is `100755` on both sides:

| moved file | fork source | sha256 |
|---|---|---|
| `receipts/bin/fm-run-receipt.sh` | `bin/fm-run-receipt.sh` | `d2cd7ad9bb8732c5a605faae5e72fac58e9ae1802cb565cd7b130bb9be72f720` |

Treat any future diff against the fork file as a contract change, not a
refactor.

## Side-by-side proof (re-run before the hook swaps the dispatched path)

1. Unpack the fork tree at the commit above into two scratch roots:
   `git -C <fork> archive 0689b4b9d9ab3594f846cfe07c400edfa58244bf | tar -x -C <rootA>`,
   then `cp -a <rootA>/. <rootB>/`.
2. In `rootB` only, overwrite `bin/fm-run-receipt.sh` with the moved file;
   `diff -r <rootA> <rootB>` must be empty, and the sha256 and mode must
   match the table above.
3. Run `tests/fm-dod-lib.test.sh` in the fork scratch tree (it exercises
   receipt publication and acceptance; `fm-dod-lib.sh` itself stays in the
   fork and is NOT moved); one PASS proves the identical bytes.
4. Run the repo CI gate (shellcheck plus syntax check over every add-on
   script) on the PR head.
