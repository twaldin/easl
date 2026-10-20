import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("browser_gates", Path(__file__).with_name("perf-browser-gates.py"))
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)


class BrowserGateTests(unittest.TestCase):
    def test_new_input_and_other_streams_cannot_supply_the_sharp_endpoint(self):
        events = [
            {"stage": "input.queued", "stream": "page", "seq": 5, "ts_ms": 100},
            {"stage": "image.assigned", "stream": "page", "seq": 20, "input": 5, "refresh": True, "ts_ms": 150},
            {"stage": "input.queued", "stream": "page", "seq": 6, "ts_ms": 160},
            {"stage": "image.assigned", "stream": "page", "seq": 21, "input": 6, "refresh": False, "ts_ms": 180},
            {"stage": "input.queued", "stream": "other", "seq": 6, "ts_ms": 220},
            {"stage": "image.assigned", "stream": "other", "seq": 22, "input": 6, "refresh": True, "ts_ms": 230},
            {"stage": "image.assigned", "stream": "page", "seq": 22, "input": 6, "refresh": True, "ts_ms": 300},
        ]
        watermark, last_input, covering, sharp = gates.endpoints(events, "page", 90, 400)
        self.assertEqual((watermark, last_input), (6, 160))
        self.assertEqual(covering["seq"], 21)
        self.assertEqual(sharp["ts_ms"] - last_input, 140)
        self.assertIsNone(gates.endpoints(events, "page", 90, 250)[3])

    def test_missing_and_failed_trials_remain_in_the_denominator(self):
        rows = [{"gate_a": {"status": "complete", "latency_ms": 100}},
                {"gate_a": {"status": "source_count_failure"}},
                {"gate_a": {"status": "deadline_failure"}},
                {"gate_a": {"status": "complete", "latency_ms": 300}}]
        summary = gates.summarize(rows, "gate_a")
        self.assertEqual(summary["denominator"], 4)
        self.assertEqual(summary["outcomes"], {"complete": 2, "source_count_failure": 1, "deadline_failure": 1})
        self.assertEqual(summary["completed_subset"], {"n": 2, "median_ms": 200, "p95_ms": 300, "max_ms": 300})


if __name__ == "__main__":
    unittest.main()
