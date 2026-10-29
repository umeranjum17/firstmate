# wait-timers

The waiting-state timers — owner-alert and escalation timers for lanes that
declared a wait — moved **verbatim** out of the supervising fork into this
add-on repository. Nothing watches from here yet: the live watcher keeps
sourcing the fork's `bin/jg-wait-timers-lib.sh`, and the fork-side hook that
will source this directory instead lands in a later PR. Until that swap this
directory is dormant, and every moved byte below is identical to the fork copy
the live watcher runs today.

Step A of the fork exit: the library runs from this directory. Its sibling
libraries (`jg-parent-channel-lib.sh`, `jg-timeout-lib.sh`) are read from the
fork's `bin/` (`$SCRIPT_DIR`, else `$JG_PUSH_TRANSITION_LIB_DIR`, else
`$JG_HOME/bin`). The library body is otherwise identical to the fork copy.

## Step-B hook lines (fork)

- `bin/jg-watch.sh` and `bin/jg-push-transition-lib.sh`: replace the sourcing of
  the fork's `jg-wait-timers-lib.sh` with
  `[ ! -r "${JG_ADDONS_DIR:-$JG_HOME/projects/juggernaut-addons}/wait-timers/bin/jg-wait-timers-lib.sh" ] || . "${JG_ADDONS_DIR:-$JG_HOME/projects/juggernaut-addons}/wait-timers/bin/jg-wait-timers-lib.sh"`.
- Tick: `if declare -F jg_wait_timers_tick >/dev/null; then jg_wait_timers_tick || { echo "watcher: waiting-state timer check failed" >&2; exit 1; }; fi`.
- Push: `if [ -n "$task" ] && declare -F jg_wait_timer_push_delivered >/dev/null; then jg_wait_timer_push_delivered "$task" "$window" || exit 1; fi`.

`tests/wait-timers-hook-e2e.sh` (set `JG_TEST_FORK` to a Juggernaut checkout)
uses the fork's post-step-B hook lines unchanged, copies this add-on's moved
`tests/jg-wait-timers.test.sh` journey into a private fork copy, and runs it with
this library installed; it also checks that the optional hooks are no-ops when
the add-on is absent.

## Layout

- `bin/jg-wait-timers-lib.sh` — the timer library the watcher sources once per
  poll: one durable episode per waiting lane under `state/.waiting-timers/`,
  an owner recheck once the alert threshold matures, then escalation when the
  owner has not cleared the wait. A blocked or needs-decision wake names its
  decision as `key=<key>` after the verb; paused waits carry none.
- `tests/jg-wait-timers.test.sh` — the watcher/drain journey that proves the
  timers (owner alert, escalation, deduplication, resolution, re-arm).
- `tests/jg-wait-timers-tmux-e2e.test.sh` — the live-terminal end-to-end
  journey; moved verbatim, run only against a real terminal session.

## Contract

The escalation chain changed this contract after the move below, so the
provenance table now records history, not the current bytes.

- Entry: `jg_wait_timers_tick` (no arguments; reads `JG_HOME` and `STATE`).
  Called once per watcher poll.
- `jg_wait_timer_push_delivered <task> <window>` — records that an immediate
  native push already told the owner about this blocked lane, so the poll
  timer skips its duplicate owner wake. Called from the push-transition path.
- `jg_wait_timer_source_delivered <task> <window> <declaration>` — the same for
  a wait source the watcher already woke the owner about (a permission prompt,
  a lead whose own supervision is down).
- `jg_wait_timer_save <record> <signature> <since> <owner> <parent> <key>
  <misses> [card] [last]`, `jg_wait_timer_report <status-line>`,
  `jg_wait_timer_owner_delivered` — episode persistence, parent reporting,
  and the post-wake hook the owner alert installs.
- Environment: `JG_WAIT_ALERT_SECS` (default 120) for the owner rung,
  `JG_WAIT_ESCALATE_SECS` (default 300) for Main's rung, `JG_WAIT_CARD_SECS`
  (default 600, above the escalation threshold) for the board card, and
  `JG_PROMPT_REALERT_SECS` (default 600) for how often a reached rung fires
  again. A declared pause rechecks at the `JG_PAUSE_RESURFACE_SECS` cadence
  instead and never escalates.
- Wait sources: the watcher writes `state/.wait-sources/<task>.prompt` for an
  unanswered permission prompt (rewritten on every sighting; a record older
  than three polls plus 30 seconds is ignored, so a prompt on a dead pane
  lapses) and
  `<task>.supervision` for a Squad Lead with work under way whose own watcher
  is not running. A wait source outranks an open decision and a pause.
  The watcher also writes `<task>.question` (a picker or question dialog on
  screen, for any harness, whatever status the terminal shows),
  `<task>.quota` (a provider rate-limit or usage-limit banner in the last
  twelve lines) and `<task>.silent` (no status line, no native progress and no
  pane text change for `JG_SILENT_SECS`, default 900; a future-dated pause, a
  finished worker, an idle lead and a running validation are exempt), from
  `bin/jg-stuck-gate-lib.sh`. They are fresh-bounded like the prompt source and
  ride the same rungs, so a worker that ignores its own question still climbs.
- Episode record: one tab-separated line per lane at
  `state/.waiting-timers/<task>` holding signature, first-observed time,
  owner-delivery time, Main-rung time (0 before it fires), report key, miss
  count, board-card time, and last re-fire time. The report key is the wait's
  identity, `waiting-timer-<home>-<task>-g<generation>-<source key>`: home is
  a short hash of the Juggernaut home, generation is the arming second, and
  the source is the open decision key (or the pause key, `herdr-blocked`,
  `prompt`, `supervision`, `unkeyed`). Every line prints
  `id=<key> source=[<declaration>]`, so the exact unresolved source is named;
  a resolution closes only the wait it names. The `waiting-timer-` prefix is
  unchanged for the fork's reserved-key fold.
- Parent lines: `blocked [key=...]: waiting-timer-overdue: <task> (<verb>,
  observed <n>s, since=<epoch>); ...; source=[...]` on escalation and on every
  re-fire, `resolved [key=...]: waiting-timer-cleared: ...` when the wait
  ends. A top-level wait with no parent escalates as a wake to the top level
  itself, never as a parent report.

## Escalation chain

A stuck worker never waits on the captain noticing it.
Every rung fires again every `JG_PROMPT_REALERT_SECS` while the wait stays open.

| rung | when | who acts |
|---|---|---|
| own-fleet read prompt | at once | the watcher approves it (`bin/jg-prompt-gate-lib.sh`) |
| secrets-path prompt (`.env`, `~/.config`, a home's `data/` or `config/`) | at once | the watcher rejects it and tells the worker why |
| any other prompt, question, decision, or blocker | first sight, then `JG_WAIT_ALERT_SECS` | the owning home is woken |
| still open | `JG_WAIT_ESCALATE_SECS` | a lead home reports `waiting-timer-overdue` to Main; Main steers the lead at once, interrupting it first when it is busy mid-turn, naming the worker and its wait |
| still open | `JG_WAIT_CARD_SECS` | the main home posts a guarded board card, and dismisses it when the wait ends |

- A lead's own supervision not running is a Main wait from lead liveness, so a
  dead hop never goes silent; a dead lead rides its relaunch.
- A new supervisor session re-presents every open wait on its first tick, so a
  relaunched lead re-presents its stuck workers within one cycle.
- The main home reads only the overdue lines a lead appends to its own
  `state/<lead>.status`, never the lead's child records.
- The board card is raised from the main home only, even when Main has not
  read its wakes, so it still fires with Main absent.

## Stalled ready backlog

A lead that ignores its ready-work wake (`bin/jg-watch.sh` `ready_work_waits_idle`) is the same ladder with the lead as the stuck party.
`jg_wait_timers_backlog` runs from a lead home's tick at most every `JG_READY_STALL_POLL_SECS` (default 60), and the watcher's `ready_backlog_stall_state` owns the condition.
The condition holds while a ready, unheld item could start now and the home has a free lane.
A free lane is fewer open lanes than `config/lane-target`, or than 4 without a usable one.
An item whose project's declared capacity is already held cannot start now, so it does not count (`bin/jg-project-capacity-lib.sh`).

| rung | when | who acts |
|---|---|---|
| ready work on a free lane | first sight | the existing ready-work wake asks the lead to dispatch |
| nothing started | `JG_READY_STALL_SECS` (default 900) | the lead is woken again, and it reports `waiting-timer-backlog-overdue` to Main, which is Main's event; Main's relay steers the lead, interrupting it first when it is busy mid-turn |
| still nothing started | every `JG_PROMPT_REALERT_SECS` | both fire again |

- A start is a lane id that was not open before; it ends the episode and re-arms the clock.
- The condition clearing (no startable ready item, or no free lane) ends the episode, and a reported one is closed with `waiting-timer-cleared`.
- An unreadable backlog leaves the episode untouched for that poll.
- There is no board card rung for a stalled backlog.
- Episode record: `state/.waiting-timers/.ready-backlog`, one tab-separated line holding first-observed time, open lane ids (comma-joined, `-` for none), report key (`waiting-timer-<home>-<lead>-g<generation>-ready-backlog`), first report time (0 before it), and last fire time.

## Provenance: byte-identical to the fork at the move

Every moved file was compared byte for byte against its fork source at
`0689b4b9d9ab3594f846cfe07c400edfa58244bf`; the sha256 manifest matched
across fork source and this directory. Treat any future diff against the fork
file as a contract change, not a refactor.

| moved file | fork source | sha256 |
|---|---|---|
| `wait-timers/bin/jg-wait-timers-lib.sh` | `bin/jg-wait-timers-lib.sh` | `5e4b399de21bdf47795dc9b0d52c12716be9b62bdb3422ad4d1f36878f0e0fd7` |
| `wait-timers/tests/jg-wait-timers.test.sh` | `tests/jg-wait-timers.test.sh` | `393b910d2bcafa41fa7b94a7f141e5c3652ab914b88b2d859545043a3938f08f` |
| `wait-timers/tests/jg-wait-timers-tmux-e2e.test.sh` | `tests/jg-wait-timers-tmux-e2e.test.sh` | `fc0f38458b02aa25efcf939bbf763bcdb01f57ce09fca888a6a68fc34c735fbf` |

## Side-by-side proof (re-run before the hook swaps the sourced path)

The acceptance proof runs the fork test and the moved test each against its
own library copy and diffs the verdicts. The library sources its two sibling
libraries from its own directory, so the moved side runs inside a throwaway
harness outside the moved files: a scratch copy of the fork tree at the
commit above whose `bin/` already holds those siblings, with only
`bin/jg-wait-timers-lib.sh` and `tests/jg-wait-timers.test.sh` replaced by
the moved bytes (verified identical first). Do not run the live-terminal
end-to-end test: it drives a real terminal session; it moves verbatim only.

1. Unpack the fork tree at the commit above into two scratch roots.
2. In the second root only, overwrite the timer library and its test with
   the moved files; `diff` both against the first root (must be empty) and
   re-check the sha256 table above.
3. Run `tests/jg-wait-timers.test.sh` in each root; both must exit 0 and
   print the same `ok` verdict lines (the harness's cycle-budget warnings
   carry process ids, so normalize digits before diffing).
4. Run the repo CI gate (the lint plus syntax check over every add-on script)
   on the PR head.

Timing note: the journey gives each watcher cycle a small single-digit
budget, so run the proof on a quiet host — under heavy load a cycle can be
terminated before it records its delivery and the run fails on timing, not
on behavior.
