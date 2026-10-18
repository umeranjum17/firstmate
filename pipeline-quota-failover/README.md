# pi-quota-failover

Drop-in pi wrapper for the no-mistakes pipeline agent. It runs the real pi and moves to the next chain model when a call hits a quota error or goes silent.

## Quota pre-check

Before each route is called, `quota-axi --provider <prefix> --json` is asked about that route's provider. A route whose
`effectiveAvailability` has `runway.status` `exhausted_now` for `all_models` or its own `model:<id>` scope is skipped
without a pi call and gets a quota marker.

Fail-open cases (the route is tried as before, one log line says so):

- `quota-axi` is missing, exits non-zero (for example `error: unsupported provider: claude-bridge`) or takes longer than 10s.
- `jq` is not installed; the pre-check is off for every route.

An answer that is not parseable JSON is treated as not exhausted, without a log line.

## Idle watchdog

A pi call that writes no stdout and no stderr for `PI_QUOTA_FAILOVER_IDLE_SECS` (default 120) is ended with TERM to pi
and its descendants, then KILL of the same set after a 5 s grace. A stall is not a quota error: the chain moves on to the next model for that
call only and writes no quota marker, so the stalled route is tried again on the next call. A stall on the last route is retried once on that same route before the call fails. Only a real quota error
(or quota-axi `exhausted_now`) writes a marker. pi stays in the wrapper's process group, so a group kill of the wrapper
reaches it.
