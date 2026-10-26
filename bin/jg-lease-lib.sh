#!/usr/bin/env bash
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
. "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh"
# jg-lease-lib.sh - the per-task supervision lease contract (one owner).
#
# WHY. A supervision branch (docs/pi-supervision-branch.md) is a second LLM
# actor beside MAIN (the captain's chat) in one juggernaut home - on Pi, a
# persistent conversation inside the same pi process; beside another primary,
# a headless engine session run by the supervision host
# (docs/supervision-host.md) - and nothing in this contract assumes the two
# actors share a process. Most records have exactly one natural owner, but the
# overlap set - steering or stopping a worker, post-landing cleanup, backlog
# status for a task, stuck-worker recovery - could otherwise be mutated by both
# actors at once. The lease is the
# merge-conflict analog: a small per-task file saying which actor is changing
# that task right now, and the mutating entrypoints refuse the other actor
# while it exists.
#
# CONTRACT.
#   - Lease file: $STATE/.lease-<task>, one line "<actor>\t<pid>\t<epoch>".
#     Written atomically (temp + ln for claim, temp + mv for a same-actor
#     refresh), with inspection and mutation serialized by the home-local
#     lease-command lock; leases never coordinate across juggernaut homes.
#   - Actors: exactly "main" and "branch". The current actor is
#     $JG_SUPERVISION_ACTOR when set, else "main". The branch's shell gets
#     JG_SUPERVISION_ACTOR=branch injected deterministically by the process
#     hosting it (on Pi, the branch extension's bash tool; elsewhere, the
#     supervision host's engine environment), not by agent memory. Any other
#     value is refused loudly - an unknown actor is a wiring bug, not a third
#     role.
#   - Staleness: the recorded pid is the long-lived supervising process (the
#     session-lock holder, or JG_LEASE_HOLDER_PID - see bin/jg-lease.sh), so a
#     dead recorded pid means the supervising session died; the lease is
#     cleared at the next claim, guard, or sweep. Liveness is the pure record
#     test, identical in every calling context: the recorded pid is alive and
#     IS the current state/.lock holder. So a lease left by an exited session
#     goes stale for every reader, whichever harness now owns the home, and an
#     unmarked main honors a live branch lease exactly as a Pi main does. The
#     one residual is a recorded pid recycled onto the next session-lock holder
#     itself; the host that owns a branch conversation releases that actor's
#     leases when it activates a new one (the Pi branch extension's
#     generation-activation cleanup; the supervision host also releases them
#     after every engine turn), which also recovers a lease held by the live
#     session but an abandoned branch conversation.
#
# THREAT MODEL (deliberate, captain-decided): these guards are
# CONFUSED-AGENT-GRADE, the same grade bin/jg-gate-refuse-lib.sh documents
# for the gate refusal. They stop non-deliberate misuse - the injected actor
# identity, the loud refusals, and the session-bound staleness make every
# accidental cross-actor mutation fail loudly. A deliberately forging shell
# running as the same uid inside the same pi process can evade any in-process
# discriminator (it can rewrite env, spawn fresh shells, and edit state
# files), so adversarial-grade separation is explicitly out of scope here and
# tracked as separate follow-up design work. The branch's shell prelude makes
# the actor variables readonly (see the Pi branch extension), so an
# ACCIDENTAL override fails loudly inside the branch's own shell as well.
#   - Guard semantics (jg_lease_guard): no lease, a same-actor lease, or a
#     provably stale lease passes; a live lease held by the OTHER actor
#     refuses with exit JG_LEASE_REFUSE_EXIT. Whenever the guard engages - a
#     supervision context (Pi, or an explicit actor), a home that runs the
#     supervision host (jg_supervision_host_enabled, whose host can claim a
#     task that has no lease yet), or any lease file for the task - it retains the
#     lease-command lock until jg_lease_guard_release, so the other actor
#     cannot claim between the check and the guarded mutation, including the
#     first claim of a task no one has leased. An unmarked caller in any other
#     home with no lease file for the task returns before taking any lock, so a
#     home that never runs a branch is unchanged byte for byte.
#   - Role partition (jg_lease_forbid_branch): actions MAIN alone owns -
#     merging a PR, landing local-only work, spawning workers, answering a
#     decision, retiring a squad_lead - refuse the branch actor outright,
#     lease or no lease, while the home is attended. While a confirmed,
#     readable, live away record exists (bin/jg-afk-contract.sh validate and
#     mode, never quiet mode's record, whose captain is present; docs/pi-
#     supervision-branch.md "Postures"), main is parked and its STANDING authority
#     relocates to the branch for exactly the actions whose guarded script
#     opts in with --away-relocated: a PR merge, a fresh spawn of queued work,
#     and a decision answer. Each guarded script keeps its own mechanical gate;
#     bin/jg-branch-prompt.sh "Postures" owns how the branch judges the
#     captain's away words before invoking one. The
#     relocation grants nothing beyond what main could do attended: it only
#     changes which actor may reach the guarded script's own gate. An action
#     that has no record-side gate of its own - landing local-only work or
#     retiring a squad_lead - is never relocated and keeps refusing the branch
#     in both postures. An archived, absent, unconfirmed, or unreadable record
#     is absence: the
#     attended refusal, byte for byte. The record is validated immediately
#     before the guarded script's first persistent side effect and the lock is
#     not held across the operation, so a return's archive is never blocked by
#     a long spawn; a spawn or answer that completes seconds after archive is
#     standing-authority work the captain had queued anyway (accepted,
#     confused-agent-grade, like the merge residuals jg-pr-merge.sh documents).
#   - "backlog" is a reserved claimable resource name used by the branch
#     prompt around its own data/backlog.md writes. This is deliberately
#     branch-side containment only; main's tasks-axi path has no executable
#     backlog lease guard in this scope.
#
# Sourced by bin/jg-send.sh, bin/jg-control.sh, bin/jg-teardown.sh,
# bin/jg-pr-merge.sh, bin/jg-merge-local.sh, bin/jg-spawn.sh, and
# bin/jg-lease.sh. Callers must have $STATE resolved before calling. No side
# effects on source. set -u / set -e safe.

# Distinct from usage errors (2), the gate refusal (3), and jg-send's
# unconfirmed submit (3): recognizable as "the other supervision actor holds
# this task right now - retry after the lease clears".
JG_LEASE_REFUSE_EXIT=6
JG_LEASE_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
JG_LEASE_GUARD_LOCK=

jg_lease_lock_helpers() {
  if ! command -v jg_lock_acquire_wait >/dev/null 2>&1; then
    # jg-wake-lib.sh is a canonical lint root in its own right and is already
    # sourced directly by every caller of this lazy fallback; keep this an
    # analysis boundary so ShellCheck's external-source traversal does not
    # recursively duplicate that large graph for every lease-lib consumer.
    # shellcheck source=/dev/null
    . "$JG_LEASE_LIB_DIR/jg-wake-lib.sh"
  fi
  if ! command -v jg_lock_age >/dev/null 2>&1; then
    # jg-lock-lib.sh is a side-effect-free leaf that owns the lock-age read
    # used by the bounded lease-command acquire below.
    # shellcheck source=bin/jg-lock-lib.sh
    . "$JG_LEASE_LIB_DIR/jg-lock-lib.sh"
  fi
}

# The lease-command lock serializes every lease inspection and mutation in the
# home, so a holder that never releases it wedges the whole lease surface at
# once - every steer, relaunch, teardown, claim, and sweep. The holder's pid
# cannot decide that on its own: a post-reboot leftover whose pid has been
# recycled onto an unrelated live process looks exactly like a working holder,
# and a wedged holder is genuinely alive. The lock's own age is the abandonment
# proof instead, so the wait is bounded by it: past this bound a live holder is
# treated as abandoned and the lock is reclaimed, and a holder still inside the
# bound is never preempted. 300s is the fleet's usual guard grace and sits far
# above any real lease-command hold (claim, release, and steer are sub-second;
# a relaunch or teardown is the longest and still finishes in seconds).
JG_LEASE_COMMAND_LOCK_MAX_AGE_SECS=${JG_LEASE_COMMAND_LOCK_MAX_AGE_SECS:-300}

# jg_lease_command_lock_max_age: echo the validated bound (invalid -> 300).
# Read at call time because this is a sourced library serving many commands in
# one shell.
jg_lease_command_lock_max_age() {
  local age=${JG_LEASE_COMMAND_LOCK_MAX_AGE_SECS:-300}
  case "$age" in '' | *[!0-9]* | 0) age=300 ;; esac
  printf '%s\n' "$age"
}

# jg_lease_command_lock_reclaim <lock> <max-age>: remove <lock> when it is still
# present and at least <max-age> seconds old. The age proof is re-verified while
# holding the lock's steal mutex, the same election jg_lock_try_acquire uses for
# stale-owner reclaim: while it is held no competing acquirer can publish a
# fresh lock (jg_lock_claim_blocked_by_steal), so a reclaimer can never delete a
# newer claim, and a lock younger than the bound is left untouched. Returns 0
# only when an over-age lock was removed.
#
# A lock whose age cannot be read is never reclaimed: an unprovable age keeps
# the ordinary wait rather than risking a live holder.
jg_lease_command_lock_reclaim() {
  local lock=$1 max_age=$2 steal age
  steal="$lock.steal"
  jg_lock_try_acquire_steal_mutex "$steal" || return 1
  if age=$(jg_lock_age "$lock") && [ "$age" -ge "$max_age" ]; then
    jg_lock_remove_path "$lock" || true
    jg_lock_release "$steal"
    return 0
  fi
  jg_lock_release "$steal"
  return 1
}

# jg_lease_command_lock_acquire <lock>: the bounded replacement for a bare
# jg_lock_acquire_wait on the lease-command lock (used by bin/jg-lease.sh and
# jg_lease_guard). The ordinary stale-owner recovery still clears a provably
# dead holder; beyond that the wait is bounded by the lock's age, so an alive
# holder past JG_LEASE_COMMAND_LOCK_MAX_AGE_SECS is reclaimed instead of
# blocking forever. One stuck relaunch can therefore never wedge every relaunch
# and steer in the home.
jg_lease_command_lock_acquire() {
  local lock=$1 max_age
  jg_lease_lock_helpers
  max_age=$(jg_lease_command_lock_max_age)
  while ! jg_lock_try_acquire "$lock"; do
    jg_lease_command_lock_reclaim "$lock" "$max_age" || sleep 0.1
  done
}

# jg_lease_home_runs_host: 0 iff this home runs the supervision host
# (jg_supervision_host_enabled owns the gate).
jg_lease_home_runs_host() {
  if ! command -v jg_supervision_host_enabled >/dev/null 2>&1; then
    # shellcheck source=bin/jg-supervision-engine-lib.sh
    . "$JG_LEASE_LIB_DIR/jg-supervision-engine-lib.sh"
  fi
  jg_supervision_host_enabled "${JG_CONFIG_OVERRIDE:-${JG_HOME:-$STATE/..}/config}"
}

# jg_lease_actor: print the current actor after validating it. Returns 1 (with
# stderr) for an unknown JG_SUPERVISION_ACTOR value.
jg_lease_actor() {
  local actor=${JG_SUPERVISION_ACTOR:-main}
  case "$actor" in
    main|branch) printf '%s\n' "$actor" ;;
    *)
      echo "error: unknown JG_SUPERVISION_ACTOR '$actor' (expected main or branch)" >&2
      return 1
      ;;
  esac
}

# jg_lease_valid_id <id>: 0 iff the task/resource id is safe to embed in a
# state filename.
jg_lease_valid_id() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

jg_lease_path() {
  printf '%s/.lease-%s\n' "$STATE" "$1"
}

# jg_lease_read <task>: read the lease into JG_LEASE_ACTOR/JG_LEASE_PID/
# JG_LEASE_EPOCH. Returns 1 when no lease file exists. A malformed lease
# (unreadable actor or pid) reads as actor "" so callers treat it as stale
# rather than blocking forever on a torn record.
jg_lease_read() {
  local file line
  file=$(jg_lease_path "$1")
  JG_LEASE_ACTOR=
  JG_LEASE_PID=
  JG_LEASE_EPOCH=
  [ -e "$file" ] || return 1
  IFS= read -r line < "$file" 2>/dev/null || line=
  JG_LEASE_ACTOR=$(printf '%s' "$line" | cut -f1)
  JG_LEASE_PID=$(printf '%s' "$line" | cut -f2)
  # shellcheck disable=SC2034 # Consumed by sourcing callers (bin/jg-lease.sh check).
  JG_LEASE_EPOCH=$(printf '%s' "$line" | cut -f3)
  case "$JG_LEASE_ACTOR" in
    main|branch) ;;
    *) JG_LEASE_ACTOR= ;;
  esac
  case "$JG_LEASE_PID" in
    '' | *[!0-9]*) JG_LEASE_PID= ;;
  esac
  return 0
}

# jg_lease_live <task>: 0 iff a well-formed lease exists, its recorded pid is
# alive, and that pid IS the current session-lock holder (the staleness
# contract above). The calling context never enters the verdict.
jg_lease_live() {
  local lock_pid
  jg_lease_read "$1" || return 1
  [ -n "$JG_LEASE_ACTOR" ] || return 1
  [ -n "$JG_LEASE_PID" ] || return 1
  kill -0 "$JG_LEASE_PID" 2>/dev/null || return 1
  lock_pid=$(head -n 1 "$STATE/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|0|1|*[!0-9]*) return 1 ;; esac
  [ "$JG_LEASE_PID" = "$lock_pid" ]
}

# jg_lease_clear_stale <task>: remove the lease file when it exists but is not
# live. Silent; never touches a live lease.
jg_lease_clear_stale() {
  local file
  file=$(jg_lease_path "$1")
  [ -e "$file" ] || return 0
  jg_lease_live "$1" && return 0
  rm -f -- "$file"
}

# jg_lease_guard <task> <action-label>: refuse (exit JG_LEASE_REFUSE_EXIT) when
# a live lease held by the OTHER actor exists for <task>. Once engaged (the
# guard semantics above), a successful guard retains the command lock across
# the caller's mutation; the caller must invoke jg_lease_guard_release from its
# EXIT cleanup. This closes the check/use race with a concurrent claim.
jg_lease_guard() {
  local task=$1 action=$2 actor lock lease_actor
  jg_lease_valid_id "$task" || return 0
  actor=$(jg_lease_actor) || exit "$JG_LEASE_REFUSE_EXIT"
  case "${PI_CODING_AGENT:-}:${JG_SUPERVISION_ACTOR:-}" in
    true:*|*:main|*:branch) ;;
    *)
      [ -e "$(jg_lease_path "$task")" ] || jg_lease_home_runs_host || return 0
      ;;
  esac
  jg_lease_lock_helpers
  lock="$STATE/.jg-lease-command.lock"
  # A caller with more than one guarded phase already excludes claims until
  # its shared cleanup; do not recursively acquire the non-reentrant lock.
  if [ "$JG_LEASE_GUARD_LOCK" != "$lock" ]; then
    jg_lease_command_lock_acquire "$lock"
    JG_LEASE_GUARD_LOCK=$lock
  fi
  if ! jg_lease_live "$task"; then
    jg_lease_clear_stale "$task" || { jg_lease_guard_release; return 1; }
    return 0
  fi
  lease_actor=$JG_LEASE_ACTOR
  if [ "$lease_actor" != "$actor" ]; then
    jg_lease_guard_release
    echo "error: $action refused - task '$task' is leased to the $lease_actor supervision actor (state/.lease-$task), which is handling that task right now; leave the lease alone (never remove or clear it) and retry after that actor releases it, which it does when its handling ends" >&2
    exit "$JG_LEASE_REFUSE_EXIT"
  fi
}

# Release the claim/guard serialization lock retained by jg_lease_guard.
# Idempotent so callers can use it unconditionally from existing EXIT cleanup.
jg_lease_guard_release() {
  local lock=$JG_LEASE_GUARD_LOCK
  [ -n "$lock" ] || return 0
  JG_LEASE_GUARD_LOCK=
  jg_lock_release "$lock"
}

# jg_lease_away_relocated: 0 iff main's standing authority is relocated to the
# branch actor right now - a confirmed, readable, live away record exists in
# $STATE, as bin/jg-afk-contract.sh's own validate and mode subcommands judge
# it (the header's role-partition paragraph). Read fresh on every call, never
# cached, because the record can be archived between two guarded actions.
jg_lease_away_relocated() {
  [ -f "$STATE/.afk-contract" ] || return 1
  JG_STATE_OVERRIDE="$STATE" "$JG_LEASE_LIB_DIR/jg-afk-contract.sh" validate >/dev/null 2>&1 || return 1
  [ "$(JG_STATE_OVERRIDE="$STATE" "$JG_LEASE_LIB_DIR/jg-afk-contract.sh" mode 2>/dev/null)" != quiet ]
}

# jg_lease_forbid_branch <action-label> [--away-relocated]: refuse (exit
# JG_LEASE_REFUSE_EXIT) when the current actor is the supervision branch.
# Guards the main-owned role partition; a home with no branch never sets the
# actor and always passes. With --away-relocated, the branch passes instead
# while jg_lease_away_relocated holds (main is parked under the away-posture
# record), and the calling script's own gate decides what may happen next;
# without the flag the action is never relocated in any posture.
jg_lease_forbid_branch() {
  local action=$1 relocatable=${2:-} actor
  actor=$(jg_lease_actor) || exit "$JG_LEASE_REFUSE_EXIT"
  [ "$actor" = branch ] || return 0
  if [ "$relocatable" = --away-relocated ] && jg_lease_away_relocated; then
    echo "note: $action proceeds for the supervision branch under the away-posture record: main is parked and its standing authority is relocated; this script's own gate still applies (docs/pi-supervision-branch.md \"Postures\")" >&2
    return 0
  fi
  echo "error: $action refused - the supervision branch never performs this action; report the outcome and leave it to main (role partition: docs/pi-supervision-branch.md)" >&2
  exit "$JG_LEASE_REFUSE_EXIT"
}
