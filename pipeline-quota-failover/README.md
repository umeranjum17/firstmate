# pi-quota-failover

Drop-in pi wrapper for the no-mistakes pipeline agent. It runs the real pi and moves to the next chain model when a call hits a quota error or goes silent.

## Quota pre-check

Before each route is called, `quota-axi --provider <prefix> --json` is asked about that route's provider. A route whose
`effectiveAvailability` has `runway.status` `exhausted_now` for `all_models` or its own `model:<id>` scope is skipped
without a pi call and gets a quota marker.

Fail-open cases (the route is tried as before, one log line says so):

- `quota-axi` is missing, exits non-zero (for example `error: unsupported provider: <name>` for a pi provider name it does not know) or takes longer than 10s. The wrapper maps the pi provider `openai-codex` to quota-axi's `codex`; other names pass unchanged.
- `jq` is not installed; the pre-check is off for every route.

An answer that is not parseable JSON is treated as not exhausted, without a log line.

## Idle watchdog

A pi call that writes no stdout and no stderr for `PI_QUOTA_FAILOVER_IDLE_SECS` (default 120) is ended with TERM to pi
and its descendants, then KILL of the same set after a 5 s grace. A stall is not a quota error: the chain moves on to the next model for that
call only and writes no quota marker, so the stalled route is tried again on the next call. A stall on the last route is retried up to `PI_QUOTA_FAILOVER_STALL_RETRIES` times (default 3, four calls total) before the call fails. Only a real quota error
(or quota-axi `exhausted_now`) writes a marker. pi stays in the wrapper's process group, so a group kill of the wrapper
reaches it.

The watch starts at the call's first byte, with no separate start limit. Before the extension change below, the silence
between pi's session header and `agent_start` was 5 s to 134 s on this host (pi-hermes-memory's sync: 91.5 s with no
prompt, 5.0 s with five other pi processes alive), so the 120 s watch killed those starts. Now it is about 1 s (session
header 1.0 s after pi starts, `agent_start` 82 ms later; measured 2026-10-18).

## Extensions

Every call runs `pi -ne` plus `-e <path>` for each extension pi would load here, except `pi-hermes-memory` (dropped by its
package source, `npm:pi-hermes-memory`, because its `session_start` sync ran before `agent_start`). The set is read at
call time from `pi list` (user packages and their manifests), the user extensions dir (`fm-rm-guard` and
`fm-literal-delete` load there), the settings `extensions` array and pi's built-ins, minus any `-builtin:<name>` in the
settings. If the list cannot be read, pi runs as before and one log line says why.

Not included: project-level `.pi/extensions/`. pi loads those only for a trusted project, and `pi list` reports user
packages only, so a pipeline call run from a trusted checkout that has them loses them under `-ne`. The firstmate
checkout does (`fm-calm`, `fm-branch-supervision`).
