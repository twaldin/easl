import importlib.util
import copy
import io
import json
from pathlib import Path
import unittest
from types import SimpleNamespace
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("browser_gates", Path(__file__).with_name("perf-browser-gates.py"))
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)


def native_frame(lower=150, upper=151):
    display = 9_007_199_254_741_001
    bridge = {"a_ticks": str(display + 1000), "b_ticks": str(display + 1000 + round((upper - lower) * 1000)),
              "epoch_ms": upper + 1, "timebase_numer": 1000, "timebase_denom": 1}
    return {"stage": "screen.observed", "frame_status": 0, "clock_valid": True,
            "bridge": bridge, "origin_bridge": copy.deepcopy(bridge),
            "display_ticks": str(display), "receipt_ticks": str(display + 500),
            "display_epoch_lower_ms": lower, "display_epoch_upper_ms": upper,
            "png": "native.png", "receipt": "native.json"}


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
        summary = gates.summarize(rows, "gate_a", 5)
        self.assertEqual(summary["denominator"], 5)
        self.assertEqual(summary["outcomes"], {"complete": 2, "source_count_failure": 1, "deadline_failure": 1, "not_attempted": 1})
        self.assertEqual(summary["completed_subset"], {"n": 2, "median_ms": 200, "p95_ms": 300, "max_ms": 300})

    def test_sharp_only_or_ambiguous_marker_is_not_an_early_motion_response(self):
        motion = {"ts_ms": 120, "refresh": False, "format": "h264"}
        sharp = {"ts_ms": 200, "refresh": True, "format": "h264"}
        for captured in ((210, 211), (199.5, 200.5)):
            marker = native_frame(*captured)
            result = gates.visible_gate(marker, 100, "relay", motion, sharp)
            self.assertEqual(result["status"], "late_marker")
            self.assertNotIn("latency_ms", result)
        first_sharp_event = {"ts_ms": 120, "refresh": True, "format": "h264"}
        for captured in ((100, 101), (149, 150)):
            first_sharp = gates.visible_gate(native_frame(*captured), 90, "relay",
                                            first_sharp_event, first_sharp_event)
            self.assertEqual(first_sharp["status"], "first_covering_sharp")
            self.assertEqual(first_sharp["phase"], "first_covering_sharp")
            self.assertNotIn("latency_ms", first_sharp)

    def test_jpeg_has_no_sharp_refinement_deadline(self):
        probe = {"stage": "image.assigned", "stream": "page", "input": 6, "format": "h264", "ts_ms": 150}
        events = [probe, {"stage": "image.assigned", "stream": "page", "input": 6, "format": "jpeg", "ts_ms": 170},
                  {"stage": "image.assigned", "stream": "other", "input": 6, "format": "h264", "ts_ms": 180}]
        image_format = gates.last_assigned_format(events, "page", 6, 100, 200)
        result = gates.sharp_gate(probe, None, 110, 100, 6, image_format)
        self.assertEqual(result["status"], "not_applicable")
        self.assertNotIn("latency_ms", result)

    def test_later_watermark_jpeg_cannot_hide_missing_refinement(self):
        motion = {"stage": "image.assigned", "stream": "page", "input": 6, "format": "h264", "ts_ms": 150}
        later = {"stage": "image.assigned", "stream": "page", "input": 7, "format": "jpeg", "ts_ms": 170}
        for assignments in ([motion, later], [later]):
            image_format = gates.last_assigned_format(assignments, "page", 6, 100, 200)
            result = gates.sharp_gate(assignments[0], None, 110, 100, 6, image_format)
            self.assertEqual(result["status"], "deadline_failure")

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

    def test_display_upper_bound_not_receipt_or_png_completion_is_gate_a(self):
        marker = native_frame(150, 151)
        marker.update(started_ms=800, ended_ms=900)
        direct = gates.visible_gate(marker, 100, "direct", deadline_ms=200)
        self.assertEqual((direct["status"], direct["latency_ms"]), ("complete", 51))
        motion = {"ts_ms": 120, "refresh": False, "format": "h264"}
        sharp = {"ts_ms": 200, "refresh": True}
        relay = gates.visible_gate(marker, 100, "relay", motion, sharp, 200)
        self.assertEqual((relay["status"], relay["latency_ms"], relay["phase"]), ("complete", 51, "h264"))

    def test_invalid_or_missing_native_clocks_cannot_pass(self):
        corruptions = [
            lambda m: m.update(clock_valid=False),
            lambda m: m.update(frame_status=1),
            lambda m: m.update(display_ticks=str(int(m["receipt_ticks"]) + 1)),
            lambda m: m["bridge"].update(timebase_denom=0),
            lambda m: m["bridge"].update(epoch_ms=m["bridge"]["epoch_ms"] + 100),
            lambda m: m["origin_bridge"].update(epoch_ms=m["origin_bridge"]["epoch_ms"] - 20),
            lambda m: m.update(display_epoch_upper_ms=150),
            lambda m: m.update(display_epoch_upper_ms=float("nan")),
            lambda m: m.pop("receipt"),
            lambda m: m.pop("origin_bridge"),
        ]
        for corrupt in corruptions:
            marker = native_frame()
            corrupt(marker)
            with self.subTest(marker=marker):
                self.assertEqual(gates.visible_gate(marker, 100, "direct")["status"], "invalid_observation")
        self.assertEqual(gates.visible_gate(None, 100, "direct")["status"], "deadline_failure")
        self.assertEqual(gates.visible_gate({"ended_ms": 150, "png": "cua.png"}, 100, "direct")["status"],
                         "invalid_observation")

    def test_input_deadline_and_assignment_intervals_do_not_hide_uncertainty(self):
        motion = {"ts_ms": 120, "refresh": False, "format": "h264"}
        self.assertEqual(gates.visible_gate(native_frame(99, 101), 100, "direct")["status"], "invalid_observation")
        self.assertEqual(gates.visible_gate(native_frame(150, 151), 100, "direct", deadline_ms=150)["status"],
                         "deadline_failure")
        self.assertEqual(gates.visible_gate(native_frame(119, 121), 100, "relay", motion)["status"], "ambiguous_marker")
        self.assertEqual(gates.visible_gate(native_frame(), 100, "relay")["status"], "missing_assignment")

    def test_native_events_do_not_break_or_supply_input_batch_evidence(self):
        events = [{"stage": "screen.ready", "ts_ms": 90}, {"stage": "screen.observed", "ts_ms": 150},
                  {"stage": "input.queued", "stream": "page", "seq": 5, "ts_ms": 110},
                  {"stage": "input.sent", "stream": "page", "first_seq": 5, "seq": 5, "ts_ms": 111}]
        self.assertEqual(gates.input_batch_shape(events, "page", 100, 200)["request_count"], 1)

    def test_foreign_window_or_session_receipts_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            observer = gates.Observer.__new__(gates.Observer)
            observer.config = {"pid": 12, "window": 34}
            observer.session = "owned"
            observer.native_directory = Path(temp)
            observer.native_events = []
            for identity in ((13, 34, "owned"), (12, 35, "owned"), (12, 34, "stale")):
                gates.save(Path(temp) / "ready.json", dict(zip(("pid", "window", "session"), identity)))
                with self.assertRaises(RuntimeError):
                    observer._receipt("ready.json")

    def test_stop_clock_failure_invalidates_previously_completed_rows(self):
        def stopped_after_clock_step():
            raise RuntimeError("clock step")

        with tempfile.TemporaryDirectory() as temp:
            rows = [{"sample": 1, "gate_a": {"status": "complete", "latency_ms": 51}}]
            observer = SimpleNamespace(stop=stopped_after_clock_step,
                                       native_events=[{"stage": "screen.error", "error": "clock step"}])
            gates.finish_observation(observer, rows, Path(temp))
            summary = gates.summarize(rows, "gate_a", 3)
            self.assertEqual(summary["outcomes"], {"invalid_observation": 1, "not_attempted": 2})
            self.assertEqual(summary["completed_subset"]["n"], 0)
            self.assertIn("clock step", rows[0]["native_session_error"])

    def test_cua_target_match_cannot_rescue_missing_native_observation(self):
        class MissingNativeObserver:
            def __init__(self, config, directory):
                self.pixel, self.native_events = [0, 0, 0], []
            def start(self): return {}
            def capture(self, label): return {"pixel": [50, 50, 75], "ended_ms": gates.epoch_ms()}
            def arm(self, label, target): return {}
            def point(self, *args, **kwargs): return (1, 1)
            def poll(self): return None
            def check(self): pass
            def stop(self): pass
            def close(self): pass

        class CounterSource:
            def __init__(self, config): self.counter_reads = 0
            def call(self, method, params):
                script = params["params"]["script"]
                if script == "Number(clicks)":
                    self.counter_reads += 1
                    return {"value": self.counter_reads}
                return {"value": True}
            def close(self): pass

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "helper").write_text("fixture")
            (root / "app.log").write_text("")
            config = {"scratch": temp, "dev_home": temp, "board": "b", "tile": "t", "mode": "direct",
                      "pid": 1, "window": 2, "viewport": {}, "input_helper": str(root / "helper"),
                      "count_region": [0, 0, 1, 1], "deadline_s": .002}
            child = SimpleNamespace(stdout=io.StringIO(str(gates.epoch_ms()) + "\n"),
                                    communicate=lambda timeout: ("", ""), returncode=0)
            args = SimpleNamespace(count=1, label="missing", block=1, action="click")
            with patch.object(gates, "Observer", MissingNativeObserver), patch.object(gates, "Source", CounterSource), \
                    patch.object(gates.subprocess, "Popen", return_value=child), \
                    patch.object(gates.select, "select", return_value=([child.stdout], [], [])), \
                    patch("sys.stdout", new_callable=io.StringIO):
                result = gates.run(config, args)
            summary_path = next(root.glob("gates-*/summary.json"))
            summary = json.loads(summary_path.read_text())
            self.assertEqual(result, 1)
            self.assertEqual(summary["gate_a"]["outcomes"], {"deadline_failure": 1})
            self.assertEqual(summary["gate_a"]["completed_subset"]["n"], 0)


if __name__ == "__main__":
    unittest.main()
