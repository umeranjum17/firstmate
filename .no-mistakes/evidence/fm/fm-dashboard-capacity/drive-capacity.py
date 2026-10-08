#!/usr/bin/env python3
"""Drive the actual flow CLI and native SSH; save public output and effective options."""
import hashlib, json, os, pathlib, shlex, shutil, socket, subprocess, tempfile, threading, time
root = pathlib.Path.cwd()
evidence = pathlib.Path('/home/umer/.no-mistakes/evidence/01M4D9A4JCF0254Q8RTZJ622ZC')
cli = root / 'bin/fm-flow.sh'
ssh = shutil.which('ssh')
assert ssh
with tempfile.TemporaryDirectory(prefix='drive-', dir=root / '.capacity-validation-tmp') as work:
    lab = pathlib.Path(work)
    home = lab / 'fleet'
    for directory in ['data', 'state', 'config']:
        (home / directory).mkdir(parents=True)
    (home / 'data/backlog.md').write_text('## Queued\n')
    (home / 'state/fleet-ledger.jsonl').write_text('')
    private = lab / 'user'
    private.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
    env.update(FM_HOME=str(home), HOME=str(private), TMPDIR=str(lab))
    def checksum():
        return {str(p.relative_to(lab)): hashlib.sha256(p.read_bytes()).hexdigest()
                for base in [home, private] for p in base.rglob('*') if p.is_file()}
    def run(name, *args, extra=None):
        start = time.monotonic()
        result = subprocess.run(['bash', str(cli), '--json', *args], env=dict(env, **(extra or {})),
                                text=True, capture_output=True, timeout=45)
        assert result.returncode == 0, result.stderr
        output = json.loads(result.stdout)
        (evidence / (name + '.json')).write_text(json.dumps(output, indent=2, sort_keys=True) + '\n')
        return output, time.monotonic() - start
    before = checksum()
    off, _ = run('capacity-opt-out', '--now', '100', extra={'FM_MAC_HOST': 'invalid;target'})
    assert off['capacity'] is None and off['at'] == 100
    unknown, _ = run('capacity-no-policy', '--capacity', '--now', '100')
    assert all(unknown['capacity']['limits'][key] is None for key in ['FM_MEM_MIN_GB', 'FM_EMU_MAX', 'FM_GRADLE_MAX', 'FM_MEM_JOB_GB'])
    assert unknown['capacity']['slots_under_caps'] == {'emulator': None, 'gradle_gate_match': None}
    # Fleet policy is an actual installed configuration input, never executed by flow.
    (home / 'config/fm-mem-gate.sh').write_text('min=${FM_MEM_MIN_GB:-12}\n'
        '[ "$psi" -lt 40 ] && [ "$running" -lt "${FM_EMU_MAX:-3}" ] && [ "$builds" -lt "${FM_GRADLE_MAX:-2}" ]\n'
        'echo "${FM_MEM_JOB_GB:-10}G"\n')
    before = checksum()
    native, seconds = run('capacity-native', '--capacity', '--now', '100')
    c = native['capacity']
    assert c['observed_at'] > 100 and native['at'] == 100
    assert c['memory_bytes']['MemTotal'] > 0
    assert 0 <= c['memory_bytes']['MemAvailable'] <= c['memory_bytes']['MemTotal']
    assert c['limits']['FM_EMU_MAX'] == 3 and c['limits']['FM_GRADLE_MAX'] == 2
    assert c['mac']['reachable'] is None and c['mac']['simulators'] is None
    for kind, limit in [('emulator', 3), ('gradle_gate_match', 2)]:
        count = c['gate_counts'][kind]
        if count is not None:
            assert count == sum(j['kind'] == kind for j in c['jobs'])
            assert c['slots_under_caps'][kind] == max(limit - count, 0)
    assert c['tmp']['filesystem_available_bytes'] <= c['tmp']['filesystem_total_bytes']
    if c['tmp']['top_folders_complete'] is False:
        assert c['tmp']['directory_bytes'] is None
        assert all(row['bytes'] is None for row in c['tmp']['top_folders'])
    assert checksum() == before
    overrides, _ = run('capacity-overrides', '--capacity', extra={
        'FM_EMU_MAX': '0', 'FM_GRADLE_MAX': '0', 'FM_MEM_JOB_GB': 'not-a-number',
        'FM_MAC_HOST': 'invalid;touch probe-was-executed'})
    assert overrides['capacity']['limits']['FM_MEM_JOB_GB'] is None
    for key in ['emulator', 'gradle_gate_match']:
        if overrides['capacity']['gate_counts'][key] is not None:
            assert overrides['capacity']['slots_under_caps'][key] == 0
    assert any(note['source'] == 'FM_MAC_HOST' and 'invalid' in note['reason'] for note in overrides['limitations'])
    assert checksum() == before and not (root / 'probe-was-executed').exists()
    route = lab / 'ssh-route'
    route.mkdir()
    config = route / 'config'
    config.write_text('Host *\n    UpdateHostKeys yes\n')
    control = dict(line.split(None, 1) for line in subprocess.check_output(
        [ssh, '-G', '-F', str(config), 'nobody@127.0.0.1'], text=True, stderr=subprocess.DEVNULL).splitlines())
    assert control['updatehostkeys'] == 'true'
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        listener.settimeout(20)
        banner = []
        def stall():
            with listener.accept()[0] as connection:
                connection.settimeout(20)
                while data := connection.recv(4096):
                    banner.append(data)
        thread = threading.Thread(target=stall, daemon=True)
        thread.start()
        effective = route / 'effective'
        command = shlex.quote(ssh) + ' -F ' + shlex.quote(str(config)) + ' -p ' + str(listener.getsockname()[1]) + ' -o ConnectTimeout=30'
        wrapper = route / 'ssh'
        wrapper.write_text('#!/bin/sh\n' + command + ' -G "$@" > ' + shlex.quote(str(effective)) + '\nexec ' + command + ' "$@"\n')
        wrapper.chmod(0o700)
        stalled, elapsed = run('capacity-ssh-timeout', '--capacity', extra={
            'FM_MAC_HOST': 'nobody@127.0.0.1', 'PATH': str(route) + os.pathsep + env['PATH']})
        thread.join(3)
        options = dict(line.split(None, 1) for line in effective.read_text().splitlines())
        assert options['updatehostkeys'] == 'false'
        assert options['stricthostkeychecking'] == 'true' and options['batchmode'] == 'yes'
        assert banner and banner[0].startswith(b'SSH-') and not thread.is_alive()
        assert any(note['source'] == 'Mac SSH probe' and 'timed out after 6 seconds' in note['reason'] for note in stalled['limitations'])
        assert all(stalled['capacity']['mac'][key] is None for key in ['reachable', 'available_bytes', 'simulators'])
        assert checksum() == before
        proof = {'native_census_elapsed_seconds': round(seconds, 3), 'timeout_cli_elapsed_seconds': round(elapsed, 3),
                 'control_updatehostkeys': control['updatehostkeys'],
                 'flow_native_ssh_options': {key: options[key] for key in ['updatehostkeys', 'stricthostkeychecking', 'batchmode', 'connecttimeout']},
                 'native_ssh_banner': banner[0].decode().strip(), 'native_connection_closed': not thread.is_alive(),
                 'isolated_fleet_and_private_user_files_unchanged': checksum() == before,
                 'note': 'Private -F config and loopback route; no shared SSH files or production credentials touched. No successful Mac host configured.'}
        (evidence / 'ssh-boundary-proof.json').write_text(json.dumps(proof, indent=2) + '\n')
        print(json.dumps(proof, indent=2))
