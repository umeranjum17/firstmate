#!/usr/bin/env python3
# Applies the step-B replacements to a COPY of a fork bin/: fork definitions removed,
# the source, call and inherit lines added. Usage: stage-step-b.py <bin-dir>
import re, sys
from pathlib import Path
bin_ = Path(sys.argv[1])
def drop(text, name):
    m = re.search(r'^%s\(\) \{.*?^\}\n' % name, text, re.S | re.M)
    assert m, name
    return text[:m.start()] + text[m.end():]
src = '[ ! -r "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/lead-wake/bin/fm-lead-wake-lib.sh" ] || . "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/lead-wake/bin/fm-lead-wake-lib.sh"\n'
p = bin_ / 'fm-wake-lib.sh'
p.write_text(drop(p.read_text(), 'fm_wake_withdraw'))
p = bin_ / 'fm-wake-drain.sh'
t = p.read_text().replace(' \\\n    "$STATE"/.wake-queue.withdraw.*; do', '; do'); p.write_text(t)
p = bin_ / 'fm-watch.sh'
t = p.read_text()
for n in ['lane_target_value', 'open_lane_count', 'warn_invalid_lane_target_once', 'ready_work_waits_idle', 'record_ready_work_surfaced']:
    t = drop(t, n)
t = re.sub(r'^READY_WORK_RESURFACE_SECS=.*\ncase .*\n', '', t, flags=re.M)
t, n = re.subn(r'^  if \[ "\$\(age_of "\$STATE/\.last-ready-work-check"\)".*?\n  fi\n', '  if declare -F lead_wake_tick >/dev/null; then lead_wake_tick; fi\n', t, count=1, flags=re.S | re.M)
assert n == 1
t = t.replace('\nwhile :; do\n', '\n' + src + 'while :; do\n', 1)
p.write_text(t)
p = bin_ / 'fm-config-inherit-lib.sh'
t = p.read_text().replace(' lane-target}"', '}"')
t = re.sub(r'^(FM_INHERITABLE_CONFIG=.*\n)', r'\1[ ! -r "${FM_ADDONS_DIR:-${FM_HOME:-}/projects/firstmate-addons}/lead-wake/bin/fm-lead-wake-inherit.sh" ] || . "${FM_ADDONS_DIR:-${FM_HOME:-}/projects/firstmate-addons}/lead-wake/bin/fm-lead-wake-inherit.sh"\n', t, count=1, flags=re.M)
p.write_text(t)
