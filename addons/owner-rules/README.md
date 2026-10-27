# owner-rules

Three brief-time rules are enforced when a lane's brief is created, not left as prose. The merge gate and publication check are described below.

1. **Owner ask.** A lane (ship or scout) must serve a named owner ask: its backlog item (the entry whose
   id equals the task id in `data/backlog.md`) has a title starting `[captain-ask]`, or its title or body
   names a `MainNNN` order.
2. **Hierarchy.** Every non-scout lane item whose title does not start `[captain-ask]` needs a body line
   `parent: <backlog item id>` naming an item in the same backlog, or `parent: upkeep` for true upkeep.
   Owner asks are epic roots; scout lanes and secondmate charters are exempt from this rule.
   `bin/fm-owner-rules-tree.sh <backlog-file>` prints each parent chain and lists items with absent,
   missing, or cyclic parents.
3. **Risk reason.** A ship lane in `--mode no-mistakes` needs one body line `risk: <reason>` with reason
   one of `release`, `security`, `migration`, `large-change`, `shared-protocol`, `fork-repo` (any PR to the
   Firstmate fork, whose required check "PR must be raised via no-mistakes" demands it). Otherwise use direct-PR plus a
   done-done check. Scouts are exempt; secondmate charters are exempt from the brief-time rules.

A refusal exits 1 before `fm-brief.sh` writes `data/<id>/brief.md`, with a one-line reason on stderr.

- `bin/fm-owner-rules-lib.sh` - `fm_owner_rules_check <data> <id> <mode> <kind>`.
- `bin/fm-owner-rules-tree.sh <backlog-file>` - read-only hierarchy report for every backlog item.
- Seam: `brief-inherit`'s `fm_brief_inherit_shared` (already called by the fork's `fm-brief.sh`) calls it when
  `config/owner-rules` exists. Without that file the check is a no-op, so an unmodified upstream Firstmate is
  unaffected. A marker whose lib is missing stops the scaffold. Needs the brief-inherit seam.
- `install.sh [--dry-run] <fm-home>` writes `config/owner-rules` and makes `config/merge-gate` run the merge gate below first, then the
  home's previous gate (moved to `config/merge-gate.pre-owner-rules`); `uninstall.sh` removes the marker and gives the gate back.
- Design flag: a backlog body line `design: required` or `design: none`. `required` adds `Design discovery: required` to the brief; a design-like line with any other value is refused (`owner-rules: design: must be required or none (backlog item for <id>)`); no line on design-sounding work only prints a stderr note. Nothing blocks at merge time. Test: `tests/design-flag.test.sh [<firstmate-checkout>]` (the checkout adds the real `fm-brief.sh` journey).
- Test: `tests/owner-rules.test.sh <firstmate-checkout>` drives the checkout's real `fm-brief.sh`.
- Done-done proof: `FM_TEST_FORK=<firstmate-checkout> done-done run owner-rules-hierarchy` records the real brief journey and hierarchy report.

## Merge gate (slice 2)

3. **Locally signed done-done receipt.** The gate requires a sealed clean run at the exact merge head and refuses an unsigned or changed receipt, even when `merge-card receipt` accepts its run record.
   Run `fm-owner-rules-gate.sh init-key` once in the captain's home to create its local key pair.
   After the passed-proof recipe succeeds on the captain's machine, `fm-owner-rules-gate.sh sign <id> <head> <pr-url|->` signs the normalized receipt with the private key at `${FM_MAIN_HOME:-$FM_HOME}/config/owner-rules-proof.key`.
   The gate verifies it with `${FM_MAIN_HOME:-$FM_HOME}/config/owner-rules-proof.pub` and binds the signature to the task, PR scope, exact head, and receipt contents.
   Keep both keys out of the repository; the private key stays on the captain's machine.
   A missing signature can be created only by running the explicit signing command after the proof recipe succeeds.
   `merge-card receipt-json <id> <head>` prints the normalized receipt used by this signature check.
   A merge whose Checks block says `screen: none` still requires a signed receipt for its text-only Evidence card (`merge-card screen-none`).
   A no-op without `config/owner-rules`. Needs the sibling `merge-card/` of this checkout.
4. **Checks-lint PASS.** After receipt authorization, the gate reads `$FM_HOME/data/checks-gate.log` (never reruns lint) and refuses unless the
   newest row naming the PR url at the merge head is a `pass`, so a later fail takes the verdict back and a `card` row is not a verdict (a local merge matches the report-file rows of its own task folder; they carry no head).
   `screen: none` exempts capture only. PR merges also require a passed-proof Evidence card on the fleet board, configured by `FM_FLEET_BOARD`, then the one-line `$FM_HOME/config/fleet-board`, then the main home board (`${FM_MAIN_HOME:-$HOME/firstmate}/config/fleet-board`); a screen-free PR with a signed receipt gets a text-only card automatically. Local merges use the same signature and lint checks but do not need a board card. Refusal:
   `owner-rules: no checks-lint PASS for <pr> at <head>; run FM_HOME=<home> <XDG_DATA_HOME>/fm-merge-on-green/checks-lint.sh <pr-url> <home>/data/<id> then merge again`.
- Test: `tests/owner-rules-gate.test.sh` covers receipt and lint refusals, verifies the Evidence-card hint is an executable absolute path, and scans gate/check scripts for bare add-on command hints. `tests/gate-contract.test.sh` uses installed `sign-off-axi` to post a merge-card-shaped Evidence card, then proves matching commits pass and mismatches refuse; it skips only when the CLI is absent.
- Roll out a new refusing gate with `config/owner-rules-canary`, one exact `FM_HOME` path per line; only listed homes enforce the new Evidence-card refusal while other homes retain prior behavior. A canary may self-waive that refusal by writing a future UTC expiry (`YYYY-MM-DDTHH:MMZ`) to `config/owner-rules-canary-waiver`; expired or malformed waivers do not apply. Remove the waiver after resolving any issue, then add homes to the canary file to expand rollout. With no canary config, all homes retain today's enforcement.

## Lavish refusal: secondmate notes and merge-card posts

With `config/owner-rules` present, `status-wait-check` checks secondmate report notes before append, and `merge-card` checks decoded card strings before posting or restoring a card.
`bin/fm-owner-rules-text-check.sh` reads proposed text on stdin and refuses HTTP(S) links to port 4387 or the word `lavish-axi`, ignoring case.
It exits 1 and prints `owner-rules: Lavish publication refused; use the sign-off board (sign-off-axi) instead`.
Other text, including clean sign-off links, passes; read errors retain their diagnostics and exit code.
This covers secondmate notes and merge-card posts only: raw status appends, report files (including `--doc` contents), and `lavish-axi` commands are not intercepted.
Retiring existing registrations and removing old files remain outside this publication check.

Existing homes need no reinstall when their add-on checkout is updated: the report hook and merge-card shims execute files from that checkout, and the existing owner-rules marker enables the checks.
Homes without the marker enable it with `install.sh <fm-home>`; the report helper still needs the existing status-wait-check fork hook.
Run `bash tests/no-lavish.test.sh` from this directory for the executable contract, note hook, and real sign-off board journey.
Set `FM_TEST_FORK=<Firstmate checkout>` to also prove the real secondmate helper refuses before writing status; `FM_TEST_KEEP=1` preserves isolated fixtures for diagnosis.
Capture the real commands and their outputs with `FM_PROOF_FORK=<Firstmate checkout> done-done run owner-rules-publication`, then check its `publication.txt` with done-done.

## Leads skill (slice 3)

`skill/SKILL.md` tells the leads both rules, the exact refusal lines and the one-step fix for each. No add-on installs skills, so
there is no installer; link it into a home once: `ln -s <firstmate-addons>/owner-rules/skill <fm-home>/.agents/skills/firstmate-addons-owner-rules`.
A home that linked the old name relinks with one line: `ln -sfn <firstmate-addons>/owner-rules/skill <fm-home>/.agents/skills/firstmate-addons-owner-rules && rm <fm-home>/.agents/skills/owner-rules`.
`tests/owner-rules.test.sh` fails if a refusal line quoted in the skill stops matching the lib or the gate.
