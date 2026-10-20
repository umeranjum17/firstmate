---
name: done-done-verify-firstmate-addons
description: Verify firstmate-addons changes through their executable integration journeys and capture output for review.
---

# Verify firstmate-addons

## Feature map

- [Incremental fleet-pulse chat export](features/incremental-fleet-pulse-chat-export.md): run `bash fleet-pulse/tests/chat-tsv.test.sh`; it uses synthetic transcripts and a disposable Git home, proves append/idempotence and redaction, and never reads real transcripts.

## Procedure

Run the feature's integration journey from the repository root and save its output under done-done's run evidence directory.

## Safety

Use synthetic transcript fixtures only. Never use a real home or transcript directory for this proof.
