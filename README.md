# firstmate-addons

Fleet dashboard and add-ons for running a fleet of coding agents.

## merge-card

Every merge runs done-done and posts one evidence card to a sign-off board, with nobody posting by hand.

`merge-card/merge-card` is one bash script with two subcommands:

- `merge-card gate <task-id> <worktree|-> <head|-> <pr-url|->` runs `done-done check --from <source> --citation-base $FM_HOME/data/<task-id> --judge --json` in the task's worktree, where `<source>` is the pull request when there is one and `$FM_HOME/data/<task-id>/checks.md` otherwise.
  The Checks evidence lives in `$FM_HOME/data/<task-id>`, so `--citation-base` resolves the block's relative evidence paths there while absolute paths stay unchanged; the work copy only supplies the repo identity.
  It prints the verdict and saves it for the card in `$FM_HOME/data/<task-id>/merge-card.json`.
  It is report only: it always exits 0, so it never refuses a merge the checks lint passes.
  Hand-captured evidence legitimately comes back inconclusive and the merge still lands.
  A judge that is not configured degrades to a plain "not checked" verdict.
- `merge-card post --board <board.json> <task-id> <worktree|-> <head|-> <pr-url|->` posts exactly one card per merge.
  The card carries the Checks outcome as the title, done-done's verdict in plain words, the pull request link (the merged commit when there is no PR), and the Checks evidence media (at most 12 screens or recordings), or those of a done-done evidence run at the merged head.
  The card key is the merge's own (`merge-<owner>-<repo>-pull-<n>`, or `merge-<head>` for a local merge), so a repeat post or a second home adds nothing.
  sign-off-axi writes the board under its lock and only appends.

Both subcommands need `done-done >= 0.3.1` (`--citation-base`), `sign-off-axi`, `jq` and `gh` on `PATH`, plus `FM_HOME` set.

Install into one home, so the post-merge hook calls `post` once for each recorded merge:

```sh
printf '#!/bin/sh\nexec <addons>/merge-card/merge-card gate "$@"\n' > $FM_HOME/config/merge-gate
printf '#!/bin/sh\nexec <addons>/merge-card/merge-card post --board <board.json> "$@"\n' > $FM_HOME/config/post-merge
chmod +x $FM_HOME/config/merge-gate $FM_HOME/config/post-merge
```

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

