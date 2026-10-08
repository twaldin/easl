import Foundation
import Testing
import CanvasCore

/// A main-thread turn a second old gets one sample, at most one every five minutes, and the
/// stalls directory keeps the newest twenty files. No live `sample` here: the runtime around the
/// policy is exercised by a development instance (docs/testing.md).
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
