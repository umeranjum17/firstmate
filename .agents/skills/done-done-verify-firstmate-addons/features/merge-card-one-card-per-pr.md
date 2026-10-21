# Merge evidence one card per PR

## User outcome

The Evidence board shows one card for each PR: a re-proof at a new head replaces the card and keeps the newest proof, and a screen-free merge's card is titled with its repo and PR number.

## Drive

Run `bash merge-card/tests/merge-card-e2e.sh` from the repository root. It posts to a fixture board through a stub sign-off-axi and never touches a real board.

## Evidence

The `new head`, `two PRs` and `internal title` assertions print `ok`; the run ends with `all assertions held`.
