#!/usr/bin/env python3
import os
import pwd
import subprocess
import sys


def checked_home(home, pairs):
    copy_home = os.path.realpath(home)
    for pair in pairs:
        key, sep, value = pair.partition("=")
        if key == "EASL_HOME" and sep:
            home = value
    if not home.startswith("/"):
        raise ValueError("EASL_HOME must be an absolute path")
    home = home.rstrip("/") or "/"
    root = os.path.realpath(home)
    paths = [os.path.join(home, name) for name in ("zmx", "state", "tmp")]
    if len((paths[0] + "/canvas-obj_000000000000000000").encode()) > 103:
        raise ValueError("home is too long for a zmx socket; choose a shorter EASL_DEV_HOME")
    uid = os.getuid()
    account = pwd.getpwuid(uid).pw_dir
    installed = [os.path.join(account, name) for name in (".local/state/zmx", ".local/state/easl", "Library/Application Support/Easl")]
    installed.append(f"/tmp/zmx-{uid}")
    app_bundles = ["/Applications/easl.app", os.path.join(account, "Applications/easl.app")]
    installed.extend(app_bundles)
    copy_target = os.path.realpath(os.path.join(copy_home, "easl.app"))
    for app in app_bundles:
        if os.path.commonpath([copy_target, os.path.realpath(app)]) == os.path.realpath(app):
            raise ValueError(f"development bundle would overwrite the installed app {app}")
    inherited_home = os.environ.get("HOME")
    if inherited_home:
        installed.append(os.path.join(inherited_home, ".local/state/zmx"))
    gui = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout.strip()
    if gui:
        installed.append(os.path.join(gui, f"zmx-{uid}"))
    for key, suffix, own in [("ZMX_DIR", "", paths[0]), ("XDG_STATE_HOME", "zmx", paths[1]), ("XDG_RUNTIME_DIR", "zmx", None)]:
        value = os.environ.get(key)
        if value and os.path.isabs(value) and (own is None or os.path.realpath(value) != os.path.realpath(own)):
            installed.append(os.path.join(value, suffix))
    installed = [os.path.realpath(path) for path in installed]
    for path in installed:
        for candidate in (root, copy_home):
            if os.path.commonpath([candidate, path]) == path:
                raise ValueError(f"development home {candidate} is in the installed easl or zmx directory {path}")
    written = paths + [os.path.join(paths[0], "logs"), os.path.join(paths[1], "zmx/logs"), os.path.join(paths[2], f"zmx-{uid}")]
    for path in written:
        resolved = os.path.realpath(path)
        if os.path.commonpath([root, resolved]) != root:
            raise ValueError(f"development zmx path {resolved} is outside its home {home}")
        for shared in installed:
            if os.path.commonpath([resolved, shared]) in (resolved, shared):
                raise ValueError(f"development zmx path {resolved} shares the installed zmx directory {shared}")
    return home


if __name__ == "__main__":
    try:
        print(checked_home(sys.argv[1], sys.argv[2:]))
    except (OSError, ValueError) as error:
        sys.exit(f"dev zmx isolation refused: {error}")
