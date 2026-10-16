#!/usr/bin/env bash
# delete-guard watcher check: prints one wake line for delete-guard.log rows appended since the last sweep, and
# nothing when there are none. Usage: check.sh <fm-home>
set -u
LOG="$1/state/delete-guard.log" SEEN="$1/state/.delete-guard.seen"
[ -f "$LOG" ] || exit 0
total=$(wc -l < "$LOG")
seen=$(cat "$SEEN" 2>/dev/null || echo 0)
case "$seen" in '' | *[!0-9]*) seen=0 ;; esac
[ "$seen" -le "$total" ] || seen=0
[ "$total" -gt "$seen" ] || exit 0
new=$(head -n "$total" "$LOG" | tail -n "$((total - seen < 5 ? total - seen : 5))" \
  | jq -r '"\(if (.task // "") == "" then "no task" else "task " + .task end) (\(.runtime), home \(if (.home // "") == "" then "?" else .home end), cwd \(.cwd)): \(.command[:160])"' 2>&1 | paste -sd ';' -)
printf '%s\n' "$total" > "$SEEN.$$" && mv "$SEEN.$$" "$SEEN"
printf 'delete guard blocked %s recursive delete(s), see %s; latest: %s\n' "$((total - seen))" "$LOG" "$new"
