#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/fixture/users/user-009" "$T/home/fixture/users/user-017"
printf '#!/bin/sh\nexit 0\n' > "$T/home/fixture/users/user-009/fm-check-register.sh"
cat > "$T/home/fixture/users/user-009/fm-check-unregister.sh" <<'UNREGISTER'
#!/bin/sh
rm -f "$FM_HOME/state/$1.check.sh" "$FM_HOME/state/$1.check-trust"
UNREGISTER
chmod +x "$T/home/fixture/users/user-009/"fm-check-*.sh; printf unrelated > "$T/home/fixture/users/user-017/other"; touch "$T/home/fixture/users/user-017/claude-quota.check-trust"
E=(env HOME="$T/user" XDG_DATA_HOME="$T/data"); "${E[@]}" "$A/install.sh" "$T/home" >/dev/null; "${E[@]}" "$A/uninstall.sh" "$T/home" >/dev/null
[ ! -e "$T/home/fixture/users/user-017/claude-quota.check.sh" ] && [ ! -e "$T/home/fixture/users/user-017/claude-quota.check-trust" ] && [ ! -e "$T/data/fm-claude-quota/claude-quota.check.sh" ] && [ "$(cat "$T/home/fixture/users/user-017/other")" = unrelated ]; "${E[@]}" "$A/uninstall.sh" "$T/home" >/dev/null; echo 'PASS claude-quota uninstall'
