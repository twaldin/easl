"""Privacy tests for scripts/perf-sanitize.py: `python3 -m unittest discover -s scripts`."""
import importlib.util
import json
import os
import unittest

spec = importlib.util.spec_from_file_location("perf_sanitize", os.path.join(os.path.dirname(__file__), "perf-sanitize.py"))
sanitizer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sanitizer)

USER = {"kind": "user"}
DATE = "2026-10-05T17:00:00Z"


def obj(id_, type_, props, **extra):
    o = {"id": id_, "type": type_, "frame": {"x": 1, "y": 2, "w": 300, "h": 200}, "z": 1, "rev": 3,
         "createdBy": USER, "createdAt": DATE, "updatedAt": DATE, "props": props}
    o.update(extra)
    return o


def board(*objects):
    return {"id": "brd_7f9488ca81a13ddbbd95", "root": "/Users/someone/work", "revision": 9, "format": 2, "objects": list(objects)}


class SanitizeTests(unittest.TestCase):
    def test_id_spelled_content_is_replaced_and_ids_renumbered(self):
        source = board(
            obj("obj_01M3QN66AAAAAAAAAAAAAA", "terminal", {"cwd": "/w", "command": ["sh"]}),
            obj("obj_01M3QN66BBBBBBBBBBBBBB", "note", {"markdown": "obj_Acquisition", "title": "obj_Acquisition"},
                createdBy={"kind": "agent", "tile": "obj_01M3QN66AAAAAAAAAAAAAA", "agent": "Acquisition"}),
            obj("obj_01M3QN66CCCCCCCCCCCCCC", "group", {"members": ["obj_01M3QN66BBBBBBBBBBBBBB"], "title": "obj_Acquisition"}),
            obj("obj_01M3QN66DDDDDDDDDDDDDD", "arrow", {"from": {"object": "obj_01M3QN66BBBBBBBBBBBBBB"},
                                                         "to": {"object": "obj_01M3QN66CCCCCCCCCCCCCC", "lines": {"start": 3, "end": 4}},
                                                         "route": "avoid", "label": "obj_Acquisition"}),
        )
        clean, text = sanitizer.run(source)
        self.assertNotIn("Acquisition", text)
        self.assertNotIn("M3QN66", text)
        ids = [o["id"] for o in clean["objects"]]
        self.assertEqual(ids, sorted(ids))
        note, group, arrow = clean["objects"][1], clean["objects"][2], clean["objects"][3]
        self.assertEqual(note["createdBy"], {"kind": "agent", "tile": clean["objects"][0]["id"]})
        self.assertEqual(group["props"]["members"], [note["id"]])
        self.assertEqual(arrow["props"]["from"], {"object": note["id"]})
        self.assertEqual(arrow["props"]["to"], {"object": group["id"], "lines": {"start": 3, "end": 4}})
        self.assertEqual(arrow["props"]["route"], "avoid")
        self.assertEqual(len(note["props"]["title"]), len("obj_Acquisition"))

    def test_enum_values_only_survive_in_their_own_fields(self):
        source = board(
            obj("obj_01A", "html", {"html": "<p>hello Acquisition</p>", "kind": "Acquisition", "title": "violet"}),
            obj("obj_01B", "shape", {"kind": "Acquisition", "text": "Acquisition", "color": "Acquisition", "fill": "semi"}),
            obj("obj_01C", "group", {"members": [], "color": "#a1b2c3", "flow": "sideways"}),
        )
        clean, text = sanitizer.run(source)
        self.assertNotIn("acquisition", text.lower())
        html, shape, group = (o["props"] for o in clean["objects"])
        self.assertNotIn("kind", html)
        self.assertEqual(shape["kind"], "rect")
        self.assertEqual(shape["color"], "grey")
        self.assertEqual(shape["fill"], "semi")
        self.assertEqual(group["color"], "#a1b2c3")
        self.assertEqual(group["flow"], "right")

    def test_leak_check_catches_words_inside_longer_runs(self):
        source = board(obj("obj_01A", "note", {"markdown": "Acquisition"}))
        self.assertEqual(sanitizer.leaks(source, json.dumps({"x": "obj_Acquisition"})), {"Acquisition"})
        self.assertEqual(sanitizer.leaks(source, json.dumps({"x": "preACQUISITIONpost"})), {"Acquisition"})
        self.assertEqual(sanitizer.leaks(source, json.dumps({"x": "lorem ipsum"})), set())

    def test_a_lorem_fragment_after_a_newline_is_not_a_leak(self):
        # An input word that is part of a lorem word ("citation" in "exercitation") must not be
        # flagged by the output's own filler: in the JSON text the escape of a line break before
        # that word (`\nexercitation`) is one letter run, which `run` no longer reads.
        source = board(obj("obj_01A", "note", {"markdown": "citation needed"}))
        filler = {"objects": [{"props": {"markdown": "line one\nexercitation ullamco"}}]}
        original = sanitizer.sanitize
        sanitizer.sanitize = lambda board: filler
        try:
            clean, text = sanitizer.run(source)
        finally:
            sanitizer.sanitize = original
        self.assertEqual(clean, filler)
        self.assertEqual(sanitizer.leaks(source, text), {"citation"}, "the JSON text run() returns still spells one run; run() itself passed")

    def test_numbers_that_spell_an_input_string_are_still_caught(self):
        # Non-string scalars are checked as JSON spells them (a `revision` of 123456 against a
        # note saying "123456"), as the JSON-text check did.
        source = board(obj("obj_01A", "note", {"markdown": "123456"}))
        original = sanitizer.sanitize
        sanitizer.sanitize = lambda board: {"revision": 123456, "objects": [{"props": {"markdown": "lorem"}}]}
        try:
            with self.assertRaises(SystemExit) as raised:
                sanitizer.run(source)
        finally:
            sanitizer.sanitize = original
        self.assertIn("$.revision", str(raised.exception))

    def test_input_words_inside_schema_keys_are_not_leaks(self):
        source = board(obj("obj_01A", "note", {"markdown": "Update created members", "title": "Updated"}))
        clean, text = sanitizer.run(source)
        self.assertIn("createdBy", text)
        # Inside a run that isn't vocabulary they still are.
        self.assertEqual(sanitizer.leaks(source, json.dumps({"x": "membersUpdated"})), {"Update", "Updated"})

    def test_leak_check_does_not_exempt_values_outside_their_fields(self):
        source = board(obj("obj_01A", "html", {"html": "<p></p>", "kind": "Acquisition"}))
        self.assertEqual(sanitizer.leaks(source, json.dumps({"kind": "Acquisition"})), {"Acquisition"})

    def test_failed_check_reports_no_content(self):
        source = board(obj("obj_01A", "note", {"markdown": "Acquisition"}))
        original = sanitizer.sanitize
        sanitizer.sanitize = lambda board: {"objects": [{"props": {"markdown": "Acquisition"}}]}
        try:
            with self.assertRaises(SystemExit) as raised:
                sanitizer.run(source)
        finally:
            sanitizer.sanitize = original
        self.assertNotIn("Acquisition", str(raised.exception))
        self.assertIn("$.objects[0].props.markdown", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
