# Testing easl

## Behavior tests

```sh
swift run -j 2 CanvasCoreTests        # swift-testing suites for CanvasCore
bun scripts/gen-clients.ts --check    # generated TS/Python clients match schema/easl-api.json, package versions match VERSION
(cd clients/python && python3 -m unittest)   # Python SDK (Python 3.11+): compositions loading, shipped compositions, the default socket's platform choice, connection config/reconnect against a fake socket
bun test extensions/agent-hooks             # hook payload classification: which thread (the tile's session, a subagent, Codex's internal sessions) an event comes from; the Codex awareness block's easl commands stay plain words
bun test clients/ts                         # TS client: the default socket's platform choice (the app's on macOS, easld's elsewhere)
bun test cli/metrics-text.test.ts           # `easl metrics` text: the draws and keys lines show with values, not before, and the stalls line
bun test scripts/rotate-lead.test.ts         # finite lead rotation against a stateful external easl CLI fixture
python3 -m unittest discover -s scripts     # Python script tests
(cd conformance && go vet ./... && go test ./...) # the conformance runner's normalisation and diff (Go 1.26)
(cd easld && go vet ./... && go test ./...)  # easld (Go 1.26): its packages' tests, and the conformance suite replayed in-process (cmd/easld, ~2 min; -short skips it)
```

Run every Bun, Python, and Go command above on Linux as well as macOS. Only `CanvasCoreTests` needs macOS. The hook suite covers socket replacement between checks. The Linux watcher retains the observed socket inode with one `O_PATH` descriptor, preventing inode reuse, and releases it on replacement or stop. macOS keeps its existing metadata polling. The rotation suite covers SIGTERM both while its CLI child runs and after the child exits.

The CI `easld` job installs real zmx 0.8.1 for two regressions. `TestSpawnFirstAttachRestoresBracketedPaste` checks that the first viewer receives the session's retained bracketed-paste mode. `TestBoardStaleRealZmxTaskCompletionIsNotShellExit` checks that completing a `zmx run` task leaves its live shell out of `board.stale`, and ending the session reports `exited`. `.github/workflows/ci.yml` pins the version and SHA-256 digest in the `Install zmx` step. The step checks the release's `.sha256` file against that pin and verifies the archive before adding zmx to PATH. Without zmx installed, these tests skip locally. The other session tests and owned-terminal conformance scenarios still select their file-backed fixtures explicitly.

`CanvasCoreTests` is an executable target, not a test target. `main.swift` calls the swift-testing entry point because `swift test` does not discover these suites with the Command Line Tools. Select the Apple toolchain with `xcode-select` or `DEVELOPER_DIR` before building. CI uses the Command Line Tools, as local development does. `Package.swift` resolves swift-testing's framework, runtime, and macro plugin paths for the selected toolchain. Tests drive real objects (boards, the socket server over a Unix socket), never mocks of our own code.

Core suites run in parallel by default. `SurfaceVideoTests`, `SurfaceImageEncoderTests`, `SurfaceImageDecoderTests`, and `SurfaceVideoQualityTests` share the `SurfaceHardwareCodec` actor to cap synchronous hardware-codec work. Concurrent VideoToolbox session creation can occupy every cooperative worker. Quality scoring still checks every RGB and RGBA byte of every frame.

The following named tests use isolated child processes while the rest of Core stays parallel:

- `identifyingAMacDoesNotHideProtocolFailures` retains its 200 ms protocol deadline without unrelated executor backlog.
- `nullAndMovedDeadlineCancelOldTimerAndOmissionPreservesDeadline` updates its 200 ms objects before unrelated main-actor work can expire them.
- `futurePersistedDeadlineFiresAfterRegistryAndStoreRestartWithSystemAttribution` restarts before its real two-second deadline.
- `wireTimeoutUsesOnlyTheDeadlineRemainingAfterQueueing` retains its two-second wire deadline and 500 ms completion bound.
- `timedSendWaitsForEarlierBytesAndItsEntireJSONLine` owns the descriptor table for its bounded descriptor-reuse probe.
- `anotherHomesStartupKeepsAReadyCopyForAsLongAsItsLeaseIsHeld` checks immediate lease release without concurrent process launches.
- Ten fixtures require the first unforced sharp successor to be predicted, although VideoToolbox may choose a keyframe. Fresh-process isolation reduces observed failures; it is not an API guarantee:
  - `SurfaceVideoTests`: `nativeSharpFrameStartsTheContinuingPredictionChain`.
  - `SurfaceImageDecoderTests`: `refreshBecomesTheReferenceForNativeSizePredictedFrames`, `rejectedRefreshBoundariesLeavePublishedReferenceUsable`, `malformedRefreshInvalidatesPredictionUntilIndependentKeyframe`.
  - `SurfaceImageEncoderTests`: `settledRefreshReplacesTheOddCanvasOnceAndBecomesTheLiveReference`, `acknowledgedSharpReferenceRemainsPredictiveWhenInputResumes`, `smallChangesKeepTheFrozenPendingRefreshAndFollowItsReferenceAfterDelivery`, `cumulativeSmallChangesRefreshAfterQuietWithoutStarvingTheFrozenSnapshot`, `changesConfinedToOnePercentDoNotRepeatedlyRefresh`, `inputCancelsARearmedCumulativeRefreshWithoutLosingTheSharpAnchor`.
- `persistentChannelCannotStarveFileReadsAndClosingReapsBothMasters` measures its three-second file-read bound without unrelated main-actor fixture work.
- `filesRequestedTogetherShareOneGitDiff` admits its three requests without unrelated executor work splitting the 20 ms batch window.
- `theFirstSocketHandshakeGoesOnlineWhileGlobalWorkersAreBlocked` deliberately blocks the global worker pool.
- `pollingContinuesWhileTheMainActorIsBusyAndCancellationDropsChanges` deliberately blocks the main actor.
- `programsTheHolderStartsDontInheritTheLock` owns its descriptor-inheritance probe.

`LineClient` scans only newly received bytes while a line is incomplete, so large replies do not repeatedly rescan their prefixes. The note-recovery reconnection fixture waits until the host observes the refresh request before waiting for the mirror's read to finish.

`HostReferencesTests` uses the runner's `list` fixture mode to return the listing stored under its private `TMPDIR`. It creates no executable script during the suite, so a cold script cannot consume the unchanged two-second zmx subprocess deadline.

Use Bun 1.4.3 or later for the host-file suites and on board hosts. Bun 1.3.14 can return successful but empty subprocess output before draining stdout. In the HostNotes stress probe this discarded Git output and transiently made a valid fixture appear outside a repository. [Bun's synchronous EOF fix](https://github.com/oven-sh/bun/pull/33832) drains stdout and stderr before returning. Upgrade Bun rather than weakening the assertions, serializing the suite, or retrying empty output. CI pins the qualified 1.4.3 runtime and prints its version.

`IsolatedVideoAudioTests` is an opt-in, headless check of the production audio reader, renderer, and synchronizer. On a Mac with a working audio device, run it separately:

```sh
EASL_TEST_AUDIO_FIXTURE=/absolute/path/to/audio.mp4 swift run -j 4 CanvasCoreTests --no-parallel --filter IsolatedVideoAudioTests
```

Use the release fixture with SHA-256 `3dea05779a4899c9e105d25b152f4c4c817d17107b2b8896c1506b0bbacb60c6`. The test rejects other bytes and requires `--no-parallel` because its test-only Objective-C guards temporarily intercept framework methods. Each guard calls the original implementation. Before forwarding any sample enqueue or nonzero clock rate, it requires renderer volume zero and exits the process on a mismatch. Over about five seconds, the test requires the production `.ready` callback, rendering status without an error, submitted samples, and advancing time before and after a seek to 20 seconds. It cancels audio and drains its worker before restoring the methods. It launches no app or window and does not change system audio settings. Without `EASL_TEST_AUDIO_FIXTURE`, the test is skipped. This check does not replace local or remote GUI playback proof.

`swift run -j 2 CanvasCoreTests --no-parallel --filter SurfaceImage` selects the stream encoder and decoder suites. Tests cover sharp prediction through small input, independent motion after large input, renewed settling, cancellation recovery, malformed packets, declared dimensions, and native padding crop. The JPEG case decodes a valid image larger than 265,627 bytes and checks literal pixels. `swift run -j 2 CanvasCoreTests --no-parallel --filter SurfaceRefreshTransfer` checks one-chunk receipt flow, duplicate and invalid receipts, complete assembly, and discarded partial transfers. `SocketServerTests` and `EaslConnectionTests` block real writers before canceling queued refresh lines. Their consumer must receive the committed line, another stream, and the replacement in order without the canceled line. Transfer-only cases use bounded opaque bytes. Decoder integration uses the actual codec.

Production streams retain the 0.3.0 behavior: independent sharp refresh codecs, one outstanding 16 KiB chunk, and a 1-second quiet period. No shorter delay, larger window, refinement profile, or cached sharp-reference restore is shipped. Frame credit, cancellation, revision fences, and chunk receipts are unchanged.

The retained real-page tests check initial settling and autonomous caret transitions: 200 for documentation and 30 for each other page, with every decoded frame acknowledged. Each settled and caret frame must have maximum RGB error at most 8 and mean at most 1. These tests do not exercise input-triggered motion return, and no new qualification of that behavior is claimed.

`swift run -j 2 CanvasCoreTests --no-parallel --filter SurfaceFrameRasterTests` covers codec-aware capture fitting, including budget-capped and thin H.264 rasters without changing JPEG dimensions. `SurfaceVideoTests.budgetCappedCaptureRastersProduceVisibleSharpReferences` encodes and decodes the fitted rasters through the production codec. `EaslConnectionTests.aDelegatedReplyLargerThan32MiBArrivesWholeAndItsOriginStillPushes` sends a reply above 33 MiB through a real process connection and verifies the full answer and a subsequent event. The blocked-reader case separately requires aggregate output overflow to close the link.

`swift run -j 2 CanvasCoreTests --no-parallel --filter SurfaceVideoTests` covers visible encoded changes, continuing sharp prediction, keyframe recovery after cancellation and resize, malformed-packet rejection, and declared and odd dimensions.

The process relay fixture retains its reply pipe with `exec 3>&1` before redirecting `cat` into the captured-input file. Otherwise the redirect signals stdout EOF, and the client correctly retires that still-running relay after two seconds. Large-reply checks must keep the duplex link open while verifying its captured output.

`swift run -j 2 CanvasCoreTests --no-parallel --filter SurfaceVideoQuality` runs `SurfaceVideoQualityTests.realBrowserPagesRetainSharpReferenceThroughTwoHundredDocsCaretTransitions`. It checks initial settling and autonomous caret transitions, not input-triggered motion return. It requires the manifest and captured image pairs in `Tests/CanvasCoreTests/Fixtures/browser-quality`. Missing fixtures fail rather than skip. The manifest records source URLs, renderer and caret provenance, image hashes, and the required 1800×1324 raster for a 900×662 tile at scale 2.

All real-page cases pass through production capture fitting. A separate 1799×1323 docs viewport crops the captured source before encoding, then compares the complete decoded odd viewport against that source through 30 caret transitions. It enforces max RGB error 8 and mean 1 while requiring the original dimensions, so unconditional even resampling cannot pass.

The quality gate drives `SurfaceImageEncoder.capture` with real documentation, a GitHub file view, and a dense table. Each complete image is compared in canonical sRGB against its captured source, without masks, cropped evaluation regions, or alpha dilution. Maximum RGB channel error must be at most 8 and mean at most 1 for the settled frame and every subsequent caret transition. Documentation runs 200 transitions; the other pages run 30. Encoder-generated sharp IDRs are accepted, decoded and acknowledged under the same quality limits and sharp-frame transport bound; this gate does not prove periodic keyframe scheduling stays disabled. Saturated synthetic raster errors are reported separately without that quality gate. `SurfaceVideoTests.sharpSizeChangeDoesNotFallBackThroughTheMotionFrameCap` also requires a sharp size-change IDR above the ordinary 48 KiB cap to retain its profile and full dimensions. A passing codec test does not qualify native page capture or a focused caret. Parent-run native measurements and GUI checks supply that evidence.

The retained encoder sweep in `/home/tim/lane-evidence/easl/easl-relay-settle-1/codec-quality-summary.json` does not justify a quality change. Quality 0.95 reduced median sharp payload by only 2.38%, while quality 0.98 increased it by 12.946%. These headless codec results are not an end-to-end relay measurement or a new motion-return qualification. Production quality remains 1.

The Swift navigation fixture builds with `--build-system native --enable-index-store`, the same command the app recommends for user projects. Swift 6.4's SwiftBuild backend reports an index-store path different from the one it writes ([SwiftPM issue 10350](https://github.com/swiftlang/swift-package-manager/issues/10350)). The fixture uses the app's default SourceKit-LSP configuration and keeps the exact cross-file references assertion and its deadline. Neither the app nor the test creates an index-store symlink or enables background builds.

What the app and easld both compute is pinned by fixtures in `Tests/Fixtures/` that `CanvasCoreTests` and easld's `go test` both check, so the two can't drift: `terminal-env.json` (a hosted and an owned terminal's session variables), `agent-resume.json` (the command resuming a recorded agent session with the tile's own options, `AgentResume.argv` and `session.ResumeArgv`) and `agent-relaunch.json` (what `agent.restart` relaunches, resumed or fresh, with the recorded model and thinking level and the call's `args`, and the tile's command from then on: `AgentResume.relaunch` and `session.RelaunchOf`). Change a case there, then make both pass.

`scripts/test_host_lsp_lifetime.py` runs the host language launcher as a real subprocess on Linux and macOS. The link-death regression reads the `easl/hostProcess` PID notification before killing the input link, then checks that the server is reaped. It does not prove cleanup before PID delivery. Separate retained real-SSH proof holds that notification back, verifies that the viewer receives zero bytes, and kills the SSH link before checking the host process. Other script cases check byte-for-byte LSP forwarding and isolation from unrelated environment files. The scripts run through the Python discovery command above and need Bun, as the host launcher does.

### Browser response and sharp-settle gates

`scripts/perf-browser-gates.py` observes an existing counter-and-marker page in an isolated native viewer. Its module help documents the fixture and JSON config. Supply the viewer's exact PID, window, current stream, and measured viewport geometry. Use the same native input helper, route, page, and compiler for before and after, retaining source and bundle hashes.

Report two endpoints separately:

- **Gate A, first visible response:** native input timestamp to the display time of the first complete own-NSWindow SCStream frame whose marker passes max-channel RGB error 16, with exactly one independently checked source counter increment. Both timestamps use the same viewer guest's `mach_absolute_time` clock, converted to milliseconds with `mach_timebase_info`. Direct and relay use this same observer. Before input, the observer acknowledges an armed target more than 32 channel levels from its current native pixel. It retains the first matching frame as an immutable PNG with the original pixel, PID, exact window, dimensions, marker coordinates, geometry metadata and mach timing receipt. Inspect the native count image and supplemental Cua count crops. Cua completion times never supply Gate A, even if native observation fails.
  Keep the native endpoint separate from decoded assignment. A display at or after sharp assignment reports `late_marker`; a first-covering sharp assignment reports `first_covering_sharp`. A display before its covering assignment reports `ambiguous_marker`. Missing assignment, missing native observation, invalid mach timing and deadline failures do not enter successful percentiles.
- **Gate B, settled sharp:** the last queued input's same-viewer mach timestamp to the first `refresh:true` image assigned for exactly that input sequence on the same stream. This endpoint is report-only, including the 1.5-second median and 2.5-second p95 targets. A `DevInput.surface` trace separately reports the first input-covering decoded-and-assigned image and its format. JPEG and PNG have no idle refresh, so Gate B is not applicable for those modes. Neither assignment endpoint proves native presentation or the separate RGB quality gate.
  Resolve the no-refresh format only from an assignment matching the selected input watermark; a later input's JPEG cannot excuse an absent sharp image.

The relay landing gate uses first input-covering decoded-and-assigned latency, not Gate A's native display time. It requires p95 at most 450 ms and median at most 110% of the matched baseline, together with improved sharp settling. Report Gate A independently. The retained matched 60-per-arm 0.3.0 baseline measured decoded assignment at median 142.104 ms and p95 364.735 ms, and settled sharp assignment at median 3,206.593 ms and p95 5,554.611 ms. Production codec and refresh behavior are unchanged, so these are baseline observations, not a measured improvement.

The 400 ms, 64 KiB experiment failed the first-response gate at p95 496.617 ms. The single guest-local 60-click-per-arm comparison of a 400 ms input delay and the original one-chunk window selected JPEG on the unshaped fast link for every click. It measured no sharp settling and did not qualify the H.264 delay change. Decoded-assignment median rose from 25.713 ms to 29.552 ms, exceeding the 10% allowance. No performance change was adopted.

The 0.3.0 release's original 243 / 2,901 ms relay-click row came from strict RGB8 image completion, not first-visible response. Its 30-action mixed observer is not pure Gate B. Keep those historical observations separate from both assignment endpoints and the own-window SCStream observer.

Launch with `EASL_DEV_INPUT=1 EASL_DEV_SURFACE_TRACE=1`; `dev.sh` forwards both. Every `DevInput.surface` event declares `clock_domain=mach_absolute_time`, integer `ts_ticks` as a decimal string, `timebase_numer`, `timebase_denom`, and converted `ts_ms`. The events are `input.queued`, `input.sent`, and `image.assigned`; assignment includes the stream and input watermark. These traces contain no input payloads or pixels. Explicitly started `screen.*` observer events include sampled marker pixels and artifact paths. Both are disabled outside development input mode. Report input request counts and queue spans beside the gates. The helper posts mouse-down and mouse-up back to back, whereas a physically held click does not receive that batching benefit.

The observer requires macOS 14.4 or later and an SDK exposing [`SCShareableContent.currentProcess`](https://developer.apple.com/documentation/screencapturekit/scshareablecontent/getcurrentprocessshareablecontent(completionhandler:)); the app still supports macOS 14.0. Earlier systems return an explicit observer error. Capture is opt-in through `EASL_DEV_INPUT=1` and notification kind `surface-probe`. It enumerates only the current process and selects the supplied exact own `NSWindow`. It never requests Screen Recording permission or enumerates other apps. Audio, cursor and single-window shadows are disabled. Marker `x,y` are DevInput top-left content points. AppKit converts them to the full-window coordinate fraction, then `contentRect * scaleFactor` maps that fraction into actual BGRA buffer pixels. Receipts retain both the original rectangle and its pixel rectangle. No title or tab-bar offset enters native measurement. `content_top` remains only for supplemental Cua crops.

Control notifications use string fields `pid`, `kind=surface-probe`, `action=start|arm|stop`, `session`, `window`, and absolute existing `directory`. `start` also takes marker `x,y`. `arm` takes an unused filename-safe `sample` and target bytes `r,g,b`. Wait for `ready.json`, then the sample's `*-armed.json` before input. Read `*-observed.json` and `*-native.png` for the endpoint. `stop` ends capture and writes `stopped.json`. `error.json` fails the recording. Missing armed samples retain `*-missing.json`. The canonical runner owns this lifecycle, retains control-helper stdout, stage receipts and `native-events.json`, and checks that PNG dimensions and marker pixels match the original receipt.

For a nonmutating content-readiness sample, add `captureReady=1` to `start`, or call `Observer.start(capture_ready=True)`. The initial complete native frame is retained as `ready-frame.png`, and `ready.json` includes its path. No input, toolbar toggle, focus change, or canvas mutation is needed. Normal gate observations do not write this extra image. Its display time is a sampled readiness upper bound, not an exact first-paint timestamp.

`SCStreamFrameInfo.displayTime` is mach absolute ticks, not epoch nanoseconds. With timebase numerator N and denominator Q, display tick D has `display_ms = D * N / Q / 1e6`. Native receipts retain `display_ticks`, `receipt_ticks`, `arm_ticks` for observed samples, `display_ms`, and the recording's `origin_clock` and frame `clock` snapshots. Each snapshot declares its domain, numerator, denominator and consecutive mach reads `a_ticks`, `b_ticks`. The timebase must remain positive and unchanged. Snapshot reads must be ordered, must not precede the previous snapshot, and must span at most 2 ms. Complete frames require nondecreasing positive display ticks no later than receipt, with receipt no later than the frame snapshot. A matched display must follow its arm ticks and must not precede input. Geometry, BGRA format, marker tolerance and immutable first-match retention remain required. The stop snapshot checks the recording through shutdown. Any native session failure invalidates earlier Gate A rows without invalidating independent Gate B endpoints.

The timed helper prints only the mach-millisecond number sampled immediately before posting `canvas.dev.input`. The harness brackets helper execution with its own absolute mach reads and rejects nonfinite or out-of-bracket helper timestamps. It binds `/usr/lib/libSystem.B.dylib` through `ctypes`, reads `mach_timebase_info` once and calls `mach_absolute_time` directly for timing and deadlines. Python 3.9's `time.monotonic_ns()` can have a process-local origin on macOS and is not interchangeable with Swift mach timestamps. No Python-version fallback, wall-clock bridge or epoch-format input is accepted. The metadata, raw helper stdout, launch/read bracket, original native receipts and PNG hashes identify the clock and retained evidence. Compare durations only within one guest; never subtract source-guest timestamps from viewer-guest timestamps.

An uninstrumented baseline needs the complete development-only observation support, not only new timestamp fields. Add `DevSurfaceObservation.swift`, the `DevInput` trace flag, mach timebase, `traceSurface` function, and `surface-probe` dispatch. Port the exact-own-window replay selection without replacing unrelated baseline input APIs. Add the three `RemoteBrowserTile` trace calls at image assignment, input queueing, and batch sending, and forward `EASL_DEV_SURFACE_TRACE` in `dev.sh`. Preserve the baseline's codec, refresh behavior, and existing replay operations. Use the same observer source and timed helper for both arms, rebuild both instrumented artifacts, and record source and bundle hashes. The harness requires the mach clock fields and rejects epoch-based receipts.

Qualification requires 60 clicks per arm in interleaved blocks in one session, retaining unique before, intermediate, and settled PNGs, native capture receipts, trace records, and exact helper stdout. Wait for sharp assignment or the declared deadline before the next click. Keep failures and uncompleted rows in the denominator and label completed-subset percentiles. Missing, censored, clock-invalid, and three-sample smoke results do not qualify an arm. Record RTT without bulk-transfer probes during timed clicks. Qualify settled real-page RGB error separately and measure static, ticker, and actually focused native-caret wire traffic after settling. The bounded run permits one guest-local 60-per-arm series for the 400 ms input-only candidate against 0.3.0. If it fails the landing gate, production behavior remains unchanged and only the observer documentation and quality finding apply.
An aborted series retains all requested samples in each gate's denominator, with unattempted samples reported separately as `not_attempted`.

### Remote terminal echo

Run `scripts/terminal-echo/` only inside a claimed GUI guest, against a guest-local scratch easld. The fixture sends native `keyDown` events through the app queue. Do not substitute `input text`: direct text insertion bypasses the local event monitor. `UserIdleWatch` combines the session's HID-idle sample with elapsed time since native app input.

The coordinator accepted the measured good-link native echo of 79 ms median and 97 ms p95 as meeting the intent of about RTT plus a display-link frame. The complete qualification used five interleaved pairs of 100 keys per profile and input mode. The earlier 356 ms baseline measured `DevInput` text replay, not native key handling. Do not use that baseline to claim a native-key speedup or continue frame-path optimization for this result.

Keep OpenSSH's default `ObscureKeystrokeTiming` protection. Do not disable it or shorten its packet interval to improve echo measurements. A fixture-only diagnostic saved about 11 to 12 ms before the host PTY with protection off, but the coordinator rejected that privacy tradeoff. This decision closes that optimization path.

Keep terminal SSH compression enabled. The same-boot A/B showed no interactive echo harm, while exact `seq 1 20000` receipt was 34% faster on the good profile and 47% faster on the poor profile. Preserve the measured child's effective SSH options and negotiated compression when reproducing the result.

Copy the tools into a fresh scratch directory and retain every binary until the session ends. Give the directory a `repo` symlink to the claimed checkout. Provide an authenticated loopback alias named `easl-guest` in `ssh_config`, with strict host-key checking and connection sharing disabled. Provide `ssh`, a wrapper for `/usr/bin/ssh -F <scratch>/ssh_config`, for link calibration. Keep credentials outside the fixture.

Build `easld` with `go -C "$G/repo/easld" build -p 2 -o "$G/easld" ./cmd/easld`, copy zmx 0.8.1 into the scratch directory as `zmx`, and build the tracer and native input helper there:

```sh
clang -arch arm64 -std=c11 -O2 -Wall -Wextra -Werror -dynamiclib "$G/pty-trace.c" -o "$G/host-pty-trace.dylib"
codesign --force --sign - "$G/zmx"
codesign --force --sign - "$G/host-pty-trace.dylib"
swiftc -O "$G/timed-input.swift" -o "$G/timed-input"
chmod 700 "$G/ssh-observed" "$G/zmx-launch"
python3 "$G/pty-trace-smoke.py" --zmx "$G/zmx" --library "$G/host-pty-trace.dylib" --output-root "$G"
python3 "$G/pty-trace-smoke.py" --zmx "$G/zmx" --library "$G/host-pty-trace.dylib" --output-root "$G" --spacing-ms 150
```

Require both tracer smokes to pass. They exercise actual PTY master reads and writes, including split output markers. Run `$G/easld --home "$G/host" --own-terminals --zmx "$G/zmx-launch"` in an owned process. Freeze release bundles as `before.app` and `after.app`, with the same development observation support. Use `run-echo.py seed`, then `run-echo.py launch --artifact <bundle> --home <home>`, with `$G` after the action. Each home belongs to one immutable bundle. `run-echo.py stop` checks the recorded PID against its instance lock before stopping it.

`measure-matrix.py "$G" --prefix <unique-name> --home <running-home> --compare-home <other-home> --compressions yes --kinds space burst --repeats 5` alternates the frozen artifacts in the same boot. Launch each home once before the matrix and leave only `--home` running. Without `--compare-home`, the matrix compares compression settings in one artifact. Defaults cover both profiles, both compression settings, 100 keys at 150 ms, 100 keys at 5 ms, and a real `seq 1 20000` burst.

`<prefix>/plan.json` records the matrix PID and every requested cohort before work starts. Failed and unattempted cohorts retain their expected key counts. To yield a guest, create `<prefix>/stop`: the current cohort finishes, shaping is cleared, and the matrix exits 130 with the remaining cohorts marked `not_attempted`. Do not qualify that stopped matrix as a complete run.

The good profile caps each direction at 10 Mbit/s and adds 17 and 18 ms. The poor profile caps each direction at 1 Mbit/s, adds 40 ms each way, and drops 1% each way. Shaping applies only to IPv4 loopback SSH. The matrix records calibration separately, tears down its PF anchor and pipes in `finally`, releases its PF reference, and restores the loopback MTU. Retain the teardown receipt and check the live guest state before releasing the claim.

Cleanup attempts every owned resource after an error and retains only unresolved resources for retry. A missing pipe is accepted only after `dnctl list` proves it absent. New SSH observers retain effective options and the compression negotiated by the actual measured child connection, separate from startup calibration.

Each cohort retains native key handling, SSH-input acceptance, actual host PTY write and output-read returns, viewer SSH-output receipt, first observed Ghostty text, and native first-glyph display timestamps. All use one guest's `mach_absolute_time` domain. `surface.updated` is a text observation sampled on a requested 2 ms timer, not an IO-thread callback. Native display metadata supplies the latency endpoint; capture receipt and its measured delay remain separate. A separate Cua capture checks the completed glyph grid.

Absolute latency includes the text sampler and byte-tracing overhead. Only capture delivery delay is removed by using native display timestamps. Capture stop waits for startup, removes the stream output even after a stop error, and publishes `stopped.json` after the final trace write. The driver waits for both `complete.json` and `surface-complete.json`, then for the stop receipt; it does not rely on a fixed drain sleep.

The driver records `observe-requested.json` before starting capture. Cleanup waits for a stop receipt only when capture was requested, so a preparation failure cannot be replaced by a timeout waiting for a nonexistent observer.

`analyze-echo.py <cohort> --database <sqlite>` requires every expected stage, unique glyphs, matching host counts, actual byte-read coverage, and causal timestamps. It matches SSH reads and input to one marker-producing observer, rather than borrowing offsets or bulk bytes from another session. It preserves failed cohorts and exits nonzero instead of qualifying completed subsets. A marker split across reads uses the read containing the glyph, not the later marker terminator. The analyzer also requires the exact 20,000-line byte sequence for a bulk arm. Trace payloads and captures are fixture-only; never attach these observers to a real terminal session.

### Remote host-file throughput

`HostFileReadsTests`, `HostFilesTests`, `HostFileRangeTests`, `HostHTTPTests`, `HostGitTests`, and `HostMasterTests` exercise real host programs and SSH subprocess fixtures. They cover binary member ordering, independent refusals, batch-budget deferral, changing files, selected byte ranges, shared-command cancellation, priority/FIFO admission, lease bounds, and cancellation isolation.

`HostBrowserSnapshotsTests` uses real process links to a Unix-socket peer to check the two-link bound, priority ordering, independent active cancellation, and queued cancellation and deadlines.

`HostImagePreviewTests` and the image-preview API tests cover explicit original selection, aspect ratio, alpha, descriptor versions, refusal, and connection lifetime. Easld's image-preview tests also retain color-tagged originals and reject malformed raster data. The `image-preview` and `image-preview-raster` scenarios run through both hosts; encoder bytes and filesystem stamps are not cross-host golden values.

For a real-link comparison, launch an isolated development viewer with `EASL_DEV_HOST_READ_TRACE=1`. Each `host-read` line reports admission wait (`queueMs`), master setup (`setupMs`), command time (`channelMs`), request/reply bytes, member count, priority (`0` background, `1` visible, `2` interactive), status, and timeout state. `scripts/dev.sh` forwards this setting and `EASL_DEV_HOST_FILE_CONCURRENCY` through its launcher. The concurrency override accepts 1–6 and is for experiments, not a second production setting.

The same trace flag enables `host-image-preview` records: object, priority, requested pixels, encoded dimensions, PNG payload bytes, queue wait, and whole-request duration. An explicit original selection has zero encoded dimensions and payload bytes. These are application payload counts, not measured TCP wire bytes. Compare visible opens and full-board draws separately; do not credit skipped offscreen work as a fully drawn board. Exercise full-detail zoom and offscreen path changes as separate controls.

Compare limits 1, 2, 4, and 6 in at least five interleaved runs on the same guest and route. Use host-backed HTML fetches that exercise individual range reads, checking every file's hash and decoded image; native images alone also measure batching. Then time 30 opens of the 50-image board, from `board.open_remote` to native captured pixels for all 50 images, not object counts. Keep incomplete opens and errors in the report. Measure route RTT and checked bulk transfers in both directions separately from cold SSH setup, and retain the before and after logs from the same session.

For native video, keep AVPlayer's default buffering. Exercise the actual tile with a silent clip whose encoded rate exceeds the measured link, delaying a middle range to empty its buffer. Require newly decoded frames beyond that range, not `isPlaybackBufferEmpty == false`: that flag can remain true while frames advance. Compare the same artifact with automatic waiting disabled, and retain all outcomes. Also pause, park and restore the tile, seek while paused, then resume and seek while playing. Check an audio-bearing clip locally and remotely; a virtual guest's CoreAudio hang needs a physical Mac audio-device control, not an SSH retry.

### Whole-board browser render regression

Use two isolated Mac viewers of one scratch easld board. Assign browser pages to both drawing identities. Put distinct text and colors in each page. Leave at least two browsers unseen by the composing viewer, with two browser frames overlapping. Keep one browser streaming as a control.

Call `view.render` on the host with the board ID, a target list containing all browser IDs and a note ID, `inline:true`, `scale:0.4`, and `timeoutMs:30000`. Decode the returned PNG and inspect each browser's distinct page content. Require each loaded browser's object record to report `rendered`, including the unseen browsers. Check that the body has one browser address bar, not a duplicated tile title bar. Repeat with content zoom other than 1 and fractional object positions.

Include host scripts that fetch JSON during initialization and from a window `load` handler, plus a host-private iframe. Inspect the PNG for the completed chart values and iframe content, not just `rendered` records. Delay the response past the kit's normal settling interval. Check `Response` cloning, JSON/text/array-buffer/blob/form-data readers, used-body errors, and aborted fetches retain their ordinary results and errors. Continuous polling and an unconsumed, non-ending response body must not prevent a render.

Repeat with a rectangle covering those tiles. The overlapping pages must not trigger repeated nested compositions. Inspect connection and surface-stream evidence before and after. Captures must not open new streams or leave snapshot links behind. The composing viewer's viewport and existing live stream must stay unchanged.

Use a page whose response stays pending, then repeat with a short `timeoutMs`. Require a bounded placeholder rather than a successful stale frame. Cancel a running render in the viewer and check that its snapshot connections close. Move a pending browser to the other drawing identity, then disconnect its drawing viewer. Neither case may return the former drawing's retained frame as a fresh render. These checks need the real app because the existing Swift behavior target imports `CanvasCore`, not `CanvasApp`.

## Rotating an omp lead

`scripts/rotate-lead.ts` runs one guarded fresh restart and one out-of-band handoff through the existing easl CLI. It is a finite developer tool, not a scheduler:

```sh
bun scripts/rotate-lead.ts --target <tile|name@board> --file <handoff.txt> --out <evidence.json>
```

`--text <handoff>` replaces `--file`. `--easl <executable>` selects the CLI (default `easl` on PATH); `EASL_SOCKET` still selects its server. `--timeoutMs <ms>` bounds the whole operation (default 30 minutes). Before restarting, the controller reserves 300 seconds: 30 for restart, 120 for startup, 30 for tell and 120 for delivery. The boundary wait gets only the time outside that reserve; a late boundary or a timeout too short to leave the reserve fails with `restart.status: "not-started"`, without restarting.

Run the controller from a separate terminal or a known broker-owned process outside the target's zmx process tree: `agent.restart` kills that session and everything it started, so merely backgrounding a command inside the target's shell does not make it survive.

The controller waits for the old agent's natural `idle` or `done` boundary, records its native identity, and calls `agent.restart --mode fresh` without force or retries. Every server restart guard still applies, including pending prompts or messages, drafts (known or unknown), focus, working or blocked agents, concurrent restarts and pastes, and the checks immediately before the kill.

Startup is proved by a different native session and PID, a live local session, kind `omp`, protocol ≥ 1, a fresh report of no draft, and the same reported model and thinking selector. The returned restart command must also carry the exact recorded `--model` and `--thinking` selectors. A retained `done` with `seen: false` is accepted; the controller never clears that unread answer or waits only for `idle`. It rechecks identity and no draft before handing off to the pinned tile id. `tell` runs as an external script labelled `lead-rotation`, without inherited caller/board identity, and carries one stable message id.

Evidence separates `restart.status: "ready"` from `handoff.status: "queued"` and `"acknowledged"`. Queueing alone cannot set `pass: true`: the controller waits through the public `agent.wait` seam, which cannot answer while a message is queued or held, then checks the same live native identity again. A user draft after delivery does not invalidate that acknowledgment. An acknowledgment that starts a turn must also reach its first working or blocked report. This proves the handoff was recorded, **not that its requested work finished**; a working recipient is a successful delivery. Restart, tell, acknowledgment and identity failures remain `pass: false`.

The behavior test drives the controller CLI against a separate stateful easl executable: reserved handoff time, successful restart, inherited/stale identity, delayed native identity with retained done, exactly one handoff, rejected restart/tell, missing acknowledgment, session changes, unrelated saved entries, a hung CLI, rejected output reads and SIGTERM. The controller creates no scratch or persistent process; its deadline and SIGINT/SIGTERM handling kill its owned CLI child. Tests create their `mkdtemp` directories in the operating system's temporary directory (`$TMPDIR` on macOS) and remove them and their owned children afterward.

## API conformance

`conformance/` drives the socket API the way agents do. App-recorded scenarios check that `easld` preserves the app's behavior. Scripted-client scenarios check easld's attachment and forwarding protocol separately from the real Mac viewer's drawing.

```sh
scripts/dev.sh start                                       # or any server: EASL_SOCKET=… / --socket
go run ./conformance/cmd/easl-conformance replay --socket .easl-home/easl.sock            # every scenario
go run ./conformance/cmd/easl-conformance replay --socket … --json out.json tray agents   # some, plus a JSON report (flags before scenario names)
go run ./conformance/cmd/easl-conformance record --socket … --on "easl main <sha>, dev instance" [scenario…]
```

- `conformance/scenarios/<name>.json` is one conversation on a board of its own: the runner makes a fresh directory (with `files`, and with `git: true` a repository whose one commit has fixed dates, so its id never changes), opens it with `board.open`, subscribes to its events, and runs the steps. A step is a `call` with `params` (templates: `{{board}}`, `{{root}}`, `{{name.path}}` from a step saved as `name`), on a named `conn` (each its own connection), optionally `async` and `await`ed later; or a `raw` line, `readFile`, `writeFile`, `sleepMs`. Terminal tiles run `/bin/cat` far off screen and are deleted at the end, on every board the scenario opened.
- `conformance/fixtures/<name>.json` is the transcript: each step's request, response and the events every subscribed connection received until it went quiet (`--settle`, default 120 ms; `settleMs` for steps that set off a slower write-back). An event on a connection that never subscribed fails its step (the transport sends events only after `events.subscribe`), and `record` refuses a run that has one. Ids become `<obj:1>`… (the prefix before `_`) by first appearance: an id is a value of an id field (every property the schema types `Id`, and the untyped `from`/`to` of an object's graph, `encloses`, `enclosedBy`, `follow`, `raisedBy`) or a key of `frames`, whatever made it, and once known it is replaced in any text (summaries, messages, refs). Revisions become `<rev:n>`/`<board:n>` by value (equal stays equal). Times keep their wire type: `<time:number>` (the API's dates, seconds since 2001, which schema/easl-api.json calls date-time strings: the fixtures record what the app sends) or `<time:iso>` (activity entries, board files); a value under a time key that isn't a moment between 2020 and now stays as it is, so it fails. The scenario directory becomes `<root>`, the home `~`, pids `<pid>`. Everything else is compared exactly, error messages included, and so is a key's presence: an explicit `null` and an absent key differ. A value the server can't know today (where a placement lands in the user's view, the foreground program of a terminal) is left out of the comparison (value and presence) through the scenario's or step's `ignore`, which says why; a step's `mask` leaves out only part of a string (the matches of `match` become `as`, the rest is still compared: a placement's coordinates in a history summary). Arrays a server lists in no particular order are compared sorted (`unordered`).
- A step whose result is the server's own measurements (`app.metrics`) says so with `shape` (the reason): instead of being compared, its result is checked against the method's result schema in schema/easl-api.json (`$ref`, `type`, `enum`, `const`, `required`, closed `properties`, `additionalProperties`, `items`, `oneOf`/`anyOf`; bounds, formats and patterns aren't checked), and the transcript keeps the verdict: `<fits the result schema>`, or where it doesn't.
- `replay` prints a table per scenario, per method and per method family, the client-delegated methods (`conformance/delegated.json`: view.get, view.render, view.snapshot, agent.prompt, agent.restart (its refusals are the server's and replayed by agent-control, and an owned terminal's restart is easld's own, replayed by agent-control-owned), agent.read's live-terminal modes (its `final` mode is the server's and replayed), object.reload, text.measure, which a Mac client serves), any schema method that is neither exercised nor delegated, and the diffs; it exits 1 unless everything passes.
- Scripted clients: a step's `replies` makes its connection a client (`client.attach` with `{{schemaVersion}}` and `{{schemaHash}}`, read from the schema) that answers the requests the server sends it, by method in order (`result`, `error`, `silent` to let the deadline pass, `hangUp` to close instead); the fixture records each step's `forwarded` requests. `client-delegation` replays every delegated method this way, `client-versions` clients on other schema versions and hashes, and `client-failures` the choice among several clients, a missed deadline and a hang-up mid-call. `viewer-serve` checks HTML measure and fit, inline render delivery and daemon-side files, reload refusals, and `client.list`. `no-client` replays easld with none attached: each delegated method's `unavailable`, and what measures text marked `approximate`. These protocol scenarios are recorded against easld; their `recordedOn` identifies the build, not a Mac rendering run. Record them on a fresh easld: it keeps the exact arrow label sizes clients gave it for as long as it runs, so an arrow label a scripted client measures names `{{board}}`, which is new on every run.
- Owned terminals: `owned-terminals` and `agent-control-owned` replay easld `--own-terminals` (docs/contracts.md "Owned terminals") with a zmx that keeps its sessions as files and runs none (`zmxtest.Script` in `easld/internal/session/zmxtest`, written to a file and passed as `--zmx`; every session's pid 4242424, which no process has): sessions started and ended with their terminals, labelled, none for a failed batch, another home's left alone; `agent.list`'s `live`, and `agent.restart` going through with no client (the kill, the queued message bounced, the relaunch's session and the tile's new command). They are recorded against easld that way (the app answers `session.*` `unsupported`, and restarts through its own tiles). `go test ./cmd/easld` replays them against an easld in that mode (its `owning` list) and every other scenario against one in its default mode (no zmx, no ownership: an easld on a Mac, where the app runs its terminals).
- Session ownership after a board merge: `Tests/Fixtures/hosted-ownership.json` is the one ownership case table checked by `HostedTerminalTests.theHostSideKeepsAMergedBoardsSession`, `RemoteHostTests.remoteAttachChecksEveryOwnershipLabelAgainstTheDiscoveredHome`, and easld's `TestSessionSpawnKeepsAMergedBoardsSession`. Both Swift attaches execute the shared ownership script through `/bin/sh` against `Tests/Fixtures/hosted-zmx.sh`; the Go test drives the real router against the same stand-in. Separate tests cover malformed merged IDs and a copied tile that holds its refusal notice without attaching.
- Text measurement with no client attached comes from `easld/internal/measure/glyphs/glyphs.json`, the advance widths of the fonts easl draws text in. After a font or text style change, regenerate it on a Mac: `swift scripts/glyph-widths.swift > easld/internal/measure/glyphs/glyphs.json`. The app-recorded `measure-notes` scenario doesn't pass against easld alone: its sizes are within a few points and marked `approximate: true`.
- Recording: run `record` against a fresh `scripts/dev.sh` instance of the commit you mean (`--on` says which), then `replay` against it twice: both must pass, or a step depends on timing. Re-record after an intended API change and review the fixture diff like code.
- Against easld: `go run ./easld/cmd/easld --home /tmp/easld-home --socket /tmp/easld.sock &`, then `replay --socket /tmp/easld.sock` (kill it afterwards; SIGINT, SIGTERM and SIGHUP save its pending board changes). Give it a home of its own: it refuses one the app (or another easld) holds, naming the holder's pid, and a socket another server answers on. `go test ./cmd/easld` in `easld/` does the same in-process and fails when a scenario in its `passing` list stops passing, or names no scenario.

## GUI proof in the macOS guest

On `twaldin-home`, run every development or test GUI step inside `agent-gui`, including launch, input, and window captures. Never launch a development bundle on the host display, hidden or visible. Do not touch `/Applications/easl.app` on the host. Headless host builds and core tests remain allowed.

Easl lanes use `/home/tim/agents/projects/easl/state/efforts/gui-guest/recipe.md` for the tested claim, guest setup, proof, export, and cleanup commands. If that recipe is absent, GUI proof is not ready. Do not substitute a host launch.
Use the project-local [verify-easl skill](../.agents/skills/verify-easl/SKILL.md) for guest launch, ownership checks, native feature journeys, retained evidence, and cleanup.

The guest needs macOS 14 or later, Command Line Tools, git, Python, Go, Bun 1.4.3 or later, and zmx 0.8.1. Use a login shell so Homebrew's tools are on `PATH`. Cap Swift builds and bundling at two jobs. Use a separate `EASL_DEV_HOME` and scratch easld home for each lane.

In `agent-gui`, use the already-authorized CuaDriver with both the dev process PID and its window ID, as the recipe shows. Capture before and after a visible change, then inspect both PNGs for changed terminal output and advancing HTML or browser content. A new file or in-process `view.snapshot` is not GUI proof. Do not pursue a native SSH Screen Recording grant.

## Native remote video regression

Run this check in a claimed GUI guest against a scratch remote board. Use an isolated app home for each audio case so a hung audio pipeline does not invalidate the next control.

1. Put an unchanged audio-bearing MP4 at `original.mp4` in the scratch board. Record its hash and track metadata on the host. Create a silent stream copy on the host, not the viewer.

   ```sh
	sha256sum original.mp4
	ffprobe -v error -show_streams -show_format -of json original.mp4
	ffmpeg -i original.mp4 -map 0:v:0 -c:v copy -an silent.mp4
   ```

2. Set `EASL_SOCKET` to the scratch daemon and `BOARD` to its board ID. Create a native silent tile and retain its returned object ID as `VIDEO`.

   ```sh
	easl object.create --board "$BOARD" --type video --json '{"props":{"path":"silent.mp4","muted":true,"autoplay":true,"startTime":20},"frame":{"x":0,"y":0,"w":300,"h":540}}'
	easl object.update --id "$VIDEO" --json '{"props":{"startTime":10,"autoplay":false}}'
	easl object.update --id "$VIDEO" --json '{"props":{"autoplay":true}}'
   ```

3. Capture native frames before and after playback. Read the native timeline through accessibility to prove that time advances. Pause, seek backward and forward through both the API and native controls, and verify the requested position before resuming. A spinner disappearing or `object.get` returning new props does not prove playback or seeking.
4. Repeat with `original.mp4`, first muted and then unmuted. Repeat both files in a guest-local board from byte-identical copies. Keep an HTML `<video controls>` tile for each file as a separate decoder and transport control. HTML success does not qualify native AVKit playback.
5. Seek during an outstanding remote read, park and reopen the tile, and close the remote board during playback. Verify responsive input, preserved position on reopen, and the cached presentation after closure. Check that no video payload was staged on the viewer's disk.
6. If the audio case hangs, retain its native PID, window ID, capture receipt, and these guest diagnostics.

   ```sh
	sample "$PID" 5 -file native-video-sample.txt
	system_profiler SPAudioDataType -json
   ```

Record the candidate commit, guest macOS version, file hashes, route, muted state, and timeline values with every result. A main-thread `currentMediaSelection` wait plus an `AQServer` CoreAudio HAL wait identifies the observed stack, not a product-code cause. Classify the hang as guest-only only after the same candidate and unchanged audio file pass native local and remote controls on a separate physical Mac. If that control is unavailable, leave guest-only attribution unproven. Never launch the development app on `twaldin-home`'s display for this control.

## A development instance

`scripts/dev.sh` runs one isolated development instance per checkout. Run the commands below in the guest when using `twaldin-home`.

```sh
scripts/dev.sh start [root]      # build, bundle, launch without activating (no root: the home's previous tabs)
scripts/dev.sh cli board.get     # the easl CLI against this instance (sets EASL_SOCKET)
scripts/dev.sh snapshot out.png  # view.snapshot: what agents see (not verification)
scripts/dev.sh input click 400 300 --mods hyper
scripts/dev.sh restart           # rebuild + relaunch with the same tabs; terminal sessions keep running
scripts/dev.sh stop              # quit and kill this instance's terminal sessions
```

A development home isolates its boards, API sockets, and zmx state. Explicit `EASL_DEV_HOME` instances also get separate browser profiles. Both dev launchers persist `ZMX_DIR=<home>/zmx`, `XDG_STATE_HOME=<home>/state`, and `TMPDIR=<home>/tmp` in the copied bundle, so plain macOS relaunches keep the same isolation. zmx 0.8.1 puts session sockets in `ZMX_DIR` and logs in `ZMX_DIR/logs`; terminal attachment and housekeeping use those paths too. The launchers and app refuse paths that escape the home or overlap installed easl or zmx state, including symlinks. `scripts/dev.sh zmx-env zmx version` prints the selected socket and log directories without launching the app.

Use a short home such as `/tmp/easl-dev-a`. macOS zmx permits 103 socket-path bytes; a generated terminal name leaves at most 69 UTF-8 bytes for the development home. Longer homes are refused before launch rather than creating detached terminal tiles.

What it sets up:

- `EASL_HOME=<checkout>/.easl-home` holds this instance's socket, boards, pid, and `app.log`, so it never touches the installed app's boards or another instance's.
- `EASL_NO_ACTIVATE=1` makes the app refuse activation (`CanvasApplication`). The launcher uses `open -g -n` without window rules or moves.
- Boards open as tabs of one window, and `open-boards.json` in the home reopens them at launch. The initial root (`dev.sh start <root>`) is the selected tab; without a root, `start` and `restart` reopen the tabs the home had open (the first one selected), or the checkout's board in a fresh home. A board opened while the window is minimized joins it as a hidden tab; under `EASL_NO_ACTIVATE`, `--select true` doesn't bring the window back.
- `EASL_DEV_INPUT=1` enables input replay (below).
- A fresh home is a first launch: Help › Get Started opens with its practice note until it's closed. For captures and studies that shouldn't show it, write `{"dismissed":true}` to `<home>/get-started.json` before `start`; a home that already has boards never shows it by itself.
- More instances of one checkout (parallel agents, user studies): `EASL_DEV_HOME=/tmp/study-a/home` gives an instance its own home (socket, boards, log, pid, zmx session label, so `stop` kills only its sessions, and browser profile), and `EASL_DEV_APP=<bundle>` launches a prebuilt bundle without rebuilding: assemble one with `EASL_BUNDLE_APP=/tmp/study-a/easl.app scripts/bundle.sh` and every instance runs that frozen build while the checkout changes (bundling deletes and rebuilds its target).
- Development bundles: an instance never runs from the bundle it was built as. `scripts/dev-bundle.sh` copies it (an APFS clone) to `<home>/easl.app` and stamps the copy's Info.plist: `LSEnvironment` with the instance's environment (`EASL_HOME`, `EASL_ROOT`, `EASL_NO_ACTIVATE`, `EASL_DEV_INPUT`, `EASL_DEV_PERF`, `EASL_BROWSER_PROFILE`, `XDG_CONFIG_HOME` when set), so when macOS relaunches it (logging back in reopens the apps that were running, or the Dock, Finder, a plain `open`) it comes back on its own home and last root instead of starting on the default home beside the user's live app; `CFBundleIdentifier` `net.waldin.easl.dev.<hash of the home>` for an `EASL_DEV_HOME` (its own user defaults, saved state and TCC identity), while the checkout's `.easl-home` keeps `net.waldin.easl` and with it its browser logins and window frames; and `NSQuitAlwaysKeepsWindows` false. The copy is signed again ad hoc (keeping the source's entitlements and hardened runtime) and registered with LaunchServices; the source bundle, a release build included, is never changed. An instance started before this runs from its source bundle until its next `start` or `restart`.
- Legacy migration rehearsal: `LegacyMigration` runs only on the default home, so to watch it on a real bundle give a throwaway home laid out like a user's: put an older install under `/tmp/up/home` (the support directory, dot directory and preferences plist of a name in `LegacyMigration.earlier`), make a development bundle with `scripts/dev-bundle.sh <app> /tmp/up/bundle HOME=/tmp/up/home "EASL_HOME=/tmp/up/home/Library/Application Support/Easl" EASL_BROWSER_PROFILE=own EASL_NO_ACTIVATE=1` and `open -g -n` it. With `HOME` not the user's own and `EASL_HOME` its default support directory, the launch migrates that home, reading and writing its `Library/Preferences` plists directly (`PreferenceFiles`: `UserDefaults` ignores `HOME`), and logs each step as `easl (rehearsal on <home>): …`. Keep the bundle outside the home: the migration may move the support directory aside.

Browser tests: `EASL_DEV_DOWNLOADS=<folder>` (passed through by `dev.sh`) saves browser downloads there instead of ~/Downloads, and `EASL_DEV_EXTERNAL_OPEN=log` makes links handed to the default browser or another app (⌥-click, `mailto:`) only log `easl: … → <app>` in `app.log`, so a test never opens a window in the user's browser. A page's open panel runs out of process, where no replayed click or key reaches: `input panel <path>` chooses the file.

To replay input in Settings or a specific board window, add `--window <id>` to `input click`, `input key`, `input shortcut`, or `input text`. The ID must belong to that instance's PID. Without this option, replay still targets the frontmost board. A stale window ID drops the input rather than sending it to another window. Keyboard actions follow the selected window's responder chain, including while another window has focus.

Run `scripts/dev.sh stop` when the test is done, not at the end of the session: it also kills the instance's zmx sessions.

### Mixed drawing and tile stacking

Build the native app objects, then run the AppKit regression on an isolated GUI test machine:

```sh
swift build --build-system native -j 2 --product Easl
python3 Tests/SceneStacking/run.py --bin-path "$(swift build --build-system native --show-bin-path)"
```

The runner uses disposable homes and links the prebuilt `CanvasApp`. It checks actual `view.render` pixels and object order in normal and full-content modes, snapshot metadata, native hit testing, both stacking commands, arrow and ink transitions, and unfilled-interior pass-through. It never rebuilds the app. This is not WindowServer proof. Capture the real overlapping note and rectangle locally and in both remote viewers before and after restacking.

### Move tool input isolation

Use an isolated guest instance with a terminal and a second tile. Press M with the canvas holding the keyboard. Drag the terminal by its live body. Require a changed tile frame, unchanged terminal input, and keyboard focus on the canvas.

Shift-click the second tile and drag either body. One ⌘Z must restore both frames. Escape during a held drag must restore the preview without committing it. After release, Select must be active. With Move on, scroll over each body and require board pan rather than content scroll.

Check hidden-terminal focus separately. Focus the terminal in Select, then pan it far enough offscreen to become a card. Press M and pan it back into view. The terminal must not regain the keyboard. Escape must return to Select without sending a byte to the terminal.

Repeat the body, multi-selection, group, and undo cases on a guest-local scratch host with a second viewer. Read committed frames from the host and capture both viewers by exact PID and window ID.


### Seeing the window

Verify what the screen shows with real pixels: the window itself, or `scripts/dev.sh shot` (with yabai; see "Optional: a machine shared with other agents"), a WindowServer capture of the window. `shot` captures by window id, including on an unviewed Space, without moving or activating the window. Confirm that changed content appears in the capture; hidden surfaces can throttle their rendering.

`view.snapshot` (`scripts/dev.sh snapshot`) is the agents' view, not verification: it redraws the window in-process and substitutes stand-ins for content drawn outside AppKit (code tiles render their text themselves, terminals are drawn from zmx session text, web views show cached images). It hides compositor and layer bugs by construction: on a large dogfood board, code tiles that were blank or smeared on screen looked perfect in `view.snapshot`.

Shots use the display's backing scale. On a 2× Retina display, divide pixel coordinates by 2 for window-content points. Subtract the 28 pt title bar, or 64 pt once a second board adds a tab bar. `shot` includes the window frame, while `snapshot` doesn't.

### Input replay

`scripts/dev.sh input` sends events into the instance's own event queue, so the Hyper monitor, hit testing, and responders run as they do for real input. It posts no system input events. On a shared Mac, never use real mouse or keyboard events, which could reach the user's apps or activate easl.

```sh
scripts/dev.sh input click <x> <y> [--mods hyper|cmd|shift|opt|ctrl[+…]] [--clicks 2]
scripts/dev.sh input drag <x> <y> <toX> <toY> [--mods …] [--hold] [--middle]   # --hold keeps the button down: shoot mid-drag, then
scripts/dev.sh input release <x> <y> [--middle]     # end the held drag; --middle: with the middle button
scripts/dev.sh input rightclick <x> <y>             # opens the context menu on screen
scripts/dev.sh input menu <x> <y> "Content Zoom/150%"   # performs that context-menu item without opening the menu (over code: "Find References", "Outline"; "//" is a slash in a title: "Review Changes/Branch vs origin//main")
scripts/dev.sh input mainmenu "Edit/Send Mentions To/codex"   # performs that menu-bar item (menus AppKit fills as they open are filled first)
scripts/dev.sh input flags <x> <y> --mods hyper     # hold Hyper over x,y (hover outline); omit --mods to release
scripts/dev.sh input close <window id>              # native close of this instance's window, without activation
scripts/dev.sh input reopen                         # replay the native reopen callback without Dock input or activation
scripts/dev.sh input move <x> <y>                   # pointer move over tracking areas: moved, entered and exited (code navigation hover, a tile's − % + control)
scripts/dev.sh input text "hello"                   # insert into the first responder
scripts/dev.sh input command insertNewline:
scripts/dev.sh input shortcut z --mods cmd           # a key press by character: p, 9, =, +, $'\r'
scripts/dev.sh input key return                      # by name: return escape tab space delete forwarddelete up down left right home end pageup pagedown
scripts/dev.sh input state                         # app.log: window, closed/selected/minimized state, ordered native tab-group window ids, viewport, responder, and object/selection hashes; no source text
scripts/dev.sh input scroll <x> <y> <dx> <dy>
scripts/dev.sh input scroll <x> <y> <dx> <dy> --repeat 30 --gesture   # one phased trackpad gesture (began and ended without movement)
scripts/dev.sh input scroll <x> <y> <dx> <dy> --lines   # a mouse wheel's notches (line units, no precise deltas); with --mods cmd, ⌘-scroll
scripts/dev.sh input magnify <x> <y> <amount>      # one pinch step: zoom × (1 + amount); 0.05 in, -0.05 out
scripts/dev.sh input panel <path>                  # choose a file in the open panel a page's <input type=file> opened
scripts/dev.sh input remote <ssh target> <board> [<host home>]   # open another easl's board as a remote board (AppDelegate.openRemoteBoard); host home: a dev instance's EASL_DEV_HOME
```

Coordinates are window-content points from the top-left: `shot` pixels / 2 (a Retina capture), minus the 28-point title bar (64 points while the window shows a tab bar, i.e. two or more boards are open). Prefer Hyper clicks and API calls: a plain click on a window of an inactive app is how macOS decides to activate it, and `EASL_NO_ACTIVATE` is the only thing standing between that and the user's screen.

Client mode with two instances on one Mac: start the host, `EASL_DEV_HOME=/tmp/easl-dev-a scripts/dev.sh start`, and give it a board (`board.open`, some objects). Start the viewer with `EASL_DEV_SSH=<wrapper>` (passed through by `dev.sh`): a script that runs `/usr/bin/ssh -F <config> "$@"`, whose config names a Host (`cmhost`: 127.0.0.1, the port of a private sshd run as yourself with `/usr/sbin/sshd -f <config>`, `UsePAM no`, its own host key and `AuthorizedKeysFile`, `StrictHostKeyChecking no`). Then `EASL_DEV_HOME=/tmp/easl-dev-b scripts/dev.sh input remote cmhost <board> /tmp/easl-dev-a` opens the host's board in the viewer as `<root> @ cmhost`. Drive the viewer with `input`, check the host over its socket (`object.get`, `agent.read`), capture the viewer's window by id (`screencapture -l`; a remote board has no `view.snapshot` on the viewer), and check `find <viewer home> -newer <mark>` names no file for that board. Stop both instances and the sshd afterwards.

`shortcut` and `key` are real key presses (key down and up, with the US-layout virtual key code and characters a keyboard produces) posted into the app's event queue, so they go where a physical key goes: the window's key equivalents first (board navigation shortcuts, `CanvasWindow`), then the focused view's (Ghostty's bindings), the main menu, and finally `keyDown` to the first responder. `input key return` submits a shell command or an omp prompt in a terminal tile; `input text` alone only types. Since the app never activates, no window is key; `CanvasApplication` dispatches a replayed key press as for the key window and resolves untargeted menu actions (Select All, Copy) through that window's responder chain, as a real key press would. `command` calls `doCommand(by:)` on the first responder directly: the text system handles it, a terminal ignores it.

`text`, `command`, `shortcut`, and `key` go to an open sheet (e.g. the ⌘G group-name prompt) when the window has one, so `input text "Auth"` then `input key return` confirms it. Esc/Delete on the board: `input key escape` / `input key delete` (the board has keyboard focus unless a terminal does). A save sheet (Save as PNG…, Save as HTML…) runs out of process: no replayed event reaches it, and `input key return` saves under the name it suggests, in the folder it opened in (the last export folder, else `~/Downloads`; `canvas.exportDirectory` in the `net.waldin.easl` defaults, which every instance shares: `defaults delete net.waldin.easl canvas.exportDirectory` after testing).

Any kind takes `--repeat N [--interval ms]` (default 8 ms apart) for a trackpad-rate burst, e.g. `input scroll 950 220 -40 -15 --repeat 120`; a `magnify` burst is one gesture (began, changed…, ended). A `scroll` burst sends continuous (trackpad-precise) steps without a gesture phase: on macOS 26 NSScrollView tracks a real phased scroll itself, and a replayed phased gesture only moved the view by its first step. `--gesture` replays the burst as that phased gesture anyway, for views that own a gesture from its first event (a changes tile keeps a whole gesture, the board never pans in it). A horizontal-dominant step (`|dx| > |dy|`) or a `--lines --mods shift` step pans over code, changes, and terminal tiles. A vertical step over a terminal never pans: it scrolls the terminal, or does nothing while the terminal has no keyboard focus, no scrollback and no program capturing the mouse (a fresh shell; `less` or a full-screen TUI in the alternate screen, which must not move). A `--gesture` replay that a pan slides a tile under keeps panning the board. When the burst ends, `app.log` records `longest gap … before step …, mean lateness …`. The longest gap between two steps is the longest stall a person sees, and it is the number to compare before and after a performance change. `scripts/perf-replica.sh start <board-id|file> [app]` copies a real board (terminals dropped) into a scratch home to measure against. It launches unfocused on the current Space and uses yabai only to look up the window id. `[app]` runs a given bundle, so two frozen builds can be measured in turns.

`magnify` is a real gesture event (CG type 29 with HID zoom type), so NSScrollView runs its own live magnification and the board's liveness pass runs at the end, exactly as for a trackpad pinch. Calling `setMagnification` per step instead measures a different thing. Live magnification anchors at the real pointer, so the replay moves the document back under the replayed point after each step. Put that point over empty board or a code tile: a note or terminal under it takes the gesture. On macOS 26 AppKit damps replayed steps after the first few (0.05 per step barely moves; `0.25 --repeat 45` goes from fit to 100% and `-0.25 --repeat 45` back out, rubber-banding at the limits).

`Tests/RemoteClosedBoard/run.py` exercises a separate development viewer of a scratch host. It requires macOS, Pillow, the authorized CuaDriver, the viewer checkout and home, a local Unix socket forwarding to the scratch host, its SSH target and home, and an empty scratch board. The prepared fixture directory must be visible to both the runner and the host. Follow the machine's GUI policy before launching it.

The regression keeps the exact Cmd-T focus, selection, object, and viewport checks, Select All, literal clipboard copies, pan, visible zoom changes, and the hidden closed tab's needs-you behavior. Code context actions, Code-menu actions, and Cmd-clicks must preserve those inspection fields and the clipboard while closed. The public viewer `app.metrics` board-write count also stays fixed, so a rejected provisional edit cannot pass by rolling back before the next state sample.

Reopening must leave host objects, revision, and attention unchanged. Object timestamps are compared at their stored whole-second precision, with raw snapshots retained. The in-memory mutation journal resets when its board closes, so it is not compared across reopening.

Prepare a fresh host root with the real sourcekit-lsp binary. The helper prints the canonical root and an `EASL_LSP_SWIFT` launcher path. Set that existing override in the scratch host's isolated SSH login environment before starting the viewer. Do not change a shared shell profile. This fixture is not a language-server replacement. It forwards real LSP frames unchanged and holds one actual definition reply until the runner releases it.

```sh
FIXTURE="$(mktemp -d /tmp/easl-closed.XXXXXX)"
FIXTURE="$(cd "$FIXTURE" && pwd -P)"
python3 Tests/RemoteClosedBoard/lsp_gate.py prepare --root "$FIXTURE" \
  --server "$(xcrun -f sourcekit-lsp)"
```

Open and reopened controls must create host code tiles aimed at `main.swift` line 3 through the context menu, menubar, and Cmd-click navigation. URL controls must create a host browser with the literal fixture URL. The delayed regression selects the code tile, pans it entirely offscreen, starts the native Open Definition shortcut, and waits for a real server reply. It closes the host board before releasing that reply. The viewport, focus, selection, clipboard, model, and board-write count must remain unchanged. The same held-reply action while open must create the exact code target.

Also exercise a terminal Cmd-click whose real host reference reply arrives after closure. Closing must cancel and invalidate that request; releasing a late reply must not open a tile, show a notice, move the viewport or focus, or increment the viewer's board-write count. Repeat while open and after reopening to prove ordinary reference navigation still works. This terminal-specific timing scenario is separate from the code-tile LSP fixture above.

Exercise the same close-before-completion order for a real HTML `<canvas-link>` host lookup. Hold its host-file reply, close the board, then release it. Neither a provisional code tile nor a late viewport/focus change is allowed. While closed, the parked page must not start new excerpt or image reads, state writes, or browser navigation. Open and reopened code-link controls must still reach the literal target. Retain host request records and the viewer's model, viewport, focus and board-write counter for each order.

For Changes, hold patch reconstruction after an open-board Stage or Discard is admitted, close the board, then release it. No new host apply may start and no late review entry, selection change or notice may appear. A write already dispatched before closure may have committed; never retry it or claim cancellation rolled it back. Also close while a card waits for its main turn, and close/reopen while a real note or Git read is held. Old cards must start no new host reads after closure, and released old reads must not replace the retained model. Open and reopened controls must still load and apply normally.

The runner's accessibility regression uses `Tests/RemoteClosedBoard/native.py` and the guest's authorized CuaDriver. Each snapshot checks that the development PID owns the instance lock and requests that exact PID and window ID. A fresh tree supplies the labelled Close button's opaque element token. The helper immediately sends a background accessibility `press` with the same PID, window ID, and unique session. It never supplies coordinates or falls back to a pointer click. Open and reopened `ax-control.swift` controls must remove exactly that host object and viewer tile, advance the host revision once, and increment the viewer's public board-write count once. With the host board closed, pressing `Close main.swift` must preserve the exact model, selection, selected-text hashes, first responder, viewport, clipboard, and board-write count. The subsequent literal cached-source copy detects a delete-and-restore that loses the retained code view. Driver action receipts are retained as evidence, not treated as proof of the postcondition.

The cached Changes proof also requires a real Git hunk and native zoom **in**, not only a zoomed-out capture. Record the fixture's literal path, removed line, and added line while the board is open. Set the tile's content zoom to 150% before closing, and retain that state too. Close the host board, pan the Changes tile entirely offscreen and back, and increase board zoom from 50% to its supported 100% ceiling with native input. Content zoom and board magnification are independent; do not change the application's zoom limits for this proof. Retain before-and-after viewport states showing the increased board zoom and CuaDriver captures of the actual cached hunk at both scales. Inspect the enlarged path and diff text for sharp rendering and unchanged content. Check that the host file bytes, index and worktree diff, board contents, and revision remain unchanged. A model-only assertion, a rescaled PNG, or the general pan/zoom captures above do not satisfy this proof.

The runner writes observations, protocol evidence, native action receipts, and CuaDriver captures of only its verified viewer PID and window. It releases its reply gates, removes its code-navigation control objects in `finally`, and ends its native-driver session on exit. It does not request native SSH Screen Recording permission or use `screencapture`. The caller still owns the scratch viewer, host, SSH forwarding, and root cleanup.

```sh
python3 Tests/RemoteClosedBoard/run.py --checkout "$PWD" --viewer-home "$EASL_DEV_HOME" \
  --host-socket "$G/host/easl.sock" --host-home "$G/host" --host easl-guest \
  --root "$FIXTURE" --fixture-directory "$FIXTURE" --out "$FIXTURE/proof"
```

### Composer token editing

Run the native AppKit regression in a claimed GUI guest. It links the production composer
and drives deletion, undo, redo, and another undo of a staged code token. The draft and tray
must agree after every action. It also checks that Japanese marked text hides the placeholder
and commits without losing text. Existing core tests do not exercise these native text-view paths.

```sh
swift build --build-system native -j 2 --product Easl
python3 Tests/ComposerInput/run.py \
	--bin-path "$(swift build --build-system native --show-bin-path)"
```

Use the native build's path, not an older native cache beside the default build backend's
products. The runner never rebuilds the app and supplies a disposable home.

For a window-level check, stage a mention on a local or remote board, focus the composer,
select and delete the token, then undo, redo, and undo again. The token and its staged mention
must return together without changing the words around them or losing redo.

Repeat after deleting the token's tile before undo. The missing mention must stay absent,
and undo must not crash. Normalizing a missing reference expires obsolete native redo.
The native regression also checks that a draft typed before deferred normalization survives it.

### Performance probes

`EASL_DEV_PERF=1` (set by `dev.sh` and `perf-replica.sh`) turns on `DevPerf` (`Sources/CanvasApp/DevPerf.swift`). Every input burst becomes a span with a `gesture` phase and a 1.5 s `settle` phase (the liveness pass, card and live flips, and the redraws they cause). `input perf [ms]` is an idle span (default 5000 ms), which also works while the window is minimized. `input idle on|off|auto` controls both terminal redraw throttling and the automatic-update idle gate. `on` supplies 600 idle seconds, enough for the ten-minute update threshold and the one-minute redraw threshold. `off` supplies zero, and `auto` resumes sampling input across the Mac's login session. The pinned value remains until `idle off` or `idle auto`; replayed keys do not clear it. Do not use `idle on` on an instance with automatic installation enabled unless you intend to allow installation. A span's `counts` carry `terminal.draw`, the redraws. At the end of a span `app.log` gets one line per phase:

With probes enabled, `applicationDidFinishLaunching` begins a `launch restore` span before scheduling board restoration. The first explicit perf or input-burst span ends and logs it; ending a span includes its still-open partial wake. The launch span initially has no window or display link, so zero frames does not mean no main-thread work. Bootstrap before that callback is not covered. For startup measurements, leave this single span active through held Git, completed restoration, and settle; a later idle span is not startup coverage. The lifetime `app.metrics` monitor also observes timer boundaries and is not a substitute for the same unsplit awake interval. Keep `sample`, accessibility walks, and pixel captures in separate diagnostic runs; their measured overruns remain evidence, not plain timing passes. Native tab switching and window-manager minimize/restore controls run after the board-load timing span, in the claimed GUI guest.

`DevPerf` brackets a wake with separate Core Foundation observers: `afterWaiting` at the lowest order and `beforeWaiting` at the highest. An order-zero end observer misses later AppKit/Core Animation commits; timings from that older probe are lower bounds, not display-inclusive passes. `app.metrics` still uses its older monitor and remains diagnostic for this gate.

`DevPerfWake` logs wall and CPU duration for each stretch of at least 50 ms, its offset from the phase's start, and the scoped timers it ran. The entire wake belongs to the phase active when it finishes; a negative offset means it began in the prior phase. Never split a continuous wake at a phase boundary: two 60 ms pieces would hide a real 120 ms main-thread stall. Parent and child timers can overlap: neither summing them nor subtracting their totals identifies an unmeasured wait. Pair the longest wall wake with its own CPU value, not the independent maximum-CPU wake.

Predeclare fresh-process runs and retain every row, including the first launch after boot and harness seed processes. Record the actual native window bounds for both artifacts; a launcher frame request is not proof that an older app honored it. Different-sized windows do not support a size-matched painting comparison. Samples, native inspectors and Cua captures are separate functional/attribution diagnostics, with their overhead and capture-geometry limits recorded.

```text
DevPerf: idle idle 6041 ms: frames 0 missed 0 (vsync 16.7 ms, longest frame 0.0 ms), main busy 259 ms, hitches 6 (longest 54.0 ms), main cpu 208 ms (longest 52.7 ms); longest wake: start+424.2 ms cpu 52.7 ms; counts: …; timings (n/total/max ms): …
```

- `frames`/`missed`/`longest frame`: a display link on the window; a missed vsync is one the main thread was too busy to serve (a dropped frame for anything the main thread draws).
- `main busy`/`hitches`: a main run-loop observer times each stretch from waking to sleeping; a stretch longer than one vsync is a hitch. `main cpu` reports those stretches by the main thread's CPU time (`CLOCK_THREAD_CPUTIME_ID` at each end), including the largest CPU duration. Wall time also includes waiting and preemption, so report both; a CPU-only result cannot establish the board-load 100 ms main-thread wall limit. `longest wake` locates the longest wall stretch relative to the phase's start and gives that same stretch's CPU time, which need not equal the independent largest CPU duration. A wake spanning a phase boundary can start before that phase. `counts` include `terminal.title`, the title changes the terminals handled in the span.
- `timings`: count, total, and longest milliseconds per probe: `draw.<View>` (every `draw(_:)` of our views), `scene.pass` (the liveness pass), `scene.boundsChanged` (per pan/pinch step), `content.live.<Tile>`/`content.unlive.<Tile>` (live/card flips), `card.call`/`card.latency`/`card.install.<Tile>` (card snapshots), `live.reveal.<Tile>` (card lifted after going live).

For CPU and wakeups, measure the process from outside: `/usr/bin/top -l 5 -s 3 -c d -stats pid,cpu,idlew,power -pid <pid>` (`IDLEW`: idle wakeups per 3 s interval; skip the first sample) and `/bin/ps -o time= -p <pid>` before and after a fixed interval (the shell's `ps` may be another tool); `sample <pid> 5` shows where the main thread spends it. Without `-c d`, `top -l` prints the process's lifetime total in every sample: a number that never varies within a run and only rises from run to run, whatever the app is doing now. `IDLEW` counts only wakeups that bring the CPU package out of idle, so on a busy shared machine it undercounts; timer wakeups are steadier as `ri_interrupt_wkups` from `proc_pid_rusage(pid, RUSAGE_INFO_V4)` (Python `ctypes`) over the same interval. A sleeping main thread with wakeups still counted belongs to another thread: per-thread CPU time from `proc_pidinfo(PROC_PIDTHREADINFO)` names it (Ghostty's are `io`, `io-reader`, `io-gather`, `renderer`, one set per terminal).

- Frame pacing needs a displayed window. Launch unfocused on the current Space and leave the window there. Never move a window, focus a Space, or activate the app for a measurement. CPU, wakeups, and memory work minimized. With synthetic boards, keep every object near the rest, or Zoom to Fit leaves the pinch point over empty board and the gesture measures nothing.
- Wakeups that stay high while the window is minimized and the main thread sleeps: `sample` the app and look for `CVDisplayLinkDriverHelper` → `TerminalSurfaceCoordinator.tick` → `draw`. That is a Ghostty surface that still believes it is visible: libghostty-spm's shared display link runs at up to 120 Hz while any visible surface owes a frame. With no display link in the sample, look at the `io` and `renderer` threads: a surface Ghostty believes focused runs cursor-blink and termios-poll timers, ~12 wakeups/s per terminal, visible or not (docs/design.md, Performance).
- Idle soak uses a minimized instance with the load you care about, such as three idle omp tiles and a shell running `while :; do date +%T; sleep 2; done`. Display it once before minimizing, then measure CPU, wakeups, and `footprint` at the start and after 20 minutes. Restore only your window without activation before taking a `shot`. Every terminal must show its current screen, and replayed typing (`input click` on it, `input text`) must reach it. Runs of two hours or more belong in an isolated VM.
- Stall samples: `input stall [ms]` holds the main thread (default 2 s) inside a `dev.stall` span; on an instance started with `EASL_DEV_PERF=0 scripts/dev.sh start` (the probes off, as in a user's easl), use a 3 s stall and allow up to 16 s for the sampling child to finish. A successful sample leaves a nonempty `<home>/stalls/<UTC>.txt`, `app.log` includes `main thread busy ~3000 ms: stalls/<file>; dev.stall ~3000 ms` (each about the hold: the turn and the span run a little past it), and `easl metrics` adds a `stalls` line; `app.metrics` carries `stalls.sampled`, `stalls.newest` and a file-prefixed `longest.cause` for the matching longest turn. Symbolication that finishes after the turn logs a second, tagged line for it. The call graph shows that hold (`DevInput` → `sleepForTimeInterval`) only while it outlasts `sample`'s attach; a hold that ends first still leaves the tagged file, and the stacks are the idle run loop (an 8 s hold left the sleep on the stack). A second stall within five minutes must not add a sample; on a fresh instance with `EASL_DEV_PERF=1`, the same stall must leave no sample and `stalls.sampled` must stay zero. The policy (threshold, once per turn, 5 min between samples, 20 kept) is tested without `sample` (`StallSamplingTests`), and so is the file reaching its own turn's line and `longest` (`StallSamplingCorrelationTests`: the main-thread monitor and the watchdog run by hand with a stand-in child, the turn ending before the claim, timed before it but published after, or while `sample` runs, the next turn claimed after it, a reset during the turn or after it, and a killed or empty sample leaving no file).
- Memory: `footprint -p <pid>` for the app; WebKit's processes aren't its children, so attribute them with `responsibility_get_pid_responsible_for_pid` (e.g. Python `ctypes.CDLL(None)`) and sum their footprints.

### Performance benchmark

A repeatable loop for API-write bursts on a large board (docs/design/next.md, "Performance and monitoring"). Bundles are frozen release builds (`EASL_BUNDLE_APP=/tmp/a.app scripts/bundle.sh release`). The loop needs yabai and starts and stops its instances itself. Each window opens unfocused on the current Space. No rule or window move isolates it. On a shared Mac, keep each launch under two hours and use an isolated VM for longer runs.

```sh
python3 scripts/perf-board.py <home> <root> [--arrows N] [--labels N]   # the synthetic board (seeded), into a dev home
python3 scripts/perf-load.py serial|batch [--variant 0|1]                # an agent's 139-event write burst over EASL_SOCKET
python3 scripts/perf-load.py poll --duration 60                          # board.get every 10 s, nothing else
python3 scripts/perf-loop.py --app base=/tmp/a.app --app fix=/tmp/b.app [--board <sanitized.json>] [--runs 3]
```

- The loop starts each bundle in turn on a scratch home of its own (a new directory under `--tmp`, deleted when that bundle stops; it never deletes anything else, so your `EASL_DEV_HOME` is safe), order alternating between runs, shows the board at 100% over its html cards, and runs `visible-serial`, `hidden-serial` (window minimized), `visible-batch`, `poll-idle` and `pan-zoom` (3000 pt across the cards and back, three zoom steps out and in, the whole board and back, twice; `html.reuse` against `html.load` says whether parked pages came back). Each row (JSONL, `--out`) has the app's CPU from the burst's start until it is quiet again, the burst's wall time and per-method RPC latency, the `DevPerf` spans over it (main busy, the longest stretch the main thread didn't sleep, `route.board` routings) and `app.metrics` where the bundle has it; the table prints medians and ranges with the targets as pass/fail, and a target whose measurement is missing fails. `--summarize` re-prints a table from earlier rows.
- The parking-based `--headless` mode is removed. Use an isolated VM when a benchmark must not share the user's display. The loop pans with mouse-wheel notches replayed through `scripts/dev-input.swift`. Sideways notches with ⌘ reach the canvas whatever tile is under the replayed pointer.
- `--scenarios agent-titles` (not in the default set) measures working agents instead of writes: 8 live terminal tiles each run an agent-like program (a braille-spinner title and a status line every 80 ms, as omp while it works), 60 s once they are up. Its row has `cpu_s`, the app's CPU over the whole interval (`proc_pid_rusage`, seconds; per second it is `cpu_s / load.wall_s`), `wakeups_s` (interrupt wakeups per second) and `main_ms_s` (the main thread's busy ms per second, `DevPerf`); A/B only, no target. The tiles go 20,000 pt to the right at the view's own height (sideways ⌘-wheel pans reach them over any tile) and are deleted after the measure.
- Every row also has the app's `instructions_G` and `cycles_G` over the scenario (`proc_pid_rusage`'s `ri_instructions`/`ri_cycles`, billions) and, where the scenario knows how many events the app handled (a burst's writes: html and shape updates plus one create; agent-titles: the title changes DevPerf counted in the span, `title_changes`, never the producers' nominal cadence, which load lowers), `instructions_per_event_k`; rows from bundles with DevPerf's `main cpu` also carry `main_cpu_ms` and `longest_cpu_ms`, the stretches by CPU time. Instructions retired are the figure that survives other load on the Mac: a fixed loop retired the same count to 0.05 % with six spinning processes beside it while its CPU time moved 5 %, and CPU time, cycles and every wall-clock stretch (longest, RPC latency) move with contention, frequency and the core the scheduler picks. Each row records the Mac's load at the scenario's start and end (`machine`: CPU idle, free memory, processes above 10 %) and is `loaded` when CPU idle was under 30 % at either sample (`LOAD_BAND`): the table counts such rows, and a decision should repeat them rather than trust them.
- A real board's geometry without its content: `scripts/perf-sanitize.py <board.json> <out.json>` keeps types, frames, z, numbers, and enum values in their own fields (checked against each field's closed list), renumbers ids found in identity and reference positions (ids, parents, actors, arrow ends, group members), and replaces every other string with filler of the same length, decided by where a value sits, never by how it looks. It fails, naming only lengths and JSON paths, if any input string over 5 characters or word of 6+ letters survives outside the sanitizer's own vocabulary. Run it on the board's machine and copy only its output; `perf-board.py --replica <out.json>` re-roots it into a home. Its tests: `python3 -m unittest discover -s scripts`.

#### Board scale fixtures

`perf-board.py --objects N` generates exactly N objects with seed 7 by default. Use 50, 200, 500, and 1000 for the scale matrix. Every board contains notes, code, images, HTML, cached diagrams, shapes, arrows, groups, and eight terminals. Each terminal prints a 256-byte sequence line every 125 ms. Create `<root>/.perf-board-quiet` to pause output without ending sessions, and remove it to resume.

HTML pages vary by their own ordinal, independently of the object-type cycle: both static and scripted pages, both initial open states, and four content-size targets. Keep a fixture's bytes fixed across compared bundles; measurements from an older generator are a separate family.

Build both bundles from the same base revision in separate scratch source trees. For the before bundle, copy only `Sources/CanvasApp/DevPerf.swift` and `Sources/CanvasApp/DevInput.swift` from the candidate into the base tree. This adds the same frame log and real-time replay protocol without the product changes. Use the candidate's scripts and replay client for both bundles. Freeze each with `EASL_BUNDLE_APP=<unique-path> scripts/bundle.sh release`; the script builds with `-j 2`. Record the source revisions, per-file hashes, compiler version, build flags, and executable and helper hashes. An uninstrumented main bundle cannot supply this harness's frame or delivery records.

Run `perf-scale.py` only inside a claimed GUI guest. Compile the window lookup helper once, keep both frozen release bundles for the session, and use the same `--fixtures` directory for both artifacts:

```sh
	swiftc -O scripts/perf-window.swift -o "$G/perf-window"
	python3 scripts/perf-scale.py --app base="$G/base.app" --app fix="$G/fix.app" \
	  --fixtures "$G/fixtures" --window-helper "$G/perf-window" --runs 5 \
	  --modes local,remote --easld "$G/easld" --ssh "$G/ssh" --out "$G/scale"
```

The remote mode requires the guest-loopback `easl-guest` SSH wrapper from the guest recipe. It starts only the specified scratch easld. Each run launches an empty viewer, requests a 1000 × 500 point window, pins the development idle policy active, then times opening the fixture board. Local calls use `board.open`; remote calls use the native remote-board opener and wait for the host's delegated `view.get`. The separate `harness_launch_ms` includes development-bundle preparation and is not intrinsic app-launch latency.

Before the first native capture, the runner polls `agent.read` until all eight terminals have produced a complete `worker=N sequence=<20 decimal digits> status=running` marker in the actual `text` output, not in command metadata. The protocol's `unavailable` state keeps the requested output pending; other RPC errors fail the run. All reads share one 90-second readiness deadline, with each RPC limited to the remaining time. `streams.json` retains the latest replies, including partial readiness and unavailable errors on failure. This wait is inside the clock started before opening the target board, so it makes the startup capture bound more conservative. Native capture still performs its original exact PID/window ownership checks; an ownership failure is not retried. Do not combine this readiness family with older runs that verified streams only after capture.

Rows record API readiness, a native startup capture and its elapsed-time upper bound, quiet CPU, app RSS, process footprints, ten-second pan and zoom gestures, and a whole-board `view.render` RPC targeting every object at scale `0.15`, with inline PNG output and a 60-second request limit. `perf-window --drawn IMAGE` uses native Vision text recognition to require the fixture's visible `sequence=… status=running` stream before accepting a startup capture. Every attempt and its receipt remains in the output. The accepted capture's completion time is recorded before OCR. Inspect its pixels too: this establishes a conservative bound for the initial viewport, not an exact first presentation or completion of offscreen tiles.

Idle CPU is a ten-second CPU-time delta before the gestures, with all eight streams paused. Rows distinguish the app, the app plus its observed helpers, and the scratch daemon. The helper aggregate is unavailable if the observed PID set changes during the window; the raw per-PID samples remain. Daemon CPU excludes backend workers. Memory snapshots cover the quiet phase and the end of the whole-board render.

These are post-open quiet observations, not proof that every card on the board has settled. Gestures also use fixed two-second setup waits. Record remaining card activity in profiles, and retain slower or failed observations. Use at least five interleaved observations before attributing a timing difference; a single observation at another board size is diagnostic.

`command()` subprocess calls have a 120-second limit, and native activation/OCR JSON helpers a 30-second limit. A timed-out JSON helper retains its partial stdout and stderr before the failed row enters cleanup. Ownership-inspection `lsof` calls also have a 30-second limit; an inspection failure marks cleanup failed and preserves the scratch directory, stopping the matrix before another run.

The pan uses 40 × 20 point steps, reverses every 60 scheduled steps, and must traverse more than one viewport width. The pinch uses 0.01 steps and reverses every 120 steps. Both use `--repeat 601 --interval 16.666667 --realtime`: missed timer ticks coalesce into the corresponding trajectory displacement instead of stretching 601 deliveries beyond ten seconds. `DevInput.delivery` confirms real-time mode and records delivered/coalesced counts. `DevInput.motion` records the observed pan and magnification range; a gesture without sufficient movement fails the runner.

`DevPerfFrames` reports callback-gap p50, p95, and p99, missed display timestamps, and `stalls50` for each phase. `stalls50` counts main run-loop busy wakes of at least 50 ms, not callback gaps or individual blocking handlers: one busy wake can include several delivered updates. Quantiles are 0.01 ms histogram upper bounds below 100 ms. `overflow100` counts larger gaps, whose quantiles use the phase maximum. Zero samples means no valid frame distribution. These callbacks are not GPU presentation timestamps. The original `DevPerf` and `DevPerfWake` lines retain their formats.

Rows retain render failures, placeholders, omitted objects, and gesture failures rather than treating fast failures as successful measurements. Output includes the original fixture, raw logs, stream replies, startup capture receipts, render object records, and PNGs. Compare the native bounds as well as fixture bytes before attributing a difference to the app.

Cold-preview proximity leaves tile bodies and title controls in their original canvas hierarchy. Distant cold tiles defer card snapshots until near, and new cold admissions wait until a pinch ends. Within a scene pass, live departure snapshots enter before cold admissions; work queued by earlier passes is not preempted. Completed cards survive far/near without being redrawn. Explicit whole-board renders remain uncapped, and remote HTML keeps its existing host-bound file and network rules.

#### Native preview lifecycle regression

Inside a claimed VirtualMac GUI guest with CuaDriver available, use the same compiled window helper and a frozen app:

```sh
python3 Tests/TileProximity/run.py --checkout "$PWD" --app "$G/fix.app" \
  --window-helper "$G/perf-window" --out "$G/proximity"
```

The five cases check a saved browser card after far/near, cold HTML demand only when near, cancelled cold demand restarting on reentry, and a loaded browser's first Zoom to Fit on 500- and 1000-object fixtures. They inspect native body pixels and gated loopback HTTP requests, not `view.snapshot` or `view.render` refreshes. Large cases verify eight outputting terminal sessions. `--cases` selects named cases listed by `--help`. Both harnesses refuse app launch on a physical Mac; the helper's activation mode also checks the guest model. Each scale run uses a fresh capture-session label and ends its session before the next run.

#### Native initial routing regression

Inside a claimed GUI guest, link the native routing smoke against the real testing-enabled app:

```sh
	swift build --build-system native -j 2 --product Easl
	python3 Tests/InitialRouting/run.py --bin-path "$(swift build --build-system native --show-bin-path)"
```

The smoke checks attached and hit-testable opening previews, initial API bounds, and exact background versus main-thread paths and labels.
It also checks parallel first previews, cancelled and zero-delta drags, unchanged-route retirement, older opening work against a newer edit, moved endpoints, new arrows, export bounds, appearance-only updates, and changed outlines.
Held shapes and unfilled group members route at their displayed geometry; group flow responds to membership changes without a frame change.
It creates disposable boards without terminal workers. Pair it with a displayed 1,000-object opening trace to verify that immediate `board.get` polling does not run obstacle routing on the main thread.

### Remote boards

To test File › Open Remote… against another development instance on this Mac, run a private sshd in a scratch directory without changing `~/.ssh`.
Give it its own host key, client key, `AuthorizedKeysFile`, and `ssh_config` entry named `easl-localhost` for its loopback port.
Run `/usr/sbin/sshd -D -e -f <dir>/sshd_config` as yourself with `UsePAM no` and `StrictModes no`.
Point the viewer at a wrapper containing `exec /usr/bin/ssh -F <dir>/ssh_config "$@"`.
Start the host, then start the viewer with `EASL_DEV_SSH=<wrapper>` and `EASL_DEV_REMOTE_HOME=<host's EASL_DEV_HOME>`.
Use `scripts/dev.sh input mainmenu "File/Open Remote…"`, `input text easl-localhost`, and `input key return` to list its boards. Another Return opens the selected board.
Stop the host to see "easl isn't running"; the viewer reconnects when the host starts again.

`remote-boards.json` stores each easld board's `host`, `sshTarget`, absolute server `home`, and `board`. Restarting without `EASL_DEV_REMOTE_HOME`, or with a different value, keeps the saved server home. Entries predating `home` use the dev override when set and the host's default only without it. With the override set, discovery refuses the default server even if an entry explicitly names it; it never redirects that address to another server. The picker remembers its most recent server home too. A custom Mac home uses its own `zmx` and `tmp` directories and has no known launcher, so Start easl is unavailable. Quit the viewer with the sheet open and verify that its SSH relays end before the app exits.

### Terminal pixel alignment regression

Run the native AppKit harness in an isolated macOS GUI session. It links the real app and uses a
Ghostty in-memory terminal. It checks exact body sizes after fractional resizing, window-space
alignment through flipped and magnified ancestors, unchanged tile geometry, the link underline,
and a Hyper-click just above a terminal row boundary.

```sh
swift build --build-system native -j 2 --product Easl
python3 Tests/TerminalPixels/run.py --bin-path "$(swift build --build-system native --show-bin-path)"
```

For pixel proof, use a real 1x display mode and confirm the window's backing scale is 1.
Compare WindowServer crops of the same terminal lines against main after ⌘-scroll, a pan and ⌘0,
then after a pinch and ⌘0. Use whole-device-pixel body sizes at 100% board and content zoom.
Fractional body sizes can still stretch Ghostty's drawable. An in-process render is not pixel proof.

### Default board directory regression

The native regression links the compiled app and invokes the shared picker action with local,
remote, and no active board, with valid, unset, and invalid preferences. It intercepts only panel
presentation and checks the actual `NSOpenPanel.directoryURL`; it is not visual proof.

```sh
swift build --build-system native -j 2 --product Easl
python3 Tests/BoardDirectory/run.py --bin-path "$(swift build --build-system native --show-bin-path)"
```

Use an isolated development instance and its own preference domain, not the installed app's.
Set `canvas.boardDirectory` in that domain to an existing folder different from both the local
board's root and the remote board's root, then restart the instance.

1. With a local board selected, invoke File › Open Board… and confirm the initial folder is the
   configured directory. Cancel, then repeat with the tab bar's + button.
2. Select a remote board and repeat both entry points. Each must ignore the local preference and
   retain the picker behavior observed with the preference unset.
3. Unset the preference and restart. On the local board, both pickers must again start at the
   active board's root. A missing directory, relative path, or regular file must behave the same.
4. Launch the isolated bundle from `/` without an explicit root: a valid preference must select
   the startup board. `EASL_ROOT`, a positional root, and a working directory other than `/` must
   still win over the preference.

Cancel every picker without opening a folder, then stop the development instance. Never change
the installed app's preferences or close the user's boards for this regression.

To check new-board creation, use the same isolated instance and disposable directories:

1. Select a local board. In a parent **outside any Git repository**, invoke File › Open Board…,
   choose **New Folder**, give it a fresh name, then choose **Open Board**. Confirm that an empty,
   independent board opens on that folder. Repeat with the tab bar's + button and a different
   fresh name. Reopen both folders and confirm that each selects its existing board without a
   duplicate.
2. Select a remote board and invoke both File › Open Board… and the tab bar's + button.
   **New Folder** must be absent or disabled: this local picker must not offer folder creation
   under a remote-titled window. Existing folders must remain selectable, and the starting
   directory must retain its previous remote-board behavior. Cancel both pickers.
3. Initialize a disposable Git repository and open its root as a board. With that local board
   active, create and open a child folder inside that repository's root through each picker entry
   point. Both child folders must select the repository's board (same board ID and repository
   root), not independent boards.

Stop the isolated instance and remove only these disposable directories.

### Testing the updater

Run this rehearsal only in a claimed GUI guest, on a scratch home whose bundle can be replaced. Never use the checkout's bundle or the installed app. Point easl › Check for Updates… at a local `latest.json` (docs/design.md "Updates"). A development instance with a loopback `EASL_UPDATE_URL` also checks automatically after about a minute and daily. Keep **Install Updates Automatically** off for the manual rehearsal. Two ad-hoc signed development bundles skip `spctl`, which refuses every ad-hoc app. This existing development-only exception does not skip signature validity, Team ID equality, size, checksum, or version verification:

```sh
t=$(mktemp -d /tmp/easl-update.XXXXXX); mkdir -p "$t/srv"
EASL_DEV_HOME="$t/home" EASL_UPDATE_URL=http://127.0.0.1:8765/latest.json EASL_DEV_EXTERNAL_OPEN=log scripts/dev.sh start
# The "newer" release, with the instance's own bundle id (the relaunch keeps its defaults and TCC identity).
EASL_VERSION=0.2.99 EASL_BUNDLE_APP="$t/new/easl.app" scripts/bundle.sh
plutil -replace CFBundleIdentifier -string "$(plutil -extract CFBundleIdentifier raw "$t/home/easl.app/Contents/Info.plist")" "$t/new/easl.app/Contents/Info.plist"
codesign --force --sign - "$t/new/easl.app"
ditto -c -k --keepParent "$t/new/easl.app" "$t/srv/easl-0.2.99.zip"
printf '{"version":"0.2.99","url":"http://127.0.0.1:8765/easl-0.2.99.zip","sha256":"%s","size":%s,"notes":"https://github.com/twaldin/easl/releases"}\n' \
  "$(shasum -a 256 "$t/srv/easl-0.2.99.zip" | cut -d' ' -f1)" "$(stat -f %z "$t/srv/easl-0.2.99.zip")" > "$t/srv/latest.json"
python3 -m http.server 8765 --bind 127.0.0.1 --directory "$t/srv" &
EASL_DEV_HOME="$t/home" scripts/dev.sh input mainmenu "easl/Check for Updates…"   # the sheet: Update to 0.2.99?
EASL_DEV_HOME="$t/home" scripts/dev.sh input key return                           # Update
```

- `dev.sh` passes `EASL_UPDATE_URL` through into the bundle's `LSEnvironment`. The helper relaunches with that environment, so the new version comes back on `$t/home` with `EASL_NO_ACTIVATE` and any `EASL_DEV_FRAME`. The relaunch uses `open -n -g`, not `EASL_DEV_LAUNCHER`. App entry consumes and unsets the one-launch `EASL_UPDATE_RELAUNCH=1` marker before spawning children. Leave the window unfocused on the current Space. Never add a yabai rule or move it through the relaunch. A frame sets geometry, not a Space. Quarantine is cleared only after Gatekeeper assessment, avoiding a hidden first-launch prompt on background launch.
- After a successful update, check that `plutil -extract CFBundleShortVersionString raw "$t/home/easl.app/Contents/Info.plist"` says 0.2.99, `$t/home/instance.lock` holds a new pid, and `dev.sh cli system.ping` answers. Launch cleans the completed staging folder. If archiving the old bundle failed, a recognized leftover beside the app can remain until stale cleanup without invalidating the installation. The relaunched instance has no `app.log` because its output goes to `/dev/null`. `$t/home/pid` still names the old process, so write the new pid there before `dev.sh stop`.
- Try a wrong `sha256` or `size`, a zip without `easl.app`, a symlink in place of the app, or a version that differs from the zip's. Expect the running app to remain unchanged and a failure notice, not a modal failure sheet. If the app is in the background, expect the notice when the user next looks. `app.update` reports failures in `error`. A version equal to the running one still gives the manual up-to-date sheet. A stopped feed produces a sheet for a manual check and an API error, while an automatic check only logs and preserves any verified staging.
- `input key escape` is Later: the titlebar keeps its Update button (`dev.sh shot`). Release Notes only logs with `EASL_DEV_EXTERNAL_OPEN=log`.
- For automatic installation, enable **Install Updates Automatically** and use `input idle off` to hold a verified update in `ready`. Then use `input idle on` to allow installation without a confirmation sheet. `input idle auto` returns to real input timing. Real input in any app, including a foreground terminal program, resets the ten-minute wait. The setting off must prevent automatic installation even with `idle on`.
- To exercise remote deferral, use two guest instances on a guest-local scratch easld. Let A draw a static browser page and B stream it. Pin A with `input idle on`, enable automatic installation, and click B every 30 seconds. `app.update check` must remain `ready` with `deferred: "remote viewer active"`. Stop B, then wait the full 600 seconds after its last activity. Observe a new A PID, the newer version, and its reopened boards. Use `system.ping`, not repeated update checks, during expiry to prove the idle sampler retries on its own. Repeat an explicit `app.update install` while B is attached and verify the warning lists the browser session before A quits.
- Exercise `dev.sh cli app.update check` and `dev.sh cli app.update install`. An accepted install must answer `phase: "installing"`, `installPending: true`, and `error: null` before the old connection closes. Reconnect and check `currentVersion` to establish that installation completed. The acknowledgment alone is not proof of replacement or relaunch.
- Open local and scratch-remote boards before updating. Record tab order, selected tabs, minimized state, pid, window ids, foreground app, and Space before and after. Only the marked update relaunch should attempt the saved layout once. Make a remote board unavailable to exercise the pending recovery notice and Retry or Discard. An ordinary later launch must use the latest normal reopen list, not resurrect the update snapshot, and failed recovery must not block later updates.
- Interrupt replacement to exercise the atomic same-volume bundle exchange. The canonical app path must contain a complete old or new bundle, never a gap between two renames. A failure to archive the old bundle after exchange must not mark the installation failed. These are rehearsal expectations, not evidence of a completed GUI run.
- Afterwards: `EASL_DEV_HOME="$t/home" scripts/dev.sh stop`, stop the server, `rm -rf "$t"`.

### Terminals and agents

- Terminal text: `scripts/dev.sh zmx-env zmx history canvas-<tileId>`. For a custom home, prefix the command with the same `EASL_DEV_HOME` used at launch.
- Create an omp tile: `scripts/dev.sh cli object.create --type terminal --json '{"props":{"cwd":"<repo>","command":["omp"]}}'`.
- Prompt it and wait: `scripts/dev.sh cli agent.prompt --target <tileId> --text "…"`, then `scripts/dev.sh cli agent.wait --target <tileId> --timeoutMs 300000`.
- Recent terminal text through the API: `scripts/dev.sh cli agent.read --target <tileId> --lines 40`; `--since prompt` gives what followed the last `agent.prompt` (its echo, then the reply); `--final` only the answer.
- Reboot resume: quit this dev instance, run `scripts/dev.sh zmx-env zmx kill canvas-<tileId> --force`, then `scripts/dev.sh start` with the same `EASL_DEV_HOME`. A missing session reruns `props.command` or resumes its recorded agent session with `omp --resume=<session file>`, the recorded id when that file is gone, `claude --resume <sessionId>`, or `codex resume <sessionId>`. The saved command's options are retained, including a checkout extension passed with `-e`. Options typed only in the shell are not recorded, so a shell-started agent resumes without those options.
- Terminal notifications: `printf '\e]9;Build finished\a'`, `printf '\e]777;notify;Title;Body\a'`, `printf '\a'` in a tile raise an attention marker on it (`app.log`: "terminal … sent a notification" / "rang the bell"; stored in the board file's `attention`). With `EASL_NO_ACTIVATE` the app is never active, so a focused terminal still gets them.
- Ghostty config: `app.log` logs which files loaded, the theme, font and size ("Ghostty config from …"), each rejected line, and each keybind of a window, tab or split action ("Ghostty keybind … runs easl's New Terminal", "dropped Ghostty keybind …"). Try a scratch config without touching the real one: `XDG_CONFIG_HOME=/tmp/x scripts/dev.sh restart` reads `/tmp/x/ghostty/config` (dev.sh passes `XDG_CONFIG_HOME` through; the Application Support config still loads after it).
- macOS notifications (agent done/blocked while the app is in the background) are never requested or posted with `EASL_NO_ACTIVATE=1`; `app.log` records "notification suppressed" instead.
- With the omp extension installed globally (`~/.omp/agent/extensions/easl.ts`, README), test a modified extension from a checkout: launch omp with `["omp", "--no-extensions", "-e", "<checkout>/extensions/omp/easl.ts"]`.
- Claude Code, Codex, Gemini CLI and opencode integrations (docs/contracts.md "Agent integrations"): type `claude`, `codex`, `gemini` or `opencode` in a tile of your instance; the bundle's wrappers load the integration from that bundle, so no install step. `agent.list` shows the kind and session id after `SessionStart`. To see what a hook does, run it by hand with the tile's variables: `echo '{"session_id":"s","source":"startup"}' | EASL_ENV=1 EASL_TILE_ID=<tile> EASL_SOCKET=<sock> extensions/agent-hooks/run claude SessionStart` prints the context it gives the agent and reports to that instance. The Codex hooks run only while `extensions/codex/config.ts` hashes them the way the installed Codex does: after a Codex update, start `codex` in a tile and check it prints no "hooks need review" warning (`/hooks` lists them as trusted). Keep real agents cheap: scratch repo copies without remotes, a low reasoning effort (`codex -c model_reasoning_effort=low`), and Claude Code against a local stand-in for the Messages API (`ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, with `CLAUDE_CONFIG_DIR` pointing at a scratch config so first-run and trust dialogs don't touch `~/.claude`) when no login is available.
- Gemini CLI in a tile: the tile's login shell may pick an older Node (nvm's default) that can't run it; `nvm use` a newer one first. Never run it opted out (`EASL_AGENT_HOOKS=0`) or outside a tile without `general.enableAutoUpdate: false`, because it auto-updates its global installation. Version 0.60 and later refuse easl's settings layer. Send approval input only through `scripts/dev.sh zmx-env zmx send canvas-<tile> $'\r'`, using the same `EASL_DEV_HOME` as launch. Use `$'\e'` for Esc. For opencode, a scratch repo's `opencode.json` with `"permission": {"bash": "ask", "edit": "ask"}` exercises approval prompts even when global config allows everything.

## Optional: a machine shared with other agents

On `twaldin-home`, use the macOS guest for every GUI check, regardless of duration. A hidden host launch and an unviewed Space are not isolation. Use the guest procedure above; never add host window-manager rules or move host windows for a proof.

- Drive only your instance through the API (`dev.sh cli`) and in-app replay (`dev.sh input`). Prefer `--mods hyper` for clicks. Never send real mouse or keyboard events with CGEvent tools, cliclick, or osascript.
- In `agent-gui`, use the recipe's authorized CuaDriver exact-PID and window-ID capture. Where native Screen Recording is already authorized, `dev.sh shot` or `screencapture -x -o -l <window-id> <file>` captures only that window. `shot` looks up this instance's window by pid with [yabai](https://github.com/koekeishiya/yabai), using `YABAI`, then `~/Applications/Yabai.app`, then `yabai` on `PATH`. These queries are read-only. It captures in place without moving or activating the window, writes into a private directory beside the destination, and replaces the output only after an image exists. A failed capture preserves the previous output.
- `EASL_DEV_FORBIDDEN_SPACES` is an optional, space-separated list of Space indices. `shot` refuses when the window's display is showing a listed Space. It never moves the window to make a capture possible.
- `EASL_DEV_LAUNCHER="<command> <its args>"` replaces `open -g -n`. It receives the same `open` arguments, runs in the background, and logs to `<home>/launcher.log`. A custom launcher must follow the same rules. It must not activate, add window rules, or move windows.
- `EASL_DEV_FRAME="x y w h"` sets explicit window geometry in AppKit screen coordinates, with the origin at the primary display's bottom left. The app honours it only with `EASL_DEV_INPUT=1`. Use it for a repeatable window size on the viewed display, not for Space isolation.
- Without yabai, `start` and `restart` still launch unfocused in place. `shot` and `scripts/perf-replica.sh` report that they need yabai for window-id lookup.
- Stop the instance with `scripts/dev.sh stop` as soon as the check ends. Release the guest claim and stop the guest after its last claimed GUI step.
- Keep builds light with `swift build -j 2`. Use one instance per checkout, and at most one omp tile at a time unless the test needs more.
