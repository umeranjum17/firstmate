#!/usr/bin/env bash
set -euo pipefail
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
home=$d/home transcripts=$d/transcripts
mkdir -p "$home/data" "$transcripts"
git -C "$home" init -q
printf 'data/\n' > "$home/.gitignore"
python3 - "$transcripts/session.jsonl" <<'PY'
import json, sys
from pathlib import Path
rows = [
    ('human-1', 'Please fix this, Umer. PIN=123456 token=sk-FAKEFAKEFAKE123456'),
    ('system-1', 'System: Firstmate instruction waiting'),
    ('mirror-1', 'MAIN DIALOG MIRROR\nInjected dialog history'),
    ('mixed-1', 'This typed note stays.\nMAIN DIALOG MIRROR\nInjected context'),
    ('summary-1', 'Summarized conversation: injected recap'),
    ('artifact-1', '<artifact-content-authored-by-others/>\nSummarized conversation: wrapped recap'),
    ('block-1', 'Keep this sentence. <system-reminder>injected reminder</system-reminder> <pasted_content>injected pasted text</pasted_content> keep this too.'),
    ('command-1', '<command-name>local command</command-name><local-command-stdout>output</local-command-stdout>'),
    ('slash-1', '/local-command output'),
    ('wake-1', 'FIRSTMATE SUPERVISION WAKE: injected context'),
    ('inbox-1', 'Firstmate operational inbox message: injected context'),
    ('waiting-1', 'Firstmate instruction waiting: injected context'),
    ('stop-hook-1', 'Stop hook: injected wake'),
    ('watcher-wake-1', 'Watcher wake: injected context'),
    ('mixed-wake-1', 'This typed note stays. FIRSTMATE SUPERVISION WAKE: injected context'),
    ('punctuation-1', ' : '),
    ('task-wrapper-1', '<task-notification> <task-id>task-123</task-id> background event'),
    ('bash-wrapper-1', '<bash-output>injected command result'),
    ('user-prompt-1', '<user-prompt>injected prompt</user-prompt> Human text outside wrapper.'),
    ('self-closing-1', '<task-event/> Human text after self-closing wrapper.'),
    ('tool-1', [{'type': 'tool_result', 'content': 'tool output'}]),
    ('long-1', 'hello world ' * 500),
]
with Path(sys.argv[1]).open('w') as f:
    for i, (uid, content) in enumerate(rows):
        msg = {'role': 'user', 'content': content}
        f.write(json.dumps({'type': 'user', 'uuid': uid, 'timestamp': f'2026-10-20T12:{i:02}:00Z', 'cwd': '/home/you/firstmate', 'message': msg}) + '\n')
PY
export FM_HOME=$home CHAT_TSV_TRANSCRIPTS=$transcripts
extractor=$(dirname "${BASH_SOURCE[0]}")/../bin/chat-tsv.py
python3 "$extractor" 2026-10-19 2026-10-21 > "$d/out" 2> "$d/audit" || { cat "$d/audit" >&2; exit 1; }
[ "$(wc -l < "$home/data/chat.tsv")" -eq 7 ]
[ "$(stat -c '%a' "$home/data/chat.tsv")" = 600 ]
if grep -Eq '123456|sk-FAKEFAKEFAKE123456' "$home/data/chat.tsv" "$home/data/chat.tsv.seen"; then exit 1; fi
python3 - "$home/data/chat.tsv" "$home/data/chat.tsv.seen" "$d/audit" <<'PY'
import sys
from pathlib import Path
rows = [line.split('\t') for line in Path(sys.argv[1]).read_text().splitlines()]
sidecar = Path(sys.argv[2]).read_text()
audit = Path(sys.argv[3]).read_text()
assert any('Please fix this, Umer.' in row[2] for row in rows)
assert sum('This typed note stays.' in row[2] for row in rows) == 2
assert any('Keep this sentence.' in row[2] and 'keep this too.' in row[2] for row in rows)
assert any(row[2] == 'Human text outside wrapper.' for row in rows)
assert any(row[2] == 'Human text after self-closing wrapper.' for row in rows)
assert all(len(row[2]) <= 4000 for row in rows)
assert any(row[2].endswith('[truncated]') for row in rows)
assert not any(token in '\n'.join(row[2] for row in rows) for token in ('MAIN DIALOG MIRROR', 'Summarized conversation', 'artifact-content', 'injected reminder', 'injected pasted text', 'local-command', 'SUPERVISION WAKE', 'operational inbox message', 'instruction waiting', 'Stop hook', 'Watcher wake', 'task-id', 'bash-output', 'user-prompt', 'injected prompt'))
assert not any(secret in sidecar for secret in ('123456', 'sk-FAKEFAKEFAKE123456'))
for reason in ('main_dialog_mirror=2', 'compaction_summary=2', 'artifact_content=1', 'xml_command-name=1', 'xml_local-command-stdout=1', 'injected_system-reminder=1', 'injected_pasted_content=1', 'slash_command=1', 'supervision_wake=2', 'operational_inbox=1', 'instruction_waiting=2', 'stop_hook_wake=1', 'watcher_wake=1', 'punctuation_only=1', 'xml_task-notification=1', 'xml_bash-output=1', 'xml_user-prompt=1', 'xml_task-event=1', 'tool_content=1', 'truncated=1'):
    assert reason in audit, reason
PY
python3 "$extractor" 2026-10-19 2026-10-21 > "$d/out2" 2> "$d/audit2"
[ "$(wc -l < "$home/data/chat.tsv")" -eq 7 ]
grep -Fq 'appended=0' "$d/audit2"
echo 'PASS: wrappers filtered, mixed human text retained, audit counts emitted, secrets redacted, text capped, rerun idempotent'
