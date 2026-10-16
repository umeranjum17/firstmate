# host-memory

The host memory sampler — the per-home loop that samples host memory
pressure for admission and monitoring — moved **verbatim** out of the
supervising fork into this add-on repository. Nothing runs it from here
yet: the live watcher keeps sourcing the fork's
`bin/fm-host-memory-sampler.sh`, and the fork-side hook that will source
this directory instead lands in a later PR. Until that swap this directory
is dormant, and every moved byte below is identical to the fork copy the
live watcher runs today.

## Layout

- `bin/fm-host-memory-sampler.sh` — the sampler: sourced by the watcher
  for its lifecycle functions (`fm_memory_sampler_ensure`,
  `fm_memory_sampler_stop`, `fm_memory_sampler_matches`,
  `fm_memory_sampler_tick`, `fm_memory_sampler_interrupt`,
  `fm_memory_sampler_cleanup`), and executable as
  `run <HOME> <STATE> <CONFIG>` for the one sampler loop per home.

## Frozen contract (identical to the fork)

- CLI: `fm-host-memory-sampler.sh run <HOME> <STATE> <CONFIG>`; any other
  argv exits 2, a missing state directory exits 1, an already-held sampler
  lock exits 0. Sourced, it provides the `fm_memory_sampler_*` functions
  above; the watcher calls `fm_memory_sampler_ensure` to start (or reuse)
  the loop and `fm_memory_sampler_stop` to end it.
- Cadence: one sample every `FM_HOST_MEMORY_SECS` (default 10), each tick
  calling the sibling guard beside it as
  `fm-jev-mem-guard.sh --config <CONFIG>/host-memory --record
  <STATE>/host-memory.tsv --owned-top-task <STATE> --state-dir ...`.
  The guard itself stays in the fork and is not moved.
- Verdicts: the guard prints `<verdict>\t<summary>` where verdict is
  `OK`, `WAIT`, `ALERT`, or `UNKNOWN`. `WAIT` and `OK` clear the alert
  latch and record nothing further; only the first `ALERT` of an episode
  wakes (later `ALERT` rows in the same episode are quiet until a
  `WAIT`/`OK` clears the latch).
- Alert: one durable wake `check host-memory` with reason
  `check: host memory ALERT: <summary>; <action>`, one row
  `<epoch>\t<task>\t<reason; action>` in
  `<STATE>/host-memory-interrupts.tsv`, one latch file
  `<STATE>/.host-memory-alerted`, and one owned-task interrupt attempt via
  the sibling control entry beside it (`fm-control.sh <task> interrupt`;
  its output becomes the recorded action). A top consumer this home does
  not own is recorded as skipped, never interrupted.
- State files, all under the home's state directory: `host-memory.tsv`
  (one sample row per tick:
  `<epoch>\t<available kB>\t<swap used kB>\t<sustained pressure>\t<verdict>`,
  read by the fork's dashboard history), `host-memory-interrupts.tsv`
  (`<epoch>\t<task>\t<action>`), `.host-memory-alerted` (the per-episode
  latch), `.host-memory-sampler.pid` (`<pid>\t<process identity>`),
  `.host-memory-sampler.lock`, and `.host-memory-sampler.log`. Config is
  read only as `<CONFIG>/host-memory`; thresholds there are owned by the
  guard and never changed here.

## Provenance: byte-identical to the fork

Every moved file was compared byte for byte against its fork source at
`umeranjum17/firstmate@0689b4b9d9ab3594f846cfe07c400edfa58244bf` at move time;
the mode is `100755` on both sides:

| moved file | sha256 at the fork commit | sha256 here |
| --- | --- | --- |
| `bin/fm-host-memory-sampler.sh` | `9a8c7a892e9df592d3cf8b8e79bc3e4dc13934bc256d0845256451972e4a945a` | `9a8c7a892e9df592d3cf8b8e79bc3e4dc13934bc256d0845256451972e4a945a` |

Treat any future diff against the fork file as a contract change, not a
refactor.

## Side-by-side proof (re-run before the fork hook swaps the sourced path)

1. Unpack the fork tree at the commit above into two scratch roots:
   `git -C <fork> archive 0689b4b9d9ab3594f846cfe07c400edfa58244bf | tar -x -C <rootA>`,
   then `cp -a <rootA>/. <rootB>/`.
2. In `rootB` only, overwrite `bin/fm-host-memory-sampler.sh` with the
   moved file; `diff -r <rootA> <rootB>` must be empty, and the file's
   sha256 and mode must equal the fork's.
3. Run `tests/fm-jev-mem-guard.test.sh` in a scratch root; it exercises
   the sampler path and one PASS proves the identical bytes. A loaded host
   can miss the journey's own timing budget, so record a run that fails
   only on timing rather than treating it as a behavior change (at most 3
   runs; with no pass, stop with the outputs).
4. Run the repository CI gate (ShellCheck plus the syntax check over every
   add-on script); it must pass on the PR head. The moved script carries
   `# shellcheck source=bin/...` directives for sibling fork libraries
   that did not move, so the gate exempts `SC1091` for `host-memory/bin/`
   only, never editing the copy.

Do **not** run the sampler against a real home, touch the memory guard or
any service, or change memory thresholds; the moved copy is dormant until
the fork hook lands.
