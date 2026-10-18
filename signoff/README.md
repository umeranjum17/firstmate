# signoff

The sign-off event handler: the adapter that turns sign-off board answers into
hold answers and merge-gate events. It runs through the process-event runner and
the keyed-answer intake, both owned by the Firstmate checkout.

## Status

- 0 copied upstream lines: no whole line of `bin/fm-procevent-signoff.sh` or
  `tests/fm-procevent-signoff.test.sh` matches kunchenguid/firstmate main.
- Dormant until the fork dispatch hook lands. Nothing here runs the adapter yet:
  the fork still ships and dispatches its own copy.
- The adapter resolves the runner, the intake and the libraries from the Firstmate
  checkout (`FM_CODE_ROOT`, defaulting to `FM_HOME`), not from its own directory.

## Seam (for the hook slice)

Upstream main has no sign-off source, its runner resolves adapters only under its
own `bin/`, and it does not call the adapter's `ack` after the intake. The fork
does all three. The hook slice has to exec this adapter with the fork's argv
(`poll`, `answers`, `ack`, `raise`) and keep the `ack` step. The full table and
the decision are in the seam record kept with the evidence.

## Tests

`tests/fm-procevent-signoff.test.sh` sources `tests/lib.sh` from the Firstmate
checkout and needs `FM_CODE_ROOT` set to it. It runs the adapter journey through
the real runner. The real-hold section is skipped when no beads-capable tasks-axi
and bd are installed.
