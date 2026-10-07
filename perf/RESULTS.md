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
| 3 | (harness) `rusage()` CPU in seconds (Mach units), docs rows | PR #58 | — | pending review | — |

## Next leads (ranked)

1. `publishLabel` per title change: 203/1523 samples of the stalled main thread (`swift_unknownObjectWeakLoadStrong` ×153 under `CanvasView.focusedTile`, `TerminalName.label` ×50). Now the largest per-change cost left.
2. Ghostty per-surface threads: ~70 wakeups/s and ~3.7 ms/s per working terminal (io-reader, io-gather, renderer, io), window viewed or not; libghostty internals (binary xcframework; needs a source build to change).
3. Heap: 184 MB MALLOC_SMALL dirty on the live app; census on a replica.
4. #33 remeasure (second window after 12:00Z; prereg to bench first).
