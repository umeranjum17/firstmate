#!/usr/bin/env python3
"""Read-only tasks-axi backfill and incremental publication via sign-off-axi ticket."""
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess as sp
import sys
import time
import tomllib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'fleet-dashboard'))
from task_rows import toon_rows, plain

def run(args, env=None, cwd=None, missing=False):
    r = sp.run(args, env=env, cwd=cwd, text=True, capture_output=True, timeout=60)
    if r.returncode and not (missing and '\ncode: NOT_FOUND\n' in '\n' + r.stdout + r.stderr + '\n'):
        raise RuntimeError(f'{args[0]}: {r.stderr.strip() or r.stdout.strip()}')
    return '{}' if r.returncode else r.stdout

def rows(args, env, cwd=None):
    text = run(args + ['--limit', '100000', '--fields', 'held,hold_kind,closed,priority,body,links'], env, cwd)
    result = toon_rows(text)
    if result is None or re.search(r'count: \d+ of (?!0\b)\d+ total', text) and len(result) >= 100000:
        raise RuntimeError('tasks-axi returned an unreadable or capped task list')
    return result

def ticket_id(home, item):
    return "fm-" + hashlib.sha256(f"{home}/{item}".encode()).hexdigest()[:32]

def sync():
    started = time.monotonic()
    home = Path(os.environ['FM_HOME']).resolve()
    board = Path((home / 'config/fleet-board').read_text().strip())
    if not board.is_absolute(): board = home / board
    if sys.argv[1:] == ['--audit']: print(run(['sign-off-axi', 'ticket', str(board), '--json'])); return
    state = home / 'state/tickets-sync'
    state.mkdir(parents=True, exist_ok=True)
    with (state / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        (state / '.tasks.toml').write_text('[markdown]\narchive="unused-archive.md"\n')
        ledger_file = state / ('published-' + hashlib.sha256(str(board).encode()).hexdigest()[:12] + '.json')
        ledger = json.loads(ledger_file.read_text()) if ledger_file.exists() else {}
        homes = {'main': home}
        registry = home / 'data/secondmates.md'
        for line in registry.read_text().splitlines() if registry.exists() else []:
            m = re.match(r'- (\S+) - .*\(home: ([^;]+);', line)
            if m: homes[m[1]] = Path(m[2])
            elif re.match(r'- \S+ - .*\(host:', line): raise RuntimeError('remote home requires a tasks-axi reader: ' + line.split(' - ')[1])
        parked_file = home / 'config/parked-homes'
        parked = {l.split('#')[0].strip() for l in parked_file.read_text().splitlines()} if parked_file.exists() else set()
        cutoff = (dt.date.today() - dt.timedelta(days=7)).isoformat()
        cursor = state / 'cursor.json'
        resume = json.loads(cursor.read_text()) if cursor.exists() else {}
        ordered = list(homes.items())
        if resume.get('home') in homes: ordered = ordered[list(homes).index(resume['home']):]
        changed = gaps = 0
        def save(path, value):
            temp = path.with_suffix('.tmp'); temp.write_text(json.dumps(value)); temp.replace(path)
        def publish(tid, desired):
            nonlocal changed
            digest = hashlib.sha256(json.dumps(desired, sort_keys=True).encode()).hexdigest()
            if ledger.get(tid) == digest: return
            old = json.loads(run(['sign-off-axi', 'ticket', str(board), '--id', tid, '--json'], missing=True)).get('ticket', {}) if tid not in ledger else {}
            if not all(old.get(k, '') == (v == 'yes' if k in ('hold', 'asked') else v) for k, v in desired.items()):
                args = ['sign-off-axi', 'ticket', str(board), '--id', tid]
                for key, value in desired.items(): args += ['--' + key, str(value)]
                run(args); changed += 1
            ledger[tid] = digest; save(ledger_file, ledger)
        for name, source in ordered:
            env = {k: v for k, v in os.environ.items() if k not in ('FM_DATA_OVERRIDE', 'FM_ROOT_OVERRIDE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND')}
            env['FM_HOME'] = str(source)
            reader = ['bash', str(home / 'bin/fm-tasks-axi.sh')]
            tasks = rows(reader + ['list'], env) + rows(reader + ['list', '--state', 'done'], env)
            address = run(['bash', '-c', '. "$1/fm-tasks-axi-lib.sh"; . "$1/fm-backlog-transition-lib.sh"; fm_backlog_tasks_axi_addressing "$FM_HOME/data" || exit; printf "%s\\n%s\\n" "$FM_BACKLOG_AXI_ROOT" "$FM_BACKLOG_AXI_FILE"', 'tickets-sync', str(home / 'bin')], env).splitlines()
            root, file = address
            if not file: raise RuntimeError(f'{name}: archive backfill requires markdown addressing')
            settings = {}
            for config in (Path.home() / '.tasks-axi/config.toml', Path(root) / '.tasks.toml'):
                if config.exists(): settings.update(tomllib.loads(config.read_text()).get('markdown', {}))
            archive = Path(root) / settings.get('archive', str(Path(file).parent / 'done-archive.md'))
            archive_copy = state / f'{name}-archive.md'
            if archive.exists():
                archive_copy.write_text(re.sub(r'^## Archived[^\n]*$', '## Done', archive.read_text(), flags=re.M))
            archived = rows(['tasks-axi', 'list', '--state', 'done', '--backend', 'markdown', '--file', str(archive_copy)], env, state) if archive.exists() else []
            tasks = {r['id']: r for r in archived + tasks}
            ids = list(tasks)
            if resume.get('home') == name and resume.get('task') in tasks: ids = ids[ids.index(resume['task']):]
            projects = {}
            required = set(resume.get('required', [])) if resume.get('home') == name else set()
            for item in ids:
                r = tasks[item]
                if time.monotonic() - started > 20:
                    save(cursor, dict(home=name, task=item, required=list(required)))
                    print(f'tickets-sync: backfill continuing on next watcher check; {changed} changed')
                    return
                tid = ticket_id(name, r['id'])
                if r['state'] == 'done' and r.get('closed', '-') < cutoff and tid not in ledger and item not in required: continue
                if '\n... (truncated, ' in r['title'] + r.get('body', ''):
                    full = run(reader + ['show', r['id'], '--full'], env) if r not in archived else run(['tasks-axi', 'show', r['id'], '--full', '--file', str(archive_copy)], env, state)
                    for key, value in re.findall(r'^  (title|body): (.*)$', full, re.M): r[key] = json.loads(value) if value.startswith('"') else value
                body = r.get('body', '')
                def field(key):
                    m = re.search(r'^\s*' + key + r':\s*(.+)$', body, re.M | re.I)
                    return m[1].strip() if m else ''
                held = name in parked or r.get('held') == 'yes' or r.get('hold_kind') == 'parked'
                done = r['state'] == 'done'
                progress = 100 if done else 0 if held or r['state'] == 'queued' else 17
                label = 'Done' if done else 'On hold' if held else 'To do' if r['state'] == 'queued' else 'In progress'
                links = re.findall(r'https?://[^\s,\]\)]+', r.get('links', '') + '\n' + r['title'] + '\n' + body)
                size = lambda text: len(text.encode('utf-16-le')) // 2
                epic = '[captain-ask]' in r['title']
                detail = (['Epic'] if epic else []) + [label, (field('release') or 'later')[:64]]
                links = list(dict.fromkeys(links))
                while links and size(' · '.join(detail + links)) > 115:
                    links.pop(); gaps += 1
                suffix = ' · ' + ' · '.join(detail + links)
                title = plain(re.sub(r'https?://\S+', '', r['title']).strip())
                room = 160 - size(suffix)
                title = (title.encode('utf-16-le')[:2*(room-1)].decode('utf-16-le', errors='ignore').rstrip() + '…' if size(title) > room else title) + suffix
                repo = r.get('repo') if r.get('repo') not in ('-', 'none', '') else name
                if repo not in projects:
                    clone = source / 'projects' / repo
                    origin = run(['git', '-C', str(clone), 'remote', 'get-url', 'origin']).strip() if (clone / '.git').exists() else repo
                    projects[repo] = origin.rstrip('/').split('/')[-1].removesuffix('.git')
                project = projects[repo]
                parent = '' if epic else field('parent')
                if parent in tasks and ticket_id(name, parent) not in ledger:
                    required.add(parent); ids.append(parent)
                upkeep = parent == 'upkeep'
                if not epic and (upkeep or parent not in tasks or parent == item):
                    group = 'Upkeep' if upkeep else 'Needs a parent'
                    parent = ':' + group + ':' + project
                    publish(ticket_id(name, parent), dict(title=group + ' · ' + project, progress=0, project=project, hold='yes' if name in parked else 'no', asked='no' if upkeep else 'yes'))
                desired = dict(title=title, progress=progress, parent=ticket_id(name, parent) if parent else '', priority=f"P{r['priority']}" if str(r.get('priority')) in ('0', '1', '2', '3') else '', project=project, hold='yes' if held and not done else 'no', asked='no' if upkeep else 'yes')
                publish(tid, desired)
        save(cursor, {})
        if changed: print(f'tickets-sync: {len(homes)} homes read; {changed} tickets changed; {gaps} links exceed the public title limit')

if __name__ == '__main__':
    try: sync()
    except (OSError, ValueError, KeyError, RuntimeError, sp.TimeoutExpired) as error:
        print(f'tickets-sync: {error}', file=sys.stderr)
        sys.exit(1)
