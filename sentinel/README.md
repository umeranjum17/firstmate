# sentinel

The restart-recovery add-on, as a thin wrapper. The supervisor runs **outside**
the agent runtime, so it survives a runtime restart that kills every agent and
watcher in the runtime server's process tree. It re-arms supervision: it
reconciles the home's direct reports, relaunches a lane that came back outside
its recorded worktree, nudges a lane whose turn was lost, and wakes the primary
session.

The sentinel itself lives in the Firstmate checkout (`bin/fm-sentinel.sh`).
This add-on holds no copy of it. `bin/fm-sentinel.sh` here only finds that
checkout and runs its script with the same arguments, so Firstmate updates apply
with no merge. The fork still runs its own copy until the fork hook lands; this
directory stays dormant until then.

## Layout

- `bin/fm-sentinel.sh` — the wrapper. It runs `<checkout>/bin/fm-sentinel.sh`
  with the same argv and exit code. The checkout is `FM_CODE_ROOT`, or `FM_HOME`
  when that is unset. With neither set, or no `bin/fm-sentinel.sh` there, it
  prints a message to stderr and exits 2.
- `tests/fm-sentinel-wrapper.test.sh` — hermetic: a stub checkout proves the
  argv and `FM_HOME` pass-through, the `FM_HOME` default, and the exit 2 failure.
  It starts nothing and never touches Herdr.

The sentinel's own CLI, state files, knobs and recovery behavior are documented
in the Firstmate checkout (`bin/fm-sentinel.sh` header). They are not repeated
here, so they cannot drift from it.

## Usage

    FM_HOME=<home> [FM_CODE_ROOT=<checkout>] sentinel/bin/fm-sentinel.sh tick|loop|reconcile|unit

`unit` prints the user-service definition whose `ExecStart` runs the checkout's
`fm-sentinel.sh loop` directly, not this wrapper. Install that unit only from the
checkout, and only when the fork hook is live.

## Checks

- `bash sentinel/tests/fm-sentinel-wrapper.test.sh` — the hermetic wrapper test.
- `FM_CODE_ROOT=<checkout> sentinel/bin/fm-sentinel.sh unit` prints the same
  bytes as `<checkout>/bin/fm-sentinel.sh unit` (no service is installed).
- Zero copied upstream lines: no non-blank, non-comment, 20-character-or-longer
  line in `sentinel/` matches a whole line of any upstream file.

Do not run the sentinel's `loop`, `tick` or `reconcile` against a real home from
here. Do not install a service unit from here.
