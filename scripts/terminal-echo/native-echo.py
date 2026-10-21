import argparse
import json
from pathlib import Path
import runpy
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('action', choices=['prepare', 'observe', 'type', 'wait', 'finish', 'delete', 'capture'])
p.add_argument('root', type=Path)
p.add_argument('name')
p.add_argument('--home', default='view')
args = p.parse_args()
root = args.root
module = runpy.run_path(str(root / 'run-echo.py'))
RPC, send = module['RPC'], module['send']
launch = json.loads((root / args.home / 'launch.json').read_text())
pid, window, board = launch['pid'], launch['window'], launch['board']
target = root / args.name
config = json.loads((target / 'config.json').read_text())
def native_state():
    result = subprocess.run(['python3', str(root / 'viewer-state.py'), '--pid', str(pid),
                             '--log', str(root / args.home / 'app.log'), '--input-helper', str(root / 'timed-input')],
                            capture_output=True, text=True, check=True)
    windows = json.loads(result.stdout)['windows']
    return next(item for item in windows if item['window'] == window)
def cua(method, fields):
    result = subprocess.run(['/Applications/CuaDriver.app/Contents/MacOS/cua-driver', 'call', method,
                             json.dumps(dict(pid=pid, window_id=window, session='echo-native-proof-' + str(pid), **fields))],
                            capture_output=True, text=True)
    value = json.loads(result.stdout)
    (target / (method + '.json')).write_text(json.dumps(value, indent=2) + '\n')
    assert result.returncode == 0, (value, result.stderr)
    return value
if args.action == 'delete':
    print(json.dumps(RPC(root / 'host/easl.sock').call('object.delete', {'id': config['tile']})), flush=True)
elif args.action == 'prepare':
    value = cua('bring_to_front', {})
    assert value.get('exact_window_effect', {}).get('verified') is True
    state = native_state()
    view = state['viewport']
    print(json.dumps(state), flush=True)
    if abs(view['zoom'] - 1) > .001:
        send(root, pid, window, kind='magnify', x=400, y=180, amount=0, phase='began')
        send(root, pid, window, kind='magnify', x=400, y=180, amount=1 / view['zoom'] - 1, phase='changed')
        send(root, pid, window, kind='magnify', x=400, y=180, amount=0, phase='ended')
        time.sleep(.3)
    for _ in range(24):
        state = native_state()
        view = state['viewport']
        assert abs(view['zoom'] - 1) < .002, view
        dx, dy = view['rect']['x'], view['rect']['y']
        if max(abs(dx), abs(dy)) < .6:
            break
        dx, dy = max(-400, min(400, dx)), max(-180, min(180, dy))
        send(root, pid, window, kind='drag', x=400, y=180, toX=400 + dx, toY=180 + dy, middle=1)
        time.sleep(.05)
    else:
        raise RuntimeError('viewport did not converge')
    send(root, pid, window, kind='click', x=200, y=200)
    time.sleep(.2)
    state = native_state()
    (target / 'prepared.json').write_text(json.dumps(state, indent=2) + '\n')
    assert state.get('responder') == 'CanvasTerminalView', state
    print(json.dumps(state), flush=True)
elif args.action == 'observe':
    (target / 'observe-requested.json').write_text(json.dumps({'pid': pid, 'window': window}) + '\n')
    send(root, pid, window, kind='terminal-echo', action='start', directory=str(target / 'native'), count=config['count'])
    print(json.dumps(module['wait'](target / 'native/ready.json', 15)), flush=True)
elif args.action == 'type':
    fields = {'kind': 'text', 'text': 'a'} if config.get('input_mode') == 'text' else {'kind': 'key', 'key': 'a'}
    result = send(root, pid, window, repeat=config['count'], interval=config['interval'], **fields)
    (target / 'input-sent.txt').write_text(result)
    print(result, flush=True)
elif args.action == 'wait':
    print(json.dumps(module['wait'](target / 'native/complete.json', max(30, config['count'] * config['interval'] / 1000 + 20))), flush=True)
    print(json.dumps(module['wait'](target / 'native/surface-complete.json', 15)), flush=True)
elif args.action == 'capture':
    value = cua('get_window_state', {'include_accessibility_tree': False, 'max_image_dimension': 0, 'screenshot_out_file': str(target / 'cua.png')})
    assert value.get('screenshot_frame_valid') is True and value['pid'] == pid and value['window_id'] == window
    print(json.dumps(value), flush=True)
elif args.action == 'finish':
    try:
        if (target / 'observe-requested.json').exists():
            send(root, pid, window, kind='terminal-echo', action='stop')
            stopped = module['wait'](target / 'native/stopped.json', 15)
            assert stopped['success'], stopped
    finally:
        (target / 'stop-fixture').touch()
        server = RPC(root / 'host/easl.sock')
        print(json.dumps(server.call('object.delete', {'id': config['tile']})), flush=True)
        deadline = time.monotonic() + 15
        while True:
            text = (target / 'host.jsonl').read_text()
            if text.endswith('\n') and json.loads(text.splitlines()[-1]).get('stage') == 'host_trace_summary':
                break
            assert time.monotonic() < deadline, 'host syscall trace did not flush after session shutdown'
            time.sleep(.01)
        while True:
            text = (target / 'ssh.jsonl').read_text()
            if text.endswith('\n'):
                rows = [json.loads(line) for line in text.splitlines()]
                inputs = {row['pid'] for row in rows if row.get('stage') == 'ssh.input'}
                transports = {row['pid'] for row in rows if row.get('stage') == 'ssh.transport'}
                if len(inputs) != 1 or inputs <= transports:
                    break
            assert time.monotonic() < deadline, 'the measured SSH observer did not publish its transport receipt'
            time.sleep(.01)
