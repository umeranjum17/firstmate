# account-pool

A home that keeps a pool of logins for one tool can have its worker launches pick the account with the most room instead of always starting on the one default login, and `relaunch --account <id|next>` moves a running worker between those accounts.
This add-on owns all of it: `bin/fm-account-pool-lib.sh` parses `config/account-pool`, maps the harness to its pool tool, runs the pool command, builds the launch prefix, runs the relaunch-time choice gate and rest, and writes every refusal message.

## Wiring

The fork's `bin/fm-spawn.sh` and `bin/fm-control.sh` carry one setup line that sources the lib from `$FM_ADDONS_DIR` (else `$FM_HOME/projects/firstmate-addons`) and makes `fm_account_hook` a no-op when the add-on is absent, plus one `fm_account_hook <event>` line at each call site:

| Script | Events, in call order |
|---|---|
| `bin/fm-spawn.sh` | `argv` (eval'd before the argument loop), `spawn-validate`, `raw-launch`, `spawn-pick <harness> <config> <pin> <want>`, `record-line`, `launch-prefix`, `spawn-line` |
| `bin/fm-control.sh` | `argv`, `control-validate <verb>`, `relaunch-pre <harness> <config> <to-model> <recorded-id> <from-model> <task>`, `relaunch-commit <harness> <config> <recorded-id>` (the last step before the stop), `spawn-args` |

With the add-on absent every hook line prints nothing and returns 0, and `--account` is the caller's own unexpected argument, as upstream.
An unknown event is a no-op too, so a newer fork never fails against an older add-on checkout.
`install.sh <home>` checks the wiring and changes nothing.

## config/account-pool

The pool is opt-in and secondary to the pin: with no file every launch is unchanged, and a home pin (`config/claude-account`, `config/pi-account`) always wins for its own named runner.
The file is local and gitignored.
It holds one `state=<absolute pool folder>`, the folder that holds the pool's `pool.json`, and optionally one `command=<byokit-accounts command>`, either a bare name resolved from `PATH` (the default `byokit-accounts`) or an absolute path.
Blank lines and `#` comments are ignored. A file with no usable `state=`, a relative `state=` path, or a `command=` that names a relative path refuses the launch and names the file.

The pool applies to the harnesses whose pool tool exists: `claude` to `claude`, `codex` to `codex`, and `pi` and `pi-signed` to `pi`. Every other harness keeps its launch.
When no pin applies and the harness is mapped, the launch runs `<command> pick <tool> --json --state <state>` before any endpoint, local copy, or task record exists, and before a relaunch stops the running worker. The command answers with the ready, not-resting account with the most room, from the same list `byokit-accounts list` shows.

A launch carries the picked folder as an `env -u <name> ... <VAR>=<folder>` prefix on the launch line (`CLAUDE_CONFIG_DIR` for Claude, `CODEX_HOME` for Codex, `PI_CODING_AGENT_DIR` for Pi), so the launch line and the task record hold folder paths only.
No key, token, or login file ever reaches a launch line, a task record, a log, a status line, or an error message.
The spawn prints the pick as `account=<id>` and records the same field in the task record.
While `config/account-pool` exists, raw launch commands refuse before account selection, even when a pin applies. Use a named harness such as `--harness claude` so a command or shell wrapper cannot bypass or override the selected account.

A malformed file (including one that is not a readable regular file, such as a broken symlink) refuses the launch before anything is created. So does a `pick` that exits non-zero, an answer whose `unset` is not an array of environment-variable names, and an answer that names no usable account folder: not the tool's own store variable, or not an existing readable, searchable directory.
A failed `pick` refusal names the tool and the login to do, and says which accounts are resting or signed out. Firstmate never falls back to an ambient login or copies a credential.
The pool is not inherited into secondmate homes: a local secondmate agent launches on the launching home's pool, and the secondmate's own workers read the secondmate home's file.

## Moving one worker between accounts (relaunch --account)

`bin/fm-control.sh <task-id> relaunch --account <id|next>` moves a running worker onto a different pool account while it replaces the agent. The local copy, its commits and its uncommitted work stay as they are, as with any relaunch.

`--account <id>` selects that account for this launch, and it is the only way to select an OpenCode Go one. The pick runs with `--prefer <id>`, and the launch refuses unless the pool answers with exactly that account, so an account that is resting, signed out, or another tool's is never launched by accident.
`--account next` rests the account the running worker launched on, for that account's own default rest, and launches the worker on another one. `byokit-accounts unrest <id>` returns a rested account to the rotation.
`next` reads the recorded account's tool with `status <id> --json --state <state>` and rests it with `rest <id> --json --state <state>`. A custom `command=` that lacks either gets a plain refusal, never a half-done move.

These refusals all happen before the running agent stops:
- a malformed choice;
- a harness whose pool tool does not exist;
- a home with no `config/account-pool`;
- `next` on a task that records no pool account;
- an OpenCode Go account, or a worker on an `opencode-go` provider (automatic moves are fixed in code to Claude, Codex and Pi logins, and the refusal names the manual command);
- an account that cannot take the worker;
- a pick that answers a different account than the requested one.

The rest and the proving pick are the last steps before the stop. With exactly one account in the pool, `next` rests it and then refuses, so the worker keeps working while its account rests.
One refusal can land after the stop: the launch owner (`fm-spawn --relaunch`) picks again at launch, so pool state that changed in between refuses there and the rollback reports the stopped agent with its work preserved.
`fm-spawn --relaunch --account next` outside fm-control refuses, because only fm-control's pre-stop gate rests the recorded account. A fresh spawn refuses `--account`: it picks on its own.
A home pin still wins: with a pin file for that runner, `--account` refuses rather than being silently ignored.
The replacement records the selected account as `account=`, exactly as a spawn-time pick does.

## Test

`bash account-pool/tests/account-pool.test.sh` drives the hook lines in their fork call-site form, a stub `byokit-accounts` and a synthetic pane through every case above, and checks that the add-on absent leaves each line a no-op. `bash account-pool/run-tool-proof.sh` (done-done journey `pool-tool-account`) proves a tool started on the pool's pick inherits the picked folder.
