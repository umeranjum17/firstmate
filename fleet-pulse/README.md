# fleet-pulse
- `install.sh [--dry-run] <home>` installs `chat-tsv.py`; retro refreshes current redacted captain chat with `FM_HOME=<main home> <addons>/fleet-pulse/bin/chat-tsv-refresh.sh`, appending only new rows to private `<main home>/data/chat.tsv`.
- Set `CHAT_TSV_TRANSCRIPTS` to override the Claude projects directory; the refresh refuses to run without `FM_HOME`, and the extractor refuses to write unless Git confirms `data/chat.tsv` is ignored.
- Rows contain UTC ISO-8601 `at`, session-cwd-basename `work` (or `main` for the home checkout/missing cwd), and flattened `text`; metadata, sidechains, tool results, commands, reminders, injected wake text, XML wrappers, mirrors, summaries, and artifact wrappers are filtered while human text outside wrappers is retained.
- Every drop and truncation reason is counted on stderr without message text; secrets/codes are redacted and text is capped at 4000 characters with `[truncated]`.
- The output and sidecar are mode 600, the data directory is mode 700, and `uninstall.sh <home>` removes only the installed script.
## Check
- `bash tests/chat-tsv.test.sh` covers wrapper filtering, mixed human text, audit counts, redaction, truncation, permissions, idempotency, and incremental refresh with disposable fixtures.
- `bash tests/gate-audit.test.sh` covers pass/card ordering, later failure, card-only/missing rows, and number-only matching.
- `bin/gate-audit.sh <checks-gate.log> <pr-url>...` prints each URL with `pass` only when its latest non-card row says pass; otherwise it prints `bypass`.
