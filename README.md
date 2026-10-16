# firstmate-addons

Fleet dashboard and add-ons for running a fleet of coding agents.

## delete-guard

No agent can recursively delete `/`, `/home`, a home folder or a folder directly in it, or a bare `.` `..` `*` or `$VAR` target, and every attempt wakes the main firstmate.
`delete-guard/guard.mjs` holds the one rule, and each runtime adapter hands it the shell command before it runs.
A block is final: there is no allow-once, flag or environment override, and no agent, reviewer or pipeline gate can approve the delete.
The one `$VAR` exception: when `d=$(mktemp ...)` with any options, or `d=$(mktemp ... || mktemp ...)` where every `||` alternative is a mktemp call, is its own statement (optionally after `export`, `local`, `readonly`, `typeset` or `declare` with only `-r`, `-x`, `-g`; never a `-n` nameref) and the last assignment to `d` in the same command, `rm -rf -- "$d"` runs (never for `HOME` or another shell or runtime variable). A literal-path assignment takes the same prefixes.
Each block appends one JSON line (time, home, task, cwd, runtime, target, command) to `<fm-home>/state/delete-guard.log`.
The `delete-guard` watcher check turns new lines into one wake on the watcher's check cadence (5 minutes by default).
A second block by the same task (or, with no task, the same cwd) within 10 minutes queues an immediate `delete guard REPEAT` wake.
A heredoc body fed to a shell (`bash <<EOF`, `cat <<EOF | sh`) is checked as commands, and one fed to anything else (`python3`, `cat > file`) is data.
Only the command string is checked, so a delete inside a script file the agent runs is not seen.
Covered: Claude Code (workers, leads, Main and the no-mistakes Claude agent) by a `PreToolUse` Bash hook in `~/.claude/settings.json`, pi by `~/.pi/agent/extensions/fm-rm-guard.ts` (replacing the 16 Oct stopgap), and OpenCode by `~/.config/opencode/plugins/fm-delete-guard.js`.
Not covered: Codex, because Firstmate launches its crewmates and scouts with `--disable hooks` and a new `~/.codex/hooks.json` entry puts a hook-trust prompt in front of every Codex launch, and cursor-agent, grok, omp, kimi and gemini, which the fleet does not dispatch.

Install or update with `delete-guard/install.sh [--dry-run] <main-fm-home>`; it is idempotent, and `--dry-run` prints the changes and writes nothing.
It backs up each file it changes as `<file>.bak-delete-guard-<epoch>`, copies the rule to `${XDG_DATA_HOME:-~/.local/share}/fm-delete-guard/`, writes the adapters, merges the Claude hook without dropping other settings, and registers the check in `<main-fm-home>`.
Test: `delete-guard/tests/delete-guard.test.sh <firstmate-checkout> [ref]` installs into a throwaway HOME against a home built from that checkout's `bin/`, then drives the installed hook through every rule case and the log, check and repeat-wake journey.

## merge-card

Every merge runs done-done and, only with passed proof, posts one evidence card to a sign-off board, with nobody posting by hand.

`merge-card/merge-card` is one bash script with three subcommands:

- `merge-card gate <task-id> <worktree|-> <head|-> <pr-url|->` runs `done-done check --from <source> --judge --json` in the task's worktree, where `<source>` is the pull request when there is one and `$FM_HOME/data/<task-id>/checks.md` otherwise.
  The Checks evidence lives in `$FM_HOME/data/<task-id>`, so it is cited from there while absolute paths stay unchanged: `done-done check --citation-base $FM_HOME/data/<task-id>` resolves the relative names itself on done-done 0.3.1+, and on an older one merge-card runs done-done without the flag and resolves the verdict's relative citations against the task folder itself, before the card copies the media.
  The work copy only supplies the repo identity.
  It prints the verdict and saves it for the card in `$FM_HOME/data/<task-id>/merge-card.json`.
  It is report only: it always exits 0, so it never refuses a merge the checks lint passes.
  Hand-captured evidence legitimately comes back inconclusive and the merge still lands.
  A judge that is not configured degrades to a plain "not checked" verdict; a done-done that could not check at all names the real reason (an older done-done rejecting `--citation-base`, say) instead of a bare exit code.
  `merge-card check <task-id> <worktree|-> <head|-> <pr-url|->` runs the gate's check alone: it saves and prints the verdict and posts nothing.
- `merge-card post --board <board.json> <task-id> <worktree|-> <head|-> <pr-url|->` posts exactly one evidence card per merge, and only when the proof is real and passed.
  A merge posts only an evidence card: the plain outcome as the title and the passed proof on the card.
  A merge with missing or unconfirmed proof posts no card; the gap goes back to the lane owner to fix the proof and re-run the post.
  The card carries the Checks claim (what a user can now do) as the title, done-done's verdict in plain words, the pull request link (the merged commit when there is no PR), and the passed proof media (at most 12 screens or recordings), or those of a verify run at the merged head.
  The card key is the merge's own (`merge-<owner>-<repo>-pull-<n>`, or `merge-<head>` for a local merge), so a repeat post or a second home adds nothing.
  sign-off-axi writes the board under its lock and only appends.

`merge-card` needs `done-done` on `PATH` (0.3.1+ lets it resolve the block's relative evidence names itself; on an older one the card still carries its retained proof, but that older done-done sees a relatively cited file as missing and says so in the verdict), plus `sign-off-axi`, `jq` and `gh`.

Install into one home, so the post-merge hook calls `post` once for each recorded merge:

```sh
printf '#!/bin/sh\nexec <addons>/merge-card/merge-card gate "$@"\n' > $FM_HOME/config/merge-gate
printf '#!/bin/sh\nexec <addons>/merge-card/merge-card post --board <board.json> "$@"\n' > $FM_HOME/config/post-merge
chmod +x $FM_HOME/config/merge-gate $FM_HOME/config/post-merge
```

Test: `merge-card/tests/merge-card-e2e.sh` drives the real script end to end against a task folder holding a retained PNG, with a stub `done-done` placed earlier on `PATH` (one accepting `--citation-base`, one rejecting it, and one that lies about supporting it), and asserts the recorded verdict, the invocation the stub saw, and that the card's media resolves in each case.

## quota-failover

Workers and leads stopped by a provider usage limit or a provider 429/5xx move to the next live route on their own, and the dead route stays out of new dispatch until it answers again.

`quota-failover/quota-failover <fm-home>` is one bash script that makes one pass over the home's workers and leads under a lock, so any cadence can run it.
A worker or lead counts as stopped by a limit when all of these hold:

- its status says working, or it has no status yet;
- it has written no status, turn end or progress for `QUOTA_FAILOVER_STALL_SECS` (default 240), and it was not spawned or relaunched inside that window;
- it is not busy, where a harness that is only retrying a provider error counts as not busy;
- one of: its visible screen shows a provider limit error; `quota-axi` reads its route's provider as exhausted now; its pinned route is already out of dispatch; or a one-line test of its pinned route answers a provider limit or 429/5xx error (that probe runs at most once per `QUOTA_FAILOVER_PROBE_SECS`, default 900, per task).

A busy worker that is making progress is never touched.
A stopped task gets the routes of the `config/crew-dispatch.json` rules that hold its current route, then the default list, in order.
Routes that are out of dispatch or whose provider reads exhausted are passed over, and the first other route that answers a one-prompt live test (`QUOTA_FAILOVER_TEST_SECS`, default 90) wins.
The task is relaunched there with `bin/fm-control.sh <task> relaunch`, with a note naming the old route, the new route and why.
A route that sits only in rules whose models all contain `opus` moves only to another such model; with none live, the task is left waiting and the reason is logged.
A remote task is detected and logged, never switched.
A route whose screen shows a limit, or that answers its pinned one-line test with a limit or 429/5xx error, is out until it answers that test again: its profile objects are dropped from `config/crew-dispatch.json` (a rule left with no profiles goes with them; the schema never changes) into `state/quota-failover-dead.json`, so a new dispatch cannot rank it, and every pass re-tests it after `QUOTA_FAILOVER_RETEST_SECS` (default 1800) to put the profiles back at the end of their list when it answers.
The filter reads the dispatch file on disk, so hand edits survive while a route is out, but a dropped profile cannot be re-added by hand until it answers again.
Every decision is one line in `state/quota-failover.log`.
A worker left with no live route also gets one failed line on the home's parent channel; nothing else is sent there.

It needs `quota-axi`, `jq`, `flock` and the harness command of each dispatch route on `PATH`.
`QUOTA_FAILOVER_MAX_AGE` (default `10m`) is the oldest quota reading it trusts.

Test: `quota-failover/tests/quota-failover-e2e.sh` drives the real script end to end against a fixture home (stub firstmate libs in its `bin/`, stub `quota-axi` and `opencode` on `PATH`): a lead on a route that answers every one-line test with the 15 Oct 429, and a screen-stopped worker on a second dead route ranked first in the dispatch rules. It asserts both move to the live candidate, the dead routes are passed over and dropped from `crew-dispatch.json`, and a second pass with the routes answering again restores them and moves nothing.

Install into one home as a watcher check, so it runs on the watcher's own cadence:

```sh
printf 'setsid -f <addons>/quota-failover/quota-failover %s >/dev/null 2>&1 </dev/null\n' "$FM_HOME" > $FM_HOME/state/quota-failover-watch.check.sh && chmod 700 $FM_HOME/state/quota-failover-watch.check.sh && $FM_HOME/bin/fm-check-register.sh quota-failover-watch
```

Remove it with `$FM_HOME/bin/fm-check-unregister.sh quota-failover-watch`.

## pipeline-quota-failover

The no-mistakes pipeline agent moves to the next allowed model the moment a provider answers a quota error, instead of retrying the same model 4 times and failing the run (speed-report row Q1: about 1,650 pipeline minutes a day).

`pipeline-quota-failover/pi-quota-failover` is one bash wrapper installed as the pipeline's `pi` through `agent_path_override.pi`. It runs the real `pi`; when an attempt answers a quota error (pi reports provider errors inside its JSON stream and still exits 0, and no-mistakes' terminal list covers only seven exact quota phrasings, so real limit errors are retried up to 4 times on the same model), the wrapper starts the next model in the chain inside the same invocation: `zai/glm-5.3-flash` (GLM 5.3 Flash), then `muse-spark-1.3-contributor` (Go Muse 1.3 Contributor), then `deepseek/deepseek-v4.1-flash` - never Claude, never Step 5. The requested model always goes first, then the other chain models in chain order, so a profile set to Muse fails over to GLM, then DeepSeek. A non-quota failure passes through byte-for-byte with its original exit code. A resumed `--session` is dropped on the failover attempt (fresh-session retry, the pipeline's own semantics after a provider switch). When every chain model is quota-dead the wrapper fails once with a line containing "quota exhausted", which no-mistakes classifies as terminal, so the dead chain is never re-retried. Calls pinned to a model outside the chain (for example `axi run --model`) pass through untouched. Each decision is one timed line in `~/.local/state/pi-quota-failover.log` and on the step's stderr.
Because every pipeline model call passes through this wrapper, it is also where the host-memory gate sits (speed-report row B3: model calls under heavy host load crash): before each call it runs `~/firstmate/config/fm-mem-gate.sh` with no command, which only waits until the host has room, for at most `PI_QUOTA_FAILOVER_GATE_SECS` (default 600) before pi starts anyway, with pi keeping its normal priority and no memory cap (`PI_QUOTA_FAILOVER_GATE` names another gate, empty disables it).

Neither installed v1.79 nor current v1.84 can express this in config: `agent:` fallback is per agent and fires only on process-unavailable errors (`pi reported error:` matches none of its needles), and `agent_config.<agent>.model` is a single string, so one agent cannot carry a model chain. The daemon re-reads the config per run, so wiring needs no daemon restart.

Install or remove with `pipeline-quota-failover/install.sh [--dry-run] [--restore]`; it copies the wrapper to `~/.local/share/fm-pipeline-quota-failover/`, makes one key-level edit to `~/.no-mistakes/config.yaml` (timestamped backup next to it, key name only in output, no config contents printed), and is idempotent.
Test: `pipeline-quota-failover/tests/pi-quota-failover-e2e.sh` drives the real wrapper against a stub pi in a throwaway HOME with the exact argv shape no-mistakes builds (quota-dead GLM route using the fleet's real 429 usage-limit surface, healthy muse route): one attempt per model, the winning stream on stdout, timed log lines, non-quota and pinned-model passthrough, session drop on failover, chain exhaustion exiting 1 with the terminal line, and the install edit's add, idempotence, restore and backup.

## ask-default

An unanswered ask gets a safe, pre-declared default instead of blocking the home, and work continues.

`ask-default/ask-default` is one bash script with four subcommands:

- `ask-default open <ask-id> --wait-until <YYYY-MM-DDTHH:MM:SSZ> | --wait <seconds> --default-cmd <command> --safety <class> --reason <one line>` records one ask in `$FM_HOME/data/ask-default/asks/<ask-id>`: its wait clock, the pre-declared default action, that action's safety class, and the reason.
  A class of `safe` means the default action is reversible and touches no destructive, irreversible, money, credential, or merge action, and it must name the command that performs it; any other class (`destructive`, `irreversible`, `money`, `credential`, `merge`) or `none` declares that no safe default exists and the ask must stay held.
  Re-opening refreshes the wait clock; a defaulted ask is settled and never re-opens under the same id.
- `ask-default decide <ask-id> [--probe-cmd <command>] [--timeout <seconds>]` probes the captain once under a hard timeout and decides what the home does about the ask.
  The probe command exits 0 for reachable; anything else, including the timeout, resolves to unreachable inside the bound, so a hanging endpoint never wedges the caller.
  Its command comes from `--probe-cmd` or `$ASK_DEFAULT_PROBE` and its timeout from `--timeout`, `$ASK_DEFAULT_TIMEOUT`, or 5 seconds; with no probe configured it refuses rather than assume the captain is unreachable.
  Exit codes: `0` defaulted (or already-defaulted), so the caller may continue unrelated work, `10` held (the clock expired but no safe default exists), `11` waiting (the clock has not expired), `12` reachable (the ask stays open for the real answer), `1` error on stderr.
  A defaulted ask runs its default action exactly once, under a per-ask lock, and appends `{ask, applied_at, default_cmd, reason, rc}` to the append-only `$FM_HOME/data/ask-default/applied.log`.
- `ask-default probe <command> [--timeout <seconds>]` runs one bounded reachability probe on its own: exit 0 reachable, 1 unreachable.
- `ask-default show <ask-id>` prints the ask record.

`ask-default` needs `bash`, `jq`, `flock`, and GNU coreutils (`timeout`, `date -d`) on `PATH`, plus `FM_HOME` set.

The add-on decides; it does not wire itself in. A home discovers open asks and calls `decide` per ask from its own supervision loop, which is a thin hook in the firstmate fork, not in this repo.

## tailscale-resilience

One host watchdog for the two failures that quietly take a lane offline: the Tailscale network going unreachable while `tailscaled` still runs, and a display/session dying while logind still lists it.

`tailscale-resilience/tailscale-resilience` is one bash script with one subcommand:

- `tailscale-resilience check [--samples N] [--window S] [--cooldown S] [--state-dir DIR]` reads both detectors from the real CLI, advances their bounded sample windows in the state dir, and on the first window that holds a failure for the whole window it heals, alerts and records.
  - `net` uses `tailscale status --json` (BackendState, peer Online flags) and `tailscale netcheck --format json` (RegionLatency): the network is unreachable when the daemon answers but nothing else does - the status call fails, `BackendState` is not `Running`, or no DERP relay and no peer is reachable.
  - `display` uses `loginctl list-sessions` and `show-session`: a session logind still lists is dead when it is closing, its leader PID is gone from `/proc`, or a graphical session has no display socket left for its user.
  - A window needs `--samples` (3) consecutive failing samples inside `--window` (600) seconds, so one transient failure never heals and never alerts.
  - The heal is one `tailscale up` per detected outage and never twice inside `--cooldown` (300) seconds.
  - It reattaches the connection and changes nothing else, so a dead `tailscaled` or a `NeedsLogin` node is recorded with the real cause instead of being papered over.
  - Alerting never uses Tailscale: `$STATE_DIR/alerts.log` always works, and `TSR_ALERT_CMD` adds a local channel - a LAN webhook, `notify-send`, an SMS gateway - run with the alert text on stdin and as `$1`.
  - Every detection, heal and alert is appended to `$STATE_DIR/events.jsonl`, one JSON line each, naming what was detected, when, and the heal result.

It needs `bash`, `jq`, `tailscale` and `loginctl` on `PATH`, and one instance owns the state dir.

Install it as a timer so the windows are fed at the fleet's scan cadence (60s matches a Firstmate scan):

```sh
printf '%s\n' '[Unit]' 'Description=Tailscale and display resilience check' \
  '[Service]' 'Type=oneshot' 'ExecStart=<addons>/tailscale-resilience/tailscale-resilience check' \
  'Environment=TSR_ALERT_CMD=<a local push channel, never a tailnet address>' \
  'EnvironmentFile=-/etc/default/tailscale-resilience' > /etc/systemd/system/tailscale-resilience.service
printf '%s\n' '[Unit]' 'Description=Run the resilience check' \
  '[Timer]' 'OnCalendar=minutely' 'Persistent=true' \
  '[Install]' 'WantedBy=timers.target' > /etc/systemd/system/tailscale-resilience.timer
systemctl enable --now tailscale-resilience.timer
```

The state defaults to `${XDG_STATE_HOME:-$HOME/.local/state}/tailscale-resilience`, so a timer runs it as one user and that user owns the record.
`TSR_SAMPLES`, `TSR_WINDOW`, `TSR_COOLDOWN` and `TSR_STATE_DIR` set the same knobs as the flags.

The dead-display case is detected, recorded and alerted but not healed; a heal for it is a later slice.

## claude-model-guard

Claude Code on this host never starts Sonnet or Fable (Main3410: a live lab ran `--model sonnet`).
`claude-model-guard/install.sh [--dry-run] [--restore] [--config-dir <dir>]` edits `<dir>/settings.json` (default `${CLAUDE_CONFIG_DIR:-~/.claude}`) at key level, with a timestamped backup, so every Sonnet or Fable form ends on Haiku or is refused, never on another model: `env.ANTHROPIC_DEFAULT_SONNET_MODEL` and `env.ANTHROPIC_DEFAULT_FABLE_MODEL` = `claude-haiku-5-5`, so the `sonnet`, `opusplan` and `fable` aliases (a `--model sonnet` launch, an agent's `model: sonnet`) run on Haiku; and a `UserPromptSubmit` hook plus a `PreToolUse` hook for `Agent|Task` running `refuse-model.sh` (copied to `${XDG_DATA_HOME:-~/.local/share}/fm-claude-model-guard`), which refuses the prompt or the subagent call before any request is sent when a full id such as `claude-sonnet-5-5` or `claude-fable-5-1` comes from `--model`, `ANTHROPIC_MODEL`, a settings `model` key or an Agent call. It prints only its own keys and never reads or touches credentials; `--restore` removes exactly its keys and hook entries.
Claude Code itself cannot refuse a full id from user settings: `availableModels` and the managed-only `deniedModels` both fall back to the default model (Opus), and `modelOverrides` does not remap first-party ids. Not covered: a launch with `--setting-sources` that leaves out `user` (the `fm-live-lab.sh` primary uses `project,local`) loads no user settings, so neither the mapping nor the hook applies there; a session with its own `CLAUDE_CONFIG_DIR` needs the installer run with `--config-dir` for that dir. The hook fails open if it cannot run.

Test: `claude-model-guard/tests/claude-model-guard-e2e.sh` installs into a throwaway HOME with no credential and drives the real `claude` binary: each `--model` (the sonnet, fable and opusplan aliases, full Sonnet and Fable ids, `--model=`, `ANTHROPIC_MODEL`, a settings `model`, opus, haiku, none) is checked against the model Claude Code dispatches to, or the hook refusal, in its debug log, so no API call is made and a banned model can never run; the Agent-call check feeds the hook a tool input; plus key-only output, other settings kept, idempotence, backup and restore.
