#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/fixture/users/user-001" "$T/home/fixture/users/user-007/agent" "$T/fm/bin" "$T/fm/state"
printf '#!/bin/sh\nexit 0\n' > "$T/fm/bin/fm-check-register.sh"; chmod +x "$T/fm/bin/fm-check-register.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/fm/bin/fm-check-unregister.sh"; chmod +x "$T/fm/bin/fm-check-unregister.sh"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other-hook"}]}]}}' > "$T/home/fixture/users/user-001/settings.json"
E=(env HOME="$T/home" XDG_DATA_HOME="$T/data" XDG_CONFIG_HOME="$T/home/fixture/users/user-003")
"${E[@]}" "$A/install.sh" "$T/fm" >/dev/null
"${E[@]}" "$A/uninstall.sh" "$T/fm" >/dev/null
jq -e '[.hooks.PreToolUse[].hooks[].command] == ["other-hook"]' "$T/home/fixture/users/user-001/settings.json" >/dev/null
[ ! -e "$T/data/fm-delete-guard/guard.mjs" ] && [ ! -e "$T/home/fixture/users/user-007/agent/extensions/fm-rm-guard.ts" ]
before=$(sha256sum "$T/home/fixture/users/user-001/settings.json"); "${E[@]}" "$A/uninstall.sh" "$T/fm" >/dev/null; [ "$before" = "$(sha256sum "$T/home/fixture/users/user-001/settings.json")" ]
echo PASS
