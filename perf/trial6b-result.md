# Trial 6b — idle redraw at 2 pulses/s: visible remeasure (2026-10-08 03:03–03:10Z)

Hold `2026-10-08T02:46Z-perf-hold` (full quiet; I lost the first 17 min waiting for a START the shepherd and I had each assumed the other owed — the go rule is now: a cleared hold is the go at its start). **One** interleaved pair ran, 03:03:26–03:09:39Z (a = main c2da458 `main-c2da458.app`, b = `perf/idle-redraw` 8b86fd7 `idle2.app` Easl sha befb7f340ee09b8c, `IdleRedraw.idleHertz = 2`), same setup as trial 6 (visible on CanvasTest display 45 / Space 19660, 15 spinner terminals, phases active 60 s → `idle on` 60 s → posted key, restored 20 s; `idle-visible.py`, rows `runs/idle2-visible.jsonl` sha 79d0b1f14588700b). Focus checks 2/2 pre passed, 2/2 post "none".

| bundle · phase | cpu s / phase | instructions G | GPU util % (ioreg, 1 s) | wrapper draws/s | WindowServer % (shepherd, median [p10–p90]) |
| --- | --- | --- | --- | --- | --- |
| a active | 35.6 | 106.4 | 52 | — | 44.1 [29–56] |
| a idle | 36.1 | 107.1 | 61 | — | 44.0 [39–48] |
| a restored | 11.8 | 35.1 | 63.5 | — | 54.0 [50–62] |
| **b active** | 34.8 | 92.6 | 55 | 576 | 50.5 [45–62] |
| **b idle** | **28.7** | **89.2** | **38** | **59.5** | **45.1 [44–48]** |
| **b restored** | 11.6 | 30.4 | 53.5 | 514 | 47.0 [45–50] |

- **The 5/s cost is gone:** the instance's instructions while idle are −4 % against its own active phase (5/s: +36 %), CPU time −17 % (5/s: +22 %). Two full redraws a second per terminal cost about what the 43 incremental draws they replace cost.
- **Wrapper draws 576 → 59.5/s** (= 15 × 2 × ~2, each pulse is a show plus one wakeup); restored 514/s. Pre-registered GUI check (idle ≤ 72/s, restored > 2× idle): **PASS**.
- **GPU −17 points (55 → 38 %) and WindowServer −5.4 points (50.5 → 45.1 %) within b**, restored on input — but see the confound below; trial 6 (Tim idle throughout) measured −24.5 GPU points and −4…−5 WindowServer points at 5/s, and the idle-phase redraw rate at 2/s is lower still, so the GPU/WindowServer saving is expected to be at least that; tonight's run can't prove it.

## Disclosures

1. **Tim was active** on his board (easl frontmost; HID idle 0.1 s at 03:03:28Z, 9.5 s at 03:06:33Z, last input ≈ 03:07:42Z, 117.8 s idle at 03:09:39Z): the whole of a and the first half of b's active phase ran under his activity, b's idle phase after it. The ambient GPU (52–63 % even in a) and WindowServer (44–54 %) were ~2× trial 6's and not stationary, so a-vs-b and b-active-vs-b-idle GPU/WindowServer differences are confounded; a's restored phase jumping to 54 % WindowServer is his activity, not the bundle. The instance's own rusage (instructions in particular) is what this run can speak to.
2. One pair, not two (window lost; disclosed above). The key-path probe did not run.
3. Shepherd's hold summary: pane `obj_01M4BWM1AV0JXSW1H4` = **Tim's own tiktok session** caught loading the machine in 3 minute-samples: 02:47:16Z Python 199 % + ffmpeg 91 %, 02:55:06Z Python 172 % (both before the run), **03:04:11Z Python pid 35946 at 91 % inside a's active phase** (03:04:06–03:05:06Z); 1 s samples once a minute, true spans unknown — a's phases near 03:04Z are possibly loaded (its instructions 106 G vs 83–88 G in trial 6 fit that: a ran under Tim's activity and his session's CPU). sky-lead's 60 ms read-only process at 03:05:14Z (inside a active), astra's `ls` 02:45–02:47Z (before the run), bench's sleeping timer: negligible.
4. machine-watch booted out 02:45:30–03:11:30Z; WindowServer rows `~/.local/state/machine-shepherd/ws-cpu-trial6b.jsonl` from 02:45:50Z.

## Run c — the clean pair (04:48–04:54Z, no hold: quiet windows were abolished at ~04:42Z; `machine-ok-queue run`)

Same setup, one interleaved pair, Tim idle through a and b's active/idle phases (he became active during b's restored phase). No WindowServer column (the shepherd's sampler is gone). Rows `runs/idle2c-visible.jsonl`.

| bundle · phase | cpu s | instructions G | GPU util % | draws/s |
| --- | --- | --- | --- | --- |
| a active / idle / restored | 34.6 / 34.7 / 11.7 | 93.4 / 97.2 / 31.2 | **40 / 40 / 40** | — |
| b active / **idle** / restored | 34.8 / **29.7** / 11.7 | 93.8 / **89.4** / 34.8 | 39 / **17** / 65 (Tim active) | 631 / **60.0** / 793 |

- GPU: a is flat at 40 % through all three phases (a steady ambient, Tim idle), b drops **39 → 17 % while idle (−22 points, −56 %)** and comes back on the posted key. The 5/s run's −24.5 points is matched at 2/s with ~40 % of its redraws.
- Instance: CPU −15 %, instructions −4.8 % while idle (the pulses cost about what they save); draws 631 → 60/s (= 15 × 2 × 2), GUI check PASS.
- Queue state during the run: Tim's tiktok `edit.py --preview` renders (GPU, nice 10, clamped to utility) ran in the queue — ambient to both arms, and a's flat 40 % says it was steady.

## Reading

At 2 pulses/s the policy is free for the app itself and removes ~90 % of the terminals' redraws while the user is away; the GPU/WindowServer saving measured clean at 5/s (trial 6) applies at least as much at 2/s but was not cleanly remeasured tonight. Run c (clean) confirms it: GPU −22 points (−56 %) while idle at no app cost. PR #83 at 2/s for 0.2.4.
