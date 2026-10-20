#!/usr/bin/env python3
"""Measure exact-size boards in an already-claimed macOS GUI guest.

Requires --app LABEL=FROZEN_RELEASE_APP, --out, and optional --easld/--ssh
for guest-loopback remote boards. Never runs a VM or changes display focus.
"""
import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import traceback

REPO = Path(__file__).resolve().parent.parent
native_spec = importlib.util.spec_from_file_location('perf_native', REPO / 'Tests/RemoteClosedBoard/native.py')
native = importlib.util.module_from_spec(native_spec)
native_spec.loader.exec_module(native)


def command(*args, env=None):
    return subprocess.check_output([str(a) for a in args], env=env, text=True, stderr=subprocess.STDOUT)


def rpc(path, method, params=None):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(120)
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
        self.args, self.app, self.count, self.mode, self.output = args, app, count, mode, output
        self.scratch = Path(tempfile.mkdtemp(prefix='eps-', dir='/tmp')).resolve()
        self.home = self.scratch / 'v'
        self.root = Path(os.path.abspath(args.fixtures)) / str(count)
        self.host = self.scratch / 'h'
        self.socket = (self.host if mode == 'remote' else self.home) / 'easl.sock'
        self.server = None
        self.pid = None
        self.env = dict(os.environ, EASL_DEV_HOME=str(self.home), EASL_DEV_APP=str(app),
                        EASL_DEV_FRAME='0 0 1200 760', EASL_DEV_PERF='1')
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
        windows = wait_for(lambda: json.loads(command(self.args.window_helper, self.pid)))
        window = max(windows, key=lambda item: item['kCGWindowBounds']['Width'] * item['kCGWindowBounds']['Height'])
        self.native_bounds = window['kCGWindowBounds']
        self.native_receipt = native.capture(self.home, window['kCGWindowNumber'], self.output / 'startup.png')
        self.startup_capture_ms = (time.monotonic() - started) * 1000
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
        args = ['scroll', 600, 300, -2, 0, '--mods', 'cmd'] if kind == 'pan' else ['magnify', 600, 300, 0.25]
        self.dev('input', *args, '--repeat', 601, '--interval', 16.666667, '--oscillate', 60)
        wait_for(lambda: 'DevPerfFrames:' in self.log()[offset:] and ' settle ' in self.log()[offset:], 90)
        text = self.log()[offset:]
        after = self.call('view.get')
        motion = re.search(r'DevInput.motion: x ([-\d.]+) ([-\d.]+) zoom ([\d.]+) ([\d.]+)', text)
        assert motion, 'No gesture movement witness'
        x0, x1, z0, z1 = map(float, motion.groups())
        moved = x1 - x0 > 10 if kind == 'pan' else z1 - z0 > 0.01
        self.output.joinpath(kind + '.log').write_text(text)
        return {'before': before, 'after': after, 'moved': moved, 'frame_rows': frames(text),
                'stalls50': [line for line in text.splitlines() if 'DevPerfWake:' in line]}

    def measure(self):
        board = self.start()
        terminals = [obj['id'] for obj in board['objects'] if obj['type'] == 'terminal']
        streams = {}
        for oid in terminals:
            result = rpc(self.socket, 'agent.read', {'target': oid, 'lines': 10})
            assert 'sequence=' in json.dumps(result), 'Terminal did not produce the fixture stream: ' + oid
            streams[oid] = result
        (self.output / 'streams.json').write_text(json.dumps(streams, indent=2))
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
                'terminals': len(terminals), 'pid': self.pid, 'scratch': str(self.scratch)}

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
            self.server.terminate()
            self.server.wait(timeout=15)
            self.server_log.close()
        native.end_session()
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
