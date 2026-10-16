# sentinel

The restart-recovery add-on — a supervisor that runs **outside** the agent
runtime, so it survives a runtime restart that kills every agent and watcher in
the runtime server's process tree. On a detected restart it re-arms supervision:
it reconciles the home's direct reports, relaunches a lane that came back
outside its recorded worktree, nudges a lane whose turn was lost, and wakes the
primary session. Moved **verbatim** out of the Firstmate fork into this add-on
repository. Nothing runs it from here yet: the fork's `bin/fm-sentinel.sh` stays
the live script its own user service runs, and the fork-side hook that will exec
into this directory lands in a later PR. Until that swap this directory is
dormant, and every moved byte below is identical to the fork copy the live
service runs today.

## Layout

- `bin/fm-sentinel.sh` — the recovery supervisor. `tick` reads the runtime
  server's socket identity under the home's lock and, on a changed identity,
  runs a reconcile pass and leaves one pending wake for the primary; `loop`
  ticks on an interval; `reconcile` performs the per-lane recovery pass; `unit`
  prints the user-service definition that runs `loop`.
- `tests/fm-sentinel-restart-resume.test.sh` — the token-free restart journey
  over a named lab runtime session: after a restart, reconciling must nudge
  exactly the one lane whose turn was lost, none for the mid-turn, properly
  waiting, or already-acted lanes, and a repeat pass must not nudge again.
- `tests/fm-sentinel-herdr-restart-live-e2e.test.sh` — the opt-in credentialed
  live end-to-end restart journey; moved verbatim, run only against a real
  terminal server (never run it from here — see the proof note).

## Frozen contract (identical to the fork)

- CLI: `FM_HOME=<home> fm-sentinel.sh tick|loop|reconcile|unit`. `FM_HOME` is
  required and must resolve to a directory; `-h`/`--help` prints the usage block
  and exits 0; any other invocation prints usage to stderr and exits 2.
- `unit` prints a user-service definition whose `ExecStart` runs
  `fm-sentinel.sh loop` (`Restart=always`, `RestartSec=10`,
  `WantedBy=default.target`), with `FM_HOME` and `PATH` in its environment.
- Knobs: `FM_SENTINEL_HERDR_SESSION` (falls back to the runtime's own session
  variable, else `default`), `FM_SENTINEL_INTERVAL` (60),
  `FM_SENTINEL_REWAKE_SECS` (1800), `FM_GUARD_GRACE` (300), and
  `FM_SENTINEL_EPISODE` for a standalone `reconcile` call.
- Exit: 0 after a pass including deferred work; 1 when a pass hit an error it
  logged; 2 for usage or a missing `FM_HOME`.
- State under `state/`, names unchanged: reads and writes
  `.sentinel-herdr-identity`, `.sentinel-woken-for`, `.sentinel-wake-pending`,
  `.sentinel-wake-last`, the `.sentinel.lock` lock and `.sentinel.log`; reads
  `.lock-session`, `.last-watcher-beat`, each `*.meta` and each lane's
  `.busy-state`/`.status`; writes each lane's `.restart-nudged`.
- Log line: `say` prints to stdout and appends one UTC-stamped line to
  `state/.sentinel.log`, which is trimmed to the last 500 lines past 1000.

## Provenance: byte-identical to the fork

Every moved file was compared byte for byte against its fork source at
`umeranjum17/firstmate@0689b4b9d9ab3594f846cfe07c400edfa58244bf` at move time,
and its mode is `100755` on both sides:

| moved file | sha256 at the fork commit | sha256 here |
| --- | --- | --- |
| `bin/fm-sentinel.sh` | `9f01f663a14804ed069ce5d0eb6bbeb850c387585ffbbdad96b0af30dcb70efa` | `9f01f663a14804ed069ce5d0eb6bbeb850c387585ffbbdad96b0af30dcb70efa` |
| `tests/fm-sentinel-restart-resume.test.sh` | `4a4a969e3cd637ff698a8b5142308b28dc2dfd9b47c0de42fde9697094682c9b` | `4a4a969e3cd637ff698a8b5142308b28dc2dfd9b47c0de42fde9697094682c9b` |
| `tests/fm-sentinel-herdr-restart-live-e2e.test.sh` | `add34f4f53edc359d8d204f9cf1f98143b7d4187617aa767dec82382d0c165af` | `add34f4f53edc359d8d204f9cf1f98143b7d4187617aa767dec82382d0c165af` |

Treat any future diff against the fork file as a contract change, not a
refactor.

## Side-by-side proof (re-run before the fork hook swaps the served path)

1. Unpack the fork tree at the commit above into two scratch roots:
   `git -C <fork> archive 0689b4b9d9ab3594f846cfe07c400edfa58244bf | tar -x -C <rootA>`,
   then `cp -a <rootA>/. <rootB>/`.
2. In `rootB` only, overwrite `bin/fm-sentinel.sh` and the two
   `tests/fm-sentinel-*.test.sh` with the moved files; `diff -r <rootA> <rootB>`
   must be empty, and every file's sha256 and mode must equal the fork's.
3. Run `tests/fm-sentinel-restart-resume.test.sh` in a scratch root; it must
   print its three `ok` lines and exit 0. A loaded host can miss the journey's
   own timing budget, so record a run that fails only on timing rather than
   treating it as a behavior change.
4. Run the repository CI gate (ShellCheck plus the syntax check over every add-on
   script); it must pass on the PR head. The moved scripts carry
   `# shellcheck source=` directives for sibling fork libraries that did not
   move, so the gate exempts `SC1091` (and the one follow-on `SC2034` those
   missing sources cause) for the verbatim copies only, never editing them.

Do **not** run `tests/fm-sentinel-herdr-restart-live-e2e.test.sh`: it restarts a
live terminal server. Do not run `fm-sentinel.sh loop`, `tick` or `reconcile`
against a real home, and never install or touch a service unit from here; the
moved script is dormant until the fork hook lands.

## For the fork hook lane

The later hook must keep the exact CLI and argv (`FM_HOME=<home> fm-sentinel.sh
tick|loop|reconcile|unit`) and the `state/` names above, exec'ing
`sentinel/bin/fm-sentinel.sh`. Re-run the side-by-side proof above immediately
before the served path swaps, and keep this README's proof sections honest when
the proof moves.
