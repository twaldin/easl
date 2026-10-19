import Foundation

/// Admission control for one HTML tile's channel. A page can post messages without awaiting
/// them, so the native side bounds what it holds: at most `maxRunning` jobs at once, at most
/// `maxQueued` waiting behind them, and anything beyond is rejected as `busy`. `cancelAll()`
/// (the tile detached) fails the queue, cancels running jobs, and discards their results.
@MainActor
public final class HtmlWorkQueue {
    public let maxRunning: Int
    public let maxQueued: Int
    public private(set) var running = 0
    private var waiting: [CheckedContinuation<Void, Error>] = []
    /// Cancels each running job, by id.
    private var active: [Int: () -> Void] = [:]
    private var nextID = 0
    private var generation = 0

    public var queued: Int { waiting.count }

    public init(maxRunning: Int = 4, maxQueued: Int = 64) {
        self.maxRunning = maxRunning
        self.maxQueued = maxQueued
    }

    public func perform<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let generation = self.generation
        nextID += 1
        let id = nextID
        if running < maxRunning {
            running += 1
        } else {
            guard waiting.count < maxQueued else { throw HtmlError.busy }
            // Resumed by a finishing job, which hands over its slot, or failed by cancelAll().
            try await withCheckedThrowingContinuation { waiting.append($0) }
        }
        defer { release() }
        guard generation == self.generation else { throw HtmlError.cancelled }
        let job = Task { @MainActor in try await work() }
        active[id] = { job.cancel() }
        defer { active[id] = nil }
        let result = await withTaskCancellationHandler { await job.result } onCancel: { job.cancel() }
        guard generation == self.generation else { throw HtmlError.cancelled }
        return try result.get()
    }

    /// Fails every queued job and cancels the running ones; later work is admitted normally.
    public func cancelAll() {
        generation += 1
        let queued = waiting
        waiting.removeAll()
        queued.forEach { $0.resume(throwing: HtmlError.cancelled) }
        active.values.forEach { $0() }
    }

    private func release() {
        if !waiting.isEmpty {
            waiting.removeFirst().resume()
        } else {
            running -= 1
        }
    }
}
