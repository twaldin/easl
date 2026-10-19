import Foundation

// Read-modify-write client files share one queue, so a queued remember cannot undo a close's forget.
enum ClientFiles {
    private static let queue = DispatchQueue(label: "net.waldin.easl.client-files", qos: .userInitiated)

    static func read<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }

    static func enqueue(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    static func flush() async {
        try? await read {}
    }

    static func sync<T>(_ work: () throws -> T) rethrows -> T {
        try queue.sync(execute: work)
    }
}
