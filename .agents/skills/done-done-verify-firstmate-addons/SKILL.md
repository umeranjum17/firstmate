---
name: done-done-verify-firstmate-addons
description: Verify firstmate-addons changes through their executable integration journeys and capture output for review.
---

# Verify firstmate-addons

## Feature map

- [Pipeline route switch](features/pipeline-route-switch.md): run `bash pipeline-quota-failover/tests/switch-route.test.sh`; it uses a fixture config and a stub pi, proves that a switch edits only the agent and model keys, writes a backup first and restores it, and never touches a real config or model.
- [Incremental fleet-pulse chat export](features/incremental-fleet-pulse-chat-export.md): run `bash fleet-pulse/tests/chat-tsv.test.sh`; it uses synthetic transcripts and a disposable Git home, proves append/idempotence and redaction, and never reads real transcripts.
- Receipt hooks across the fork boundary: with a full Firstmate checkout on disk and compatible `tasks-axi` on `PATH`, run `FM_TEST_FORK=<checkout> bash receipts/tests/receipts-hook-e2e.sh`; it clones the real fork scripts and proves done acceptance, local delivery, both PR-merge call sites, the PR candidate hook (outside-origin prints PR_HEAD, same-repo and unverified print nothing) through the real `bin/fm-pr-check.sh`, and absent-add-on no-op behavior; `done-done run receipts-pr-candidate` runs it and keeps the transcript.
- [Quota failover screen matching](features/quota-failover-screen-match.md): run `bash quota-failover/run-proof.sh`; it invokes the real failover against wrapper text and Claude's own limit banner in a disposable fixture home.
- [Persisted pipeline route](features/pipeline-route.md): run `bash pipeline-quota-failover/tests/pi-quota-failover-route.test.sh`; it uses a stub pi and quota-axi in a throwaway HOME, proves the chain is the route the config holds and that an `openrouter/*` route keeps the deepseek idle limit, and never calls a real pi or reads a real config.
- [Fleet dashboard live core](features/fleet-dashboard-live-core.md): run `done-done run core` (`bash fleet-dashboard/run-core-proof.sh`); it seeds a throwaway Firstmate home, serves this checkout's dashboard, and captures the lanes on the Board, the Stuck and Waiting tabs, the lane cap beside a home's count, the queue reasons on Insights and the Tickets board (backlog mapping and the ask list as Waiting on captain) in headless Chrome at 390px and 1280px.
- [Claude accounts quota view](features/claude-accounts-quota.md): run `bash claude-accounts/tests/claude-accounts.test.sh`; it uses a fixture muxr registry and a stub quota-axi, proves 5h and 7d left per account and a recorded failure cause, and never opens a login folder.
- [Claude accounts chooser](features/claude-accounts-pick.md): run `bash claude-accounts/tests/claude-accounts-pick.test.sh`; it uses a fixture registry and stub quota-axi, proves the most-runway pick, the switch when one account runs low, and install/uninstall of config/account-pool.
- [Claude accounts refresh timer](features/claude-accounts-timer.md): run `bash claude-accounts/tests/claude-accounts-timer.test.sh`; it installs the units into a throwaway tree with a stub systemctl, proves dry run, rerun and uninstall, and never touches the host's timers.
- [Merge evidence one card per PR](features/merge-card-one-card-per-pr.md): run `bash merge-card/tests/merge-card-e2e.sh`; it uses a fixture board and stub sign-off-axi, proves a new head leaves one live card and archives the old one (posted one at a time, never `--replace`), two PRs keep two cards, and the internal-change title names repo and PR. Also run `bash merge-card/tests/real-board.test.sh` for the same journey with the real sign-off-axi on a seeded temp board.
- [Legacy merge-card retitle](features/merge-card-retitle.md): run `bash merge-card/tests/retitle-old-cards.test.sh` for the stubbed regression, then `done-done run merge-card-retitle` for the seeded fixture journey through the real sign-off-axi; together they prove dry-run safety, link and key mapping, skipping, evidence retention, archival, and idempotence.
- Merge-gate lint pin: run `bash merge-on-green/tests/checks-lint-parity.test.sh`; it uses a fake gh and isolated homes, runs the pinned done-done-axi lint against size fixtures (plain, generated, routes, oversized) and proves its PASS/FAIL verdicts match the legacy lint.
- Fleet contract check: run `done-done run fleet-contract-check` (`bash fleet-contract-check/run-proof.sh`); it runs the real script on the installed fork in a throwaway HOME (one ok or FAIL line per caller) and then the fixture journey that breaks a caller and must name it.
- Sign-off hold card: run `FM_CODE_ROOT=<Firstmate checkout> bash signoff/tests/fm-procevent-signoff.test.sh`; it uses a stub sign-off-axi that rejects a raise without `--ask-ref` (the real VALIDATION_ERROR), proves a hold raises its card with the hold task id as ask reference, and never touches a real board.
- Task priority check: run `bash task-priority/tests/task-priority.test.sh`; it installs the check into a throwaway `XDG_DATA_HOME`, proves a task add without `--priority 0-3` is refused naming the flag, that a priority passes with release `later`, and that an explicit `release:` line is kept.

## Procedure

Run the feature's integration journey from the repository root and save its output under done-done's run evidence directory.

## Safety

Use synthetic transcript fixtures only. Never use a real home or transcript directory for this proof.
