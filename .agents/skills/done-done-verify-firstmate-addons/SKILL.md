---
name: done-done-verify-firstmate-addons
description: Verify firstmate-addons changes through their executable integration journeys and capture output for review.
---

# Verify firstmate-addons

## Feature map

- [Pipeline route switch](features/pipeline-route-switch.md): run `bash pipeline-quota-failover/tests/switch-route.test.sh`; it uses a fixture config and a stub pi, proves that a switch edits only the agent and model keys, writes a backup first and restores it, and never touches a real config or model.
- [Incremental fleet-pulse chat export](features/incremental-fleet-pulse-chat-export.md): run `bash fleet-pulse/tests/chat-tsv.test.sh`; it uses synthetic transcripts and a disposable Git home, proves append/idempotence and redaction, and never reads real transcripts.
- [Quota failover screen matching](features/quota-failover-screen-match.md): run `bash quota-failover/run-proof.sh`; it invokes the real failover against wrapper text and Claude's own limit banner in a disposable fixture home.
- [Persisted pipeline route](features/pipeline-route.md): run `bash pipeline-quota-failover/tests/pi-quota-failover-route.test.sh`; it uses a stub pi and quota-axi in a throwaway HOME, proves the chain is the route the config holds and that an `openrouter/*` route keeps the deepseek idle limit, and never calls a real pi or reads a real config.
- [Claude accounts quota view](features/claude-accounts-quota.md): run `bash claude-accounts/tests/claude-accounts.test.sh`; it uses a fixture muxr registry and a stub quota-axi, proves 5h and 7d left per account and a recorded failure cause, and never opens a login folder.
- [Claude accounts chooser](features/claude-accounts-pick.md): run `bash claude-accounts/tests/claude-accounts-pick.test.sh`; it uses a fixture registry and stub quota-axi, proves the most-runway pick, the switch when one account runs low, and install/uninstall of config/account-pool.

## Procedure

Run the feature's integration journey from the repository root and save its output under done-done's run evidence directory.

## Safety

Use synthetic transcript fixtures only. Never use a real home or transcript directory for this proof.
