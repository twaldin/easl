import Darwin
import Foundation
import os
import Testing
@testable import CanvasCore

struct StallSamplingTests {
    @Test func capturesAt150msNotBeforeAndNotWhileTheLoopSleeps() {
        var policy = StallSampling()
        let early = policy.shouldSample(turnStart: 100, now: 100.149)
        let asleep = policy.shouldSample(turnStart: nil, now: 200)
        let at = policy.shouldSample(turnStart: 100, now: 100.150)
        #expect(!early)
        #expect(!asleep)
        #expect(at)
    }

    @Test func retentionRequires250msOfTheWholeTurn() {
        #expect(!StallSampling.qualifies(turnStart: 100, at: 100.249))
        #expect(StallSampling.qualifies(turnStart: 100, at: 100.250))
    }

    @Test func aTurnIsSampledOnceHoweverLongItLasts() {
        var policy = StallSampling()
        let first = policy.shouldSample(turnStart: 100, now: 100.15)
        let again = policy.shouldSample(turnStart: 100, now: 100.50)
        let atInterval = policy.shouldSample(turnStart: 100, now: 400.15)
        let afterInterval = policy.shouldSample(turnStart: 100, now: 400.50)
        #expect(first && !again)
        #expect(!atInterval && !afterInterval, "the same turn, at and after the rate limit")
    }

    @Test func aLaterStallWaitsOutTheMinimumIntervalSinceTheLastSample() {
        var policy = StallSampling()
        let first = policy.shouldSample(turnStart: 0, now: 0.15)
        let tooSoon = policy.shouldSample(turnStart: 299.999, now: 300.149)
        let inTime = policy.shouldSample(turnStart: 300, now: 300.15)
        #expect(first)
        #expect(!tooSoon, "299.999 seconds since the last capture")
        #expect(inTime, "300 seconds since the last capture")
    }

    @Test func aStallRefusedByTheRateLimitDoesNotPushTheLimitOut() {
        var policy = StallSampling()
        let first = policy.shouldSample(turnStart: 0, now: 0.15)
        let refused = policy.shouldSample(turnStart: 200, now: 200.15)
        let next = policy.shouldSample(turnStart: 200, now: 300.15)
        #expect(first && !refused)
        #expect(next, "the refused turn remains eligible, measured from the capture taken")
    }

    @Test func theDeadlineTracksActiveTurnsAndTheCaptureInterval() {
        var policy = StallSampling()
        #expect(policy.deadline(turnStart: nil) == nil)
        #expect(policy.deadline(turnStart: 100) == 100.15)
        let sampled = policy.shouldSample(turnStart: 100, now: 100.15)
        #expect(sampled)
        #expect(policy.deadline(turnStart: 100) == nil)
        #expect(policy.deadline(turnStart: 101) == 400.15)
        #expect(policy.deadline(turnStart: 500) == 500.15)
    }

    @Test func aTurnThatEndsBeforeCaptureDoesNotSpendTheCaptureInterval() {
        var policy = StallSampling()
        let first = policy.shouldSample(turnStart: 100, now: 100.15)
        #expect(first)
        policy.cancelled(turn: 100)
        let same = policy.shouldSample(turnStart: 100, now: 101)
        let next = policy.shouldSample(turnStart: 101, now: 101.15)
        let limited = policy.shouldSample(turnStart: 102, now: 102.15)
        let later = policy.shouldSample(turnStart: 401, now: 401.15)
        #expect(!same && next && !limited && later)
    }

    @Test func discardingAnEarlyCaptureRestoresThePreviousSamplesRateBoundary() {
        var policy = StallSampling()
        let first = policy.shouldSample(turnStart: 0, now: 0.15)
        let discarded = policy.shouldSample(turnStart: 300, now: 300.15)
        #expect(first && discarded)
        policy.cancelled(turn: 300)
        let same = policy.shouldSample(turnStart: 300, now: 301)
        let next = policy.shouldSample(turnStart: 301, now: 301.15)
        #expect(!same && next, "discarded turns are not retried or charged against the interval")
        policy.cancelled(turn: 300)
        let limited = policy.shouldSample(turnStart: 302, now: 302.15)
        let later = policy.shouldSample(turnStart: 601, now: 601.15)
        #expect(!limited && later, "late cancellation cannot refund another turn")
    }

    @Test func mainThreadStatesDistinguishCPUWaitsAndNotRunning() {
        #expect(StallSampler.state(runState: TH_STATE_RUNNING, suspendCount: 0, cpuNs: 5_000_000) == "on-CPU")
        #expect(StallSampler.state(runState: TH_STATE_RUNNING, suspendCount: 0, cpuNs: 0) == "not running")
        #expect(StallSampler.state(runState: TH_STATE_RUNNING, suspendCount: 1, cpuNs: 5_000_000) == "not running")
        #expect(StallSampler.state(runState: TH_STATE_WAITING, suspendCount: 0, cpuNs: 0) == "blocked in a wait")
        #expect(StallSampler.state(runState: TH_STATE_UNINTERRUPTIBLE, suspendCount: 0, cpuNs: 0) == "blocked in a wait")
        #expect(StallSampler.state(runState: TH_STATE_STOPPED, suspendCount: 0, cpuNs: 0) == "not running")
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

enum StandInCapture: Sendable {
    case samples, fails, writesNothing
}

private final class StallRig: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("easl-stalls-\(UUID().uuidString)", isDirectory: true)
    let lines: OSAllocatedUnfairLock<[String]>
    let metrics: Metrics
    let monitor: MainMonitor
    private var sampler: StallSampler?
    private var watchdogTime = 0.0
    private var capture = StandInCapture.samples
    private var whileSampling: () -> Void = {}
    private var whileCapturing: () -> Void = {}
    /// How many captures ran.
    private(set) var samples = 0

    init(at now: Double) {
        let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
        self.lines = lines
        metrics = Metrics(log: { line in lines.withLock { $0.append(line) } })
        monitor = MainMonitor(metrics, at: now)
        sampler = StallSampler(directory: directory, metrics: metrics, now: { [unowned self] in watchdogTime }, sample: { [unowned self] file in
            let main = whileSampling
            whileSampling = {}
            main()
            switch capture {
            case .samples: return FileManager.default.createFile(atPath: file.path, contents: Data("Main thread stack:\n".utf8))
            case .fails: FileManager.default.createFile(atPath: file.path, contents: Data("Main thread sta".utf8)); return false
            case .writesNothing: return FileManager.default.createFile(atPath: file.path, contents: nil)
            }
        }, captured: { [unowned self] in
            samples += 1
            let main = whileCapturing
            whileCapturing = {}
            main()
        })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// The main thread wakes at `start` into a turn.
    func begin(at start: Double) {
        monitor.loop(sleeping: false, at: start)
    }

    /// The turn's `dev.stall` span (`ms` long) ends at `end`, and the loop goes to sleep or
    /// (`intoNext`) straight into the next turn.
    func end(at end: Double, stall ms: Double, intoNext: Bool = false) {
        monitor.push()
        monitor.pop("dev.stall", ms: ms)
        monitor.loop(sleeping: !intoNext, at: end)
    }

    /// Advances the watchdog clock; capture and file-writing callbacks can publish turn ends.
    func wake(at now: Double, capture: StandInCapture = .samples,
              whileCapturing: @escaping () -> Void = {}, whileSampling: @escaping () -> Void = {}) {
        sampler?.queue.sync {
            watchdogTime = now
            self.capture = capture
            self.whileCapturing = whileCapturing
            self.whileSampling = whileSampling
            sampler?.tick()
        }
    }

    func settle() {
        sampler?.queue.sync {}
    }

    /// The stalls directory's file names.
    var files: [String] { (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] }

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
    /// Claiming a turn (`Metrics.claimStall`) and ending one (`Metrics.mainTurn`) take the same
    /// lock, so the two are ordered whatever the threads do: a turn that ended before the claim
    /// is not sampled and doesn't spend the five minutes (here); one that ends after it finds its
    /// claim and gets its file (the tests below).
    @Test func aTurnThatEndedBeforeTheClaimIsNotSampledAndDoesNotSpendTheFiveMinutes() throws {
        let t = Metrics.now()
        let rig = StallRig(at: t)
        rig.begin(at: t)
        rig.end(at: t + 1.6, stall: 1600)
        rig.wake(at: t + 1.7)
        #expect(rig.samples == 0, "a turn that has ended is not sampled")
        rig.begin(at: t + 10)
        rig.wake(at: t + 11.5)
        rig.end(at: t + 13, stall: 3000)
        let file = try #require(rig.newest)
        #expect(rig.samples == 1, "the next stall, well within five minutes")
        #expect(rig.busy(naming: file).map(\.ms) == [3000])
        #expect(rig.longest?.cause == "\(file); dev.stall 3000 ms")
    }

    @Test func anEarlyCaptureWritesOnlyOnceThePublishedTurnReaches250ms() throws {
        let t = Metrics.now()
        let rig = StallRig(at: t)
        rig.begin(at: t)
        rig.wake(at: t + 0.15)
        #expect(rig.samples == 1)
        #expect(rig.files.isEmpty && rig.newest == nil && rig.sampled == 0)
        rig.wake(at: t + 0.249)
        #expect(rig.files.isEmpty)
        rig.wake(at: t + 0.25)
        let file = try #require(rig.newest)
        #expect(rig.files.count == 1 && rig.sampled == 1, "persisted during the ongoing stall")
        rig.wake(at: t + 0.26)
        rig.end(at: t + 0.3, stall: 300)
        rig.wake(at: t + 301)
        #expect(rig.samples == 1 && rig.sampled == 1)
        #expect(rig.busy(naming: file).map(\.ms) == [300])
    }

    @Test(arguments: [false, true]) func aCaptureWhoseTurnEndsBefore250msLeavesNoFileAndRefundsTheInterval(endBeforeCaptureCompletes: Bool) throws {
        let t = Metrics.now()
        let rig = StallRig(at: t)
        rig.begin(at: t)
        let end = { rig.end(at: t + 0.2, stall: 200) }
        rig.wake(at: t + 0.15, whileCapturing: endBeforeCaptureCompletes ? end : {})
        if !endBeforeCaptureCompletes { end() }
        rig.settle()
        #expect(rig.samples == 1)
        #expect(rig.files.isEmpty && rig.newest == nil && rig.sampled == 0)
        rig.begin(at: t + 1)
        rig.wake(at: t + 1.15)
        rig.end(at: t + 1.3, stall: 300)
        rig.settle()
        let file = try #require(rig.newest)
        #expect(rig.samples == 2 && rig.sampled == 1, "the discarded capture did not spend five minutes")
        #expect(rig.busy(naming: file).map(\.ms) == [300])
    }

    @Test func aQualifyingTurnEndingBeforeItsEarlyCaptureCompletesStillGetsItsFile() throws {
        let t = Metrics.now()
        let rig = StallRig(at: t)
        rig.begin(at: t)
        rig.wake(at: t + 0.15, whileCapturing: { rig.end(at: t + 0.3, stall: 300) })
        let file = try #require(rig.newest)
        #expect(rig.sampled == 1)
        #expect(rig.busy(naming: file).map(\.ms) == [300])
    }

    @Test func anEarlyCaptureKeepsItsWholeTurnWhenResetBeforeQualification() throws {
        let t = Metrics.now() - 10
        let rig = StallRig(at: t)
        rig.begin(at: t)
        rig.wake(at: t + 0.15)
        #expect(rig.newest == nil)
        let reset = Metrics.now()
        rig.metrics.reset()
        let end = Metrics.now() + 0.001
        rig.end(at: end, stall: 3000)
        rig.settle()
        let file = try #require(rig.newest)
        let lines = rig.busy(naming: file)
        #expect(lines.count == 1)
        #expect((lines.first?.ms ?? 0) >= 10_000)
        #expect(lines.first?.cause == "dev.stall 3000 ms")
        #expect((rig.longest?.ms ?? 0) <= (end - reset) * 1000 + 1, "the new window counts only the post-reset part")
        #expect(rig.sampled == 1)
    }

    @Test func aLateFileKeepsItsOwnTurnWithoutTaggingANewerLongestStretch() throws {
        let t = Metrics.now()
        let rig = StallRig(at: t)
        rig.begin(at: t)
        rig.wake(at: t + 0.15)
        rig.wake(at: t + 0.25, whileSampling: {
            rig.end(at: t + 0.3, stall: 300, intoNext: true)
            rig.end(at: t + 0.9, stall: 600)
        })
        let file = try #require(rig.newest)
        #expect(rig.busy(naming: file).map(\.ms) == [300])
        #expect(rig.longest?.cause == "dev.stall 600 ms")
        #expect(rig.sampled == 1)
    }

    /// A sampled turn whose file is in ends straight into the next, which the watchdog claims
    /// once the five minutes are up. Ending one turn and publishing the next are one critical
    /// section, so the next turn's claim can't take the ended one's place before its line is
    /// settled: each line names its own turn's file.
    @Test func theNextTurnsClaimDoesNotTakeTheEndedTurnsPlace() throws {
        let t = Metrics.now()
        let rig = StallRig(at: t)
        rig.begin(at: t)
        rig.wake(at: t + 1.5)
        let first = try #require(rig.newest)
        rig.end(at: t + 3, stall: 3000, intoNext: true)
        #expect(rig.longest?.cause == "\(first); dev.stall 3000 ms")
        rig.wake(at: t + 302)
        let second = try #require(rig.newest)
        rig.end(at: t + 303, stall: 300_000)
        #expect(rig.samples == 2)
        #expect(rig.busy(naming: first).contains { $0.ms == 3000 && $0.cause == "dev.stall 3000 ms" })
        #expect(rig.busy(naming: second).contains { $0.ms == 300_000 && $0.cause == "dev.stall 300000 ms" })
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
        // The capture outlasts the turn, and the window is reset before it finishes.
        rig.wake(at: t + 1.5, whileSampling: { rig.end(at: t + 3, stall: 3000); rig.metrics.reset() })
        let file = try #require(rig.newest)
        #expect(rig.busy(naming: file).map(\.ms) == [3000], "the late, tagged line")
        #expect(rig.longest == nil, "the reset cleared the turn; its late file doesn't bring it back")
        #expect(rig.sampled == 1, "the launch total survives a reset")
    }

    /// A failed or empty capture's file is deleted and the stretch names nothing.
    /// The directory is pruned all the same.
    @Test(arguments: [StandInCapture.fails, .writesNothing]) func aSampleThatLeavesNoUsableFileIsDeletedAndNamesNothing(capture: StandInCapture) throws {
        let t = Metrics.now()
        let rig = StallRig(at: t)
        // More than twenty older files: one too many, as an attempt that never pruned left them.
        try FileManager.default.createDirectory(at: rig.directory, withIntermediateDirectories: true)
        for i in 0...StallSampling.keep {
            let path = rig.directory.appendingPathComponent("old-\(i).txt").path
            FileManager.default.createFile(atPath: path, contents: Data("Main thread stack:\n".utf8))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i - 3600))], ofItemAtPath: path)
        }
        rig.begin(at: t)
        rig.wake(at: t + 1.5, capture: capture)
        rig.end(at: t + 3, stall: 3000)
        #expect(rig.samples == 1)
        #expect(Set(rig.files) == Set((1...StallSampling.keep).map { "old-\($0).txt" }), "the newest twenty, none of them the attempt's")
        #expect(rig.lines.withLock { $0 } == ["easl: main thread busy 3000 ms: dev.stall 3000 ms"])
        #expect(rig.sampled == 0 && rig.newest == nil)
    }
}
