#!/usr/bin/env bash
# End to end: install into a throwaway HOME, load the installed OpenCode plugin and run bash calls through it in a lead
# home and a plain home. Nothing real is touched and no command is executed.
set -euo pipefail; unset JG_HOME
ADDON=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/.config/opencode" "$T/lead" "$T/plain"; printf 'lead\n' > "$T/lead/.jg-squad-lead-home"
env HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" "$ADDON/install.sh" >/dev/null
[ "$(env HOME="$T/home" XDG_DATA_HOME="$T/home/.local/share" "$ADDON/install.sh" | grep -c '^unchanged: ')" -eq 2 ] || { echo "FAIL: reinstall not idempotent"; exit 1; }
cat > "$T/run.mjs" <<'JS'
const [file, dir, command] = process.argv.slice(2);
const hooks = await (await import(file)).JgLeadSleepGuard({ directory: dir });
try { await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command } }); console.log("allowed"); }
catch (e) { console.log(e.message); }
JS
P=$T/home/.config/opencode/plugins/jg-lead-sleep-guard.js; fail=0
run() { node "$T/run.mjs" "$P" "$1" "$2"; }
for c in 'sleep 30' 'while ! test -e x; do sleep 5; done' 'until grep -q done f; do sleep 1; done' 'cd /tmp && sleep 2' 'watch -n 5 ls'; do
  [[ "$(run "$T/lead" "$c")" == *"End your turn"* ]] && echo "ok: lead refuses: $c" || { echo "FAIL: lead allowed: $c"; fail=1; }
  [[ "$(run "$T/plain" "$c")" == allowed ]] && echo "ok: plain home allows: $c" || { echo "FAIL: plain home refused: $c"; fail=1; }
done
for c in 'echo sleep' 'git log --oneline' 'cat sleeper.txt'; do
  [[ "$(run "$T/lead" "$c")" == allowed ]] && echo "ok: lead allows: $c" || { echo "FAIL: lead refused: $c"; fail=1; }
done
exit "$fail"
