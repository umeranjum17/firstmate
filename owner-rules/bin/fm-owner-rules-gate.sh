#!/usr/bin/env bash
# fm-owner-rules-gate.sh <task-id> <worktree|-> <head|-> <pr-url|-> - the merge-gate half of owner-rules.
# config/merge-gate runs this first, with the gate args and FM_HOME set. It refuses (exit 1, one line naming
# the PR) a merge with no passed-proof receipt: no sealed clean done-done run at the merge head in the task's
# folder. A merge that declares `screen: none` is exempt, as merge-card's post exempts it. A no-op when
# config/owner-rules is absent. Reuses merge-card's own checks (`merge-card receipt`, `merge-card screen-none`).
set -u
[ "$#" -eq 4 ] || { echo "usage: fm-owner-rules-gate.sh <task-id> <worktree|-> <head|-> <pr-url|->" >&2; exit 2; }
[ -n "${FM_HOME:-}" ] && [ -e "$FM_HOME/config/owner-rules" ] || exit 0
mc=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../merge-card" && pwd -P)/merge-card
"$mc" screen-none "$1" "$4" && exit 0
[ "$3" != - ] && "$mc" receipt "$1" "$3" && exit 0
what=$4; [ "$4" != - ] || what="local merge $3"
echo "owner-rules: no passed-proof receipt for $what; run the done-done check and post the evidence to the sign-off Evidence tab first"
exit 1
