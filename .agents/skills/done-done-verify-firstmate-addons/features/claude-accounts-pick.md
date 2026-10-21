# Claude accounts: the chooser for new workers

## User outcome

A new Claude worker starts on the signed-in account with the most quota runway, and on the other account when one runs low.

## Drive

Run `bash claude-accounts/tests/claude-accounts-pick.test.sh` (fixture registry, stub quota-axi, the add-on's own pool pick). For the real accounts, `FM_BIN=<fork bin> done-done run claude-accounts-pick` runs the pool pick fm-spawn calls against a throwaway config/account-pool, starts one tiny Haiku task on the picked profile folder and reads both accounts' quota before and after.

## Evidence

Capture `pick.txt` (ids, names and percentages only). Never open files inside a login folder or print a folder path or credential.
