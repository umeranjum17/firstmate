---
name: juggernaut-evals
description: Verification skill for Juggernaut's own behaviour. Load before claiming a change to Overwatch behaviour, a rename, or the install path works, and when the captain asks whether Juggernaut still does what it should. Runs the behaviour evals as done-done journeys on real tools in a scratch home; deterministic cases pass or fail, judged cases are graded from real output by done-done's judge.
user-invocable: false
metadata:
  internal: true
---

# Juggernaut behaviour evals

On demand only: no CI job runs these, because CI holds no model keys and the judge is a model.
Each case is a done-done journey in `.done-done.yaml`; its script is in `journeys/evals/`.
Run with real tools, a scratch board and a scratch home, never the captain's home.
`journeys/evals/lib.sh` makes the scratch home on disk (not `/tmp`, which is memory) and writes done-done's step record.
done-done keeps each case's evidence in its evidence root; cite that folder in a report.

## Run

- `done-done run evals-old-names` and `done-done run evals-fresh-home`: deterministic cases, plain pass or fail, no judge.
- A judged case runs with `done-done verify <journey> --outcome "<the case's outcome below>"`.
  The judge is done-done's own; build no other.
  Default to Haiku: `done-done init --judge claude-code --judge-model claude-haiku-5-5`.
  For one hard case set Sonnet the same way (`--judge-model claude-sonnet-5-5`) for that run, then set Haiku back.
- The captain's saved judge choice stands: change it only when the captain asked for this run.

## Cases

| # | Case | Grading | Status |
|---|------|---------|--------|
| 1 | Overwatch creates, answers and closes tickets through `juggernaut-axi` and the board | judge | follow-up |
| 2 | Overwatch designs a screen through first-draft and posts it to sign-off | judge | follow-up |
| 3 | Overwatch dispatches a task through done-done proof and merge-card | judge | follow-up |
| 4 | Overwatch routes work to the right Squad Lead | judge | follow-up |
| 5 | Old skill, command and variable names resolve to the new ones (`evals-old-names`) | pass/fail | live |
| 6 | A fresh home reaches a working fleet from one install (`evals-fresh-home`) | pass/fail | live |

A judged case drives Overwatch in a scratch home and board, saves the transcript and captures as evidence, and states the outcome the judge grades, for example case 1: "a ticket was created, answered and closed, and the board shows it closed".
Add a judged case as a journey script beside the live two, wire it in `.done-done.yaml`, and flip its row to live.
Write no unit, snapshot or mock test; a case that only runs a test script is code-only and done-done refuses it.
