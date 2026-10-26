#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/bin" "$T/home/state" "$T/data"
printf '#!/bin/sh\nexit 0\n' > "$T/home/bin/jg-check-register.sh"
cat > "$T/home/bin/jg-check-unregister.sh" <<'UNREGISTER'
#!/bin/sh
rm -f "$FM_HOME/state/$1.check.sh" "$FM_HOME/state/$1.check-trust"
UNREGISTER
chmod +x "$T/home/bin/"jg-check-*.sh; touch "$T/home/state/merge-on-green.check-trust"
E=(env HOME="$T/user" XDG_DATA_HOME="$T/data")
"${E[@]}" "$A/install.sh" "$T/home" >/dev/null; "${E[@]}" "$A/uninstall.sh" "$T/home" >/dev/null
[ ! -e "$T/data/jg-merge-on-green/merge-on-green.sh" ] && [ ! -e "$T/data/jg-merge-on-green/checks-lint.sh" ] && [ ! -e "$T/data/jg-merge-on-green/jg-checks-lint.sh" ] && [ ! -e "$T/data/jg-merge-on-green/.done-done.yaml" ] && [ ! -e "$T/home/state/merge-on-green.check.sh" ] && [ ! -e "$T/home/state/merge-on-green.check-trust" ]; "${E[@]}" "$A/uninstall.sh" "$T/home" >/dev/null; echo 'PASS merge-on-green uninstall'
