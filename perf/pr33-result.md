# PR #33 remeasure — result (perf, 2026-10-07, hold 2026-10-07T19:40Z-perf-hold)

Registration f91bb2e4 + A1–A3, notes 1–3, attempt-counting ruling. Run on the shepherd's START (19:41Z), displays stable (Tim's + CanvasTest display id 45 / Space index 10 / SkyLight 19660, UUID 78FCD58F; `EASL_DEV_FRAME=1522 -972 1492 922`), harness `perf/pr33-harness` **58aad4b** (c2da458 + `birth_frame(display_id)`), bundles base **0347b5d050c7918f** (5da311a + #57) and p2 **103a6506705cb349** (a9928c6 + #57), `--birth-display 45`, 3 runs interleaved (b,p / p,b / b,p), Space 6, every launch born on CanvasTest and moved by the GR1 guard, window-watch armed (allow ids [9, 19660]), gate `machine-ok --memory --wait` (pinned 68ea4029; the queue would have deadlocked behind foreign tickets my own hold paused: reported to meta).

## Primary pairs (medians of 3, [range]; "improved" = every p2 run below every base run)

| pair | base | p2 | Δ | separated |
| --- | --- | --- | --- | --- |
| P1 visible-serial · cpu_s | 5.43 [5.35–5.44] | 3.17 [2.59–3.21] | −2.26 s (−42 %) | **yes, 3/3 → improved** |
| P2 visible-batch · longest_ms | 64.0 [60.3–285.8] | 46.0 [45.0–60.5] | −18 ms (−28 %) | **no** (p2's 60.5 ≥ base's 60.3; one base run hit 285.8) → no claim |
| P3 pan-zoom · html_reuses | 42 [42–42] | 42 [42–42] | 0 | equal → no claim (loads 18 = 18 too) |

## Secondary (as printed; no claims beyond the pairs)

- visible-batch cpu_s 4.53 [4.48–4.56] → 2.38 [2.19–2.50] (−47 %, separated); visible-serial longest_ms 57.5 [55.2–62.2] → 36.9 [29.6–46.6] (−36 %, separated).
- poll-idle: cpu 1.20 → 1.31, longest 10.5 → 11.3 ms (not separated). pan-zoom: cpu 4.28 → 4.17, longest 95.1 [90.6–108.2] → 101.2 [99.1–103.4] ms (not separated), routings 0.
- Gates as printed: base FAIL cpu on both bursts, PASS poll-idle and pan-zoom; p2 FAIL cpu on visible-serial (3.17 s vs < 3 s target), PASS visible-batch and poll-idle, FAIL pan-zoom stretch (101.2 vs < 100 ms; base 95.1 PASS).

## Disclosures

1. **Attempt 1 (void launch).** `run.sh measure` started 19:42:32Z and launched run 1/3 base, pid 56091 (window 91752 first seen on display 45 / Space 19660 at 19:42:37Z, verdict allowed, moved to Space 6 at 19:42:38.157Z); `Instance.start()` then failed in `zoom_to_cards` because the fresh registered worktree had no `.build/dev-input` (bundle.sh builds it; `dev.sh input` needs it). perf-loop's `finally: inst.stop()` stopped the instance and removed its scratch dir; zero scenarios, zero rows. Replaced once in position (run 1/3 base) by attempt 2 — ruled a void launch under A1–A2.
2. **dev-input binary used by attempt 2:** `perf-pr33-harness/.build/dev-input`, sha256 `42eed11e6080390133f3f01f…`, copied from `perf-main/.build/dev-input` (same sha); source blob `scripts/dev-input.swift` = `a7ae0726…` in both worktrees (unchanged since 8679fde; not in the registered diff).
3. **Hold script gap:** hold-1940.sh ran `run.sh measure 2>&1 | grep -v …` so `set -e` saw grep's status, and the script went on to trial 4's A/B after the failure instead of stopping.
4. **Trial 4's agent-titles A/B ran between the attempts** (19:42:44–~19:55:00Z, Space 6, 6 launches) — not under this registration; swarm's disturbance (19:46:45–19:53:32Z, up to 1 core for 38.5 s) falls inside it only. Its own verdict: not separated, no claim.
5. **Attempt 2 window and load:** 19:55:19Z–20:15:0xZ, 6 launches (19:55:33, 19:58:40, 20:01:41, 20:04:43, 20:07:51, 20:10:58Z watcher ends), `killed: []` on all; shepherd's machine rows over the window (142 rows): CPU idle median 77.0 % (min 49.8 %), WindowServer median 49.9 % (Tim's board visible, ambient for both arms); the registered harness carries no per-row load sample (that field is #58's). No other process ran on home for a hold owner besides mine after 19:53:32Z (shepherd).
6. Tim's board (16–17 live agent tiles, visible on Space 4) is ambient to both interleaved arms.

## Receipts (sha256, first 16)

gui-launch.jsonl `3cb86ff2136fad30` (858 lines) · window-watch.log `aaba3816031a4296` · pr33/ab.jsonl `ac38281d6afd67f2` (24 rows) · runs/ab-label-9dd9765.jsonl `b9652281d73b2c21` · base Easl `0347b5d050c7918f` · p2 Easl `103a6506705cb349` · logs: runs/hold-1940.log (attempt 1), runs/hold-1940-measure.log (attempt 2), pr33/table.txt, pr33/compare.txt.

## Reading

#33's phase 2 holds on what it claimed for write bursts: CPU per serial burst −42 % with full separation (and −47 % for batched writes, −36 % longest stretch there, both separated as secondaries). The longest-stretch claim for batched writes is not separated at n=3 (one base outlier at 285.8 ms and a 0.2 ms range overlap). Pan-zoom is unchanged in every metric — p2 did not touch it, and the HTML page reuse count is identical — so P3 is "equal", not a regression.
