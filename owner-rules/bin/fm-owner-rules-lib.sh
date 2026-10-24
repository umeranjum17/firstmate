#!/usr/bin/env bash
# fm-owner-rules-lib.sh - brief-time owner rules for a lane. Source only.
#
# brief-inherit's fm_brief_inherit_shared sources this and calls
#   fm_owner_rules_check <data-dir> <task-id> <mode> <kind>
# when owner-rules/install.sh wrote config/owner-rules. It reads the home's backlog entry whose id
# is the task id and exits 1, before fm-brief.sh writes anything, when the lane breaks a rule.

fm_owner_rules_check() {
  local data=$1 id=$2 mode=$3 kind=$4 entry title risks parent exists
  [ "$kind" != secondmate ] || return 0
  # Entry = the "- [.] <id> - <title>" line and its indented body, up to the next item or heading.
  entry=$(awk -v id="$id" '
    /^- \[.\] / { on = (substr($0, 7, length(id) + 1) == id " ") } /^## / { on = 0 } on' "$data/backlog.md" 2>/dev/null)
  title=$(printf '%s\n' "$entry" | head -n 1)
  title=${title#*"$id"}
  title=${title# - }
  if [[ $title != '[captain-ask]'* ]] && ! printf '%s\n' "$entry" | grep -Eq '(^|[^[:alnum:]])Main[0-9]+'; then
    echo "owner-rules: no owner ask: name the [captain-ask] item or the MainNNN order this lane serves (add it to the backlog item for $id)" >&2
    exit 1
  fi
  if [ "$kind" != scout ] && [[ $title != '[captain-ask]'* ]]; then
    parent=$(printf '%s\n' "$entry" | awk '/^[[:space:]]*parent:[[:space:]]*/ { sub(/^[[:space:]]*parent:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }')
    exists=0
    if [ "$parent" = upkeep ]; then
      exists=1
    elif [ -n "$parent" ]; then
      exists=$(awk -v id="$parent" '/^- \[[^]]\] / { row = substr($0, 7); split(row, fields, /[[:space:]]+/); if (fields[1] == id) found = 1 } END { print found + 0 }' "$data/backlog.md" 2>/dev/null)
    fi
    if [ "$exists" -ne 1 ]; then
      echo "owner-rules: no valid parent: add parent: <backlog item id> or parent: upkeep to the backlog item for $id" >&2
      exit 1
    fi
  fi
  [ "$kind" = ship ] && [ "$mode" = no-mistakes ] || return 0
  risks=$(printf '%s\n' "$entry" | tail -n +2 | grep -Ec '^[[:space:]]*risk:[[:space:]]*(release|security|migration|large-change|shared-protocol|fork-repo)[[:space:]]*$') || true
  if [ "$risks" -ne 1 ]; then
    echo "owner-rules: mode no-mistakes needs one listed risk reason (release, security, migration, large-change, shared-protocol, fork-repo) in the backlog item for $id; use direct-PR plus a done-done check" >&2
    exit 1
  fi
}
