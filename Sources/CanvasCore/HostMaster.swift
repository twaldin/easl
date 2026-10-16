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

/// One tracked ssh master per exact target and app support directory, independent of easld.
@MainActor
public final class HostMaster {
    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
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
    private var master: MasterProcess?
    private var starting: Task<Void, Error>?
    private var lastError: String?
    private var closed = false

    static let maxFileSessions = 4
    private var fileSessions = 0
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var fileWaiters: [Waiter] = []

    init(route: HostRoute, processes: RemoteProcesses = .shared) {
        self.route = route
        self.processes = processes
    }

    /// Concurrent callers share one start and readiness check. A caller's cancellation does
    /// not end a master other consumers are using. Only the terminal owner retries failures.
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

    private func establish() async throws {
        try Task.checkCancellation()
        if let master, !master.process.isRunning {
            await offPool { master.drained.wait() }
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
            lastError = nil
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
        guard let live = master else { throw Failure(lastError ?? "ssh to \(route.target) exited") }
        let deadline = Date().addingTimeInterval(15)
        do {
            while true {
                try Task.checkCancellation()
                guard !closed else { throw Failure("easl is quitting") }
                guard live === master, live.process.isRunning else {
                    await offPool { live.drained.wait() }
                    ended(live)
                    throw Failure(lastError ?? live.message(target: route.target))
                }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw Failure("ssh to \(route.target) didn't connect in 15 s") }
                let check = try await RemoteHost.run(route.executable, ["-S", route.controlPath, "-O", "check", route.target], timeout: remaining)
                guard live === master, live.process.isRunning else {
                    await offPool { live.drained.wait() }
                    ended(live)
                    throw Failure(lastError ?? live.message(target: route.target))
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
        let message = live.message(target: route.target)
        lastError = message
        onEnded?(message)
    }

    public func fileSession() async throws {
        try Task.checkCancellation()
        guard !closed else { throw Failure("easl is quitting") }
        if fileSessions < Self.maxFileSessions {
            fileSessions += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    fileWaiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelFileWaiter(id) }
        }
        do {
            try Task.checkCancellation()
        } catch {
            endFileSession()
            throw error
        }
    }

    public func endFileSession() {
        precondition(fileSessions > 0)
        if !fileWaiters.isEmpty {
            fileWaiters.removeFirst().continuation.resume()
        } else {
            fileSessions -= 1
        }
    }

    private func cancelFileWaiter(_ id: UUID) {
        guard let index = fileWaiters.firstIndex(where: { $0.id == id }) else { return }
        fileWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func close() {
        closed = true
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

    func message(target: String) -> String {
        let message = String(decoding: errors.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "ssh to \(target) exited (\(process.terminationStatus))" : message
    }
}
