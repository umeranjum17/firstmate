#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (jg-gotmp).
#
# jg-spawn gives each task a temp root /tmp/jg-<id>/ with Go's build temp nested at
# gotmp/, exports GOTMPDIR into the crewmate pane, and records tasktmp= in the task's
# meta. jg-teardown reads tasktmp= and removes the whole root on cleanup.
#
# These tests exercise jg-teardown directly as a subprocess against a fake FM_HOME/FM_ROOT
# built so the real script resolves into it, with stub helper scripts.
# The isolated jg-spawn subprocess in jg-kimi-harness.test.sh covers temp-root creation,
# metadata publication, and the pane environment export.
set -u

# This suite does not source tests/lib.sh, so exempt its teardown subprocess from
# the gate-lifecycle refusal (bin/jg-gate-refuse-lib.sh) the way lib.sh does for
# the rest of the suite: the no-mistakes gate runs this suite from a gate worktree,
# which the guard would otherwise refuse.
export FM_GATE_REFUSE_BYPASS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEARDOWN="$ROOT/bin/jg-teardown.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/jg-gotmp-tests.XXXXXX")

# Build a fake FM_HOME/FM_ROOT so the real jg-teardown.sh (symlinked in) resolves
# state and helper scripts inside it. Stub the helper scripts jg-teardown calls so no
# live tmux/treehouse/fleet state is touched. A nonexistent worktree path makes both
# `if [ -d "$WT" ]` guards skip, so teardown runs straight to the cleanup + state rm.
make_fake_root() {
  local id=$1 tasktmp=$2
  local fake="$TMP_ROOT/$id"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/data"
  # Symlink the REAL teardown so the test exercises actual code, not a copy.
  ln -s "$TEARDOWN" "$fake/bin/jg-teardown.sh"
  # jg-backend.sh is real, while its adapter is stubbed so this temp-cleanup
  # test cannot depend on or mutate a host tmux server. Teardown still refuses
  # unless every sibling the real tmux adapter sources is present.
  ln -s "$ROOT/bin/jg-backend.sh" "$fake/bin/jg-backend.sh"
  cat > "$fake/bin/backends/tmux.sh" <<'SH'
jg_backend_tmux_kill() { return 0; }
SH
  ln -s "$ROOT/bin/jg-tmux-lib.sh" "$fake/bin/jg-tmux-lib.sh"
  ln -s "$ROOT/bin/jg-session-lock-lib.sh" "$fake/bin/jg-session-lock-lib.sh"
  ln -s "$ROOT/bin/jg-agent-process-lib.sh" "$fake/bin/jg-agent-process-lib.sh"
  ln -s "$ROOT/bin/jg-gemini-lib.sh" "$fake/bin/jg-gemini-lib.sh"
  ln -s "$ROOT/bin/jg-cursor-lib.sh" "$fake/bin/jg-cursor-lib.sh"
  ln -s "$ROOT/bin/jg-composer-lib.sh" "$fake/bin/jg-composer-lib.sh"
  ln -s "$ROOT/bin/jg-nm-run-lib.sh" "$fake/bin/jg-nm-run-lib.sh"
  # jg-lock-lib.sh: teardown sources it for the shared lock-staleness proof.
  ln -s "$ROOT/bin/jg-lock-lib.sh" "$fake/bin/jg-lock-lib.sh"
  # jg-lease-lib.sh: teardown sources it for the supervision lease guard.
  ln -s "$ROOT/bin/jg-lease-lib.sh" "$fake/bin/jg-lease-lib.sh"
  # Lifecycle serialization, status presentation retirement, and shared adapter
  # ownership are sourced by teardown.
  ln -s "$ROOT/bin/jg-control-lib.sh" "$fake/bin/jg-control-lib.sh"
  ln -s "$ROOT/bin/jg-classify-lib.sh" "$fake/bin/jg-classify-lib.sh"
  # jg-timeout-lib.sh: the shared hard bound jg-classify-lib.sh sources for the
  # wedge detector's bounded worktree write probe.
  ln -s "$ROOT/bin/jg-timeout-lib.sh" "$fake/bin/jg-timeout-lib.sh"
  ln -s "$ROOT/bin/jg-wake-lib.sh" "$fake/bin/jg-wake-lib.sh"
  ln -s "$ROOT/bin/jg-path-lib.sh" "$fake/bin/jg-path-lib.sh"
  # jg-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/jg-gate-refuse-lib.sh" "$fake/bin/jg-gate-refuse-lib.sh"
  # jg-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/jg-pr-lib.sh" "$fake/bin/jg-pr-lib.sh"
  ln -s "$ROOT/bin/jg-scratch.sh" "$fake/bin/jg-scratch.sh"
  # jg-dod-lib.sh (and the jg-brief-heading-lib.sh it sources): teardown uses
  # its PR-outside-origin check to prove a cross-repo lane.
  ln -s "$ROOT/bin/jg-dod-lib.sh" "$fake/bin/jg-dod-lib.sh"
  ln -s "$ROOT/bin/jg-brief-heading-lib.sh" "$fake/bin/jg-brief-heading-lib.sh"
  # jg-public-followup-lib.sh (and the jg-x-lib.sh and jg-env-lib.sh it
  # sources): teardown sources it for the relay-activation gate on the
  # promised-public-reply check. None does anything in this fixture, which has
  # no .env, but all three are real siblings teardown now requires.
  ln -s "$ROOT/bin/jg-public-followup-lib.sh" "$fake/bin/jg-public-followup-lib.sh"
  ln -s "$ROOT/bin/jg-x-lib.sh" "$fake/bin/jg-x-lib.sh"
  ln -s "$ROOT/bin/jg-env-lib.sh" "$fake/bin/jg-env-lib.sh"
  ln -s "$ROOT/bin/jg-secondmate-registry-lib.sh" "$fake/bin/jg-secondmate-registry-lib.sh"
  ln -s "$ROOT/bin/jg-secondmate-parent-lib.sh" "$fake/bin/jg-secondmate-parent-lib.sh"
  # Receiver-wake retirement sources the pending-reply library, which in turn
  # requires the marker helper even for this ordinary-task teardown fixture.
  ln -s "$ROOT/bin/jg-pending-reply-lib.sh" "$fake/bin/jg-pending-reply-lib.sh"
  ln -s "$ROOT/bin/jg-parked-homes-lib.sh" "$fake/bin/jg-parked-homes-lib.sh"
  ln -s "$ROOT/bin/jg-marker-lib.sh" "$fake/bin/jg-marker-lib.sh"
  ln -s "$ROOT/bin/jg-operational-input.sh" "$fake/bin/jg-operational-input.sh"
  # Ordinary teardown reports any final ledger outcome before removing records.
  ln -s "$ROOT/bin/jg-inactive-reconcile.sh" "$fake/bin/jg-inactive-reconcile.sh"
  ln -s "$ROOT/bin/jg-parent-channel-lib.sh" "$fake/bin/jg-parent-channel-lib.sh"
  # jg-guard.sh: stub (teardown calls it with `|| true`).
  cat > "$fake/bin/jg-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/jg-guard.sh"
  # jg-fleet-sync.sh: stub (called for non-scout/non-local-only teardowns).
  cat > "$fake/bin/jg-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/jg-fleet-sync.sh"
  # jg-tasks-axi-lib.sh: stub (teardown sources it). Report no backend so the
  # fused backlog close is skipped and the follow-up echo takes the plain-message
  # path; there is no tasks-axi and no backlog in this fixture.
  cat > "$fake/bin/jg-tasks-axi-lib.sh" <<'SH'
FM_TASKS_AXI_MIN=0.2.6
jg_tasks_axi_backend() { printf 'markdown\n'; }
jg_tasks_axi_backend_available() { return 1; }
jg_tasks_axi_compatible() { return 1; }
jg_backlog_backend_manual() { return 1; }
SH
  ln -s "$ROOT/bin/jg-backlog-transition-lib.sh" "$fake/bin/jg-backlog-transition-lib.sh"
  # Meta with a nonexistent worktree so the dirty/treehouse blocks skip.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:jg-$id
worktree=$TMP_ROOT/nonexistent-worktree-$id
project=$TMP_ROOT/nonexistent-project-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=$tasktmp
META
  printf '%s' "$fake"
}

# --- jg-teardown side (real subprocess) ---

test_teardown_removes_tasktmp_dir() {
  local id=td-rm-z2
  local task_tmp="$TMP_ROOT/jg-$id"
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  # Sanity: dir + contents exist before teardown.
  [ -d "$task_tmp/gotmp" ] || fail "precondition: gotmp missing before teardown"
  # Run the REAL teardown against the fake root.
  FM_HOME="$fake" bash "$fake/bin/jg-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero with a valid tasktmp"
  [ ! -e "$task_tmp" ] \
    || fail "teardown did not remove the tasktmp dir ($task_tmp still exists)"
  pass "jg-teardown removes the dir pointed to by tasktmp= in meta"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake="$TMP_ROOT/$id-root"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/data"
  ln -s "$TEARDOWN" "$fake/bin/jg-teardown.sh"
  ln -s "$ROOT/bin/jg-backend.sh" "$fake/bin/jg-backend.sh"
  cat > "$fake/bin/backends/tmux.sh" <<'SH'
jg_backend_tmux_kill() { return 0; }
SH
  ln -s "$ROOT/bin/jg-tmux-lib.sh" "$fake/bin/jg-tmux-lib.sh"
  ln -s "$ROOT/bin/jg-session-lock-lib.sh" "$fake/bin/jg-session-lock-lib.sh"
  ln -s "$ROOT/bin/jg-agent-process-lib.sh" "$fake/bin/jg-agent-process-lib.sh"
  ln -s "$ROOT/bin/jg-gemini-lib.sh" "$fake/bin/jg-gemini-lib.sh"
  ln -s "$ROOT/bin/jg-cursor-lib.sh" "$fake/bin/jg-cursor-lib.sh"
  ln -s "$ROOT/bin/jg-composer-lib.sh" "$fake/bin/jg-composer-lib.sh"
  ln -s "$ROOT/bin/jg-nm-run-lib.sh" "$fake/bin/jg-nm-run-lib.sh"
  ln -s "$ROOT/bin/jg-lock-lib.sh" "$fake/bin/jg-lock-lib.sh"
  # jg-lease-lib.sh: teardown sources it for the supervision lease guard.
  ln -s "$ROOT/bin/jg-lease-lib.sh" "$fake/bin/jg-lease-lib.sh"
  ln -s "$ROOT/bin/jg-control-lib.sh" "$fake/bin/jg-control-lib.sh"
  ln -s "$ROOT/bin/jg-classify-lib.sh" "$fake/bin/jg-classify-lib.sh"
  # jg-timeout-lib.sh: the shared hard bound jg-classify-lib.sh sources for the
  # wedge detector's bounded worktree write probe.
  ln -s "$ROOT/bin/jg-timeout-lib.sh" "$fake/bin/jg-timeout-lib.sh"
  ln -s "$ROOT/bin/jg-wake-lib.sh" "$fake/bin/jg-wake-lib.sh"
  ln -s "$ROOT/bin/jg-path-lib.sh" "$fake/bin/jg-path-lib.sh"
  # jg-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/jg-gate-refuse-lib.sh" "$fake/bin/jg-gate-refuse-lib.sh"
  # jg-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/jg-pr-lib.sh" "$fake/bin/jg-pr-lib.sh"
  ln -s "$ROOT/bin/jg-scratch.sh" "$fake/bin/jg-scratch.sh"
  # jg-dod-lib.sh (and the jg-brief-heading-lib.sh it sources): teardown uses
  # its PR-outside-origin check to prove a cross-repo lane.
  ln -s "$ROOT/bin/jg-dod-lib.sh" "$fake/bin/jg-dod-lib.sh"
  ln -s "$ROOT/bin/jg-brief-heading-lib.sh" "$fake/bin/jg-brief-heading-lib.sh"
  # jg-public-followup-lib.sh (and the jg-x-lib.sh and jg-env-lib.sh it
  # sources): teardown sources it for the relay-activation gate on the
  # promised-public-reply check. None does anything in this fixture, which has
  # no .env, but all three are real siblings teardown now requires.
  ln -s "$ROOT/bin/jg-public-followup-lib.sh" "$fake/bin/jg-public-followup-lib.sh"
  ln -s "$ROOT/bin/jg-x-lib.sh" "$fake/bin/jg-x-lib.sh"
  ln -s "$ROOT/bin/jg-env-lib.sh" "$fake/bin/jg-env-lib.sh"
  ln -s "$ROOT/bin/jg-secondmate-registry-lib.sh" "$fake/bin/jg-secondmate-registry-lib.sh"
  ln -s "$ROOT/bin/jg-secondmate-parent-lib.sh" "$fake/bin/jg-secondmate-parent-lib.sh"
  ln -s "$ROOT/bin/jg-pending-reply-lib.sh" "$fake/bin/jg-pending-reply-lib.sh"
  ln -s "$ROOT/bin/jg-parked-homes-lib.sh" "$fake/bin/jg-parked-homes-lib.sh"
  ln -s "$ROOT/bin/jg-marker-lib.sh" "$fake/bin/jg-marker-lib.sh"
  ln -s "$ROOT/bin/jg-operational-input.sh" "$fake/bin/jg-operational-input.sh"
  ln -s "$ROOT/bin/jg-inactive-reconcile.sh" "$fake/bin/jg-inactive-reconcile.sh"
  ln -s "$ROOT/bin/jg-parent-channel-lib.sh" "$fake/bin/jg-parent-channel-lib.sh"
  cat > "$fake/bin/jg-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/jg-guard.sh"
  cat > "$fake/bin/jg-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/jg-fleet-sync.sh"
  cat > "$fake/bin/jg-tasks-axi-lib.sh" <<'SH'
FM_TASKS_AXI_MIN=0.2.6
jg_tasks_axi_backend() { printf 'markdown\n'; }
jg_tasks_axi_backend_available() { return 1; }
jg_tasks_axi_compatible() { return 1; }
jg_backlog_backend_manual() { return 1; }
SH
  ln -s "$ROOT/bin/jg-backlog-transition-lib.sh" "$fake/bin/jg-backlog-transition-lib.sh"
  # No tasktmp= line at all.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:jg-$id
worktree=$TMP_ROOT/nonexistent-wt-$id
project=$TMP_ROOT/nonexistent-proj-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
META
  FM_HOME="$fake" bash "$fake/bin/jg-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp= was absent"
  pass "jg-teardown skips gracefully when tasktmp= is absent (backward compat)"
}

test_teardown_skips_gracefully_when_dir_missing() {
  # tasktmp= points to a path that does not exist. Teardown must not error.
  local id=td-missing-z4
  local task_tmp="$TMP_ROOT/never-created-jg-$id"
  # Intentionally do NOT create $task_tmp.
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  FM_HOME="$fake" bash "$fake/bin/jg-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp dir was missing"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "jg-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}

test_teardown_removes_tasktmp_dir
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
