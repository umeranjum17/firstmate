# owner-rules

Two owner rules enforced when a lane's brief is created, not left as prose. Slices 1 and 2 of 3 are below; slice 3 is the leads skill.

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
- `install.sh [--dry-run] <fm-home>` writes `config/owner-rules` and makes `config/merge-gate` run the merge gate below first, then the
  home's previous gate (moved to `config/merge-gate.pre-owner-rules`); `uninstall.sh` removes the marker and gives the gate back.
- Test: `tests/owner-rules.test.sh <firstmate-checkout>` drives the checkout's real `fm-brief.sh`.

## Merge gate (slice 2)

3. **Done-done receipt.** `bin/fm-owner-rules-gate.sh` refuses a merge (exit 1) unless the task folder
   `$FM_HOME/data/<id>/.done-done/runs/` holds a sealed clean done-done run at the merge head. That is merge-card's own
   `receipt_run` check (`merge-card receipt`: exit 0, clean, files captured, run id). It checks only that the receipt
   exists, not what it shows: merge-card posts the Evidence-tab card after the merge, and only when the proof is real.
   Refusal, naming the PR URL (`local merge <head>` with no PR):
   `owner-rules: no passed-proof receipt for <PR url>; run the done-done check and post the evidence to the sign-off Evidence tab first`.
   Exempt: a merge whose Checks block says `screen: none`, the skip merge-card's post already uses (`merge-card screen-none`).
   A no-op without `config/owner-rules`. Needs the sibling `merge-card/` of this checkout.
4. **Checks-lint PASS.** After the receipt, the gate reads `$FM_HOME/data/checks-gate.log` (never reruns lint) and refuses unless a
   `pass` row names the PR url at the merge head (a local merge matches the report-file rows of its own task folder; they carry no head).
   `screen: none` exempts the receipt only. Refusal:
   `owner-rules: no checks-lint PASS for <pr> at <head>; run FM_HOME=<home> config/fm-checks-lint.sh <pr-url> <evidence folder> first`.
- Test: `tests/owner-rules-gate.test.sh` installs into a temp home and runs the real `config/merge-gate` against a stubbed receipt.

## Leads skill (slice 3)

`skill/SKILL.md` tells the leads both rules, the exact refusal lines and the one-step fix for each. No add-on installs skills, so
there is no installer; link it into a home once: `ln -s <firstmate-addons>/owner-rules/skill <fm-home>/.agents/skills/owner-rules`.
`tests/owner-rules.test.sh` fails if a refusal line quoted in the skill stops matching the lib or the gate.
