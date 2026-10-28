#!/usr/bin/env bash
# Eval case 6 (deterministic): a fresh home reaches a working fleet from one install.
# done-done journey; run through `done-done run evals-fresh-home`. Real install.sh with real npm,
# in a throwaway HOME, so it needs the network and a minute or two.
# shellcheck source=journeys/evals/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO" || exit 1
scratch_home
JG=$SCRATCH/jg

# A clean machine has no signed-in account, and the installer never holds a login: stopping at that
# named step, after every tool is installed, is the finished install; any other failure is not.
install_home() {
  local rc=0
  printf '1\n' | bash install.sh --home "$JG" > "$OUT/install.out" 2>&1 || rc=$?
  cat "$OUT/install.out"
  [ "$rc" -eq 0 ] || grep -q 'No signed-in BYOKit subscription accounts' "$OUT/install.out"
}
session_start() { JG_HOME=$JG bash bin/jg-session-start.sh | grep -q 'lock acquired'; }
fleet_view() { JG_HOME=$JG bash bin/jg-fleet-view.sh | grep -q '^# Fleet View'; }
written() { for f in config/brief-include.md data/owner-rules.md; do [ -s "$JG/$f" ] || { echo "missing $f"; return 1; }; done; }

check "one install" install_home
check "defaults written" written
check "session start" session_start
check "fleet view" fleet_view
rm_scratch
steps "$(git rev-parse --short HEAD)" "a machine with no Juggernaut home, tools or config" \
  "install.sh wrote the defaults, installed the pinned tools (the account sign-in is the user's), and the new home starts a session and shows an empty fleet" \
  "Run install.sh once for a new home" \
  "Check the defaults landed in the home" \
  "Start a session in the new home" \
  "Open the fleet view of the new home"
