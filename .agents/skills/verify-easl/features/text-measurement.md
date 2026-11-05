# Delegated text measurement

A remote board asks its viewing Mac to measure notes, text shapes, labels, arrow captions, and code captions. These measurements feed `layout.check` and intrinsic object sizes.

## Sub-features

- `measure-exact` preserves the complete size result for every item kind, including table shortfall, math, and Mermaid outcomes.
- `measure-responsive` leaves the main run loop available during a heavy delegated batch.
- `measure-terminal` keeps native terminal keys responsive while a remote board runs `layout.check`.

## Run the native regression

Use a claimed guest with the toolchain required by [testing.md](../../../../docs/testing.md). The executable pumps the real main run loop and calls the actual delegated handler.

```sh
swift build -c release -j 2 --product CanvasCoreTests -Xswiftc -enable-testing
BIN=$(swift build -c release --show-bin-path)
test ! -e "$G/proof/measure-fix"
"$BIN/CanvasCoreTests" --text-measure-regression \
	--output "$G/proof/measure-fix" \
	--expected "$G/proof/measure-base/sizes.json"
```

For historical comparison, first build the same test sources against the unchanged production source. Run without `--expected` into a fresh `measure-base` directory. Retain the expected nonzero responsiveness result and its output files. Never regenerate the baseline from the candidate.

Require a zero exit status from the candidate. Inspect `report.json` for zero `main.stretch50` and `main.stretch250` counts and timer callbacks inside the 200-note request. Compare `sizes.json` byte for byte with the baseline. Keep `corpus.json`, which names each fixed input and includes all item kinds, tables, Unicode, math, and deterministic Mermaid image, fallback, and absent outcomes.

The normal `CanvasCoreTests` suite also runs this probe in an isolated process and compares worker results with main-thread layout. The historical file adds an independent before-and-after check.

## Exercise the remote board while typing

Follow Launch, Doctor, Evidence, and Cleanup in [verify-easl](../SKILL.md). Use release bundles from recorded source revisions and a guest-local scratch easld over loopback SSH. Follow the [performance controls](../performance.md). Do not use a production board or substitute a local board.

1. Seed 200 notes containing tables, long paragraphs, lists, and unanchored code fences. Keep one real terminal visible beside a note. Use the same content bytes, frames, and viewport for both builds. Retain the fixture and its hash.
2. Make each note shorter than its content so every measurement produces an overflow finding. This makes an approximate fallback visible in the response.
3. Open the remote tab, refresh its PID and window ID, and pass Doctor. Capture the actual board and shell prompt. Click the terminal body and require a fresh `CanvasTerminalView` responder receipt.
4. Enter a harmless shell command prefix. Send a repeated native key with `input key a --repeat 100 --interval 20 --window "$WINDOW"`. Run `layout.check --board "$BOARD"` against the scratch host while that burst is in flight.
5. Time each complete socket request and response with one monotonic clock. Require ten successful checks per build. Save every response, including errors and approximate results.
6. Reset viewer `app.metrics` before each check, then read it after the measured main-loop turn closes. Retain `main.stretch50` and `main.stretch250` counts and `maxMs`, `longest`, key counters, and the app log.
7. Wait for the matching `DevInput: burst of 100 key took` completion receipt before appending and submitting the shell command. Verify all 100 characters in a scratch receipt file. The input helper's exit only acknowledges the queued notification, not completion of its timer burst.
8. Capture the board after the ten checks. Export and inspect both builds' PNGs and receipts. Report every batch wall time, stretch counts and maxima, errors, fallbacks, and typed receipt results.

Keep captures, accessibility walks, and profiling outside the reported intervals. Profile a separate batch to identify the work behind any long main-thread turn.

## Limits and failure signals

- Easld falls back to approximate glyph-table measurement when its viewer does not answer within two seconds. A fast fallback is not a completed exact batch.
- `layout.check` adds `approximate` only when a finding depends on an approximate size. Its absence on a board with no findings does not prove delegation succeeded.
- SwiftMath's view-based sizing and Mermaid's WebKit service stay on main. Only attachment bounds, diagram point sizes, and fallback text enter worker layout. Include their native parity cases even when the heavy responsiveness corpus excludes them.
- This journey does not qualify note display editing, HTML measurement, or Mermaid prose-churn timing. Run the [note Mermaid probes](note-mermaid.md) when the renderer changes.
