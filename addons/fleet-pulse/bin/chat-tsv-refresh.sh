#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  eval "[ -n \"\${$_jg_new+set}\" ]" && continue
  eval "_jg_val=\${_jg_old}"
  export "$_jg_new=$_jg_val"
done
unset _jg_old _jg_new _jg_val 2>/dev/null || true
set -euo pipefail

if [[ -z ${JG_HOME:-} ]]; then
    echo 'chat-tsv-refresh: JG_HOME must be set to the main Firstmate home' >&2
    exit 1
fi
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
transcripts=${CHAT_TSV_TRANSCRIPTS:-$HOME/.claude/projects/-home-umer-firstmate}
if [[ ! -d $transcripts || ! -r $transcripts ]]; then
    echo "chat-tsv-refresh: transcripts directory is missing or unreadable: $transcripts" >&2
    exit 1
fi
result=$(python3 "$script_dir/chat-tsv.py" 2>&1) || {
    echo "chat-tsv-refresh: $result" >&2
    exit 1
}
appended=$(sed -n 's/^appended=\([0-9][0-9]*\).*/\1/p' <<<"$result")
if [[ ! $appended =~ ^[0-9]+$ ]]; then
    echo 'chat-tsv-refresh: extractor did not report an append count' >&2
    exit 1
fi
total=$(wc -l < "$JG_HOME/data/chat.tsv")
printf 'appended=%s rows total=%s\n' "$appended" "$total"
