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
