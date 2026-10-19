import Foundation

public enum GitError: Error, Equatable, Sendable {
    case launch(String)
    case failed(status: Int32, stderr: String)
    /// stdout passed the caller's `maxOutput`; git was stopped.
    case outputTooLarge
    /// git ran past the caller's `timeout`; it was stopped.
    case timedOut
}

/// Runs git with an app-wide cap on concurrent processes (docs/design.md, Performance). Every
/// git invocation in the app goes through `shared`.
///
/// Cancelling the calling task drops a request still waiting for a slot and stops a running git
/// (throwing `CancellationError`), so work for tiles that went away doesn't hold the cap.
public actor GitRunner {
    public static let shared = GitRunner(limit: 2)
    /// stderr past this is dropped; it only feeds error messages.
    static let maxDiagnostics = 16 << 10

    private typealias Waiter = (id: UInt64, continuation: CheckedContinuation<Void, Error>)
    private let limit: Int
    private var running = 0
    private var waiting: [Waiter] = []
    private var nextWaiter: UInt64 = 0

    public init(limit: Int) {
        self.limit = limit
    }

    /// stdout of `git <args>` run in `directory`, with `input` on its stdin (none by default).
    /// Exit codes outside `allowedStatus` throw `GitError.failed` with git's stderr; more than
    /// `maxOutput` bytes of stdout stops git and throws `GitError.outputTooLarge`; running past
    /// `timeout` stops git and throws `GitError.timedOut`.
    public func run(_ args: [String], in directory: URL, input: Data? = nil, allowedStatus: Set<Int32> = [0], maxOutput: Int = .max, timeout: TimeInterval? = nil) async throws -> Data {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let request = Request()
        let result = try await withTaskCancellationHandler {
            try await Self.spawn(args, in: directory, input: input, maxOutput: maxOutput, timeout: timeout, request: request)
        } onCancel: {
            request.cancel()
        }
        guard allowedStatus.contains(result.status) else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.failed(status: result.status, stderr: message)
        }
        return result.stdout
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = nextWaiter
        nextWaiter += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    /// A cancelled waiter leaves the queue without ever holding a slot.
    private func abandon(_ id: UInt64) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Hands the slot straight to the next waiter so a burst can't overshoot the cap.
    private func release() {
        if !waiting.isEmpty {
            waiting.removeFirst().continuation.resume()
        } else {
            running -= 1
        }
    }

    /// One git process: cancellation and the timeout stop it; both are checked once it exits.
    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var finished = false
        private(set) var cancelled = false
        private(set) var expired = false

        /// false when the request was cancelled before git started.
        func attach(_ process: Process) -> Bool {
            lock.withLock {
                self.process = process
                return !cancelled
            }
        }

        func cancel() { stop { $0.cancelled = true } }
        func expire() { stop { $0.expired = true } }

        private func stop(_ mark: (Request) -> Void) {
            lock.withLock {
                guard !finished else { return }
                mark(self)
                if let process, process.isRunning { process.terminate() }
            }
        }

        func finish() -> (cancelled: Bool, expired: Bool) {
            lock.withLock {
                finished = true
                return (cancelled, expired)
            }
        }
    }

    private final class Diagnostics: @unchecked Sendable {
        var data = Data()
    }

    private static func spawn(_ args: [String], in directory: URL, input: Data?, maxOutput: Int, timeout: TimeInterval?, request: Request) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                // Paths print verbatim; no pager, prompts, or optional index locks that would
                // contend with the agents working in the same repository.
                process.arguments = ["-c", "core.quotepath=off", "--no-pager"] + args
                process.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                environment["GIT_OPTIONAL_LOCKS"] = "0"
                environment["GIT_TERMINAL_PROMPT"] = "0"
                // easl reads what the repository has and never goes to the network: a partial
                // clone's missing blob is missing, not fetched behind the user's back.
                environment["GIT_NO_LAZY_FETCH"] = "1"
                process.environment = environment
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                let stdin = input.map { _ in Pipe() }
                process.standardInput = stdin ?? FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: GitError.launch(error.localizedDescription))
                    return
                }
                if let stdin, let input {
                    // A git that exits early must fail the write with EPIPE, not kill the app.
                    let writer = stdin.fileHandleForWriting
                    _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? writer.write(contentsOf: input)
                        try? writer.close()
                    }
                }
                if !request.attach(process) { process.terminate() }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { request.expire() }
                }
                // Drain stderr alongside stdout so neither pipe can fill up and stall git.
                let diagnostics = Diagnostics()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let reader = stderr.fileHandleForReading
                    while true {
                        let chunk = reader.availableData
                        if chunk.isEmpty { break }
                        if diagnostics.data.count < maxDiagnostics { diagnostics.data.append(chunk.prefix(maxDiagnostics - diagnostics.data.count)) }
                    }
                    group.leave()
                }
                var data = Data()
                var overflow = false
                let reader = stdout.fileHandleForReading
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    if overflow { continue }
                    data.append(chunk)
                    if data.count > maxOutput {
                        overflow = true
                        data = Data()
                        process.terminate()
                    }
                }
                group.wait()
                process.waitUntilExit()
                let stopped = request.finish()
                if stopped.cancelled {
                    continuation.resume(throwing: CancellationError())
                } else if stopped.expired {
                    continuation.resume(throwing: GitError.timedOut)
                } else if overflow {
                    continuation.resume(throwing: GitError.outputTooLarge)
                } else {
                    continuation.resume(returning: (process.terminationStatus, data, diagnostics.data))
                }
            }
        }
    }
}

/// Runs blocking work (file reads, parsing large files) on GCD rather than a Swift concurrency
/// thread: the cooperative pool is only as wide as the core count, and parking it starves the
/// socket servers' request tasks.
public func offPool<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: qos).async { continuation.resume(returning: work()) }
    }
}
