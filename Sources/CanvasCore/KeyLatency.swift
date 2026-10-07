import Foundation

/// How long keys into terminals waited for the main thread, and how long handing them to the
/// terminal took, summed on the key path without a lock or an allocation: `add` touches six
/// numbers, and the owner hands the batch to `Metrics` (and logs) once a second with `flush`,
/// off the key handler. A main-thread stall holds every key typed during it and releases them
/// together, late and in order, so a long wait here is the board's doing, upstream of the
/// terminal, zmx and the program; `late` counts the keys that waited `lateMs` or more.
public struct KeyLatency: Equatable, Sendable {
    /// A wait this long counts as late (one main-thread hitch, `Metrics.hitchStretch`).
    public static let lateMs = 50.0

    public struct Batch: Equatable, Sendable {
        public var keys = 0
        public var waitMs = 0.0, waitMaxMs = 0.0
        public var handleMs = 0.0, handleMaxMs = 0.0
        public var late = 0
        public var isEmpty: Bool { keys == 0 }
    }

    private var batch = Batch()

    public init() {}

    /// One key: `waitMs` from the press to the handler, `handleMs` the hand-over to the terminal.
    public mutating func add(waitMs: Double, handleMs: Double) {
        batch.keys += 1
        batch.waitMs += waitMs
        batch.waitMaxMs = max(batch.waitMaxMs, waitMs)
        batch.handleMs += handleMs
        batch.handleMaxMs = max(batch.handleMaxMs, handleMs)
        if waitMs >= Self.lateMs { batch.late += 1 }
    }

    /// What accumulated since the last flush, and starts the next batch.
    public mutating func flush() -> Batch {
        defer { batch = Batch() }
        return batch
    }
}
