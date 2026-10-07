#!/usr/bin/env python3
"""A board file with its geometry kept and every string replaced, for performance replicas of a
real board whose content must not leave its machine (docs/testing.md, "Performance benchmark").

    python3 scripts/perf-sanitize.py <board.json> <out.json>

Every value is handled by where it sits, never by how it is spelled:
- Kept: types, frames, z, revisions, numbers and booleans, and enum values in their own fields
  (shape kind and fill, arrow route, group flow, palette or #rrggbb colors, ...), each checked
  against that field's closed list; anything else there becomes the field's first value.
- Renumbered: ids, only in identity and reference positions (an object's id and parent, actor
  tiles, arrow ends, group members, a follow tile's source), to `obj_01REPL<n>` in the original
  order, so references, membership and id order survive and the originals don't.
- Replaced with filler of the same length: titles, note text (line structure and list/heading
  markers kept), labels, relations, shape text, keys (unique per original), urls, paths, commands,
  and html (a synthetic page of the same UTF-8 size, with a small script where the original had
  one). Structured props (page state, graphs, histories, agent records) and props a type doesn't
  define become filler structures of the same encoded size, under replaced keys.
Everything outside the objects (tray, attention, answers, repository record) is dropped, and
timestamps are fixed. The run ends with a leak check that allows only this file's own vocabulary
(lorem, the synthetic page's markup, schema keys, the closed enum lists) to come from the input:
no string of the input longer than 5 characters and no word of 6+ letters (case-insensitive, also
inside longer runs) may appear in the output otherwise. A failed check names lengths and schema
paths, never content.
"""
import hashlib
import json
import os
import re
import sys

LOREM = ("lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna "
         "aliqua ut enim ad minim veniam quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat ")
SALT = os.urandom(16)
FIXED_DATE = "2026-01-01T00:00:00Z"
BOARD_ID = "brd_" + "0" * 20

# Each type's props (`ObjectType.knownProps`, schema `TerminalProps` ... `GroupProps`). Any other
# key is an agent's own prop: its key and value are replaced.
KNOWN_PROPS = {
    "terminal": {"cwd", "command", "zmxSession", "host", "title", "name", "agent", "lifecycle", "follow", "zoom", "worktree", "branch"},
    "browser": {"url", "title", "pageTitle", "zoom"},
    "code": {"path", "range", "anchor", "symbol", "caption", "diffBase", "followOf", "lastAction", "lastChanges", "history", "pinnedCommit", "ref", "refSha", "zoom"},
    "note": {"markdown", "title", "root", "ref", "refSha", "zoom"},
    "html": {"html", "title", "root", "ref", "refSha", "allowNetwork", "state", "zoom"},
    "changes": {"root", "base", "head", "ref", "refSha", "paths", "title", "reviewed", "viewed", "zoom"},
    "image": {"path", "caption", "title"},
    "diagram": {"kind", "path", "symbol", "line", "direction", "depth", "expanded", "title", "graph", "zoom"},
    "shape": {"kind", "text", "points", "color", "fill", "textSize"},
    "arrow": {"from", "to", "relation", "label", "color", "route"},
    "group": {"members", "title", "color", "padding", "flow"},
}
for _props in KNOWN_PROPS.values():
    _props.add("key")
TYPES = list(KNOWN_PROPS)
# Closed lists, per type and field (schema enums); the first value stands in for anything else.
ENUMS = {
    ("shape", "kind"): ["rect", "ellipse", "text", "ink"],
    ("shape", "fill"): ["none", "semi", "solid"],
    ("arrow", "route"): ["straight", "orthogonal", "avoid"],
    ("group", "flow"): ["right", "down", "left", "up"],
    ("diagram", "kind"): ["calls"],
    ("diagram", "direction"): ["incoming", "outgoing", "both"],
    ("code", "lastAction"): ["read", "edit", "write", "lsp", "search"],
}
PALETTE = ["grey", "black", "blue", "green", "orange", "red", "violet"]
HEX_COLOR = re.compile(r"^#[0-9A-Fa-f]{6}$")
COLORS = {("shape", "color"), ("arrow", "color"), ("group", "color")}
# Props holding object ids (reference positions).
ID_PROPS = {("code", "followOf"), ("group", "members")}
BINDINGS = {("arrow", "from"), ("arrow", "to")}
# Props whose values are numbers or structures of numbers, kept as they are.
NUMERIC = {"zoom", "padding", "textSize", "line", "depth", "follow", "range", "points"}
# Keys the output carries as they are; every other key in it is a salted digest.
SCHEMA_KEYS = ({"objects", "format", "revision", "id", "type", "frame", "z", "rev", "parent", "createdBy", "updatedBy",
                "createdAt", "updatedAt", "props", "x", "y", "w", "h", "kind", "tile", "object", "lines", "selector", "node",
                "point", "start", "end", "filler", "root"} | set().union(*KNOWN_PROPS.values()))


def filler(n, offset=0):
    """`n` characters of lorem text: whole lorem words, a cut-off last word as dots (a word
    fragment could spell a real word, which the leak check would rightly flag)."""
    source = (LOREM * (n // len(LOREM) + 2))[LOREM.find(" ", offset % len(LOREM)) + 1:]
    out = source[:n]
    if source[n:n + 1] not in ("", " ") and not out.endswith(" "):
        cut = out.rfind(" ") + 1
        out = out[:cut] + "." * (n - cut)
    return out


def text_filler(s):
    """Same length, newlines kept, each line's leading markdown marker kept."""
    lines = s.split("\n")
    out = []
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*(?:#{1,6} |[-*+] |\d+\. |> |\|)?)", line)
        lead = m.group(1) if m else ""
        out.append(lead + filler(len(line) - len(lead), i * 7))
    return "\n".join(out)


def unique_filler(s):
    """Same length, unique per original (salted, not reversible)."""
    digest = hashlib.sha256(SALT + s.encode()).hexdigest()
    while len(digest) < len(s):
        digest += hashlib.sha256(SALT + digest.encode()).hexdigest()
    return digest[: len(s)]


def html_filler(s):
    """A page of the same UTF-8 size; a small script where the original had one."""
    size = len(s.encode())
    head = "<!doctype html><html><head><style>body{font:13px -apple-system,sans-serif;margin:10px;color:#222}p{margin:0 0 6px}</style></head><body>"
    script = "<script>document.body.dataset.ready='1'</script>" if "<script" in s.lower() else ""
    tail = "</body></html>"
    room = size - len(head) - len(script) - len(tail)
    if room < 8:
        return filler(size)
    body, i = [], 0
    while room > 0:
        chunk = min(room, 240)
        if chunk >= 8:
            body.append("<p>" + filler(chunk - 7, i * 13) + "</p>")
        else:
            body.append(filler(chunk, i))
        room -= chunk
        i += 1
    return head + "".join(body) + script + tail


def opaque(value):
    """`value` replaced by a structure of the same encoded size that names nothing."""
    size = len(json.dumps(value, ensure_ascii=False))
    pad = max(size - len('{"filler":""}'), 0)
    return {"filler": filler(pad)}


def text(value):
    """Strings replaced by same-length filler, lists element by element, structures whole;
    numbers, booleans and null kept."""
    if isinstance(value, str):
        return text_filler(value)
    if isinstance(value, list):
        return [text(v) for v in value]
    if isinstance(value, dict):
        return opaque(value)
    return value


def numeric(value):
    """Numbers, booleans and null (in lists and range objects) kept; anything else dropped."""
    if isinstance(value, (bool, int, float)) or value is None:
        return value
    if isinstance(value, list):
        return [numeric(v) for v in value if not isinstance(v, (str, dict))]
    if isinstance(value, dict):
        return {k: v for k, v in value.items() if k in ("start", "end") and isinstance(v, (int, float))}
    return None


class Ids:
    """Every id in an identity or reference position, renumbered in the original order."""

    def __init__(self, board):
        self.map = {}
        found = set()
        for o in objects_of(board):
            found.update(s for s in id_positions(o) if isinstance(s, str))
        for n, original in enumerate(sorted(found)):
            self.map[original] = f"obj_01REPL{n:012d}"

    def __call__(self, value):
        return self.map[value] if isinstance(value, str) else None


def objects_of(board):
    objects = board.get("objects") or []
    return objects if isinstance(objects, list) else list(objects.values())


def id_positions(o):
    """The strings an object holds in identity and reference positions."""
    yield o.get("id")
    yield o.get("parent")
    for actor in ("createdBy", "updatedBy"):
        if isinstance(o.get(actor), dict):
            yield o[actor].get("tile")
    props = o.get("props") if isinstance(o.get("props"), dict) else {}
    t = o.get("type")
    for key in ("from", "to"):
        if (t, key) in BINDINGS and isinstance(props.get(key), dict):
            yield props[key].get("object")
    if (t, "followOf") in ID_PROPS:
        yield props.get("followOf")
    if (t, "members") in ID_PROPS and isinstance(props.get("members"), list):
        yield from props["members"]


def actor(value, ids):
    if isinstance(value, dict) and value.get("kind") == "agent" and isinstance(value.get("tile"), str):
        return {"kind": "agent", "tile": ids(value["tile"])}
    return {"kind": "user"}


def binding(value, ids):
    if not isinstance(value, dict):
        return {"point": [0, 0]}
    if "point" in value:
        return {"point": numeric(value["point"])}
    out = {"object": ids(value.get("object"))}
    if isinstance(value.get("lines"), dict):
        out["lines"] = numeric(value["lines"])
    if isinstance(value.get("selector"), str):
        out["selector"] = text_filler(value["selector"])
    if isinstance(value.get("node"), str):
        out["node"] = unique_filler(value["node"])
    return out


def prop(type_, key, value, ids):
    field = (type_, key)
    if field in ENUMS:
        allowed = ENUMS[field]
        return value if value in allowed else allowed[0]
    if field in COLORS:
        return value if isinstance(value, str) and (value in PALETTE or HEX_COLOR.match(value)) else PALETTE[0]
    if field in BINDINGS:
        return binding(value, ids)
    if field == ("group", "members"):
        return [ids(m) for m in value] if isinstance(value, list) else []
    if field == ("code", "followOf"):
        return ids(value)
    if key in NUMERIC:
        return numeric(value)
    if key == "html" and isinstance(value, str):
        return html_filler(value)
    if key in ("key", "zmxSession") and isinstance(value, str):
        return unique_filler(value)
    if key == "url" and isinstance(value, str):
        return ("about:blank#" + filler(max(len(value) - 12, 0)))[: max(len(value), 11)]
    return text(value)


def sanitize_props(type_, props, ids):
    known = KNOWN_PROPS.get(type_, set())
    out = {}
    for key, value in props.items():
        if key in known:
            out[key] = prop(type_, key, value, ids)
        else:
            out[unique_filler(key)] = opaque(value)
    return out


def sanitize(board):
    ids = Ids(board)
    clean = []
    for o in objects_of(board):
        if o.get("type") not in KNOWN_PROPS:
            continue
        c = {"id": ids(o["id"]), "type": o["type"]}
        c["frame"] = {k: o["frame"][k] for k in "xywh"}
        for k in ("z", "rev"):
            if isinstance(o.get(k), (int, float)):
                c[k] = o[k]
        if o.get("parent") is not None:
            c["parent"] = ids(o["parent"])
        for who in ("createdBy", "updatedBy"):
            if who in o:
                c[who] = actor(o[who], ids)
        c["createdAt"] = c["updatedAt"] = FIXED_DATE
        c["props"] = sanitize_props(o["type"], o.get("props") or {}, ids)
        clean.append(c)
    out = {"id": BOARD_ID, "root": "/tmp/" + filler(max(len(str(board.get("root", ""))) - 5, 1)).replace(" ", "-"),
           "revision": board.get("revision", 0) if isinstance(board.get("revision"), int) else 0, "objects": clean}
    if isinstance(board.get("format"), int):
        out["format"] = board["format"]
    return out


def strings(value):
    """Every string in `value`: values and keys."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for v in value:
            yield from strings(v)
    elif isinstance(value, dict):
        for k, v in value.items():
            yield k
            yield from strings(v)


def spelled(value):
    """What the output says, one item per line for the leak check: every string and key as it
    is, and every other scalar (numbers, booleans, null) as JSON spells it, so a number that
    spells an input string is still caught. Not the JSON text itself: there a line-break escape
    before a word spells one letter run with it (`\\nexercitation`), which no vocabulary masks."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for v in value:
            yield from spelled(v)
    elif isinstance(value, dict):
        for k, v in value.items():
            yield k
            yield from spelled(v)
    else:
        yield json.dumps(value)


def vocabulary():
    """What the output may carry without coming from the input: lorem, the synthetic page's
    markup, schema keys, the closed enum lists, palette names, the fixed date and type names."""
    words = [LOREM, html_filler("<script>" + "x" * 1000), FIXED_DATE, BOARD_ID, "about:blank", "/tmp/"]
    words += list(SCHEMA_KEYS) + TYPES + PALETTE + [v for allowed in ENUMS.values() for v in allowed]
    return {w.lower() for w in re.findall(r"[^\W\d_]+", " ".join(words))}, set(words)


def kept(source):
    """The input's strings the rules keep where they sit: closed-list values in their own fields."""
    for o in objects_of(source):
        props = o.get("props") if isinstance(o.get("props"), dict) else {}
        for key, value in props.items():
            field = (o.get("type"), key)
            if (field in ENUMS or field in COLORS) and prop(field[0], key, value, None) == value:
                yield value


def leaks(source, text):
    """Input strings and words found in `text` (the output) outside the output's own vocabulary
    and the values `kept` in their fields. Letter runs of `text` that are vocabulary words (a schema
    key such as `updatedBy`, lorem) are masked first, so an input word only matches what the
    output doesn't carry by construction; inside any other run it still does."""
    own_words, own_strings = vocabulary()
    for value in kept(source):
        own_strings.add(value)
        own_words.update(w.lower() for w in re.findall(r"[^\W\d_]+", value))
    masked = re.sub(r"[^\W\d_]+", lambda m: "\0" if m.group(0).lower() in own_words else m.group(0), text)
    lowered = masked.lower()
    found = set()
    for s in strings(source):
        if len(s) > 5 and s not in own_strings and s in masked:
            found.add(s)
    for word in set(re.findall(r"[^\W\d_]{6,}", " ".join(strings(source)))):
        if word.lower() not in own_words and word.lower() in lowered:
            found.add(word)
    return found


def where(value, needle, path="$"):
    """JSON paths of the output items (strings, keys, other scalars as JSON spells them) holding
    `needle`; schema keys only."""
    if isinstance(value, str):
        return [path] if needle.lower() in value.lower() else []
    if isinstance(value, list):
        return [p for i, v in enumerate(value) for p in where(v, needle, f"{path}[{i}]")]
    if isinstance(value, dict):
        found = []
        for k, v in value.items():
            name = k if k in SCHEMA_KEYS else "<key>"
            if needle.lower() in k.lower():
                found.append(f"{path}.{name} (key)")
            found += where(v, needle, f"{path}.{name}")
        return found
    return [path] if needle.lower() in json.dumps(value).lower() else []


def run(source):
    """The sanitized board's JSON text, or SystemExit naming (by length and path only) what leaked."""
    clean = sanitize(source)
    out = json.dumps(clean, ensure_ascii=False)
    # The check reads what the output says (`spelled`), not its JSON text (a work board, 2026-10-07).
    found = leaks(source, "\n".join(spelled(clean)))
    if found:
        # Never print what leaked: this runs on the board's own machine and its output travels.
        places = [(len(s), where(clean, s)[:3]) for s in found]
        raise SystemExit(f"leak check failed: {len(found)} strings survived: {places[:10]}")
    return clean, out


def main():
    source = json.load(open(sys.argv[1]))
    clean, out = run(source)
    with open(sys.argv[2], "w") as f:
        f.write(out)
    kinds = {}
    for o in clean["objects"]:
        kinds[o["type"]] = kinds.get(o["type"], 0) + 1
    print(f"{len(clean['objects'])} objects {kinds}, {len(out.encode())} bytes, leak check passed")


if __name__ == "__main__":
    main()
