# merge-card

`merge-card` remains the gate/check/post executable documented in the root [README](../README.md#merge-card).
Its existing config shims and card behavior are unchanged.

## One card per PR

The card key is the PR's alone (`merge-<owner>-<repo>-pull-<n>`). A post for a new head replaces that PR's card, and any head-suffixed card an older merge-card filed for it, so the board keeps the newest proof; a repeat post for the same head adds nothing.
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
```

The seam test runs the unmodified fork bin against the add-on loader selected by `FM_ADDONS_DIR`.
It exercises real local merges and actual config executables, testing refusal, exact arguments, non-executable/dangling gates, timeout, successful output, post failure, repeat suppression, missing config hooks and a completely absent add-on.
It does not start or arm a watcher, contact a forge, post cards or launch a harness.
