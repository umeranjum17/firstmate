#!/usr/bin/env bash
# fm-dashboard.sh - build the read-only fleet dashboard pages for this home.
#
# Builds three self-contained HTML pages (inline CSS, no script, no network
# reference), phone first, each answering one question set:
#   index    Overview: Main's ask list only, then slow spots, lanes,
#            devices and machine, and one row per home
#   backlog  queued, ready and held work per home, held-for-captain items, every lane, agents
#   measure  how each number is measured: cycles, windows, records that disagree, unknowns
# Every number names its window and the time its source was read. Every list is
# grouped, by default by what to act on first; index and backlog also build a
# by-home variant. Parked homes are left out of every total, with one line saying so.
#
# Sources, all read-only and all optional (a failed source shows "unknown" and why):
#   data/captain-asks.tsv           Waiting on you: Main's fleet-wide headerless
#                                   id<TAB>since-epoch<TAB>text<TAB>url; each row with an id and
#                                   text is an ask (a bad time or duplicate id shows as a record
#                                   needing correction); blank rows and rows without an id or text
#                                   are skipped, with a note; absent/empty means zero
#   FM_BEARINGS_SECONDMATES=500 FM_BEARINGS_UNHEALTHY=500 FM_SNAPSHOT_SECONDMATES=500
#                                   bin/fm-bearings-snapshot.sh --json: lead state and unhealthy
#                                   endpoints (the FM_SNAPSHOT_* bound raises the fleet snapshot's
#                                   own registry cap from 20 to 500, which otherwise omits mates past 20 upstream)
#   data/secondmates.md             registered homes: "- <name> - ... (home: <dir>; ...)"
#   config/parked-homes             home ids the captain parked, one per line (# comments)
#   <home>/state/*.meta + *.status  lanes: every ship/scout record, in one state by its last
#                                   status verb and [at=] time (building, validating or waiting on
#                                   CI, waiting on a decision, blocked, waiting on something
#                                   else, finished not landed); a secondmate record is a lead
#   config/lane-caps                "<home> <cap>" lane plan per home (Main is "main" or the name
#                                   of its home's parent folder); config/lane-target is the default (4)
#   bin/fm-tasks-axi.sh list        each home's backlog (FM_HOME=<home>): queued = ready + held +
#                                   waiting on another item; held for the captain = hold-kind captain
#   herdr agent list                agents busy now (agent_status working), the state the muxr
#                                   app reads; role by pane id against the records: lead, worker,
#                                   Main (the folder holding this home's data), else other
# Machine and devices, each probe read-only with a 5 s timeout:
#   adb devices -l                  connected phones and emulators (nothing else is asked of adb);
#                                   adb from PATH, else platform-tools under $ANDROID_HOME,
#                                   $ANDROID_SDK_ROOT, ~/Android/Sdk or ~/Library/Android/sdk
#   pgrep -a '^qemu-system'         running emulators (-avd, -port; VmRSS from <proc>/<pid>/status)
#   pgrep -cf 'appname=gradle[w]'   Gradle builds, counted as config/fm-mem-gate.sh counts them
#   systemctl --user show fm-heavy.slice   MemoryCurrent, MemoryHigh, MemoryMax
#   <proc>/meminfo, <proc>/pressure/memory   MemAvailable; "some avg10" (the gate's rule) and
#                                   "some avg300" (the 5-minute average the page shows)
#   <locks>/fm-phone-<name>.lock + <proc>/locks   who holds a device now (flock by inode);
#   <locks>/fm-device-lock.log      the holder's pid, time and cwd, mapped to its home by
#                                   each home's state/*.meta worktree=, tasktmp= or task id;
#                                   an emulator matches a held lock its process ancestry took
#   <proc> is FM_DASHBOARD_PROC (default /proc), <locks> FM_DEVICE_LOCK_DIR (default /tmp);
#   FM_EMU_MAX, FM_GRADLE_MAX, FM_MEM_MIN_GB (defaults 2, 2, 12) mirror the memory gate's caps
# All day comparisons use the host timezone. Besides the pages, a build writes only
# its pages under state/dashboard, and the snapshot's own ledger cache.
#
# Usage:
#   fm-dashboard.sh [build]
#   fm-dashboard.sh serve [--bind ADDR] [--port N]
# build (the default) writes $FM_HOME/state/dashboard/*.html and prints the index path.
# serve runs a small read-only web server (python3 stdlib, IPv4) that answers GET or
# HEAD for /, /index.html, /backlog and /measure only; every other path
# is 404. ?group=home or ?group=action picks how lists are grouped and is remembered in
# a cookie. It answers at once with the last built pages, marked "updated N s ago", and
# keeps them fresh itself: a side thread starts each rebuild early enough, by the last
# build's length, for the new pages to land as the old ones turn 60 seconds old, and
# the pages reload themselves every 60 seconds; only the very first load waits for a
# build. It prints `serving http://ADDR:PORT/` once listening. ADDR defaults to
# 127.0.0.1 and PORT to 8787; port 0 picks a free port. There is no authentication:
# reach is whatever the bind address exposes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
out_dir="$FM_HOME/state/dashboard"
page="$out_dir/index.html"
MAX_AGE=60

usage() { echo "usage: fm-dashboard.sh [build] | serve [--bind ADDR] [--port N]" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "fm-dashboard: python3 is required" >&2; exit 1; }

cmd=${1:-build}
[ $# -gt 0 ] && shift
case "$cmd" in
  build) [ $# -eq 0 ] || usage ;;
  serve)
    bind=127.0.0.1 port=8787
    while [ $# -gt 0 ]; do
      case "$1" in
        --bind) [ $# -ge 2 ] || usage; bind=$2; shift 2 ;;
        --port) [ $# -ge 2 ] || usage; port=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    case "$port" in ''|*[!0-9]*) usage ;; esac
    exec python3 - "$0" "$FM_HOME" "$out_dir" "$bind" "$port" "$MAX_AGE" <<'PY'
import http.server, os, subprocess, sys, threading, time, urllib.parse
SCRIPT, HOME, DIR, BIND, PORT, MAX_AGE = sys.argv[1:7]
MAX_AGE = int(MAX_AGE)
PAGE = os.path.join(DIR, 'index.html')
ROUTES = {'/': 'index', '/index.html': 'index', '/backlog': 'backlog', '/measure': 'measure'}
building = threading.Lock()
last_error = b''
last_took = 30.0  # seconds the last build took; a fleet snapshot alone can take 45 s under load

def build():  # call holding `building`; the build replaces each page in one rename
    global last_error, last_took
    start = time.time()
    try:
        r = subprocess.run(['bash', SCRIPT, 'build'], env=dict(os.environ, FM_HOME=HOME),
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        last_error = r.stderr if r.returncode else b''
        last_took = time.time() - start
    finally:
        building.release()

def age():
    try: return time.time() - os.path.getmtime(PAGE)
    except OSError: return None

class Handler(http.server.BaseHTTPRequestHandler):
    timeout = 10  # an idle preconnect must not hold the one-at-a-time server

    def send(self, code, body, ctype, cookie=None):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; img-src data:")
        if cookie: self.send_header('Set-Cookie', f'fm_group={cookie}; Path=/; Max-Age=31536000; SameSite=Lax')
        self.end_headers()
        if self.command != 'HEAD': self.wfile.write(body)

    def do_GET(self):
        path, _, query = self.path.partition('?')
        name = ROUTES.get(path)
        if name is None:
            return self.send(404, b'not found\n', 'text/plain; charset=utf-8')
        asked = urllib.parse.parse_qs(query).get('group', [''])[0]
        asked = asked if asked in ('home', 'action') else None
        jar = dict(c.strip().split('=', 1) for c in (self.headers.get('Cookie') or '').split(';') if '=' in c)
        group = asked or jar.get('fm_group')
        a = age()
        if a is None:  # the first load ever waits for the first pages
            with building: pass  # a build already under way finishes first
            if age() is None:
                building.acquire(); build()
            a = age()
            if a is None:
                return self.send(500, b'dashboard build failed: ' + last_error, 'text/plain; charset=utf-8')
        note = f' · updated {int(a)} s ago' + (' · refreshing' if building.locked() else '')
        if last_error: note += ' · last refresh failed, showing the last good page'
        f = os.path.join(DIR, f'{name}.home.html' if group == 'home' else f'{name}.html')
        if not os.path.isfile(f): f = os.path.join(DIR, f'{name}.html')
        try:
            with open(f, 'rb') as fh: body = fh.read().replace(b'<!--age-->', note.encode(), 1)
        except OSError:
            return self.send(404, b'not built yet\n', 'text/plain; charset=utf-8')
        self.send(200, body, 'text/html; charset=utf-8', asked)
    do_HEAD = do_GET

# ponytail: one request at a time; rebuilds run on a side thread, one at a time.
def refresh():  # rebuild on age, not on requests, so an idle phone never opens a minutes-old page
    while True:
        a = age()  # start early by the last build's length, so the new page lands as this one turns MAX_AGE
        if (a is None or a + last_took >= MAX_AGE) and building.acquire(blocking=False):
            build()
            if last_error: time.sleep(MAX_AGE)  # a failing build retries once a minute
        time.sleep(5)

threading.Thread(target=refresh, daemon=True).start()
srv = http.server.HTTPServer((BIND, int(PORT)), Handler)
print(f'serving http://{BIND}:{srv.server_address[1]}/', flush=True)
try: srv.serve_forever()
except KeyboardInterrupt: pass
PY
    ;;
  -h|--help) sed -n '2,63p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac

mkdir -p "$out_dir" || { echo "fm-dashboard: cannot create $out_dir" >&2; exit 1; }
# Per-run scratch names, so a manual build and a served rebuild never share files.
snap="$out_dir/.snapshot.$$.json"
snap_err="$out_dir/.snapshot.$$.err"
tmp="$out_dir/.build.$$"
trap 'rm -rf "$snap" "$snap_err" "$tmp"' EXIT
mkdir -p "$tmp" || { echo "fm-dashboard: cannot create $tmp" >&2; exit 1; }
FM_HOME="$FM_HOME" FM_BEARINGS_SECONDMATES=500 FM_BEARINGS_UNHEALTHY=500 FM_SNAPSHOT_SECONDMATES=500 "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json > "$snap" 2> "$snap_err" \
  || { rc=$?; : > "$snap"; printf 'fleet snapshot exited %s: %s\n' "$rc" "$(tail -n 1 "$snap_err")" >> "$snap_err"; }

python3 - "$FM_HOME" "$snap" "$snap_err" "$tmp" "$SCRIPT_DIR" "$MAX_AGE" <<'PY' || { echo "fm-dashboard: page build failed" >&2; exit 1; }
import html, json, os, re, shutil, subprocess, sys
from datetime import date, datetime

HOME, SNAP, SNAP_ERR, OUT, BIN, MAX_AGE = sys.argv[1:7]
MAX_AGE = int(MAX_AGE)
NOW = datetime.now().astimezone()
NOW_TS = NOW.timestamp()
TODAY = NOW.date()
notes = []  # (source, one-line reason) for every source that could not be read

def esc(v): return html.escape(str(v), quote=True)
def iso_day(s):
    try: return date.fromisoformat(s)
    except (TypeError, ValueError): return None
def dur(s):
    s = max(0, int(s))
    if s < 60: return 'under a minute'
    if s < 3600: return f'{s // 60}\u00a0min'
    if s < 86400: return f'{s // 3600}\u00a0h' + (f' {s % 3600 // 60}\u00a0min' if s < 36000 and s % 3600 >= 60 else '')
    return f'{s // 86400}\u00a0d'
def days_old(d): return 'today' if d == TODAY else f'{(TODAY - d).days}\u00a0d'
def plural(n, word, many=None): return f'{n} {word if n == 1 else many or word + "s"}'
def hname(h): return 'Main' if h == 'main' else h

def adb_path():  # a server started outside a login shell often lacks the SDK on PATH
    sdks = [os.environ.get('ANDROID_HOME'), os.environ.get('ANDROID_SDK_ROOT'), '~/Android/Sdk', '~/Library/Android/sdk']
    return shutil.which('adb') or next((p for d in sdks if d and os.access(p := os.path.join(os.path.expanduser(d), 'platform-tools', 'adb'), os.X_OK)), 'adb')

def probe(cmd, ok=(0,), timeout=5, env=None, cwd=None):
    """(stdout, None) from a read-only command, or (None, reason)."""
    try: r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env, cwd=cwd)
    except FileNotFoundError: return None, f'{cmd[0]} not found'
    except subprocess.TimeoutExpired: return None, f'{os.path.basename(cmd[0])} gave no answer in {timeout} s'
    except OSError as e: return None, f'{cmd[0]}: {e.strerror}'
    if r.returncode not in ok: return None, (r.stderr.strip().splitlines() or [f'{cmd[0]} exit {r.returncode}'])[-1]
    return r.stdout, None

# --- homes ---------------------------------------------------------------
home_dir = {'main': HOME}
try:
    for l in open(os.path.join(HOME, 'data/secondmates.md'), encoding='utf-8', errors='replace'):
        m = re.match(r'- (\S+) - ', l)
        f = re.match(r'.*\(home: ([^;]*);', l)  # the routing fields close the line; greedy .* lands on the last "(home:"
        if m and f: home_dir[m.group(1)] = f.group(1).strip()
except OSError: pass  # no registered homes
parked = set()
try:
    for l in open(os.path.join(HOME, 'config/parked-homes'), encoding='utf-8', errors='replace'):
        if l.split('#', 1)[0].strip(): parked.add(l.split('#', 1)[0].strip())
except OSError: pass  # no parked homes
ACTIVE = sorted(set(home_dir) - parked, key=lambda h: (h != 'main', h))
PARKED = sorted(set(home_dir) & parked)

lane_default = 4
try: lane_default = int(open(os.path.join(HOME, 'config/lane-target')).read().split()[0])
except (OSError, ValueError, IndexError): pass
caps = {}
try:
    for l in open(os.path.join(HOME, 'config/lane-caps'), encoding='utf-8', errors='replace'):
        f = l.split('#', 1)[0].split()
        if len(f) == 2 and f[1].isdigit(): caps[f[0]] = int(f[1])
except OSError: pass
MAIN_ALIAS = os.path.basename(os.path.dirname(os.path.realpath(HOME)))
def plan(h): return caps.get(h, caps.get(MAIN_ALIAS, lane_default) if h == 'main' else lane_default)
PLAN = sum(plan(h) for h in ACTIVE)

# --- fleet snapshot: lead state -----------------------------------------
snap = None
try:
    snap = json.load(open(SNAP))
    if not isinstance(snap, dict) or snap.get('schema') != 'fm-bearings.v1': raise ValueError('unexpected schema')
except (OSError, ValueError) as e:
    err = ''
    try: err = open(SNAP_ERR, errors='replace').read().strip().splitlines()[-1]
    except (OSError, IndexError): pass
    notes.append(('fleet snapshot', err or str(e) or 'no output')); snap = None
leads = {s.get('id'): s for s in (snap or {}).get('secondmates') or [] if s.get('id') in home_dir and s.get('id') not in parked}
down = {e.get('id') for e in (snap or {}).get('unhealthy_endpoints') or []} & set(leads)
LEAD_WORDS = {'captain_decision': ('Holding a decision', 'warn'), 'externally_held': ('Waiting on someone else', 'warn'),
              'unknown': ('Records need tidy-up', 'bad'), 'working': ('Working', 'ok'), 'idle': ('Idle', ''),
              'active_child_work': ('Working', 'ok'), 'no_active_work': ('Idle', ''),
              'stale': ('Not responding', 'bad'), 'dead': ('Stopped', 'bad')}
def lead_word(h):
    if h in down: return ('Not running', 'bad')
    s = (leads.get(h) or {}).get('state')
    return LEAD_WORDS.get(s, (str(s or '').replace('_', ' ').capitalize(), '')) if h in leads else ('', '')

# --- Waiting on you: Main's ask list ------------------------------------
asks, asks_known, ask_ids = [], True, set()
try:
    for n, line in enumerate(open(os.path.join(HOME, 'data/captain-asks.tsv'), encoding='utf-8', errors='replace'), 1):
        fields = line.rstrip('\r\n').split('\t')
        if not line.strip(): continue
        if len(fields) < 3 or not fields[0].strip() or not fields[2].strip():  # no id or no text: not an ask
            notes.append(('data/captain-asks.tsv', f'row {n} skipped: no id or text')); continue
        valid = len(fields) == 4 and fields[0].strip() and fields[2].strip() and re.fullmatch(r'[0-9]{1,10}', fields[1]) and fields[0] not in ask_ids
        if valid: ask_ids.add(fields[0])
        epoch = int(fields[1]) if valid else None
        age = None if epoch is None or epoch > int(NOW_TS) else int(NOW_TS) - epoch
        asks.append((fields, age))
        if age is None: notes.append(('data/captain-asks.tsv', f'malformed row {n}'))
except FileNotFoundError: pass
except OSError as e:
    asks_known = False
    notes.append(('data/captain-asks.tsv', f'unreadable: {e.strerror}'))

# --- lanes: every ship/scout record, one state each ---------------------
VALIDATING = re.compile(r'validat|no-mistakes|\bCI\b|\bchecks?\b|pipeline', re.I)
STATES = {'blocked': 'Blocked, needs help', 'decision': 'Waiting on a decision', 'finished': 'Finished, not landed',
          'building': 'Building', 'validating': 'Validating or waiting on CI', 'waiting': 'Waiting on something else'}
ACT = [('Blocked or waiting on a decision', ('blocked', 'decision'), 'wb'), ('Finished, not landed', ('finished',), 'l2'),
       ('Producing', ('building', 'validating'), ''), ('Waiting on something else', ('waiting',), 'ol')]
metas, lanes, lane_err = {}, [], set()
for h, d in sorted(home_dir.items()):
    sd = os.path.join(d, 'state')
    try: files = sorted(f for f in os.listdir(sd) if f.endswith('.meta'))
    except OSError as e:
        lane_err.add(h); notes.append(('lane records', f'{h}: {e.strerror}')); continue
    for f in files:
        try: meta = dict(l.rstrip('\n').split('=', 1) for l in open(os.path.join(sd, f), errors='replace') if '=' in l)
        except OSError: continue
        metas.setdefault(h, []).append((f[:-5], meta))
        if meta.get('kind') not in ('ship', 'scout'): continue
        try:
            ls = [l.strip() for l in open(os.path.join(sd, f[:-5] + '.status'), errors='replace') if l.strip()]
            mt = os.path.getmtime(os.path.join(sd, f[:-5] + '.status'))
        except OSError: ls, mt = [], os.path.getmtime(os.path.join(sd, f))
        keys, verb, at, text, pr = set(), 'working', None, '', ''
        for l in ls:
            v = re.match(r'^(?:\d{9,11}\s+)?([a-z][a-z-]*)', l)
            verb = v.group(1) if v else 'unknown'
            a = re.search(r'\[at=(\d+)\]', l)
            at = int(a.group(1)) if a else at
            k = re.search(r'\[key=([^\]]+)\]', l)
            key = k.group(1) if k else 'default'
            if verb in ('done', 'failed'): keys.clear()
            elif verb in ('blocked', 'needs-decision'): keys.add(key)
            elif verb in ('resolved', 'captain-held'): keys.discard(key)
            text = l.split(':', 1)[1].strip() if ':' in l else ''
            pr = (re.findall(r'https://github\.com/[\w.-]+/[\w.-]+/pull/\d+', l) or [pr])[-1]
        if any(k.startswith('captain-hold') for k in keys): state = 'decision'
        elif verb in ('working', 'resolved'): state = 'building'
        elif verb == 'needs-decision': state = 'decision'
        elif verb == 'done': state = 'finished'
        elif verb in ('blocked', 'paused', 'failed') and VALIDATING.search(text): state = 'validating'
        elif verb in ('blocked', 'failed'): state = 'blocked'
        else: state = 'waiting'
        lanes.append(dict(home=h, task=f[:-5], state=state, since=at or mt, text=text, pr=pr, meta=meta))
live = [l for l in lanes if l['home'] not in parked]
def split(ls): return {s: sum(l['state'] == s for l in ls) for s in STATES}
SPLIT = split(live)
OPEN = len(live)
by_home = {h: [l for l in live if l['home'] == h] for h in ACTIVE}

# --- backlog per home: tasks-axi ----------------------------------------
def toon_fields(s):
    out, i = [], 0
    while i <= len(s):
        if s.startswith('"', i):
            j = i + 1
            while j < len(s) and s[j] != '"': j += 2 if s[j] == '\\' else 1
            out.append(json.loads(s[i:j + 1])); i = j + 2
        else:
            j = s.find(',', i); j = len(s) if j < 0 else j
            out.append(s[i:j]); i = j + 1
    return out
def toon_rows(text, name='tasks'):
    """Rows of the named tabular TOON block, [] when it says there are none, else None."""
    lines = text.splitlines()
    for i, l in enumerate(lines):
        m = re.match(rf'^{name}\[(\d+)\]\{{([^}}]*)\}}:$', l)
        if m:
            cols = m.group(2).split(',')
            body = lines[i + 1:i + 1 + int(m.group(1))]
            if len(body) < int(m.group(1)): return None
            return [dict(zip(cols, toon_fields(r.strip()))) for r in body]
        if re.match(rf'^{name}: 0 ', l): return []
    return None
def clean(t):
    t = str(t or '')
    return t.split('\n', 1)[0].rstrip() + '…' if '\n' in t else t
backlog = {}
for h, d in sorted(home_dir.items()):
    out, err = probe(['bash', os.path.join(BIN, 'fm-tasks-axi.sh'), 'list', '--limit', '10000',
                      '--fields', 'held,hold_kind,hold_reason,blocked,created,closed'],
                     timeout=20, env=dict(os.environ, FM_HOME=d))
    rows = toon_rows(out) if out is not None else None
    if rows is None:
        backlog[h] = None; notes.append(('backlog', f'{h}: {err or "no task table in its output"}')); continue
    for r in rows:
        r['title'] = clean(r.get('title'))
        r['day'] = iso_day(r.get('created'))
        r['class'] = ('held' if r.get('held') == 'yes' else 'waiting' if r.get('blocked') == 'yes' else 'ready') if r.get('state') == 'queued' else None
    backlog[h] = rows
def bl(h, cls=None, state=None):
    return [r for r in backlog.get(h) or [] if (cls is None or r['class'] == cls) and (state is None or r.get('state') == state)]
bl_known = all(backlog.get(h) is not None for h in ACTIVE)
QUEUE = {c: sum(len(bl(h, c)) for h in ACTIVE) for c in ('ready', 'held', 'waiting')} if bl_known else None
held_cap = sorted(((h, r) for h in ACTIVE for r in backlog.get(h) or []
                   if r.get('hold_kind') == 'captain' and r.get('state') != 'done'),
                  key=lambda x: (x[1]['day'] or TODAY, x[0]))
titles = {(h, r['id']): r['title'] for h in home_dir for r in backlog.get(h) or []}

# --- agents: the Herdr state the muxr app reads -------------------------
agents = None
out, err = probe(['herdr', 'agent', 'list'])
try:
    if out is None: raise ValueError(err)
    agents = json.loads(out)['result']['agents']
    if not isinstance(agents, list): raise ValueError('no agent list')
except (ValueError, KeyError, TypeError) as e:
    agents = None; notes.append(('herdr agent list', str(e) or 'unreadable'))
pane_role = {}
for h, ms in metas.items():
    for task, m in ms:
        if m.get('herdr_pane_id'):
            pane_role[m['herdr_pane_id']] = ('lead', task, task) if m.get('kind') == 'secondmate' else ('worker', h, task)
ROLES = [('lead', 'leads'), ('main', 'Main'), ('worker', 'workers'), ('other', 'other')]
agent_rows = []  # (role, home, name, status)
for a in agents or []:
    role = pane_role.get(a.get('pane_id'))
    if role: r, h, n = role
    elif os.path.realpath(os.path.join(a.get('cwd') or '/', 'data')) == os.path.realpath(os.path.join(HOME, 'data')): r, h, n = 'main', 'main', 'Main'  # the folder holding this home's records
    else: r, h, n = 'other', None, a.get('name') or os.path.basename((a.get('cwd') or '').rstrip('/')) or 'unnamed'
    if h in parked: continue
    agent_rows.append((r, h, n, a.get('agent_status') or 'unknown'))
busy = [a for a in agent_rows if a[3] == 'working']
BUSY = {r: sum(a[0] == r for a in busy) for r, _ in ROLES}

# --- machine and devices: read-only probes, each with a short timeout ------
# A probe that fails says "unknown" and why; it never guesses a value or a zero.
PROC = os.environ.get('FM_DASHBOARD_PROC', '/proc')
LOCK_DIR = os.environ.get('FM_DEVICE_LOCK_DIR', '/tmp')
def env_int(name, default):
    try: return int(os.environ.get(name, default))
    except ValueError: return default
EMU_MAX, GRADLE_MAX, MEM_MIN_GB = env_int('FM_EMU_MAX', 2), env_int('FM_GRADLE_MAX', 2), env_int('FM_MEM_MIN_GB', 12)

def read(rel):
    try: return open(os.path.join(PROC, rel), errors='replace').read(), None
    except OSError as e: return None, f'{PROC}/{rel}: {e.strerror}'
def gb(kib): return kib / 1048576

def machine():
    m = {}
    t, err = read('meminfo')
    kv = dict(re.findall(r'^(\w+):\s+(\d+)', t or '', re.M))
    m['free'] = (gb(int(kv['MemAvailable'])), gb(int(kv['MemTotal']))) if 'MemAvailable' in kv and 'MemTotal' in kv else None
    m['free_why'] = err or 'no MemAvailable in meminfo'
    t, err = read('pressure/memory')
    p = re.search(r'^some avg10=([0-9.]+) .*avg300=([0-9.]+)', t or '', re.M)
    m['pressure'], m['pressure_why'] = (float(p.group(1)) if p else None), err or 'no "some avg10 ... avg300" line'
    m['pressure5'] = float(p.group(2)) if p else None  # avg10 swings within a minute; the page shows the 5-minute average
    out, err = probe(['systemctl', '--user', 'show', 'fm-heavy.slice', '-p', 'MemoryCurrent', '-p', 'MemoryHigh', '-p', 'MemoryMax'])
    kv = dict(l.split('=', 1) for l in (out or '').splitlines() if '=' in l)
    def size(v): return int(v) / 2**30 if (v or '').isdigit() else None
    m['heavy'] = (size(kv.get('MemoryCurrent')), size(kv.get('MemoryHigh')), size(kv.get('MemoryMax')))
    m['heavy_why'] = err or f"MemoryCurrent is {kv.get('MemoryCurrent', 'missing')}"
    out, err = probe(['pgrep', '-cf', 'appname=gradle[w]'], ok=(0, 1))  # the memory gate's own count
    m['gradle'], m['gradle_why'] = (int(out.split()[0]) if out and out.split()[0].isdigit() else None), err or 'no count'
    return m

def emulators():
    """[{pid, avd, port, rss}] from the running qemu processes, or (None, reason)."""
    out, err = probe(['pgrep', '-a', '^qemu-system'], ok=(0, 1))
    if out is None: return None, err
    emus = []
    for l in out.splitlines():
        pid, _, args = l.partition(' ')
        a = args.split()
        opt = lambda k: a[a.index(k) + 1] if k in a[:-1] else None
        st, _ = read(f'{pid}/status')
        rss = re.search(r'^VmRSS:\s+(\d+)', st or '', re.M)
        emus.append(dict(pid=pid, avd=opt('-avd') or '?', port=opt('-port'), rss=gb(int(rss.group(1))) if rss else None))
    return emus, None

def lock_holders():
    """{lock name: {held, pid, cwd, at, last, verb}} from the device locks, /proc/locks and the lock log."""
    t, err = read('locks')
    held = set(re.findall(r'^\d+:\s+FLOCK\s+\S+\s+\S+\s+\d+\s+(\S+)', t or '', re.M))
    locks = {}
    try: names = sorted(f for f in os.listdir(LOCK_DIR) if f.startswith('fm-phone-') and f.endswith('.lock'))
    except OSError: names = []
    for f in names:
        try: s = os.stat(os.path.join(LOCK_DIR, f))
        except OSError: continue
        key = f'{os.major(s.st_dev):02x}:{os.minor(s.st_dev):02x}:{s.st_ino}'
        locks[f[9:-5]] = dict(held=None if t is None else key in held)
    try:
        for l in open(os.path.join(LOCK_DIR, 'fm-device-lock.log'), errors='replace'):
            f = l.split()
            if len(f) < 3: continue
            at = datetime.fromisoformat(f[0].replace('Z', '+00:00')) if re.match(r'\d{4}-\d\d-\d\dT', f[0]) else None
            d = locks.setdefault(f[1], dict(held=None if t is None else False))
            d.update(last=at, verb=f[2])
            if f[2] == 'acquired':
                kv = dict(x.split('=', 1) for x in f[3:] if '=' in x)
                d.update(pid=kv.get('pid'), at=at, cwd=l.split(' cwd=', 1)[1].strip() if ' cwd=' in l else None)
    except OSError: pass
    return locks, err

def worktree_homes():  # every task's worktree and id, and each home itself, mapped to its home
    m = {}
    for h, d in home_dir.items():
        m[os.path.realpath(d)] = h
        try:
            for f in os.listdir(os.path.join(d, 'state')):
                if not f.endswith('.meta'): continue
                m[f[:-5]] = h  # a worker's own scratch dir is often named after its task id
                for l in open(os.path.join(d, 'state', f), errors='replace'):
                    k, _, v = l.strip().partition('=')
                    if k in ('worktree', 'tasktmp') and v: m[os.path.realpath(v)] = h
        except OSError: pass
    return m
def who(cwd, homes_by_path):
    if not cwd: return 'an unknown worker'
    p = os.path.realpath(cwd)
    while p not in homes_by_path and os.path.dirname(p) != p: p = os.path.dirname(p)
    h = homes_by_path.get(p)
    base = os.path.basename(cwd.rstrip('/'))
    h = h or homes_by_path.get(base) or homes_by_path.get(base.removeprefix('fm-'))
    return ('Main' if h == 'main' else h) if h else base
def ago(at):
    if at is None: return ''
    s = max(0, int(NOW.timestamp() - at.timestamp()))
    return 'under a minute' if s < 60 else f'{s // 60} min' if s < 3600 else f'{s // 3600} h {s % 3600 // 60} min' if s < 86400 else f'{s // 86400} d'
def ancestors(pid):
    seen = []
    for _ in range(40):
        t, _ = read(f'{pid}/stat')
        m = re.match(r'\d+ \(.*\) \S (\d+)', t or '', re.S)
        if not m or m.group(1) in ('0', '1'): break
        pid = m.group(1); seen.append(pid)
    return seen

def devices():
    """(rows, summary) for every adb device, every running emulator and every held device lock."""
    out, adb_err = probe([adb_path(), 'devices', '-l'])
    emus, emu_err = emulators()
    locks, lock_err = lock_holders()
    homes_by_path = worktree_homes()
    held_by_pid = {d['pid']: n for n, d in locks.items() if d.get('held') and d.get('pid')}
    rows, seen_locks = [], set()
    def holder(names, pids=()):
        """(text, tone) for the first held lock among names, else via a held lock an ancestor process took."""
        for n in names:
            d = locks.get(n)
            if d and d.get('held'):
                seen_locks.add(n); w = who(d.get("cwd"), homes_by_path); return f'In use by {w} · {ago(d.get("at"))}', 'warn', w
        for p in pids:
            if p in held_by_pid:
                d = locks[held_by_pid[p]]; seen_locks.add(held_by_pid[p]); w = who(d.get("cwd"), homes_by_path)
                return f'In use by {w} · {ago(d.get("at"))}', 'warn', w
        if lock_err: return f'unknown: {lock_err}', '', None  # no lock state, so free is a guess
        d = next((locks[n] for n in names if n in locks), None)
        if d and d.get('at'):
            return f'Free · last used by {who(d.get("cwd"), homes_by_path)} {ago(d.get("last"))} ago', 'ok', None
        return 'Free', 'ok', None
    emu_by_port = {e['port']: e for e in emus or [] if e['port']}
    serials = []
    connected = 0
    for l in (out or '').splitlines()[1:]:
        f = l.split()
        if len(f) < 2: continue
        serials.append(f[0])
        if f[1] == 'device': connected += 1
        kv = dict(x.split(':', 1) for x in f[2:] if ':' in x)
        e = emu_by_port.pop(f[0][9:], None) if f[0].startswith('emulator-') else None
        if e:
            name, sub = f'Emulator {e["avd"]}', f'{f[0]}' + (f' · {e["rss"]:.1f} GB in use' if e['rss'] is not None else '')
            text, tone, w = holder([f[0], e['avd']], ancestors(e['pid']))
        else:
            name, sub = (kv.get('model') or 'Device').replace('_', ' '), f'{f[0]}' + (' · USB' if 'usb' in kv else '')
            name = ('Emulator ' if f[0].startswith('emulator-') else 'Phone ') + name
            text, tone, w = holder([f[0]])
        if f[1] != 'device': text, tone = f'{f[1].capitalize()} · {text}', 'bad'
        rows.append((name, sub, text, tone, w))
    for e in emu_by_port.values() if emus is not None else []:  # running, but adb does not list it
        text, tone, w = holder([f'emulator-{e["port"]}', e['avd']], ancestors(e['pid']))
        rows.append((f'Emulator {e["avd"]}', 'not listed by adb' + (f' · {e["rss"]:.1f} GB in use' if e['rss'] is not None else ''), text, tone, w))
    for n, d in sorted(locks.items()):  # a held lock no device above accounts for
        if d.get('held') and n not in seen_locks and n not in serials:
            w = who(d.get("cwd"), homes_by_path)
            rows.append((f'Lock {n}', 'no matching device', f'Held by {w} · {ago(d.get("at"))}', 'warn', w))
    problems = [f'adb: {adb_err}'] if out is None else []
    if emus is None: problems.append(f'emulators: {emu_err}')
    if lock_err: problems.append(f'device locks: {lock_err}')
    return rows, connected if out is not None else None, len(emus) if emus is not None else None, problems

mach = machine()
dev_rows, dev_count, emu_count, dev_problems = devices()

# --- html pieces ---------------------------------------------------------
BUILT = NOW.strftime('%H:%M')
def link(text, url, cls='inl'):
    return f'<a class="{cls}" href="{esc(url)}" rel="noreferrer">{esc(text)}</a>' if re.match(r'https?://', url or '') else esc(text)
def sh(label, more=None):  # a section's small label: what it counts, its window and the time its source was read
    a = f'<a href="{esc(more[0])}">{esc(more[1])} →</a>' if more else ''
    return f'<div class="sh"><p class="label">{esc(label)}</p>{a}</div>'
def dot(tone=''): return f'<span class="dot {tone}"></span>'
def unknown(why): return f'<span class="unkv">unknown: {esc(why)}</span>'
def why_of(source): return next((r for s, r in notes if s == source or s.startswith(source)), 'not read')

def item(tone, t, h='', w='', tm=None, href=None):
    t = f'<a href="{esc(href)}">{t}</a>' if href else t
    return (f'<div class="item{" feed" if tm is not None else ""}">' + (f'<span class="tm">{esc(tm)}</span>' if tm is not None else dot(tone))
            + f'<span class="t">{t}</span><span class="h">{h}</span>' + (f'<span class="w">{w}</span>' if w else '') + '</div>')

def switch(group):
    segs = ''.join(f'<a href="?group={k}"{" aria-current=true" if k == group else ""}>{n}</a>' for k, n in (('action', 'What to do'), ('home', 'Home')))
    return f'<div class="gsw"><span>Group lists by</span><nav class="seg" aria-label="Group every list on this page">{segs}</nav></div>'
def glist(groups, total_label, total=None):
    """groups: (name, count, rows html, sub, swatch class or None, open). Group counts sum to the total line."""
    out = ''
    for name, n, rows, sub, sw, op in groups:
        s = f'<i class="sw2 {sw}"></i>' if sw is not None else ''
        out += (f'<details class="g"{" open" if op else ""}><summary><span class="cv"></span><span class="gn">{s}{esc(name)}</span>'
                + (f'<span class="gs">{sub}</span>' if sub else '') + f'<span class="gc">{n}</span></summary><div class="gb">{rows}</div></details>')
    counts = [g[1] for g in groups]
    total = sum(counts) if total is None else total
    eq = f'{" + ".join(map(str, counts))} = ' if len(counts) > 1 else ''
    return f'<div class="gl">{out}<div class="gtot"><span class="k">{esc(total_label)}</span><span class="sum">{eq}<b>{total}</b></span></div></div>'
def grow(n, w='', c=None):
    if c is None: return f'<div class="gr st"><span class="n">{n}</span><span class="w">{w}</span></div>'  # a named row: what, then where and why
    return f'<div class="gr"><span class="n">{n}</span><span class="w">{w}</span><span class="c">{c}</span></div>'
def split_txt(sp, states): return ' · '.join(f'{sp[s]} {s if s != "decision" else "on a decision"}' for s in states if sp.get(s))
PARKED_LINE = (f'<p class="note">{esc(" and ".join(PARKED))} {"is" if len(PARKED) == 1 else "are"} parked by the captain and left out of every total.</p>'
               if PARKED else '')

# --- lanes: the strip (graft from B) and the grouped list ----------------
FREE = max(0, PLAN - OPEN)
def lane_strip(): return stack(lane_parts(SPLIT), max(PLAN, OPEN), 'sb big') + lane_legend(SPLIT, FREE)
def lanes_list(group, names=False, strip=True):
    """Every open lane in exactly one group; with names, each lane is a row, else one row per home with its count."""
    def lane_row(l):
        t = esc(titles.get((l['home'], l['task'])) or l['task'])
        what = STATES[l['state']] if group == 'home' else hname(l['home'])
        pr = f' · {link("pull request", l["pr"])}' if l['pr'] else ''
        return grow(t, f'{esc(what)} · {dur(NOW_TS - l["since"])}{pr}')
    groups = []
    if group == 'home':
        for h in sorted(ACTIVE, key=lambda h: (-sum(l['state'] in ('blocked', 'decision') for l in by_home[h]), -len(by_home[h]), h)):
            ls, sp = by_home[h], split(by_home[h])
            need = sp['blocked'] + sp['decision']
            rows = (''.join(lane_row(l) for l in sorted(ls, key=lambda l: (list(STATES).index(l['state']), l['since']))) if names else
                    ''.join(grow(f'<i class="sw2 {sw}"></i>{esc(STATES[s])}', '', sp[s]) for _, states, sw in ACT for s in states if sp[s]))
            groups.append((hname(h), len(ls), rows, esc(split_txt(sp, list(STATES))) if not need or names else esc(split_txt(sp, ('blocked', 'decision'))), None, bool(need) or names and bool(ls)))
    else:
        for name, states, sw in ACT:
            ls = [l for l in live if l['state'] in states]
            if names: rows = ''.join(lane_row(l) for l in sorted(ls, key=lambda l: l['since']))
            else:
                per = sorted(((h, [l for l in ls if l['home'] == h]) for h in ACTIVE), key=lambda x: (-len(x[1]), x[0]))
                rows = ''.join(grow(esc(hname(h)), esc(split_txt(split(hl), states)) if len(states) > 1 else '', len(hl)) for h, hl in per if hl)
            groups.append((name, len(ls), rows, esc(split_txt(SPLIT, states)) if len(states) > 1 else '', sw, True))
    return (lane_strip() if strip else '') + glist(groups, 'Open lanes', OPEN)

# --- slow spots: each row a state, a number and an age ------------------
spots = []  # dict(tone, chip, what, n, age, href, title)
def where(ls):
    c = {}
    for l in ls: c[l['home']] = c.get(l['home'], 0) + 1
    return ', '.join(f'{hname(h)} {n}' for h, n in sorted(c.items(), key=lambda x: (-x[1], x[0])))
def spot(tone, chip, what, n, age, href, title=''):
    spots.append(dict(tone=tone, chip=chip, what=what, n=n, age=age, href=href, title=f'{n} {what}' + (f' · {title}' if title else '')))
stuck = [l for l in live if l['state'] in ('blocked', 'decision')]
if stuck: spot('warn', 'Stuck', 'blocked or on a decision', len(stuck), dur(NOW_TS - min(l['since'] for l in stuck)), 'backlog#lanes', where(stuck))
fin = [l for l in live if l['state'] == 'finished']
if fin: spot('warn', 'To land', 'finished, not landed', len(fin), dur(NOW_TS - min(l['since'] for l in fin)), 'backlog#lanes', where(fin))
if held_cap:
    c = {}
    for h, _ in held_cap: c[h] = c.get(h, 0) + 1
    oldest = held_cap[0][1]['day']
    spot('warn', 'Held', 'held - Main must triage', f'{"" if bl_known else "≥"}{len(held_cap)}', days_old(oldest) if oldest else 'unknown',
         'backlog?group=home#held', ', '.join(f'{hname(h)} {n}' for h, n in sorted(c.items(), key=lambda x: (-x[1], x[0]))))
if bl_known:
    could = {h: min(max(0, plan(h) - len(by_home[h])), len(bl(h, 'ready'))) for h in ACTIVE}
    if sum(could.values()):
        old = min((r['day'] for h in ACTIVE if could[h] for r in bl(h, 'ready') if r['day']), default=None)
        spot('warn', 'Idle', 'free lanes, ready work', sum(could.values()), days_old(old) if old else 'unknown', 'backlog#targets',
             ', '.join(f'{hname(h)} {len(bl(h, "ready"))} ready, {len(by_home[h])} of {plan(h)} open' for h in ACTIVE if could[h]))
if down: spot('bad', 'Down', 'leads not running', len(down), 'now', '#homes', ', '.join(sorted(down)))
tidy = sorted(h for h in leads if h not in down and lead_word(h)[1] == 'bad')
if tidy: spot('warn', 'Tidy', 'homes to tidy up', len(tidy), 'now', '#homes', ', '.join(tidy))

# --- machine and devices -------------------------------------------------
free, psi, psi5, (hc_, hh_, hm_) = mach['free'], mach['pressure'], mach['pressure5'], mach['heavy']
def psi_tone(v): return 'bad' if v >= 40 else 'warn' if v >= 20 else 'ok'
gate_wait = (free is not None and free[0] < MEM_MIN_GB) or (psi is not None and psi >= 40)
at_cap = [x for x, full in (('emulators', (emu_count or 0) >= EMU_MAX), ('Gradle builds', (mach['gradle'] or 0) >= GRADLE_MAX)) if full]
if gate_wait: spot('bad', 'Memory', 'heavy jobs wait', f'{free[0]:.0f} GB' if free else '?', 'now', '#devices', 'the next heavy job queues')
for x, n, cap in (('emulators', emu_count, EMU_MAX), ('Gradle builds', mach['gradle'], GRADLE_MAX)):
    if x in at_cap: spot('warn', 'At cap', f'{x} at the cap', f'{n}/{cap}', 'now', '#devices', 'the next one queues')
def meter(label, value, frac, tone, hint=''):
    bar = f'<span class="bar"><i class="{tone}" style="width:{max(2, min(100, round(100 * frac)))}%"></i></span>' if frac is not None else ''
    return f'<div class="mm"><span>{esc(label)}</span><b class="{tone}">{value}</b>{bar}{f"<small>{esc(hint)}</small>" if hint else ""}</div>'
machine_rows = ''.join([
    meter('Free memory', f'{free[0]:.1f} GB <small>of {free[1]:.0f} GB</small>', free[0] / free[1] if free[1] else None,
          'bad' if free[0] < MEM_MIN_GB else 'ok', f'heavy jobs wait below {MEM_MIN_GB} GB')
    if free else meter('Free memory', unknown(mach['free_why']), None, ''),
    meter('Memory pressure', f'{psi5:.0f}%', psi5 / 100, psi_tone(psi5),
          f'5-minute average share of time some job waited on memory; heavy jobs wait while the 10 s share is 40% or more (now {psi:.0f}%)')
    if psi5 is not None else meter('Memory pressure', unknown(mach['pressure_why']), None, ''),
    meter('Heavy jobs', f'{hc_:.1f} GB <small>of {hh_:.0f} GB</small>' if hh_ else f'{hc_:.1f} GB', hc_ / hh_ if hh_ else None,
          'warn' if hh_ and hc_ >= 0.9 * hh_ else 'ok', 'shared group for builds and emulators' + (f'; hard limit {hm_:.0f} GB' if hm_ else ''))
    if hc_ is not None else meter('Heavy jobs', unknown(mach['heavy_why']), None, ''),
    meter('Gradle builds', f'{mach["gradle"]} <small>of {GRADLE_MAX}</small>', mach['gradle'] / GRADLE_MAX if GRADLE_MAX else None,
          'warn' if mach['gradle'] >= GRADLE_MAX else 'ok', 'a new build waits at the cap')
    if mach['gradle'] is not None else meter('Gradle builds', unknown(mach['gradle_why']), None, ''),
    meter('Emulators', f'{emu_count} <small>of {EMU_MAX}</small>', emu_count / EMU_MAX if EMU_MAX else None,
          'warn' if emu_count >= EMU_MAX else 'ok', 'a new emulator waits at the cap')
    if emu_count is not None else meter('Emulators', unknown(next((p for p in dev_problems if p.startswith('emulators')), 'no answer')), None, ''),
])
def devices_list(group):
    if group == 'home':
        key = lambda r: r[4] or 'No holder'
        order = sorted({key(r) for r in dev_rows}, key=lambda k: (k == 'No holder', k))
    else:
        key = lambda r: 'Problem' if r[3] == 'bad' else 'In use' if r[4] else 'Free'
        order = [k for k in ('Problem', 'In use', 'Free') if any(key(r) == k for r in dev_rows)]
    groups = [(k, sum(key(r) == k for r in dev_rows), ''.join(grow(esc(r[0]), esc(f'{r[2]} · {r[1]}')) for r in dev_rows if key(r) == k), '', None, True) for k in order]
    body = glist(groups, 'Devices') if dev_rows else ('<p class="note">No device connected and no emulator running.</p>' if dev_count is not None else '')
    return body + ''.join(f'<p class="note">unknown - {esc(p)}</p>' for p in dev_problems)

# --- homes ---------------------------------------------------------------
def home_row(h):
    sp, lw = split(by_home[h]), lead_word(h)
    parts = [lw[0]] if lw[1] in ('bad', 'warn') else []
    parts += [split_txt(sp, list(STATES))] if by_home[h] else ['No open lanes']
    if h in lane_err: parts = ['Lane records unreadable']
    need = sp['blocked'] + sp['decision']
    tone = 'bad' if lw[1] == 'bad' else 'warn' if need or lw[1] == 'warn' else 'ok' if by_home[h] else 'idle'
    rd = len(bl(h, 'ready')) if backlog.get(h) is not None else None
    z = lambda v, c, s=None: f'<span class="f {c}{" z" if not v else ""}">{"–" if v is None else s or v}</span>'
    return (f'<div class="home"><span class="n">{dot(tone)}{esc(hname(h))}</span><span class="s">{esc(" · ".join(p for p in parts if p))}</span>'
            + z(len(by_home[h]), 'fb', f'{len(by_home[h])}<small>/{plan(h)}</small>') + z(rd, 'fc') + '</div>')
homes_table = ('<div class="homes nl"><div class="home head" aria-hidden="true"><span class="n"></span><span class="s">.</span>'
               '<span class="f fb">Lanes open / plan</span><span class="f fc">Ready</span></div>'
               + ''.join(home_row(h) for h in ACTIVE) + '</div>' + PARKED_LINE)

# --- charts: inline CSS bars drawn here, no script ----------------------
def legend(*items):  # (class, text)
    return '<div class="lg">' + ''.join(f'<span><i class="{c}"></i>{t}</span>' for c, t in items) + '</div>'
# Lane states in one order and one colour each, the same everywhere.
LANE_ORDER = [('building', 'building'), ('validating', 'validating or CI'), ('finished', 'finished, not landed'),
              ('waiting', 'waiting on something'), ('decision', 'on a decision'), ('blocked', 'blocked')]
def stack(parts, total, cls='sb'):  # parts: (class, n, title); total sets the scale, the rest is free
    used = sum(n for _, n, _ in parts)
    segs = ''.join(f'<i class="{c}" style="flex:{n}" title="{esc(t)}"></i>' for c, n, t in parts if n)
    free = total - used
    return f'<div class="{cls}">{segs}' + (f'<i class="free" style="flex:{free}" title="{free} free"></i>' if free > 0 else '') + '</div>'
def lane_parts(sp): return [(f's-{s}', sp[s], f'{sp[s]} {n}') for s, n in LANE_ORDER]
def lane_legend(sp, free=None):
    return legend(*[(f'k s-{s}', f'{sp[s]} {n}') for s, n in LANE_ORDER if sp[s]], *([('k free', f'{free} free of plan {PLAN}')] if free else []))
def spot_table():
    if not spots: return '<p class="note okn">No slow spots now.</p>'
    rows = ''.join(f'<a class="sp" href="{esc(s["href"])}" title="{esc(s["title"])}"><span class="chip c-{s["tone"]}">{esc(s["chip"])}</span>'
                   f'<span class="spw">{esc(s["what"])}</span><b class="sn">{s["n"]}</b><span class="sa">{esc(s["age"])}</span></a>' for s in spots)
    return f'<div class="sps"><div class="sp sph"><span>State</span><span>What</span><span>N</span><span>Oldest</span></div>{rows}</div>'

def card(title, window, body, cls='', more=None):
    m = f'<a class="cm" href="{esc(more[0])}">{esc(more[1])} →</a>' if more else ''
    return f'<section class="card {cls}"><div class="ch"><h3>{title}</h3>{m}</div><p class="cw">{window}</p>{body}</section>'

# --- page shell ----------------------------------------------------------
NAV = [('./', 'index', 'Overview'), ('backlog', 'backlog', 'Backlog'), ('measure', 'measure', 'Method')]
records = []  # (title, detail): two records that give different answers
for h in sorted(home_dir):
    fl = bl(h, state='in_flight')
    if h in parked and fl: records.append((f'{h} is parked but has {plural(len(fl), "item")} marked in flight', 'Its backlog still lists them in flight.'))
    elif fl and h not in lane_err:
        lt = {l['task'] for l in lanes if l['home'] == h}
        orphan = [r for r in fl if r['id'] not in lt and r.get('kind') in ('ship', 'scout')]
        if orphan: records.append((f'{hname(h)}: {plural(len(orphan), "item")} marked in flight with no live lane',
                                   ', '.join(r['id'] for r in orphan[:6]) + (' and more' if len(orphan) > 6 else '')))
def trust():
    parts = [f'<a class="warn" href="measure#records">{plural(len(records), "record")} disagree</a>'] if records else []
    parts += [f'<a class="warn" href="measure#unknown">{plural(len(notes), "source")} unknown</a>'] if notes else []
    return ' · '.join(parts) or 'All sources read'
CSS = ':root{color-scheme:light dark;--bg:#fbf6ef;--card:#ffffff;--text:#231b14;--text2:#5d5045;--text3:#857768;--line:rgba(90,55,20,.11);--line2:rgba(90,55,20,.22);--bar:#4a3f36;--track:rgba(90,55,20,.09);--tick:#231b14;--acc:#ec5a24;--in:#1c8c9c;--vio:#7a5ae6;--ok:#22924e;--okbar:#2fae62;--warn:#a76800;--warnbar:#eba51c;--bad:#d42f5a}@media (prefers-color-scheme:dark){:root{--bg:#16120e;--card:#211b16;--text:#f5eee6;--text2:#d2c6b8;--text3:#a09385;--line:rgba(255,230,200,.09);--line2:rgba(255,230,200,.18);--bar:#d8ccbf;--track:rgba(255,230,200,.09);--tick:#f5eee6;--acc:#ff8352;--in:#4fc3d2;--vio:#a88dff;--ok:#4fd18b;--okbar:#43c47e;--warn:#f7bc45;--warnbar:#f0ab2a;--bad:#ff6b8f}}*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.5 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;font-variant-numeric:tabular-nums;-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}a{color:inherit;text-decoration:none}a:hover{text-decoration:underline;text-decoration-color:var(--line2);text-underline-offset:3px}.shell{max-width:780px;margin:0 auto;padding:0 16px 40px}/* nav */.brand{display:none}.brand b{font-size:16px;font-weight:600;letter-spacing:-.01em}.stamp{display:block;font-size:12px;color:var(--text3);margin-top:2px}.nav{display:flex;gap:16px;align-items:center;border-bottom:1px solid var(--line);overflow-x:auto;scrollbar-width:none}.nav a{font-size:14px;color:var(--text2);padding:12px 0 11px;border-bottom:1.5px solid transparent;margin-bottom:-1px;white-space:nowrap}.nav a:hover{text-decoration:none;color:var(--text)}.nav a[aria-current]{color:var(--text);border-bottom-color:var(--text);font-weight:500}.side-foot{display:none}main{padding-top:14px}/* type: 12 meta, 14 small, 16 body, 20 answers, 28/36 verdicts */.label{font-size:12px;color:var(--text3);margin:0;font-weight:500}.sh{display:flex;justify-content:space-between;align-items:baseline;gap:12px;margin:0 0 4px}.sh a{font-size:12px;color:var(--text2);white-space:nowrap}h1{text-wrap:balance;font-size:28px;line-height:1.15;letter-spacing:-.022em;font-weight:650;margin:0;max-width:24ch}.lede{text-wrap:pretty;font-size:16px;color:var(--text2);margin:8px 0 0;max-width:56ch}.lede a,.inl{color:var(--text);text-decoration:underline;text-decoration-color:var(--line2);text-underline-offset:3px}h2{font-size:20px;line-height:1.3;letter-spacing:-.014em;font-weight:600;margin:0 0 10px;text-wrap:balance}.meta{display:flex;flex-wrap:wrap;align-items:center;gap:4px 14px;margin-bottom:8px;font-size:12px;color:var(--text3)}.state{display:inline-flex;align-items:center;gap:7px;font-size:14px;font-weight:500}.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}.mut{color:var(--text3)}.sub{color:var(--text2)}a.warn{text-decoration:underline;text-decoration-color:currentColor;text-underline-offset:3px;text-decoration-thickness:1px}.dot{width:7px;height:7px;border-radius:50%;background:currentColor;flex:none;display:inline-block}.dot.idle{background:none;box-shadow:inset 0 0 0 1.5px var(--text3)}.dot.warn{background:var(--warnbar)}.dot.ok{background:var(--ok)}.sections{display:grid;gap:26px;margin-top:20px}.stack{display:grid;gap:28px;align-content:start;min-width:0}section{min-width:0}.more{display:inline-block;margin-top:10px;font-size:14px;color:var(--text2)}/* key-value rows */.rows{border-top:1px solid var(--line)}.kv{display:grid;grid-template-columns:minmax(0,1fr) 48px 2.6em 6.6em;align-items:center;column-gap:10px;min-height:40px;border-bottom:1px solid var(--line)}.kv .k{color:var(--text2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.kv .v{text-align:right;font-weight:600;white-space:nowrap;letter-spacing:-.01em}.kv .d{font-size:12px;color:var(--text3);white-space:nowrap}.kv .d.warn{color:var(--warn)}.ge{font-weight:400;color:var(--text3);margin-right:1px}.spark{display:block;width:48px;height:18px;color:var(--text3)}.wo,.wonly{display:none}.nw{white-space:nowrap}/* items: what / where / why */.item{display:grid;grid-template-columns:14px minmax(0,1fr) auto;column-gap:8px;padding:8px 0;border-bottom:1px solid var(--line);align-items:baseline}.item .dot{transform:translateY(-1px)}.item .t{font-weight:500}.item .w{grid-column:2/4;font-size:14px;color:var(--text3);margin-top:1px}.item .h{font-size:14px;color:var(--text2);white-space:nowrap}.cline{display:grid;grid-template-columns:14px minmax(0,1fr);column-gap:8px;align-items:baseline;font-size:14px;color:var(--text2);padding:10px 0 0}.cline .dot{transform:translateY(-1px)}/* homes */.home{display:grid;grid-template-columns:minmax(0,1fr) repeat(3,3.4em);grid-template-areas:"n a b c" "s s s s";column-gap:6px;padding:10px 0;border-bottom:1px solid var(--line);align-items:baseline}.home.head{padding:0 0 6px;font-size:12px;color:var(--text3);line-height:1.25;align-items:end}.home .n{grid-area:n;display:flex;align-items:center;gap:9px;font-weight:550}.home .s{grid-area:s;font-size:14px;color:var(--text2);padding-left:16px;margin-top:1px}.home .f{text-align:right}.home .fa{grid-area:a}.home .fb{grid-area:b}.home .fc{grid-area:c}.home.head .s{display:none}.z{color:var(--text3)}/* lane split */.split{display:flex;height:10px;gap:2px;margin:2px 0 12px}.split i{display:block;height:100%;background:var(--bar)}.split i.l2{opacity:.6}.split i.l3{opacity:.35}.split i.wb{background:var(--warnbar)}.lane{display:grid;grid-template-columns:12px minmax(0,1fr) 2.4em;column-gap:8px;padding:8px 0;border-bottom:1px solid var(--line);align-items:baseline}.lane .sw2{width:9px;height:9px;border-radius:2px;background:var(--bar);transform:translateY(0)}.lane .sw2.l2{opacity:.6}.lane .sw2.l3{opacity:.35}.lane .sw2.wb{background:var(--warnbar)}.lane .c{text-align:right;font-weight:600}.lane .w{grid-column:2/4;font-size:14px;color:var(--text3)}.lane.tot{border-bottom:0;border-top:1px solid var(--line2);margin-top:-1px}.lane.tot .k{font-weight:600}.split i.ol,.sw2.ol{background:none;box-shadow:inset 0 0 0 1.5px var(--text3)}/* grouped lists: switch, collapsible groups, visible sum */.gsw{display:flex;align-items:center;gap:10px;margin:18px 0 0;font-size:12px;color:var(--text3)}.seg{display:inline-flex;gap:2px;padding:2px;border:1px solid var(--line2);border-radius:8px}.seg a{padding:4px 11px;border-radius:6px;color:var(--text2);white-space:nowrap;line-height:1.4}.seg a:hover{text-decoration:none;color:var(--text)}.seg a[aria-current]{background:var(--track);color:var(--text);font-weight:600}.gl{border-top:1px solid var(--line)}details.g{border-bottom:1px solid var(--line)}details.g>summary{list-style:none;cursor:pointer;display:grid;grid-template-columns:16px minmax(0,1fr) auto;grid-template-areas:"cv gn gc" ". gs gs";column-gap:8px;align-items:baseline;padding:10px 0}details.g>summary::-webkit-details-marker{display:none}.cv{grid-area:cv;align-self:start;height:24px;display:flex;align-items:center}.cv::before{content:"";width:6px;height:6px;border-right:1.5px solid var(--text3);border-bottom:1.5px solid var(--text3);transform:translate(2px,-2px) rotate(45deg)}details.g:not([open]) .cv::before{transform:translate(0,0) rotate(-45deg)}details.g[open] .gs.cl{display:none}.gn{grid-area:gn;font-weight:600}.gn .sw2{display:inline-block;width:9px;height:9px;border-radius:2px;background:var(--bar);margin-right:9px;vertical-align:0}.gn .sw2.l3{opacity:.35}.gn .sw2.wb{background:var(--warnbar)}.gn .sw2.ol{background:none}.gn .sw2.no{visibility:hidden}.gc{grid-area:gc;font-weight:600;text-align:right}.gs{grid-area:gs;font-size:14px;color:var(--text3)}.gb{padding:0 0 10px 24px;font-size:14px}.gr{display:grid;grid-template-columns:6.5em minmax(0,1fr) 2.4em;column-gap:12px;align-items:baseline;padding:3px 0}.gr .n{color:var(--text)}.gr .w{color:var(--text3)}.gr .c{grid-column:3;text-align:right;color:var(--text2)}.gr.st .n{grid-column:1/3}.gr .sw2{display:inline-block;width:8px;height:8px;border-radius:2px;background:var(--bar);margin-right:9px}.gr .sw2.l3{opacity:.35}.gr .sw2.wb{background:var(--warnbar)}.gr .sw2.ol{background:none}.gr.dv{grid-template-columns:minmax(0,1fr)}.homes.nl .home{grid-template-columns:minmax(0,1fr) repeat(2,3.4em);grid-template-areas:"n b c" "s s s"}.gtot{display:flex;justify-content:space-between;align-items:baseline;gap:12px;padding:10px 0 0;border-top:1px solid var(--line2);margin-top:-1px}.gtot .k{font-weight:600}.gtot .sum{font-size:14px;color:var(--text3);white-space:nowrap}.gtot .sum b{font-size:16px;color:var(--text);font-weight:600;margin-left:3px}.ks{display:block;font-size:12px;color:var(--text3);line-height:1.3}.kv .k.span{grid-column:1/3;padding:4px 0}/* tables */table{width:100%;border-collapse:collapse}th{font-size:12px;font-weight:500;color:var(--text3);text-align:right;padding:0 0 6px 8px;vertical-align:bottom;line-height:1.25}th:first-child,td:first-child{text-align:left;padding-left:0}td{text-align:right;padding:9px 0 9px 8px;border-top:1px solid var(--line)}tbody tr:last-child td{border-bottom:1px solid var(--line)}tfoot td{font-weight:600;border-top:1px solid var(--line2);border-bottom:0}td.l,th.l{text-align:left}td .bf,th.bfc,td.bfc{display:none}.tt td{vertical-align:top}.tt td:first-child{color:var(--text)}.tt td.l{color:var(--text2);font-size:14px}.tt th.l{width:46%}/* totals equation */.eq{display:flex;flex-wrap:wrap;align-items:flex-end;gap:6px 14px;border-top:1px solid var(--line);border-bottom:1px solid var(--line);padding:12px 0}.eq div span{display:block;font-size:12px;color:var(--text3)}.eq div b{display:block;font-size:20px;font-weight:600;letter-spacing:-.015em;line-height:1.3}.eq .op{font-size:20px;color:var(--text3);line-height:1.3}.eq small{font-size:14px;font-weight:400;color:var(--text2)}/* charts */.chart svg{display:block;width:100%;height:120px}.cols{display:grid;text-align:center;font-size:12px;color:var(--text3);border-top:1px solid var(--line2);padding-top:6px}.cols b{display:block;font-size:14px;font-weight:600;color:var(--text)}.cols i{font-style:normal}.legend{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:14px;color:var(--text2);margin:0 0 10px}.sw{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;vertical-align:-1px}.sw.f{background:var(--bar)}.sw.o{box-shadow:inset 0 0 0 1.5px var(--text2)}.note{font-size:14px;color:var(--text3);margin:10px 0 0;max-width:62ch}.unk{display:flex;justify-content:space-between;gap:12px;padding:10px 0;border-bottom:1px solid var(--line);color:var(--text2)}.unk b{font-weight:500;color:var(--text3)}/* feed */.feed .item{grid-template-columns:3.4em minmax(0,1fr) auto}.feed.nt .item{grid-template-columns:minmax(0,1fr) auto}.feed.nt .item .w{grid-column:1/3}.feed .tm{font-size:14px;color:var(--text3)}/* quota */.acct{padding:14px 0 16px;border-bottom:1px solid var(--line)}.acct:first-child{border-top:1px solid var(--line)}.acct-h{display:flex;justify-content:space-between;align-items:baseline;gap:4px 12px;flex-wrap:wrap}.acct-h b{font-weight:600}.acct-h .r{font-size:14px;font-weight:500}.acct-meta{font-size:14px;color:var(--text3);margin-top:1px}.win{display:grid;grid-template-columns:minmax(0,1fr) 3.2em;grid-template-areas:"l p" "b b" "x x";column-gap:10px;margin-top:12px}.win .l{grid-area:l;font-size:14px;color:var(--text2)}.win .p{grid-area:p;text-align:right;font-weight:600}.win svg{grid-area:b;display:block;width:100%;height:12px;margin:4px 0 2px;overflow:visible}.win .x{grid-area:x;font-size:12px;color:var(--text3)}.meter .tr{fill:var(--track)}.meter .fi{fill:var(--bar)}.meter .fi.w{fill:var(--warnbar)}.meter .fi.m{fill:var(--text3);opacity:.55}.meter .tk{stroke:var(--tick);stroke-width:1.5}.users{font-size:14px;color:var(--text3);margin-top:12px}.users b{font-weight:500;color:var(--text2)}.two table{margin-top:22px}.grp{font-size:12px;color:var(--text3);font-weight:500;margin:16px 0 4px}.grp:first-of-type{margin-top:0}footer{margin-top:40px;padding-top:14px;border-top:1px solid var(--line);font-size:14px;color:var(--text3);line-height:1.6}footer p{margin:0 0 4px}footer a{color:var(--text2);text-decoration:underline;text-decoration-color:var(--line2);text-underline-offset:3px}@media (min-width:600px){ .shell{padding:0 32px 48px} .nav{gap:22px} main{padding-top:24px} h1{font-size:36px} .sections{gap:36px;margin-top:28px} .stack{gap:36px} .kv{grid-template-columns:minmax(0,1fr) 72px 2.8em 13em;column-gap:16px;min-height:44px} .spark{width:72px;height:22px} .wo{display:inline}.wonly{display:block} .item .w{grid-column:2/3} .feed.nt .item .w{grid-column:1/2} .home{grid-template-columns:9em minmax(0,1fr) repeat(3,4.6em);grid-template-areas:"n s a b c";column-gap:12px} .home .s{padding-left:0;margin-top:0} .home.head .s{display:block;visibility:hidden} td .bf{display:block;margin:0 auto} th.bfc,td.bfc{display:table-cell;width:42%} th.bfc{text-align:center} .chart svg{height:140px} details.g>summary{grid-template-columns:16px auto minmax(0,1fr) auto;grid-template-areas:"cv gn gs gc";column-gap:10px} .homes.nl .home{grid-template-columns:9em minmax(0,1fr) repeat(2,4.6em);grid-template-areas:"n s b c"}}@media (max-width:1099px){ .ov>.stack{display:contents} .a-out{order:1}.a-slow{order:2}.a-lanes{order:3}.a-homes{order:4}.a-dev{order:5}}@media (min-width:1100px){ .shell{max-width:1360px;display:grid;grid-template-columns:184px minmax(0,1fr);column-gap:72px;padding:0 56px 64px} .side{position:sticky;top:0;align-self:start;padding-top:40px;height:100vh} .brand{display:block} .nav{flex-direction:column;align-items:flex-start;gap:2px;border:0;margin-top:28px;overflow:visible} .nav a{padding:6px 10px;margin:0 0 0 -10px;border:0;border-radius:6px} .nav a[aria-current]{background:var(--track);border:0} .side-foot{display:block;position:absolute;bottom:40px;font-size:12px;color:var(--text3);line-height:1.6;max-width:184px} .side-foot a{color:var(--text2);text-decoration:underline;text-decoration-color:var(--line2);text-underline-offset:3px} main{padding-top:40px;max-width:1100px} .hero .meta{display:none} .sections{grid-template-columns:repeat(2,minmax(0,1fr));gap:52px 72px;margin-top:44px} .sections .wide{grid-column:1/-1} .stack{gap:52px} .accts{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));column-gap:72px} .acct:nth-child(2){border-top:1px solid var(--line)} .two{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);column-gap:72px;align-items:start} .two table{margin-top:0!important} .kv{grid-template-columns:minmax(0,1fr) 64px 2.8em 10.5em} .home{grid-template-columns:9em minmax(0,30em) repeat(3,minmax(4.6em,1fr))} .homes.nl .home{grid-template-columns:9em minmax(0,30em) repeat(2,minmax(4.6em,1fr))}}/* phase 2: grafts and live-only pieces */.unkv{color:var(--text3);font-weight:400;font-size:14px}.trust{margin-top:0}.trust a{color:var(--text2)}.trust a.warn{color:var(--warn)}.strip{display:flex;height:12px;gap:2px;margin:2px 0 8px}.strip i{flex:1;border-radius:2px;background:var(--bar)}.strip i.st{background:var(--warnbar)}.strip i.fr{background:none;box-shadow:inset 0 0 0 1.5px var(--line2)}.sw.mv{background:var(--bar)}.sw.st{background:var(--warnbar)}.sw.fr{box-shadow:inset 0 0 0 1.5px var(--line2)}.gr .n{min-width:0;overflow:hidden;text-overflow:ellipsis}.gb .gr{grid-template-columns:minmax(0,1fr) auto 2.4em}.gb .gr .w{font-size:13px;text-align:right}@media (max-width:599px){.gb .gr{grid-template-columns:minmax(0,1fr) 2.4em}.gb .gr .w{grid-column:1/-1;grid-row:2;text-align:left}}.iol{border-top:1px solid var(--line)}.iob{display:grid;grid-template-columns:6em minmax(0,1fr);grid-template-areas:"lab bars" ". nums";column-gap:12px;padding:10px 0;border-bottom:1px solid var(--line)}.iob .lab{grid-area:lab;color:var(--text2)}.iob .bars{grid-area:bars;display:grid;gap:4px;align-content:center}.iob .nums{grid-area:nums;font-size:13px;color:var(--text3)}.io{display:block;height:9px;border-radius:2px;min-width:0}.io.out{background:var(--bar)}.io.in{box-shadow:inset 0 0 0 1.5px var(--text2)}.iol+.legend{margin-top:10px}.ro{display:grid;grid-template-columns:auto minmax(0,1fr);column-gap:12px;padding:10px 0;border-bottom:1px solid var(--line);align-items:baseline}.ro>b{font-size:20px;font-weight:600;letter-spacing:-.015em}.ro .rn{font-size:14px;color:var(--text2)}.ro .rn b{color:var(--text)}.ro .bar,.mm .bar{grid-column:1/-1;display:block;height:6px;background:var(--track);border-radius:3px;margin:6px 0 3px;overflow:hidden}.ro .bar i,.mm .bar i{display:block;height:100%;background:var(--bar)}.ro .bar i.w,.mm .bar i.warn{background:var(--warnbar)}.mm .bar i.bad{background:var(--bad)}.ro small,.mm small{grid-column:1/-1;font-size:12px;color:var(--text3)}.mach{margin-top:18px}.mm{display:grid;grid-template-columns:minmax(0,1fr) auto;column-gap:12px;padding:8px 0;border-bottom:1px solid var(--line);align-items:baseline}.mm:first-child{border-top:1px solid var(--line)}.mm>span{color:var(--text2)}.mm>b{font-weight:600}.mm>b small{font-size:12px;font-weight:400;color:var(--text3);grid-column:auto}.xl{display:none}.sm{font-size:13px}@media (min-width:1100px){.xl{display:block}.trust{margin-top:6px}}.gb .gr.st{display:block;padding:5px 0}.gb .gr.st .n{display:block;white-space:normal}.gb .gr.st .w{display:block;text-align:left;grid-column:auto}.kv .ks{white-space:normal}.kv .k.wide{grid-column:1/3}.kv .dw{display:block;white-space:normal;line-height:1.3}.item.feed{grid-template-columns:4.2em minmax(0,1fr) auto}.item.feed .tm{white-space:nowrap}.item.feed .w{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}.item.feed .tm{font-size:14px;color:var(--text3)}/* visual-first: cards, tiles and charts */.c-ok{--c:var(--okbar)}.c-warn{--c:var(--warnbar)}.c-bad{--c:var(--bad)}.c-in{--c:var(--in)}.c-out{--c:var(--acc)}.c-vio{--c:var(--vio)}.c-mut{--c:var(--text3)}.hero.ov h1{display:flex;align-items:center;gap:12px;max-width:none}.hd{width:14px;height:14px;border-radius:50%;background:var(--c);flex:none;box-shadow:0 0 0 5px color-mix(in srgb,var(--c) 22%,transparent)}.tiles{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin-top:18px}.tile{display:flex;flex-direction:column;min-width:0;background:var(--card);border:1px solid var(--line);border-radius:16px;padding:12px 12px 10px;color:inherit;position:relative;overflow:hidden}.tile:hover{text-decoration:none;border-color:var(--line2)}.tile.t-warn{box-shadow:inset 0 3px 0 var(--warnbar)}.tile.t-bad{box-shadow:inset 0 3px 0 var(--bad)}.tl{font-size:12px;font-weight:600;color:var(--text2);letter-spacing:.01em}.tv{display:flex;align-items:baseline;flex-wrap:wrap;gap:4px 8px;font-size:30px;font-weight:700;letter-spacing:-.03em;line-height:1.15;margin:2px 0 4px}.tv small{font-size:14px;font-weight:500;color:var(--text3);letter-spacing:0}.tv .unkv{font-size:13px;letter-spacing:0}.okv{color:var(--ok)}.dl{font-size:12px;font-weight:600;letter-spacing:0;padding:1px 7px;border-radius:999px;background:var(--track);color:var(--text2);white-space:nowrap}.dl.up{color:var(--ok);background:color-mix(in srgb,var(--ok) 14%,transparent)}.dl.down{color:var(--warn);background:color-mix(in srgb,var(--warnbar) 16%,transparent)}.ta{font-size:11px;line-height:1.35;color:var(--text3);margin-top:auto;padding-top:6px}.tc{flex-basis:100%;font-size:12px;font-weight:500;letter-spacing:0;color:var(--text3)}.mini b{font-weight:600;color:var(--text)}.tsp.ok .ln{stroke:var(--okbar)}.tsp.ok .ar{fill:var(--okbar)}.tsp.warn .ln{stroke:var(--warnbar)}.tsp.warn .ar{fill:var(--warnbar)}.tsp.bad .ln{stroke:var(--bad)}.tsp.bad .ar{fill:var(--bad)}.gauge+.mini,.tv:has(.gauge)+.mini{margin-top:6px}.mini+.tsp{margin-top:6px}.tsp{display:block;width:100%;height:34px}.tsp .ln{fill:none;stroke-width:2;stroke-linejoin:round}.tsp .ar{stroke:none;opacity:.16}.tsp.out .ln{stroke:var(--acc)}.tsp.out .ar{fill:var(--acc)}.tsp.in .ln{stroke:var(--in)}.tsp.in .ar{fill:var(--in)}.hit{fill:transparent}.donut{width:84px;height:84px;display:block;margin:2px 0}.donut,.gauge{letter-spacing:0}.donut circle{fill:none;stroke-width:4.2;stroke:var(--c)}.donut .tr{stroke:var(--track)}.donut .dc,.gauge .dc{font-size:9px;font-weight:700;fill:var(--text);text-anchor:middle;letter-spacing:-.3px}.donut .ds,.gauge .ds{font-size:4.2px;font-weight:500;letter-spacing:0;fill:var(--text3);text-anchor:middle}.tv:has(.donut),.tv:has(.gauge){margin:0}.gauge{width:110px;height:64px;display:block}.gauge path{fill:none;stroke-width:4.6;stroke-linecap:round;stroke:var(--c)}.gauge .tr{stroke:var(--track)}.gauge .dc{font-size:10px}.mini{display:flex;flex-wrap:wrap;gap:2px 10px;font-size:12px;color:var(--text2)}.mini span{display:inline-flex;align-items:center;gap:5px;white-space:nowrap}.mini i.free{background:none;box-shadow:inset 0 0 0 1.5px var(--line2)}.mini i,.lg i{width:8px;height:8px;border-radius:2px;background:var(--c);display:inline-block;flex:none}.sb{display:flex;gap:2px;height:10px;border-radius:5px;overflow:hidden;margin:4px 0}.sb.big{height:14px;margin:8px 0 6px}.sb i{display:block;min-width:3px;background:var(--c)}.sb i.free,.lg i.free{background:none;box-shadow:inset 0 0 0 1.5px var(--line2)}.s-building{--c:var(--okbar)}.s-validating{--c:var(--in)}.s-finished{--c:var(--acc)}.s-waiting{--c:var(--text3)}.s-decision{--c:var(--warnbar)}.s-blocked{--c:var(--bad)}.k.out{--c:var(--acc)}.k.in{--c:var(--in)}.k.y{opacity:.55}.k.p50{--c:var(--acc)}.k.p85{--c:var(--vio)}.k.ok{--c:var(--okbar)}.k.bad{--c:var(--bad)}.k.mut{--c:var(--text3)}.lg{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:12px;color:var(--text2);margin:2px 0 8px}.lg span{display:inline-flex;align-items:center;gap:6px;white-space:nowrap}.lg .k.y{opacity:1}.lg .k.y i,.lg i.k.y{opacity:.5}.cards{display:grid;gap:12px;margin-top:12px}.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px 14px 12px;min-width:0}.ch{display:flex;justify-content:space-between;align-items:baseline;gap:10px}.ch h3{font-size:16px;font-weight:650;letter-spacing:-.01em;margin:0}.cm{font-size:12px;color:var(--text2);white-space:nowrap}.cw{font-size:11px;color:var(--text3);margin:0 0 10px}.cf{display:grid;grid-template-columns:auto minmax(0,1fr);column-gap:6px}.ya{display:flex;flex-direction:column;justify-content:space-between;height:var(--ch);font-size:11px;color:var(--text3);text-align:right;line-height:1;margin-top:-1px}.pl svg{display:block;width:100%;height:var(--ch);overflow:visible}.xa{display:grid;font-size:11px;color:var(--text3);margin-top:4px}.xa span{text-align:center;white-space:nowrap}.gl{stroke:var(--line);stroke-width:1}.ln{fill:none;stroke-width:2.5;stroke-linejoin:round;stroke-linecap:round}.ln.out{stroke:var(--acc)}.ln.in{stroke:var(--in)}.ln.y{stroke-width:1.6;stroke-dasharray:5 4;opacity:.7}.ln.p50{stroke:var(--acc)}.ln.p85{stroke:var(--vio);stroke-dasharray:6 4}.now{stroke:var(--text3);stroke-width:1;stroke-dasharray:2 3}.b.out{fill:var(--acc)}.b.in{fill:var(--in);opacity:.85}.b.in.fl{fill:none;stroke:var(--in);stroke-width:3}.hbs{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:6px 16px}.hb{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:baseline;color:inherit;padding:4px 0}.hb:hover{text-decoration:none}.hb .hn{font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.hb .hv{font-size:14px;font-weight:700}.hb .hv small{font-size:11px;color:var(--text3);font-weight:500}.hb .sb{grid-column:1/-1;height:8px;margin:3px 0 0}.qb{display:grid;grid-template-columns:6.5em minmax(0,1fr) auto;align-items:center;gap:10px;padding:5px 0}.qn{font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.qt{position:relative;height:10px;border-radius:5px;background:var(--track)}.qt i{position:absolute;inset:0 auto 0 0;border-radius:5px;background:var(--c)}.qt b{position:absolute;top:-3px;bottom:-3px;width:2px;margin-left:-1px;background:var(--tick);opacity:.55;border-radius:1px}.qr{font-size:12px;white-space:nowrap;text-align:right;min-width:6.5em}.qr.warn{font-weight:600}.sps{display:grid}.sp{display:grid;grid-template-columns:4.8em minmax(0,1fr) 3.4em 4.6em;align-items:center;gap:8px;padding:7px 0;border-top:1px solid var(--line);color:inherit}.sp:hover{text-decoration:none;background:var(--track)}.sp.sph{font-size:11px;color:var(--text3);border-top:0;padding-top:0}.sp.sph span:nth-child(n+3){text-align:right}.chip{font-size:11px;font-weight:700;text-align:center;padding:2px 0;border-radius:999px;color:var(--c);background:color-mix(in srgb,var(--c) 17%,transparent);white-space:nowrap}.sp .spw{font-size:13.5px;line-height:1.3;min-width:0}.sp .sn{font-size:15px;text-align:right}.sp .sa{font-size:12px;color:var(--text3);text-align:right;white-space:nowrap}.okn{color:var(--ok)}.card .gl,.card table{margin-top:4px}@media (min-width:600px){ .tiles{grid-template-columns:repeat(3,minmax(0,1fr));gap:12px} .cards{grid-template-columns:repeat(2,minmax(0,1fr));gap:14px} .cards .wide,.cards .wide-m{grid-column:1/-1} .hbs{grid-template-columns:repeat(3,minmax(0,1fr))}}@media (min-width:1100px){ .tiles{grid-template-columns:repeat(6,minmax(0,1fr))} .cards .wide-m{grid-column:auto} .cards .wide-l{grid-column:1/-1} .hbs{grid-template-columns:repeat(4,minmax(0,1fr))}}.xa.xp{position:relative;display:block;height:1.3em}.xa.xp span{position:absolute;transform:translateX(-50%)}.xa.xp span:first-child{transform:none}.xa.xp span:last-child{transform:translateX(-100%)}.mm .bar i.ok{background:var(--okbar)}@media (min-width:600px){.devm{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);column-gap:28px;align-items:start}.devm .mach{margin-top:0}}.sections section{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px 14px 12px}.sections .stack{gap:12px}.sections{gap:12px}.io.out{background:var(--acc)}.io.in{box-shadow:inset 0 0 0 1.5px var(--in)}.legend .sw.f{background:var(--acc)}.legend .sw.o{box-shadow:inset 0 0 0 1.5px var(--in);background:none}@media (min-width:600px){.sections,.sections .stack{gap:14px}}@media (min-width:1100px){.sections{gap:16px}.sections .stack{gap:16px}}'
def page(name, title, body, foot=''):
    nav = ''.join(f'<a href="{u}"{" aria-current=page" if n == name else ""}>{t}</a>' for u, n, t in NAV)
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><meta http-equiv="refresh" content="{MAX_AGE}">
<title>{esc(title)}</title><style>{CSS}</style></head>
<body><div class="shell">
<header class="side"><div class="brand"><b>Fleet</b></div>
<span class="stamp">Built {NOW:%a %d %b}, {BUILT}<!--age--></span><span class="stamp trust">{trust()}</span>
<nav class="nav" aria-label="Pages">{nav}</nav>
<div class="side-foot">Read-only. Each section names what it counts, its window and when its source was read. <a href="measure">How each number is measured</a></div>
</header>
<main>{body}
<footer>{foot}{"" if name == "measure" else '<p><a href="measure">How each number is measured</a></p>'}</footer>
</main></div></body></html>
'''
def unknown_foot(*sources):
    hit = [f'{s}: {r}' for s, r in notes if any(s.startswith(x) for x in sources)]
    return f'<p>Unknown now: {esc("; ".join(hit))}.</p>' if hit else ''

# --- overview ------------------------------------------------------------
def ask_rows():
    if not asks_known: return f'<p class="lede">{unknown("the ask list is unreadable")}</p>'
    if not asks: return ''
    rs = []
    for fields, age in asks:
        if age is None: rs.append(item('bad', 'Ask record needs correction', '', ''))
        else: rs.append(item('warn', link(fields[2], fields[3]), esc(dur(age))))
    return f'<div class="rows asks">{"".join(rs)}</div>'
def busy_split():  # leads + Main + workers (+ other), always summing to the busy total
    return ' + '.join(f'{BUSY[r]} Main' if r == 'main' else plural(BUSY[r], r) for r, n in ROLES if BUSY[r] or r != 'other')
def index_body(group):
    n_asks = len(asks)
    h1 = 'Nothing needs you.' if asks_known and not asks else f'{plural(n_asks, "thing")} {"needs" if n_asks == 1 else "need"} you.' if asks_known else 'Ask list unknown.'
    tone = 'ok' if asks_known and not asks else 'warn' if asks_known else 'mut'
    return f'''
<div class="hero ov">
<h1><span class="hd c-{tone}"></span>{h1}</h1>
{ask_rows()}
</div>
<div class="cards">
{card("Slow spots", f"now {BUILT}", spot_table(), "wide-m")}
{card("Lanes by what to do", f"every open lane · now {BUILT}",  switch(group) + lanes_list(group, strip=False), "wide", ("backlog#lanes", "Every lane"))}
<section class="card wide" id="devices"><div class="ch"><h3>Devices and machine</h3></div><p class="cw">now {BUILT}</p><div class="devm"><div>{devices_list(group)}</div><div class="mach">{machine_rows}</div></div></section>
<section class="card wide" id="homes"><div class="ch"><h3>Homes</h3><a class="cm" href="backlog">Backlog →</a></div><p class="cw">lanes and backlog now {BUILT}</p>{homes_table}</section>
</div>
'''

# --- backlog -------------------------------------------------------------
def backlog_body(group):
    if QUEUE is None:
        eq = f'<p class="lede">{unknown("; ".join(r for s, r in notes if s == "backlog"))}</p>'
        queued = ''
    else:
        total = sum(QUEUE.values())
        eq = (f'<div class="eq"><div><span>Queued</span><b>{total}</b></div><span class="op">=</span><div><span>Ready</span><b>{QUEUE["ready"]}</b></div>'
              f'<span class="op">+</span><div><span>Held</span><b>{QUEUE["held"]}</b></div><span class="op">+</span><div><span>Waiting on another item</span><b>{QUEUE["waiting"]}</b></div></div>'
              f'<p class="note">In flight: {sum(len(bl(h, state="in_flight")) for h in ACTIVE)} items, counted apart from the queue. Held for the captain: {len(held_cap)}.</p>')
        CL = (('ready', 'Ready to start'), ('held', 'Held'), ('waiting', 'Waiting on another item'))
        if group == 'home':
            gs = [(hname(h), len([r for r in backlog[h] if r['class']]),
                   ''.join(grow(esc(n), '', len(bl(h, c))) for c, n in CL if bl(h, c)), '', None, False)
                  for h in sorted(ACTIVE, key=lambda h: (-len([r for r in backlog[h] if r['class']]), h)) if any(r['class'] for r in backlog[h])]
        else:
            gs = [(n, QUEUE[c], ''.join(grow(esc(hname(h)), '', len(bl(h, c))) for h in sorted(ACTIVE, key=lambda h: (-len(bl(h, c)), h)) if bl(h, c)), '', None, c == 'ready')
                  for c, n in CL]
        queued = glist(gs, 'Queued', total)
    def held_row(h, r):
        return item('', esc(r['title']), esc(hname(h)), esc(r.get('hold_reason') if r.get('hold_reason') not in (None, '-') else 'no reason recorded'),
                    tm=days_old(r['day']) if r['day'] else '?')
    if group == 'home':
        hs = sorted({h for h, _ in held_cap}, key=lambda h: (-sum(x == h for x, _ in held_cap), h))
        hgroups = [(hname(h), sum(x == h for x, _ in held_cap), ''.join(held_row(x, r) for x, r in held_cap if x == h), '', None, True) for h in hs]
    else:
        band = lambda r: 'Over 3 days' if r['day'] and (TODAY - r['day']).days > 3 else '1 to 3 days' if r['day'] and (TODAY - r['day']).days >= 1 else 'Today or unknown'
        hgroups = [(b, sum(band(r) == b for _, r in held_cap), ''.join(held_row(h, r) for h, r in held_cap if band(r) == b), '', None, True)
                   for b in ('Over 3 days', '1 to 3 days', 'Today or unknown') if any(band(r) == b for _, r in held_cap)]
    held = (glist(hgroups, 'Held for the captain') if held_cap else '<p class="note">No item is held for the captain in any home record.</p>' if bl_known else '')
    unread = [hname(h) for h in ACTIVE if backlog.get(h) is None]
    held_h2 = (f'{plural(len(held_cap), "item")} held' + (f'; oldest {days_old(held_cap[0][1]["day"])}' if held_cap and held_cap[0][1]['day'] else '') + '. Main must triage them.'
               if bl_known else f'At least {plural(len(held_cap), "item")} held; the backlog of {", ".join(unread)} is unknown.')
    val = [l for l in live if l['state'] == 'validating']
    oldest_val = min(val, key=lambda l: l['since']) if val else None
    ltrows = ''.join(f'<tr><td>{esc(hname(h))}</td><td>{len(by_home[h])}</td><td>{plan(h)}</td><td>{len(bl(h, "ready")) if backlog.get(h) is not None else "–"}</td></tr>'
                     for h in ACTIVE)
    raised = ', '.join(f'{hname(h)} {plan(h)}' for h in ACTIVE if plan(h) != lane_default)
    if group == 'home':
        ag = [(hname(h) if h else 'Not matched to a home', sum(1 for a in agent_rows if a[1] == h and a[3] == 'working'),
               ''.join(grow(esc(n), esc(f'{dict(ROLES)[r]} · {s}')) for r, hh, n, s in sorted(agent_rows, key=lambda a: (a[3] != 'working', a[2])) if hh == h), '', None, False)
              for h in sorted({a[1] for a in agent_rows}, key=lambda h: (h is None, h != 'main', h or ''))]
    else:
        ag = [(n.capitalize() if r != 'main' else 'Main', BUSY[r], ''.join(grow(esc(nm), esc(f'{hname(hh) if hh else "no home"} · {s}')) for rr, hh, nm, s in sorted(agent_rows, key=lambda a: (a[3] != 'working', a[2])) if rr == r), '', None, False)
              for r, n in ROLES if any(a[0] == r for a in agent_rows)]
    agents_html = (glist(ag, 'Busy now', sum(BUSY.values())) + f'<p class="note">Busy means working now in Herdr; the groups list all {len(agent_rows)} running agents, busy first.</p>'
                   if agents is not None else f'<p class="lede">{unknown(why_of("herdr"))}</p>')
    return f'''
<div class="hero">
{sh(f"Backlog · read {BUILT} from each home's backlog")}
<h1>{QUEUE["ready"] if QUEUE else "–"} items ready to start; {SPLIT["building"]} of {OPEN} open lanes building.</h1>
{switch(group)}
</div>
<div class="sections">
<section class="wide">
{sh(f"Fleet totals · now {BUILT}")}
{eq}
{PARKED_LINE}
</section>
<div class="stack">
<section id="held">
{sh("Held for the captain · in home records, oldest first")}
<h2>{held_h2}</h2>
{held}
</section>
<section>
{sh(f"Queued work · now {BUILT}")}
<h2>{"Queued work unknown." if QUEUE is None else f"{sum(QUEUE.values())} queued."}</h2>
{queued}
</section>
<section id="agents">
{sh(f"Agents · Herdr, now {BUILT}")}
<h2>{f"{sum(BUSY.values())} busy: {busy_split()}." if agents is not None else "Agents unknown."}</h2>
{agents_html}
</section>
</div>
<div class="stack">
<section id="lanes">
{sh(f"Every lane · now {BUILT} · age since its last status")}
<h2>{plural(OPEN, "lane")} open; {SPLIT["blocked"] + SPLIT["decision"]} blocked or waiting.</h2>
{lanes_list(group, names=True)}
<p class="note">Oldest validation or CI wait: {f"{dur(NOW_TS - oldest_val['since'])} ({esc(oldest_val['task'])}, {esc(hname(oldest_val['home']))})" if oldest_val else "none running"}.</p>
</section>
<section id="targets">
{sh("Lane plan · lane settings")}
<h2>Lane settings plan {PLAN} lanes; {OPEN} are open.</h2>
<table><thead><tr><th>Home</th><th>Open</th><th>Plan</th><th>Ready</th></tr></thead><tbody>{ltrows}</tbody>
<tfoot><tr><td>Fleet</td><td>{OPEN}</td><td>{PLAN}</td><td>{QUEUE["ready"] if QUEUE else "–"}</td></tr></tfoot></table>
<p class="note">Plan per home from config/lane-caps{f" ({esc(raised)})" if raised else ""}; every other home {lane_default}, from config/lane-target.</p>
</section>
</div>
</div>
'''

# --- method --------------------------------------------------------------
def measure_body():
    cycles = [
        ('Every page', f'rebuilt every {MAX_AGE} s by the page server', BUILT),
        ('Lanes, backlog, agents, devices, machine', 'read at every build', BUILT),
        ('Fleet retro', 'no schedule in any record this page reads', '–'),
    ]
    crow = ''.join(f'<tr><td>{esc(n)}<div class="mut sm">{esc(how)}</div></td><td class="nw">{esc(last)}</td></tr>' for n, how, last in cycles)
    off = NOW.strftime('%z')
    windows = [('Today', f'since local midnight (UTC{off[:3]}:{off[3:]})'), ('Yesterday', 'the full local day before'),
               ('Lane plan', f'{lane_default} lanes per home from config/lane-target; config/lane-caps overrides ({PLAN} in all)'),
               ('Ages', "a lane's last status time; a held item's filing day"),
               ('Parked homes', 'left out of every total' + (f': {", ".join(PARKED)}' if PARKED else ''))]
    wrow = ''.join(f'<tr><td>{esc(n)}</td><td class="l">{esc(w)}</td></tr>' for n, w in windows)
    rrow = ''.join(item('warn', esc(t), '', esc(w)) for t, w in records) or '<p class="note">No two records disagree.</p>'
    urow = ''.join(item('warn', esc(s), '', esc(r)) for s, r in notes) or '<p class="note">Every source was read.</p>'
    return f'''
<div class="hero">
{sh(f"Method · read from the code and config at {BUILT}")}
<h1>How each number is measured.</h1>
<p class="lede">Each source runs on its own cycle, so every section names its own time. A source that cannot be read shows unknown and why, never a guess or a zero.</p>
</div>
<div class="sections">
<section>
{sh("Cycles")}
<h2>The pages rebuild every {MAX_AGE} s.</h2>
<table class="tt"><thead><tr><th>Number · how often</th><th>Last</th></tr></thead><tbody>{crow}</tbody></table>
</section>
<section>
{sh("Windows")}
<h2>Today starts at local midnight.</h2>
<table class="tt"><thead><tr><th>Number</th><th class="l">Window</th></tr></thead><tbody>{wrow}</tbody></table>
</section>
<section id="records" class="wide">
{sh("Records that disagree")}
<h2>{plural(len(records), "place")} where two records give different answers.</h2>
<div class="rows">{rrow}</div>
</section>
<section id="unknown" class="wide">
{sh("Sources not read")}
<h2>{plural(len(notes), "source")} could not be read.</h2>
<div class="rows">{urow}</div>
</section>
</div>
'''

# The pages, rendered after every source so each shell shows the full trust line.
pages = {'index.html': page('index', 'Fleet', index_body('action'), unknown_foot('backlog', 'herdr')),
         'index.home.html': page('index', 'Fleet', index_body('home'), unknown_foot('backlog', 'herdr')),
         'backlog.html': page('backlog', 'Fleet backlog', backlog_body('action'), unknown_foot('backlog', 'herdr', 'lane')),
         'backlog.home.html': page('backlog', 'Fleet backlog', backlog_body('home'), unknown_foot('backlog', 'herdr', 'lane')),
         'measure.html': page('measure', 'Fleet method', measure_body())}
for f, doc in pages.items():
    with open(os.path.join(OUT, f), 'w', encoding='utf-8') as fh: fh.write(doc)
PY
# The index lands last, so its time is the time the whole set was built.
for f in "$tmp"/*.html; do
  [ "$(basename "$f")" = index.html ] && continue
  mv -f "$f" "$out_dir/" || { echo "fm-dashboard: cannot write $out_dir/$(basename "$f")" >&2; exit 1; }
done
mv -f "$tmp/index.html" "$page" || { echo "fm-dashboard: cannot write $page" >&2; exit 1; }
printf '%s\n' "$page"
