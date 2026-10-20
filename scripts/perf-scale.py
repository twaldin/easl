#!/usr/bin/env python3
"""Measure exact-size boards in an already-claimed macOS GUI guest.

Requires --app LABEL=FROZEN_RELEASE_APP, --out, and optional --easld/--ssh
for guest-loopback remote boards. Activates only its owned app in a VirtualMac guest.
"""
import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import traceback
import uuid

REPO = Path(__file__).resolve().parent.parent
native_spec = importlib.util.spec_from_file_location('perf_native', REPO / 'Tests/RemoteClosedBoard/native.py')
native = importlib.util.module_from_spec(native_spec)
native_spec.loader.exec_module(native)


def command(*args, env=None):
    return subprocess.check_output([str(a) for a in args], env=env, text=True, stderr=subprocess.STDOUT, timeout=120)


def require_guest():
    if sys.platform != 'darwin':
        raise RuntimeError('GUI runs require a claimed VirtualMac guest')
    model = command('sysctl', '-n', 'hw.model').strip()
    if not model.startswith('VirtualMac'):
        raise RuntimeError('GUI runs require a claimed VirtualMac guest, not ' + model)
    return model


def native_json(helper, output, *arguments):
    try:
        result = subprocess.run([str(helper), *map(str, arguments)], capture_output=True, timeout=30)
    except subprocess.TimeoutExpired as error:
        output.with_suffix(output.suffix + '.stdout').write_bytes(error.stdout or b'')
        output.with_suffix(output.suffix + '.stderr').write_bytes(error.stderr or b'')
        raise
    output.with_suffix(output.suffix + '.stdout').write_bytes(result.stdout)
    output.with_suffix(output.suffix + '.stderr').write_bytes(result.stderr)
    result.check_returncode()
    return json.loads(result.stdout)


def frame_text(helper, image):
    return native_json(helper, image.with_suffix('.ocr'), '--drawn', image)


def rpc(path, method, params=None, timeout=120):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(timeout)
        connection.connect(str(path))
        connection.sendall((json.dumps({'id': 1, 'method': method, 'params': params or {}}) + '\n').encode())
        with connection.makefile('rb') as stream:
            while True:
                line = stream.readline()
                if not line:
                    raise RuntimeError('RPC disconnected: ' + method)
                response = json.loads(line)
                if response.get('id') == 1:
                    if response.get('ok') is not True or 'error' in response:
                        raise RuntimeError(json.dumps(response))
                    return response['result']


def wait_for(predicate, seconds=90):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise TimeoutError('Readiness deadline expired')


def cpu_times(pids):
    result = {}
    for line in command('/bin/ps', '-o', 'pid=,time=', '-p', ','.join(map(str, sorted(pids)))).splitlines():
        pid, value = line.split()
        seconds = 0
        for part in value.split(':'):
            seconds = seconds * 60 + float(part)
        result[int(pid)] = seconds
    return result


def memory(pid):
    return int(command('/bin/ps', '-o', 'rss=', '-p', pid).strip()) / 1024


def frames(text):
    pattern = (r'DevPerfFrames: .* gesture ([\d.]+) ms: samples (\d+) p50 ([\d.]+) ms '
               r'p95 ([\d.]+) ms p99 ([\d.]+) ms missed (\d+) stalls50 (\d+) overflow100 (\d+)')
    matches = list(re.finditer(pattern, text))
    assert len(matches) == 1, 'Expected one complete gesture frame distribution'
    names = ('duration_ms', 'samples', 'p50_ms', 'p95_ms', 'p99_ms', 'dropped', 'stalls50', 'overflow100')
    result = dict(zip(names, map(float, matches[0].groups())))
    assert result['samples'] > 0, 'No displayed-window callbacks'
    return result


class Run:
    def __init__(self, args, app, count, mode, output):
        require_guest()
        native.SESSION = 'PerfScale' + uuid.uuid4().hex
        native.used = False
        self.args, self.app, self.count, self.mode, self.output = args, app, count, mode, output
        self.scratch = Path(tempfile.mkdtemp(prefix='eps-', dir='/tmp')).resolve()
        self.home = self.scratch / 'v'
        self.root = Path(os.path.abspath(args.fixtures)) / str(count)
        self.host = self.scratch / 'h'
        self.socket = (self.host if mode == 'remote' else self.home) / 'easl.sock'
        self.server = None
        self.pid = None
        self.env = dict(os.environ, EASL_DEV_HOME=str(self.home), EASL_DEV_APP=str(app),
                        EASL_DEV_FRAME='0 0 1000 500', EASL_DEV_PERF='1')
        for key in ('EASL_BOARD_ID', 'EASL_TILE_ID'):
            self.env.pop(key, None)
        if mode == 'remote':
            self.env.update(EASL_DEV_SSH=str(args.ssh), EASL_DEV_REMOTE_HOME=str(self.host))
        self.bid = None

    def dev(self, *args):
        return command(REPO / 'scripts/dev.sh', *args, env=self.env)

    def call(self, method, params=None):
        return rpc(self.socket, method, dict(params or {}, board=self.bid))

    def log(self):
        return (self.home / 'app.log').read_text(errors='replace')

    def start(self):
        fixture_home = self.host if self.mode == 'remote' else self.home
        self.bid = command(sys.executable, REPO / 'scripts/perf-board.py', fixture_home, self.root,
                           '--objects', self.count, '--seed', 7).strip().splitlines()[-1]
        source = fixture_home / 'boards' / (self.bid + '.json')
        shutil.copy2(source, self.output / 'fixture.json')
        if self.mode == 'remote':
            self.server_log = (self.output / 'easld.log').open('w')
            self.server = subprocess.Popen([str(self.args.easld), '--home', str(self.host), '--own-terminals'],
                                           stdout=self.server_log, stderr=subprocess.STDOUT)
            wait_for(lambda: (self.host / 'easl.sock').exists())
            rpc(self.host / 'easl.sock', 'board.open', {'root': str(self.root)})
            self.home.mkdir(parents=True)
            (self.home / 'get-started.json').write_text('{"dismissed":true}')
        launched = time.monotonic()
        self.dev('start', self.scratch / 'empty')
        self.pid = int((self.home / 'pid').read_text())
        self.harness_launch_ms = (time.monotonic() - launched) * 1000
        self.dev('input', 'idle', 'off')
        self.dev('input', 'perf', '900000')
        active = native_json(self.args.window_helper, self.output / 'activation', '--activate', self.pid)
        assert active['pid'] == self.pid and active['isActive'], 'Owned guest app was not active before timed target open'
        started = time.monotonic()
        if self.mode == 'remote':
            self.dev('input', 'remote', 'easl-guest', self.bid, self.host)
        else:
            rpc(self.socket, 'board.open', {'root': str(self.root), 'select': True})
        try:
            board = wait_for(lambda: self.read_ready('board.get'))
        except TimeoutError as error:
            raise TimeoutError(str(error) + ': ' + getattr(self, 'readiness_error', 'no reply')) from error
        self.api_ready_ms = (time.monotonic() - started) * 1000
        assert len(board['objects']) == self.count, 'Fixture object count changed'
        wait_for(lambda: (self.read_ready('view.get') or {}).get('visible'))
        self.terminals = [obj['id'] for obj in board['objects'] if obj['type'] == 'terminal']
        assert len(self.terminals) == 8, 'Fixture must contain eight outputting terminals'
        streams = {}
        pending = set(self.terminals)
        stream_deadline = time.monotonic() + 90
        stream_path = self.output / 'streams.json'
        stream_path.write_text(json.dumps(streams, indent=2))
        while pending:
            for oid in self.terminals:
                if oid not in pending:
                    continue
                remaining = stream_deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError('Fixture stream readiness expired: ' + ', '.join(sorted(pending)))
                result = rpc(self.socket, 'agent.read', {'target': oid, 'lines': 10}, timeout=remaining)
                streams[oid] = result
                stream_path.write_text(json.dumps(streams, indent=2))
                if time.monotonic() >= stream_deadline:
                    raise TimeoutError('Fixture stream readiness expired: ' + ', '.join(sorted(pending)))
                if re.search(r'\bworker=[0-7] sequence=[0-9]{20} status=running\b', result['text']):
                    pending.remove(oid)
            if pending:
                time.sleep(min(0.05, max(0, stream_deadline - time.monotonic())))
        windows = wait_for(lambda: json.loads(command(self.args.window_helper, self.pid)))
        window = max(windows, key=lambda item: item['kCGWindowBounds']['Width'] * item['kCGWindowBounds']['Height'])
        self.native_bounds = window['kCGWindowBounds']
        attempts = []
        deadline = time.monotonic() + 30
        while True:
            image = self.output / ('startup-attempt-' + str(len(attempts)) + '.png')
            receipt = native.capture(self.home, window['kCGWindowNumber'], image)
            captured_ms = (time.monotonic() - started) * 1000
            attempt = {'captured_ms': captured_ms, 'capture_id': receipt['capture_id']}
            attempts.append(attempt)
            (self.output / 'startup-attempts.json').write_text(json.dumps(attempts, indent=2))
            probe = frame_text(self.args.window_helper, image)
            attempt.update(probe)
            (self.output / 'startup-attempts.json').write_text(json.dumps(attempts, indent=2))
            if probe['drawn']:
                self.native_receipt = receipt
                self.startup_capture_ms = captured_ms
                for suffix in ('.png', '.capture.json', '.capture.stderr'):
                    shutil.copy2(image.with_suffix(suffix), self.output / ('startup' + suffix))
                break
            if time.monotonic() >= deadline:
                raise TimeoutError('No fixture terminal output in native startup pixels')
            time.sleep(0.05)
        time.sleep(5)
        self.dev('input', 'perf', '1')
        time.sleep(0.2)
        self.output.joinpath('launch.log').write_text(self.log())
        return board

    def read_ready(self, method):
        try:
            return self.call(method)
        except (OSError, RuntimeError) as error:
            self.readiness_error = str(error)
            return None

    def gesture(self, kind):
        self.dev('input', 'mainmenu', 'View/Zoom to Fit')
        time.sleep(2)
        if kind == 'pan':
            self.dev('input', 'mainmenu', 'View/Actual Size')
            time.sleep(2)
        before = self.call('view.get')
        offset = len(self.log())
        args = ['scroll', 600, 300, -40, -20, '--mods', 'cmd'] if kind == 'pan' else ['magnify', 600, 300, 0.01]
        oscillate = 60 if kind == 'pan' else 120
        self.dev('input', *args, '--repeat', 601, '--interval', 16.666667, '--oscillate', oscillate, '--realtime')
        wait_for(lambda: 'DevPerfFrames:' in self.log()[offset:] and ' settle ' in self.log()[offset:], 90)
        text = self.log()[offset:]
        after = self.call('view.get')
        motion = re.search(r'DevInput.motion: x ([-\d.]+) ([-\d.]+) zoom ([\d.]+) ([\d.]+)', text)
        assert motion, 'No gesture movement witness'
        delivery = re.search(r'DevInput.delivery: scheduled (\d+) delivered (\d+) coalesced (\d+) realtime (\d+)', text)
        assert delivery and delivery[4] == '1', 'App/helper did not honor real-time gesture delivery'
        x0, x1, z0, z1 = map(float, motion.groups())
        moved = x1 - x0 > before['viewport']['rect']['w'] if kind == 'pan' else z1 - z0 > 0.01
        self.output.joinpath(kind + '.log').write_text(text)
        return {'before': before, 'after': after, 'moved': moved, 'frame_rows': frames(text),
                'input_delivery': dict(zip(('scheduled', 'delivered', 'coalesced', 'realtime'), map(int, delivery.groups()))),
                'stalls50': [line for line in text.splitlines() if 'DevPerfWake:' in line]}

    def measure(self):
        board = self.start()
        quiet = self.root / '.perf-board-quiet'
        quiet.touch()
        time.sleep(5)
        self.dev('input', 'mainmenu', 'View/Actual Size')
        time.sleep(2)
        process = rpc(self.home / 'easl.sock', 'app.metrics').get('process', {})
        family = {self.pid} | {helper['pid'] for helper in process.get('helpers', [])}
        pids = family | ({self.server.pid} if self.server else set())
        start = time.monotonic()
        c0 = cpu_times(pids)
        time.sleep(10)
        c1 = cpu_times(pids)
        elapsed = time.monotonic() - start
        idle_cpu = (c1[self.pid] - c0[self.pid]) / elapsed * 100
        process = rpc(self.home / 'easl.sock', 'app.metrics').get('process', {})
        current_family = {self.pid} | {helper['pid'] for helper in process.get('helpers', [])}
        changed_pids = sorted((set(c0) - set(c1)) | (current_family - family))
        family_cpu = None if changed_pids else sum(c1[pid] - c0[pid] for pid in family & c0.keys() & c1.keys()) / elapsed * 100
        daemon_cpu = (c1[self.server.pid] - c0[self.server.pid]) / elapsed * 100 if self.server else None
        rss = memory(self.pid)
        quiet.unlink()
        pan, zoom = self.gesture('pan'), self.gesture('zoom')
        ids = [obj['id'] for obj in board['objects']]
        before = self.call('view.get')
        start = time.monotonic()
        rendered = self.call('view.render', {'target': ids, 'scale': 0.15, 'inline': True, 'timeoutMs': 60000})
        render_ms = (time.monotonic() - start) * 1000
        image = base64.b64decode(rendered.pop('data'), validate=True)
        assert image.startswith(b'\x89PNG\r\n\x1a\n'), 'Render is not PNG'
        (self.output / 'whole.png').write_bytes(image)
        width, height = __import__('struct').unpack('>II', image[16:24])
        assert (width, height) == (rendered['width'], rendered['height']), 'PNG dimensions differ'
        states = {state: sum(obj['state'] == state for obj in rendered['objects']) for state in ('rendered', 'placeholder', 'failed')}
        missing = sorted(set(ids) - {obj['id'] for obj in rendered['objects']})
        (self.output / 'render.json').write_text(json.dumps(rendered, indent=2))
        assert self.call('view.get')['viewport'] == before['viewport'], 'Render moved the viewport'
        return {'api_ready_ms': self.api_ready_ms, 'startup_capture_upper_ms': self.startup_capture_ms,
                'harness_launch_ms': self.harness_launch_ms,
                'native_bounds': self.native_bounds, 'capture_id': self.native_receipt['capture_id'],
                'pan': pan, 'zoom': zoom, 'idle_cpu_percent': idle_cpu, 'app_rss_MiB': rss,
                'process_memory': process,
                'idle_app_and_helpers_cpu_percent': family_cpu, 'idle_daemon_cpu_percent': daemon_cpu,
                'idle_cpu_seconds': elapsed, 'idle_cpu_changed_pids': changed_pids,
                'idle_cpu_samples': {'before': c0, 'after': c1},
                'process_memory_after_render': rpc(self.home / 'easl.sock', 'app.metrics').get('process', {}),
                'render_ms': render_ms, 'render_states': states, 'render_missing': missing,
                'terminals': len(self.terminals), 'pid': self.pid, 'scratch': str(self.scratch)}

    def owned_processes(self):
        scopes = {str(path) for path in (self.root, self.root.resolve(), self.scratch, self.scratch.resolve())}
        processes = {}
        for line in command('/bin/ps', '-axo', 'pid=,ppid=,command=').splitlines():
            fields = line.strip().split(None, 2)
            if len(fields) == 3:
                pid, parent, argv = fields
                processes[int(pid)] = {'pid': int(pid), 'parent': int(parent), 'command': argv}
        cwd = subprocess.run(['lsof', '-a', '-u', str(os.getuid()), '-d', 'cwd', '-Fpn'],
                             capture_output=True, text=True, check=True)
        current = None
        for line in cwd.stdout.splitlines():
            if line.startswith('p'):
                current = int(line[1:])
            elif line.startswith('n') and current in processes:
                processes[current]['cwd'] = line[1:]
        owned = []
        for pid, process in processes.items():
            if pid == os.getpid():
                continue
            directory = process.get('cwd', '')
            ownership = []
            if any(directory == scope or directory.startswith(scope + '/') for scope in scopes):
                ownership.append('owned fixture or run cwd')
            if any(scope + '/' in process['command'] for scope in scopes):
                ownership.append('owned fixture or run command')
            if ownership:
                owned.append(dict(process, ownership=ownership))
        return owned

    def stop_owned_processes(self):
        receipt = {'app_pid': self.pid, 'daemon_pid': self.server.pid if self.server else None, 'passes': []}
        path = self.output / 'owned-processes.json'
        for signum in (signal.SIGTERM, signal.SIGTERM, signal.SIGKILL):
            owned = self.owned_processes()
            receipt['passes'].append({'signal': signum, 'processes': owned})
            path.write_text(json.dumps(receipt, indent=2))
            if not owned:
                break
            for process in owned:
                try:
                    os.kill(process['pid'], signum)
                except ProcessLookupError:
                    pass
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if not self.owned_processes():
                    break
                time.sleep(0.1)
        receipt['remaining'] = self.owned_processes()
        path.write_text(json.dumps(receipt, indent=2))
        if receipt['remaining']:
            raise RuntimeError('Owned fixture/run processes survived cleanup: ' + json.dumps(receipt['remaining']))

    def close(self):
        errors = []
        if self.bid and ((self.mode == 'remote' and self.server and self.server.poll() is None)
                         or (self.mode == 'local' and self.pid and self.socket.exists())):
            try:
                rpc(self.socket, 'board.close', {'board': self.bid, 'endSessions': True})
            except Exception as error:
                errors.append(str(error))
        try:
            self.dev('stop')
        except Exception as error:
            errors.append(str(error))
        if (self.home / 'app.log').exists():
            (self.output / 'app.log').write_text(self.log())
        if self.server:
            try:
                self.server.terminate()
                self.server.wait(timeout=15)
            except Exception as error:
                errors.append(str(error))
            finally:
                self.server_log.close()
        try:
            native.end_session()
        except Exception as error:
            errors.append(str(error))
        try:
            self.stop_owned_processes()
        except Exception as error:
            errors.append(str(error))
        quiet = self.root / '.perf-board-quiet'
        quiet.unlink(missing_ok=True)
        if errors:
            raise RuntimeError('; '.join(errors))
        shutil.rmtree(self.scratch)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', action='append', required=True)
    parser.add_argument('--sizes', default='50,200,500,1000')
    parser.add_argument('--modes', default='local,remote')
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--easld', type=Path)
    parser.add_argument('--ssh', type=Path)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--window-helper', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Run inside the claimed macOS GUI guest')
    apps = [(label, Path(path).resolve()) for label, path in (value.split('=', 1) for value in args.app)]
    modes = args.modes.split(',')
    if any(mode not in ('local', 'remote') for mode in modes):
        parser.error('modes must be local and/or remote')
    if 'remote' in modes and not (args.easld and args.ssh):
        parser.error('remote mode requires guest-local --easld and --ssh')
    args.out.mkdir(parents=True, exist_ok=True)
    for repeat in range(args.runs):
        for size in map(int, args.sizes.split(',')):
            for mode in modes:
                for label, app in (apps if repeat % 2 == 0 else list(reversed(apps))):
                    output = args.out / '{}-{}-{}-{}'.format(repeat, size, mode, label)
                    output.mkdir()
                    row = {'run': repeat, 'objects': size, 'mode': mode, 'app': label,
                           'uptime': command('uptime').strip(), 'cores': command('sysctl', '-n', 'hw.ncpu').strip()}
                    run = Run(args, app, size, mode, output)
                    try:
                        row.update(run.measure())
                        row['ok'] = row['pan']['moved'] and row['zoom']['moved'] and not row['render_missing'] and row['render_states']['failed'] == 0 and row['render_states']['placeholder'] == 0
                    except Exception:
                        row.update(ok=False, error=traceback.format_exc())
                    finally:
                        try:
                            run.close()
                        except Exception:
                            row['cleanup_error'] = traceback.format_exc()
                            row['ok'] = False
                    with (args.out / 'rows.jsonl').open('a') as stream:
                        stream.write(json.dumps(row) + '\n')
                    print(json.dumps(row), flush=True)
                    if 'cleanup_error' in row:
                        raise RuntimeError('Owned resources need cleanup before another run')


if __name__ == '__main__':
    main()
