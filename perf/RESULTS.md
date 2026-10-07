# perf: results

One row per trial. Objective: lower easl's GPU memory, footprint, CPU, wakeups and main-thread stalls on Tim's real boards (idle, pan/zoom, agent bursts) with behavior unchanged and every test passing. Harness: `scripts/perf-loop.py` (interleaved A/B of frozen release bundles), `scripts/perf-replica.sh`, `scripts/perf-sanitize.py`, `scripts/perf-board.py --terminals`. Methodology rulings: bench-judge. Evidence under `~/dev/easl-lanes/perf-lead/` unless noted.

## Baseline: Tim's live app on home (read-only, 2026-10-07 04:55–05:15Z)

easl 0.2.1 (15), pid 24608, up 12.3 h, window 87438 on Space 4 (not the viewed Space: Ghostty draws nothing, GPU 0 %). Live tiles: 13 terminals (all omp; 7 "working" with omp's 80 ms title spinner), 1 browser, 7 notes, 6 code. Home boards are small (canvas 14 objects, sky-agent 13, home 3, dotfiles 2): the home workload is terminals + their agents, not board geometry.

| metric | value | how |
| --- | --- | --- |
| footprint | 455 MB (peak 1153) | `footprint -p`; MALLOC_SMALL 184 MB dirty (+109 reclaimable), IOSurface 74 MB (+128), graphics owned 70 MB, MALLOC_LARGE 46 MB, CoreAnimation 24 MB, CG image 12 MB, IOAccelerator 7.5 MB (+39) |
| CPU, whole process | 0.2 % (10 s rusage) to 6.3–7.5 % (top -c d, 5×3 s) | bursty with agent output |
| CPU by thread, 10 s | 55.6 ms/s total: main 28.8; io-reader 9.4 (14×), io-gather 8.5 (14×), renderer 5.1 (14×), io 2.8 (14×) | `proc_pidinfo` PROC_PIDTHREADINFO deltas |
| interrupt wakeups | 534/s (rusage 10 s); `easl metrics` 567/s | 13 terminals ≈ 40/s each; `top` IDLEW 0 (undercounts on a busy machine) |
| main thread | busy 2.9 % (233/8141 samples); `easl metrics` 4.2 % over 60 s; 54 stretches ≥50 ms and 6 ≥250 ms in 12 h, longest 352 ms | `sample 24608 10 1` → `baseline-sample-live-10s.txt` |
| GPU | Easl 217 s accumulated GPU time in 12.3 h (0.49 % average); this window 0 % (unviewed Space); WindowServer 6.7 % | ioreg `AGXDeviceUserClient` `accumulatedGPUTime` deltas (as `machine-ok --gpu`) |

Main-thread busy breakdown (10 s sample, 233 busy samples): **~138 (59 %) in terminal title handling** — `TerminalTile.titleChanged` → `refreshProgram` → `ForegroundProgram.leader/process/members` (`__proc_info` 50, `__sysctl` 49 leaf samples) + `publishLabel`/`TerminalName.label` 15; ~56 AppKit event plumbing (HID driver, menu bar tracking); the rest noise. omp emits a deduplicated title with a braille spinner every 80 ms while working (`vxl = 80` in the omp bundle), so 7 working tiles ≈ 88 title changes/s, each a full process-tree walk on the main thread: `proc_pidinfo`(shell) + `sysctl KERN_PROCARGS2`(shell, parsed incl. environment) + `proc_listpids`(pgrp) + `proc_pidinfo`×members + `sysctl KERN_PROCARGS2`(leader, parsed incl. environment) + `proc_pidinfo` VNODEPATHINFO. Measured syscall costs (ctypes, this machine): bsdinfo 1.9 µs, procargs 6–10 µs, listpids 12 µs, vnodepath 1.5 µs.

Ranked targets (by measured waste on this workload):
1. Title-change process walk on main: ~17 ms/s of main-thread CPU and ~88 main-thread wakeups/s while agents work, window viewed or not.
2. Ghostty per-surface threads: ~26 ms/s and most of the ~534 wakeups/s across 14 surfaces, also while the window is on an unviewed Space (libghostty internals; `patches/`).
3. Heap: 184 MB MALLOC_SMALL dirty with 13 terminals + 13 small tiles; needs a heap census on a replica (never on Tim's live app).
4. Peak footprint 1153 MB: cause unknown (10 `view.render`s in 12 h; WebKit?). Needs a reproduction.
5. GPU while viewed: not measurable now (window unviewed); measure on a replica with `--terminals` once a Space is assigned.

## Trials

| # | hypothesis | commit | numbers | decision | evidence |
| --- | --- | --- | --- | --- | --- |
| 1 | A tile keeps the foreground job the process-table walk found (`ForegroundJob`: shell + leader by pid/start/executable, group, how it was found) and re-checks it with 2–3 `proc_pidinfo`s for at most 1 s; argv reads stop before the environment; no `proc_listpids` per check. | PR #56 → main 1bdfe11 (v0.2.2); bundles `perf-lead/bundles/main-birth-c38f990.app` vs `title-ab-4900dd7.app` (both + #57) | `agent-titles` ×3 interleaved, 8 working tiles: main-thread busy 47.4 → 26.5 ms/s (−44 %, every fix run below every main run); CPU ≈ −25 % (coarse); wakeups 576 → 553/s (not separated: Ghostty's threads). Live: home's app stalled at 100 % main thread in this path with 15 omp tiles (06:07Z sample). | **keep** (merged, released in v0.2.2; bench: supporting evidence, not preregistered) | `perf-lead/runs/ab-titles-4900dd7.{jsonl,txt,compare.txt}`, PR #56 comment, `perf-lead/live-hang-sample-0607Z.txt` |
| 2 | (infrastructure) `EASL_DEV_FRAME`: a dev instance's window opens on CanvasTest, never on a viewed Space; `perf-loop.py --birth-display`. | PR #57 → main c2da458 | proof launches: window first seen on display 43 / Space 10, moved to 6; 0 of 6 A/B launches on display 1 | keep | `perf-lead/gui-launch.jsonl` (sha 5fc65307…), `perf-lead/window-watch.log` |
| 3 | (harness, Tim's 07:05Z ask) load-tolerant rows: `ri_instructions`/`ri_cycles` per scenario and per handled event (a fixed loop beside six spinners: instructions ±0.05 %, CPU time +5 %), the Mac's load per row with `loaded` (idle < 30 %), DevPerf stretches by main-thread CPU (`longest_cpu_ms`); rusage Mach units → seconds | PR #58 (0ccf804) | — (first rows from #33's run) | pending review; meta approved the method 07:2xZ: A/B deltas need no hold, wall-clock gates keep a heavy-only hold until the CPU-stretch gate is adopted | `perf-followups` |
| 4 | the title handler loads the canvas once per change (4 weak loads → 1: 10 % of the saturated thread's samples were `swift_unknownObjectWeakLoadStrong` in that closure) | `perf/title-label` 9dd9765 (local) | agent-titles ×3 interleaved, main c2da458 vs label (19:42–19:55Z, Space 6, not loaded): main_ms_s 39.1 → 32.9 (−16 %), cpu_s 3.78 → 3.42 (−10 %), instructions 3.90 → 3.78 G (−3 %); **not separated** (ranges overlap, n=3) | **no claim; parked** (`runs/ab-label-9dd9765.*`) | hang sample `live-hang-sample-0607Z.txt`; 07:22Z sample `live-sample-0722Z.txt` (0.2.1: publishLabel 9 % of a 6 % busy main thread) |

## PR #33 remeasure (registered; 2026-10-07 19:55–20:15Z)

#33 (perf phase 2) was squash-merged as a5c2945 on 2026-10-06 and shipped in 0.2.1; this remeasure judges what it shipped (bundles 5da311a vs a9928c6 = main's tree before and after, each + the dev-frame change). Result: `perf/pr33-result.md` (rows `pr33-ab.jsonl`, table `pr33-table.txt`), judged valid by bench. P1 visible-serial cpu_s 5.43 → 3.17 s (−42 %, separated 3/3: **improved**); P2 visible-batch longest 64 → 46 ms (−28 %, not separated: no claim); P3 pan-zoom html_reuses 42 = 42 (equal). Secondaries separated: visible-batch cpu −47 %, visible-serial longest −36 %. Pan-zoom and poll-idle unchanged; two gates still fail on both: serial-burst CPU 3.17 s vs < 3 s, pan-zoom longest ~100 ms. One void launch (attempt 1, setup fault) replaced in position; disclosures in the result.

## Next leads (ranked)

0. **Idle GPU (shepherd, 18:37Z; sample 18:38Z)**: easl 17–19 % GPU and WindowServer 48–51 % CPU with Tim idle and his board visible. Each live terminal's `NSView.displayLink` runs at `CAFrameRateRange(60–120, preferred 120)` (vendored AppTerminalView.swift:186) and draws on every PTY wakeup; 15 agent terminals × 12.5 spinner ticks/s ≈ 190 unsynchronised draws/s → the ProMotion window updates on nearly every one of 120 frames/s: one CA commit (82 ms/4 s on main: `collect_animations`, `commit_if_needed` over the whole layer tree) and one WindowServer composite per frame. Shepherd's 60 s baseline 18:45Z: GPU 24.1 % (Easl 15.3, WindowServer 8.8), WindowServer CPU 47.4 %, idle 4980 s, 16 live tiles. Trial 5 (wrapper link capped at 60 Hz, PR #67) **withdrawn**: the wrapper's draws are wakeup-bound at any link rate and libghostty presents from its own CVDisplayLink regardless (Spec review P2). Trial 6 (Tim's yes 18:55Z): while idle the terminal is kept **occluded** to Ghostty and shown for one redraw 5×/s (50 ms pulses) — `perf/idle-redraw` 8a46326; visible measured run + GUI check in the 23:56Z full-quiet hold on CanvasTest. Sample: `perf-lead/gpu/live-sample-1838Z.txt`.
1. `publishLabel` per title change: 203/1523 samples of the stalled main thread (`swift_unknownObjectWeakLoadStrong` ×153 in the `onTitle` closure, `TerminalName.label` ×50 in Foundation's case-insensitive `range(of:)`). Trial 4 covers the first; the second is ~3 % and stays.
2. Ghostty per-surface threads: ~70 wakeups/s and ~3.7 ms/s per working terminal (io-reader, io-gather, renderer, io), window viewed or not; libghostty internals (binary xcframework; needs a source build to change).
3. Heap: 184 MB MALLOC_SMALL dirty on the live app; census on a replica.
4. #33 remeasure (second window after 12:00Z; prereg to bench first).
