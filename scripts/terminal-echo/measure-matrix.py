import argparse
import json
from pathlib import Path
import runpy
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('root', type=Path)
p.add_argument('--home', default='bview')
p.add_argument('--compare-home')
p.add_argument('--prefix', required=True)
p.add_argument('--profiles', nargs='+', default=['good', 'poor'])
p.add_argument('--compressions', nargs='+', default=['yes', 'no'])
p.add_argument('--kinds', nargs='+', default=['space', 'burst', 'bulk'])
p.add_argument('--repeats', type=int, default=1)
a = p.parse_args()
root = a.root
output = root / a.prefix
output.mkdir(exist_ok=False)
analyzer = runpy.run_path(str(root / 'analyze-echo.py'))['analyze']
results = []
def run(label, args, timeout=120):
    started = time.monotonic()
    result = subprocess.run([str(item) for item in args], capture_output=True, text=True, timeout=timeout)
    record = dict(argv=[str(item) for item in args], exit=result.returncode, elapsed_s=time.monotonic() - started,
                  stdout=result.stdout, stderr=result.stderr)
    (output / (label + '.json')).write_text(json.dumps(record, indent=2) + '\n')
    if result.returncode:
        raise RuntimeError(label + ': ' + result.stderr + result.stdout)
    return result
active_home = a.home
def select_home(home, label):
    global active_home
    if home == active_home:
        return
    run(label + '-stop', ['python3', root / 'run-echo.py', 'stop', root, '--home', active_home])
    artifact = json.loads((root / home / 'launch.json').read_text())['artifact']
    run(label + '-launch', ['python3', root / 'run-echo.py', 'launch', root, '--home', home, '--artifact', artifact])
    active_home = home

def cohort(home, profile, compression, kind, rep):
    name = '%s-%s-%s-%s-%d-%s' % (a.prefix, profile, compression, kind, rep, home)
    select_home(home, name)
    directory = root / name
    args = ['python3', root / 'run-echo.py', 'cohort', root, '--home', home, '--name', name,
            '--compression', compression, '--count', 1 if kind == 'bulk' else 100,
            '--interval', 5 if kind == 'burst' else 150]
    if kind == 'bulk':
        args.append('--burst')
    run(name + '-create', args)
    try:
        deadline = time.monotonic() + 30
        while True:
            trace = directory / 'ssh.jsonl'
            if trace.exists() and any(json.loads(line).get('stage') == 'viewer.received' for line in trace.read_text().splitlines()):
                break
            assert time.monotonic() < deadline, 'terminal SSH attach never delivered output'
            time.sleep(.01)
        for action in ['prepare', 'observe', 'type', 'wait']:
            run(name + '-' + action, ['python3', root / 'native-echo.py', action, root, name, '--home', home])
        if rep == 0:
            run(name + '-capture', ['python3', root / 'native-echo.py', 'capture', root, name, '--home', home])
    finally:
        run(name + '-finish', ['python3', root / 'native-echo.py', 'finish', root, name, '--home', home])
    result, rows = analyzer(directory)
    if kind == 'bulk':
        received = b''.join(bytes.fromhex(row['hex']) for row in rows if row.get('stage') == 'viewer.received')
        expected = b''.join(str(value).encode() + b'\r\n' for value in range(1, 20001))
        result['burst_bytes_valid'] = expected in received
        result['valid'] = result['valid'] and result['burst_bytes_valid']
        (directory / 'analysis.json').write_text(json.dumps(result, indent=2) + '\n')
    results.append(result)
    print(json.dumps(dict(name=name, valid=result['valid'], complete=result['complete'], expected=result['expected'], stages=result['stages'])), flush=True)
    (output / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
    assert result['valid'], name + ': invalid stage cohort; retained errors in analysis.json'

try:
    for rep in range(a.repeats):
        profiles = a.profiles if rep % 2 == 0 else list(reversed(a.profiles))
        for profile in profiles:
            run('shape-%s-%d' % (profile, rep), ['python3', root / 'shape-link.py', profile, root])
            if rep == 0:
                run('calibrate-' + profile, ['python3', root / 'calibrate-link.py', root, profile])
            arms = a.compressions if rep % 2 == 0 else list(reversed(a.compressions))
            homes = [a.home] + ([a.compare_home] if a.compare_home else [])
            if rep % 2:
                homes.reverse()
            for compression in arms:
                for kind in a.kinds:
                    for home in homes:
                        cohort(home, profile, compression, kind, rep)
finally:
    if (root / 'shaper-state.json').exists():
        run('shaping-teardown', ['python3', root / 'shape-link.py', 'clear', root])
