# supervisor-guard

The supervisor-work guard — the pre-tool check that stops a supervisor
session from doing a worker's job — moved **verbatim** out of the Firstmate
fork into this add-on repository. Nothing calls it from here yet: the fork's
`bin/fm-supervisor-work-pretool-check.sh` and
`bin/fm-supervisor-work-command-policy.mjs` stay the live guard every home
runs through today, and the fork-side hook that will call into this directory
instead lands in a later PR. Until that swap this directory is dormant, and
every moved byte below is identical to the fork copy the live guard runs
today.

## Layout

- `bin/fm-supervisor-work-pretool-check.sh` — the hook transport: scopes the
  guard to a genuine supervisor home, takes the command from a PreToolUse JSON
  payload on stdin or from `--command`, invokes the policy, and renders the
  deny/allow verdict. It never executes, sources, evaluates, or expands the
  command.
- `bin/fm-supervisor-work-command-policy.mjs` — the single owner of the
  patterns and the block/allow decision.
- `tests/fm-supervisor-work-pretool-check.test.sh` — the fork's behavior test
  for the guard over real fixture homes.
- `docs/supervisor-work-guard.md` — the human-readable contract and
  validation record.

The transport sources `fm-primary-scope-lib.sh` from its own directory and
the policy imports the lexer from the sibling `fm-arm-command-policy.mjs`;
those fork files did not move, so the moved copy only runs with the fork bin
tree beside it (see the proof below).

## Frozen contract (identical to the fork)

- Entry: `bin/fm-supervisor-work-pretool-check.sh --claude`; also accepts
  `--command <cmd>` (CLI transport), `--secondmate` (judge pane typing as a
  secondmate lead), and a PreToolUse JSON payload on stdin when `--command`
  is absent.
- Verdicts: ALLOW is exit 0 with no output. DENY is exit 2 with a deny
  object on stderr —
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[<code>] <reason>"}` —
  plus a `{"decision":"deny","reason":"[<code>] <reason>"}` object on stdout
  unless `--claude` was supplied (with it, stdout stays empty). Outside a
  genuine supervisor home, and on malformed transport or a missing runtime,
  it exits 0 with no output: inert or fail-open, never a block.
- Rules: `supervisor-no-mistakes-run` (a supervisor never drives a
  crew-owned `no-mistakes axi run`/`respond`; `status` stays allowed),
  `supervisor-poll-in-turn` (no sleep over 60 seconds, no unreadable sleep
  duration, no loop whose body sleeps), `supervisor-pane-typing` (no
  `herdr pane send-text`/`send-keys` or `tmux send-keys`, secondmate lead
  only). A linked worker worktree is always allowed.
- Policy module: exports `decision` and `MAX_TURN_SLEEP_SECONDS`; direct CLI
  `--command <cmd> [--secondmate]` prints `allow` or
  `deny<TAB><code><TAB><reason>`.

## Provenance: byte-identical to the fork

Every moved file was compared byte for byte (sha256 plus file mode)
against its fork source at
`umeranjum17/firstmate@0689b4b9d9ab3594f846cfe07c400edfa58244bf` at move
time:

| moved file | fork source | sha256 |
| --- | --- | --- |
| `supervisor-guard/bin/fm-supervisor-work-pretool-check.sh` | `bin/fm-supervisor-work-pretool-check.sh` | `d8dd118470d1f43e5f75b4516d70afbfd186458366145a2f87a7a1625a3e7bf5` |
| `supervisor-guard/bin/fm-supervisor-work-command-policy.mjs` | `bin/fm-supervisor-work-command-policy.mjs` | `cb9f9dff78d518bc2ffec7c1d83637fb0f02db277eb3ac2387e820b5eb18e131` |
| `supervisor-guard/tests/fm-supervisor-work-pretool-check.test.sh` | `tests/fm-supervisor-work-pretool-check.test.sh` | `195b6d27bf1e7bfed0c14076803cc62cadd7ca84a12cd5e5a479985eebc6dae0` |
| `supervisor-guard/docs/supervisor-work-guard.md` | `docs/supervisor-work-guard.md` | `c11d84b9fd566fcb837d4b4497424ba35a44b1146181cd27d10ade6c8498f11d` |

Modes match too: the two `bin/` files and the test are executable, the doc
is not. Treat any future diff against the fork file as a contract change,
not a refactor.

## Side-by-side proof (re-run before the hook swaps the called path)

1. Unpack the fork tree at the commit above into two scratch roots with
   `git archive`; in the second root only, overwrite the four files with
   the moved bytes. `diff -r` of the two roots must be empty, and the
   sha256 table above must still match.
2. Run `tests/fm-supervisor-work-pretool-check.test.sh` in the fork scratch
   root; it must print its PASS lines. The test drives the sibling scope
   library, lexer module, and tracked hook registrations, so it runs in the
   full fork tree, never against this directory alone.
3. Run the repo CI gate (the lint plus syntax check over every add-on
   script) on the PR head.

Timing note: the host is often heavily loaded, so a run can fail on a
timing budget rather than on behavior; record the output and allow at most
three runs in total.
