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
    def cohort(self, rows, count=1):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'config.json').write_text(json.dumps({'count': count}))
            (root / 'events.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
            return echo.analyze(root)[0]

    def rows(self):
        return [
            {'stage': 'viewer.key', 'seq': 1, 'ts_ms': 1, 'ascii': [97]},
            {'stage': 'ssh.input', 'ts_ms': 2, 'write_end_ms': 2.1, 'bytes': 1, 'offset_start': 0, 'offset_end': 1, 'hex': '61'},
            {'stage': 'host_pty_write', 'seq': 1, 'ts_ms': 3},
            {'stage': 'host_output_read_call', 'ts_ms': 4, 'offset': 0, 'bytes': 10},
            {'stage': 'host_output_read', 'seq': 1, 'ts_ms': 9, 'marker_start_offset': 14},
            {'stage': 'viewer.received', 'ts_ms': 5, 'offset_start': 0, 'offset_end': 10},
            {'stage': 'viewer.received.marker', 'seq': 1, 'ts_ms': 10, 'offset_start': 14},
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


if __name__ == '__main__':
    unittest.main()
