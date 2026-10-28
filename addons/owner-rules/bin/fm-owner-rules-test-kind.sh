#!/usr/bin/env bash
# fm-owner-rules-test-kind.sh <worktree|-> <head> <pr-url|-> - refuse a change that adds a unit, snapshot or mock test.
# This repo takes integration and end-to-end journey tests only (defaults/brief-include.md). A no-op when the
# change adds no test file, or when its added files cannot be listed (no checkout holding the head, no readable PR).
# The classifier, for each ADDED file, in this order (case-insensitive):
#   1. not a test file -> skip. A test file sits under tests/ test/ spec/ __tests__/, or is named *.test.* *.spec.*
#      *_test.* test_* or *.snap.
#   2. a path word unit, snapshot(s) or mock(s), or a *.snap file -> refuse.
#   3. a path word e2e, integration or journey -> pass.
#   4. content using a snapshot or mock library (toMatchSnapshot, jest.mock, vi.mock, unittest.mock, @patch,
#      MagicMock, sinon.stub, gomock, mockall) -> refuse; anything else passes.
set -u
[ "$#" -eq 3 ] || { echo "usage: fm-owner-rules-test-kind.sh <worktree|-> <head> <pr-url|->" >&2; exit 2; }
wt=$1 head=$2 pr=$3
added=
if [ "$wt" != - ] && git -C "$wt" cat-file -e "$head^{commit}" 2>/dev/null; then
  for b in refs/remotes/origin/HEAD origin/main main master; do
    git -C "$wt" rev-parse --verify -q "$b" >/dev/null && { base=$b; break; }
  done
  [ -z "${base:-}" ] || added=$(git -C "$wt" diff --name-only --diff-filter=A "$base...$head" 2>/dev/null)
  show() { git -C "$wt" show "$head:$1" 2>/dev/null; }
elif [[ $pr =~ ^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
  nwo=${BASH_REMATCH[1]}
  added=$(gh api --paginate "repos/$nwo/pulls/${BASH_REMATCH[2]}/files" --jq '.[] | select(.status == "added") | .filename' 2>/dev/null)
  show() { gh api -H 'Accept: application/vnd.github.raw' "repos/$nwo/contents/$1?ref=$head" 2>/dev/null; }
fi
what=$pr; [ "$pr" != - ] || what="local merge $head"
shopt -s nocasematch
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [[ $f =~ (^|/)(tests?|specs?|__tests__)/ || $f =~ \.(test|spec)\.[^/]+$ || $f =~ _test\.[^/]+$ || $f =~ (^|/)test_[^/]+$ || $f =~ \.snap$ ]] || continue
  if [[ $f =~ \.snap$ || $f =~ (^|[^a-z])(unit|snapshots?|mocks?)([^a-z]|$) ]]; then why="its path marks a unit, snapshot or mock test"
  elif [[ $f =~ (^|[^a-z])(e2e|integration|journeys?)([^a-z]|$) ]]; then continue
  elif show "$f" | grep -Eq 'toMatch(Inline)?Snapshot|(jest|vi)\.mock\(|unittest\.mock|@patch\(|MagicMock|sinon\.(stub|mock)|gomock|mockall'; then why="it uses a snapshot or mock library"
  else continue; fi
  echo "owner-rules: $what adds $f, and $why; this repo takes integration and end-to-end journey tests only. Replace it with a test that drives the real product like a user, or extend the journey test your change touches"
  exit 1
done <<< "$added"
exit 0
