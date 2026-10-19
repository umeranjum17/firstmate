# merge-card

`merge-card` remains the gate/check/post executable documented in the root [README](../README.md#merge-card).
Its existing config shims and card behavior are unchanged.

## Optional fork adapters (step A)

`bin/fm-merge-hooks-lib.sh` owns the fork-only `fm_dod_merge_gate` and `fm_merge_post_hook` adapters, with their existing names, arguments, timeout defaults and messages.
The gate prints output on success and failure; a failing, non-executable, dangling or timed-out gate refuses the merge.
The post hook prints output and reports failure without refusing an already completed merge.
These functions require the caller's upstream `fm_run_timed`, `fm_timed_out` and `fm_dod_meta_value` helpers; no Kun implementation is copied here.

The fork still defines its own adapters until step B.
There is no installer change: the library is loaded from the add-on checkout, while the existing config shims still invoke the executable.
Step B replaces each adapter definition with this optional-source line and guards each invocation with `if declare -F <function> >/dev/null; then <existing call>; fi`:

```bash
[ ! -r "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/merge-card/bin/fm-merge-hooks-lib.sh" ] || . "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/merge-card/bin/fm-merge-hooks-lib.sh"
```

An absent library defines no adapter and runs no config hook, preserving Kun's behavior even under `set -e`.
Removing the add-on directory disables this integration after step B; removing only the config shims disables the corresponding policies.

## Integration proof

```bash
FM_TEST_FORK=/path/to/read-only/firstmate bash merge-card/tests/merge-hooks-e2e.sh
bash merge-card/tests/merge-card-e2e.sh
```

The seam test stages a private copy of the fork's bin directory and applies only the proposed definition/call replacements there.
It exercises real local merges and actual config executables, testing refusal, exact arguments, non-executable/dangling gates, timeout, successful output, post failure, repeat suppression, missing config hooks and a completely absent add-on.
It does not start or arm a watcher, contact a forge, post cards or launch a harness.
