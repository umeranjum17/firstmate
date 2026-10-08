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

The earlier boundary replay did not drive an actual hung **running validation record** or synchronize the precise concurrent scan boundary live. The captain subsequently accepted automated evidence for those cases. The **captain-held-lane journey is explicitly deferred to the next slice** and must not be claimed newly implemented or proven live in the PR body.

## Candidate-bound ordinary Pi streaming replay

At `fb4e95712c2d0a0bd1ac370759b1fd1de9150166`, the first authorized live attempt passed; no second model request was made. A real Pi worker used `openai-codex/gpt-5.5` with extension discovery disabled and the candidate's unchanged, `fm-spawn.sh`-generated worker extension explicitly loaded. Existing authentication was used without credential copying or login changes. The guarded disposable home, private tmux server, real watcher and real crew-state entrypoints were confined to the test worktree; no Herdr lifecycle or other pipeline ran.

One unfinished response produced 730 ordinary `text_delta` events over an observed 18.06 seconds, with 17 generation-bound progress-marker updates, exceeding the six-second busy-age and six-second wedge bounds. There was no completed-turn marker, the watcher remained alive, and its stdout contained no stale alert. Exact watcher log lines and candidate identity are retained in `/home/umer/.no-mistakes/evidence/01M4E0PYS32NKAC69Q1R5M33FY/live-pi-streaming.json`, including:

```text
[2026-10-08T20:17:20+0400] absorbed stale (recent worker progress): primary:fm-stream
[2026-10-08T20:17:35+0400] absorbed stale (recent worker progress): primary:fm-stream
```

Focused existing behavioral checks passed:

- `tests/fm-watch-triage.test.sh`: `test_stale_terminal_status_overridden_by_active_run` proves active validation stays quiet but a hung running record escalates; `test_nonterminal_stale_provably_working_absorbed_then_escalated` checks the non-terminal wedge path.
- `tests/fm-crew-state.test.sh`: `test_daemon_claim_over_live_run_reads_run_alive` checks recent, quiet and missing execution evidence through the real crew-state interface.
- `tests/fm-watch-triage.test.sh`: `test_progress_observation_keeps_concurrent_writes` checks post-scan eligibility for all four activity sources.
- `tests/fm-watch-triage.test.sh`: `test_captain_held_never_rechecked_while_away_record_exists` and `test_live_captain_held_first_sight_silenced_by_away_record` check existing held-lane behavior with fixtures, not new implementation or live acceptance.
- `tests/fm-busy-adapter-wiring.test.sh`: `test_pi_extension_semantic_lifecycle` executes the generated extension's ordinary streaming and lifecycle handlers.

Temporary focused runners, generated interfaces, disposable homes and the owned tmux server were removed. No product failure was reproduced and no upstream core file was edited in this replay. No broad suite, lint or static analysis was run.
