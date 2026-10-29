#!/usr/bin/env bash
# jg-tmp-sweep.sh - /tmp inode guard: report inode pressure and sweep stale fleet scratch.
#
# A tmpfs /tmp has a fixed inode budget, and fleet tooling leaks many small
# entries into it (mktemp dirs, per-home agent scratch, tool caches). When the
# inodes run out, wake acknowledgements and tools fail even with free space.
# bin/jg-sentinel.sh tick calls both modes below; this script owns the policy.
#
# Usage:
#   jg-tmp-sweep.sh check [--root DIR] [--warn-pct N]
#       Print the inode use of the filesystem holding DIR; exit 1 at or above N
#       percent (default JG_TMP_INODE_WARN_PCT, else 80), 0 below it, 2 when the
#       use cannot be read.
#   jg-tmp-sweep.sh sweep [--dry-run | --apply] [--root DIR] [--min-age-days N]
#       List (default, --dry-run) or remove (--apply) stale entries; see below.
#
# What a sweep may remove, all directly under DIR (default /tmp, JG_TMP_ROOT):
#   - an entry named tmp.*, crewhouse-*, or claude-accounts.* (file or directory);
#   - an entry directly inside a container named claude-<digits> (per-home agent
#     scratch) or opencode; the container itself is never removed.
# Anything else is never touched and is only counted by name prefix.
# An allowlisted entry is kept unless every one of these holds:
#   - it is a real file or directory (never a symlink) owned by this user;
#   - nothing in its tree, including itself, changed in the last N days
#     (default 2, JG_TMP_SWEEP_MIN_AGE_DAYS);
#   - no live process has it as a cwd, an open file, a command-line argument or
#     an environment value, or inside any of those (read from /proc);
#   - no live lane owns it: no state/*.meta of JG_HOME (when set) names its
#     task id or its worktree path as part of the entry name, and it is not
#     inside or above a directory recorded in state/*.scratch.
# A host with no /proc cannot prove liveness, so a sweep there refuses (exit 3).
# Removal is find -P -xdev -depth -delete on the one checked path: symlinks are
# removed as links and never followed, and other filesystems are not entered.
# Output: one "remove <path>" (or "would remove <path>") line per entry, then a
# summary with the kept counts by reason and the not-allowlisted count by prefix.
# Exit: 0 after a pass, 1 when a removal failed, 2 for usage, 3 when unsafe.
set -u

ROOT=${JG_TMP_ROOT:-/tmp}
WARN_PCT=${JG_TMP_INODE_WARN_PCT:-80}
MIN_AGE_DAYS=${JG_TMP_SWEEP_MIN_AGE_DAYS:-2}

usage() { sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "jg-tmp-sweep: $*" >&2; exit "${2:-2}"; }

MODE=${1:-}
case "$MODE" in
  check|sweep) shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || die "--root needs a value"; ROOT=$2; shift 2 ;;
    --warn-pct) [ $# -ge 2 ] || die "--warn-pct needs a value"; WARN_PCT=$2; shift 2 ;;
    --min-age-days) [ $# -ge 2 ] || die "--min-age-days needs a value"; MIN_AGE_DAYS=$2; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$WARN_PCT" in ''|*[!0-9]*) die "warn percent must be a number" ;; esac
case "$MIN_AGE_DAYS" in ''|*[!0-9]*) die "min age days must be a number" ;; esac
case "$ROOT" in /*) ;; *) die "root must be an absolute path" ;; esac
case "$ROOT" in *[*?[]*|*$'\n'*|*//*|*/./*|*/../*|*/.|*/..) die "root has a glob, newline or dot component" ;; esac
[ "$ROOT" = / ] || ROOT=${ROOT%/}
[ -d "$ROOT" ] && [ ! -L "$ROOT" ] || die "root is not a real directory: $ROOT"
[ "$ROOT" != / ] || die "refusing to sweep /"

# "<used-percent> <used> <total>" for the filesystem holding ROOT; fails when unreadable.
inode_use() {
  df -Pi "$ROOT" 2>/dev/null | awk 'NR==2 && $2 ~ /^[0-9]+$/ && $2 > 0 { printf "%d %d %d\n", $3 * 100 / $2, $3, $2; ok = 1 } END { exit ok ? 0 : 1 }'
}

if [ "$MODE" = check ]; then
  use=$(inode_use) || die "cannot read inode use of $ROOT"
  read -r pct used total <<<"$use"
  printf '%s inodes %s%% used (%s of %s)\n' "$ROOT" "$pct" "$used" "$total"
  [ "$pct" -lt "$WARN_PCT" ]
  exit $?
fi

[ -d /proc/self ] || die "no /proc here, so liveness of a scratch entry cannot be proven; refusing to sweep" 3
NOW=$(date +%s)
CUTOFF=$(( NOW - MIN_AGE_DAYS * 86400 ))
CUTOFF_STAMP=$(date -u -d "@$CUTOFF" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) \
  || CUTOFF_STAMP=$(date -u -r "$CUTOFF" '+%Y-%m-%d %H:%M:%S')

# Newline-delimited "<name>" and "<name>/<child>" keys, relative to ROOT, of the
# paths that live processes use plus recorded lane scratch. An entry is live when
# its own key is listed, which is when it holds, or contains, a path in use.
ROOT_RE=$(printf '%s' "$ROOT" | sed 's/[][\.*^$+?(){}|]/\\&/g')
LIVE_KEYS=$(
  {
    for p in /proc/[0-9]*; do
      {
        readlink "$p/cwd" "$p"/fd/*
        for f in cmdline environ; do
          tr '\0' '\n' <"$p/$f" | grep -aoE "$ROOT_RE/[^[:space:]:\"'=]+"
        done
      } 2>/dev/null
    done
    [ -z "${JG_HOME:-}" ] || cat "$JG_HOME"/state/*.scratch 2>/dev/null
  } | sed 's/ (deleted)$//' | awk -v r="$ROOT/" 'index($0, r) == 1 { n = split(substr($0, length(r) + 1), c, "/"); print c[1]; if (n > 1) print c[1] "/" c[2] }' | sort -u
)

# Lane tokens: a task id or worktree path that, as an entry-name part, marks the entry as a lane's.
LANE_TOKENS=
if [ -n "${JG_HOME:-}" ]; then
  for meta in "$JG_HOME"/state/*.meta; do
    [ -f "$meta" ] || continue
    LANE_TOKENS="$LANE_TOKENS
$(basename "$meta" .meta)"
    wt=$(sed -n 's/^worktree=//p' "$meta" | head -n 1)
    [ -z "$wt" ] || LANE_TOKENS="$LANE_TOKENS
$(printf '%s' "$wt" | tr '/.' '--')"
  done
fi

# Why <path> (an absolute path under ROOT) must be kept; prints nothing when it may go.
keep_reason() {
  local path=$1 name=${1##*/} rel token
  [ ! -L "$path" ] || { echo symlink; return; }
  [ -O "$path" ] || { echo not-owned; return; }
  rel=${path#"$ROOT"/}
  case "
$LIVE_KEYS
" in *"
$rel
"*) echo live-process; return ;; esac
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    case "$name$path" in *"$token"*) echo live-lane; return ;; esac
  done <<EOF
$LANE_TOKENS
EOF
  if [ -d "$path" ] && [ -n "$(find -P "$path" -xdev -newermt "$CUTOFF_STAMP" -print -quit 2>/dev/null)" ]; then
    echo recent; return
  fi
}

REMOVED=0; FAILED=0; KEPT_LIST=; OTHER=0
note_keep() { KEPT_LIST="$KEPT_LIST
$1"; }

consider() {  # <absolute path of an allowlisted entry>
  local entry=$1 why
  why=$(keep_reason "$entry")
  if [ -n "$why" ]; then note_keep "$why"; return; fi
  if [ "$APPLY" = 1 ]; then
    # A read-only directory (a locked hooks folder) blocks its own removal; unlock this entry's directories first.
    find -P "$entry" -xdev -type d ! -perm -u+rwx -exec chmod u+rwx {} + 2>/dev/null
    if find -P "$entry" -xdev -depth -delete 2>/dev/null; then
      printf 'remove %s\n' "$entry"; REMOVED=$((REMOVED + 1))
    else
      printf 'FAILED %s\n' "$entry" >&2; FAILED=$((FAILED + 1))
    fi
  else
    printf 'would remove %s\n' "$entry"; REMOVED=$((REMOVED + 1))
  fi
}

# Entries are walked by name only (no forks per entry); just the ones whose own
# mtime is already older than the cutoff go through the deeper keep_reason checks.
old_entries() {  # <dir>: NUL-separated children whose own mtime is older than the cutoff
  find -P "$1" -mindepth 1 -maxdepth 1 ! -newermt "$CUTOFF_STAMP" -print0 2>/dev/null
}

before=$(inode_use) || before="? ? ?"
OTHER_PREFIXES=; ALLOWED=0; CONSIDERED=0; CONTAINERS=
for entry in "$ROOT"/* "$ROOT"/.[!.]*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  name=${entry##*/}
  case "$name" in
    tmp.*|crewhouse-*|claude-accounts.*) ALLOWED=$((ALLOWED + 1)) ;;
    claude-[0-9]*|opencode)
      if [ -d "$entry" ] && [ ! -L "$entry" ]; then
        CONTAINERS="$CONTAINERS
$entry"
        for child in "$entry"/* "$entry"/.[!.]*; do
          [ -e "$child" ] || [ -L "$child" ] || continue
          ALLOWED=$((ALLOWED + 1))
        done
      fi
      ;;
    *) OTHER=$((OTHER + 1)); OTHER_PREFIXES="$OTHER_PREFIXES
${name%%[.+_-]*}" ;;
  esac
done
while IFS= read -r -d '' entry; do
  case "${entry##*/}" in
    tmp.*|crewhouse-*|claude-accounts.*) CONSIDERED=$((CONSIDERED + 1)); consider "$entry" ;;
  esac
done < <(old_entries "$ROOT")
# A container is never removed itself, however old; only its old children are.
while IFS= read -r container; do
  [ -n "$container" ] || continue
  while IFS= read -r -d '' child; do
    CONSIDERED=$((CONSIDERED + 1)); consider "$child"
  done < <(old_entries "$container")
done <<EOF
$CONTAINERS
EOF
RECENT=$((ALLOWED - CONSIDERED))
after=$(inode_use) || after="? ? ?"

verb="would remove"; [ "$APPLY" = 0 ] || verb="removed"
printf '%s %d entries older than %s days (cutoff %s UTC)\n' "$verb" "$REMOVED" "$MIN_AGE_DAYS" "$CUTOFF_STAMP"
printf 'kept by reason:'
printf '%s\n' "$KEPT_LIST" | grep -v '^$' | sort | uniq -c | awk -v q="$RECENT" '{printf " %s=%s", $2, $1} END {printf " recent-by-own-mtime=%d\n", q}'
printf 'not allowlisted, left alone: %d entries; top prefixes:' "$OTHER"
printf '%s\n' "$OTHER_PREFIXES" | grep -v '^$' | sort | uniq -c | sort -rn | head -n 8 | awk '{printf " %s=%s", $2, $1}'
printf '\n'
read -r b _ <<<"$before"
read -r a _ <<<"$after"
printf 'inode use of %s: %s%% before, %s%% after\n' "$ROOT" "$b" "$a"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
