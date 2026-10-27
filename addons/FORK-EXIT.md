# Fork exit list

Every change on `umeranjum17/juggernaut` main since merge-base `0397cb2b`
(161 commits, 218 changed files, +19,292/−1,942; fork `7a6e4cb0`, 2026-10-18), grouped by feature,
with its exit path and status. The rule behind the list: **the next core gap goes in an
add-on when it can; a fork patch only when it cannot — and it joins this list the same day.**

The retired add-ons repository is no longer a home for any add-on: `addons/` in this repository is the only one, installed by `addons/install-all.sh`, and a row whose exit path is an add-on is done as an add-on even where the fork still runs its own copy.

Exit paths: **add-on** `<dir>` (lives under this repository's `addons/` directory) · **offer to Kun** (upstream fix,
only with the owner's approval) · **stays** (thin hook or fork-only policy, nothing to move).
Statuses: **on fork** · **moved to** add-on + fork shim · **dormant copy** (add-on holds a
verbatim copy; the fork still runs its own) · **done** · **dropped** (add-on removed; the fork
copy still runs until a later fork PR drops it).

## How to add a row

The same-day rule: any new fork commit (or PR merge) lands a row here the same day, with its
exit path decided at entry. Reuse a row when the commit belongs to a listed feature; otherwise
add one. Source of truth: `git -C ~/juggernaut fetch origin && git -C ~/juggernaut
fetch kun && git -C ~/juggernaut log --oneline kun/main..origin/main`. Check each status
against the files, not against this table. PRs at the top until they are resolved.

## Priority: open and recent fork PRs

| Feature | Fork PR | Key files | Exit path | Status |
|---|---|---|---|---|
| Watcher check cadence calls the ask-default add-on's decide for each open ask | [92](https://github.com/umeranjum17/juggernaut/pull/92) (merged cfb646f2) | `bin/jg-watch.sh`, `docs/configuration.md`, `docs/scripts.md`, `tests/jg-watch-triage.test.sh` | stays (thin hook; the logic is add-on `ask-default`) | on fork |
| Ready-work nudge reads the fleet-flow add-on's counted lanes | [91](https://github.com/umeranjum17/juggernaut/pull/91) (merged 852a3488) | `bin/jg-watch.sh`, `tests/jg-watch-triage.test.sh` | stays (thin hook; the logic is add-on `fleet-flow`) | on fork |
| Live labs write `treehouse.toml` so lab copies stay under the lab root | [86](https://github.com/umeranjum17/juggernaut/pull/86) (merged e43cddbc) | `bin/jg-live-lab.sh`, `bin/jg-claude-trust.sh`, `tests/jg-live-lab-up-mate.test.sh` | offer to Kun (lab containment fix, only with the owner's approval) | on fork |
| Skip parked homes in every supervision producer | [85](https://github.com/umeranjum17/juggernaut/pull/85) (88e57fe1) | `bin/jg-parked-homes-lib.sh` (new shim), gate lines in `bin/jg-send.sh`, `bin/jg-control.sh`, `bin/jg-remote-squad-lead-relaunch.sh`, `bin/jg-squad-lead-restart.sh`, `bin/jg-squad-lead-reconcile.sh`, `bin/jg-config-push.sh`, `bin/jg-bootstrap.sh`, `bin/jg-pending-reply-lib.sh`, `bin/jg-model-outage-lib.sh`, `bin/jg-watch.sh` | add-on `parked-homes` (the reader + policy live there; fork carries only the shim and one predicate call per producer) | on fork |
| Fork catch-up with Kun's main | [74](https://github.com/umeranjum17/juggernaut/pull/74) (merge e9e2ef20) | merge commits only | stays (sync, no feature content) | done — merged; current capacity, tool-exclusion, spend and growth-check libraries match Kun's main |
| Label the Main-owned wait escalation as the check wake | [78](https://github.com/umeranjum17/juggernaut/pull/78) (4df0ed20) | `bin/jg-wait-timers-lib.sh` | add-on `wait-timers` | dormant copy |
| Fold open decisions without forking per status line | [79](https://github.com/umeranjum17/juggernaut/pull/79) (226ea2b2) | `bin/jg-classify-lib.sh` | offer to Kun | on fork |
| Replace fleet dashboard copy with the juggernaut-addons shim | [80](https://github.com/umeranjum17/juggernaut/pull/80) (561cc47e) | `bin/jg-dashboard.sh` (now a ~20-line exec shim) | add-on `fleet-dashboard` | done — moved to fleet-dashboard + fork shim PR 80; live dashboard serves from the add-on |
| Withdraw stale ready-work wakes instead of replaying them | [81](https://github.com/umeranjum17/juggernaut/pull/81) (c66d9594) | `bin/jg-wake-lib.sh`, `bin/jg-wake-drain.sh`, `bin/jg-watch.sh` | offer to Kun | on fork |
| Move a relaunching worker to another pool account (`--account`) | [83](https://github.com/umeranjum17/juggernaut/pull/83) (merged 0766f3c3) | `bin/jg-account-pool-lib.sh`, `bin/jg-control.sh`, `bin/jg-spawn.sh` | add-on `account-pool` if jg-control gains an account hook, else offer to Kun | on fork (see named item fm/jg-acct-f2-relaunch) |
| Retry the watch-triage drain ack under load and log missed attempts | [84](https://github.com/umeranjum17/juggernaut/pull/84) (merged 5758e520) | `tests/jg-watch-triage.test.sh` | offer to Kun (test hardening, only with the owner's approval) | on fork — diagnostics only; the flake was not reproduced |
| Home launch-env hook: `config/launch-env-hook <out>` runs in the pane and its export is sourced before the AI-trailer step | [90](https://github.com/umeranjum17/juggernaut/pull/90) (merged adcfce9e) | `bin/jg-spawn.sh` (thin hook), `docs/configuration.md` | stays (thin hook; the logic is add-on `git-identity`) | on fork — needed because no existing spawn hook point reaches the pane environment |

## Named items

| Item | Fork PR / commits | Key files | Exit path | Status |
|---|---|---|---|---|
| fm/jg-acct-f2-relaunch | [83](https://github.com/umeranjum17/juggernaut/pull/83) (0766f3c3) | jg-control relaunch `--account <id\|next>` | move to an add-on if jg-control gains an account hook, else offer to Kun only with the owner's approval | on fork |
| fork-live-lab-haiku | [82](https://github.com/umeranjum17/juggernaut/pull/82) (c19ba5f7) | `bin/jg-live-lab.sh` — Claude lab runtime, supervision host and squad-lead defaults all `claude-haiku-5-5` | offer to Kun only with the owner's approval (fleet lab policy) | on fork — verified in files |
| fork-live-lab-treehouse-leak | (no fork-only commit; rule on the shared lab script) | `bin/jg-live-lab.sh:171` — `TREEHOUSE_ROOT` points inside the lab root, so lab copies stay under it | stays (lab containment rule; re-check on every lab change) | holds today — verified in files |
| cicd-ci-tuning Q6/B4 (JG_LINT_JOBS 2–4, shard rebalance) | 7c6b3525 ([18](https://github.com/umeranjum17/juggernaut/pull/18)) and later CI commits | `.github/workflows/ci.yml` (still pins `JG_LINT_JOBS: '1'`), `bin/jg-lint.sh` (default 2), `docs/jg-test-portable-shards.md` | stays (fleet CI policy, never an add-on; tune in place) | open — CI still pins 1; raise to 2–4 and rebalance shards |

## Everything else, by feature

### Moved to an add-on

| Feature | Commits / PRs | Key files | Exit path | Status |
|---|---|---|---|---|
| Fleet dashboard: server, board, charts, kanban, ship view, Insights | 4a43b1ef…c7f2c100 + [80](https://github.com/umeranjum17/juggernaut/pull/80) (~20 commits, #10 #13 #20 #26 #28 #30 #31 #34 #42 #43 #49 #50 #53 #62) | `bin/jg-dashboard.sh`, `bin/jg-dashboard/` app | add-on `fleet-dashboard` | done — moved + fork shim (PR 80) |
| Model gate: one allow-list per provider | `bin/jg-model-allowlist.sh` reads the same list | add-on `model-gate` | done — folded into this repository's `addons/` with its installer, fleet check and tests; the fork's `bin/jg-model-allowlist.sh` keeps reading the same file |

### Dormant copy in an add-on (fork still runs its own)

| Feature | Commits / PRs | Key files (fork, still live) | Exit path | Status |
|---|---|---|---|---|
| Fleet flow reader (lifecycle/queue/bottleneck JSON) | 3b00213c ([23](https://github.com/umeranjum17/juggernaut/pull/23)) | `bin/jg-flow.sh` | add-on `fleet-flow` + fork shim | done — add-on folded into this repository's `addons/` (the fork still runs its own copy) |
| Home flow check (lane slots, dry pulse column) | fleet retro (add-on branch `fm/retro-lane-slots`) | `config/jg-flow-check.sh` | add-on `fleet-flow` + operator symlink (fleet-flow README install runbook); never a shim — `bin/jg-flow.sh` reads its stage-clock policy from the file's text | done — add-on folded into this repository's `addons/` (the fork still runs its own copy) |
| Fleet stats (per-model, per-skill, outcome recorder) | 877ded84 ([56](https://github.com/umeranjum17/juggernaut/pull/56)), eb0cb110 ([75](https://github.com/umeranjum17/juggernaut/pull/75)) | `bin/jg-model-stats.sh`, `bin/jg-skill-stats.sh`, `bin/jg-task-outcome.sh` | add-on `fleet-stats` + fork hook | done — add-on folded into this repository's `addons/` (the fork still runs its own copy) |
| Host memory sampling + admission | 2b3097c7 ([29](https://github.com/umeranjum17/juggernaut/pull/29)), 9f63932e ([33](https://github.com/umeranjum17/juggernaut/pull/33)), de32a41f ([45](https://github.com/umeranjum17/juggernaut/pull/45)) | `bin/jg-host-memory-sampler.sh`, `bin/jg-jev-mem-guard.py` delta, `config/host-memory` flag | add-on `host-memory` + flag hook | done — add-on folded into this repository's `addons/` (the fork still runs its own copy) |
| Wait timers lib + watcher integration | 3d9c09cc ([54](https://github.com/umeranjum17/juggernaut/pull/54)), 4df0ed20 ([78](https://github.com/umeranjum17/juggernaut/pull/78)) | `bin/jg-wait-timers-lib.sh`, one source line in `bin/jg-watch.sh` | add-on `wait-timers` + source hook | done — add-on folded into this repository's `addons/` (the fork still runs its own copy) |
| Sign-off hold cards, merge gate, answer delivery, receipts | a37c496e ([66](https://github.com/umeranjum17/juggernaut/pull/66)), 5dff364f ([71](https://github.com/umeranjum17/juggernaut/pull/71)), 06327fc1, 5774d939 | `bin/jg-procevent-signoff.sh`, `bin/jg-run-receipt.sh`, procevent dispatch hunk | add-on `receipts`; add-on `signoff`: 0 copied upstream lines, dormant until the fork dispatch hook (seam in `signoff/README.md`) | done — add-on folded into this repository's `addons/` (the fork still runs its own copy) |
| Sentinel (agent-runtime restart recovery) | 0f03b981 ([12](https://github.com/umeranjum17/juggernaut/pull/12)), dce39b61 ([70](https://github.com/umeranjum17/juggernaut/pull/70)) | `bin/jg-sentinel.sh` + unit path | add-on `sentinel` (thin wrapper, no copy) + unit hook | done — add-on folded into this repository's `addons/` (the fork still runs its own copy) |
| Supervisor-work guard | e4a6c5e0 | `bin/jg-supervisor-work-command-policy.mjs`, `bin/jg-supervisor-work-pretool-check.sh` | add-on `supervisor-guard` (code moved from fork commit e4a6c5e0, fork-only and not in Kun upstream, 0 lines copied from Kun upstream; `install.sh` merges the hook; reads the checkout's scope lib and lexer) + pretool hook | done — add-on folded into this repository's `addons/` (the fork still runs its own copy) |
| Model-outage, usage-limit and stuck-wait alerts | 16e04a41 ([48](https://github.com/umeranjum17/juggernaut/pull/48)), da71f161 ([52](https://github.com/umeranjum17/juggernaut/pull/52)), 01f01944 ([47](https://github.com/umeranjum17/juggernaut/pull/47)) | `bin/jg-model-outage-lib.sh`, watch hunks | add-on `alerts` + watch hook | done — add-on folded into this repository's `addons/` (the fork still runs its own copy) |
| Local Qwen tuning docs + bench | 78cc325a | `docs/local-qwen-tuning/` (fork copy still differs from Kun's main) | add-on `local-qwen-tuning` (reference lives there) | dropped — add-on `local-qwen-tuning` removed in the same change (the local Qwen lab is off); the fork copy keeps running |
| Bearings board milestones + evidence thumbnails | 9ad8e1fb, 08472745 | `bin/jg-bearings-board.sh`, `.agents/skills/bearings/` | add-on `bearings-board` (thin wrapper, no copied upstream code); extras in later slices | done — add-on folded into this repository's `addons/` (the fork still runs its own copy) |

### Still on the fork, add-on planned

| Feature | Commits / PRs | Key files | Exit path | Status |
|---|---|---|---|---|
| Lead-wake fleet policy (lane floor, idle lead, stalled ring, ready-work) | afd00e42, bd86f55b, 0ef3188b ([9](https://github.com/umeranjum17/juggernaut/pull/9)), 49d4ea80, d4881b01 ([7](https://github.com/umeranjum17/juggernaut/pull/7)), a7d3b2cc ([8](https://github.com/umeranjum17/juggernaut/pull/8)), c66d9594 ([81](https://github.com/umeranjum17/juggernaut/pull/81)) | `bin/jg-watch.sh`, `bin/jg-wake-lib.sh` | add-on (watch-side policy seam); never offer upstream as a "fix" | dormant copy - add-on `lead-wake` holds the whole feature and its tests; the fork step replaces the call sites |
| Worker account pooling at spawn + raw-launch refusal | aa56a40c ([72](https://github.com/umeranjum17/juggernaut/pull/72)), 46e2273b ([76](https://github.com/umeranjum17/juggernaut/pull/76)) | `bin/jg-account-pool-lib.sh`, `bin/jg-worker-account-lib.sh`, `bin/jg-spawn.sh` | add-on if jg-control gains an account hook, else offer to Kun only with the owner's approval | on fork |
| Shared worker-brief inheritance | e2071b0a | brief builder hunks | add-on (brief seam) | on fork |

### Fork fixes to offer to Kun (owner approval required first)

| Feature | Commits / PRs | Key files | Exit path | Status |
|---|---|---|---|---|
| Composer classifier furniture (pi, OpenCode, Claude frames, notices, wrappers) | 8f93ec97, 0006081e, dd5473ca, 297c0671, 283bb0ff, 27ab02fa, effd129d, c0101169 ([43](https://github.com/umeranjum17/juggernaut/pull/43)), 07e8da20 ([49](https://github.com/umeranjum17/juggernaut/pull/49)), 4f9d1833 ([55](https://github.com/umeranjum17/juggernaut/pull/55)), 6c218a0b ([59](https://github.com/umeranjum17/juggernaut/pull/59)), bcd56b27 ([63](https://github.com/umeranjum17/juggernaut/pull/63)), e06887f7 ([65](https://github.com/umeranjum17/juggernaut/pull/65)), 226ea2b2 ([79](https://github.com/umeranjum17/juggernaut/pull/79)) | `bin/jg-composer-lib.sh`, `bin/jg-classify-lib.sh` | offer to Kun | on fork |
| Herdr backend fixes (liveness, busy reads, registrations, display names, restart husks, lineage) | 9e0f4610, 41791476, 29489df9, 5aba26c9, 89f37b6c, 65e7989a, 738354c1 ([3](https://github.com/umeranjum17/juggernaut/pull/3)), 77aa4489, 3b1ef6e1, 158fdf6e | `bin/backends/herdr.sh`, `bin/jg-control.sh` | offer to Kun | on fork |
| Herdr lab isolation (`--isolated-xdg`, disposable homes) | c4a8401e ([25](https://github.com/umeranjum17/juggernaut/pull/25)), 64b16da2, 65e7989a | `bin/jg-herdr-lab.sh` | offer to Kun | on fork |
| Treehouse slot lease (spawns stop reusing live slots) | 9d7f14a5 ([39](https://github.com/umeranjum17/juggernaut/pull/39)), d146491a | `bin/jg-treehouse-protect.py`, spawn/teardown hunks | offer to Kun | on fork |
| Watch progress false-stale fix | 856dc3c0 | `bin/jg-watch-progress-lib.sh` | offer to Kun | on fork |
| Watcher/supervision fixes (continuity, false-stale, harness pin, stale index.lock, relaunch replaces held worker, busy-record proof, lease lock wait) | 3af203da ([38](https://github.com/umeranjum17/juggernaut/pull/38)), 856dc3c0 ([41](https://github.com/umeranjum17/juggernaut/pull/41)), c47fb103 ([11](https://github.com/umeranjum17/juggernaut/pull/11)), fc2f67e3, 7d273504, 1c46db48 ([58](https://github.com/umeranjum17/juggernaut/pull/58)), fed23d2a, 62e1962b, e4696b16, c91ecee4, 910b7cd8 ([77](https://github.com/umeranjum17/juggernaut/pull/77)), fc86b441 | `bin/jg-watch.sh`, `bin/jg-lease-lib.sh`, `bin/jg-crew-state.sh` | offer to Kun | on fork |
| Spawn/teardown/control/remote-job worker-lifecycle fixes (no interactive git editors, session store per worker, resume after host restart, merge proof before teardown, executable outcome scripts) | 84e1a4a9 ([19](https://github.com/umeranjum17/juggernaut/pull/19)), 482a5072 ([57](https://github.com/umeranjum17/juggernaut/pull/57)), 9d8616d9 ([37](https://github.com/umeranjum17/juggernaut/pull/37)), 446a05e6 ([67](https://github.com/umeranjum17/juggernaut/pull/67)), dce39b61 ([70](https://github.com/umeranjum17/juggernaut/pull/70)), ce00911f ([69](https://github.com/umeranjum17/juggernaut/pull/69)), eb0cb110 ([75](https://github.com/umeranjum17/juggernaut/pull/75)), e216dac7, 96b69521, fdf5a5bd, af26b9a9, 0efa37b2, 9f8be03d | `bin/jg-spawn.sh`, `bin/jg-teardown.sh`, `bin/jg-session-start.sh` | offer to Kun (verify each hunk) | on fork |
| Pi 1.2.0 before_agent_start custom events | b1cb0da5 ([68](https://github.com/umeranjum17/juggernaut/pull/68)) | `.pi/extensions/jg-branch-supervision.ts` | offer to Kun | on fork |
| Privacy: no public test-evidence publication | 5d304a2c ([35](https://github.com/umeranjum17/juggernaut/pull/35)) | test helper + docs | offer to Kun | on fork |
| Docs fixes (stash ban in briefs, composer-restore notes, jg-role rows, sign-off-axi pointers) | db0abe4b ([17](https://github.com/umeranjum17/juggernaut/pull/17)), 28482318 ([14](https://github.com/umeranjum17/juggernaut/pull/14)), 4887b114, 0624f124 ([73](https://github.com/umeranjum17/juggernaut/pull/73)) | `docs/`, `AGENTS.md`, skills | offer to Kun | on fork |

### Fork-only policy (stays, never moves)

| Feature | Commits / PRs | Key files | Exit path | Status |
|---|---|---|---|---|
| CI fleet policy (advisory pipeline check, self-hosted light jobs, shard split) | 7c9b2326 ([60](https://github.com/umeranjum17/juggernaut/pull/60)), abbac7b6 ([61](https://github.com/umeranjum17/juggernaut/pull/61)), 7c6b3525 ([18](https://github.com/umeranjum17/juggernaut/pull/18)), 158fdf6e | `.github/workflows/`, `.no-mistakes.yaml` | stays (fleet policy; see cicd-ci-tuning named item) | on fork |
| Upstream ports (capacity, tool exclusions, pipeline spend, growth check) | cd49747b ([44](https://github.com/umeranjum17/juggernaut/pull/44)) ported them early | `bin/jg-project-capacity-lib.sh`, `bin/jg-exclude-tools-lib.sh`, `bin/jg-pipeline-spend.sh`, `bin/jg-startup-growth-check.sh` match Kun's main; some other fork files also match | stays — reconcile remaining differences on the next sync | done via PR 74 |

---

Counts and method: fork main `7a6e4cb0a1428dca62dc66d3fcc7472fd85044f8` (2026-10-18) is 161 commits
and 218 files ahead of merge-base `0397cb2bb431948f3865b7f28c522290546dcaaf` (+19,292/−1,942;
three-dot diff). Some fork files are byte-identical to Kun main. Statuses re-checked against fork files
and add-on READMEs. Short SHAs resolve at https://github.com/umeranjum17/juggernaut.
