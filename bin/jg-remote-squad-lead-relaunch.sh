#!/usr/bin/env bash
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
. "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh"
# Relaunch a REMOTE secondmate onto a new harness, model, or effort, then
# republish this parent's own route record to match what the host confirmed.
#
# Usage: jg-remote-secondmate-relaunch.sh <id> <harness> <model|default|-> <effort|default|->
#
# bin/jg-remote-secondmate-control.sh's relaunch verb runs entirely on the
# secondmate's own host and can only rewrite that host's own endpoint record;
# this parent's route record (state/<id>.meta here, marked remote_host=... to
# a different machine) is a separate file that verb has no access to. Running
# the relaunch alone therefore leaves this file naming the runtime the mate
# used to run, not the one it runs now.
#
# This wrapper is the missing other half. It runs the host-local relaunch
# through bin/jg-on.sh exactly as secondmate-provisioning documents, then reads
# the confirmed harness, model, and effort back out of the endpoint's own
# route report - the same read-back-from-the-endpoint shape bin/jg-spawn.sh
# already uses when it first records a remote route - and republishes this
# home's own metadata to match. A failed or refused relaunch leaves this
# parent's record untouched.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"

# shellcheck source=bin/jg-backend.sh
. "$SCRIPT_DIR/jg-backend.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ "$#" -eq 4 ] || usage
ID=$1
HARNESS=$2
MODEL=$3
EFFORT=$4
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "no metadata for $ID at $META"
REMOTE_HOST=$(jg_meta_get "$META" remote_host)
[ -n "$REMOTE_HOST" ] \
  || die "task $ID is not a remotely placed secondmate; use bin/jg-control.sh $ID relaunch instead"

# Parked-home guard (firstmate-addons/parked-homes): a parked secondmate home
# gets no relaunch, remote or local. The shim answers not parked when the add-on is absent.
# shellcheck source=bin/jg-parked-homes-lib.sh
. "$SCRIPT_DIR/jg-parked-homes-lib.sh"
jg_parked_refuse_meta "$META" "$ID" relaunch || exit 1

RELAUNCH_OUT=$("$SCRIPT_DIR/jg-on.sh" "$ID" jg-remote-secondmate-control.sh \
  relaunch "$ID" "$HARNESS" "$MODEL" "$EFFORT" </dev/null 2>&1) || {
  rc=$?
  printf '%s\n' "$RELAUNCH_OUT" >&2
  exit "$rc"
}
printf '%s\n' "$RELAUNCH_OUT"

# The confirmed identity comes from the route block the host prints after a
# successful relaunch, never from the human-readable "relaunched ..." summary
# line: a relaunch onto "default" prints that literal word there, while the
# endpoint's own record - and this parent's, to match it - store an empty
# field for "no explicit pin".
[ "$(printf '%s\n' "$RELAUNCH_OUT" | sed -n 's/^schema=//p' | tail -1)" \
  = jg-remote-secondmate-control.v1 ] \
  || die "the host relaunched $ID but reported no route confirmation to record"
NEW_HARNESS=$(printf '%s\n' "$RELAUNCH_OUT" | sed -n 's/^harness=//p' | tail -1)
NEW_MODEL=$(printf '%s\n' "$RELAUNCH_OUT" | sed -n 's/^model=//p' | tail -1)
NEW_EFFORT=$(printf '%s\n' "$RELAUNCH_OUT" | sed -n 's/^effort=//p' | tail -1)
[ -n "$NEW_HARNESS" ] || die "the host's route confirmation carried no harness to record"

META_LOCK=$(jg_meta_lock_path "$META") || die "metadata lock path is invalid for $ID"
jg_lock_acquire_wait "$META_LOCK"
META_TMP=$(mktemp "$STATE/.jg-remote-relaunch-meta.XXXXXX") || {
  jg_lock_release "$META_LOCK"
  die "cannot stage the updated record"
}
{
  printf 'harness=%s\n' "$NEW_HARNESS"
  printf 'model=%s\n' "$NEW_MODEL"
  printf 'effort=%s\n' "$NEW_EFFORT"
} >> "$META_TMP"
# Every other line is preserved in its original relative order after the
# refreshed harness/model/effort. A pr= line's own identity block (pr_head=
# and the rows jg_pr_metadata_identity_parse allows after it) must stay
# LAST in the record: that parser rejects any other key following pr=, so
# writing harness/model/effort after it would break PR movement monitoring on
# a task that already had one armed.
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    harness=*|model=*|effort=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" ;;
  esac
done < "$META"
chmod 0600 "$META_TMP"
mv -f -- "$META_TMP" "$META"
jg_lock_release "$META_LOCK"
