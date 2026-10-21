# Measure easl without confusing endpoints

Read the installed `benchmark-checklist` skill before measuring or reporting performance. Use only a claimed guest, frozen compared builds, the same fixture bytes, and the same observer for both builds. `docs/testing.md` owns the full tool contracts. This page selects the tools and their limits.

## Record the experiment

Before the run, write the source SHAs, instrumentation changes, compiler and flags, executable hashes, route, fixture hash, native bounds, sample count, deadlines, order, and endpoints. Keep every failed, timed-out, unattempted, and incomplete row. State whether percentiles describe only completed samples. One observation or a three-sample smoke is not qualification.

Time native input and output with one guest's `mach_absolute_time`, converted by its timebase. Do not combine guest clocks or substitute epoch timestamps. Record capture cost and AX-walk cost separately. A capture-completion interval is a conservative readiness bound, not an exact first-paint measurement. Run profiles and captures separately from uninstrumented performance controls where their overhead matters.

## Observe browser response and sharp settling

Use `scripts/perf-browser-gates.py --help` and its module-level fixture/config contract. It observes an existing fixture; it does not provision one. The page must expose `#click`, `#rcMark`, `rcCapture`, `rcExpectedType`, and `rcNextColor`. The timed-input executable must print same-viewer mach milliseconds immediately before posting input. Retained source and builders are in `/home/tim/agents/projects/easl/state/lanes/easl-slow-link-perf-1/timed-input.swift` and `make-gates-config.py`; inspect and adapt those to the current fixture, never reuse their old PID, stream, window, or coordinates.

Create an actual config with the current board/tile, viewer PID/window, viewport, stream, marker, count region, input helper, SSH wrapper, and scratch host. Validate each against native pixels and source counter reads before collecting data. Invoke:

```sh
python3 scripts/perf-browser-gates.py --config "$G/gates.json" --label candidate --block 1
```

Use the same helper and fixture for direct and relay arms. For a full browser qualification, follow `docs/testing.md`'s 60-click-per-arm interleaved series and separate real-page RGB and wire-traffic controls.

- Gate A is native input to the first valid own-window SCStream marker display, with max-channel RGB error 16 and exactly one independently verified source increment.
- Gate B is the last queued input to its matching same-stream sharp-refresh assignment. JPEG and PNG have no idle refresh, so B is not applicable for those matching formats.
- First input-covering decoded assignment is neither A nor B. Keep its latency and format separately.
- Preserve immutable native PNGs, armed/observed receipts, mach launch/read brackets, trace events, helper stdout, and source-counter audit. Late, ambiguous, missing, and invalid-clock rows do not become successful percentiles. Sharp assignment does not establish native presentation or RGB quality.

## Exercise exact-size boards

`perf-board.py --objects N` generates exact-size fixtures with eight terminals, not N approximate tiles. Generate only into an unlaunched owned home:

```sh
python3 scripts/perf-board.py "$G/scale-seed" "$G/scale-root" --objects 500 --seed 7
```

The eight terminals each emit sequence lines every 125 ms. Touch `$G/scale-root/.perf-board-quiet` to pause them without ending sessions. An API count is not a fully drawn board.

For a matrix, build two frozen release bundles as `docs/testing.md`'s board-scale section specifies. Port only its required observation support to the baseline and retain that source manifest. Compile the helper once:

```sh
swiftc -O scripts/perf-window.swift -o "$G/perf-window"
python3 scripts/perf-scale.py --app base="$G/base.app" --app fix="$G/fix.app" \
  --fixtures "$G/fixtures" --window-helper "$G/perf-window" --runs 5 \
  --modes local,remote --easld "$G/easld" --ssh "$G/ssh" --out "$G/proof/scale"
```

The runner refuses physical-Mac launch and owns its run instances. Require real output from all eight streams and native OCR plus inspected pixels for startup readiness. Its native capture completion is an initial-viewport upper bound, not all-board completion. `harness_launch_ms` includes development bundle preparation. Whole-board `view.render` is a separate API result. Preserve placeholder, omitted, render-failure, and gesture-failure records. Frame callback-gap quantiles are not GPU presentation timings. Stop on cleanup failure before starting another row.

## Shape only the guest-loopback board route

The retained implementation is `/home/tim/agents/projects/easl/state/lanes/easl-slow-link-perf-1/shape-link.py`; its report records limits rather than a passing SLA. Copy it into your guest scratch, inspect it, and adapt its private PF anchor to `com.apple/$LANE`. Keep the `com.apple/` prefix so the default PF configuration evaluates it. Its fixed pipe IDs 27101/27102 must be absent before acquisition. Never overwrite an existing pipe or another lane's anchor. This mutates guest networking and is unnecessary for ordinary functional proof.

The tested profiles are 10 Mbit/s with 17+18 ms delay, 1 Mbit/s with 40+40 ms and 1% loss per direction, and 100 kbit/s with 75+75 ms. Rules select only IPv4 `lo0` TCP port 22, in both directions, leaving management SSH outside that route. The helper records prior PF status and loopback MTU, acquires a PF enable token, and temporarily sets MTU 1500. Verify the actual rule, endpoint, rate, and RTT rather than treating profile labels as observations.

Use a lane-specific copied helper at `$G/shape-link.py`:

```sh
test ! -e "$G/proof/shape-before.json" && test ! -e "$G/proof/shape-before-helper.json" &&
python3 "$G/shape-link.py" status "$G" > "$G/proof/shape-before.json" &&
mv "$G/shape-status.json" "$G/proof/shape-before-helper.json"
python3 "$G/shape-link.py" poor "$G"
python3 "$G/shape-link.py" clear "$G"
test ! -e "$G/proof/shape-after.json" && test ! -e "$G/proof/shape-after-helper.json" &&
python3 "$G/shape-link.py" status "$G" > "$G/proof/shape-after.json" &&
mv "$G/shape-status.json" "$G/proof/shape-after-helper.json"
```

Run `clear` only after a successful acquisition with its saved `shaper-state.json`. It empties only the private anchor, deletes only owned pipes, releases only its PF token, and restores the saved MTU. Require matching final state, not a global PF flush or disable. Retain setup, calibration, and teardown receipts before guest stop. Never run shaping commands on home. A failed acquisition needs inspection and cleanup of the recorded partial state, not another blind invocation.
