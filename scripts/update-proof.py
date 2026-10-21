#!/usr/bin/env python3
"""Prepare real update artifacts inside a claimed GUI guest, without building or launching.

    EASL_DEV_HOME=/tmp/eg.XXXXXX/view EASL_GUI_GUEST=agent-gui \
        python3 scripts/update-proof.py prepare --app .build/easl.app \
        --old-version 0.2.7 --new-version 0.2.8
    python3 scripts/update-proof.py serve
    python3 scripts/update-proof.py select unsigned

Keep EASL_DEV_HOME and EASL_GUI_GUEST exported for every command. Preparation
refuses an existing update-proof directory. Use a fresh scratch home for another
old-to-new run. Serving and feed selection can be repeated without preparing.
This helper does not acquire a guest, build, launch the app, or claim GUI proof.
"""

import argparse
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys


REPO = Path(__file__).resolve().parent.parent
VARIANTS = ("valid", "corrupt", "unsigned")


def scratch_home():
    if sys.platform != "darwin" or os.environ.get("EASL_GUI_GUEST") != "agent-gui":
        raise ValueError("run only inside the claimed agent-gui guest")
    value = os.environ.get("EASL_DEV_HOME", "")
    if not value or not Path(value).is_absolute():
        raise ValueError("set EASL_DEV_HOME to an explicit absolute guest scratch path")
    home = Path(value).resolve()
    temporary = Path("/tmp").resolve()
    if temporary not in home.parents or home.parent == temporary:
        raise ValueError("EASL_DEV_HOME must be below a guest scratch directory in /tmp")
    return home


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def save_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def set_version(app, version, home):
    path = app / "Contents/Info.plist"
    with path.open("rb") as stream:
        info = plistlib.load(stream)
    info["CFBundleShortVersionString"] = version
    info["CFBundleVersion"] = version
    base = info["CFBundleIdentifier"].split(".dev.")[0]
    info["CFBundleIdentifier"] = base + ".dev." + hashlib.sha256(str(home).encode()).hexdigest()[:10]
    with path.open("wb") as stream:
        plistlib.dump(info, stream)
    run("codesign", "--force", "--sign", "-", "--preserve-metadata=entitlements,flags,runtime", app)


def prepare(home, args):
    versions = (args.old_version, args.new_version)
    if any(not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) for version in versions):
        raise ValueError("versions must have three numeric components, such as 0.2.7")
    if tuple(map(int, versions[0].split("."))) >= tuple(map(int, versions[1].split("."))):
        raise ValueError("--new-version must be newer than --old-version")
    source = Path(args.app).resolve()
    if (REPO / ".build").resolve() not in source.parents:
        raise ValueError("--app must name an existing built source bundle beneath this checkout's .build")
    if not (source / "Contents/Info.plist").is_file() or not (source / "Contents/MacOS/Easl").is_file():
        raise ValueError("--app must contain a built easl app; this helper never builds it")
    root = home / "update-proof"
    if root.exists() or root.is_symlink():
        raise ValueError("update-proof already exists; reuse serve/select or choose a fresh EASL_DEV_HOME")
    root.mkdir(parents=True)
    base = "http://127.0.0.1:{}".format(args.port)
    environment = ["EASL_HOME=" + str(home), "EASL_DEV_INPUT=1", "EASL_BROWSER_PROFILE=own",
                   "EASL_UPDATE_URL=" + base + "/latest.json"]
    for name in ("EASL_DEV_SSH", "EASL_DEV_REMOTE_HOME", "EASL_DEV_FRAME", "EASL_NO_ACTIVATE"):
        if os.environ.get(name):
            environment.append(name + "=" + os.environ[name])
    old = root / "old/easl.app"
    subprocess.run([str(REPO / "scripts/dev-bundle.sh"), str(source), str(old.parent)] + environment,
                   check=True, stdout=subprocess.DEVNULL)
    set_version(old, args.old_version, home)
    new = root / "new/easl.app"
    new.parent.mkdir()
    run("ditto", old, new)
    set_version(new, args.new_version, home)
    run("codesign", "--verify", "--deep", "--strict", old)
    run("codesign", "--verify", "--deep", "--strict", new)
    web = root / "http"
    web.mkdir()
    (web / "notes.txt").write_text("Guest-local update proof. No release was published.\n")
    artifacts = {}
    for variant in VARIANTS:
        app = new
        if variant != "valid":
            app = root / variant / "easl.app"
            app.parent.mkdir()
            run("ditto", new, app)
            if variant == "unsigned":
                run("codesign", "--remove-signature", app)
            else:
                with (app / "Contents/Info.plist").open("ab") as stream:
                    stream.write(b"\n")
        archive = web / (variant + ".zip")
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
        feed = {"version": args.new_version, "url": base + "/" + archive.name,
                "sha256": digest(archive), "size": archive.stat().st_size,
                "notes": base + "/notes.txt"}
        save_json(web / (variant + ".json"), feed)
        artifacts[variant] = {"bundle": str(app), "archive": str(archive), "feed": feed,
                              "feedPath": str(web / (variant + ".json"))}
    manifest = {"home": str(home), "sourceApp": str(source), "sourceExecutableSHA256": digest(source / "Contents/MacOS/Easl"),
                "oldVersion": args.old_version, "newVersion": args.new_version,
                "oldApp": str(old), "newApp": str(new), "port": args.port,
                "feedURL": base + "/latest.json", "artifacts": artifacts}
    save_json(root / "manifest.json", manifest)
    select(home, "valid")
    print(json.dumps(manifest, indent=2, sort_keys=True), flush=True)


def manifest_for(home):
    root = home / "update-proof"
    if root.is_symlink() or root.resolve() != root:
        raise ValueError("update-proof must be an owned scratch directory, not a symlink")
    manifest = json.loads((root / "manifest.json").read_text())
    if manifest["home"] != str(home):
        raise ValueError("manifest belongs to another EASL_DEV_HOME")
    return root, manifest


def select(home, variant):
    root, _ = manifest_for(home)
    web = root / "http"
    temporary = web / "latest.json.tmp"
    shutil.copyfile(web / (variant + ".json"), temporary)
    temporary.replace(web / "latest.json")
    print(json.dumps({"selected": variant, "latest": str(web / "latest.json")}), flush=True)


def serve(home):
    root, manifest = manifest_for(home)
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root / "http"))
    with http.server.ThreadingHTTPServer(("127.0.0.1", manifest["port"]), handler) as server:
        record = {"pid": os.getpid(), "address": "127.0.0.1", "port": server.server_port,
                  "feedURL": manifest["feedURL"], "directory": str(root / "http")}
        save_json(root / "server.json", record)
        print(json.dumps(record, sort_keys=True), flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("prepare", help="copy and ad-hoc sign two bundle versions from an existing source build")
    build.add_argument("--app", required=True)
    build.add_argument("--old-version", required=True)
    build.add_argument("--new-version", required=True)
    build.add_argument("--port", type=int, default=18766)
    commands.add_parser("serve", help="serve only the prepared scratch artifacts on loopback, in the foreground")
    choose = commands.add_parser("select", help="atomically select the feed used by the running old app")
    choose.add_argument("variant", choices=VARIANTS)
    args = parser.parse_args()
    home = scratch_home()
    if args.command == "prepare":
        if not 1 <= args.port <= 65535:
            raise ValueError("--port must be between 1 and 65535")
        prepare(home, args)
    elif args.command == "serve":
        serve(home)
    else:
        select(home, args.variant)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit("update-proof: " + str(error))
