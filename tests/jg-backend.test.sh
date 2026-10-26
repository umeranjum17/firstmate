#!/usr/bin/env bash
# tests/jg-backend.test.sh - P1 runtime-backend extraction conformance
# (data/jg-backend-design-d7/report.md, herdr-addendum.md "events as the core
# abstraction"). bin/jg-backend.sh and bin/backends/tmux.sh move the tmux
# command sequences that jg-send.sh, jg-peek.sh, jg-spawn.sh, and
# jg-teardown.sh used to run inline into named adapter functions. This suite:
#
#   1. Unit-tests bin/jg-backend.sh's selection, meta, and dispatch helpers.
#   2. Runs the PRE-REFACTOR versions of jg-send.sh, jg-peek.sh, jg-spawn.sh,
#      and jg-teardown.sh (checked out from the merge-base with `main`, the
#      commit this branch started from) against the SAME fake tmux/treehouse
#      binaries and fixtures as the REFACTORED versions in this checkout, then
#      diffs the two command logs byte-for-byte - the report's P1 checklist
#      item "run current main scripts and refactored scripts against the same
#      fake tools and compare command logs". The teardown old-vs-new case also
#      overlays a content-historical permissive tmux kill fixture: after the
#      exact-selector change lands on the default branch, merge-base with main
#      collapses to HEAD and can no longer supply that baseline.
#   3. Asserts the `--backend`/`JG_BACKEND` selection refuses unknown backends
#      and the blocked `codex-app` backend loudly.
#
# jg-watch.sh's signal/stale/check/heartbeat wake-string contract is already
# exercised end-to-end against this refactor by tests/jg-watch-triage.test.sh
# and tests/wake-helpers.sh (same fake-tmux convention, run against the
# now-refactored bin/jg-watch.sh); this suite adds one direct old-vs-new
# diff for the stale-pane path specifically, since that is the one wake path
# that now calls through jg_backend_capture instead of tmux directly.
# The real tmux smoke test (create session, send text + Enter, capture, list,
# kill) lives in tests/jg-backend-tmux-smoke.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_git_identity fmtest fmtest@example.invalid

# shellcheck source=/dev/null
. "$ROOT/bin/jg-backend.sh"

TMP_ROOT=$(jg_test_tmproot jg-backend-tests)
# A claude spawn writes workspace trust into the launching user's own store,
# and the script resolves it as ${CLAUDE_CONFIG_DIR:-${HOME:-}}, so the value
# is pinned EMPTY beside the throwaway HOME: an inherited one would beat that
# HOME and reach the developer's real store, while empty falls through to it
# and adds no launch prefix, since jg-spawn only prefixes a non-empty value.
SPAWN_HOME="$TMP_ROOT/user-home"
mkdir -p "$SPAWN_HOME"

write_spawn_brief() {  # <file> <id>
  cat > "$1" <<EOF
# Task
## Captain's intent
Exercise backend dispatch for $2.

## Juggernaut spec
Verify backend selection without changing task intent.
EOF
}

# jg_backend_detect's cmux fallback (bundle id + process ancestry,
# docs/cmux-backend.md "Runtime auto-detection") consults uname, lsappinfo,
# and ps. FAKE_NONDARWIN_BIN pins uname to Linux so the whole fallback is
# deterministically inert for every assertion that expects NO detection,
# regardless of the ambient runtime this suite itself executes inside (a real
# cmux tab would otherwise leak a bundle-id or ancestry match into results).
FAKE_NONDARWIN_BIN="$TMP_ROOT/fake-nondarwin-bin"
mkdir -p "$FAKE_NONDARWIN_BIN"
printf '#!/bin/sh\necho Linux\n' > "$FAKE_NONDARWIN_BIN/uname"
chmod +x "$FAKE_NONDARWIN_BIN/uname"

# make_cmux_fallback_fakebin: PATH fakes for the DETECTING side of the cmux
# fallback - uname pinned to Darwin, lsappinfo echoing $JG_FAKE_LSAPPINFO_OUT
# (empty output mirrors the real lsappinfo's app-not-running behavior: prints
# nothing, exit 0), and a ps answering `-o ppid=/-o comm= -p <pid>` from the
# tab-separated "pid ppid comm" table file named by $JG_FAKE_PS_TABLE.
make_cmux_fallback_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin-cmux-fallback"
  mkdir -p "$fb"
  printf '#!/bin/sh\necho Darwin\n' > "$fb/uname"
  cat > "$fb/lsappinfo" <<'SH'
#!/bin/sh
[ -n "${JG_FAKE_LSAPPINFO_OUT:-}" ] && printf '%s\n' "$JG_FAKE_LSAPPINFO_OUT"
exit 0
SH
  cat > "$fb/ps" <<'SH'
#!/bin/sh
# supports exactly: ps -o ppid= -p <pid> / ps -o comm= -p <pid>
field=${2:-} pid=${4:-}
while IFS="	" read -r tpid tppid tcomm; do
  if [ "$tpid" = "$pid" ]; then
    case "$field" in
      ppid=) printf '%s\n' "$tppid" ;;
      comm=) printf '%s\n' "$tcomm" ;;
    esac
    exit 0
  fi
done < "${JG_FAKE_PS_TABLE:?}"
exit 1
SH
  chmod +x "$fb/uname" "$fb/lsappinfo" "$fb/ps"
  printf '%s\n' "$fb"
}

# The commit this branch started from - the P1 "current main" baseline.
# Suitable for byte-identical old-vs-new checks while a branch still diverges
# from main. After a squash lands, merge-base(HEAD, main) collapses to HEAD, so
# callers that need a true pre-change fixture must not rely on this alone.
resolve_base_ref() {
  local ref base
  for ref in main refs/heads/main origin/main refs/remotes/origin/main origin/HEAD refs/remotes/origin/HEAD; do
    if git -C "$ROOT" rev-parse --verify -q "$ref^{commit}" >/dev/null; then
      base=$(git -C "$ROOT" merge-base HEAD "$ref" 2>/dev/null) || continue
      [ -n "$base" ] || continue
      printf '%s\n' "$base"
      return 0
    fi
  done
  return 1
}
BASE_REF=

backend_base_ref() {
  if [ -z "${BASE_REF:-}" ]; then
    BASE_REF=$(resolve_base_ref) \
      || fail "jg-backend baseline requires local main or origin/main; fetch the default branch before running this test"
  fi
  printf '%s\n' "$BASE_REF"
}

# Newest first-parent revision whose bin/backends/tmux.sh still uses the
# pre-exact permissive kill-window target. Content-addressed from history so the
# fixture stays historical on default-branch CI and on branches cut after the
# exact-selector change, where merge-base with main is self-referential.
resolve_permissive_tmux_kill_ref() {
  local commit body
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    body=$(git -C "$ROOT" show "$commit:bin/backends/tmux.sh" 2>/dev/null) || continue
    # shellcheck disable=SC2016
    case "$body" in
      *'tmux kill-window -t "=$session:=$window"'*) continue ;;
    esac
    # shellcheck disable=SC2016
    case "$body" in
      *'tmux kill-window -t "$1"'*|*'tmux kill-window -t "$target"'*)
        printf '%s\n' "$commit"
        return 0
        ;;
    esac
  done < <(git -C "$ROOT" log --first-parent --format='%H' HEAD -- bin/backends/tmux.sh)
  return 1
}

# --- shared: a pre-refactor bin/ shim --------------------------------------
#
# build_old_bin echoes a directory whose bin/ subdir is the complete bin/ tree
# from BASE_REF.
# Materializing the whole historical tree keeps every entrypoint and sourced
# sibling on the same revision, while avoiding a hand-maintained dependency
# list that can omit a newly sourced helper and make the old process abort
# before it reaches the behavior under test.
# JG_ROOT_OVERRIDE pointed at this dir's root makes
# "$JG_ROOT/bin/jg-project-mode.sh" (etc.) resolve correctly.
# The teardown conformance case applies its explicitly historical tmux adapter
# after this complete baseline has been materialized.

build_old_bin() {  # <name> -> echoes root dir (root/bin/<script> is the entry point)
  local name=$1 root archive base_ref
  root="$TMP_ROOT/$name"
  archive="$root/bin.tar"
  mkdir -p "$root"
  base_ref=$(backend_base_ref)
  git -C "$ROOT" archive --format=tar "$base_ref" bin > "$archive" \
    || fail "old-bin shim: could not archive bin/ from $base_ref"
  tar -xf "$archive" -C "$root" \
    || fail "old-bin shim: could not extract bin/ from $base_ref"
  rm -f "$archive"
  printf '%s\n' "$root"
}

# --- jg-backend.sh unit tests ------------------------------------------------

test_backend_name_precedence() {
  local dir cfg
  dir="$TMP_ROOT/name-precedence"; cfg="$dir/config"
  mkdir -p "$cfg"

  # TMUX/HERDR_ENV/CMUX_WORKSPACE_ID explicitly unset in a subshell so this
  # stays deterministic regardless of the runtime this test suite itself
  # happens to execute inside (e.g. a real tmux pane, which is the normal case
  # for a captain's session).
  # jg_backend_name reads JG_BACKEND_CONFIG_DIR (bound once, at jg-backend.sh
  # source time, from JG_CONFIG_OVERRIDE); a later JG_CONFIG_OVERRIDE=... prefix
  # on the function call itself does not re-bind it, so these calls set
  # JG_BACKEND_CONFIG_DIR directly.
  [ "$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier; PATH="$FAKE_NONDARWIN_BIN:$PATH" JG_BACKEND='' JG_BACKEND_CONFIG_DIR="$cfg" jg_backend_name)" = tmux ] \
    || fail "jg_backend_name should default to tmux with no env/config/detection markers"

  printf 'tmux\n' > "$cfg/backend"
  [ "$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; JG_BACKEND='' JG_BACKEND_CONFIG_DIR="$cfg" jg_backend_name)" = tmux ] \
    || fail "jg_backend_name should read config/backend"

  [ "$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; JG_BACKEND=tmux JG_BACKEND_CONFIG_DIR="$cfg" jg_backend_name)" = tmux ] \
    || fail "JG_BACKEND env should win over config/backend"

  pass "jg_backend_name: JG_BACKEND env > config/backend > default tmux"
}

# jg_backend_detect: environment-marker runtime auto-detection (mirrors
# jg-harness.sh's detect_own layer). Every case explicitly controls TMUX,
# HERDR_ENV, and CMUX_WORKSPACE_ID - and, where no detection is expected, the
# cmux fallback inputs (__CFBundleIdentifier plus a non-Darwin uname fake) -
# so results never depend on the ambient shell this suite runs inside (a real
# tmux pane or cmux tab, both normal cases for a captain's session).
test_backend_detect_precedence() {
  local out

  if out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier; PATH="$FAKE_NONDARWIN_BIN:$PATH" jg_backend_detect); then
    fail "jg_backend_detect should return 1 (undetected) with no markers set, got '$out'"
  fi

  out=$(unset TMUX CMUX_WORKSPACE_ID; HERDR_ENV=1 jg_backend_detect) \
    || fail "jg_backend_detect should succeed when HERDR_ENV=1"
  [ "$out" = herdr ] || fail "jg_backend_detect should report herdr for HERDR_ENV=1 alone, got '$out'"

  out=$(unset HERDR_ENV CMUX_WORKSPACE_ID; TMUX='fake,1,0' jg_backend_detect) \
    || fail "jg_backend_detect should succeed when \$TMUX is set"
  [ "$out" = tmux ] || fail "jg_backend_detect should report tmux for \$TMUX alone, got '$out'"

  out=$(unset TMUX HERDR_ENV; CMUX_WORKSPACE_ID='fake-uuid' jg_backend_detect) \
    || fail "jg_backend_detect should succeed when CMUX_WORKSPACE_ID is set"
  [ "$out" = cmux ] || fail "jg_backend_detect should report cmux for CMUX_WORKSPACE_ID alone, got '$out'"

  # Nesting: tmux started inside a herdr pane carries BOTH markers. Innermost
  # (tmux) must win, since that is the surface juggernaut is actually running on.
  out=$(unset CMUX_WORKSPACE_ID; TMUX='fake,1,0' HERDR_ENV=1 jg_backend_detect) \
    || fail "jg_backend_detect should succeed with both markers present"
  [ "$out" = tmux ] || fail "jg_backend_detect should resolve nesting innermost-first (tmux over herdr), got '$out'"

  # Nesting: tmux started inside a cmux-provided shell carries BOTH markers.
  # cmux is a terminal application, not a nestable multiplexer, so the
  # innermost multiplexer (tmux) must still win.
  out=$(unset HERDR_ENV; TMUX='fake,1,0' CMUX_WORKSPACE_ID='fake-uuid' jg_backend_detect) \
    || fail "jg_backend_detect should succeed with tmux and cmux markers present"
  [ "$out" = tmux ] || fail "jg_backend_detect should resolve nesting innermost-first (tmux over cmux), got '$out'"

  # Nesting: herdr started inside a cmux-provided shell carries BOTH markers.
  # Same reasoning: herdr (the innermost multiplexer) must win over cmux.
  out=$(unset TMUX; HERDR_ENV=1 CMUX_WORKSPACE_ID='fake-uuid' jg_backend_detect) \
    || fail "jg_backend_detect should succeed with herdr and cmux markers present"
  [ "$out" = herdr ] || fail "jg_backend_detect should resolve nesting innermost-first (herdr over cmux), got '$out'"

  # Pathological: all three markers present. tmux still wins (innermost of all).
  out=$(TMUX='fake,1,0' HERDR_ENV=1 CMUX_WORKSPACE_ID='fake-uuid' jg_backend_detect) \
    || fail "jg_backend_detect should succeed with all three markers present"
  [ "$out" = tmux ] || fail "jg_backend_detect should resolve nesting innermost-first with all three markers (tmux wins), got '$out'"

  pass "jg_backend_detect: no markers -> undetected, HERDR_ENV=1 -> herdr, \$TMUX -> tmux, CMUX_WORKSPACE_ID -> cmux, nested combinations resolve innermost-first"
}

# jg_backend_detect's cmux FALLBACK signals (docs/cmux-backend.md "Runtime
# auto-detection"): cmux's bundled claude wrapper strips every CMUX_* env var
# on its passthrough path, so a claude-under-cmux juggernaut has no
# CMUX_WORKSPACE_ID; detection then falls back to __CFBundleIdentifier and,
# after that, a process-ancestry walk - macOS-only, and never outranking the
# $TMUX/HERDR_ENV innermost-first checks.
test_backend_detect_cmux_fallback_bundle_id() {
  local dir fb out
  dir="$TMP_ROOT/detect-fallback-bundle"; mkdir -p "$dir"
  fb=$(make_cmux_fallback_fakebin "$dir")

  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; PATH="$fb:$PATH" __CFBundleIdentifier='com.cmuxterm.app' jg_backend_detect) \
    || fail "jg_backend_detect should fall back to the cmux bundle id when CMUX_WORKSPACE_ID is absent"
  [ "$out" = cmux ] || fail "bundle-id fallback should report cmux, got '$out'"

  (
    unset TMUX HERDR_ENV CMUX_WORKSPACE_ID
    PATH="$fb:$PATH" __CFBundleIdentifier='com.cmuxterm.app' jg_backend_detect >/dev/null || exit 1
    [ "$JG_BACKEND_DETECT_SIGNAL" = bundle-id ] || exit 2
  ) || fail "bundle-id fallback should set JG_BACKEND_DETECT_SIGNAL=bundle-id (subshell exit $?)"

  # A foreign bundle id (an ordinary terminal app) must not match.
  if out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; PATH="$fb:$PATH" JG_FAKE_PS_TABLE="$dir/no-table" __CFBundleIdentifier='com.apple.Terminal' jg_backend_detect); then
    fail "a non-cmux __CFBundleIdentifier should not detect cmux, got '$out'"
  fi

  pass "jg_backend_detect: falls back to __CFBundleIdentifier=com.cmuxterm.app when CMUX_WORKSPACE_ID is absent (signal bundle-id; foreign bundle ids rejected)"
}

test_backend_detect_cmux_fallback_requires_darwin() {
  local out
  if out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; PATH="$FAKE_NONDARWIN_BIN:$PATH" __CFBundleIdentifier='com.cmuxterm.app' jg_backend_detect); then
    fail "the cmux fallback must be macOS-only (cmux itself is), got '$out' on a non-Darwin uname"
  fi
  pass "jg_backend_detect: the cmux fallback signals are macOS-only (inert on a non-Darwin uname)"
}

# The false positive the innermost-first ordering must keep absorbing: a tmux
# server started from a cmux tab inherits __CFBundleIdentifier=com.cmuxterm.app
# into every pane (verified live, docs/cmux-backend.md), so the bundle-id
# fallback WILL match inside such panes - $TMUX winning first is what keeps
# the result correct. Same for a herdr pane whose server was started from a
# cmux tab.
test_backend_detect_cmux_fallback_tmux_nested_false_positive() {
  local dir fb out
  dir="$TMP_ROOT/detect-fallback-nested"; mkdir -p "$dir"
  fb=$(make_cmux_fallback_fakebin "$dir")

  out=$(unset HERDR_ENV CMUX_WORKSPACE_ID; PATH="$fb:$PATH" TMUX='fake,1,0' __CFBundleIdentifier='com.cmuxterm.app' jg_backend_detect) \
    || fail "jg_backend_detect should still succeed with \$TMUX plus an inherited cmux bundle id"
  [ "$out" = tmux ] || fail "\$TMUX must win over an inherited cmux bundle id (tmux-inside-cmux pane), got '$out'"

  out=$(unset TMUX CMUX_WORKSPACE_ID; PATH="$fb:$PATH" HERDR_ENV=1 __CFBundleIdentifier='com.cmuxterm.app' jg_backend_detect) \
    || fail "jg_backend_detect should still succeed with HERDR_ENV=1 plus an inherited cmux bundle id"
  [ "$out" = herdr ] || fail "HERDR_ENV=1 must win over an inherited cmux bundle id (herdr-inside-cmux pane), got '$out'"

  pass "jg_backend_detect: an inherited cmux bundle id never outranks \$TMUX or HERDR_ENV (tmux/herdr-inside-cmux false positive absorbed)"
}

test_backend_detect_cmux_fallback_ancestry_pid_match() {
  local dir fb table
  dir="$TMP_ROOT/detect-ancestry-pid"; mkdir -p "$dir"
  fb=$(make_cmux_fallback_fakebin "$dir")
  table="$dir/ps-table"
  # $$ is this test script's own pid - the walk starts there. The cmux app
  # pid (66666) is matched via the lsappinfo bundle-id resolution, with a
  # deliberately non-standard install path so only the pid can match.
  printf '%s\t77777\t/bin/zsh\n77777\t66666\t/usr/bin/login\n66666\t1\t/home/x/Custom.app/Contents/MacOS/custom\n' "$$" > "$table"

  (
    unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier
    PATH="$fb:$PATH" JG_FAKE_PS_TABLE="$table" JG_FAKE_LSAPPINFO_OUT='"pid"=66666' jg_backend_detect >/dev/null || exit 1
    [ "$JG_BACKEND_DETECTED" = cmux ] || exit 2
    [ "$JG_BACKEND_DETECT_SIGNAL" = ancestry ] || exit 3
  ) || fail "ancestry fallback should detect cmux via the lsappinfo-resolved app pid (subshell exit $?)"

  pass "jg_backend_detect: ancestry fallback matches the lsappinfo-resolved (bundle-id) cmux app pid in the parent chain"
}

test_backend_detect_cmux_fallback_ancestry_comm_match() {
  local dir fb table
  dir="$TMP_ROOT/detect-ancestry-comm"; mkdir -p "$dir"
  fb=$(make_cmux_fallback_fakebin "$dir")
  table="$dir/ps-table"
  # lsappinfo resolves nothing (empty output, like the real one for a
  # non-running or non-GUI-visible app); the bundle-shaped comm path is the
  # remaining match, at a non-/Applications install location on purpose.
  printf '%s\t77777\t/bin/zsh\n77777\t66666\t/usr/bin/login\n66666\t1\t/home/x/Applications/cmux.app/Contents/MacOS/cmux\n' "$$" > "$table"

  (
    unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier JG_FAKE_LSAPPINFO_OUT
    PATH="$fb:$PATH" JG_FAKE_PS_TABLE="$table" jg_backend_detect >/dev/null || exit 1
    [ "$JG_BACKEND_DETECTED" = cmux ] || exit 2
    [ "$JG_BACKEND_DETECT_SIGNAL" = ancestry ] || exit 3
  ) || fail "ancestry fallback should detect cmux via a bundle-shaped comm path when lsappinfo resolves nothing (subshell exit $?)"

  pass "jg_backend_detect: ancestry fallback matches a bundle-shaped cmux comm path at any install location when lsappinfo cannot resolve a pid"
}

# From inside tmux, ancestry can never reach cmux: the tmux server reparents
# to launchd (verified live - the reference machine's own tmux server, started
# from a cmux tab, has ppid 1), so the walk stops at ppid 1 undetected. This
# pins the walk's launchd stop as the structural guarantee behind that.
test_backend_detect_cmux_fallback_ancestry_stops_at_launchd() {
  local dir fb table out
  dir="$TMP_ROOT/detect-ancestry-stop"; mkdir -p "$dir"
  fb=$(make_cmux_fallback_fakebin "$dir")
  table="$dir/ps-table"
  printf '%s\t77777\t/bin/zsh\n77777\t1\ttmux\n' "$$" > "$table"

  if out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier JG_FAKE_LSAPPINFO_OUT; PATH="$fb:$PATH" JG_FAKE_PS_TABLE="$table" jg_backend_detect); then
    fail "ancestry fallback should stop undetected at a launchd-reparented chain, got '$out'"
  fi
  pass "jg_backend_detect: ancestry fallback stops undetected at launchd (a reparented tmux server never reaches cmux)"
}

# The auto-detect NOTICE must say when cmux was selected via a fallback
# signal, so a captain can tell a wrapper-stripped claude-under-cmux spawn
# apart from the primary-marker case.
test_backend_name_cmux_fallback_notice() {
  local dir cfg fb out errfile
  dir="$TMP_ROOT/name-fallback-notice"; cfg="$dir/config-empty"; mkdir -p "$cfg"
  fb=$(make_cmux_fallback_fakebin "$dir")
  errfile="$dir/err.txt"

  : > "$errfile"
  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; PATH="$fb:$PATH" __CFBundleIdentifier='com.cmuxterm.app' JG_BACKEND='' JG_BACKEND_CONFIG_DIR="$cfg" jg_backend_name 2>"$errfile")
  [ "$out" = cmux ] || fail "jg_backend_name should auto-detect cmux via the bundle-id fallback, got '$out'"
  assert_contains "$(cat "$errfile")" "FALLBACK signal __CFBundleIdentifier" \
    "the fallback-detected cmux notice did not name the bundle-id fallback signal"
  assert_contains "$(cat "$errfile")" "EXPERIMENTAL cmux backend" \
    "the fallback-detected cmux notice lost the experimental warning"
  assert_contains "$(cat "$errfile")" "--backend tmux" \
    "the fallback-detected cmux notice lost the opt-out"

  # The primary-marker notice is unchanged: it names CMUX_WORKSPACE_ID and
  # carries no FALLBACK wording.
  : > "$errfile"
  out=$(unset TMUX HERDR_ENV; CMUX_WORKSPACE_ID='fake-uuid' JG_BACKEND='' JG_BACKEND_CONFIG_DIR="$cfg" jg_backend_name 2>"$errfile")
  [ "$out" = cmux ] || fail "jg_backend_name should auto-detect cmux from CMUX_WORKSPACE_ID, got '$out'"
  assert_contains "$(cat "$errfile")" "(CMUX_WORKSPACE_ID)" \
    "the primary-marker cmux notice no longer names CMUX_WORKSPACE_ID"
  case "$(cat "$errfile")" in
    *FALLBACK*) fail "the primary-marker cmux notice must not carry FALLBACK wording" ;;
  esac

  pass "jg_backend_name: a fallback-detected cmux prints a NOTICE naming the fallback signal; the primary-marker notice is unchanged"
}

# jg_backend_name's auto-detect step: fires only when JG_BACKEND/config/backend
# are both absent, selects between the three markers exactly as
# jg_backend_detect does, and is loud only when it selects experimental cmux -
# never when it selects verified herdr or tmux (today's default-path behavior
# must stay byte-for-byte silent).
test_backend_name_autodetect_notice() {
  local dir cfg out errfile

  dir="$TMP_ROOT/name-autodetect"; cfg="$dir/config-empty"; mkdir -p "$cfg"
  errfile="$dir/err.txt"

  : > "$errfile"
  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier; PATH="$FAKE_NONDARWIN_BIN:$PATH" JG_BACKEND='' JG_BACKEND_CONFIG_DIR="$cfg" jg_backend_name 2>"$errfile")
  [ "$out" = tmux ] || fail "jg_backend_name should default to tmux with no detection markers, got '$out'"
  [ -s "$errfile" ] && fail "jg_backend_name must stay silent with no detection markers"$'\n'"$(cat "$errfile")"

  : > "$errfile"
  out=$(unset TMUX CMUX_WORKSPACE_ID; HERDR_ENV=1 JG_BACKEND='' JG_BACKEND_CONFIG_DIR="$cfg" jg_backend_name 2>"$errfile")
  [ "$out" = herdr ] || fail "jg_backend_name should auto-detect herdr from HERDR_ENV=1, got '$out'"
  [ ! -s "$errfile" ] || fail "jg_backend_name must keep verified Herdr auto-detection silent"$'\n'"$(cat "$errfile")"

  : > "$errfile"
  out=$(unset HERDR_ENV CMUX_WORKSPACE_ID; TMUX='fake,1,0' JG_BACKEND='' JG_BACKEND_CONFIG_DIR="$cfg" jg_backend_name 2>"$errfile")
  [ "$out" = tmux ] || fail "jg_backend_name should auto-detect tmux from \$TMUX, got '$out'"
  [ -s "$errfile" ] && fail "auto-detecting tmux must stay silent (today's unchanged default-path behavior)"$'\n'"$(cat "$errfile")"

  : > "$errfile"
  out=$(unset TMUX HERDR_ENV; CMUX_WORKSPACE_ID='fake-uuid' JG_BACKEND='' JG_BACKEND_CONFIG_DIR="$cfg" jg_backend_name 2>"$errfile")
  [ "$out" = cmux ] || fail "jg_backend_name should auto-detect cmux from CMUX_WORKSPACE_ID, got '$out'"
  assert_contains "$(cat "$errfile")" "EXPERIMENTAL cmux backend" \
    "jg_backend_name did not print a loud notice when auto-detecting cmux"
  assert_contains "$(cat "$errfile")" "config/backend" \
    "jg_backend_name's cmux auto-detect notice did not name the opt-out"
  assert_contains "$(cat "$errfile")" "--backend tmux" \
    "jg_backend_name's cmux auto-detect notice did not name the --backend tmux opt-out"

  : > "$errfile"
  out=$(unset CMUX_WORKSPACE_ID; TMUX='fake,1,0' HERDR_ENV=1 JG_BACKEND='' JG_BACKEND_CONFIG_DIR="$cfg" jg_backend_name 2>"$errfile")
  [ "$out" = tmux ] || fail "nested tmux-in-herdr should auto-detect tmux (innermost first), got '$out'"
  [ -s "$errfile" ] && fail "nested tmux-in-herdr auto-detect (result tmux) must stay silent"$'\n'"$(cat "$errfile")"

  : > "$errfile"
  out=$(unset HERDR_ENV; TMUX='fake,1,0' CMUX_WORKSPACE_ID='fake-uuid' JG_BACKEND='' JG_BACKEND_CONFIG_DIR="$cfg" jg_backend_name 2>"$errfile")
  [ "$out" = tmux ] || fail "nested tmux-in-cmux should auto-detect tmux (innermost first), got '$out'"
  [ -s "$errfile" ] && fail "nested tmux-in-cmux auto-detect (result tmux) must stay silent"$'\n'"$(cat "$errfile")"

  pass "jg_backend_name: verified Herdr and tmux stay silent while experimental cmux remains loud"
}

# Explicit configuration (JG_BACKEND env or config/backend) always wins over
# runtime auto-detection, even when a detection marker points the other way.
test_backend_name_explicit_beats_detection() {
  local dir cfg out

  dir="$TMP_ROOT/name-explicit-beats-detect"
  cfg="$dir/config-tmux"; mkdir -p "$cfg"; printf 'tmux\n' > "$cfg/backend"
  mkdir -p "$dir/config-empty"

  # jg_backend_name reads JG_BACKEND_CONFIG_DIR (bound once, at jg-backend.sh
  # source time, from JG_CONFIG_OVERRIDE); a later JG_CONFIG_OVERRIDE=... prefix
  # on the function call itself does not re-bind it, so these calls set
  # JG_BACKEND_CONFIG_DIR directly to control which config dir is checked.
  out=$(unset TMUX; HERDR_ENV=1 JG_BACKEND=tmux JG_BACKEND_CONFIG_DIR="$dir/config-empty" jg_backend_name)
  [ "$out" = tmux ] || fail "JG_BACKEND=tmux should win over an ambient HERDR_ENV=1 auto-detect marker, got '$out'"

  out=$(unset TMUX; HERDR_ENV=1 JG_BACKEND='' JG_BACKEND_CONFIG_DIR="$cfg" jg_backend_name)
  [ "$out" = tmux ] || fail "config/backend=tmux should win over an ambient HERDR_ENV=1 auto-detect marker, got '$out'"

  # The same opt-out must work for an ambient cmux auto-detect marker: a
  # captain who is running juggernaut inside a cmux terminal but explicitly
  # wants tmux is never overridden by CMUX_WORKSPACE_ID.
  out=$(unset TMUX HERDR_ENV; CMUX_WORKSPACE_ID='fake-uuid' JG_BACKEND=tmux JG_BACKEND_CONFIG_DIR="$dir/config-empty" jg_backend_name)
  [ "$out" = tmux ] || fail "JG_BACKEND=tmux should win over an ambient CMUX_WORKSPACE_ID auto-detect marker, got '$out'"

  out=$(unset TMUX HERDR_ENV; CMUX_WORKSPACE_ID='fake-uuid' JG_BACKEND='' JG_BACKEND_CONFIG_DIR="$cfg" jg_backend_name)
  [ "$out" = tmux ] || fail "config/backend=tmux should win over an ambient CMUX_WORKSPACE_ID auto-detect marker, got '$out'"

  pass "jg_backend_name: an explicit JG_BACKEND or config/backend setting always wins over runtime auto-detection, including an ambient cmux marker"
}

test_backend_validate_refuses_unknown() {
  jg_backend_validate tmux 2>/dev/null || fail "jg_backend_validate should accept tmux"
  jg_backend_validate orca 2>/dev/null || fail "jg_backend_validate should accept orca"
  local out
  # bogus names a backend with no adapter at all; tmux, herdr, zellij, orca,
  # and cmux are all known adapters and spawn-supported.
  out=$(jg_backend_validate bogus 2>&1) && fail "jg_backend_validate should refuse bogus (no such adapter)"
  assert_contains "$out" "unknown backend 'bogus'" "jg_backend_validate did not name the rejected backend"
  out=$(jg_backend_validate codex-app 2>&1) && fail "jg_backend_validate should refuse codex-app"
  assert_contains "$out" "unknown backend 'codex-app'" "jg_backend_validate accepted codex-app"
  out=$(jg_backend_validate "tmux herdr" 2>&1) && fail "jg_backend_validate should refuse a multi-token backend name"
  assert_contains "$out" "unknown backend 'tmux herdr'" "jg_backend_validate accepted a multi-token backend name"
  pass "jg_backend_validate: implemented adapters accepted, unknown and blocked codex-app backends refused loudly"
}

test_backend_source_shell_portable() {
  local out status stub probe
  # zsh does not word-split unquoted expansions; sourcing jg-backend.sh from
  # an interactive zsh session must still recognize known backend names.
  # The claim is name matching and the sibling precheck only: the adapters
  # find their own siblings through BASH_SOURCE, so zsh is not a full load.
  if command -v zsh >/dev/null 2>&1; then
    zsh -c "cd '$ROOT' && source bin/jg-backend.sh && jg_backend_source herdr" >/dev/null 2>&1 \
      || fail "zsh: jg_backend_source herdr should accept the known backend name and find its sibling libraries"
    out=$(zsh -c "cd '$ROOT' && source bin/jg-backend.sh && jg_backend_source bogus" 2>&1) \
      && fail "zsh: jg_backend_source bogus should fail"
    assert_contains "$out" "unknown backend 'bogus'" \
      "zsh: jg_backend_source did not reject bogus with the expected error"
    pass "zsh: jg_backend_source recognizes known backends and rejects unknown ones"

    # zsh ties the lowercase `path` array to PATH; a backend loaded while
    # jg_backend_source clobbers PATH cannot resolve external commands.
    stub="$TMP_ROOT/zsh-source-path"
    probe="$stub/probe"
    mkdir -p "$stub/backends"
    printf 'command -v dirname > "%s"\n' "$probe" > "$stub/backends/orca.sh"
    : > "$stub/jg-composer-lib.sh"
    zsh -c "cd '$ROOT' && source bin/jg-backend.sh && JG_BACKEND_LIB_DIR='$stub' && jg_backend_source orca" >/dev/null 2>&1 \
      || fail "zsh: jg_backend_source orca should load a stub adapter"
    [ -s "$probe" ] \
      || fail "zsh: jg_backend_source clobbered PATH while loading a backend adapter"
    pass "zsh: jg_backend_source keeps PATH intact while loading a backend adapter"
  else
    pass "zsh: shell-portable backend matching skipped (zsh not found)"
  fi

  bash -c "cd '$ROOT' && source bin/jg-backend.sh && jg_backend_source herdr && declare -F jg_backend_herdr_capture >/dev/null" 2>/dev/null \
    || fail "bash: jg_backend_source herdr should load the adapter when sourced"
  out=$(bash -c "cd '$ROOT' && source bin/jg-backend.sh && jg_backend_source bogus" 2>&1) \
    && fail "bash: jg_backend_source bogus should fail"
  assert_contains "$out" "unknown backend 'bogus'" \
    "bash: jg_backend_source did not reject bogus with the expected error"
  pass "bash: jg_backend_source recognizes known backends and rejects unknown ones"
}

test_backend_source_requires_adapter_file() {
  local dir adapter exit_status continuation out rc condition test_bash
  dir="$TMP_ROOT/adapter-precheck"
  adapter="$dir/backends/tmux.sh"
  test_bash=${JG_TEST_BASH:-${BASH:-bash}}
  mkdir -p "$dir/backends"

  for condition in missing unreadable; do
    if [ "$condition" = unreadable ]; then
      printf ':\n' > "$adapter"
      chmod 000 "$adapter"
      if [ -r "$adapter" ]; then
        pass "jg_backend_source: unreadable adapter case skipped (this user can read mode-000 files)"
        continue
      fi
    fi
    exit_status="$dir/$condition.exit"
    continuation="$dir/$condition.continued"
    # shellcheck disable=SC2016 # The child Bash expands $1..$4 and $? at runtime.
    out=$("$test_bash" -c '
      . "$1"
      JG_BACKEND_LIB_DIR=$2
      trap '\''printf "%s\n" "$?" > "$3"'\'' EXIT
      set -e
      jg_backend_source tmux
      : > "$4"
    ' _ "$ROOT/bin/jg-backend.sh" "$dir" "$exit_status" "$continuation" 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "jg_backend_source returned success for a $condition adapter: $out"
    [ -f "$exit_status" ] || fail "jg_backend_source did not record the $condition adapter exit status"
    [ "$(cat "$exit_status")" -ne 0 ] || fail "jg_backend_source lost the $condition adapter failure at EXIT"
    [ ! -e "$continuation" ] || fail "jg_backend_source continued the lifecycle after a $condition adapter"
    pass "jg_backend_source: $condition adapter fails before lifecycle continuation"
  done
}

test_backend_validate_spawn_accepts_orca() {
  local out
  jg_backend_validate_spawn tmux 2>/dev/null || fail "jg_backend_validate_spawn should accept tmux"
  jg_backend_validate_spawn herdr 2>/dev/null || fail "jg_backend_validate_spawn should accept herdr"
  jg_backend_validate_spawn zellij 2>/dev/null || fail "jg_backend_validate_spawn should accept zellij"
  jg_backend_validate_spawn orca 2>/dev/null || fail "jg_backend_validate_spawn should accept orca"
  jg_backend_validate_spawn cmux 2>/dev/null || fail "jg_backend_validate_spawn should accept cmux"
  out=$(jg_backend_validate_spawn bogus 2>&1) && fail "jg_backend_validate_spawn should still refuse unknown backends"
  assert_contains "$out" "unknown backend 'bogus'" "jg_backend_validate_spawn did not preserve unknown-backend validation"
  out=$(jg_backend_validate_spawn codex-app 2>&1) && fail "jg_backend_validate_spawn should refuse codex-app"
  assert_contains "$out" "unknown backend 'codex-app'" "jg_backend_validate_spawn accepted codex-app"
  out=$(jg_backend_validate_spawn "tmux herdr" 2>&1) && fail "jg_backend_validate_spawn should refuse a multi-token backend name"
  assert_contains "$out" "unknown backend 'tmux herdr'" "jg_backend_validate_spawn accepted a multi-token backend name"
  pass "jg_backend_validate_spawn: all implemented lifecycle backends are spawn-supported"
}

test_meta_get_and_backend_of_meta() {
  local meta=$TMP_ROOT/meta-get.meta edge=$TMP_ROOT/meta-get-edge.meta
  jg_write_meta "$meta" "window=juggernaut:jg-x1" "harness=claude"
  [ "$(jg_meta_get "$meta" window)" = "juggernaut:jg-x1" ] || fail "jg_meta_get did not read window="
  [ "$(jg_meta_get "$meta" missing)" = "" ] || fail "jg_meta_get should print nothing for an absent key"
  [ "$(jg_backend_of_meta "$meta")" = tmux ] || fail "jg_backend_of_meta should default absent backend= to tmux"

  printf 'backend=tmux\n' >> "$meta"
  [ "$(jg_backend_of_meta "$meta")" = tmux ] || fail "jg_backend_of_meta should read an explicit backend=tmux"

  printf 'token=first\ntoken=last=value' > "$edge"
  [ "$(jg_meta_get "$edge" token)" = "last=value" ] \
    || fail "jg_meta_get did not preserve last-value or no-final-newline semantics"

  pass "jg_meta_get / jg_backend_of_meta: read last key=value and default backend to tmux"
}

test_resolve_selector_three_forms() {
  local state=$TMP_ROOT/resolve-state fakebin out
  mkdir -p "$state"
  jg_write_meta "$state/task1.meta" "window=juggernaut:jg-task1"
  jg_write_meta "$state/dotfiles-d6.meta" "window=default:wA:p2" "backend=herdr"
  jg_write_meta "$state/jg-turnend-all-harnesses-v9.meta" "window=default:wB:p3" "backend=herdr"

  [ "$(jg_backend_resolve_selector 'sess:win' "$state")" = "sess:win" ] \
    || fail "explicit session:window should be used as-is"

  [ "$(jg_backend_resolve_selector 'dotfiles-d6' "$state")" = "default:wA:p2" ] \
    || fail "bare non-fm task id should resolve through exact metadata"
  [ "$(jg_backend_of_selector 'dotfiles-d6' 'default:wA:p2' "$state")" = herdr ] \
    || fail "bare non-fm task id should use its recorded backend"
  [ "$(jg_backend_expected_label_of_selector 'dotfiles-d6' "$state")" = "jg-dotfiles-d6" ] \
    || fail "bare non-fm task id should report the spawned jg-<id> label"

  [ "$(jg_backend_resolve_selector 'jg-turnend-all-harnesses-v9' "$state")" = "default:wB:p3" ] \
    || fail "exact jg-* task id should resolve through its exact metadata"
  [ "$(jg_backend_of_selector 'jg-turnend-all-harnesses-v9' 'default:wB:p3' "$state")" = herdr ] \
    || fail "exact jg-* task id should use exact metadata without stripping jg-"
  [ "$(jg_backend_expected_label_of_selector 'jg-turnend-all-harnesses-v9' "$state")" = "jg-jg-turnend-all-harnesses-v9" ] \
    || fail "exact jg-* task id should report the spawned jg-<id> label"

  [ "$(jg_backend_resolve_selector 'jg-task1' "$state")" = "juggernaut:jg-task1" ] \
    || fail "legacy jg-<id> label should resolve through <id>.meta's window="
  [ "$(jg_backend_expected_label_of_selector 'jg-task1' "$state")" = "jg-task1" ] \
    || fail "legacy jg-<id> label should preserve its backend label"

  out=$(jg_backend_resolve_selector 'jg-missing' "$state" 2>&1) && fail "jg-<id> with no meta should fail"
  assert_contains "$out" "no metadata for jg-missing" "missing-meta error text changed"

  fakebin="$TMP_ROOT/resolve-fakebin"; mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'juggernaut:adhoc\nother:otherwin\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  out=$(PATH="$fakebin:$PATH" jg_backend_resolve_selector 'jg-adhoc' "$state" 2>&1) || true
  # jg-adhoc carries no meta file, so it is NOT the bare-name fallback path - it
  # is the jg-* meta-miss error path after exact-id and legacy-label metadata
  # lookup both miss.
  # Only a NON jg-* bare name falls through to the live-window search.
  assert_contains "$out" "no metadata for jg-adhoc" "an jg-* selector must always require meta, not silently fall back to a live search"

  out=$(PATH="$fakebin:$PATH" jg_backend_resolve_selector 'adhoc' "$state")
  [ "$out" = "juggernaut:adhoc" ] || fail "an ad hoc bare name should resolve via the tmux live-window fallback, got '$out'"

  pass "jg_backend_resolve_selector: session:window literal, exact task id first, legacy jg-<id> label fallback, ad hoc bare name via tmux list-windows"
}

test_backend_of_selector_matches_explicit_target_meta() {
  local state=$TMP_ROOT/backend-selector-state
  mkdir -p "$state"
  jg_write_meta "$state/herdr-task.meta" "window=default:w1:p2" "backend=herdr"
  jg_write_meta "$state/dotfiles-d6.meta" "window=default:wA:p2" "backend=herdr"
  jg_write_meta "$state/jg-turnend-all-harnesses-v9.meta" "window=default:wB:p3" "backend=herdr"
  jg_write_meta "$state/tmux-task.meta" "window=juggernaut:jg-tmux-task"
  jg_write_meta "$state/custom-window-task.meta" "window=custom-window"
  jg_write_meta "$state/orca-task.meta" "window=jg-orca-task" "terminal=term-orca-task" "backend=orca"

  [ "$(jg_backend_of_selector 'dotfiles-d6' 'default:wA:p2' "$state")" = herdr ] \
    || fail "bare non-fm task id selector should use its recorded backend"
  [ "$(jg_backend_of_selector 'jg-turnend-all-harnesses-v9' 'default:wB:p3' "$state")" = herdr ] \
    || fail "exact jg-* task id selector should use exact metadata before legacy stripping"
  [ "$(jg_backend_of_selector 'jg-herdr-task' 'default:w1:p2' "$state")" = herdr ] \
    || fail "legacy jg-<id> selector should use its recorded backend"
  [ "$(jg_backend_resolve_selector 'jg-orca-task' "$state")" = term-orca-task ] \
    || fail "Orca jg-<id> selector should resolve to terminal=, not window="
  [ "$(jg_backend_resolve_selector 'term-orca-task' "$state")" = term-orca-task ] \
    || fail "raw Orca terminal selector should resolve through metadata"
  [ "$(jg_backend_resolve_selector 'custom-window' "$state")" = custom-window ] \
    || fail "raw window selector matching metadata should not require tmux fallback"
  [ "$(jg_backend_of_selector 'term-orca-task' 'term-orca-task' "$state")" = orca ] \
    || fail "matching an explicit Orca terminal handle should inherit metadata backend"
  [ "$(jg_backend_of_selector 'default:w1:p2' 'default:w1:p2' "$state")" = herdr ] \
    || fail "explicit backend target matching metadata should use that task's backend"
  [ "$(jg_backend_of_selector 'juggernaut:jg-tmux-task' 'juggernaut:jg-tmux-task' "$state")" = tmux ] \
    || fail "explicit tmux-shaped target with absent backend= should default to tmux"
  [ "$(jg_backend_of_selector 'manual:outside' 'manual:outside' "$state")" = tmux ] \
    || fail "explicit target with no matching metadata should keep the tmux compatibility default"

  pass "jg_backend_of_selector: exact task ids, legacy jg-<id> labels, and matching explicit targets inherit metadata backend"
}

# --- old vs new: jg-send.sh --------------------------------------------------

make_send_fakebin() {  # <dir> -> echoes fakebin dir; logs every tmux call to $JG_TMUX_LOG
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${JG_TMUX_LOG:?}"
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    start= end=
    while [ $# -gt 0 ]; do
      case "$1" in
        -S) start=$2; shift 2 ;;
        -E) end=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ "$start" = 1 ] && [ "$end" = 1 ]; then
      printf '│    │\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

run_send_case() {  # <bin-root> <fakebin> <log> <home> -- <send args...>
  local bin=$1 fb=$2 log=$3 home=$4; shift 4
  [ "${1:-}" = -- ] && shift
  : > "$log"
  env PATH="$fb:$PATH" JG_ROOT_OVERRIDE="$bin" JG_HOME="$home" JG_TMUX_LOG="$log" \
    JG_SEND_SETTLE=0 JG_SEND_SLEEP=0 \
    "$bin/bin/jg-send.sh" "$@" >/dev/null 2>&1
}

strip_send_preflight() {  # <log>
  local preflight
  preflight=$'tmux\x1fdisplay-message\x1f-p\x1f-t\x1fsess:win\x1f#{pane_id}'
  awk -v preflight="$preflight" '$0 != preflight { print }' "$1"
}

# The byte-identical old-vs-new tmux log comparison this test used to run
# covered the P1 backend extraction, which promised an unchanged command
# sequence. The composer consolidation (jg-composer-thin-adapter-refactor-r1)
# deliberately changed that sequence - the submit core reads a busy baseline
# before typing (its idle-to-busy turn-started confirmation) and the composer
# verdict comes from one full styled capture instead of a second band capture -
# so the current contract is asserted directly instead.
test_send_tmux_contract() {
  local fb log home rc
  fb=$(make_send_fakebin "$TMP_ROOT/send-fake")
  home="$TMP_ROOT/send-home"; mkdir -p "$home/state"
  log="$TMP_ROOT/send-new.log"

  # Case 1: --key path - target verified, named key sent, no typing.
  run_send_case "$ROOT" "$fb" "$log" "$home" -- "sess:win" --key Escape
  rc=$?
  expect_code 0 "$rc" "jg-send --key should succeed against a live fake pane"
  assert_contains "$(cat "$log")" $'\x1f''display-message'$'\x1f''-p'$'\x1f''-t'$'\x1f''sess:win'$'\x1f''#{pane_id}' \
    "jg-send --key did not verify the explicit tmux target before sending"
  assert_contains "$(cat "$log")" $'\x1f''Escape' "jg-send --key did not send the named key"
  assert_not_contains "$(cat "$log")" $'\x1f''-l'$'\x1f' "jg-send --key must not type literal text"

  # Case 2: plain text - typed literally exactly once, submitted with Enter,
  # confirmed against the bordered-empty fake composer.
  run_send_case "$ROOT" "$fb" "$log" "$home" -- "sess:win" hello captain
  rc=$?
  expect_code 0 "$rc" "jg-send plain text should confirm against the empty fake composer"
  assert_contains "$(cat "$log")" $'\x1f''send-keys'$'\x1f''-t'$'\x1f''sess:win'$'\x1f''-l'$'\x1f''hello captain' \
    "jg-send did not send the literal text with send-keys -l"
  [ "$(grep -c $'\x1f''-l'$'\x1f' "$log")" -eq 1 ] \
    || fail "jg-send must type the text exactly once (Enter-only retries, never a retype)"
  assert_contains "$(cat "$log")" $'\x1f''Enter' "jg-send did not submit with Enter"

  # Case 3: a slash command still opens the popup-settle path (verified in
  # tests/jg-send-popup-settle.test.sh) and ends in the same command shape:
  # one literal type, then Enter.
  run_send_case "$ROOT" "$fb" "$log" "$home" -- "sess:win" /some-skill
  rc=$?
  expect_code 0 "$rc" "jg-send /skill should confirm against the empty fake composer"
  assert_contains "$(cat "$log")" $'\x1f''send-keys'$'\x1f''-t'$'\x1f''sess:win'$'\x1f''-l'$'\x1f''/some-skill' \
    "jg-send /skill did not type the literal slash command"
  [ "$(grep -c $'\x1f''-l'$'\x1f' "$log")" -eq 1 ] \
    || fail "jg-send /skill must type the text exactly once"

  pass "jg-send.sh: explicit tmux targets are verified; text types once and submits with Enter"
}

# --- old vs new: jg-peek.sh --------------------------------------------------

make_peek_fakebin() {  # <dir> <capture-output> -> echoes fakebin dir
  local dir=$1 payload=$2 fb="$1/fakebin"
  mkdir -p "$fb"
  printf '%s' "$payload" > "$dir/capture.out"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "\$@"; do printf '\\x1f%s' "\$a"; done; printf '\\n'; } >> "\${JG_TMUX_LOG:?}"
case "\${1:-}" in
  capture-pane) cat "$dir/capture.out" ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

test_peek_conformance_old_vs_new() {
  local old_bin fb log_old log_new home out_old out_new payload neutral_root
  payload=$'line one\nline two\ncaptain on deck'
  old_bin=$(build_old_bin peek-old)
  fb=$(make_peek_fakebin "$TMP_ROOT/peek-fake" "$payload")
  home="$TMP_ROOT/peek-home"; mkdir -p "$home/state"
  log_old="$TMP_ROOT/peek-old.log"; log_new="$TMP_ROOT/peek-new.log"
  # A fresh non-git dir keeps jg-guard.sh's worktree-tangle check inert (it warns
  # to stderr, discarded below) - neither run needs JG_ROOT for anything beyond
  # that guard, since STATE/HOME are already overridden directly.
  neutral_root="$TMP_ROOT/peek-neutral-root"; mkdir -p "$neutral_root"

  : > "$log_old"
  out_old=$(PATH="$fb:$PATH" JG_ROOT_OVERRIDE="$neutral_root" JG_HOME="$home" JG_TMUX_LOG="$log_old" \
    "$old_bin/bin/jg-peek.sh" "sess:win" 25 2>/dev/null)
  : > "$log_new"
  out_new=$(PATH="$fb:$PATH" JG_ROOT_OVERRIDE="$neutral_root" JG_HOME="$home" JG_TMUX_LOG="$log_new" \
    "$ROOT/bin/jg-peek.sh" "sess:win" 25 2>/dev/null)

  [ "$out_old" = "$out_new" ] || fail "jg-peek output differs old vs new"$'\n'"--- old ---"$'\n'"$out_old"$'\n'"--- new ---"$'\n'"$out_new"
  [ "$out_new" = "$payload" ] || fail "jg-peek did not pass through the fake capture-pane output exactly"
  diff -u "$log_old" "$log_new" > "$TMP_ROOT/peek-diff.txt" 2>&1 \
    || fail "jg-peek: tmux command log differs old vs new"$'\n'"$(cat "$TMP_ROOT/peek-diff.txt")"
  assert_contains "$(cat "$log_new")" $'\x1f''capture-pane'$'\x1f''-p'$'\x1f''-t'$'\x1f''sess:win'$'\x1f''-S'$'\x1f''-25' \
    "jg-peek did not call capture-pane -p -t <target> -S -<lines> exactly"

  pass "jg-peek.sh: capture-pane invocation and output are byte-identical old vs new"
}

# --- old vs new: jg-spawn.sh --------------------------------------------------

make_spawn_fakebin() {  # <dir> <fake-worktree-path> -> echoes fakebin dir
  local dir=$1 wt=$2 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "\$@"; do printf '\\x1f%s' "\$a"; done; printf '\\n'; } >> "\${JG_TMUX_LOG:?}"
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_path*) printf '%s\\n' "$wt"; exit 0 ;; esac; done
    printf 'juggernaut\\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$wt" > "$fb/treehouse"
  chmod +x "$fb/treehouse"
  printf '%s\n' "$fb"
}

run_spawn_case() {  # <bin-root> <fakebin> <log> <state> <data> <config> <proj> -- <spawn args...>
  local bin=$1 fb=$2 log=$3 state=$4 data=$5 config=$6 proj=$7 home; shift 7
  [ "${1:-}" = -- ] && shift
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/state"
  : > "$log"
  env PATH="$fb:$PATH" JG_ROOT_OVERRIDE="$bin" JG_HOME="$home" HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' \
    JG_STATE_OVERRIDE="$state" JG_DATA_OVERRIDE="$data" JG_CONFIG_OVERRIDE="$config" \
    JG_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" \
    JG_SPAWN_NO_GUARD=1 TMUX="fake,1,0" JG_TMUX_LOG="$log" \
    "$bin/bin/jg-spawn.sh" "$@"
}

# NOTE: the old-vs-new spawn command-log conformance test that used to live here
# was retired. It asserted the P1 backend refactor was a byte-for-byte pure
# extraction of the spawn window-creation/targeting sequence, but that sequence
# is now DELIBERATELY changed: jg-spawn drives the tmux backend to capture a
# stable window id, pin the window name (automatic-rename/allow-rename off), and
# target that id for the rename-critical spawn steps (robustness under a
# captain's non-default tmux config). A byte-identical old-vs-new diff can no
# longer hold there by design. That intended sequence is now authoritatively and
# comprehensively verified - via a recording fake-tmux - by
# tests/jg-tangle-guard.test.sh ("jg-spawn: appends windows by session-colon,
# pins the name, and targets the window id"), and the real tmux create/kill path
# by tests/jg-backend-tmux-smoke.test.sh. The send/peek/teardown conformance
# tests below remain pure extractions and stay. (make_spawn_fakebin and
# run_spawn_case are retained: test_spawn_default_backend_writes_no_meta_field
# uses make_spawn_fakebin, and #294's run_spawn_symlink_case uses run_spawn_case.)

# --- symlinked project prefix must not false-refuse the isolation guard -----
#
# docs/herdr-backend.md "Known gaps": a real backend's pane_current_path read
# (tmux, herdr) reports the OS-level PHYSICALLY-resolved cwd. When the project
# itself lives under a symlinked prefix (e.g. macOS's /tmp -> /private/tmp),
# jg-spawn.sh's PROJ_ABS - a logical `cd && pwd` - differs string-for-string
# from that physical read even before treehouse moves the pane at all, so the
# worktree-discovery poll used to mistake an UNMOVED pane for one that had
# already left the project, handing validate_spawn_worktree the project's own
# directory as "the worktree" and tripping its false isolation refusal.
# make_spawn_symlink_fakebin's tmux stub returns an unmoved project path on the
# first pane_current_path poll, then the real worktree path from the second poll
# onward, so this test fails loudly if the PROJ_ABS/PROJ_ABS_REAL
# canonicalization in bin/jg-spawn.sh ever regresses.
make_spawn_symlink_fakebin() {  # <dir> <initial-project-path> <worktree-path> -> echoes fakebin dir
  local dir=$1 initial_path=$2 wt=$3 fb="$1/fakebin" counter="$1/poll-count"
  mkdir -p "$fb"
  : > "$counter"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "\$@"; do printf '\\x1f%s' "\$a"; done; printf '\\n'; } >> "\${JG_TMUX_LOG:?}"
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_path*)
      printf x >> "$counter"
      if [ "\$(wc -c < "$counter")" -le 1 ]; then
        printf '%s\\n' "$initial_path"
      else
        printf '%s\\n' "$wt"
      fi
      exit 0
    ;; esac; done
    printf 'juggernaut\\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$wt" > "$fb/treehouse"
  chmod +x "$fb/treehouse"
  printf '%s\n' "$fb"
}

run_spawn_symlink_case() {  # <label> <physical|logical>
  local label=$1 first_reply=$2 real_root link_root proj wt id fb data state config log out rc proj_phys initial_path
  real_root="$TMP_ROOT/symlink-real-$label"; link_root="$TMP_ROOT/symlink-link-$label"
  mkdir -p "$real_root"
  ln -s "$real_root" "$link_root"
  proj="$link_root/proj"
  wt="$TMP_ROOT/symlink-wt-$label"
  id="spawnsymlink$label"
  jg_git_worktree "$real_root/proj" "$wt" "fm/$id"
  # TMP_ROOT itself can already sit behind an OS-level symlink (e.g. macOS's
  # /var -> /private/var), so resolve the fakebin's "physical" reply with
  # pwd -P rather than string concatenation - it must match exactly what
  # jg-spawn.sh's own PROJ_ABS_REAL computes, including any symlink layers
  # ABOVE this test's own synthetic real_root/link_root pair.
  proj_phys=$(cd "$real_root/proj" && pwd -P)
  case "$first_reply" in
    physical) initial_path=$proj_phys ;;
    logical) initial_path=$proj ;;
    *) fail "unknown symlink first-reply mode: $first_reply" ;;
  esac
  fb=$(make_spawn_symlink_fakebin "$TMP_ROOT/symlink-fake-$label" "$initial_path" "$wt")
  data="$TMP_ROOT/symlink-data-$label"
  mkdir -p "$data/$id"
  write_spawn_brief "$data/$id/brief.md" "$id"
  state="$TMP_ROOT/symlink-state-$label"; config="$TMP_ROOT/symlink-config-$label"
  mkdir -p "$state" "$config"
  log="$TMP_ROOT/symlink-spawn-$label.log"

  out=$(run_spawn_case "$ROOT" "$fb" "$log" "$state" "$data" "$config" "$proj" -- "$id" "$proj" claude --mode no-mistakes --yolo off 2>&1)
  rc=$?
  expect_code 0 "$rc" "jg-spawn.sh should succeed for a project reached through a symlinked prefix when the backend reports $first_reply cwd"$'\n'"$out"
  assert_contains "$out" "worktree=$wt" \
    "jg-spawn.sh did not resolve a symlinked-prefix project to its real worktree when the backend reports $first_reply cwd"

  rm -rf "/tmp/jg-$id"
}

test_spawn_symlinked_project_prefix_avoids_false_refusal() {
  run_spawn_symlink_case physical physical
  run_spawn_symlink_case logical logical
  pass "jg-spawn.sh: a project reached through a symlinked prefix (e.g. macOS /tmp -> /private/tmp) does not trip the isolation guard's false refusal"
}

# --- old vs new: jg-teardown.sh ----------------------------------------------

make_teardown_fakebin() {  # <dir> -> echoes fakebin dir; logs tmux+treehouse calls
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${JG_TMUX_LOG:?}"
exit 0
SH
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'treehouse'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${JG_TMUX_LOG:?}"
exit 0
SH
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) printf '0.2.6\n'; exit 0 ;;
  hold) [ "${2:-}" = --help ] && { printf '%s\n' 'usage: tasks-axi hold <id> --reason <text> --kind captain'; exit 0; } ;;
  update) [ "${2:-}" = --help ] && { printf '%s\n' 'usage: tasks-axi update <id> --body-file <path> --archive-body'; exit 0; } ;;
  mv) [ "${2:-}" = --help ] && { printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'; exit 0; } ;;
esac
exit 0
SH
  chmod +x "$fb/tmux" "$fb/treehouse" "$fb/tasks-axi"
  printf '%s\n' "$fb"
}

# run_teardown_case <script> <jg-root-override> <fakebin> <log> <state> <data> <config> <id>
# JG_ROOT_OVERRIDE is passed separately from <script> so both the old and new
# runs can point it at the SAME neutral (non-git) shim root - that root's
# bin/jg-guard.sh is a symlink to the real, unchanged script, so the
# worktree-tangle check runs identically (and silently) for both, regardless
# of which jg-teardown.sh (old or new) is actually being invoked.
run_teardown_case() {
  local script=$1 fmroot=$2 fb=$3 log=$4 state=$5 data=$6 config=$7 id=$8
  : > "$log"
  env PATH="$fb:$PATH" JG_ROOT_OVERRIDE="$fmroot" \
    JG_STATE_OVERRIDE="$state" JG_DATA_OVERRIDE="$data" JG_CONFIG_OVERRIDE="$config" \
    JG_TMUX_LOG="$log" \
    "$script" "$id"
}

test_teardown_conformance_old_vs_new() {
  local old_bin fb proj wt id old_tmux_ref saved_base_ref
  local state_old state_new config_old config_new data log_old log_new out_old out_new rc_old rc_new
  # Force the post-squash topology inside this case: merge-base with main may
  # equal HEAD on default-branch CI, and that must not make the legacy kill
  # fixture self-referential. build_old_bin still uses BASE_REF for entrypoints;
  # only the tmux kill adapter is pinned to the content-historical permissive ref.
  saved_base_ref=$BASE_REF
  BASE_REF=$(git -C "$ROOT" rev-parse HEAD)
  old_tmux_ref=$(resolve_permissive_tmux_kill_ref) \
    || { BASE_REF=$saved_base_ref; fail "unable to locate a historical bin/backends/tmux.sh with permissive kill-window selectors"; }
  old_bin=$(build_old_bin teardown-old)
  git -C "$ROOT" show "$old_tmux_ref:bin/backends/tmux.sh" > "$old_bin/bin/backends/tmux.sh" \
    || { BASE_REF=$saved_base_ref; fail "could not materialize historical tmux adapter from $old_tmux_ref"; }
  BASE_REF=$saved_base_ref
  proj="$TMP_ROOT/teardown-project"; wt="$TMP_ROOT/teardown-wt"
  id="teardownconform1"
  jg_git_worktree "$proj" "$wt" "fm/$id"
  fb=$(make_teardown_fakebin "$TMP_ROOT/teardown-fake")

  data="$TMP_ROOT/teardown-data"
  mkdir -p "$data/$id"
  printf 'scout findings\n' > "$data/$id/report.md"

  state_old="$TMP_ROOT/teardown-state-old"; state_new="$TMP_ROOT/teardown-state-new"
  config_old="$TMP_ROOT/teardown-config-old"; config_new="$TMP_ROOT/teardown-config-new"
  mkdir -p "$state_old" "$state_new" "$config_old" "$config_new"

  jg_write_meta "$state_old/$id.meta" \
    "window=juggernaut:jg-$id" "worktree=$wt" "project=$proj" "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "decisions_reviewed=1" "decision_keys="
  jg_write_meta "$state_new/$id.meta" \
    "window=juggernaut:jg-$id" "worktree=$wt" "project=$proj" "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "decisions_reviewed=1" "decision_keys="
  touch "$state_old/.last-watcher-beat" "$state_new/.last-watcher-beat"

  log_old="$TMP_ROOT/teardown-old.log"; log_new="$TMP_ROOT/teardown-new.log"
  out_old=$(run_teardown_case "$old_bin/bin/jg-teardown.sh" "$old_bin" "$fb" "$log_old" "$state_old" "$data" "$config_old" "$id" 2>&1)
  rc_old=$?
  out_new=$(run_teardown_case "$ROOT/bin/jg-teardown.sh" "$old_bin" "$fb" "$log_new" "$state_new" "$data" "$config_new" "$id" 2>&1)
  rc_new=$?

  expect_code 0 "$rc_old" "old jg-teardown.sh (scout, report present) should succeed"$'\n'"$out_old"
  expect_code 0 "$rc_new" "new jg-teardown.sh (scout, report present) should succeed"$'\n'"$out_new"
  assert_contains "$(cat "$log_new")" "treehouse"$'\x1f''return'$'\x1f''--force'$'\x1f'"$wt" \
    "teardown did not call treehouse return --force <worktree>"
  # The legacy fixture's adapter comes from BASE_REF, so its selector form is
  # whatever the merge-base carried: permissive while the exact-selector change
  # was still on a branch, exact for every branch cut after it landed on main.
  # Pinning the old form here would make this case pass once and then fail
  # forever, so the '=' exactness markers are normalized away and the legacy run
  # is only required to have reached tmux window cleanup for this task. The
  # exact-selector contract belongs to the current script, asserted below.
  assert_contains "$(tr -d '=' < "$log_old")" "tmux"$'\x1f''kill-window'$'\x1f''-t'$'\x1f'"juggernaut:jg-$id" \
    "legacy teardown fixture did not exercise tmux window cleanup for the task"
  assert_contains "$(cat "$log_new")" "tmux"$'\x1f''kill-window'$'\x1f''-t'$'\x1f'"=juggernaut:=jg-$id" \
    "teardown did not call tmux kill-window with exact session and window selectors"

  pass "jg-teardown.sh: treehouse return remains compatible while tmux cleanup uses exact selectors"
}

# --- backend selection loudly refuses an unknown backend --------------------

test_spawn_refuses_unknown_backend_flag() {
  local out status
  # bogus names a backend with no adapter at all; zellij and orca both
  # graduated to real adapters and have their own spawn tests.
  out=$(JG_ROOT_OVERRIDE='' JG_HOME='' JG_STATE_OVERRIDE='' JG_DATA_OVERRIDE='' \
    JG_PROJECTS_OVERRIDE='' JG_CONFIG_OVERRIDE='' JG_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/jg-spawn.sh" nope-backend-z1 projects/none claude --mode no-mistakes --yolo off --backend bogus 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "jg-spawn --backend bogus should refuse"
  assert_contains "$out" "unknown backend 'bogus'" "jg-spawn did not name the rejected backend"
  pass "jg-spawn.sh --backend bogus is refused loudly"
}

test_spawn_refuses_codex_app_backend_flag() {
  local out status
  out=$(JG_ROOT_OVERRIDE='' JG_HOME='' JG_STATE_OVERRIDE='' JG_DATA_OVERRIDE='' \
    JG_PROJECTS_OVERRIDE='' JG_CONFIG_OVERRIDE='' JG_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/jg-spawn.sh" nope-codex-app-z1 projects/none claude --mode no-mistakes --yolo off --backend codex-app 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "jg-spawn --backend codex-app should refuse"
  assert_contains "$out" "unknown backend 'codex-app'" "jg-spawn did not preserve the blocked codex-app contract"
  pass "jg-spawn.sh --backend codex-app is refused"
}

test_spawn_refuses_unknown_jg_backend_env() {
  local out status
  out=$(JG_ROOT_OVERRIDE='' JG_HOME='' JG_STATE_OVERRIDE='' JG_DATA_OVERRIDE='' \
    JG_PROJECTS_OVERRIDE='' JG_CONFIG_OVERRIDE='' JG_SPAWN_NO_GUARD=1 JG_BACKEND=bogus \
    "$ROOT/bin/jg-spawn.sh" nope-backend-z2 projects/none claude --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "JG_BACKEND=bogus should refuse"
  assert_contains "$out" "unknown backend 'bogus'" "jg-spawn did not name the rejected JG_BACKEND"
  pass "jg-spawn.sh honors JG_BACKEND and refuses an unimplemented value loudly"
}

test_spawn_default_backend_writes_no_meta_field() {
  local proj wt data id state config out
  proj="$TMP_ROOT/nobackend-project"; wt="$TMP_ROOT/nobackend-wt"; data="$TMP_ROOT/nobackend-data"
  id="nobackendz3"
  jg_git_worktree "$proj" "$wt" "fm/$id"
  local fb
  fb=$(make_spawn_fakebin "$TMP_ROOT/nobackend-fake" "$wt")
  mkdir -p "$data/$id"; write_spawn_brief "$data/$id/brief.md" "$id"
  state="$TMP_ROOT/nobackend-state"; config="$TMP_ROOT/nobackend-config"
  mkdir -p "$state" "$config"

  out=$(PATH="$fb:$PATH" JG_ROOT_OVERRIDE="$ROOT" HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' \
    JG_STATE_OVERRIDE="$state" JG_DATA_OVERRIDE="$data" JG_CONFIG_OVERRIDE="$config" \
    JG_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" JG_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    JG_TMUX_LOG="$TMP_ROOT/nobackend.log" \
    "$ROOT/bin/jg-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend tmux 2>&1)
  expect_code 0 $? "explicit --backend tmux should spawn successfully"$'\n'"$out"
  assert_no_grep 'backend=' "$state/$id.meta" \
    "an explicit --backend tmux (the default) must not write backend= to meta (P1 compatibility contract)"
  rm -rf "/tmp/jg-$id"
  pass "jg-spawn.sh: an explicit --backend tmux resolves silently and writes no backend= (missing means tmux)"
}

test_spawn_explicit_backend_flag_beats_autodetect_herdr_env() {
  local proj wt data id state config out fb
  proj="$TMP_ROOT/explicit-backend-project"; wt="$TMP_ROOT/explicit-backend-wt"; data="$TMP_ROOT/explicit-backend-data"
  id="explicitbackendz4"
  jg_git_worktree "$proj" "$wt" "fm/$id"
  fb=$(make_spawn_fakebin "$TMP_ROOT/explicit-backend-fake" "$wt")
  mkdir -p "$data/$id"; write_spawn_brief "$data/$id/brief.md" "$id"
  state="$TMP_ROOT/explicit-backend-state"; config="$TMP_ROOT/explicit-backend-config"
  mkdir -p "$state" "$config"

  # HERDR_ENV=1 is present (as if juggernaut itself were running under herdr),
  # but an explicit --backend tmux flag must still win outright.
  out=$(PATH="$fb:$PATH" JG_ROOT_OVERRIDE="$ROOT" HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' \
    JG_STATE_OVERRIDE="$state" JG_DATA_OVERRIDE="$data" JG_CONFIG_OVERRIDE="$config" \
    JG_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" JG_SPAWN_NO_GUARD=1 TMUX="fake,1,0" HERDR_ENV=1 \
    JG_TMUX_LOG="$TMP_ROOT/explicit-backend.log" \
    "$ROOT/bin/jg-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend tmux 2>&1)
  expect_code 0 $? "explicit --backend tmux should spawn successfully even with HERDR_ENV=1 set"$'\n'"$out"
  assert_no_grep 'backend=' "$state/$id.meta" \
    "an explicit --backend tmux must win over an ambient HERDR_ENV=1 auto-detect marker"
  rm -rf "/tmp/jg-$id"
  pass "jg-spawn.sh: explicit --backend tmux wins over an ambient HERDR_ENV=1 auto-detect marker"
}

test_spawn_autodetect_nesting_resolves_tmux_silently() {
  local proj wt data id state config out fb
  proj="$TMP_ROOT/nest-project"; wt="$TMP_ROOT/nest-wt"; data="$TMP_ROOT/nest-data"
  id="nestbackendz5"
  jg_git_worktree "$proj" "$wt" "fm/$id"
  fb=$(make_spawn_fakebin "$TMP_ROOT/nest-fake" "$wt")
  mkdir -p "$data/$id"; write_spawn_brief "$data/$id/brief.md" "$id"
  state="$TMP_ROOT/nest-state"; config="$TMP_ROOT/nest-config"
  mkdir -p "$state" "$config"

  # No --backend, no JG_BACKEND, no config/backend: nothing is explicitly
  # configured, so auto-detect runs. $TMUX and HERDR_ENV=1 are both present
  # (tmux nested inside a herdr pane) - the full jg-spawn.sh pipeline, not just
  # jg_backend_name, must resolve this to tmux and stay completely silent about
  # it (today's default path, byte-identical).
  out=$(PATH="$fb:$PATH" JG_ROOT_OVERRIDE="$ROOT" HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' \
    JG_STATE_OVERRIDE="$state" JG_DATA_OVERRIDE="$data" JG_CONFIG_OVERRIDE="$config" \
    JG_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" JG_SPAWN_NO_GUARD=1 TMUX="fake,1,0" HERDR_ENV=1 \
    JG_TMUX_LOG="$TMP_ROOT/nest.log" \
    "$ROOT/bin/jg-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off 2>&1)
  expect_code 0 $? "jg-spawn.sh should auto-detect tmux and spawn successfully for nested tmux-in-herdr"$'\n'"$out"
  assert_no_grep 'backend=' "$state/$id.meta" \
    "auto-detected nested tmux-in-herdr must resolve to tmux (missing backend= means tmux)"
  case "$out" in
    *NOTICE*) fail "auto-detecting tmux (even nested inside herdr) must stay silent, no NOTICE expected"$'\n'"$out" ;;
  esac
  rm -rf "/tmp/jg-$id"
  pass "jg-spawn.sh: auto-detect resolves nested tmux-in-herdr to tmux and stays silent end to end"
}

if [ -n "${JG_TEST_ONLY:-}" ]; then
  "$JG_TEST_ONLY"
  exit 0
fi

backend_base_ref >/dev/null

test_backend_name_precedence
test_backend_detect_precedence
test_backend_detect_cmux_fallback_bundle_id
test_backend_detect_cmux_fallback_requires_darwin
test_backend_detect_cmux_fallback_tmux_nested_false_positive
test_backend_detect_cmux_fallback_ancestry_pid_match
test_backend_detect_cmux_fallback_ancestry_comm_match
test_backend_detect_cmux_fallback_ancestry_stops_at_launchd
test_backend_name_cmux_fallback_notice
test_backend_name_autodetect_notice
test_backend_name_explicit_beats_detection
test_backend_validate_refuses_unknown
test_backend_source_shell_portable
test_backend_source_requires_adapter_file
test_backend_validate_spawn_accepts_orca
test_meta_get_and_backend_of_meta
test_resolve_selector_three_forms
test_backend_of_selector_matches_explicit_target_meta
test_send_tmux_contract
test_peek_conformance_old_vs_new
test_spawn_symlinked_project_prefix_avoids_false_refusal
test_teardown_conformance_old_vs_new
test_spawn_refuses_unknown_backend_flag
test_spawn_refuses_codex_app_backend_flag
test_spawn_refuses_unknown_jg_backend_env
test_spawn_default_backend_writes_no_meta_field
test_spawn_explicit_backend_flag_beats_autodetect_herdr_env
test_spawn_autodetect_nesting_resolves_tmux_silently
