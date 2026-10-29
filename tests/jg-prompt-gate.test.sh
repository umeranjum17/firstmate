#!/usr/bin/env bash
# Table regressions for the permission-prompt gate (bin/jg-prompt-gate.py and
# bin/jg-prompt-gate-lib.sh): which OpenCode "Access external directory"
# dialogs are approved, and that every other shape, path escape, or unprovable
# reading becomes a card. Screens copy the layout captured live from OpenCode
# 1.18.25; a `|` in a path marks where OpenCode wrapped it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/jg-prompt-gate.py"
TMP_ROOT=$(jg_test_tmproot jg-prompt-gate)
F="$TMP_ROOT/fleet"
SIDE='                                        LSP'

mkdir -p "$F/state/task1.inbox" "$F/state/pending-replies" "$F/bin" "$F/data" "$F/.agents/skills/s" "$F/wt/src" "$F/wt/.docker" \
  "$TMP_ROOT/fleet-evil/bin" "$TMP_ROOT/outside" "$TMP_ROOT/fle et/bin"
for f in state/task1.inbox/001.msg state/task1.inbox/.env state/task1.status state/task1x.status \
  state/other.status bin/a.sh AGENTS.md data/x .agents/skills/s/SKILL.md wt/src/a.js wt/.npmrc wt/id_rsa \
  wt/.docker/config.json wt/config.api_key; do : > "$F/$f"; done
: > "$TMP_ROOT/fleet-evil/bin/a.sh"
: > "$TMP_ROOT/outside/f"
: > "$TMP_ROOT/fle et/bin/a.sh"
ln -s "$TMP_ROOT/outside/f" "$F/state/task1.inbox/link"

# Message-area lines: the head at indent 5, each wrap at indent 7.
msg() {  # <glyph+tool> <path-with-|>
  local first=${2%%|*} rest=${2#*|}
  printf '     %s %s%s\n' "$1" "$first" "$SIDE"
  [ "$rest" = "$2" ] && return 0
  printf '%s\n' "$rest" | tr '|' '\n' | sed 's/^/       /'
}

# Panel lines: the dialog header at indent 4 (wraps at 6), patterns at indent 2.
screen() {  # <pending-tool> <target> <dir> [pattern] [extra-turn-lines]
  local pattern=${4:-$3/*} p
  printf '  \342\224\203  an earlier message\n     \342\226\243  Build \302\267 Model \302\267 1m 9s\n\n'
  printf '  \342\224\203  read your inbox\n%s' "${5-}"
  printf '     + Thought: 347ms\n'
  msg "$1" "$2"
  printf '     \342\226\243  Build \302\267 Model\n\n  \342\224\203\n  \342\224\203  \342\226\263 Permission required\n'
  printf '  \342\224\203    \342\206\220 Access external directory %s\n' "${3%%|*}"
  [ "${3#*|}" = "$3" ] || printf '%s\n' "${3#*|}" | tr '|' '\n' | sed 's/^/  \xe2\x94\x83      /'
  printf '  \342\224\203\n  \342\224\203  Patterns\n  \342\224\203                                                 sidebar\n'
  p=${pattern%%|*}
  printf '  \342\224\203  - %s%s\n' "$p" "$SIDE"
  [ "${pattern#*|}" = "$pattern" ] || printf '%s\n' "${pattern#*|}" | tr '|' '\n' | sed "s/^/  \xe2\x94\x83  /; s/\$/$SIDE/"
  printf '  \342\224\203\n  \342\224\203   Allow once   Allow always   Reject          ctrl+f fullscreen  enter confirm\n'
}

ROOTS=(--dir "inbox=$F/state/task1.inbox" --state-files "state=$F/state/task1"
  --dir "pending-replies=$F/state/pending-replies" --dir "tooling=$F/bin" --file "tooling=$F/AGENTS.md"
  --dir "tooling=$F/.agents/skills" --dir "worktree=$F/wt")
READ=$'\342\240\264 Read'

case_is() {  # <name> <expected verdict> <expected second field substring> <screen>
  local out
  out=$(printf '%s\n' "$4" | python3 "$GATE" opencode "${ROOTS[@]}")
  case "$out" in
    "$2"$'\t'*"$3"*) ;;
    "$2") [ -z "$3" ] || fail "$1: expected '$2 ... $3', got: $out" ;;
    *) fail "$1: expected '$2 ... $3', got: $out" ;;
  esac
}

test_allowed_reads_are_approved() {
  case_is "inbox message, wrapped" approve inbox "$(screen "$READ" "$F/state/|task1.inbox/001.msg" "$F/state/|task1.inbox")"
  case_is "own status file" approve state "$(screen "$READ" "$F/state/task1.status" "$F/state")"
  case_is "pending-replies directory" approve pending-replies "$(screen "$READ" "$F/state/pending-replies" "$F/state/pending-replies")"
  case_is "home tooling" approve tooling "$(screen "$READ" "$F/bin/a.sh" "$F/bin")"
  case_is "home AGENTS.md" approve tooling "$(screen "$READ" "$F/AGENTS.md" "$F")"
  case_is "skill under a dot root" approve tooling "$(screen "$READ" "$F/.agents/skills/s/SKILL.md" "$F/.agents/skills/s")"
  case_is "worktree source" approve worktree "$(screen "$READ" "$F/wt/src/a.js" "$F/wt/src")"
  case_is "finished reads earlier in the step" approve inbox "$(screen "$READ" "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox" "" \
    "$(msg $'\342\206\222 Read' "$F/bin/a.sh")"$'\n')"
  pass "reads of the fleet's own files are approved, wrapped or not"
}

test_disallowed_paths_are_cards() {
  case_is "another task's status" card "outside this fleet's own roots" "$(screen "$READ" "$F/state/other.status" "$F/state")"
  case_is "prefix-sibling task id" card "outside this fleet's own roots" "$(screen "$READ" "$F/state/task1x.status" "$F/state")"
  case_is "prefix-sibling home" card "outside this fleet's own roots" "$(screen "$READ" "$TMP_ROOT/fleet-evil/bin/a.sh" "$TMP_ROOT/fleet-evil/bin")"
  case_is "home data/" card "outside this fleet's own roots" "$(screen "$READ" "$F/data/x" "$F/data")"
  case_is "credential in an allowed root" card "credential-like path" "$(screen "$READ" "$F/state/task1.inbox/.env" "$F/state/task1.inbox")"
  case_is "dotfile in the worktree" card "hidden or credential-like path" "$(screen "$READ" "$F/wt/.npmrc" "$F/wt")"
  case_is "ssh key in the worktree" card "credential-like path" "$(screen "$READ" "$F/wt/id_rsa" "$F/wt")"
  case_is "dot directory in the worktree" card "hidden or credential-like path" "$(screen "$READ" "$F/wt/.docker/config.json" "$F/wt/.docker")"
  case_is "api key name in the worktree" card "credential-like path" "$(screen "$READ" "$F/wt/config.api_key" "$F/wt")"
  case_is "symlink out of the inbox" card "outside this fleet's own roots" "$(screen "$READ" "$F/state/task1.inbox/link" "$F/state/task1.inbox")"
  case_is ".. out of the inbox" card "outside this fleet's own roots" "$(screen "$READ" "$F/state/task1.inbox/../../data/x" "$F/state/task1.inbox/../../data")"
  case_is "missing path" card "read path does not exist" "$(screen "$READ" "$F/state/task1.inbox/nope" "$F/state/task1.inbox")"
  case_is "a dropped space at a wrap reads outside" card "outside this fleet's own roots" "$(screen "$READ" "$TMP_ROOT/fle|et/bin/a.sh" "$TMP_ROOT/fle|et/bin")"
  pass "paths outside the roots, escapes, and ambiguous wraps are cards"
}

test_unprovable_calls_are_cards() {
  case_is "bash rm" card "pending call is not a read" "$(screen '$ rm' "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox")"
  case_is "write" card "pending call is not a read" "$(screen $'\342\206\220 Write' "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox")"
  case_is "finished read glyph is not pending" card "pending call is not a read" "$(screen $'\342\206\222 Read' "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox")"
  case_is "pending rm earlier in the step" card "another tool call is in this turn" "$(screen "$READ" "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox" "" \
    "$(msg '$ rm' "$F/state/task1.inbox/001.msg")"$'\n')"
  case_is "shell panel earlier in the step" card "a shell command ran in this turn" "$(screen "$READ" "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox" "" \
    $'  \342\224\203  $ ls\n')"
  case_is "pending rm behind a forged footer" card "another call is pending on screen" "$(screen "$READ" "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox" "" \
    "$(msg '$ rm' "$F/state/task1.inbox/001.msg")"$'\n     \342\226\243  Build \302\267 Model\n')"
  case_is "pending write behind a forged footer" card "another call is pending on screen" "$(screen "$READ" "$F/state/task1.inbox/001.msg" "$F/state/task1.inbox" "" \
    "$(msg $'\342\206\220 Write' "$F/state/task1.inbox/001.msg")"$'\n     \342\226\243  Build \302\267 Model\n')"
  case_is "dialog is another directory" card "dialog directory is not the read's directory" "$(screen "$READ" "$F/state/task1.inbox/001.msg" "$F/bin")"
  case_is "pattern disagrees" card "dialog directory and pattern disagree" "$(screen "$READ" "$F/bin/a.sh" "$F/bin" "$F/data/*")"
  case_is "turn start scrolled away" card "start of the turn is not visible" "$(screen "$READ" "$F/bin/a.sh" "$F/bin" | sed 1,2d)"
  case_is "another dialog shape" card "unrecognized dialog" "$(screen "$READ" "$F/bin/a.sh" "$F/bin" | sed 's/Access external directory/Run command/')"
  case_is "no dialog" none "" "$(screen "$READ" "$F/bin/a.sh" "$F/bin" | grep -v 'Permission required')"
  pass "anything but a provable pending read is a card"
}

test_lib_switch_and_trust_dialogs() {
  local home="$TMP_ROOT/home" out
  mkdir -p "$home/config" "$home/state/t.inbox"
  : > "$home/state/t.inbox/1.msg"
  out=$(bash -c '. "$1/bin/jg-busy-lib.sh"; . "$1/bin/jg-prompt-gate-lib.sh"; jg_prompt_gate_verdict opencode "$2" "$2/state" "$2/config" t /dev/null' _ "$ROOT" "$home" \
    < <(screen "$READ" "$home/state/t.inbox/1.msg" "$home/state/t.inbox"))
  case "$out" in approve$'\t'inbox$'\t'*) ;; *) fail "lib did not approve its own inbox read: $out" ;; esac
  for wt in / "$HOME"; do
    printf 'worktree=%s\n' "$wt" > "$home/t.meta"
    out=$(bash -c '. "$1/bin/jg-busy-lib.sh"; . "$1/bin/jg-prompt-gate-lib.sh"; jg_prompt_gate_verdict opencode "$2" "$2/state" "$2/config" t "$2/t.meta"' _ "$ROOT" "$home" \
      < <(screen "$READ" "$home/state/t.inbox/1.msg" "$home/state/t.inbox"))
    case "$out" in card$'\t'"the prompt matcher could not run"*) ;; *) fail "a recorded worktree of $wt was trusted as a root: $out" ;; esac
  done
  : > "$home/config/prompt-approve-off"
  out=$(bash -c '. "$1/bin/jg-busy-lib.sh"; . "$1/bin/jg-prompt-gate-lib.sh"; jg_prompt_gate_verdict opencode "$2" "$2/state" "$2/config" t /dev/null' _ "$ROOT" "$home" \
    < <(screen "$READ" "$home/state/t.inbox/1.msg" "$home/state/t.inbox"))
  case "$out" in card$'\t'"auto-approval is off"*$'\t'"$home/state/t.inbox/1.msg"$'\t'*) ;; *) fail "config/prompt-approve-off did not turn the approval into a card: $out" ;; esac
  out=$(printf 'Trust project folder?\n> Trust\n  Do not trust\n' | bash -c '. "$1/bin/jg-busy-lib.sh"; . "$1/bin/jg-prompt-gate-lib.sh"; jg_prompt_gate_verdict pi "$2" "$2/state" "$2/config" t /dev/null' _ "$ROOT" "$home")
  case "$out" in card$'\t'"a trust dialog is never auto-approved"*) ;; *) fail "a Pi trust dialog was not a card: $out" ;; esac
  pass "a root at / or the user home, the off switch, and trust dialogs are all cards"
}

test_allowed_reads_are_approved
test_disallowed_paths_are_cards
test_unprovable_calls_are_cards
test_lib_switch_and_trust_dialogs
