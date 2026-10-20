import importlib.util
import io
import json
from pathlib import Path
import unittest
from types import SimpleNamespace
import tempfile
import time
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("browser_gates", Path(__file__).with_name("perf-browser-gates.py"))
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)


def trace_event(ts_ms, **fields):
    return {"clock_domain": "mach_absolute_time", "timebase_numer": 1000, "timebase_denom": 1,
            "ts_ticks": str(round(ts_ms * 1000)), "ts_ms": ts_ms, **fields}


def native_frame(display_ms=150, numer=1000, denom=1, display_ticks=None):
    ticks_per_ms = 1e6 * denom / numer
    display = round(display_ms * ticks_per_ms) if display_ticks is None else display_ticks
    receipt = display + round(ticks_per_ms)
    a = receipt + round(ticks_per_ms / 4)
    b = a + round(ticks_per_ms / 4)
    clock = {"clock_domain": "mach_absolute_time", "a_ticks": str(a), "b_ticks": str(b),
             "timebase_numer": numer, "timebase_denom": denom}
    return {"stage": "screen.observed", "frame_status": 0, "clock_valid": True,
            "clock": clock, "origin_clock": {**clock, "a_ticks": "1", "b_ticks": "2"},
            "clock_domain": "mach_absolute_time", "timebase_numer": numer, "timebase_denom": denom,
            "ts_ticks": str(b), "ts_ms": b * numer / denom / 1e6,
            "display_ticks": str(display), "receipt_ticks": str(receipt),
            "arm_ticks": str(display - round(ticks_per_ms)),
            "display_ms": display * numer / denom / 1e6,
            "png": "native.png", "receipt": "native.json"}


class BrowserGateTests(unittest.TestCase):
    def test_new_input_and_other_streams_cannot_supply_the_sharp_endpoint(self):
        events = [
            trace_event(100, stage="input.queued", stream="page", seq=5),
            trace_event(150, stage="image.assigned", stream="page", seq=20, input=5, refresh=True),
            trace_event(160, stage="input.queued", stream="page", seq=6),
            trace_event(180, stage="image.assigned", stream="page", seq=21, input=6, refresh=False),
            trace_event(220, stage="input.queued", stream="other", seq=6),
            trace_event(230, stage="image.assigned", stream="other", seq=22, input=6, refresh=True),
            trace_event(300, stage="image.assigned", stream="page", seq=22, input=6, refresh=True),
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

    def test_sharp_only_or_late_marker_is_not_an_early_motion_response(self):
        motion = trace_event(120, refresh=False, format="h264")
        sharp = trace_event(200, refresh=True, format="h264")
        for displayed in (200, 210):
            result = gates.visible_gate(native_frame(displayed), 100, "relay", motion, sharp)
            self.assertEqual(result["status"], "late_marker")
            self.assertNotIn("latency_ms", result)
        first_sharp_event = trace_event(120, refresh=True, format="h264")
        for displayed in (100, 150):
            result = gates.visible_gate(native_frame(displayed), 90, "relay", first_sharp_event, first_sharp_event)
            self.assertEqual(result["status"], "first_covering_sharp")
            self.assertNotIn("latency_ms", result)

    def test_jpeg_has_no_sharp_refinement_deadline(self):
        probe = trace_event(150, stage="image.assigned", stream="page", input=6, format="h264")
        events = [probe, trace_event(170, stage="image.assigned", stream="page", input=6, format="jpeg"),
                  trace_event(180, stage="image.assigned", stream="other", input=6, format="h264")]
        image_format = gates.last_assigned_format(events, "page", 6, 100, 200)
        result = gates.sharp_gate(probe, None, 110, 100, 6, image_format)
        self.assertEqual(result["status"], "not_applicable")
        self.assertNotIn("latency_ms", result)

    def test_later_watermark_jpeg_cannot_hide_missing_refinement(self):
        motion = trace_event(150, stage="image.assigned", stream="page", input=6, format="h264")
        later = trace_event(170, stage="image.assigned", stream="page", input=7, format="jpeg")
        for assignments in ([motion, later], [later]):
            image_format = gates.last_assigned_format(assignments, "page", 6, 100, 200)
            result = gates.sharp_gate(assignments[0], None, 110, 100, 6, image_format)
            self.assertEqual(result["status"], "deadline_failure")

    def test_batch_shape_distinguishes_merged_clicks_from_split_or_missing_sends(self):
        queued = [trace_event(110, stage="input.queued", stream="page", seq=5),
                  trace_event(111, stage="input.queued", stream="page", seq=6)]
        merged = gates.input_batch_shape(queued + [
            trace_event(112, stage="input.sent", stream="page", first_seq=5, seq=6)], "page", 100, 200)
        self.assertEqual((merged["status"], merged["request_count"], merged["queue_span_ms"]), ("complete", 1, 1))
        split = queued + [
            trace_event(112, stage="input.sent", stream="page", first_seq=5, seq=5),
            trace_event(113, stage="input.sent", stream="other", first_seq=5, seq=6),
            trace_event(180, stage="input.sent", stream="page", first_seq=6, seq=6)]
        self.assertEqual(gates.input_batch_shape(split, "page", 100, 150)["status"], "missing")
        complete = gates.input_batch_shape(split, "page", 100, 200)
        self.assertEqual((complete["status"], complete["request_count"]), ("complete", 2))

    def test_display_time_not_receipt_or_png_completion_is_gate_a(self):
        marker = native_frame(150, numer=125, denom=3)
        marker.update(started_ms=800, ended_ms=900)
        direct = gates.visible_gate(marker, 100, "direct", deadline_ms=200)
        self.assertEqual((direct["status"], direct["latency_ms"]), ("complete", 50))
        motion = trace_event(120, refresh=False, format="h264")
        sharp = trace_event(200, refresh=True)
        relay = gates.visible_gate(native_frame(150), 100, "relay", motion, sharp, 200)
        self.assertEqual((relay["status"], relay["latency_ms"], relay["phase"]), ("complete", 50, "h264"))

    def test_ticks_above_double_integer_precision_are_not_truncated_during_validation(self):
        ticks = 9_007_199_254_741_001
        marker = native_frame(display_ticks=ticks)
        self.assertAlmostEqual(gates.native_timing(marker), ticks / 1000, delta=.002)
        marker["receipt_ticks"] = str(ticks - 1)
        self.assertEqual(gates.visible_gate(marker, ticks / 1000 - 50, "direct")["status"], "invalid_observation")

    def test_invalid_or_missing_native_clocks_cannot_pass(self):
        corruptions = [
            lambda m: m.update(clock_valid=False),
            lambda m: m.update(frame_status=1),
            lambda m: m.update(display_ticks=str(int(m["receipt_ticks"]) + 1)),
            lambda m: m.update(receipt_ticks=str(int(m["clock"]["a_ticks"]) + 1)),
            lambda m: m.update(arm_ticks=m["display_ticks"]),
            lambda m: m["clock"].update(timebase_denom=0),
            lambda m: m["clock"].update(a_ticks=str(int(m["clock"]["b_ticks"]) + 1)),
            lambda m: m["origin_clock"].update(timebase_numer=999),
            lambda m: m["origin_clock"].update(a_ticks=m["clock"]["b_ticks"], b_ticks=m["clock"]["b_ticks"]),
            lambda m: m.update(clock_domain="epoch"),
            lambda m: m.update(display_ms=151),
            lambda m: m.update(display_ms=float("nan")),
            lambda m: m.update(ts_ticks="1"),
            lambda m: m.pop("receipt"),
            lambda m: m.pop("origin_clock"),
            lambda m: m.pop("clock_domain"),
        ]
        for corrupt in corruptions:
            marker = native_frame()
            corrupt(marker)
            with self.subTest(marker=marker):
                self.assertEqual(gates.visible_gate(marker, 100, "direct")["status"], "invalid_observation")
        self.assertEqual(gates.visible_gate(None, 100, "direct")["status"], "deadline_failure")
        self.assertEqual(gates.visible_gate({"ended_ms": 150, "png": "cua.png"}, 100, "direct")["status"],
                         "invalid_observation")

    def test_clock_sampling_limit_is_not_relaxed(self):
        for span, expected in ((2000, "complete"), (2001, "invalid_observation")):
            marker = native_frame()
            a = int(marker["clock"]["a_ticks"])
            marker["clock"]["b_ticks"] = str(a + span)
            marker.update(ts_ticks=str(a + span), ts_ms=(a + span) / 1000)
            self.assertEqual(gates.visible_gate(marker, 100, "direct")["status"], expected)

    def test_input_deadline_and_assignment_boundaries(self):
        motion = trace_event(120, refresh=False, format="h264")
        self.assertEqual(gates.visible_gate(native_frame(99), 100, "direct")["status"], "invalid_observation")
        self.assertEqual(gates.visible_gate(native_frame(100), 100, "direct")["latency_ms"], 0)
        self.assertEqual(gates.visible_gate(native_frame(150), 100, "direct", deadline_ms=150)["status"], "complete")
        self.assertEqual(gates.visible_gate(native_frame(150.001), 100, "direct", deadline_ms=150)["status"],
                         "deadline_failure")
        self.assertEqual(gates.visible_gate(native_frame(119), 100, "relay", motion)["status"], "ambiguous_marker")
        self.assertEqual(gates.visible_gate(native_frame(120), 100, "relay", motion)["status"], "complete")
        self.assertEqual(gates.visible_gate(native_frame(), 100, "relay")["status"], "missing_assignment")

    def test_input_helper_requires_a_finite_same_clock_launch_read_bracket(self):
        for stamp in ("100", "150.25", "200"):
            self.assertEqual(gates.input_timestamp(stamp, 100, 200), float(stamp))
        for stamp, launched, received in (("99.999", 100, 200), ("200.001", 100, 200),
                                          ("1700000000000", 100, 200), ("nan", 100, 200),
                                          ("inf", 100, 200), ("150", 200, 100),
                                          ("150", float("nan"), 200), ("not-a-number", 100, 200)):
            with self.subTest(stamp=stamp, launched=launched, received=received):
                with self.assertRaises(ValueError):
                    gates.input_timestamp(stamp, launched, received)

    def test_legacy_or_inconsistent_trace_clocks_cannot_supply_gate_b(self):
        for corrupt in (lambda e: e.pop("clock_domain"), lambda e: e.update(clock_domain="epoch"),
                        lambda e: e.update(ts_ms=1700000000000), lambda e: e.update(timebase_denom=0),
                        lambda e: e.update(ts_ms=float("nan"))):
            event = trace_event(110, stage="input.queued", stream="page", seq=5)
            corrupt(event)
            with self.subTest(event=event):
                with self.assertRaises((KeyError, ValueError)):
                    gates.endpoints([event], "page", 100, 200)
        sharp = trace_event(180, stage="image.assigned", stream="page", seq=6, input=5, refresh=True)
        queued = trace_event(110, stage="input.queued", stream="page", seq=5)
        covering = trace_event(130, stage="image.assigned", stream="page", seq=5, input=5, refresh=False)
        watermark, last, motion, refresh = gates.endpoints([queued, covering, sharp], "page", 100, 200)
        self.assertEqual(gates.sharp_gate(motion, refresh, last, 100, watermark)["latency_ms"], 70)
        wrong_timebase = {**sharp, "timebase_numer": 125, "timebase_denom": 3,
                          "ts_ticks": "4320000"}
        with self.assertRaises(ValueError):
            gates.endpoints([queued, wrong_timebase], "page", 100, 200)
        self.assertEqual(gates.visible_gate(native_frame(), 100, "relay", wrong_timebase)["status"],
                         "invalid_observation")

    def test_trace_reader_rejects_old_clock_records(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "app.log"
            path.write_text("")
            trace = gates.Trace(path)
            try:
                with path.open("a") as log:
                    log.write('DevInput.surface {"stage":"input.queued","ts_ms":1700000000000}\n')
                with self.assertRaises((KeyError, ValueError)):
                    trace.poll()
            finally:
                trace.file.close()

    def test_native_events_do_not_break_or_supply_input_batch_evidence(self):
        events = [trace_event(90, stage="screen.ready"), trace_event(150, stage="screen.observed"),
                  trace_event(110, stage="input.queued", stream="page", seq=5),
                  trace_event(111, stage="input.sent", stream="page", first_seq=5, seq=5)]
        self.assertEqual(gates.input_batch_shape(events, "page", 100, 200)["request_count"], 1)
        self.assertEqual(gates.endpoints(events, "page", 100, 200)[:2], (5, 110))

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

    def test_stop_failure_invalidates_previously_completed_rows(self):
        def failed_stop():
            raise RuntimeError("invalid capture clock")

        with tempfile.TemporaryDirectory() as temp:
            rows = [{"sample": 1, "gate_a": {"status": "complete", "latency_ms": 50},
                     "gate_b": {"status": "complete", "latency_ms": 200}}]
            observer = SimpleNamespace(stop=failed_stop, native_events=[{"stage": "screen.error"}])
            gates.finish_observation(observer, rows, Path(temp))
            summary = gates.summarize(rows, "gate_a", 3)
            self.assertEqual(summary["outcomes"], {"invalid_observation": 1, "not_attempted": 2})
            self.assertEqual(summary["completed_subset"]["n"], 0)
            self.assertEqual(gates.summarize(rows, "gate_b", 3)["completed_subset"]["n"], 1)

    def test_cua_target_match_cannot_rescue_missing_native_observation(self):
        class MissingNativeObserver:
            def __init__(self, config, directory):
                self.pixel, self.native_events = [0, 0, 0], []
            def start(self): return {}
            def capture(self, label): return {"pixel": [50, 50, 75], "ended_ms": gates.monotonic_ms()}
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
            child = SimpleNamespace(stdout=SimpleNamespace(readline=lambda: str(gates.monotonic_ms()) + "\n"),
                                    communicate=lambda timeout: ("", ""), returncode=0)
            args = SimpleNamespace(count=1, label="missing", block=1, action="click")
            with patch.object(gates, "Observer", MissingNativeObserver), patch.object(gates, "Source", CounterSource), \
                    patch.object(gates.subprocess, "Popen", return_value=child), \
                    patch.object(gates.select, "select", return_value=([child.stdout], [], [])), \
                    patch.object(gates, "mach_clock", return_value=(time.monotonic_ns, 1, 1)), \
                    patch.object(gates.time, "time_ns", side_effect=AssertionError("wall clock is unavailable")), \
                    patch("sys.stdout", new_callable=io.StringIO):
                result = gates.run(config, args)
            summary_path = next(root.glob("gates-*/summary.json"))
            summary = json.loads(summary_path.read_text())
            self.assertEqual(result, 1)
            self.assertEqual(summary["gate_a"]["outcomes"], {"deadline_failure": 1})
            self.assertEqual(summary["gate_a"]["completed_subset"]["n"], 0)


if __name__ == "__main__":
    unittest.main()
