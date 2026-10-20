import argparse
import json
import os
from pathlib import Path
import runpy
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('root', type=Path)
p.add_argument('--home', default='bview')
p.add_argument('--compare-home')
p.add_argument('--prefix', required=True)
p.add_argument('--profiles', nargs='+', choices=['good', 'poor'], default=['good', 'poor'])
p.add_argument('--compressions', nargs='+', choices=['yes', 'no'], default=['yes', 'no'])
p.add_argument('--kinds', nargs='+', choices=['space', 'burst', 'bulk'], default=['space', 'burst', 'bulk'])
p.add_argument('--repeats', type=int, default=1)
a = p.parse_args()
if a.repeats <= 0:
    p.error('--repeats must be positive')
root = a.root
output = root / a.prefix
output.mkdir(exist_ok=False)
analyzer = runpy.run_path(str(root / 'analyze-echo.py'))['analyze']
results = []
trials = []
for rep in range(a.repeats):
    profiles = a.profiles if rep % 2 == 0 else list(reversed(a.profiles))
    arms = a.compressions if rep % 2 == 0 else list(reversed(a.compressions))
    homes = [a.home] + ([a.compare_home] if a.compare_home else [])
    if rep % 2:
        homes.reverse()
    for profile in profiles:
        for compression in arms:
            for kind in a.kinds:
                for home in homes:
                    name = '%s-%s-%s-%s-%d-%s' % (a.prefix, profile, compression, kind, rep, home)
                    trials.append(dict(name=name, home=home, profile=profile, compression=compression,
                                       kind=kind, rep=rep, expected=1 if kind == 'bulk' else 100, status='not_attempted'))
manifest = dict(pid=os.getpid(), status='running', expected=sum(t['expected'] for t in trials), trials=trials)
def save_manifest():
    (output / 'plan.json').write_text(json.dumps(manifest, indent=2) + '\n')
save_manifest()
(output / 'summary.json').write_text('[]\n')

def run(label, args, timeout=120):
    command = [str(item) for item in args]
    started = time.monotonic()
    path = output / (label + '.json')
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        def text(value):
            return value.decode(errors='replace') if isinstance(value, bytes) else value or ''
        record = dict(argv=command, exit=None, error='timeout', elapsed_s=time.monotonic() - started,
                      stdout=text(error.stdout), stderr=text(error.stderr))
        path.write_text(json.dumps(record, indent=2) + '\n')
        raise RuntimeError(label + ': timeout; see ' + str(path)) from None
    record = dict(argv=command, exit=result.returncode, elapsed_s=time.monotonic() - started,
                  stdout=result.stdout, stderr=result.stderr)
    path.write_text(json.dumps(record, indent=2) + '\n')
    if result.returncode:
        raise RuntimeError(label + ': exit %d; see %s' % (result.returncode, path))
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

def cohort(trial):
    name, home, kind = trial['name'], trial['home'], trial['kind']
    select_home(home, name)
    directory = root / name
    args = ['python3', root / 'run-echo.py', 'cohort', root, '--home', home, '--name', name,
            '--compression', trial['compression'], '--count', trial['expected'],
            '--interval', 5 if kind == 'burst' else 150]
    if kind == 'bulk':
        args.append('--burst')
    try:
        run(name + '-create', args)
        deadline = time.monotonic() + 30
        while True:
            trace = directory / 'ssh.jsonl'
            if trace.exists() and any(json.loads(line).get('stage') == 'viewer.received' for line in trace.read_text().splitlines()):
                break
            assert time.monotonic() < deadline, 'terminal SSH attach never delivered output'
            time.sleep(.01)
        for action in ['prepare', 'observe', 'type', 'wait']:
            run(name + '-' + action, ['python3', root / 'native-echo.py', action, root, name, '--home', home])
        if trial['rep'] == 0:
            run(name + '-capture', ['python3', root / 'native-echo.py', 'capture', root, name, '--home', home])
    finally:
        if (directory / 'config.json').exists():
            run(name + '-finish', ['python3', root / 'native-echo.py', 'finish', root, name, '--home', home])

def analyze_trial(trial):
    result, _ = analyzer(root / trial['name'])
    results.append(result)
    (output / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
    trial.update(complete=result['complete'], valid=result['valid'])
    print(json.dumps(dict(name=trial['name'], valid=result['valid'], complete=result['complete'], expected=result['expected'], stages=result['stages'])), flush=True)
    return result

try:
    shaped = None
    for trial in trials:
        if (output / 'stop').exists():
            manifest['status'] = 'stopped'
            break
        profile, rep = trial['profile'], trial['rep']
        if shaped != (profile, rep):
            run('shape-%s-%d' % (profile, rep), ['python3', root / 'shape-link.py', profile, root])
            shaped = profile, rep
            if rep == 0:
                run('calibrate-' + profile, ['python3', root / 'calibrate-link.py', root, profile])
        trial['status'] = 'running'
        save_manifest()
        try:
            cohort(trial)
        except BaseException as error:
            trial.update(status='failed', error=type(error).__name__ + ': ' + str(error))
            if (root / trial['name'] / 'config.json').exists():
                try:
                    analyze_trial(trial)
                except Exception as analysis_error:
                    trial['analysis_error'] = str(analysis_error)
            save_manifest()
            raise
        result = analyze_trial(trial)
        trial['status'] = 'complete' if result['valid'] else 'failed'
        save_manifest()
        if not result['valid']:
            raise RuntimeError(trial['name'] + ': invalid cohort; retained all expected samples')
    else:
        manifest['status'] = 'complete'
except BaseException as error:
    manifest.update(status='failed', error=type(error).__name__ + ': ' + str(error))
    for trial in trials:
        if trial['status'] == 'running':
            trial.update(status='failed', error=type(error).__name__ + ': ' + str(error))
    raise
finally:
    try:
        if (root / 'shaper-state.json').exists():
            run('shaping-teardown', ['python3', root / 'shape-link.py', 'clear', root])
    except BaseException as error:
        manifest['teardown_error'] = str(error)
        raise
    finally:
        save_manifest()
if manifest['status'] == 'stopped':
    raise SystemExit(130)
