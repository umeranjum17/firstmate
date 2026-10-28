# Our rules for every brief

These lines are appended to every ship and Recon brief in this home.
They are the defaults this repo installs; edit this file freely, because the installer never overwrites it.

- Prove the change on the real product before reporting done, and name the evidence files you kept.
- Report a Checks block: outcome, repro, proof, evidence. Write "not proven: <cause>" rather than a pass nobody saw.
- Tests: integration and end-to-end only, driving the real product like a user; no unit, snapshot or mock-heavy tests, no duplicate coverage, and a new test only for a journey nothing covers, so the total count goes down over time (the merge gate refuses a PR that adds one).
- CI: run few jobs; skip drafts, skip body-only edits, cancel in-progress runs per PR, path-filter docs and evidence, and never run twice on main.
- One worker, one agent: start no sub-agents.
- Never run a recursive delete over home, a directory directly in it, `/`, or a bare `*` or `$VAR` target; keep a temp directory's literal path in the same command that deletes it.
- Kill only processes you started yourself in this task, never a parent, and never one found by name or pattern.
- Work only inside your own worktree, commit rather than stashing, and leave the worktree clean before reporting.
- If the brief leaves the method open and your method cannot give the user value, stop and report instead of substituting silently.
