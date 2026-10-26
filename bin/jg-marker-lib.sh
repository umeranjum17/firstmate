#!/usr/bin/env bash
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
. "$(dirname "${BASH_SOURCE[0]}")/jg-compat.sh"
# jg-marker-lib.sh - compatibility entry point for from-firstmate routing.
#
# bin/jg-operational-input.sh owns current operational-input construction,
# parsing, marker bytes, and the established from-firstmate compatibility
# carrier. Existing callers source this path so they do not need a flag-day
# migration. No side effects on source. set -u / set -e safe.

_JG_MARKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-operational-input.sh
. "$_JG_MARKER_LIB_DIR/jg-operational-input.sh"
unset _JG_MARKER_LIB_DIR
