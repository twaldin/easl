import Foundation

/// A host's commands and the app instance's shared ssh control socket.
public struct HostRoute: Sendable, Equatable {
    public let target: String
    public let controlPath: String
    public let executable: String

    public init(target: String, support: String, executable: String = RemoteHost.ssh) {
        let key = HostedTerminal.instance(hostname: target, support: support + "\n" + target)
        self.init(target: target, controlPath: FileManager.default.temporaryDirectory.appendingPathComponent("easl-ssh-\(key)").path, executable: executable)
    }

    public init(target: String, controlPath: String, executable: String = RemoteHost.ssh) {
        self.target = target
        self.controlPath = controlPath
        self.executable = executable
    }

    public func ssh(_ command: String) -> [String] {
        HostedTerminal.sshOptions(controlPath: controlPath) + ["-o", "ControlMaster=no", "-T", target, command]
    }
}

public enum HostReadPriority: Int, Sendable {
    case background = 0
    case visible = 1
    case interactive = 2
}

/// A tracked ssh master with a separate, lazily created pool for file commands.
@MainActor
public final class HostMaster {
    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public let retryable: Bool
        public var errorDescription: String? { message }
        public init(_ message: String, retryable: Bool = false) {
            self.message = message
            self.retryable = retryable
        }
    }

    private struct Key: Hashable {
        let target: String
        let support: String
    }

    private static var hosts: [Key: HostMaster] = [:]

    public static func named(_ target: String, support: String) -> HostMaster {
        let key = Key(target: target, support: support)
        if let host = hosts[key] { return host }
        let host = HostMaster(route: HostRoute(target: target, support: support))
        hosts[key] = host
        return host
    }

    public static func closeAll() {
        for host in hosts.values { host.close() }
    }

    public nonisolated let route: HostRoute
    public var onEnded: ((String) -> Void)?

    private let processes: RemoteProcesses
    lazy var fileReads = HostFileReads()
    private let fileConcurrency: Int
    private var master: MasterProcess?
    private var starting: Task<Void, Error>?
    private var lastFailure: Failure?
    private var closed = false
    private var cachedFileReader: HostMaster?
    private var cachedHTTPReader: HostMaster?

    var fileReader: HostMaster {
        if let cachedFileReader { return cachedFileReader }
        let key = HostedTerminal.instance(hostname: "files", support: route.controlPath)
        let path = URL(fileURLWithPath: route.controlPath).deletingLastPathComponent().appendingPathComponent("easl-ssh-\(key)").path
        let reader = HostMaster(
            route: HostRoute(target: route.target, controlPath: path, executable: route.executable),
            processes: processes,
            fileConcurrency: fileConcurrency
        )
        if closed { reader.close() }
        cachedFileReader = reader
        return reader
    }
    var httpReader: HostMaster {
        if let cachedHTTPReader { return cachedHTTPReader }
        let key = HostedTerminal.instance(hostname: "http", support: route.controlPath)
        let path = URL(fileURLWithPath: route.controlPath).deletingLastPathComponent().appendingPathComponent("easl-ssh-\(key)").path
        let reader = HostMaster(
            route: HostRoute(target: route.target, controlPath: path, executable: route.executable),
            processes: processes,
            fileConcurrency: 1
        )
        if closed { reader.close() }
        cachedHTTPReader = reader
        return reader
    }

    private var fileTransports: [HostMaster] = []
    private var fileLeases: Set<Int> = []
    private struct Waiter {
        let id: UUID
        let priority: HostReadPriority
        let continuation: CheckedContinuation<HostMaster, Error>
    }
    private var fileWaiters: [Waiter] = []

    init(route: HostRoute, processes: RemoteProcesses = .shared,
         fileConcurrency: Int = Int(ProcessInfo.processInfo.environment["EASL_DEV_HOST_FILE_CONCURRENCY"] ?? "") ?? 4) {
        self.route = route
        self.processes = processes
        self.fileConcurrency = min(6, max(1, fileConcurrency))
    }

    /// Concurrent callers share one start and readiness check. A caller's cancellation does
    /// not end a master other consumers are using.
    public func ready() async throws {
        try Task.checkCancellation()
        guard !closed else { throw Failure("easl is quitting") }
        if let starting {
            try await starting.value
        } else {
            let task = Task { try await self.establish() }
            starting = task
            defer { starting = nil }
            try await task.value
        }
        try Task.checkCancellation()
    }

    func interruption() throws -> @Sendable () -> Void {
        guard !closed else { throw Failure("easl is quitting") }
        guard let master else {
            throw lastFailure ?? Failure("ssh to \(route.target) exited")
        }
        return { master.interrupt() }
    }

    private func establish() async throws {
        try Task.checkCancellation()
        if let master, master.interrupted.withLock({ $0 }) || !master.process.isRunning {
            await offPool { master.process.waitUntilExit(); master.drained.wait() }
            ended(master)
        }
        if master == nil {
            _ = try await RemoteHost.run(route.executable, ["-S", route.controlPath, "-O", "exit", route.target], timeout: 3)
            try Task.checkCancellation()
            guard !closed else { throw Failure("easl is quitting") }
            let live = MasterProcess()
            let process = live.process
            process.executableURL = URL(fileURLWithPath: route.executable)
            process.arguments = HostedTerminal.sshOptions(controlPath: route.controlPath) + ["-M", "-N", "-o", "ControlPersist=no", "-o", "ExitOnForwardFailure=no", route.target]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            process.terminationHandler = { [weak self, weak live] _ in
                guard let live else { return }
                live.drained.wait()
                Task { @MainActor [weak self] in self?.ended(live) }
            }
            live.drained.enter()
            do {
                try processes.launch(process)
            } catch {
                live.drained.leave()
                throw Failure("ssh didn't start: \(error.localizedDescription)")
            }
            master = live
            lastFailure = nil
            DispatchQueue.global().async {
                let reader = errors.fileHandleForReading
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    live.errors.withLock {
                        $0.append(chunk)
                        if $0.count > 8192 { $0.removeFirst($0.count - 8192) }
                    }
                }
                live.drained.leave()
            }
        }
        guard let live = master else { throw lastFailure ?? Failure("ssh to \(route.target) exited") }
        let deadline = Date().addingTimeInterval(15)
        do {
            while true {
                try Task.checkCancellation()
                guard !closed else { throw Failure("easl is quitting") }
                guard live === master, live.process.isRunning else {
                    await offPool { live.drained.wait() }
                    ended(live)
                    throw lastFailure ?? live.failure(target: route.target)
                }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw Failure("ssh to \(route.target) didn't connect in 15 s") }
                let check = try await RemoteHost.run(route.executable, ["-S", route.controlPath, "-O", "check", route.target], timeout: remaining)
                guard live === master, live.process.isRunning else {
                    await offPool { live.drained.wait() }
                    ended(live)
                    throw lastFailure ?? live.failure(target: route.target)
                }
                if check.status == 0 { return }
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch {
            if live === master {
                RemoteProcesses.stop(live.process)
                await offPool { live.process.waitUntilExit(); live.drained.wait() }
                ended(live)
            }
            throw error
        }
    }

    private func ended(_ live: MasterProcess) {
        guard live === master else { return }
        master = nil
        let failure = live.failure(target: route.target)
        lastFailure = failure
        if live.process.terminationStatus != 0 {
            NSLog("easl: ssh master for %@ exited (status %d): %@", route.target, live.process.terminationStatus,
                  String(decoding: live.errors.withLock { $0 }, as: UTF8.self))
        }
        onEnded?(failure.message)
    }

    public func fileSession(priority: HostReadPriority = .visible) async throws -> HostMaster {
        try Task.checkCancellation()
        guard !closed else { throw Failure("easl is quitting") }
        if let slot = (0..<fileConcurrency).first(where: { !fileLeases.contains($0) }) {
            fileLeases.insert(slot)
            return fileTransport(slot)
        }
        let id = UUID()
        let transport = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HostMaster, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    let waiter = Waiter(id: id, priority: priority, continuation: continuation)
                    let index = fileWaiters.firstIndex { $0.priority.rawValue < priority.rawValue } ?? fileWaiters.endIndex
                    fileWaiters.insert(waiter, at: index)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelFileWaiter(id) }
        }
        do {
            try Task.checkCancellation()
            guard !closed else { throw Failure("easl is quitting") }
        } catch {
            endFileSession(transport)
            throw error
        }
        return transport
    }

    public func endFileSession(_ transport: HostMaster) {
        let slot: Int
        if transport === self {
            slot = 0
        } else {
            guard let index = fileTransports.firstIndex(where: { $0 === transport }) else {
                preconditionFailure("file transport belongs to another master")
            }
            slot = index + 1
        }
        precondition(fileLeases.contains(slot), "file transport is not leased")
        if !closed, !fileWaiters.isEmpty {
            fileWaiters.removeFirst().continuation.resume(returning: transport)
        } else {
            fileLeases.remove(slot)
        }
    }

    private func fileTransport(_ slot: Int) -> HostMaster {
        if slot == 0 { return self }
        if slot > fileTransports.count {
            let key = HostedTerminal.instance(hostname: "files-\(slot)", support: route.controlPath)
            let path = URL(fileURLWithPath: route.controlPath).deletingLastPathComponent().appendingPathComponent("easl-ssh-\(key)").path
            fileTransports.append(HostMaster(
                route: HostRoute(target: route.target, controlPath: path, executable: route.executable),
                processes: processes,
                fileConcurrency: 1
            ))
        }
        return fileTransports[slot - 1]
    }

    private func cancelFileWaiter(_ id: UUID) {
        guard let index = fileWaiters.firstIndex(where: { $0.id == id }) else { return }
        fileWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func close() {
        closed = true
        cachedFileReader?.close()
        cachedHTTPReader?.close()
        for transport in fileTransports { transport.close() }
        starting?.cancel()
        if let master { RemoteProcesses.stop(master.process) }
        let waiting = fileWaiters
        fileWaiters.removeAll()
        for waiter in waiting { waiter.continuation.resume(throwing: Failure("easl is quitting")) }
    }
}

private final class MasterProcess: @unchecked Sendable {
    let process = Process()
    let errors = Locked(Data())
    let drained = DispatchGroup()
    let interrupted = Locked(false)

    func interrupt() {
        interrupted.withLock {
            guard !$0 else { return }
            $0 = true
            RemoteProcesses.stop(process)
        }
    }

    func failure(target: String) -> HostMaster.Failure {
        let raw = String(decoding: errors.withLock { $0 }, as: UTF8.self)
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = process.terminationStatus
        let reason = message.isEmpty
            ? (status == 255 ? "the SSH connection to \(target) ended unexpectedly" : "ssh to \(target) exited (\(status))")
            : message
        return HostMaster.Failure(reason, retryable: HostFiles.retryableSSHFailure(status: status, errors: raw))
    }
}
