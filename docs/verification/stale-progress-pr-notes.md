# Stale-progress PR body notes

Core files edited and rationale:

- `bin/fm-watch.sh`: loads the thin progress add-on, consumes activity for frozen-pane and busy-age monitoring, and clears generation-scoped observation state during pruning.
- `bin/fm-watch-progress-lib.sh`: shares independent activity absorption across normal and away monitoring, requires positive validation execution evidence, and preserves a pre-scan observation cutoff for all four activity sources.
- `bin/fm-crew-state.sh`: exposes the existing recent-active-step verdict as an explicit execution component without changing the semantic working state; coarse, quiet, and missing-activity records do not receive it.
- `bin/fm-spawn.sh`: sends ordinary Pi text, thinking, and tool-call streaming deltas through the existing throttled, generation-bound progress writer alongside native adapter progress. It does not synthesize completed turns or alter busy state.

Declared waits and captain-held lanes retain their existing bounded wait and ownership handling. No footer/token parsing, retries, fallback backend, or monitoring subsystem is introduced.

## Test-phase live evidence (8 October)

The task-private tmux server ran a real Pi RPC process without a model request, the real `fm-watch.sh` entrypoint and real `fm-crew-state.sh`, with public `fm-busy-event.sh` lifecycle/progress writes. No canned crew-state authority or other pipeline was used. Bounds were shortened to three seconds for busy age and wedge escalation; the external timer was sixteen seconds.

- A working pane verdict with a busy record but no activity escalated three consecutive times, with `demand-deep-inspection` on the third wake. Each wake was acknowledged through `fm-wake-drain.sh` before rearming; no timers or escalation counters were backdated.
- A declared external wait surfaced initially as a status signal, stayed quiet before its UTC bound, and rechecked after that bound without a wedge verdict.
- Rearming the same task rejected predecessor progress and lifecycle events without changing the replacement record or creating a progress marker.
- Ten concurrent current-generation progress writes kept the watcher alive and cleared escalation history. This proves live activity consumption, **not** the precise write-after-scan race; deterministic cutoff-race evidence remains fixture-only.

Evidence and the disposable driver are retained in `/home/umer/.no-mistakes/evidence/01M4E0PYS32NKAC69Q1R5M33FY/live-boundaries.json` and `live-boundaries.py`. All owned runtimes and worktree artifacts were cleaned up. No product failure was reproduced; no core files were edited in this test phase.

Remaining acceptance gaps: an actual hung **running validation record** was not driven because no authorized disposable validation job was available and this phase cannot initialize or control another pipeline. The exact concurrent scan boundary also remains unproven live. The overall live verdict remains **inconclusive**, not complete. The **captain-held-lane journey is explicitly deferred to the next slice** and must not be claimed proven in the PR body.
