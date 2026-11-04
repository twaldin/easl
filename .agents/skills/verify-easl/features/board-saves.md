# Board-save attribution

Read [verify-easl](../SKILL.md) for claims, release builds, Doctor, native captures, export, and cleanup. Use an isolated development home and only scratch boards.

## Entry points

- `save-main-steps`: edit a local note, pan its canvas, close its window, and quit with a pending board save. Board debounce and in-flight coalescing use `save.schedule`; enqueue and flush admission use `save.enqueue`; board snapshot capture uses `save.snapshot`. Completion delivery, flush callbacks, checked-save resumption, and close continuation use `save.complete`. Close and quit preparation use `save.prepare`. Composer and viewport persistence use `save.composer` and `save.viewport`.
- `save-slow-worker`: the release-config app with `Tests/BoardSave/atomic-write-hook.c`, `EASL_TEST_SAVE_DELAY_MS=2000`, and `EASL_TEST_SAVE_DIRECTORY` set to the canonical private boards directory. The hook delays the real atomic rename on the worker. It does not deliberately delay main-thread completion.
- `save-slow-completion`: the native regression's `completion` and `completion-modal` modes delay a flush callback on main for 300 ms. Both require a durable note and a longest stretch attributed to `save.complete`.

## Run the native regression

```sh
swift build --build-system native -c release -j 2 --product Easl -Xswiftc -enable-testing
python3 Tests/BoardSave/run.py --bin-path "$(swift build --build-system native -c release --show-bin-path)" --output "$G/proof/board-save"
```

The runner covers concurrent edits, modal quit, failed close, completion attribution, and crash atomicity. Its `--ci-timing-report-only` option relaxes only the pre-existing slow-worker responsiveness upper bound. Completion attribution remains required.

## Drive the slowed-save journey

Use the release check's 204-object fixture, re-rooted to a recorded scratch directory. Record fixture changes and owned terminal commands. Build the hook with `xcrun clang -dynamiclib -O2`, sign it ad hoc, and inject it only into the private development app. A hardened copy requires the hook-only `allow-dyld-environment-variables` and `disable-library-validation` signing exceptions. Never modify the installed app or the frozen source bundle.

1. Warm the note editor and capture its own window before resetting metrics.
2. Start a note prop edit. Require a new `BoardSaveHook begin` log receipt.
3. Enter and commit new note text through native input while the write is delayed. Verify the note text with `object.get`.
4. Pan empty canvas through native scroll input. Require changed `view.get` viewport coordinates.
5. Wait for queued writes to finish. Retain `app.metrics`, the app log, board readback, stall records, and an after capture.

Report stretch causes, not only save durations. A turn of at least 50 ms must name a save span or have independent stack evidence identifying non-save work. An untagged turn alone cannot exclude save work. A run with no such turn proves the journey and counters, not the cause of a previous stall.

## Idle-cost pair

Compare matching release-config baseline and fixed bundles on the same quiet fixture and geometry. Warm each for 30 seconds, capture, then wait five seconds. Measure each for 600 seconds without input, compilation, profiling, or app polling. Record process CPU and package-idle and interrupt wakeups externally, plus metrics and board-file metadata at the interval boundaries. Require zero `save.write` delta. One pair reports observed cost; it does not establish general statistical equivalence.
