#!/usr/bin/env python3
"""Read-only tasks-axi backfill and incremental publication via sign-off-axi ticket."""
import argparse
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
import shutil
import tomllib
import xml.etree.ElementTree as xml

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'fleet-dashboard'))
from task_rows import toon_rows, plain
from lane import progress as lane_progress

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

ICONS = Path(__file__).resolve().parents[1] / 'fleet-dashboard/fm-dashboard/icons'
ALIAS = {'firstmate-fork': 'firstmate', 'main': 'firstmate', 'muxr': 'pockit'}  # the dashboard's own project-to-image names

def icon_problem(image):
    if image.suffix == '.svg':
        try: root = xml.parse(image).getroot()
        except xml.ParseError as error: return f'not valid XML ({error})'
        return None if root.tag in ('svg', '{http://www.w3.org/2000/svg}svg') else 'not an svg root'
    try: r = sp.run(['identify', '-format', '%m %w %h', str(image) + '[0]'], text=True, capture_output=True, timeout=60)
    except FileNotFoundError: return 'ImageMagick identify is not installed'
    kind, _, size = r.stdout.partition(' ')
    return None if r.returncode == 0 and kind in ('PNG', 'JPEG', 'WEBP') and all(int(n) > 0 for n in size.split()) else 'not a readable ' + image.suffix[1:] + ' image'

def register_icon(board, project, registry):
    """Registers the dashboard's local image for a project; returns a skip reason or None."""
    found = sorted(ICONS.glob(ALIAS.get(project.lower(), project.lower()) + '.*'))
    if not found: return 'no local image'
    image = found[0]
    problem = icon_problem(image)
    if problem: return problem
    digest = hashlib.sha256(image.read_bytes()).hexdigest()
    if registry.get(project.lower()) == digest: return None
    target = board.parent / 'icons' / (project.lower() + image.suffix)
    target.parent.mkdir(exist_ok=True)
    shutil.copyfile(image, target)
    try: run(['sign-off-axi', 'project', str(board), '--name', project, '--icon', 'icons/' + target.name])
    except RuntimeError as error: return str(error)[:120]
    registry[project.lower()] = digest
    return None

def ticket_id(home, item):
    return "fm-" + hashlib.sha256(f"{home}/{item}".encode()).hexdigest()[:32]

def sync():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit', action='store_true')
    parser.add_argument('--reconcile', action='store_true', help='read every home without the watcher time budget')
    parser.add_argument('--close', metavar='HOME/ITEM', help='record an authorized cancellation or supersession on the board only')
    parser.add_argument('--reason', choices=['superseded', 'cancelled'])
    options = parser.parse_args()
    if bool(options.close) != bool(options.reason): parser.error('--close and --reason are required together')
    started = time.monotonic()
    home = Path(os.environ['FM_HOME']).resolve()
    board = Path((home / 'config/fleet-board').read_text().strip())
    if not board.is_absolute(): board = home / board
    if options.audit: print(run(['sign-off-axi', 'ticket', str(board), '--json'])); return
    state = home / 'state/tickets-sync'
    state.mkdir(parents=True, exist_ok=True)
    with (state / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        (state / '.tasks.toml').write_text('[markdown]\narchive="unused-archive.md"\n')
        ledger_file = state / ('published-' + hashlib.sha256(str(board).encode()).hexdigest()[:12] + '.json')
        ledger = json.loads(ledger_file.read_text()) if ledger_file.exists() else {}
        pr_file = state / 'prs.json'
        prs = json.loads(pr_file.read_text()) if pr_file.exists() else {}
        closures_file = state / 'closures.json'
        closures = json.loads(closures_file.read_text()) if closures_file.exists() else {}
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
        resume = json.loads(cursor.read_text()) if cursor.exists() and not options.reconcile else {}
        ordered = list(homes.items())
        if resume.get('home') in homes: ordered = ordered[list(homes).index(resume['home']):]
        existing = {t['id']: t for t in json.loads(run(['sign-off-axi', 'ticket', str(board), '--json']))['tickets']}
        changed = gaps = 0
        registry = {p['name'].lower(): p.get('icon', {}).get('sha256') for p in json.loads(run(['sign-off-axi', 'project', str(board), '--json'])).get('projects', [])}
        skip_file = state / 'icons-skipped.json'
        skipped = json.loads(skip_file.read_text()) if skip_file.exists() else {}
        tried = set()
        def save(path, value):
            temp = path.with_suffix('.tmp'); temp.write_text(json.dumps(value)); temp.replace(path)
        def publish(tid, desired):
            nonlocal changed
            digest = hashlib.sha256(json.dumps(desired, sort_keys=True).encode()).hexdigest()
            if ledger.get(tid) == digest: return
            old = existing.get(tid, {})
            if not all((old.get('prs', []) == ([v] if v else []) if k == 'pr' else old.get(k, '') == (v == 'yes' if k in ('hold', 'asked') else v)) for k, v in desired.items()):
                args = ['sign-off-axi', 'ticket', str(board), '--id', tid]
                for key, value in desired.items(): args += ['--' + key, str(value)]
                run(args); changed += 1
            ledger[tid] = digest; save(ledger_file, ledger)
        if options.close:
            name, sep, item = options.close.partition('/')
            if name not in homes or not sep or not item: raise RuntimeError('--close requires a registered HOME/ITEM')

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
            if options.close and name == options.close.partition('/')[0]:
                if options.close.partition('/')[2] not in tasks: raise RuntimeError('--close item not found: ' + options.close)
                closures[options.close] = options.reason
                save(closures_file, closures)
            ids = list(tasks)
            parents = {m[1].strip() for r in tasks.values() if (m := re.search(r'^\s*parent:\s*(.+)$', r.get('body', ''), re.M))}
            if resume.get('home') == name and resume.get('task') in tasks: ids = ids[ids.index(resume['task']):]
            projects = {}
            required = set(resume.get('required', [])) if resume.get('home') == name else set()
            for item in ids:
                r = tasks[item]
                if not options.reconcile and time.monotonic() - started > 20:
                    save(cursor, dict(home=name, task=item, required=list(required)))
                    print(f'tickets-sync: backfill continuing on next watcher check; {changed} changed')
                    return
                tid = ticket_id(name, r['id'])
                if r['state'] == 'done' and r.get('closed', '-') < cutoff and tid not in ledger and tid not in existing and item not in required: continue
                if '\n... (truncated, ' in r['title'] + r.get('body', ''):
                    full = run(reader + ['show', r['id'], '--full'], env) if r not in archived else run(['tasks-axi', 'show', r['id'], '--full', '--file', str(archive_copy)], env, state)
                    for key, value in re.findall(r'^  (title|body): (.*)$', full, re.M): r[key] = json.loads(value) if value.startswith('"') else value
                body = r.get('body', '')
                def field(key):
                    m = re.search(r'^\s*' + key + r':\s*(.+)$', body, re.M | re.I)
                    return m[1].strip() if m else ''
                held = name in parked or r.get('held') == 'yes' or r.get('hold_kind') == 'parked'
                progress, done, pr = lane_progress(source, item, r, prs, run)
                save(pr_file, prs)
                done = done or f'{name}/{item}' in closures or existing.get(tid, {}).get('state') == 'done'
                if done: progress = 100
                label = 'Done' if done else 'On hold' if held else 'To do' if progress == 0 else 'In progress'
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
                if project not in tried:
                    tried.add(project); reason = register_icon(board, project, registry)
                    if reason != skipped.get(project):
                        skipped.pop(project, None) if reason is None else skipped.__setitem__(project, reason)
                        save(skip_file, skipped); print(f'tickets-sync: {project} icon ' + (f'skipped ({reason})' if reason else 'registered'))
                parent = '' if epic else field('parent')
                if parent in tasks and ticket_id(name, parent) not in ledger:
                    required.add(parent); ids.append(parent)
                upkeep = parent == 'upkeep'
                if not epic and (upkeep or parent not in tasks or parent == item):
                    group = 'Upkeep' if upkeep else 'Needs a parent'
                    parent = ':' + group + ':' + project
                    publish(ticket_id(name, parent), dict(title=group + ' · ' + project, progress=0, project=project, hold='yes' if name in parked else 'no', asked='no' if upkeep else 'yes'))
                desired = dict(title=title, progress=progress, state='' if item in parents else 'done' if done else 'on hold' if held else 'queued' if progress == 0 else 'in progress', pr=pr, parent=ticket_id(name, parent) if parent else '', priority=f"P{r['priority']}" if str(r.get('priority')) in ('0', '1', '2', '3') else '', project=project, hold='yes' if held and not done else 'no', asked='no' if upkeep else 'yes')
                publish(tid, desired)
        save(cursor, {})
        if changed: print(f'tickets-sync: {len(homes)} homes read; {changed} tickets changed; {gaps} links exceed the public title limit')

if __name__ == '__main__':
    try: sync()
    except (OSError, ValueError, KeyError, RuntimeError, sp.TimeoutExpired) as error:
        print(f'tickets-sync: {error}', file=sys.stderr)
        sys.exit(1)
