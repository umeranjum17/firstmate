# alerts

The model-outage alerts add-on — the observation that notices a lane stopped by
a model or provider outage and raises one grouped wake to the home, moved
**verbatim** out of the Firstmate fork into this add-on repository. Nothing
calls it from here yet: the fork's `bin/fm-watch.sh` still sources its own copy
of the library and runs it every scan, and the fork-side hook that will point
the watcher at this directory lands in a later PR. Until that swap this
directory is dormant, and every moved byte below is identical to the fork copy
the live watcher runs today.

## Layout

- `bin/fm-model-outage-lib.sh` — the observer. `fm_model_outage_tick` reads each
  recorded lane once per 60-second scan, before the watcher's stale suppression,
  matches explicit provider/harness outage banners in a lane's visible viewport,
  and appends one grouped wake naming every lane failing with the same
  normalized error. `fm_model_outage_text` normalizes one error to a single
  printable line.
- `tests/fm-model-outage-live-e2e.test.sh` — the opt-in credentialed live
  journey. Moved verbatim and **never run from here**: it drives live agents
  (see the proof note).

## Frozen contract (identical to the fork)

- Interface the watcher uses: `bin/fm-watch.sh` sources the library from its own
  `bin/` directory and calls `fm_model_outage_tick` with no arguments once per
  cycle, before stale suppression. A non-zero return means the scan could not be
  recorded; the watcher logs one line and continues the cycle, it never aborts.
- The library sources its two sibling helper libraries (`fm-timeout-lib.sh` and
  `fm-composer-lib.sh`) from its own directory, and reads the composer library's
  usage-limit banner pattern rather than re-declaring it, so the outage alert
  cannot drift from the composer furniture. Those sibling files did not move, so
  the dormant copy only runs with the fork `bin/` tree beside it.
- It reads the watcher's `STATE` directory and the watcher-provided helpers for
  lane metadata, busy state, bounded backend reads, visible capture, composer
  normalization, pane hashing, and wake-queue append (`fm_busy_token_valid`,
  `fm_backend_target_of_meta`, `fm_backend_of_meta`, `fm_meta_get`,
  `fm_busy_current_gen`, `fm_run_timed`, `fm_backend_agent_state`,
  `fm_backend_visible_capture_supported`, `fm_backend_visible_capture`,
  `fm_composer_normalize_trim_var`, `_fm_composer_leftbar_floor_row`,
  `hash_pane`, `fm_wake_append`, `wake`). It owns no settings, model changes, or
  recovery: the existing blocked/wait escalation owns later attention.
- Scope and cadence: only lanes whose meta names the `opencode` harness are
  observed, each read bounded to 3 seconds; a scan runs at most once per 60
  seconds. A mid-turn lane is matched against the usage-limit banner alone
  (the one outage that persists while a limited lane sits retrying); every other
  banner is named only once the lane is idle.
- Alert line appended to the wake queue, one per normalized error episode:
  `check: model outage affected=[<id>,<id>,...]: <normalized error>` under wake
  key `model-outage-<hash>`; a lane joining an alerted episode sends one updated
  grouped wake, a recovered lane leaves the record, and a lane whose endpoint is
  dead or missing is dropped without an alert.
- State under `$STATE/.model-outages/`, names unchanged: reads and writes
  `.scan-at`, `lane-<id>` (`<target>|<gen>|<hash>`), and `alert-<hash>`; a
  symlinked directory disables the observer, so a second monitor is never
  started.

## Provenance: byte-identical to the fork

Every moved file was compared byte for byte (sha256 plus file mode) against its
fork source at `umeranjum17/firstmate@0689b4b9d9ab3594f846cfe07c400edfa58244bf`
at move time:

| moved file | fork source | mode | sha256 (fork = here) |
| --- | --- | --- | --- |
| `alerts/bin/fm-model-outage-lib.sh` | `bin/fm-model-outage-lib.sh` | `100644` | `4c6fd425f8104d6ad3dd8e7310b9056d421b3d13b91982327ae9fb311c455365` |
| `alerts/tests/fm-model-outage-live-e2e.test.sh` | `tests/fm-model-outage-live-e2e.test.sh` | `100755` | `9573d0ecb87c72581a0ae8c2140ab89a396e110265c90c0b0b8c517b3a79420a` |

Treat any future diff against the fork file as a contract change, not a
refactor.

## Side-by-side proof (re-run before the hook swaps the served path)

1. Unpack the fork tree at the commit above into two scratch roots:
   `git -C <fork> archive 0689b4b9d9ab3594f846cfe07c400edfa58244bf | tar -x -C <rootA>`,
   then `cp -a <rootA>/. <rootB>/`.
2. In `rootB` only, overwrite `bin/fm-model-outage-lib.sh` and
   `tests/fm-model-outage-live-e2e.test.sh` with the moved files; `diff -r <rootA>
   <rootB>` must be empty, and every file's sha256 and mode must equal the fork's.
3. Run the fork's `tests/fm-busy-adapter-wiring.test.sh` in a scratch root; it
   exercises this library's wiring through its `test_model_outage_*` cases and
   must print their `ok` lines. A heavily loaded host can miss the earlier
   secondmate stall-gate case's own checkpoint timing budget; that failure is a
   timing budget, not a behavior change — record the output, and the eight
   `test_model_outage_*` cases are the ones that exercise this library.
4. Run the repository CI gate (ShellCheck plus the syntax check over every
   add-on script); it must pass on the PR head. The moved library carries a
   `# shellcheck source=` directive for a sibling fork library that did not
   move, so the gate exempts `SC1091` for the verbatim copy only, never editing
   it.

Do **not** run `tests/fm-model-outage-live-e2e.test.sh`: it drives live hosted
agents and a named lab session. Do not source this library into a live
supervision process, and never point a home at the moved copy; it is dormant
until the fork hook lands.

## For the fork hook lane

The later hook must keep the exact interface above (source the library from its
`bin/` and call `fm_model_outage_tick` with no arguments before stale
suppression) and the `$STATE/.model-outages/` names and alert line above. Re-run
the side-by-side proof immediately before the served path swaps, and keep this
README's proof sections honest when the proof moves.
