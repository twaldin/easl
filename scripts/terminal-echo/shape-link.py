#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import re
import subprocess

PROFILES = {"good": ("10Mbit/s", 17, 18, "0", "64Kbytes"), "poor": ("1Mbit/s", 40, 40, "0.01", "16Kbytes"), "bad": ("100Kbit/s", 75, 75, "0", "8Kbytes")}
ANCHOR = "com.apple/easl-terminal-echo"
PIPES = (27111, 27112)


def run(*args, content=None, check=True):
    result = subprocess.run(["sudo", "-n", *args], input=content, capture_output=True, text=True)
    if check and result.returncode:
        raise RuntimeError("{}: {}".format(" ".join(args), result.stderr))
    return {"argv": list(args), "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("profile", choices=[*PROFILES, "clear", "status"])
    parser.add_argument("scratch", type=Path)
    args = parser.parse_args()
    state_path = args.scratch / "shaper-state.json"
    record = {"profile": args.profile, "commands": []}
    commands = record["commands"]
    if args.profile == "clear":
        state = json.loads(state_path.read_text())
        commands.append(run("pfctl", "-a", ANCHOR, "-f", "-", content=""))
        for pipe in PIPES:
            commands.append(run("dnctl", "pipe", "delete", str(pipe)))
        commands.append(run("pfctl", "-X", state["token"]))
        commands.append(run("ifconfig", "lo0", "mtu", str(state["mtu"])))
        state_path.unlink()
    elif args.profile != "status":
        if not state_path.exists():
            before = run("dnctl", "list")
            assert not any(re.search(r"\b{}\b".format(pipe), before["stdout"]) for pipe in PIPES), "owned pipe IDs already exist"
            commands.append(before)
            before_pf = run("pfctl", "-s", "info")
            commands.append(before_pf)
            interface = run("ifconfig", "lo0")
            commands.append(interface)
            mtu = int(re.search(r"\bmtu (\d+)", interface["stdout"]).group(1))
            enabled = run("pfctl", "-E")
            commands.append(enabled)
            token = re.search(r"Token\s*:\s*(\d+)", enabled["stderr"] + enabled["stdout"])
            assert token, enabled
            state_path.write_text(json.dumps({"token": token.group(1), "before_pf": before_pf, "before_dn": before, "mtu": mtu}) + "\n")
            commands.append(run("ifconfig", "lo0", "mtu", "1500"))
        bandwidth, upstream_delay, downstream_delay, loss, queue = PROFILES[args.profile]
        for pipe, delay in zip(PIPES, [upstream_delay, downstream_delay]):
            commands.append(run("dnctl", "pipe", str(pipe), "config", "bw", bandwidth, "delay", str(delay), "plr", loss, "queue", queue))
        rules = ("dummynet out quick on lo0 inet proto tcp from 127.0.0.1 to 127.0.0.1 port 22 pipe 27111\n"
                 "dummynet out quick on lo0 inet proto tcp from 127.0.0.1 port 22 to 127.0.0.1 pipe 27112\n")
        commands.append(run("pfctl", "-n", "-a", ANCHOR, "-f", "-", content=rules))
        commands.append(run("pfctl", "-a", ANCHOR, "-f", "-", content=rules))
    commands.append(run("dnctl", "list"))
    commands.append(run("pfctl", "-s", "info"))
    print(json.dumps(record, indent=2), flush=True)
    (args.scratch / ("shape-" + args.profile + ".json")).write_text(json.dumps(record, indent=2) + "\n")


if __name__ == "__main__":
    main()
