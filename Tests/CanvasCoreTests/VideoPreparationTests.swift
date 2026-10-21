import Foundation
import Testing
@testable import CanvasCore

@MainActor
struct VideoPreparationTests {
    @Test(.timeLimit(.minutes(1))) func blockedPreparationLeavesMainActorResponsiveAndCancellationDropsItsResult() async throws {
        let preparation = VideoPreparation<Int>()
        let release = DispatchSemaphore(value: 0)
        let (entered, signal) = AsyncStream<Void>.makeStream()
        var results: [Int] = []
        let work = preparation.start({
            await offPool {
                signal.yield()
                signal.finish()
                release.wait()
                return 7
            }
        }) { result in
            if case .success(let value) = result { results.append(value) }
        }
        defer { release.signal() }
        for await _ in entered { break }
        #expect(preparation.state == .preparing)
        var heartbeat = 0
        await Task { @MainActor in heartbeat += 1 }.value
        #expect(heartbeat == 1)
        preparation.cancel()
        #expect(preparation.state == .idle)
        release.signal()
        await work.value
        #expect(results.isEmpty)
        #expect(preparation.state == .idle)
    }

    @Test(.timeLimit(.minutes(1))) func replacementPublishesOnlyTheCurrentSourceEvenWhenOldWorkIgnoresCancellation() async throws {
        let preparation = VideoPreparation<String>()
        let release = DispatchSemaphore(value: 0)
        let (entered, signal) = AsyncStream<Void>.makeStream()
        var results: [String] = []
        let old = preparation.start({
            await offPool {
                signal.yield()
                signal.finish()
                release.wait()
                return "old clip"
            }
        }) { result in
            if case .success(let value) = result { results.append(value) }
        }
        defer { release.signal() }
        for await _ in entered { break }
        let current = preparation.start({ "new clip" }) { result in
            if case .success(let value) = result { results.append(value) }
        }
        await current.value
        #expect(results == ["new clip"])
        #expect(preparation.state == .ready)
        release.signal()
        await old.value
        #expect(results == ["new clip"])
        #expect(preparation.state == .ready)
    }

    @Test(.timeLimit(.minutes(1))) func stalledAudioWorkerCoalescesUpdatesAndDropsCancelledSessions() async throws {
        let worker = VideoAudioWorkQueue()
        let release = DispatchSemaphore(value: 0)
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let (finished, complete) = AsyncStream<Void>.makeStream()
        let blocker = UUID()
        let updates = UUID()
        let values = Locked<[Int]>([])
        worker.schedule(blocker) {
            signal.yield()
            signal.finish()
            release.wait()
        }
        defer { release.signal() }
        for await _ in entered { break }
        for value in 0..<1_000 {
            worker.schedule(updates) { values.withLock { $0.append(value) } }
        }
        for _ in 0..<1_000 {
            let cancelled = UUID()
            worker.schedule(cancelled) { values.withLock { $0.append(-1) } }
            worker.cancel(cancelled)
        }
        worker.schedule(UUID()) {
            complete.yield()
            complete.finish()
        }
        #expect(values.withLock { $0 }.isEmpty)
        release.signal()
        for await _ in finished { break }
        #expect(values.withLock { $0 } == [999])
    }

    @Test(.timeLimit(.minutes(1))) func stalledTileDoesNotBlockAnotherTilesAudioControls() async {
        let stalled = VideoAudioWorkQueue()
        let independent = VideoAudioWorkQueue()
        let release = DispatchSemaphore(value: 0)
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let (finished, complete) = AsyncStream<Void>.makeStream()
        let controls = Locked<[String]>([])
        stalled.schedule(UUID()) {
            signal.yield()
            signal.finish()
            release.wait()
        }
        defer { release.signal() }
        for await _ in entered { break }
        for command in ["mute", "pause", "close"] {
            independent.schedule(UUID()) { controls.withLock { $0.append(command) } }
        }
        independent.schedule(UUID()) {
            complete.yield()
            complete.finish()
        }
        for await _ in finished { break }
        #expect(controls.withLock { $0 } == ["mute", "pause", "close"])
    }

    @Test func externalClockPlaybackWaitsForPlayerReadinessAndSatisfiesNativePrerequisites() {
        let player = AudioClockProbe()
        var playback = VideoAudioPlayback(player: player)
        player.itemIsReady = true
        playback.preroll { _ in }
        playback.synchronize(seconds: 3, rate: 1, volume: 0.4)
        #expect(player.prerolls == 0)
        #expect(player.synchronizedSeconds.isEmpty)

        player.isReady = true
        let finished = Locked<Bool?>(nil)
        playback.preroll { value in finished.withLock { $0 = value } }
        playback.preroll { _ in }
        #expect(player.prerolls == 1)
        #expect(finished.withLock { $0 } == true)
        playback.ready = finished.withLock { $0 } == true
        playback.synchronize(seconds: 3, rate: 1, volume: 0.4)
        #expect(player.violations.isEmpty)
        #expect(player.synchronizedSeconds == [3])
        #expect(player.volume == 0.4)

        playback.synchronize(seconds: 3, rate: 1, volume: 0.7)
        #expect(player.synchronizedSeconds == [3])
        #expect(player.volume == 0.7)
        playback.synchronize(seconds: 8, rate: 0, volume: 0)
        #expect(player.synchronizedSeconds == [3, 8])
        #expect(player.volume == 0)
        #expect(player.violations.isEmpty)
    }
}

private final class AudioClockProbe: VideoAudioClockPlayer {
    var automaticallyWaitsToMinimizeStalling = true
    var isReady = false
    var itemIsReady = false
    var currentSeconds: Double = 0
    var rate: Float = 0
    var volume: Float = 1
    var prerolls = 0
    var synchronizedSeconds: [Double] = []
    var violations: [String] = []

    func prepareAudio(completion: @escaping @Sendable (Bool) -> Void) {
        prerolls += 1
        guard isReady else {
            violations.append("preroll before player readiness")
            completion(false)
            return
        }
        completion(true)
    }

    func synchronize(rate: Float, seconds: Double) {
        guard !automaticallyWaitsToMinimizeStalling else {
            violations.append("external clock cannot wait automatically")
            return
        }
        self.rate = rate
        currentSeconds = seconds
        synchronizedSeconds.append(seconds)
    }
}
