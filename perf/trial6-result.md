# Trial 6 — terminals redraw slowly while the user is away: visible measured run (2026-10-08 00:06–00:20Z)

Hold `2026-10-07T23:56Z-perf-hold` (full quiet, shepherd START 23:56Z, released 00:21:41Z). Dev instances **visible on CanvasTest** (display id 45 / Space 10 / SkyLight 19660, born there and kept there; watcher allow ids [9, 19660]; focus pre/post checks around every launch, all passed, no restore needed), 15 terminals running perf-loop's AGENT (title + text every 80 ms) in view, harness `perf-idle` (main 2f7846c's perf-loop.py; its `dev-input` knows `idle`), bundles **a** = main c2da458 (`main-c2da458.app`), **b** = `perf/idle-redraw` dccb5a8 (`idle.app`, Easl sha 66befa445109e59c). 2 runs interleaved (a,b / b,a). Phases per instance: active 60 s; `dev-input idle on` + 3 s, idle 60 s; a posted flagsChanged + 2 s, restored 20 s. Script `perf-lead/idle-visible.py`, rows `runs/idle-visible.jsonl` (sha f53bd7494b829f87).

## Medians over 2 runs [range]

| bundle · phase | cpu s / phase | instructions G | GPU util % (ioreg, 1 s, in-process) | wrapper draws/s |
| --- | --- | --- | --- | --- |
| a active (60 s) | 34.2 [34.1–34.3] | 83.4 | 36.8 [36.5–37] | — (no counter) |
| a idle (60 s) | 34.7 [34.2–35.3] | 88.2 | 39 [37–41] | — |
| a restored (20 s) | 11.3 | 27.4 | 34.8 | — |
| **b active** (60 s) | 34.9 [34.7–35.1] | 88.5 | 38 [38–38] | 646 [634–659] |
| **b idle** (60 s) | **42.5 [42.45–42.49]** | **120.6** | **13.5 [13–14]** | **151 [149–154]** |
| **b restored** (20 s) | 11.7 | 29.2 | 38.3 | 651 [621–682] |

- **GPU utilization while idle: 38 → 13.5 % (−64 %)**, back to 38 % on input. (Whole-Mac counter; Tim's board ambient for both arms; a second shell sampler I started at 00:00Z read the same counter and may have contended with it — the shepherd's `accumulatedGPUTime` is the independent check.)
- **Wrapper redraws: 646 → 151/s (−77 %)**, restored 651/s. The pre-registered GUI pass rule (idle ≤ 15 × 5 × 1.2 = 90/s **and** restored > 2 × idle) **fails on the first clause**: each 50 ms pulse yields ~2 draws (the show + a spinner wakeup inside the window), ~10/s per terminal, not 5. The restore clause passes (4.3×).
- **CPU of the instance while idle: 34.9 → 42.5 s per 60 s (+22 %; instructions +36 %)** — Ghostty redraws the whole screen each time a surface becomes visible (its occlusion path rebuilds the cell state), so 15 × 5 pulses/s = 75 full redraws/s cost more CPU than 646 incremental draws/s. GPU falls because each full redraw is one presentation instead of ~43/s per terminal.
- Bundle a is flat across phases (the `idle` command is unknown to it), as expected.

## Disclosures

1. **Attempt 1 (23:56–00:05Z) is void for the idle arm:** the hold script passed perf-main as the harness, whose `.build/dev-input` predates the `idle` kind (exit 2, hidden by `check=False`), so the policy never engaged; its rows (`idle-visible-attempt1-idle-not-engaged.jsonl`, b idle 204 draws/s ≈ active 192) show the instrument working and the policy off. Attempt 2 (00:06Z) used perf-idle's `dev-input`.
2. Attempt 2 ran 2 runs (not 3) to fit the window after attempt 1.
3. The in-script GPU sampler failed in attempt 1 (an int() parse on ioreg's dict line; fixed for attempt 2); the shell sampler `runs/gpu-2356.log` ran alongside from 00:00:48Z and shows alternating zeros, consistent with the counter being reset on read by two readers — so the table's GPU column is the in-process series only.
4. Focus checks (`focus-check.jsonl`): 7 pre-checks passed (a Discord window on display 1; HID idle > 5000 s), 7 post-checks "ok, action none"; no exposure.
5. Machine: queue paused, machine-watch booted out 23:55:30–00:31:30Z, typing-watch running (reads Tim's app), Tim idle throughout (HID idle ≥ 5331 s at START).

## Key-path probe (00:20:15–00:21:13Z, `runs/key-path-probe.json`, bundle b with #69's metrics)

One terminal running a pty stamper; 60 keys posted 100 ms apart through `dev-input key a`. All 60 arrived in order. **Post → program median 210.6 ms (p90 230, max 241)**; easl's share: `key.wait` mean 24.4 ms (max 47.3), `key.handle` mean 0.11 ms (max 1.4). The remainder (~185 ms minus the dev-input process spawn, est. 30–60 ms) is the writer side — Ghostty's IO thread → pty → zmx client → zmx daemon → program — on an unloaded single-terminal instance. That is the first number for the PTY-write follow-up and it is large.

## WindowServer CPU per phase (shepherd's 1 s `sudo ps` rows, `ws-cpu-trial6.jsonl`, medians [p10–p90])

| bundle · phase | run 1 | run 2 |
| --- | --- | --- |
| a active / idle / restored | 24.0 / 25.1 / 23.5 % | 23.9 / 26.1 / 23.5 % |
| **b active / idle / restored** | 26.5 / **21.1** / 24.9 % | 24.9 / **21.5** / 26.0 % |

WindowServer drops 4–5 points of a core (−17…−20 %) in both idle phases of b and in neither of a; b's idle medians (21.1, 21.5) sit below every other phase median of either bundle. Net for the Mac at 5 pulses/s: WindowServer −45 ms/s, the instance +125 ms/s → **CPU worse by ~80 ms/s, GPU −64 %**.

## Reading

Occlusion pulses do what they were for — the native presentation path is bounded, GPU load falls by two thirds while the user is away and comes back on input — but 5 pulses a second buy that with +22 % CPU on the instance because Ghostty treats each un-occlusion as a full redraw. Before a PR: fewer pulses (2/s halves the full redraws: est. instance +60 ms/s against WindowServer −45 and GPU still well down; 1/s would net-win CPU too but a spinner at 1 frame/s barely reads as alive — Tim's tile said "~5 Hz"), remeasured in a short window; or a cheaper reveal if Ghostty offers one.
