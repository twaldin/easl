import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest

spec = importlib.util.spec_from_file_location('terminal_echo', Path(__file__).parent / 'terminal-echo/analyze-echo.py')
echo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(echo)


class TerminalEchoAnalysisTests(unittest.TestCase):
    def cohort(self, rows, count=1, burst=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'config.json').write_text(json.dumps({'count': count, 'burst': burst}))
            (root / 'events.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
            return echo.analyze(root)[0]

    def rows(self):
        return [
            {'stage': 'viewer.key', 'seq': 1, 'ts_ms': 1, 'ascii': [97]},
            {'stage': 'ssh.input', 'pid': 11, 'ts_ms': 2, 'write_end_ms': 2.1, 'bytes': 1, 'offset_start': 0, 'offset_end': 1, 'hex': '61'},
            {'stage': 'host_pty_write', 'seq': 1, 'ts_ms': 3},
            {'stage': 'host_output_read_call', 'pid': 22, 'ts_ms': 4, 'offset': 0, 'bytes': 10},
            {'stage': 'host_output_read', 'pid': 22, 'seq': 1, 'ts_ms': 9, 'marker_start_offset': 14},
            {'stage': 'viewer.received', 'pid': 11, 'ts_ms': 5, 'offset_start': 0, 'offset_end': 10},
            {'stage': 'viewer.received.marker', 'pid': 11, 'seq': 1, 'ts_ms': 10, 'offset_start': 14},
            {'stage': 'surface.updated', 'seq': 1, 'ts_ms': 5.5},
            {'stage': 'screen.glyph', 'seq': 1, 'ts_ms': 6, 'receipt_ms': 8, 'observer_ms': 2},
            {'stage': 'host_trace_summary', 'dropped': 0, 'input_keys': 1, 'output_markers': 1},
        ]

    def test_split_marker_does_not_move_glyph_receipt_to_a_later_read(self):
        result = self.cohort(self.rows())
        self.assertTrue(result['valid'])
        self.assertEqual(result['stages']['echo_frame']['median_ms'], 5)
        self.assertEqual(result['stages']['output_received']['median_ms'], 1)
        self.assertEqual(result['stages']['echo_native_receipt']['median_ms'], 7)
        self.assertAlmostEqual(result['stages']['key_ssh']['median_ms'], 1.1)

    def test_missing_native_frame_invalidates_the_series(self):
        rows = [row for row in self.rows() if row['stage'] != 'screen.glyph']
        result = self.cohort(rows)
        self.assertFalse(result['valid'])
        self.assertEqual((result['expected'], result['complete']), (1, 0))
        self.assertNotIn('echo_frame', result['stages'])

    def test_duplicate_glyph_is_not_a_second_successful_sample(self):
        rows = self.rows()
        rows.append({'stage': 'screen.glyph', 'seq': 1, 'ts_ms': 7, 'receipt_ms': 9, 'observer_ms': 2})
        result = self.cohort(rows)
        self.assertFalse(result['valid'])
        self.assertEqual(result['complete'], 1)

    def test_marker_without_actual_pty_read_coverage_cannot_qualify(self):
        rows = [row for row in self.rows() if row['stage'] != 'host_output_read_call']
        next(row for row in rows if row['stage'] == 'host_output_read')['ts_ms'] = 4
        self.assertFalse(self.cohort(rows)['valid'])

    def test_marker_without_viewer_byte_coverage_cannot_qualify(self):
        rows = [row for row in self.rows() if row['stage'] != 'viewer.received']
        next(row for row in rows if row['stage'] == 'viewer.received.marker')['ts_ms'] = 5
        self.assertFalse(self.cohort(rows)['valid'])

    def test_empty_series_cannot_qualify_without_any_keystrokes(self):
        rows = [{'stage': 'host_trace_summary', 'dropped': 0, 'input_keys': 0, 'output_markers': 0}]
        self.assertFalse(self.cohort(rows, count=0)['valid'])

    def test_cli_reports_invalid_series_as_failure_and_retains_the_analysis(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'config.json').write_text(json.dumps({'count': 1}))
            rows = [row for row in self.rows() if row['stage'] != 'screen.glyph']
            (directory / 'events.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
            result = subprocess.run([sys.executable, echo.__file__, str(directory)], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            retained = json.loads((directory / 'analysis.json').read_text())
            self.assertFalse(retained['valid'])
            self.assertEqual(retained['expected'], 1)
            self.assertEqual(retained['complete'], 0)

    def test_truncated_bulk_cannot_borrow_another_sessions_complete_seq_body(self):
        rows = self.rows()
        marker = b'\x1b]777;easl-echo;1\x07'
        payload = b'1\r\n2\r\na\x1b[0m' + marker
        start = len(payload) - len(marker)
        next(row for row in rows if row['stage'] == 'host_output_read_call')['bytes'] = len(payload)
        next(row for row in rows if row['stage'] == 'host_output_read')['marker_start_offset'] = start
        next(row for row in rows if row['stage'] == 'viewer.received').update(offset_end=len(payload), hex=payload.hex())
        next(row for row in rows if row['stage'] == 'viewer.received.marker')['offset_start'] = start
        unrelated = b''.join(str(value).encode() + b'\r\n' for value in range(1, 20001))
        rows.append({'stage': 'viewer.received', 'pid': 99, 'ts_ms': 5, 'offset_start': 0,
                     'offset_end': len(unrelated), 'hex': unrelated.hex()})
        result = self.cohort(rows, burst=True)
        self.assertFalse(result['valid'])
        self.assertEqual((result['expected'], result['complete']), (1, 1))
        self.assertFalse(result['burst_bytes_valid'])

    def test_unexpected_input_is_retained_as_an_invalid_cohort(self):
        rows = self.rows()
        next(row for row in rows if row['stage'] == 'ssh.input')['hex'] = '62'
        result = self.cohort(rows)
        self.assertFalse(result['valid'])
        self.assertEqual((result['expected'], result['complete']), (1, 1))

    def test_background_ssh_read_cannot_move_the_glyph_receipt(self):
        rows = self.rows()
        rows.insert(0, {'stage': 'viewer.received', 'pid': 99, 'ts_ms': 4.5,
                        'offset_start': 0, 'offset_end': 10})
        result = self.cohort(rows)
        self.assertTrue(result['valid'])
        self.assertEqual(result['stages']['output_received']['median_ms'], 1)

    def test_two_input_producers_cannot_qualify_as_one_series(self):
        rows = self.rows()
        rows.append({'stage': 'ssh.input', 'pid': 99, 'ts_ms': 2.2, 'write_end_ms': 2.3,
                     'bytes': 1, 'offset_start': 0, 'offset_end': 1, 'hex': '61'})
        self.assertFalse(self.cohort(rows)['valid'])

    def test_a_second_marker_producer_is_not_ignored_outside_the_expected_range(self):
        rows = self.rows()
        rows.append({'stage': 'viewer.received.marker', 'pid': 99, 'seq': 2, 'ts_ms': 10, 'offset_start': 14})
        self.assertFalse(self.cohort(rows)['valid'])

    def test_a_compression_request_does_not_qualify_the_wrong_negotiated_arm(self):
        rows = self.rows()
        rows.append({'stage': 'ssh.transport', 'pid': 11, 'ts_ms': 11,
                     'options': ['compression yes'],
                     'negotiated_compression': {'server->client': 'none', 'client->server': 'none'}})
        result = self.cohort(rows)
        self.assertFalse(result['valid'])
        self.assertEqual(result['complete'], 1)


if __name__ == '__main__':
    unittest.main()
