# merge-card

`merge-card` remains the gate/check/post executable documented in the root [README](../README.md#merge-card).
Its existing config shims and card behavior are unchanged.

## Naming the claim

`merge-card post --board <board.json> --claim-id <id> <task-id> <worktree|-> <head|-> <pr-url|->` passes `--claim-id <id>` to the `done-done check` it runs, for a PR whose evidence is bound to a claim other than done-done's default (the PR branch name). The check re-runs even when the gate left a record. Without the flag nothing changes. `merge-card check` takes the same flag.

## Naming the judge for one call

`merge-card gate|check|post [--judge <route>]` passes `--judge <route>` to the `done-done check` it runs, so a lane whose configured judge route is rate limited can name another one for that merge instead of waiting on done-done's fallback. Without the flag nothing changes: done-done checks the proof with its own configured judge.

## One card per PR

The first card for a PR takes the PR's key (`merge-<owner>-<repo>-pull-<n>`). A post for a new head posts its card through `sign-off-axi post --kind evidence` under that key plus a 12-character head suffix, then archives (`sign-off-axi dismiss`) the PR's earlier live cards, so the board has one live card and the history stays under Archived. sign-off-axi takes evidence one post at a time and holds a key to its first message, so there is no `--from --replace` feed. A repeat post for a head adds nothing; a post for a head whose card was dismissed restores that card.
A screen-free merge's card is titled `<repo> #<n>: internal change passed its checks`.

## Optional fork adapters

`bin/fm-merge-hooks-lib.sh` owns the fork-only `fm_dod_merge_gate` and `fm_merge_post_hook` adapters, with their existing names, arguments, timeout defaults and messages.
The gate prints output on success and failure; a failing, non-executable, dangling or timed-out gate refuses the merge.
The post hook prints output and reports failure without refusing an already completed merge.
These functions require the caller's upstream `fm_run_timed`, `fm_timed_out` and `fm_dod_meta_value` helpers; no Kun implementation is copied here.

The fork sources this library from the add-on checkout, selected by `FM_ADDONS_DIR` (default `$FM_HOME/projects/firstmate-addons`), through the seam merged in fork PR 115.
Each invocation is guarded with `if declare -F <function> >/dev/null; then <existing call>; fi`.
There is no installer change: the existing config shims still invoke the executable.

An absent library defines no adapter and runs no config hook, preserving Kun's behavior even under `set -e`.
Removing the add-on directory disables this integration; removing only the config shims disables the corresponding policies.

## Integration proof

```bash
FM_TEST_FORK=/path/to/read-only/firstmate bash merge-card/tests/merge-hooks-e2e.sh
bash merge-card/tests/merge-card-e2e.sh
bash merge-card/tests/real-board.test.sh
```

The seam test runs the unmodified fork bin against the add-on loader selected by `FM_ADDONS_DIR`.
It exercises real local merges and actual config executables, testing refusal, exact arguments, non-executable/dangling gates, timeout, successful output, post failure, repeat suppression, missing config hooks and a completely absent add-on.
It does not start or arm a watcher, contact a forge, post cards or launch a harness.

`real-board.test.sh` runs the real `merge-card post` against the real `sign-off-axi` on a seeded temp board (its own `SIGN_OFF_HOME`) and proves a new head leaves one live card with the old one archived.
