# signoff

The sign-off event handler — the adapter that turns sign-off board answers
into hold answers and merge-gate events through the fork's process-event
runner — moved **verbatim** out of the Firstmate fork into this add-on
repository. Nothing runs it from here yet: the fork's
`bin/fm-procevent-signoff.sh` stays the live adapter its runner dispatches,
and the fork-side hook that will exec into this directory lands in a later
PR. Until that swap this directory is dormant, and every moved byte below is
identical to the fork copy the live runner dispatches today.

## Layout

- `bin/fm-procevent-signoff.sh` — the `signoff` source adapter for the
  process-event runner: `arm` opts a home in (binds the source to the
  keyed-answer intake and registers `poll` with the runner), `retire` opts
  out, `raise` raises one board card per hold, `poll` prints one JSON object
  per deliverable answer, `answers` maps captured poll lines to the intake's
  tab-separated rows, `ack` records delivered answers, and `relisten` exits 0
  so the runner polls again.
- `tests/fm-procevent-signoff.test.sh` — the fork's adapter journey: a stub
  section (a transient intake failure is offered again until taken; a re-held
  task gets a live card of its own) and a real-hold section over an isolated
  home (hold raises a card with the right title, reason and close mode; a
  dated deferral raises none; the reserved reconcile answer is refused for
  good, acked once, and leaves the hold open).

The adapter sources `fm-pr-lib.sh`, `fm-wake-lib.sh` and
`fm-procevent-lib.sh` from its own directory and calls the runner
(`fm-procevent.sh`) and the keyed-answer intake (`fm-captain-hold.sh`) beside
it; those fork files did not move, so the moved copy only runs with the fork
tree around it (see the proof below).

## Frozen contract (identical to the fork)

- CLI: `fm-procevent-signoff.sh arm|retire|raise <task-id> <title> <reason>
  <done|release>|poll|answers <result-file>|ack <result-file>|relisten`;
  `-h`/`--help` prints usage and exits 2, as does any other bad invocation.
- Dispatch: registered with the runner as the `signoff` source with `poll`
  as the blocking child; `answers` is this adapter's half of the keyed-answer
  contract and `ack` runs only after the intake exits 0 (every answer taken)
  or 3 (every skip permanent).
- `poll` prints one JSON object per line per deliverable answer —
  `{"key","answer","label","close","at"}` with the bare task id as key — and
  exits 0; with nothing deliverable it waits up to 600 seconds, rests 30
  seconds when still nothing is deliverable, and exits 75 with no output, the
  runner's clean empty wait.
- `answers` prints `<task-id>\t<answer>\t<label>\t<close>` per captured
  line, with tabs and newlines inside the answer or label turned into spaces;
  it records nothing.
- An answer is deliverable only when its key carries this home's tag, its
  bare task id is one this home still holds, its key names that hold's
  current stamp, and it was not already acknowledged.
- Board keys are `fm-<tag>-<task-id>-<stamp>`, where `<tag>` is a stable
  digest of `FM_HOME` and `<stamp>` is the hold-set stamp in alphanumerics
  only. The board tool must be on PATH: without it `arm` refuses, and `raise`
  fails so the hold is kept and only warns.

## Provenance: byte-identical to the fork

Every moved file was compared byte for byte against its fork source at
`umeranjum17/firstmate@0689b4b9d9ab3594f846cfe07c400edfa58244bf` at move time;
modes are `100755` for the script and `100644` for the test on both sides:

| moved file | sha256 at the fork commit | sha256 here |
| --- | --- | --- |
| `bin/fm-procevent-signoff.sh` | `14bdbecc0bdf18fafa8ef6b9049419d5cd9de2190d10f8ff371862c6176bb947` | `14bdbecc0bdf18fafa8ef6b9049419d5cd9de2190d10f8ff371862c6176bb947` |
| `tests/fm-procevent-signoff.test.sh` | `c89cd346c8ca92683d45d156c67495bf9dd5aa6ea2cd85a964bc21fe672b9367` | `c89cd346c8ca92683d45d156c67495bf9dd5aa6ea2cd85a964bc21fe672b9367` |

Treat any future diff against the fork file as a contract change, not a
refactor.

## Side-by-side proof (re-run before the fork hook swaps the dispatched path)

1. Unpack the fork tree at the commit above into two scratch roots:
   `git -C <fork> archive 0689b4b9d9ab3594f846cfe07c400edfa58244bf | tar -x -C <rootA>`,
   then `cp -a <rootA>/. <rootB>/`.
2. In `rootB` only, overwrite `bin/fm-procevent-signoff.sh` and
   `tests/fm-procevent-signoff.test.sh` with the moved files; `diff -r
   <rootA> <rootB>` must be empty, and every file's sha256 and mode must
   equal the fork's.
3. Run `tests/fm-procevent-signoff.test.sh` in a scratch root; one PASS
   proves the identical bytes. A loaded host can miss the journey's own
   timing budget, so record a run that fails only on timing rather than
   treating it as a behavior change (at most 3 runs; with no pass, stop with
   the outputs).
4. Run the repository CI gate (ShellCheck plus the syntax check over every
   add-on script); it must pass on the PR head. The moved script carries
   `# shellcheck source=bin/...` directives for sibling fork libraries that
   did not move, so the gate exempts `SC1091` for `signoff/bin/` only, never
   editing the copy.

Do **not** run the adapter against a real home or a live sign-off board, and
never post to any board; the moved copy is dormant until the fork hook
lands.

## For the fork hook lane

The runner dispatches the adapter by running the fork's
`bin/fm-procevent-signoff.sh` with the source id `signoff`; the later hook
must keep that exact CLI and argv (it will exec
`signoff/bin/fm-procevent-signoff.sh`). Re-run the side-by-side proof above
immediately before the dispatched path swaps, and keep this README's proof
sections honest when the proof moves.
