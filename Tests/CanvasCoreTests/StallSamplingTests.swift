import Foundation
import os
import Testing
@testable import CanvasCore

/// A main-thread turn a second old gets one sample, at most one every five minutes, and the
/// stalls directory keeps the newest twenty files. No live `sample` here: the policy alone, and
/// below, the watchdog and the main-thread monitor around it with a stand-in child; the real
/// child is exercised by a development instance (docs/testing.md).
struct StallSamplingTests {
    @Test func samplesATurnAtTheThresholdNotBeforeAndNotWhileTheLoopSleeps() {
        var policy = StallSampling()
        let early = policy.shouldSample(turnStart: 100, now: 100 + StallSampling.threshold - 0.05)
        let asleep = policy.shouldSample(turnStart: nil, now: 200)
        let at = policy.shouldSample(turnStart: 100, now: 100 + StallSampling.threshold)
        #expect(!early && !asleep && at)
    }

    @Test func aTurnIsSampledOnceHoweverLongItLasts() {
        var policy = StallSampling()
        let first = policy.shouldSample(turnStart: 100, now: 101.2)
        let again = policy.shouldSample(turnStart: 100, now: 102.2)
        let muchLater = policy.shouldSample(turnStart: 100, now: 100 + StallSampling.minInterval + 10)
        #expect(first && !again)
        #expect(!muchLater, "the same turn, after the rate limit")
    }

    @Test func aLaterStallWaitsOutTheMinimumIntervalSinceTheLastSample() {
        var policy = StallSampling()
        let first = policy.shouldSample(turnStart: 100, now: 101.5)
        let soon = 101.5 + StallSampling.minInterval - 1
        let tooSoon = policy.shouldSample(turnStart: soon - 2, now: soon)
        let later = 101.5 + StallSampling.minInterval
        let inTime = policy.shouldSample(turnStart: later - 2, now: later)
        #expect(first && !tooSoon && inTime)
    }

    @Test func aStallRefusedByTheRateLimitDoesNotPushTheLimitOut() {
        var policy = StallSampling()
        let first = policy.shouldSample(turnStart: 0, now: 1)
        let refused = policy.shouldSample(turnStart: 200, now: 201)
        let next = policy.shouldSample(turnStart: 300, now: 1 + StallSampling.minInterval)
        #expect(first && !refused)
        #expect(next, "measured from the sample taken, not the one refused")
    }

    @Test func staleKeepsTheNewestFilesByModificationTime() {
        let files = (0..<25).map { i in (url: URL(fileURLWithPath: "/stalls/\(i).txt"), modified: Date(timeIntervalSince1970: Double(i * 7 % 25))) }
        let stale = StallSampling.stale(files)
        #expect(stale.count == 5)
        let staleTimes = Set(files.filter { stale.contains($0.url) }.map(\.modified.timeIntervalSince1970))
        #expect(staleTimes == [0, 1, 2, 3, 4])
        #expect(StallSampling.stale(Array(files.prefix(20))).isEmpty)
    }

    @Test func fileNamesAreUTCToTheSecondAndSortChronologically() {
        let earlier = StallSampling.fileName(at: Date(timeIntervalSince1970: 1_791_000_000))
        #expect(earlier == "2026-10-03T040000Z.txt")
        let later = StallSampling.fileName(at: Date(timeIntervalSince1970: 1_791_000_001))
        #expect(earlier < later)
    }
}

/// One `Metrics` with its main-thread monitor and stall watchdog run by hand: run-loop
/// activities and watchdog wakeups at chosen times, `sample` a file write, the log lines kept.
/// A reset stamps the real clock, so the times are on `Metrics.now()`'s.
private final class StallRig: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("easl-stalls-\(UUID().uuidString)", isDirectory: true)
    let lines: OSAllocatedUnfairLock<[String]>
    let metrics: Metrics
    let monitor: MainMonitor
    private var sampler: StallSampler?
    private var clock = 0.0
    private var asItWakes: () -> Void = {}
    private var whileSampling: () -> Void = {}
    /// How many times `sample` ran.
    private(set) var samples = 0

    init(at now: Double) {
        let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
        self.lines = lines
        metrics = Metrics(log: { line in lines.withLock { $0.append(line) } })
        monitor = MainMonitor(metrics, at: now)
        sampler = StallSampler(directory: directory, metrics: metrics, now: { [unowned self] in
            let main = asItWakes
            asItWakes = {}
            main()
            return clock
        }, sample: { [unowned self] file in
            samples += 1
            let main = whileSampling
            whileSampling = {}
            main()
            return FileManager.default.createFile(atPath: file.path, contents: Data("Call graph:\n".utf8))
        })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// The main thread wakes at `start` into a turn.
    func begin(at start: Double) {
        monitor.loop(sleeping: false, at: start)
    }

    /// The turn's `dev.stall` span (`ms` long) ends, and the loop goes to sleep at `end`.
    func end(at end: Double, stall ms: Double) {
        monitor.push()
        monitor.pop("dev.stall", ms: ms)
        monitor.loop(sleeping: true, at: end)
    }

    /// The watchdog wakes at `now`. `asItWakes` is what the main thread does just after the
    /// watchdog reads its clock; `whileSampling`, while `sample` runs.
    func wake(at now: Double, asItWakes: @escaping () -> Void = {}, whileSampling: @escaping () -> Void = {}) {
        clock = now
        self.asItWakes = asItWakes
        self.whileSampling = whileSampling
        sampler?.tick()
    }

    /// The newest sample's file and the launch total, as `app.metrics` has them.
    var newest: String? { metrics.snapshot()["stalls"]?["newest"]?.string }
    var sampled: Int? { metrics.snapshot()["stalls"]?["sampled"]?.int }

    var longest: (ms: Double, cause: String)? {
        guard let longest = metrics.snapshot()["longest"], let ms = longest["ms"]?.number, let cause = longest["cause"]?.string else { return nil }
        return (ms, cause)
    }

    /// The `main thread busy` lines whose cause starts with `file`: their length (ms) and the
    /// rest of the cause.
    func busy(naming file: String) -> [(ms: Double, cause: String)] {
        let prefix = "easl: main thread busy "
        return lines.withLock { $0 }.compactMap { line in
            guard line.hasPrefix(prefix), let tag = line.range(of: " ms: \(file); "),
                  let ms = Double(line[line.index(line.startIndex, offsetBy: prefix.count)..<tag.lowerBound]) else { return nil }
            return (ms, String(line[tag.upperBound...]))
        }
    }
}

/// A sample's file reaches its own turn's `app.log` line and `longest` cause, whenever the turn
/// ends relative to the watchdog and the sample, and across a metrics reset.
struct StallSamplingCorrelationTests {
    @Test func aTurnThatEndsAsTheWatchdogWakesIsNotSampledAndTheNextStallIs() throws {
        let t = Metrics.now()
        let rig = StallRig(at: t)
        rig.begin(at: t)
        // The watchdog wakes 1.5 s in; the turn ends just after it reads its clock. A sample
        // now would be of whatever runs next, under a file no line can name.
        rig.wake(at: t + 1.5, asItWakes: { rig.end(at: t + 1.6, stall: 1600) })
        #expect(rig.samples == 0, "a turn that has ended is not sampled")
        // The missed turn doesn't use up the five minutes: the next stall is sampled and named.
        rig.begin(at: t + 10)
        rig.wake(at: t + 11.5)
        rig.end(at: t + 13, stall: 3000)
        let file = try #require(rig.newest)
        #expect(rig.samples == 1)
        #expect(rig.busy(naming: file).map(\.ms) == [3000])
        #expect(rig.longest?.cause == "\(file); dev.stall 3000 ms")
    }

    @Test func aSampleFinishingAfterItsTurnTagsALaterLineAndTheLongest() throws {
        let t = Metrics.now()
        let rig = StallRig(at: t)
        rig.begin(at: t)
        rig.wake(at: t + 1.5, whileSampling: { rig.end(at: t + 3, stall: 3000) })
        let file = try #require(rig.newest)
        #expect(rig.busy(naming: file).map(\.ms) == [3000])
        #expect(rig.longest?.cause == "\(file); dev.stall 3000 ms")
    }

    /// `easl metrics --reset` handled in the stalled turn itself, with the sample finished
    /// before the turn ends or after.
    @Test(arguments: [false, true]) func aResetDuringTheSampledTurnStillLogsItWithItsFile(sampleOutlastsTurn: Bool) throws {
        let t = Metrics.now() - 10
        let rig = StallRig(at: t)
        rig.begin(at: t)
        var reset = 0.0
        var end = 0.0
        let resetAndEnd = {
            reset = Metrics.now()
            rig.metrics.reset()
            // A sliver after the reset: under a hitch, so the new window keeps no stretch for it.
            end = Metrics.now() + 0.001
            rig.end(at: end, stall: 3000)
        }
        rig.wake(at: t + 1.5, whileSampling: sampleOutlastsTurn ? resetAndEnd : {})
        if !sampleOutlastsTurn { resetAndEnd() }
        let file = try #require(rig.newest)
        let lines = rig.busy(naming: file)
        #expect(lines.count == 1)
        #expect((lines.first?.ms ?? 0) >= 10_000, "the whole turn, not the part after the reset")
        #expect(lines.first?.cause == "dev.stall 3000 ms", "what it ran before the reset")
        #expect((rig.longest?.ms ?? 0) <= (end - reset) * 1000 + 1, "the new window counts only the part after the reset")
        #expect(rig.sampled == 1, "the launch total survives a reset")
    }

    @Test func theSampledTurnsPartAfterAResetNamesItsFileInTheNewWindow() throws {
        let t = Metrics.now() - 10
        let rig = StallRig(at: t)
        rig.begin(at: t)
        rig.wake(at: t + 1.5)
        rig.metrics.reset()
        rig.end(at: Metrics.now() + 0.4, stall: 3000)
        let file = try #require(rig.newest)
        let longest = try #require(rig.longest)
        #expect(longest.ms >= 400 && longest.ms < 10_000, "only the part after the reset")
        #expect(longest.cause.hasPrefix("\(file); "))
        #expect(rig.busy(naming: file).count == 1)
    }

    @Test func aResetAfterTheSampledTurnKeepsItsLateLineButNotItsLength() throws {
        let t = Metrics.now() - 10
        let rig = StallRig(at: t)
        rig.begin(at: t)
        // `sample` outlasts the turn, and the window is reset before it finishes.
        rig.wake(at: t + 1.5, whileSampling: { rig.end(at: t + 3, stall: 3000); rig.metrics.reset() })
        let file = try #require(rig.newest)
        #expect(rig.busy(naming: file).map(\.ms) == [3000], "the late, tagged line")
        #expect(rig.longest == nil, "the reset cleared the turn; its late file doesn't bring it back")
        #expect(rig.sampled == 1, "the launch total survives a reset")
    }
}
