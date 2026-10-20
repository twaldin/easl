#!/usr/bin/env python3
import argparse
import json
import math
from pathlib import Path
import sqlite3
import statistics


def percentile(values, p):
    return sorted(values)[max(0, math.ceil(len(values) * p) - 1)]


def stats(values):
    return {'n': len(values), 'median_ms': statistics.median(values), 'p95_ms': percentile(values, .95),
            'min_ms': min(values), 'max_ms': max(values)} if values else {'n': 0}


def read_rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def analyze(directory):
    config = json.loads((directory / 'config.json').read_text())
    count = config.get('count', 100)
    rows = []
    for path in sorted(directory.rglob('*.jsonl')):
        rows.extend(dict(source=str(path.relative_to(directory)), **row) for row in read_rows(path))
    by_seq = {seq: {} for seq in range(1, count + 1)}
    errors = []
    if count <= 0:
        errors.append({'error': 'expected a positive keystroke count', 'expected': count})
    stage_map = {'viewer.key': 'key', 'host_pty_write': 'pty', 'host_output_read': 'host_output',
                 'viewer.received.marker': 'received', 'surface.updated': 'surface', 'screen.glyph': 'glyph',
                 'fixture.received': 'fixture', 'fixture.output': 'fixture_output'}
    for row in rows:
        stage = row.get('stage')
        if stage == 'ssh.input':
            assert row.get('hex') == '61' * row['bytes'], ('unexpected terminal input', row)
            for offset in range(row['offset_start'], row['offset_end']):
                if offset + 1 in by_seq:
                    by_seq[offset + 1]['ssh'] = dict(row, ts_ms=row['write_end_ms'])
        if stage in stage_map and row.get('seq') in by_seq:
            seq = row['seq']
            key = stage_map[stage]
            if key in by_seq[seq]:
                errors.append({'seq': seq, 'error': 'duplicate stage', 'stage': stage})
            by_seq[seq][key] = row
        if stage and ('error' in stage or 'missing' in stage):
            errors.append(row)
    summaries = [row for row in rows if row.get('stage') == 'host_trace_summary']
    if len(summaries) != 1 or summaries[0]['dropped'] or summaries[0]['input_keys'] != count or summaries[0]['output_markers'] != count:
        errors.append({'error': 'incomplete host syscall trace', 'summaries': summaries})
    host_reads = [row for row in rows if row.get('stage') == 'host_output_read_call' and row['bytes'] > 0]
    viewer_reads = [row for row in rows if row.get('stage') == 'viewer.received']
    for seq, stages in by_seq.items():
        if 'host_output' in stages:
            end = stages['host_output']['marker_start_offset'] - 4
            call = next((row for row in host_reads if row['offset'] < end <= row['offset'] + row['bytes']), None)
            if call:
                stages['host_output'] = call
            else:
                errors.append({'seq': seq, 'error': 'glyph has no actual host PTY read coverage'})
        if 'received' in stages:
            end = stages['received']['offset_start'] - 4
            call = next((row for row in viewer_reads if row['offset_start'] < end <= row['offset_end']), None)
            if call:
                stages['received'] = call
            else:
                errors.append({'seq': seq, 'error': 'glyph has no viewer byte read coverage'})
    samples = []
    required = ['key', 'ssh', 'pty', 'host_output', 'received', 'surface', 'glyph']
    for seq, stages in by_seq.items():
        missing = [stage for stage in required if stage not in stages]
        if missing:
            errors.append({'seq': seq, 'error': 'missing stages', 'missing': missing})
            continue
        times = {key: value['ts_ms'] for key, value in stages.items()}
        if stages['key'].get('ascii') != [97]:
            errors.append({'seq': seq, 'error': 'not native ASCII a', 'key': stages['key']})
        if not times['key'] <= times['ssh'] <= times['pty'] <= times['host_output'] <= times['received'] <= times['glyph']:
            errors.append({'seq': seq, 'error': 'causal timestamp violation', 'times': times})
        sample = {'seq': seq, 'key_ssh': times['ssh'] - times['key'], 'ssh_pty': times['pty'] - times['ssh'],
                  'pty_output': times['host_output'] - times['pty'], 'output_received': times['received'] - times['host_output'],
                  'received_surface': times['surface'] - times['received'], 'surface_frame': times['glyph'] - times['surface'],
                  'echo_frame': times['glyph'] - times['key'],
                  'echo_native_receipt': stages['glyph']['receipt_ms'] - times['key'],
                  'observer': stages['glyph']['observer_ms']}
        samples.append(sample)
    deltas = {name: stats([row[name] for row in samples]) for name in samples[0] if name != 'seq'} if samples else {}
    result = {'directory': str(directory), 'config': config, 'expected': count, 'complete': len(samples),
              'valid': len(samples) == count and not errors, 'errors': errors, 'stages': deltas, 'samples': samples}
    (directory / 'analysis.json').write_text(json.dumps(result, indent=2) + '\n')
    return result, rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directories', nargs='+', type=Path)
    parser.add_argument('--database', type=Path)
    args = parser.parse_args()
    database = sqlite3.connect(args.database) if args.database else None
    valid = True
    if database:
        database.executescript('CREATE TABLE IF NOT EXISTS series (name TEXT PRIMARY KEY, result TEXT NOT NULL); CREATE TABLE IF NOT EXISTS events (series TEXT, event TEXT);')
    for directory in args.directories:
        result, rows = analyze(directory)
        valid = valid and result['valid']
        print(json.dumps({key: value for key, value in result.items() if key not in ('samples', 'errors')}), flush=True)
        if database:
            database.execute('INSERT OR REPLACE INTO series VALUES (?, ?)', (str(directory), json.dumps(result)))
            database.execute('DELETE FROM events WHERE series = ?', (str(directory),))
            database.executemany('INSERT INTO events VALUES (?, ?)', [(str(directory), json.dumps(row)) for row in rows])
    if database:
        database.commit()
        database.close()
    if not valid:
        raise SystemExit('one or more echo series are incomplete or invalid')


if __name__ == '__main__':
    main()
