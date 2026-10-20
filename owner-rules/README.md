# owner-rules

Two owner rules enforced when a lane's brief is created, not left as prose. Slice 1 of 3; the merge-gate
refusal and the leads skill section follow.

1. **Owner ask.** A lane (ship or scout) must serve a named owner ask: its backlog item (the entry whose
   id equals the task id in `data/backlog.md`) has a title starting `[captain-ask]`, or its title or body
   names a `MainNNN` order.
2. **Risk reason.** A ship lane in `--mode no-mistakes` needs one body line `risk: <reason>` with reason
   one of `release`, `security`, `migration`, `large-change`, `shared-protocol`. Otherwise use direct-PR plus a
   done-done check. Scouts are exempt; secondmate charters are exempt from both rules.

A refusal exits 1 before `fm-brief.sh` writes `data/<id>/brief.md`, with a one-line reason on stderr.

- `bin/fm-owner-rules-lib.sh` - `fm_owner_rules_check <data> <id> <mode> <kind>`.
- Seam: `brief-inherit`'s `fm_brief_inherit_shared` (already called by the fork's `fm-brief.sh`) calls it when
  `config/owner-rules` exists. Without that file the check is a no-op, so an unmodified upstream Firstmate is
  unaffected. A marker whose lib is missing stops the scaffold. Needs the brief-inherit seam.
- `install.sh [--dry-run] <fm-home>` writes `config/owner-rules`; `uninstall.sh` removes it.
- Test: `tests/owner-rules.test.sh <firstmate-checkout>` drives the checkout's real `fm-brief.sh`.
