# fleet-pulse
- `install.sh [--dry-run] <home>` installs `chat-tsv.py`; schedule it periodically with `FM_HOME=<home>` to append redacted captain chat to private `<home>/data/chat.tsv`.
- Set `CHAT_TSV_TRANSCRIPTS` to override the Claude projects directory; the extractor refuses to write unless Git confirms `data/chat.tsv` is ignored.
- Rows contain UTC ISO-8601 `at`, session-cwd-basename `work` (or `main` for the home checkout/missing cwd), and flattened `text`; metadata, sidechains, tool results, commands, reminders, injected wake text, XML wrappers, mirrors, summaries, and artifact wrappers are filtered while human text outside wrappers is retained.
- Every drop and truncation reason is counted on stderr without message text; secrets/codes are redacted and text is capped at 4000 characters with `[truncated]`.
- The output and sidecar are mode 600, the data directory is mode 700, and `uninstall.sh <home>` removes only the installed script.
## Check
- `bash tests/chat-tsv.test.sh` covers wrapper filtering, mixed human text, audit counts, redaction, truncation, permissions, and idempotency with disposable fixtures.
