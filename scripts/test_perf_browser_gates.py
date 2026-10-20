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

    def test_sharp_only_or_ambiguous_marker_is_not_an_early_motion_response(self):
        motion = {"ts_ms": 120, "refresh": False, "format": "h264"}
        sharp = {"ts_ms": 200, "refresh": True, "format": "h264"}
        for captured in ((210, 230), (180, 220)):
            marker = {"started_ms": captured[0], "ended_ms": captured[1], "png": "native.png"}
            result = gates.visible_gate(marker, 100, "relay", motion, sharp)
            self.assertEqual(result["status"], "late_marker")
            self.assertNotIn("latency_ms", result)
        first_sharp_event = {"ts_ms": 120, "refresh": True, "format": "h264"}
        first_sharp = gates.visible_gate({"started_ms": 100, "ended_ms": 150, "png": "native.png"},
                                        90, "relay", first_sharp_event, first_sharp_event)
        self.assertEqual(first_sharp["status"], "complete")
        self.assertEqual(first_sharp["phase"], "first_covering_sharp")

    def test_jpeg_has_no_sharp_refinement_deadline(self):
        result = gates.sharp_gate({"format": "jpeg", "ts_ms": 150}, None, 110, 100)
        self.assertEqual(result["status"], "not_applicable")
        self.assertNotIn("latency_ms", result)

    def test_batch_shape_distinguishes_merged_clicks_from_split_or_missing_sends(self):
        queued = [{"stage": "input.queued", "stream": "page", "seq": 5, "ts_ms": 110},
                  {"stage": "input.queued", "stream": "page", "seq": 6, "ts_ms": 111}]
        merged = gates.input_batch_shape(queued + [
            {"stage": "input.sent", "stream": "page", "first_seq": 5, "seq": 6, "ts_ms": 112}], "page", 100, 200)
        self.assertEqual((merged["status"], merged["request_count"], merged["queue_span_ms"]), ("complete", 1, 1))
        split = queued + [
            {"stage": "input.sent", "stream": "page", "first_seq": 5, "seq": 5, "ts_ms": 112},
            {"stage": "input.sent", "stream": "other", "first_seq": 5, "seq": 6, "ts_ms": 113},
            {"stage": "input.sent", "stream": "page", "first_seq": 6, "seq": 6, "ts_ms": 180}]
        self.assertEqual(gates.input_batch_shape(split, "page", 100, 150)["status"], "missing")
        complete = gates.input_batch_shape(split, "page", 100, 200)
        self.assertEqual((complete["status"], complete["request_count"]), ("complete", 2))


if __name__ == "__main__":
    unittest.main()
