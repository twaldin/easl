import argparse
import json
import pathlib

parser = argparse.ArgumentParser(description="Reject diagnostic runs whose calibration cannot distinguish CPU work from a blocked main thread.")
parser.add_argument("log", type=pathlib.Path)
args = parser.parse_args()
records = []
for line in args.log.read_text().splitlines():
    if line.startswith("{"):
        records.append(json.loads(line))

for fixture, busy in (("calibration-cpu", True), ("calibration-blocked", False)):
    selected = [r for r in records if r.get("fixture") == fixture]
    summaries = [r for r in selected if r["event"] == "instrumentation-summary"]
    assert len(summaries) == 1, f"{fixture}: missing calibration summary"
    summary = summaries[0]
    assert summary["startResult"] == "ok" and summary["watchdogJoined"], f"{fixture}: probe lifecycle failed"
    assert summary["watchdogRealtimePolicyError"] == 0, f"{fixture}: real-time watchdog policy unavailable"
    assert summary["deadlineLatenessNsMax"] <= 10_000_000, f"{fixture}: watchdog wake lateness exceeds 10ms"
    for field in ("gapsDropped", "contextRecordsDropped", "stackRecordsDropped", "suspendErrors", "stateErrors", "readErrors", "resumeErrors"):
        assert summary[field] == 0, f"{fixture}: {field}={summary[field]}"
    gaps = [r for r in selected if r["event"] == "gap"]
    assert len(gaps) == 1, f"{fixture}: expected one induced gap"
    gap = gaps[0]
    assert gap["wallNs"] >= 70_000_000 and gap["cpuDeltaNs"] is not None, f"{fixture}: invalid induced interval"
    ratio = gap["cpuDeltaNs"] / gap["wallNs"]
    assert ratio >= 0.7 if busy else ratio <= 0.1, f"{fixture}: unexpected CPU ratio {ratio}"
    stacks = [r for r in selected if r["event"] == "watchdog-stack" and r["accepted"]
              and r["intervalSeq"] == gap["intervalSeq"] and r["frameCount"] >= 3
              and gap["startNs"] <= r["atNs"] <= gap["endNs"]]
    assert len(stacks) >= 2, f"{fixture}: fewer than two usable during-gap stacks"
    expected = "running-or-runnable" if busy else "waiting"
    assert any(s["preSuspendCPU"]["runStateName"] == expected for s in stacks), f"{fixture}: missing expected thread state"
    print(json.dumps({"event": "probe-calibration-validated", "fixture": fixture,
                      "wallMs": gap["wallNs"] / 1e6, "cpuMs": gap["cpuDeltaNs"] / 1e6,
                      "usableStacks": len(stacks), "maxWakeLatenessMs": summary["deadlineLatenessNsMax"] / 1e6}, sort_keys=True))

native_pid = json.loads((args.log.parent / "runner-cleanup.json").read_text())["ownedPid"]
cpu_gap = next(r for r in records if r["event"] == "gap" and r["fixture"] == "calibration-cpu")
previous = None
calibration_cpu = 0
summary = None
with (args.log.parent / "sampler.noindex" / "processes.jsonl").open() as stream:
    for line in stream:
        sample = json.loads(line)
        if sample["event"] == "sampler-summary":
            summary = sample
        for row in sample.get("processes", []):
            if row["pid"] != native_pid or "userNs" not in row:
                continue
            if previous is not None and previous["birthUs"] == row["birthUs"]:
                if previous["startNs"] < cpu_gap["endNs"] and row["endNs"] > cpu_gap["startNs"]:
                    calibration_cpu += row["userNs"] + row["systemNs"] - previous["userNs"] - previous["systemNs"]
            previous = row
assert calibration_cpu >= 0.7 * cpu_gap["wallNs"], "Sampler does not see the known-busy calibration CPU"
assert summary is not None, "Missing sampler summary"
fraction = summary["cpuNs"] / (summary["endNs"] - summary["startNs"])
assert fraction <= 0.05, f"Sampler used {100*fraction:.3f}% of one CPU, above the 5% measurement bound"
assert summary["maxLatenessNs"] <= 50_000_000, "Sampler wake lateness exceeds one 50ms period"
print(json.dumps({"event": "sampler-validated", "calibrationCPUms": calibration_cpu / 1e6,
                  "cpuPercentOneCore": fraction * 100, "maxScanMs": summary["maxScanNs"] / 1e6,
                  "maxLatenessMs": summary["maxLatenessNs"] / 1e6}, sort_keys=True))
