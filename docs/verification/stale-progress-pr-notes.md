# Stale-progress PR body notes

Core files edited and rationale:

- `bin/fm-watch.sh`: loads the thin progress add-on, consumes activity for frozen-pane and busy-age monitoring, and clears generation-scoped observation state during pruning.
- `bin/fm-watch-progress-lib.sh`: shares independent activity absorption across normal and away monitoring, requires positive validation execution evidence, and preserves a pre-scan observation cutoff for all four activity sources.
- `bin/fm-crew-state.sh`: exposes the existing recent-active-step verdict as an explicit execution component without changing the semantic working state; coarse, quiet, and missing-activity records do not receive it.
- `bin/fm-spawn.sh`: sends ordinary Pi text, thinking, and tool-call streaming deltas through the existing throttled, generation-bound progress writer alongside native adapter progress. It does not synthesize completed turns or alter busy state.

Declared waits and captain-held lanes retain their existing bounded wait and ownership handling. No footer/token parsing, retries, fallback backend, or monitoring subsystem is introduced.
