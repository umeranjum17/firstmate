# Merge evidence one card per PR

## User outcome

The Evidence board shows one card for each PR: a re-proof at a new head replaces the card and keeps the newest proof, and a screen-free merge's card is titled with its repo and PR number.

## Drive

Run `bash merge-card/tests/merge-card-e2e.sh` from the repository root. It posts to a fixture board through a stub sign-off-axi and never touches a real board.

## Evidence

The `new head`, `two PRs` and `internal title` assertions print `ok`; the run ends with `all assertions held`.

## Real sign-off-axi

Run `bash merge-card/tests/real-board.test.sh`. It runs the real `merge-card post` against the real `sign-off-axi` on a seeded temp board (its own `SIGN_OFF_HOME`), posts a PR's card at one head and again at a new head, and prints `all assertions held` when exactly one card is live, the old one is archived with its history kept, and a repeat post adds nothing.
