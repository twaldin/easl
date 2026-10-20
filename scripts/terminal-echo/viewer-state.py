import argparse
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--pid', required=True)
parser.add_argument('--log', required=True, type=Path)
parser.add_argument('--input-helper', required=True)
parser.add_argument('--out', type=Path)
args = parser.parse_args()
with args.log.open() as log:
    log.seek(0, 2)
    result = subprocess.run([args.input_helper, json.dumps({'pid': args.pid, 'kind': 'state'})], capture_output=True, text=True, check=True, timeout=10)
    deadline = time.monotonic() + 10
    pending = ''
    while time.monotonic() < deadline:
        pending += log.read()
        lines = pending.split('\n')
        pending = lines.pop()
        for line in lines:
            if 'DevInput.state ' in line:
                windows = json.loads(line.split('DevInput.state ', 1)[1])
                record = {'input_timestamp_ms': float(result.stdout), 'windows': windows, 'meaning': 'Actual viewer model state, not native presentation'}
                if args.out:
                    args.out.write_text(json.dumps(record, indent=2) + '\n')
                print(json.dumps(record, indent=2))
                raise SystemExit(0)
        time.sleep(.005)
raise TimeoutError('Viewer state receipt missing')
