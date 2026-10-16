# fleet-flow

The read-only fleet flow reader — the lifecycle, queue, bottleneck and capacity
JSON reader the dashboard consumes as its `fm-flow.v1` observation — moved
**verbatim** out of the Firstmate fork into this add-on repository. Nothing
calls it from here yet: the fork's `bin/fm-flow.sh` stays the live reader the
shipped dashboard runs, and the fork-side shim that will exec into this
directory lands in a later PR. Until that swap this directory is dormant, and
every moved byte below is identical to the fork copy the live reader runs
today.

## Layout

- `bin/fm-flow.sh` — the `--json` reader: FM_HOME plus recursively registered
  local homes in, one `fm-flow.v1` document out; no endpoint or cache writes.
- `tests/fm-flow.test.sh` — the fork's integration test for that reader over
  isolated durable records.

The reader sources `fm-classify-lib.sh`, `fm-tasks-axi-lib.sh` and
`fm-backlog-transition-lib.sh` from its own directory and runs the
home-addressed `fm-tasks-axi.sh` backlog consumer beside it; those fork files
did not move, so the moved copy only runs with them next to it (see the proof
below). The same is true of the moved test, which also drives the fork's
model/skill statistics and outcome-recording readers.

## Frozen contract (identical to the fork)

- CLI: `FM_HOME=<home> fm-flow.sh --json [--now <unix-seconds>] [--checks]
  [--capacity]`; every other invocation prints the usage line and exits 2.
- Output: one `fm-flow.v1` document with `homes`, `lanes`, `queue`,
  `bottlenecks`, `capacity` (null unless `--capacity`), `executed_24h`,
  `executed_7d`, `time_to_merge` (median, nearest-rank P85),
  `time_to_merge_by_home`, `trend_7d`, `trend_7d_by_home` and `limitations`;
  `at` carries the effective now.
- Read-only: no endpoint or cache writes. Missing or unavailable probes yield
  null with a limitation, never a fabricated zero; live capacity observations
  carry their own timestamp, independent of `--now`.

## Provenance: byte-identical to the fork

Every moved file was compared byte for byte against its fork source at
`umeranjum17/firstmate@0689b4b9d9ab3594f846cfe07c400edfa58244bf` at move time:

| moved file | sha256 at the fork commit | sha256 here |
| --- | --- | --- |
| `bin/fm-flow.sh` | `fa7ef5bf41d759b483393bccd7bc867daeb13111c87dd7c444ef66bd6a8ba4f1` | `fa7ef5bf41d759b483393bccd7bc867daeb13111c87dd7c444ef66bd6a8ba4f1` |
| `tests/fm-flow.test.sh` | `a0fdc3349fa899c9b12897797d2051187b1e321db70e8e136be6f7bd38e9e93d` | `a0fdc3349fa899c9b12897797d2051187b1e321db70e8e136be6f7bd38e9e93d` |

Treat any future diff against the fork file as a contract change, not a
refactor.

Contract change since the move (16 Oct, mem-gate-wrappers): the capacity
census reads the gate policy from the installed gate
`${XDG_DATA_HOME:-~/.local/share}/fm-host-memory/fm-mem-gate.sh` when it
exists (Main's `config/fm-mem-gate.sh` is then a one-line shim to it), else
from `config/fm-mem-gate.sh` as before, and `gate_source` names the file it
read. Both moved files now differ from the fork at that census only.

## Side-by-side proof (re-run before the served path swaps)

The acceptance proof runs the fork copy and this copy on the same synthesized
fixture homes with the same fixed `--now` and diffs the JSON byte for byte.
It also runs the moved test against the moved copy with the fork libraries
overlaid beside it.

One command (harness lives with this task's evidence):

```sh
bash /home/fixture/users/user-019/.treehouse/fixture-home/4/firstmate/data/addons-fleet-flow/parity/run-parity.sh
```

It must end with `ALL CHECKS PASSED`, with every `diff-*.txt` empty. Manual
recipe if the harness is gone:

1. Copy `bin/fm-flow.sh` and `tests/fm-flow.test.sh` from the fork at the
   commit above and `fleet-flow/` from this repo into two scratch dirs;
   verify sha256 of every moved file matches across both.
2. Overlay the rest of the fork's `bin/` (the reader's libraries and backlog
   consumer) next to both copies, never editing a moved file; the moved test
   needs the whole bin tree beside it.
3. Synthesize fixture homes: several lanes in different states (a live lane
   with keyed waits including a captain hold, a paused lane, an unstamped
   lane, reused task ids, a live-relaunched lane), a ledger with lifecycle
   rows plus one malformed row, queued/held/blocked backlog rows including an
   archived dependency, one home with no `config/fm-flow-check.sh`, one empty
   home, one with an unavailable alternate backlog backend, and one with a
   recorded PR head for `--checks`.
4. Pin `TZ=UTC LC_ALL=C` and freeze the clock, redirect `/proc` and `/tmp` to
   fixtures through a `PYTHONPATH` sitecustomize, and put PATH stubs for
   `gh-axi`, `systemctl` and `du` ahead of the real tools, so the two runs
   see one identical instant and one identical host census.
5. Run both copies with the same `--now` on each fixture — plain, `--checks`,
   `--capacity`, and both together — and diff stdout byte for byte. Assert
   the home is untouched across each run with a sha256 manifest taken before
   and after. Check the CLI contract (no flags, a bad flag, a missing or
   non-numeric `--now` value: usage line and exit 2) on both copies.
6. Run `tests/fm-flow.test.sh` against the moved copy with the fork bin tree
   beside it; it must print both of its PASS lines.

## For the fork shim lane

The shipped dashboard reads the flow observation by running the fork's
`bin/fm-flow.sh` with `FM_HOME` set to the reading home; the later shim must
keep that exact path and argv (it will exec `fleet-flow/bin/fm-flow.sh`).
Re-run the side-by-side proof above immediately before the served path swaps,
and keep this README's proof sections honest when the harness moves.

CI note: `.github/workflows/addons-ci.yml` ShellChecks and syntax-checks the
shell scripts in an add-on's top level and its `bin/` and `tests/`
subdirectories, so both moved files are covered; they passed at move time
with no exclusion.
