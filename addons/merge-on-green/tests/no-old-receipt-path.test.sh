#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
# Exercise the lint caller with an executable receipt publisher fixture.
bash "$ROOT/merge-on-green/tests/checks-lint-parity.test.sh"
