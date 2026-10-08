import os, json, subprocess, time, hashlib, shutil
from pathlib import Path
root = Path.cwd()
evidence = Path('/home/umer/.no-mistakes/evidence/01M4D2EP948XPJ7HJFPB6DCMTN')
lab = root / '.flow-live'
lab.mkdir()
env = dict(os.environ, HOME=str(lab / 'user'), XDG_CONFIG_HOME=str(lab / 'xdg'))
for k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TASKS_AXI_BACKEND','TASKS_AXI_FILE'):
    env.pop(k, None)
main, child = lab / 'main', lab / 'child'
for home in (main, child):
    for part in ('state','data','config'):
        (home / part).mkdir(parents=True)
    (home / 'data/backlog.md').write_text('## Queued\n')
    (home / 'config/fleet-ledger').touch()
(lab / 'user').mkdir()
(lab / 'xdg').mkdir()
env['FM_HOME'] = str(main)
def cli(script, *args, home=main):
    return subprocess.check_output(['bash',str(root/'bin'/script),*args],env=dict(env,FM_HOME=str(home)),text=True)
def fingerprint():
    return {str(p.relative_to(lab)): hashlib.sha256(p.read_bytes()).hexdigest() for p in lab.rglob('*') if p.is_file()}
def observe(label, now):
    before=fingerprint()
    a=cli('fm-flow.sh','--json','--now',str(now))
    assert a == cli('fm-flow.sh','--json','--now',str(now))
    assert before == fingerprint(), 'reader changed home files'
    (evidence/(label+'.json')).write_text(a)
    return json.loads(a)
def status(task, lines):
    (child/'state'/f'{task}.meta').write_text('kind=ship\n')
    (child/'state'/f'{task}.status').write_text(lines)
try:
    (main/'data/secondmates.md').write_text(f'- child - Worker (home: {child}; scope: app; projects: app)\n- macbook - Remote (host: macbook; root: /remote/repo; home: {child}; scope: app; projects: app)\n')
    (child/'data/secondmates.md').write_text(f'- main - Parent (home: {main}; scope: fleet; projects: app)\n')
    (main/'config/fm-flow-check.sh').write_text("clock = 30 if L['verb'] == 'needs-decision' else 50\n")
    # Run the real producer with wall-clock timestamps, not a fabricated ledger.
    cli('fm-fleet-ledger.sh','dispatched','delivered','ship','app','manual','none',home=child)
    status('delivered', f'working [at={int(time.time())}]: implementing\n')
    cli('fm-fleet-ledger.sh','appended',str(child/'config'),str(child/'state/delivered.status'),home=child)
    time.sleep(1.1)
    cli('fm-fleet-ledger.sh','pr_ready','delivered','https://github.com/example/app/pull/1',home=child)
    cli('fm-fleet-ledger.sh','merged','delivered','local',home=child)
    cli('fm-fleet-ledger.sh','cleaned_up','delivered',home=child)
    (child/'state/delivered.meta').unlink()
    (child/'state/delivered.status').unlink()
    now=int(time.time())
    status('mixed', f'blocked [at={now-90}] [key=a]: fm-mem-gate: waiting (free 1 GB)\nblocked [at={now-70}]: [key=b] waiting for memory gate\nblocked [key=c]: waiting for memory gate\nblocked [at={now-10}] [key=m]: waiting for merge\n')
    status('smallmerge', f'blocked [at={now-10}] [key=m]: waiting for merge\n')
    status('reopen', f'blocked [at={now-90}] [key=a]: waiting for login\nblocked [at={now-80}]: [key=a] waiting for merge\n')
    status('closedkey', f'blocked [at={now-90}] [key=a]: waiting for login\nresolved [at={now-80}]: [key=a] login restored\n')
    status('pause', f'paused [at={now-90}]: waiting for login\npaused [at={now-80}]: waiting for memory gate\n')
    (main/'data/backlog.md').write_text('## Queued\n- [ ] ready - Next blocked-by: archived\n- [ ] blocked - Next blocked-by: archived blocked-by: prior\n## In flight\n- [ ] prior - Prerequisite\n')
    (main/'data/done-archive.md').write_text('## Done\n- [x] archived - Completed\n')
    x=observe('flow-live',now)
    rows={l['task']:l for l in x['lanes']}
    delivered=rows['delivered']
    assert delivered['durations']['time_to_merge'] >= 1
    assert delivered['durations']['time_to_merge'] == delivered['times']['merged'] - delivered['times']['dispatched']
    assert x['time_to_merge']['median_seconds'] == delivered['durations']['time_to_merge']
    assert delivered['times']['pr_opened'] is None and delivered['times']['checks_green'] is None
    assert rows['closedkey']['open_waits'] == []
    assert rows['reopen']['open_waits'][0]['cause']=='review_merge' and rows['reopen']['open_waits'][0]['seconds']==80
    assert rows['pause']['open_waits'][0]['seconds']==80 and rows['pause']['open_waits'][0]['key'] is None
    assert x['bottlenecks'][0]['cause']=='memory_gate'
    item=next(i for i in x['bottlenecks'][0]['items'] if i['task']=='mixed')
    assert item['seconds'] is None and item['known_seconds']==90 and item['unknown_waits']==1 and item['overlap']
    assert x['bottlenecks'][0]['unknown_items']==1 and x['bottlenecks'][0]['additive'] is False
    assert {q['task']:q['why'] for q in x['queue']} == {'ready':'unknown: dispatch admission not recorded','blocked':'dependency: prior'}
    assert 'macbook' in x['homes'] and not any(l['home']=='macbook' for l in x['lanes'])
    assert any(n['source']=='macbook' and 'unknown' in n['reason'] for n in x['limitations'])
    # Capture real status producer output then switch to retained-record projection.
    cli('fm-fleet-ledger.sh','capture',home=child)
    for p in (child/'state').glob('*.status'): p.unlink()
    captured=observe('flow-captured',int(time.time()))
    cr={l['task']:l for l in captured['lanes']}
    assert cr['closedkey']['open_waits']==[] and cr['reopen']['open_waits'][0]['cause']=='review_merge'
    assert cr['pause']['open_waits'][0]['key'] is None and cr['pause']['open_waits'][0]['cause']=='memory_gate'
    (child/'data/backlog.md').unlink()
    missing=observe('flow-missing-backlog',int(time.time()))
    assert any(n['source']=='child/backlog' and n['reason'].startswith('unknown:') for n in missing['limitations'])
    (child/'.tasks.toml').write_text('backend = "beads"\n[beads]\npath = ".beads"\nbin = "./unavailable-bd"\nprefix = "flow"\n')
    (child/'data/backlog.md').write_text('## Queued\n- [ ] stale - Obsolete markdown\n')
    alternate=observe('flow-unavailable-backend',int(time.time()))
    assert not any(q['home']=='child' for q in alternate['queue'])
    assert any(n['source']=='child/backlog' and n['reason'].startswith('unknown:') for n in alternate['limitations'])
    (evidence/'producer-ledger.jsonl').write_bytes((child/'state/fleet-ledger.jsonl').read_bytes())
    print('Real CLI: live ledger producer lifecycle, emitted and captured waits, lower-bound ranking, archived dependency, remote coverage, unavailable backend, deterministic read-only snapshots passed. No worker, Herdr, or dashboard launched.')
finally:
    shutil.rmtree(lab)
