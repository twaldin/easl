import Darwin
import Foundation

/// The processes remote boards run on this Mac (docs/design.md "Open Remote"): ssh relays,
/// host discovery and Start easl. Each is tracked until it exits, so quitting ends them all before
/// the app exits instead of leaving a relay to notice its stdin's EOF, which an `nc` without `-N`
/// never passes on.
public final class RemoteProcesses: @unchecked Sendable {
    /// Every process this app runs for remote boards.
    public static let shared = RemoteProcesses()

    /// A launch after `terminateAll`: easl is quitting.
    struct Stopped: Error, LocalizedError {
        var errorDescription: String? { "easl is quitting" }
    }

    private final class Entry: @unchecked Sendable {
        let process: Process
        /// Entered at launch, left when the process exited.
        let exited = DispatchGroup()
        init(_ process: Process) { self.process = process }
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var stopped = false

    public init() {}

    /// Runs `process`, tracked until it exits (its own `terminationHandler`, if any, still runs).
    /// The launch is under the lock, so `terminateAll` sees every process that was started.
    func launch(_ process: Process) throws {
        let entry = Entry(process)
        let key = ObjectIdentifier(process)
        let previous = process.terminationHandler
        process.terminationHandler = { [weak self] process in
            previous?(process)
            self?.lock.withLock { self?.entries[key] = nil }
            entry.exited.leave()
        }
        try lock.withLock {
            guard !stopped else { throw Stopped() }
            entry.exited.enter()
            do {
                try process.run()
            } catch {
                entry.exited.leave()
                throw error
            }
            entries[key] = entry
        }
    }

    /// Ends every tracked process and returns once each has exited, so the app can exit right
    /// after: SIGTERM, and SIGKILL for one still running after `grace` seconds. Nothing launches
    /// after this.
    public func terminateAll(grace: TimeInterval = 2) {
        let live = lock.withLock { () -> [Entry] in
            stopped = true
            return Array(entries.values)
        }
        for entry in live where entry.process.isRunning { entry.process.terminate() }
        let deadline = DispatchTime.now() + grace
        for entry in live where entry.exited.wait(timeout: deadline) == .timedOut {
            if entry.process.isRunning { kill(entry.process.processIdentifier, SIGKILL) }
            _ = entry.exited.wait(timeout: .now() + 1)
        }
    }

    /// How many tracked processes are running.
    public var count: Int { lock.withLock { entries.count } }

    /// Ends `process` without waiting: SIGTERM, then SIGKILL after `grace` seconds if it ignored
    /// that. Whoever waits on it (or its termination handler) reaps it.
    static func stop(_ process: Process, grace: TimeInterval = 2) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        let box = UncheckedBox(process)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if box.value.isRunning { kill(pid, SIGKILL) }
        }
    }
}
