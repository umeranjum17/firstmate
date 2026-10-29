#!/usr/bin/env python3
"""Decide whether a captured pane's permission prompt may be approved.

Usage: python3 jg-prompt-gate.py <harness> [--dir L=PATH]... [--file L=PATH]... [--state-files L=DIR/ID]... < capture
Prints one tab-separated line:
  none                              no permission dialog is visible
  approve <root> <path> <prompt>    a pending read of <path>, inside the root labelled <root>
  card <reason> <path|-> <prompt>   a dialog this gate will not answer
--dir admits a path at or below PATH, --file exactly PATH, and --state-files any
DIR/ID.<ext> file with one extension (no sibling task, no deeper path).

Only OpenCode's "Access external directory" dialog can approve, verified live on
1.18.25 (.agents/skills/harness-adapters/references/harness/opencode.md). That
dialog is identical for Read, Write and a bash rm, so the call it serves is
read off the screen above it: the one pending tool line must be a Read, and the
whole current turn back to the last finished message footer must hold nothing
but finished reads and thoughts. Every other shape is a card.
OpenCode wraps a long path over several lines and may have dropped a space at
each break, so every reading of each wrap is tried: each reading that exists
must resolve (symlinks and .. followed) inside a root, and the dialog
directory must be the read's own directory. One unprovable step is a card.
"""
import itertools
import os
import re
import sys

PANEL = "┃"
WIDE = 12  # deeper text on a line is OpenCode's sidebar, not dialog content
CREDENTIAL = re.compile(r"^\.env|credential|secret|token|password|^auth\.json$|\.pem$|\.key$|^\.ssh$|^\.gnupg$|^\.netrc$", re.I)


def split(line):
    """(is_panel, indent, text) with the right-hand sidebar column cut off."""
    body = line.rstrip()
    stripped = body.lstrip(" ")
    panel = stripped.startswith(PANEL)
    if panel:
        body = stripped[1:]
    indent = len(body) - len(body.lstrip(" "))
    text = re.split(r"\s{2,}", body.strip())[0] if indent <= WIDE else ""
    return panel, indent, text, body.strip()


def readings(chunks):
    if not chunks or len(chunks) > 6:
        return set()
    out = set()
    for seps in itertools.product(("", " "), repeat=len(chunks) - 1):
        out.add(os.path.expanduser(chunks[0] + "".join(s + c for s, c in zip(seps, chunks[1:]))))
    return out


def opencode(lines, roots):
    rows = [split(line) for line in lines]
    top = max((i for i, r in enumerate(rows) if r[0] and r[2] == "△ Permission required"), default=None)
    if top is None:
        return ("none",)
    prompt = "Permission required"

    def card(reason, path="-"):
        return ("card", reason, path, prompt)

    i = top + 1
    while i < len(rows) and rows[i][0] and not rows[i][2]:
        i += 1
    m = re.match(r"^← Access external directory (\S.*)$", rows[i][2]) if i < len(rows) and rows[i][0] else None
    if not m:
        return card("unrecognized dialog")
    head_indent, chunks = rows[i][1], [m.group(1)]
    i += 1
    while i < len(rows) and rows[i][0] and rows[i][2] and rows[i][1] == head_indent + 2:
        chunks.append(rows[i][2])
        i += 1
    prompt = "Access external directory " + "".join(chunks)
    while i < len(rows) and rows[i][0] and not rows[i][2]:
        i += 1
    if i >= len(rows) or rows[i][2] != "Patterns":
        return card("dialog has no single pattern")
    pat_indent, entries, i = rows[i][1], [], i + 1
    while i < len(rows) and rows[i][0] and not all(w in rows[i][3] for w in ("Allow once", "Allow always", "Reject")):
        panel, indent, text, _ = rows[i]
        if text:
            if indent != pat_indent:
                return card("dialog has an unexpected section")
            if text.startswith("- "):
                entries.append([text[2:]])
            elif entries:
                entries[-1].append(text)
            else:
                return card("dialog has an unexpected section")
        i += 1
    if i >= len(rows) or len(entries) != 1:
        return card("dialog has no single pattern")
    dirs = readings(chunks) & {p[:-2] for p in readings(entries[0]) if p.endswith("/*")}
    if not dirs:
        return card("dialog directory and pattern disagree")

    # The pending call: the newest tool line above the dialog, under the
    # unfinished message footer.
    k = top - 1
    while k >= 0 and not rows[k][2]:
        k -= 1
    if k < 0 or rows[k][0] or not rows[k][2].startswith("▣"):
        return card("pending tool not visible")
    k -= 1
    while k >= 0 and not rows[k][2]:
        k -= 1
    tail = []
    while k >= 0 and not rows[k][0] and rows[k][1] == 7 and rows[k][2]:
        tail.insert(0, rows[k][2])
        k -= 1
    m = re.match(r"^([⠀-⣿]) Read (\S.*)$", rows[k][2]) if k >= 0 and not rows[k][0] and rows[k][1] == 5 else None
    if not m:
        return card("pending call is not a read", rows[k][2] if k >= 0 else "-")
    targets = readings([m.group(2)] + tail)
    shown = min(targets, key=len)
    prompt += " (pending Read " + shown + ")"

    # The rest of this step, up to the footer of the message before it: every
    # call above that footer had finished before this step began.
    for k in range(k - 1, -2, -1):
        if k < 0:
            return card("start of the turn is not visible", shown)
        panel, indent, text, _ = rows[k]
        if not panel and text.startswith("▣"):
            break
        if panel and text.startswith("$ "):
            return card("a shell command ran in this turn", shown)
        tool = None if panel else re.match(r"^([^\w\s]) (\S+)", text)
        if tool and not (tool.groups() == ("→", "Read") or (tool.group(1) == "+" and tool.group(2).startswith("Thought"))):
            return card("another tool call is in this turn", shown)

    existing = [t for t in targets if os.path.exists(t)]
    if not existing:
        return card("read path does not exist", shown)
    labels = set()
    for t in existing:
        own = (t if os.path.isdir(t) else os.path.dirname(t)).rstrip(os.sep) or os.sep
        if own not in dirs:
            return card("dialog directory is not the read's directory", t)
        real = os.path.realpath(t)
        if any(CREDENTIAL.search(part) for part in real.split(os.sep)):
            return card("credential-like path", real)
        label = next((lab for lab, kind, root in roots if inside(real, kind, root)), None)
        if label is None:
            return card("outside this fleet's own roots", real)
        labels.add(label)
    return ("approve", ",".join(sorted(labels)), shown, prompt)


def inside(real, kind, root):
    if kind == "file":
        return real == root
    if kind == "dir":
        return real == root or real.startswith(root.rstrip(os.sep) + os.sep)
    directory, task = os.path.split(root)
    return os.path.dirname(real) == directory and re.fullmatch(re.escape(task) + r"\.[A-Za-z0-9_-]+", os.path.basename(real)) is not None


def parse_roots(args):
    roots = []
    for flag, value in zip(args[::2], args[1::2]):
        kind = {"--dir": "dir", "--file": "file", "--state-files": "state"}.get(flag)
        label, sep, path = value.partition("=")
        if kind is None or not sep or not os.path.isabs(path):
            raise ValueError(f"bad root {flag} {value}")
        if kind == "state":
            path = os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))
        else:
            path = os.path.realpath(path)
        roots.append((label, kind, path))
    if len(args) % 2:
        raise ValueError("odd root arguments")
    return roots


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    roots = parse_roots(argv[2:])
    lines = sys.stdin.read().splitlines()
    verdict = opencode(lines, roots) if argv[1].startswith("opencode") else ("none",)
    print("\t".join(v.replace("\t", " ") for v in verdict))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
