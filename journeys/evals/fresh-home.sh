#!/usr/bin/env bash
# Eval case 6 (deterministic): a fresh home reaches a working fleet from one install.
# done-done journey; run through `done-done run evals-fresh-home`. Real install.sh with real npm,
# in a throwaway HOME, so it needs the network and a minute or two.
# shellcheck source=journeys/evals/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO" || exit 1
scratch_home
JG=$SCRATCH/jg

install_home() { printf '1\n' | bash install.sh --home "$JG"; }
session_start() { JG_HOME=$JG bash bin/jg-session-start.sh | grep -q 'lock acquired'; }
fleet_view() { JG_HOME=$JG bash bin/jg-fleet-view.sh | grep -q '^# Fleet View'; }
written() { for f in config/brief-include.md data/owner-rules.md config/ai-engine.json; do [ -s "$JG/$f" ] || { echo "missing $f"; return 1; }; done; }

check "one install" install_home
check "defaults written" written
check "session start" session_start
check "fleet view" fleet_view
rm_scratch
steps "$(git rev-parse --short HEAD)" "a machine with no Juggernaut home, tools or config" \
  "install.sh wrote the defaults, installed the pinned tools, and the new home starts a session and shows an empty fleet" \
  "Run install.sh once for a new home" \
  "Check the defaults and the AI engine choice landed in the home" \
  "Start a session in the new home" \
  "Open the fleet view of the new home"
