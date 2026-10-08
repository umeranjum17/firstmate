import json, os, pathlib, subprocess, sys, time, urllib.request, urllib.error
from html.parser import HTMLParser
root = pathlib.Path(sys.argv[1]); home = root / '.dashboard-validation/home'
evidence = pathlib.Path('/home/umer/.no-mistakes/evidence/01M4CT4VSY7GX5EKERSEYBBPJ5')
url = (root / '.dashboard-validation/server.log').read_text().splitlines()[0].split()[1]
env = dict(os.environ, FM_HOME=str(home), HOME=str(home), PATH=str(root / '.dashboard-validation/path'), ANDROID_HOME=str(home / 'no-sdk'), ANDROID_SDK_ROOT=str(home / 'no-sdk'), FM_DEVICE_LOCK_DIR=str(home / 'locks'))
for key in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TASKS_AXI_FILE','TASKS_AXI_BACKEND'): env.pop(key, None)
class Text(HTMLParser):
    def __init__(self): super().__init__(); self.parts=[]; self.ignore=0
    def handle_starttag(self,t,a):
        if t in ('style','script'): self.ignore+=1
    def handle_endtag(self,t):
        if t in ('style','script'): self.ignore-=1
    def handle_data(self,s):
        if not self.ignore: self.parts.append(s)
def page(route, cookie=None):
    req=urllib.request.Request(url+route, headers={'Cookie': cookie} if cookie else {})
    with urllib.request.urlopen(req) as r: data=r.read(); headers=dict(r.headers)
    if route=='data.json': return json.loads(data),headers
    p=Text(); p.feed(data.decode()); return ' '.join(' '.join(p.parts).split()),headers
log=[]
def note(s): print(s,flush=True); log.append(s)
def save_json(name,d): (evidence/name).write_text(json.dumps(d,indent=2)+'\n')
data,headers=page('data.json')
assert headers['Content-Type']=='application/json'
assert data['metrics']['held_for_captain']['value']==2
assert data['metrics']['queue']['value']=={'ready':1,'held':3,'waiting':0}
assert len(data['held_items'])==3
assert any(r['home']=='main' and r['title']=='Main release approval' for r in data['held_items'])
assert any(r['home']=='lead' and r['title']=='Lead release approval' for r in data['held_items'])
for route in ('','backlog','backlog?group=home'):
    text,h=page(route)
    if route: 
        for value in ('Main release approval','Lead release approval','Approve evidence=main-release.json','Choose lead rollout','waiting for vendor credentials','3 items held'):
            assert value in text,(route,value)
    else:
        assert '1 thing needs you.' in text and 'Choose rollout window' in text
        assert '2 held for triage' in text and 'Captain calls and queued holds' in text
    assert '/home/u/x/' not in text
text,h=page('backlog?group=home'); assert 'fm_group=home' in h['Set-Cookie']
text,_=page('backlog', 'fm_group=home'); assert '2 + 1 = 3' in text
text,_=page('measure'); assert 'data.json contains the same readings' in text and 'Window' in text and 'cutoff' in json.dumps(data)
for metric in data['metrics'].values():
    assert metric['status'] in ('exact','lower_bound','unknown')
    assert all(k in metric for k in ('value','source','window','cutoff','read_at'))
    if metric['status']=='unknown': assert metric['reason']
head=urllib.request.urlopen(urllib.request.Request(url+'data.json',method='HEAD'))
assert head.status==200 and head.headers['Content-Type']=='application/json' and head.read()==b''
for route in ('unknown','../data/backlog.md'):
    try: urllib.request.urlopen(url+route)
    except urllib.error.HTTPError as e: assert e.code==404
    else: raise AssertionError('unexpected public path: '+route)
save_json('live-data.json',data)
note('Same task ID release held independently in Main and lead: both titles/reasons survive in action/home HTML and JSON; captain count 2, total held 3, queue 4; ask list remains Main-only.')
note('GET/HEAD data.json: application/json, coverage/source/window/cutoff/read_at present; home-group cookie persists; unrecognized/private paths return 404.')
# Perform a genuine task close and let the running server refresh without requesting a build.
r=subprocess.run(['bash',str(root/'bin/fm-tasks-axi.sh'),'done','ready','--no-prune','--json'],env=env,check=True,capture_output=True,text=True)
(evidence/'live-close.json').write_text(r.stdout)
deadline=time.monotonic()+75
while True:
    after,_=page('data.json')
    if after['metrics']['closed']['value']==1 and after['metrics']['ready']['value']==0: break
    assert time.monotonic()<deadline,'server failed to rebuild after closing a task'
    time.sleep(.5)
assert after['metrics']['filed']['value']==3
assert sum(x['value'] for x in after['metrics']['closed']['daily'])==1
text,_=page(''); assert '0 ready' not in text or after['metrics']['ready']['value']==0
save_json('live-after-close.json',after)
note('Closing ready through fm-tasks-axi.sh done updates the unattended server: ready 1→0, closed 0→1, observed filings retained at least 3, chart daily out total 1.')
# Remove only the disposable lead's record directory: it is missing, not an empty home.
(home/'mates/lead/state').rename(home/'mates/lead/state.saved')
subprocess.run(['bash',str(root/'bin/fm-dashboard.sh'),'build'],env=env,check=True,capture_output=True)
missing,_=page('data.json')
assert missing['metrics']['lanes']['status']=='lower_bound'
assert missing['metrics']['free_lanes']['status']=='unknown' and missing['metrics']['free_lanes']['value'] is None
assert missing['metrics']['lanes']['value']==1
text,_=page(''); assert 'All flowing' not in text and 'free unknown' in text
text,_=page('measure'); assert 'lanes' in text and 'lead:' in text
save_json('live-missing-lanes.json',missing)
note('Missing lead lane directory: fleet observed lane count is lower_bound 1, free capacity null/unknown, source failure is listed, and no All flowing reassurance appears.')
(evidence/'live-results.log').write_text('\n'.join(log)+'\n')
