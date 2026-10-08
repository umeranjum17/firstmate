#!/usr/bin/env python3
"""Run the actual guard CLI on kernel measurements and task-private processes.
The ownership probe filters /proc with symlinks to real kernel entries: no
fabricated memory readings, process status, cwd, or environment files.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path.cwd()
GUARD = ROOT / 'bin/fm-jev-mem-guard.sh'
EVIDENCE = Path('/home/umer/.no-mistakes/evidence/01M4D8J6Y6KAAA7DQBH50JCH1S')
env = dict(os.environ)
for key in ('FM_HOST_MEMORY_PROC', 'FM_HOST_MEMORY_CGROUP_ROOT', 'PYTHONPATH'):
    env.pop(key, None)
transcript = []

def call(*args, extra=None, expected=0):
    runenv = env | (extra or {})
    p = subprocess.run([str(GUARD), *map(str, args)], env=runenv, text=True, capture_output=True, timeout=15)
    row = {'argv': ['bin/fm-jev-mem-guard.sh', *map(str, args)],
           'environment': extra or {}, 'exit': p.returncode,
           'stdout': p.stdout.rstrip('\n'), 'stderr': p.stderr.rstrip('\n')}
    transcript.append(row)
    assert p.returncode == expected, row
    return p.stdout.rstrip('\n')

processes = []
try:
    with tempfile.TemporaryDirectory(prefix='live-memory-', dir=ROOT / '.test-memory-tmp') as tmp:
        home = Path(tmp)
        state = home / 'state'
        state.mkdir()
        sample = state / 'host-memory.tsv'
        out = call('--record', sample)
        assert out.split('\t')[0] in ('OK', 'WAIT', 'ALERT'), out
        fields = sample.read_text().strip().split('\t')
        assert len(fields) == 5 and fields[0].isdigit() and int(fields[1]) > 0
        transcript.append({'persisted_sample': fields})

        # Only change the documented thresholds; never induce host pressure.
        healthy = home / 'healthy.conf'
        healthy.write_text('wait_pressure=100000\nalert_pressure=100000\nwait_available_gb=0\nalert_available_gb=0\n')
        wait = home / 'wait.conf'
        wait.write_text('wait_pressure=0\nalert_pressure=100000\nwait_available_gb=0\nalert_available_gb=0\n')
        alert = home / 'alert.conf'
        alert.write_text('alert_pressure=0\nalert_available_gb=0\n')
        for config, level in ((wait, 'WAIT'), (alert, 'ALERT')):
            out = call('--config', config, '--record', sample)
            assert out.startswith(level + '\t'), out
            call('--config', config, '--admit', 'private-build', '--state', state, expected=1)
            refusal = (state / 'admission-refused').read_text().strip().split('\t')
            assert len(refusal) == 3 and refusal[0].isdigit() and refusal[1] == 'private-build'
            transcript.append({'persisted_refusal': refusal})
        parallel = [subprocess.Popen([str(GUARD), '--config', str(wait), '--admit', task, '--state', str(state)],
                                     env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    for task in ('parallel-a', 'parallel-b')]
        for p in parallel:
            stdout, stderr = p.communicate(timeout=15)
            transcript.append({'parallel_admission_exit': p.returncode, 'stdout': stdout.strip(), 'stderr': stderr.strip()})
            assert p.returncode == 1 and not stderr
        row = (state / 'admission-refused').read_text().strip().split('\t')
        assert len(row) == 3 and row[1] in ('parallel-a', 'parallel-b')
        assert not list(state.glob('.admission-refused.*'))
        transcript.append({'parallel_persisted_refusal': row})
        call('--config', healthy, '--admit', 'private-build', '--state', state)
        assert not (state / 'admission-refused').exists()
        transcript.append({'healthy_admission_cleared_refusal': True})
        unknown_sample = state / 'unknown.tsv'
        unknown_env = {'FM_HOST_MEMORY_PROC': str(home / 'absent-proc')}
        out = call('--record', unknown_sample, extra=unknown_env)
        assert out.startswith('UNKNOWN\t') and not unknown_sample.exists()
        call('--admit', 'unknown-build', '--state', state, extra=unknown_env)
        transcript.append({'unmeasurable_host_admitted_without_recording': True})
        bad = home / 'bad.conf'
        for value in ('nan', 'inf', '-inf', 'typo'):
            bad.write_text('alert_pressure=' + value + '\n')
            call('--config', bad, expected=2)

        mate = home / 'mate'
        (mate / 'state').mkdir(parents=True)
        # Hold modest real resident allocations, without altering any fleet pane.
        workload = 'import sys,time; data=bytearray(int(sys.argv[1])*1024*1024); print("ready",flush=True); time.sleep(60)'
        for cwd, mb in ((home, 32), (home, 32), (mate, 48), (mate, 48)):
            p = subprocess.Popen(['python3', '-u', '-c', workload, str(mb)], cwd=cwd, env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            processes.append(p)
            assert p.stdout.readline().strip() == 'ready'
        proc = home / 'selected-proc'
        proc.mkdir()
        for name in ('meminfo', 'pressure', 'self', *[str(p.pid) for p in processes]):
            (proc / name).symlink_to('/proc/' + name)
        extra = {'FM_HOST_MEMORY_PROC': str(proc)}
        out = call('--config', alert, '--state-dir', home, state,
                   '--state-dir', mate, mate / 'state', '--owned-top-task', state, extra=extra)
        assert 'lead main ' in out and 'in 2 processes' in out and out.endswith('\t'), out
        transcript.append({'empty_home_aggregated_real_processes': True})
        (state / 'sm1.meta').write_text('kind=secondmate\nhome=' + str(mate) + '\n')
        for pairs in ((home, state, mate, mate / 'state'), (mate, mate / 'state', home, state)):
            out = call('--config', alert, '--state-dir', *pairs[:2], '--state-dir', *pairs[2:],
                       '--owned-top-task', state, extra=extra)
            assert 'largest: lead sm1 ' in out and 'lead main ' in out and out.endswith('\tsm1'), out
        out = call('--config', alert, '--state-dir', mate, mate / 'state', '--state-dir', home, state,
                   '--owned-top-task', mate / 'state', extra=extra)
        assert out.endswith('\t'), out
        transcript.append({'parent_owned_lead_preserved_both_argument_orders': True,
                           'child_control_not_authorized': True})
        (state / 'sm1.meta').write_text('kind=secondmate\nremote_host=other\nhome=' + str(mate) + '\n')
        out = call('--config', alert, '--state-dir', home, state, '--state-dir', mate, mate / 'state',
                   '--owned-top-task', state, extra=extra)
        assert 'lead sm1' not in out and out.endswith('\t'), out
        transcript.append({'remote_record_did_not_authorize_local_control': True})
finally:
    for p in processes:
        p.terminate()
        p.communicate(timeout=10)
    (EVIDENCE / 'live-memory-cli.json').write_text(json.dumps(transcript, indent=2) + '\n')
print('Real host sample, threshold-driven admission and persisted records, invalid config refusal, and real-process home ownership verified; private processes and state removed.')
