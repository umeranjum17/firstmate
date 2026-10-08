import os, json, subprocess, tempfile, time, hashlib, shutil
from pathlib import Path
root = Path.cwd()
evidence = Path('/home/umer/.no-mistakes/evidence/01M4D51MZR6JHF01352HTED463')
lab = Path(tempfile.mkdtemp(prefix='.flow-validation-', dir=root))
transcript = []
env = {k:v for k,v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE')) and k != 'TASKS_AXI_BACKEND'}
env.update(FM_HOME=str(lab), TMPDIR=str(lab))
def run(script, *args):
    cmd = ['bash', str(root/'bin'/script), *args]
    p = subprocess.run(cmd, env=env, text=True, capture_output=True, timeout=30)
    transcript.append('$ ' + ' '.join(cmd) + '\n' + p.stdout + p.stderr + '\nexit=' + str(p.returncode))
    assert p.returncode == 0, transcript[-1]
    return p.stdout

def snapshot(name, now=None, checks=False):
    args = ['--json'] + (['--now', str(now)] if now is not None else []) + (['--checks'] if checks else [])
    data = run('fm-flow.sh', *args)
    (evidence/(name+'.json')).write_text(data)
    return json.loads(data)

def status(task, verb, text, key=None, epoch=True):
    ts = int(time.time())
    line = verb + (f' [at={ts}]' if epoch else '') + (f' [key={key}]' if key else '') + ': ' + text + '\n'
    with (lab/'state'/(task+'.status')).open('a') as f: f.write(line)
    transcript.append('worker status append: '+line.strip())
    run('fm-fleet-ledger.sh', 'appended', str(lab/'config'), str(lab/'state'/(task+'.status')))
    return ts

def hashes():
    return {str(p.relative_to(lab)): hashlib.sha256(p.read_bytes()).hexdigest() for p in lab.rglob('*') if p.is_file()}
try:
    for d in ('config', 'data', 'state'): (lab/d).mkdir()
    (lab/'config/fleet-ledger').touch()
    # Task inputs use the documented home-addressed consumer, never a copied backlog.
    run('fm-tasks-axi.sh', 'add', 'prerequisite', 'Prerequisite')
    run('fm-tasks-axi.sh', 'add', 'dependent', 'Depends on prerequisite', '--blocked-by', 'prerequisite')
    run('fm-tasks-axi.sh', 'add', 'held', 'Needs captain approval')
    run('fm-tasks-axi.sh', 'hold', 'held', '--reason', 'Wait for approval', '--kind', 'captain')
    queued = snapshot('queue-before')
    reasons = {q['task']:q['why'] for q in queued['queue']}
    assert reasons['dependent'] == 'dependency: prerequisite' and reasons['held'] == 'hold: Wait for approval'
    run('fm-tasks-axi.sh', 'done', 'prerequisite', '--keep', '0')
    archived = snapshot('queue-after-archive')
    assert next(q for q in archived['queue'] if q['task']=='dependent')['why'] == 'unknown: dispatch admission not recorded'
    assert (lab/'data/done-archive.md').is_file()
    # Record a new lifecycle through the real public writer; this is not a worker launch/merge proof.
    run('fm-fleet-ledger.sh', 'dispatched', 'lifecycle', 'ship', 'validation', 'claude', '')
    status('lifecycle', 'working', 'building')
    time.sleep(1.1)
    run('fm-fleet-ledger.sh', 'pr_ready', 'lifecycle', 'https://github.com/umeranjum17/firstmate/pull/26')
    run('fm-fleet-ledger.sh', 'merged', 'lifecycle', 'local')
    time.sleep(1.1)
    run('fm-fleet-ledger.sh', 'cleaned_up', 'lifecycle')
    lifecycle = snapshot('recorded-lifecycle')
    lane = next(l for l in lifecycle['lanes'] if l['task']=='lifecycle')
    t = lane['times']
    assert lane['durations']['time_to_merge'] == t['merged']-t['dispatched'] >= 1
    assert lane['durations']['merge_to_cleanup'] == t['cleaned_up']-t['merged'] >= 1
    assert t['pr_opened'] is None and t['checks_green'] is None
    assert lifecycle['time_to_merge']['known'] == 1
    assert lifecycle['time_to_merge']['median_seconds'] == lifecycle['time_to_merge']['p85_seconds'] == lane['durations']['time_to_merge']
    before = hashes(); fixed_now = int(time.time())
    one = run('fm-flow.sh', '--json', '--now', str(fixed_now))
    two = run('fm-flow.sh', '--json', '--now', str(fixed_now))
    assert one == two and hashes() == before
    # Active inventory is a task-private manual input, not a launched agent.
    (lab/'state/wait.meta').write_text('kind=ship\n')
    status('wait', 'blocked', 'waiting for login', 'a')
    status('wait', 'resolved', '[key=a] login restored')
    resolved = snapshot('note-key-resolved')
    assert next(l for l in resolved['lanes'] if l['task']=='wait')['open_waits'] == []
    status('wait', 'blocked', 'waiting for login', 'a')
    status('wait', 'blocked', '[key=a] waiting for memory gate')
    time.sleep(2.1)
    status('wait', 'blocked', 'waiting for memory gate', 'unstamped', epoch=False)
    status('wait', 'blocked', 'waiting for merge', 'merge')
    status('wait', 'paused', 'waiting for memory gate')
    mixed = snapshot('open-waits')
    mem = next(b for b in mixed['bottlenecks'] if b['cause']=='memory_gate')
    item = mem['items'][0]
    assert mixed['bottlenecks'][0]['cause'] == 'memory_gate'
    assert item['seconds'] is None and item['known_seconds'] >= 2 and item['unknown_waits'] == 1
    assert mem['unknown_items'] == 1 and mem['additive'] is False and item['overlap'] is True
    assert {w['cause'] for w in next(l for l in mixed['lanes'] if l['task']=='wait')['open_waits']} == {'memory_gate','review_merge'}
    status('wait', 'working', 'resumed')
    resumed = snapshot('pause-ended')
    assert all(w['key'] is not None for w in next(l for l in resumed['lanes'] if l['task']=='wait')['open_waits'])
    # Real public forge query, recorded current head; never create or modify a PR.
    pr = subprocess.run(['gh-axi','api','/repos/umeranjum17/firstmate/pulls/26','--jq','{head: .head.sha}|tojson','--full'], text=True, capture_output=True, timeout=15)
    transcript.append('$ gh-axi api /repos/umeranjum17/firstmate/pulls/26 --jq {head:.head.sha}|tojson --full\n'+pr.stdout+pr.stderr)
    assert pr.returncode == 0
    head = next(line.split(': ',1)[1].strip('"') for line in pr.stdout.splitlines() if line.startswith('head: '))
    (lab/'state/wait.meta').write_text(f'kind=ship\npr=https://github.com/umeranjum17/firstmate/pull/26\npr_head={head}\n')
    checked = snapshot('live-forge-checks', checks=True)
    ci = next(l for l in checked['lanes'] if l['task']=='wait')['ci']
    assert ci is not None and ci['head']==head and ci['total']==ci['returned']
    (lab/'state/wait.meta').write_text('kind=ship\npr=https://github.com/umeranjum17/firstmate/pull/26\npr_head='+'0'*40+'\n')
    stale = snapshot('stale-head-rejected', checks=True)
    assert next(l for l in stale['lanes'] if l['task']=='wait')['ci'] is None
    assert any('differs' in n['reason'] for n in stale['limitations'])
    # Remote paths intentionally alias an existing local home: must not collect it.
    (lab/'data/secondmates.md').write_text(f'- macbook - Remote (host: macbook; root: /remote/repo; home: {lab}; scope: app; projects: app)\n')
    remote = snapshot('remote-coverage')
    assert 'macbook' in remote['homes'] and not any(l['home']=='macbook' for l in remote['lanes'])
    assert any(n['source']=='macbook' and 'unknown' in n['reason'] for n in remote['limitations'])
    (lab/'.tasks.toml').write_text('backend = "beads"\n[beads]\npath = ".beads"\nbin = "./unavailable-bd"\nprefix = "flow"\n')
    before = hashes()
    unavailable = snapshot('backend-unavailable')
    assert unavailable['queue'] == [] and hashes() == before
    assert any(n['source']=='main/backlog' and n['reason'].startswith('unknown:') for n in unavailable['limitations'])
    transcript.append('All assertions passed. No harness launch, actual branch merge, or dashboard rendering was attempted.')
finally:
    (evidence/'cli-transcript.log').write_text('\n\n'.join(transcript)+'\n')
    shutil.rmtree(lab)
