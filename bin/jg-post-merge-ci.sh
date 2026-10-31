#!/usr/bin/env bash
# Watch the GitHub run of a head this home merged ahead of CI, and open exactly
# one fix item if it goes red. This is an alarm, never a gate: the merge already
# happened, so nothing here can refuse or undo it.
#
# Usage: jg-post-merge-ci.sh <task-id> <PR URL> <merged head>
#
# bin/jg-local-suite-lib.sh's jg_local_suite_arm_ci_alarm starts this detached
# right after a merge proven by the local suite, so the merge returns at once.
# It polls the runs filed against that exact commit until every run finishes or
# JG_POST_MERGE_CI_DEADLINE seconds pass (default 2700, polled every
# JG_POST_MERGE_CI_INTERVAL seconds, default 30). A run that ends in failure,
# timed_out, startup_failure or action_required is red.
#
# One item per task and head: data/jg-post-merge-ci/<task>.filed records that an
# item was opened, so a re-run cannot file a second one. The item names the run
# id, so a reader opens the failing run directly. A wake line is queued too, so
# the red result reaches the lead instead of sitting in a log.
# A deadline that passes with runs still going, an unreadable run list, or a
# backlog that refuses the add are all reported in the log and change nothing
# else, because an alarm that cannot report itself must not pretend it did.
# Run it by hand any time: its exit status is 0 once it reached a verdict or its
# deadline, and 2 for a malformed request.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"

if [ "$#" -ne 3 ] || [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
  echo "usage: jg-post-merge-ci.sh <task-id> <PR URL> <merged head>" >&2
  exit 2
fi
ID=$1
URL=$2
HEAD=$3
DEADLINE_SECS=${JG_POST_MERGE_CI_DEADLINE:-2700}
INTERVAL=${JG_POST_MERGE_CI_INTERVAL:-30}
case "$DEADLINE_SECS" in ''|*[!0-9]*) DEADLINE_SECS=2700 ;; esac
case "$INTERVAL" in ''|0*|*[!0-9]*) INTERVAL=30 ;; esac

DIR="$DATA/jg-post-merge-ci"
FILED="$DIR/$ID.filed"
mkdir -p "$DIR" || exit 0
say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

if [ -e "$FILED" ]; then
  say "already filed for $ID at head $HEAD ($(cat "$FILED" 2>/dev/null))"
  exit 0
fi

deadline=$(( $(date +%s) + DEADLINE_SECS ))
while :; do
  runs=$(gh run list --commit "$HEAD" --limit 50 \
    --json databaseId,status,conclusion,workflowName 2>/dev/null) || runs=
  if [ -n "$runs" ]; then
    pending=$(printf '%s' "$runs" | jq -r '[.[] | select(.status != "completed")] | length' 2>/dev/null) || pending=''
    red=$(printf '%s' "$runs" | jq -r '
      [ .[] | select(.status == "completed")
        | select(.conclusion == "failure" or .conclusion == "timed_out"
                 or .conclusion == "startup_failure" or .conclusion == "action_required") ]
      | .[0] // empty | "\(.databaseId) \(.workflowName) \(.conclusion)"' 2>/dev/null) || red=''
    if [ -n "$red" ]; then
      run_id=${red%% *}
      rest=${red#* }
      workflow=${rest% *}
      conclusion=${rest##* }
      item="ci-red-$ID"
      repo=$(printf '%s' "$URL" | sed -n 's#^https://github.com/\([^/]*/[^/]*\)/pull/.*#\1#p')
      body="The merge of $URL landed on the proof of its local suite receipt.
Its GitHub run at head $HEAD then went red: run $run_id ($workflow, $conclusion).
https://github.com/$repo/actions/runs/$run_id
Fix the failing check on main before the next change builds on it."
      if "$SCRIPT_DIR/jg-tasks-axi.sh" add "$item" \
        "[blocker] CI went red after merging $URL (run $run_id)" \
        --kind ship --body "$body" >/dev/null 2>&1; then
        printf '%s %s\n' "$run_id" "$HEAD" > "$FILED"
        say "filed $item for red run $run_id ($workflow, $conclusion) at head $HEAD"
        # shellcheck source=bin/jg-wake-lib.sh
        if . "$SCRIPT_DIR/jg-wake-lib.sh" 2>/dev/null; then
          jg_wake_append check "post-merge-ci-$ID" \
            "check: CI went red after merging $URL: run $run_id ($workflow) failed at head $HEAD; fix item $item opened" \
            >/dev/null 2>&1 || say "could not queue the red-CI wake"
        fi
      else
        say "CI went red at head $HEAD on run $run_id, but backlog item $item could not be added"
      fi
      exit 0
    fi
    if [ "$pending" = 0 ]; then
      say "every run for head $HEAD finished green"
      exit 0
    fi
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    say "no verdict for head $HEAD within ${DEADLINE_SECS}s; the GitHub run is still going or unreadable"
    exit 0
  fi
  sleep "$INTERVAL"
done
