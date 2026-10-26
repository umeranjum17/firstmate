#!/usr/bin/env bash
# jg-jev-mem-guard.sh - host memory guard; usage and contract: bin/jg-jev-mem-guard.py header.
# Without python3 the host is not measurable here, which admits and records nothing.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
. "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v python3 >/dev/null 2>&1 || { printf 'UNKNOWN\thost memory is not measurable here (python3 is not installed)\n'; exit 0; }
exec python3 "$SCRIPT_DIR/jg-jev-mem-guard.py" "$@"
