#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home"; E=(env HOME="$T/home" XDG_DATA_HOME="$T/data"); printf unrelated > "$T/keep"
"${E[@]}" "$A/install.sh" >/dev/null; "${E[@]}" "$A/uninstall.sh" >/dev/null; [ ! -e "$T/data/fm-host-memory/fm-mem-gate.sh" ] && [ "$(cat "$T/keep")" = unrelated ]; before=$(sha256sum "$T/keep"); "${E[@]}" "$A/uninstall.sh" >/dev/null; [ "$before" = "$(sha256sum "$T/keep")" ]; echo 'PASS host-memory uninstall'
