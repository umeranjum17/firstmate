#!/usr/bin/env bash
# Second half of the real supervision-host integration suite, on its own CI runner.
FM_SUPERVISION_HOST_PART=late exec bash "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host.test.sh"
