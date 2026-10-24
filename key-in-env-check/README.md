# key-in-env-check

Wakes Main when any running fleet process carries a provider API key in its environment. Born from BYOKit finding 13 live `pi` workers holding the OpenRouter key, inherited from a long-lived parent (the herdr server or the no-mistakes daemon).

## What it does

Every run it scans same-user processes under `/proc`, read-only:

- **Names only.** `/proc/<pid>/environ` is split on NUL and only the variable names are kept; a value is never stored, printed, logged or written. The e2e test plants a canary value and greps everything the check wrote.
- **Matches names** against a pattern list: `*_API_KEY`, `*_API_TOKEN`, and `<PROVIDER>_*KEY|TOKEN|SECRET` for OPENROUTER, ANTHROPIC, OPENAI, MINIMAX, GOOGLE, GEMINI, XAI, MOONSHOT, ZAI, DEEPSEEK, MISTRAL, GROQ, COHERE, TOGETHER, FIREWORKS. Override with `FM_KEY_PATTERNS` (comma or space separated globs) or the home's `config/key-in-env-patterns`.
- **Attributes each hit** to a home and task: the process's cwd (or its nearest ancestor's) is matched against every home's `state/*.meta` `worktree=` record (homes: `~/firstmate` and `~/.treehouse/*/*/firstmate`); no match prints `unknown`.
- **Names the parent still exporting it:** the parent chain is walked to the topmost ancestor that holds the same variable.

Output: `state/key-in-env.incidents` (rewritten each run, empty when clean), one TSV line per process: `pid  home  task  variables  topmost-parent(pid)`. One wake line on stdout when the set of hits changes (de-duplicated through `state/.key-in-env.last`; silent when clean or unchanged). The Incidents view can read the file directly.

It never kills, signals or changes anything.

## Install and test

`FM_HOME=<home> key-in-env-check/install.sh [--dry-run]` copies the check to `${XDG_DATA_HOME:-~/.local/share}/fm-key-in-env-check/` and registers `key-in-env-check` as a home watcher check. Remove with `uninstall.sh`. Test: `bash key-in-env-check/tests/key-in-env-check-e2e.sh`.
