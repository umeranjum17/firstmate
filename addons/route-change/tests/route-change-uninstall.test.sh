#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home"; E=(env HOME="$T/home" XDG_DATA_HOME="$T/data")
"${E[@]}" "$A/install.sh" >/dev/null; printf keep > "$T/home/fixture/users/user-004/bin/other"; "${E[@]}" "$A/uninstall.sh" >/dev/null
[ ! -e "$T/data/fm-route-change/route-change" ] && [ ! -L "$T/home/fixture/users/user-004/bin/route-change" ] && [ "$(cat "$T/home/fixture/users/user-004/bin/other")" = keep ]; before=$(sha256sum "$T/home/fixture/users/user-004/bin/other"); "${E[@]}" "$A/uninstall.sh" >/dev/null; [ "$before" = "$(sha256sum "$T/home/fixture/users/user-004/bin/other")" ]; echo 'PASS route-change uninstall'
