#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import time

class RPC:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(60)
        self.sock.connect(str(path))
        self.reader = self.sock.makefile('rb')
        self.seq = 0
    def call(self, method, params=None):
        self.seq += 1
        ident = 'echo-' + str(self.seq)
        self.sock.sendall((json.dumps(dict(id=ident, method=method, params=params or {})) + '\n').encode())
        while True:
            line = self.reader.readline()
            assert line, ('RPC ended', method)
            reply = json.loads(line)
            if reply.get('id') != ident:
                continue
            assert reply.get('ok') is True, (method, reply)
            return reply['result']

def wait(path, seconds=60):
    until = time.monotonic() + seconds
    while not path.exists():
        assert time.monotonic() < until, 'deadline ' + str(path)
        time.sleep(.02)
    return json.loads(path.read_text())

def send(root, pid, window, **fields):
    payload = dict(pid=str(pid), window=str(window), **{k: str(v) for k, v in fields.items()})
    return subprocess.run([str(root / 'timed-input'), json.dumps(payload)], capture_output=True, text=True, check=True).stdout

def stop(home):
    launch = json.loads((home / 'launch.json').read_text())
    pid = launch['pid']
    owners = subprocess.check_output(['lsof', '-t', str(home / 'instance.lock')], text=True)
    assert {int(value) for value in owners.split()} == {pid}, 'viewer no longer owns its instance lock'
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 20
    while True:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            break
        assert time.monotonic() < deadline, 'viewer did not stop'
        time.sleep(.02)
    subprocess.run(['/Applications/CuaDriver.app/Contents/MacOS/cua-driver', 'call', 'end_session',
                    json.dumps({'session': 'echo-native-proof-' + str(pid)})], capture_output=True, text=True, check=True)
    print(json.dumps({'stopped_pid': pid, 'home': str(home)}), flush=True)

def main():
    p = argparse.ArgumentParser()
    p.add_argument('action', choices=['seed', 'launch', 'cohort', 'stop'])
    p.add_argument('root', type=Path)
    p.add_argument('--artifact', default='before.app')
    p.add_argument('--home', default='view')
    p.add_argument('--name', default='smoke')
    p.add_argument('--compression', choices=['yes', 'no'], default='yes')
    p.add_argument('--interval', type=int, default=150)
    p.add_argument('--count', type=int, default=100)
    p.add_argument('--burst', action='store_true')
    p.add_argument('--input-mode', choices=['key', 'text'], default='key')
    args = p.parse_args()
    root = args.root
    home = root / args.home
    if args.action == 'stop':
        stop(home)
        return
    repo = (root / 'repo').resolve()
    server = RPC(root / 'host/easl.sock')
    if args.action == 'seed':
        (root / 'board').mkdir(exist_ok=True)
        opened = server.call('board.open', {'root': str(root / 'board')})
        (root / 'board.json').write_text(json.dumps(opened) + '\n')
        print(json.dumps(opened), flush=True)
        return
    board = json.loads((root / 'board.json').read_text())['board']
    if args.action == 'launch':
        source_hash = hashlib.sha256((root / args.artifact / 'Contents/MacOS/Easl').read_bytes()).hexdigest()
        if (home / 'easl.app').exists():
            old = json.loads((home / 'launch.json').read_text())
            assert old['artifact'] == args.artifact and old['source_binary_sha256'] == source_hash, 'use a fresh home for another artifact'
            subprocess.run(['/usr/bin/open', '-g', '-n', '--stdout', str(home / 'app.log'),
                            '--stderr', str(home / 'app.log'), str(home / 'easl.app')], check=True)
        else:
            env = os.environ.copy()
            env.update(EASL_DEV_HOME=str(home), EASL_DEV_APP=str(root / args.artifact),
                       EASL_DEV_SSH=str(root / 'ssh-observed'), EASL_DEV_REMOTE_HOME=str(root / 'host'),
                       EASL_DEV_FRAME='0 0 1200 800')
            subprocess.run([str(repo / 'scripts/dev.sh'), 'start', str(root / ('local-' + args.home))], env=env, cwd=str(repo), check=True)
        until = time.monotonic() + 90
        while not (home / 'easl.sock').exists():
            assert time.monotonic() < until
            time.sleep(.05)
        owners = subprocess.check_output(['lsof', '-t', str(home / 'instance.lock')], text=True).split()
        assert len(set(owners)) == 1
        pid = int(owners[0])
        viewer = RPC(home / 'easl.sock')
        opened = viewer.call('board.open_remote', {'host': 'easl-guest', 'board': board, 'select': True})
        result = dict(pid=pid, window=opened['window'], board=board, home=str(home), artifact=args.artifact,
                      source_binary_sha256=source_hash,
                      binary_sha256=hashlib.sha256((home / 'easl.app/Contents/MacOS/Easl').read_bytes()).hexdigest(), opened=opened)
        (home / 'launch.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result), flush=True)
        return
    launch = json.loads((home / 'launch.json').read_text())
    pid, window = launch['pid'], launch['window']
    target = root / args.name
    target.mkdir(exist_ok=False)
    (root / 'current.json').write_text(json.dumps(dict(directory=str(target), compression=args.compression, burst=args.burst)) + '\n')
    made = server.call('object.create', {'board': board, 'type': 'terminal', 'frame': {'x': 80, 'y': 80, 'w': 900, 'h': 600},
                       'props': {'command': ['/usr/bin/python3', '-u', str(root / 'echo-fixture.py'), str(target)] + (['--burst'] if args.burst else []), 'cwd': str(root / 'board'), 'name': args.name}})
    tile = made['object']['id']
    configuration = dict(vars(args))
    configuration.update(tile=tile, artifact=launch['artifact'], binary_sha256=launch['binary_sha256'], pid=pid, window=window,
                         boot_session=subprocess.check_output(['sysctl', '-n', 'kern.bootsessionuuid'], text=True).strip())
    (target / 'config.json').write_text(json.dumps(configuration, default=str, indent=2) + '\n')
    wait(target / 'fixture-ready.json')
    print(json.dumps(dict(stage='cohort.created', tile=tile, target=str(target))), flush=True)
    return

if __name__ == '__main__':
    main()
