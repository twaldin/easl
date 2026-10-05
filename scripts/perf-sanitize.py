#!/usr/bin/env python3
"""A board file with its geometry kept and every string replaced, for performance replicas of a
real board whose content must not leave its machine (docs/testing.md, "Performance benchmark").

    python3 scripts/perf-sanitize.py <board.json> <out.json>

Kept: object ids, types, frames, z, revisions, parents, group membership, arrow bindings (object
ids, line ranges), route styles, shape kinds, fills, palette colors, numbers and booleans. Replaced
with filler of the same length: titles, note text (line structure and list/heading markers kept),
labels, shape text, keys (unique per original), urls, paths, commands, and html (a synthetic page
of the same UTF-8 size, with a small script where the original had one). Everything outside the
objects (tray, attention, answers, repository record) is dropped, and timestamps are fixed. The
run ends with a leak check: no string of the input longer than 5 characters, other than kept ids
and enum values, may appear anywhere in the output.
"""
import hashlib
import json
import os
import re
import sys

LOREM = ("lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna "
         "aliqua ut enim ad minim veniam quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat ")
ID = re.compile(r"^(obj|brd)_[A-Za-z0-9]+$")
ENUM_KEYS = {"type", "kind", "fill", "route", "flow", "color", "direction"}
ENUM = re.compile(r"^#?[A-Za-z0-9_-]{1,24}$")
SALT = os.urandom(16)
FIXED_DATE = "2026-01-01T00:00:00Z"
# Props whose values are free-form structures (their keys too): replaced whole, same size.
OPAQUE = {"state", "graph", "history", "lastAction", "lastChanges", "anchor", "viewed", "reviewed", "agent", "lifecycle", "follow", "paths"}


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


def scrub(value, key=None):
    """Strings replaced (ids and enum values kept); keys of plain props objects kept."""
    if isinstance(value, str):
        if ID.match(value) or (key in ENUM_KEYS and ENUM.match(value)):
            return value
        return text_filler(value)
    if isinstance(value, list):
        return [scrub(v, key) for v in value]
    if isinstance(value, dict):
        return {(k if k in SCHEMA_KEYS else unique_filler(k)): scrub(v, k) for k, v in value.items()}
    return value


# Keys the output may carry as they are: object fields, every type's props (`ObjectType.knownProps`),
# bindings, frames, actors. Any other key (an agent's own prop, a nested structure's) is replaced.
SCHEMA_KEYS = {
    "objects", "format", "revision", "id", "type", "frame", "z", "rev", "parent", "createdBy", "updatedBy", "createdAt", "updatedAt", "props",
    "x", "y", "w", "h", "object", "lines", "selector", "node", "point", "start", "end", "agent", "tile", "user", "filler",
    "cwd", "command", "zmxSession", "title", "name", "lifecycle", "follow", "zoom", "worktree", "branch", "url", "pageTitle",
    "path", "range", "anchor", "symbol", "caption", "diffBase", "followOf", "lastAction", "lastChanges", "history",
    "pinnedCommit", "ref", "refSha", "markdown", "root", "html", "allowNetwork", "state", "base", "head", "paths",
    "reviewed", "viewed", "kind", "line", "direction", "depth", "expanded", "graph", "text", "points", "color", "fill",
    "textSize", "from", "to", "relation", "label", "route", "members", "padding", "flow", "key",
}


def sanitize_props(type_, props):
    out = {}
    for key, value in props.items():
        if key not in SCHEMA_KEYS:
            out[unique_filler(key)] = opaque(value)
            continue
        if key == "html" and isinstance(value, str):
            out[key] = html_filler(value)
        elif key == "key" and isinstance(value, str):
            out[key] = unique_filler(value)
        elif key in OPAQUE:
            out[key] = opaque(value)
        elif key == "url" and isinstance(value, str):
            out[key] = ("about:blank#" + filler(max(len(value) - 12, 0)))[: max(len(value), 11)]
        else:
            out[key] = scrub(value, key)
    return out


def sanitize(board):
    objects = board["objects"] if isinstance(board["objects"], list) else list(board["objects"].values())
    clean = []
    for o in objects:
        c = {k: o[k] for k in ("id", "type", "frame", "z", "rev") if k in o}
        if o.get("parent") is not None:
            c["parent"] = o["parent"]
        for actor in ("createdBy", "updatedBy"):
            if actor in o:
                c[actor] = scrub(o[actor])
        c["createdAt"] = c["updatedAt"] = FIXED_DATE
        c["props"] = sanitize_props(o["type"], o.get("props") or {})
        clean.append(c)
    out = {"id": board["id"], "root": "/tmp/" + filler(max(len(board.get("root", "")) - 5, 1)).replace(" ", "-"),
           "revision": board.get("revision", 0), "objects": clean}
    if "format" in board:
        out["format"] = board["format"]
    return out


def strings(value, key=None):
    if isinstance(value, str):
        yield key, value
    elif isinstance(value, list):
        for v in value:
            yield from strings(v, key)
    elif isinstance(value, dict):
        for k, v in value.items():
            yield None, k
            yield from strings(v, k)


def leaks(source, text):
    found = set()
    for key, s in strings(source):
        if len(s) <= 5 or ID.match(s) or (key in ENUM_KEYS and ENUM.match(s)) or s == FIXED_DATE or s in SCHEMA_KEYS:
            continue
        if s in text:
            found.add(s)
    # Every word of 8+ letters from the source's strings, too (words of html, notes, titles),
    # except words the output carries by construction: lorem, schema keys, kept type and enum
    # values, and the synthetic page's own markup.
    vocabulary = set(re.findall(r"[^\W\d_]{8,}", " ".join(s for _, s in strings(source))))
    kept = [s for key, s in strings(text and json.loads(text)) if key in ENUM_KEYS]
    own = set(re.findall(r"[^\W\d_]+", " ".join([LOREM, html_filler("<script>" + "x" * 1000)] + kept))) | SCHEMA_KEYS
    for word in vocabulary - own:
        if re.search(r"\b" + re.escape(word) + r"\b", text):
            found.add(word)
    return found


def where(value, needle, path="$"):
    """JSON paths of the output strings (values or keys) holding `needle`; schema keys only."""
    if isinstance(value, str):
        return [path] if needle in value else []
    if isinstance(value, list):
        return [p for i, v in enumerate(value) for p in where(v, needle, f"{path}[{i}]")]
    if isinstance(value, dict):
        found = []
        for k, v in value.items():
            name = k if k in SCHEMA_KEYS else "<key>"
            if needle in k:
                found.append(f"{path}.{name} (key)")
            found += where(v, needle, f"{path}.{name}")
        return found
    return []


def main():
    source = json.load(open(sys.argv[1]))
    clean = sanitize(source)
    text = json.dumps(clean, ensure_ascii=False)
    found = leaks(source, text)
    if found:
        # Never print what leaked: this runs on the board's own machine and its output travels.
        # Only its length and where it sits (schema key paths) are reported.
        places = [(len(s), where(clean, s)[:3]) for s in found]
        sys.exit(f"leak check failed: {len(found)} strings survived: {places[:10]}")
    with open(sys.argv[2], "w") as f:
        f.write(text)
    kinds = {}
    for o in clean["objects"]:
        kinds[o["type"]] = kinds.get(o["type"], 0) + 1
    print(f"{len(clean['objects'])} objects {kinds}, {len(text.encode())} bytes, leak check passed")


if __name__ == "__main__":
    main()
