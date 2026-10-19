import Foundation

/// Two independent snapshot links per host; waiting does not extend a render's deadline.
@MainActor
public final class HostBrowserSnapshots {
    private struct Waiter {
        let id: UUID
        let priority: HostReadPriority
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }

    private static let excludedTypes: JSONValue = .array(ObjectType.allCases.map { .string($0.rawValue) })
    private let executable: String
    private var active = 0
    private var waiting: [Waiter] = []

    public init(executable: String = RemoteHost.ssh) {
        self.executable = executable
    }

    public func render(host: RemoteHost, board: BoardID, browser: ObjectID, scale: Double,
                       priority: HostReadPriority, deadline: ContinuousClock.Instant) async throws -> JSONValue {
        try await acquire(priority: priority, deadline: deadline)
        defer { release() }
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw EaslConnection.Failure("timeout", "browser render timed out") }
        let parts = remaining.components
        let milliseconds = remaining >= .seconds(60) ? 60_000 : max(1, Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000))
        let connection = EaslConnection.process(executable, host.relayArguments)
        defer { connection.close() }
        let result = try await connection.request("view.render", .object([
            "board": .string(board), "target": .string(browser), "inline": .bool(true),
            "format": .string("png"), "scale": .number(scale),
            "exclude": Self.excludedTypes, "timeoutMs": .number(Double(milliseconds)),
        ]), timeout: remaining)
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw EaslConnection.Failure("timeout", "browser render timed out") }
        return result
    }

    private func acquire(priority: HostReadPriority, deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw EaslConnection.Failure("timeout", "browser render timed out") }
        if active < 2 {
            active += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    let timeout = Task { [weak self] in
                        do { try await Task.sleep(until: deadline, clock: .continuous) }
                        catch { return }
                        self?.fail(id, error: EaslConnection.Failure("timeout", "browser render timed out"))
                    }
                    let waiter = Waiter(id: id, priority: priority, continuation: continuation, timeout: timeout)
                    let index = waiting.firstIndex { $0.priority.rawValue < priority.rawValue } ?? waiting.endIndex
                    waiting.insert(waiter, at: index)
                }
            }
        } onCancel: {
            Task { @MainActor in self.fail(id, error: CancellationError()) }
        }
        do { try Task.checkCancellation() }
        catch { release(); throw error }
    }

    private func release() {
        if waiting.isEmpty {
            active -= 1
        } else {
            let waiter = waiting.removeFirst()
            waiter.timeout.cancel()
            waiter.continuation.resume()
        }
    }

    private func fail(_ id: UUID, error: Error) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiting.remove(at: index)
        waiter.timeout.cancel()
        waiter.continuation.resume(throwing: error)
    }
}
