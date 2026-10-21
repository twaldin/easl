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
            signal.yield()
            signal.finish()
            release.wait()
            return 7
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
            signal.yield()
            signal.finish()
            release.wait()
            return "old clip"
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

    @Test func preparationFailureIsVisibleAndDoesNotPublishAReadyValue() async {
        struct Unavailable: LocalizedError {
            var errorDescription: String? { "video source is unavailable" }
        }
        let preparation = VideoPreparation<Int>()
        var reported: String?
        let work = preparation.start({ throw Unavailable() }) { result in
            if case .failure(let error) = result { reported = error.localizedDescription }
        }
        await work.value
        #expect(reported == "video source is unavailable")
        #expect(preparation.state == .failed("video source is unavailable"))
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
}
