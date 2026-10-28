"""The daily ticket clean-up: flag what needs a keep/remove call and keep every captain quote."""
import datetime as dt
import os
import re
from pathlib import Path
from hierarchy import field, title as request_title

STALE_DAYS = 14


def captain_origin(row):
    return '[captain-ask]' in row['title'] or bool(re.search(r'type:\s*captain-ask', row.get('body', ''), re.I))


def quote(row):
    """(words, date, source) a captain ticket carries; any part may be ''."""
    return request_title(row, True) if captain_origin(row) and re.search(r'["“]', row.get('body', '')) else '', field(row, 'quoted-at'), field(row, 'source')


def find_source(words, home):
    """(date, path) of the steer record that holds the captain's words, else None."""
    for msg in sorted(Path(home, 'state').glob('*.inbox/**/*.msg')):
        text = msg.read_text(errors='replace')
        if words in text:
            at = re.search(r'^at=(\d{4}-\d{2}-\d{2})', text, re.M)
            return (at[1] if at else ''), str(msg)
    return None


def raise_ask_card(it, words, board, run):
    """Raise the ask card the board's Asked block quotes: title is his words cut to sign-off's 12-word cap, body is the full quote. True when raised; the same key twice is a no-op, so a rerun adds no card."""
    key = f"ask-{it['tid']}"
    try:
        run(['sign-off-axi', 'raise', str(board), '--key', key, '--ask-ref', key, '--ticket', it['tid'],
             '--title', ' '.join(words.split()[:12]).rstrip('.,;:!?') + '?',
             '--about', f'The captain said: "{words}"',
             '--why', 'The captain asked for this and no ask card carried his words.',
             '--outcome', 'yes=Main keeps working on it.', '--outcome', 'no=Main closes the ticket.',
             '--recommend', 'yes', '--recommend-reason', 'He asked for it.', '--default', 'yes'])
    except (RuntimeError, OSError): return False
    return True


def findings(items, today):
    """items: dicts of name, row, event (epoch or None), parked. Returns (kind, label, detail) tuples, one per ticket."""
    out, seen, listed = [], {}, set()
    parked = {}
    for it in items:
        row, label = it['row'], f"{it['name']}/{it['row']['id']}"
        if row['state'] == 'done' or label in listed: continue
        listed.add(label)
        body = row.get('body', '')
        if it['parked']: parked[it['name']] = parked.get(it['name'], 0) + 1
        if re.search(r'^\s*(status:\s*superseded|superseded-by:)', body, re.M | re.I):
            out.append(('superseded', label, 'still open'))
        key = (it['name'], re.sub(r'\W+', ' ', request_title(row).lower()).strip())
        if key in seen:
            out.append(('duplicate', label, f'same title as {seen[key]}; the kept ticket must carry both quotes'))
        seen.setdefault(key, label)
        if row.get('held') == 'yes' and not re.search(r'^\s*(until|trigger|resume):\s*\S', body, re.M | re.I):
            out.append(('undated-hold', label, 'held with no date or trigger'))
        age = it['event'] and (today - dt.datetime.fromtimestamp(it['event'], dt.timezone.utc).date()).days
        if str(row.get('priority')) in ('0', '1') and age and age > STALE_DAYS:
            out.append(('stale', label, f'P{row["priority"]}, quiet for {age} days'))
    out += [('parked', name, f'{n} open tickets in a parked project') for name, n in parked.items()]
    return out


def daily(items, today, state, board, home, run, carded, cards=None):
    """Once a UTC day (carded: ids of tickets an ask card names): back-fill missing quote parts, raise one keep/remove card, return the one board line."""
    day = state / 'cleanup.day'
    if day.exists() and day.read_text() == today.isoformat(): return None
    found, filled = [], 0
    for it in items:
        row = it['row']
        if row['state'] == 'done' or not captain_origin(row): continue
        label, (words, at, src) = f"{it['name']}/{row['id']}", quote(row)
        if it['tid'] not in carded and words and raise_ask_card(it, words, board, run): carded = carded | {it['tid']}
        if it['tid'] not in carded: found.append(('no-ask-card', label, 'no ask card names this ticket, so the board open view shows none of his words'))
        if not words: found.append(('no-quote', label, 'captain ticket carries no quoted words')); continue
        if at and src: continue
        hit = find_source(words, it['source'])
        if not hit: found.append(('no-source', label, 'quote has no dated source link and no steer record holds it')); continue
        add = ('' if at else f'\nquoted-at: {hit[0]}') + ('' if src else f'\nsource: {hit[1]}')
        run(['bash', str(home / 'bin/jg-tasks-axi.sh'), 'update', row['id'], '--body', row.get('body', '') + add], {**os.environ, 'JG_HOME': str(it['source'])})
        filled += 1
    found += findings(items, today)
    kinds = {}
    for kind, *_ in found: kinds[kind] = kinds.get(kind, 0) + 1
    summary = ', '.join(f'{n} {k}' for k, n in sorted(kinds.items())) or 'none'
    card = ''
    if found:
        card = f'ticket-cleanup-{today.isoformat()}'
        run(['sign-off-axi', 'raise', str(board), '--key', card, '--ask-ref', card, '--title', f'Keep or remove {len(found)} flagged tickets?',
             '--why', f'The daily clean-up flagged tickets: {summary}. Every captain quote stays on the survivor.'[:200],
             '--detail', '\n'.join(f'{k}: {l} - {d}' for k, l, d in found),
             '--option', 'keep=Keep them', '--option', 'remove=Remove them',
             '--outcome', 'keep=They stay as they are and show again tomorrow only if still flagged.',
             '--outcome', 'remove=Main closes the flagged tickets on the board and keeps their quotes.',
             '--recommend', 'keep', '--recommend-reason', 'Nothing is lost if they stay.', '--default', 'keep'])
    day.write_text(today.isoformat())
    return f'tickets-cleanup: flagged {summary}; {filled} quotes back-filled' + (f'; card {card}' if card else '') + (cards() if cards else '')
