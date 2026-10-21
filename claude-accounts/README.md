# claude-accounts

One quota view of every Claude account signed in on this machine.

`bin/claude-accounts-quota.sh` reads the account list from the muxr registry (`~/.muxr/plans/accounts-v1.json`, or `FM_CLAUDE_ACCOUNTS_REGISTRY`), takes only the `id`, `name` and `folder` of each Claude account, and runs `quota-axi --provider claude --profile-only --json` with `CLAUDE_CONFIG_DIR` set to that folder. It never opens, copies, links or edits anything inside a login folder, and changes nothing about how accounts sign in.

It writes `<home>/state/claude-accounts.json` (atomic replace):

```json
{"schema":1,"generated_at":1792566241,"accounts":[
  {"id":"found-claude","name":"default","folder":"/path/to/profile",
   "five_hour":{"left":63,"resets_at":"2026-10-21T08:39:59+00:00"},
   "seven_day":{"left":34,"resets_at":"2026-10-26T12:59:59+00:00"},"problem":null}]}
```

`left` is percent remaining; a window that could not be read is `null` and the account's `problem` names the cause. Exit 0 when at least one account was read. Run it on a timer (a few minutes apart); `--print` also shows the file.

The fleet dashboard's Overview and index page show a "Claude accounts" card from that file; the card is absent when the file is.

Test: `bash claude-accounts/tests/claude-accounts.test.sh`.

## Automatic account choice for new workers

`bin/claude-accounts-pick` is a `config/account-pool` command: fm-spawn already runs `<command> pick claude --json` for every new Claude worker and launches it with the folder the answer names, so no core change is needed. The pick uses a quota reading no older than 2 minutes (it runs the reader otherwise) and takes the account with the most runway, the tighter of its 5h and 7d left. An account under 5% left is skipped, so new workers go to the other account when one runs low; if every account is low the spawn is refused with that cause. `--prefer <id>` (a relaunch's `--account`) is honored only for an account that has quota. Running workers are never moved: the choice happens at launch only. Codex and Pi get their ambient folder, unchanged.

Wire in: `claude-accounts/install.sh <home>` writes `<home>/config/account-pool`; remove with `claude-accounts/uninstall.sh <home>`. It refuses to replace a different account-pool file, and it never touches a pin file (`config/claude-account`). Install from merged main only.

Test: `bash claude-accounts/tests/claude-accounts-pick.test.sh`.
