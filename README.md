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
