import Darwin
import Foundation

struct LSPLaunch: Sendable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var directory: URL?
    var name: String
    var remote: Bool
}

/// One language-server process speaking JSON-RPC 2.0 over stdio. Thread-safe: requests may come
/// from any task; responses arrive on the pipe's reader thread and resume the waiting request.
final class LSPConnection: @unchecked Sendable {
    /// Called once with the connection and a human-readable reason (status, last stderr line).
    typealias Exit = @Sendable (_ connection: LSPConnection, _ reason: String) -> Void

    /// Queued-but-unwritten bytes beyond which a server that stopped reading counts as hung.
    static let maxQueuedBytes = 64 << 20

    let process = Process()
    let launch: LSPLaunch
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let onExit: Exit

    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    /// Each pending request's timeout, cancelled when it is answered or abandoned.
    private var timeouts: [Int: DispatchWorkItem] = [:]
    private var exitWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var exited = false
    private var exitReason = ""
    private var hostProcess: Int32?
    /// Work-done progress in flight (token → title), e.g. sourcekit-lsp's "Indexing".
    private var progress: [String: String] = [:]
    /// Last bytes of stderr, for the crash message. Only touched on the stderr reader thread and at exit.
    private var stderrTail = Data()
    /// Only touched on the stdout reader thread.
    private var framer = LSPFramer()
    /// Writes go through a stream channel so callers (including cancellation on the main actor
    /// and app quit) never block on a full pipe. Only set in `start`.
    private var writer: DispatchIO?
    private let writeQueue = DispatchQueue(label: "canvas.lsp.write")
    private var queuedBytes = 0

    fileprivate init(_ launch: LSPLaunch, onExit: @escaping Exit) {
        self.launch = launch
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.environment = launch.environment
        if let directory = launch.directory { process.currentDirectoryURL = directory }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        self.onExit = onExit
    }

    var pid: Int32 { process.processIdentifier }

    var serverPID: Int32? { launch.remote ? lock.withLock { hostProcess } : pid }

    fileprivate func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.receive(chunk)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else {
                if chunk.isEmpty { handle.readabilityHandler = nil }
                return
            }
            // Servers log freely to stderr; it must be drained or the server blocks on a full pipe.
            self.lock.withLock {
                self.stderrTail.append(chunk)
                if self.stderrTail.count > 4096 { self.stderrTail.removeFirst(self.stderrTail.count - 4096) }
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.didExit(process.terminationStatus)
        }
        try process.run()
        // The channel owns a duplicate of the pipe's write end; closing the original leaves the
        // channel as the only writer, so the server sees EOF once it closes.
        let fd = dup(input.fileHandleForWriting.fileDescriptor)
        try? input.fileHandleForWriting.close()
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        // A write to a server that just died must fail with EPIPE, not kill the app.
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: writeQueue) { _ in close(fd) }
        lock.withLock { writer = channel }
    }

    // MARK: Sending

    func request(_ method: String, _ params: JSONValue, timeout: Duration? = nil) async throws -> JSONValue {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let expiry = timeout.map { _ in DispatchWorkItem { [weak self] in self?.abandon(id, with: LSPError.timedOut(method)) } }
                let refusal: Error? = lock.withLock {
                    if exited { return LSPError.serverExited(exitReason) }
                    if Task.isCancelled { return CancellationError() }
                    pending[id] = continuation
                    timeouts[id] = expiry
                    return nil
                }
                if let refusal { return continuation.resume(throwing: refusal) }
                if let timeout, let expiry { DispatchQueue.global().asyncAfter(deadline: .now() + timeout.seconds, execute: expiry) }
                send(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params]))
            }
        } onCancel: {
            abandon(id, with: CancellationError())
        }
    }

    func notify(_ method: String, _ params: JSONValue?) {
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { message["params"] = params }
        send(.object(message))
    }

    /// Fails a pending request and tells the server to stop working on it.
    private func abandon(_ id: Int, with error: Error) {
        guard let continuation = take(id) else { return }
        continuation.resume(throwing: error)
        notify("$/cancelRequest", .object(["id": .number(Double(id))]))
    }

    /// The request waiting on `id`, no longer pending; its timeout goes with it.
    private func take(_ id: Int) -> CheckedContinuation<JSONValue, Error>? {
        lock.withLock {
            timeouts.removeValue(forKey: id)?.cancel()
            return pending.removeValue(forKey: id)
        }
    }

    /// Queues a message; never blocks. EPIPE and friends surface through the exit handler.
    private func send(_ message: JSONValue) {
        guard let body = try? JSONEncoder().encode(message) else { return }
        let data = LSPFramer.frame(body)
        let (channel, backlog) = lock.withLock {
            queuedBytes += data.count
            return (exited ? nil : writer, queuedBytes)
        }
        guard let channel else { return }
        guard backlog <= Self.maxQueuedBytes else { return kill() }
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: bytes, queue: writeQueue) { [weak self] done, _, _ in
            guard done, let self else { return }
            self.lock.withLock { self.queuedBytes -= data.count }
        }
    }

    // MARK: Receiving

    private func receive(_ chunk: Data) {
        let bodies: [Data]
        do {
            bodies = try framer.append(chunk)
        } catch {
            // A desynchronized stream can't be trusted again; the exit handler reports it.
            terminate()
            return
        }
        for body in bodies {
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: body) else { continue }
            let method = message["method"]?.string
            if let id = message["id"], id != .null, let method {
                answer(id: id, method: method, params: message["params"])
            } else if method == "$/progress" {
                track(message["params"])
            } else if method == "easl/hostProcess", launch.remote, let pid = message["params"]?["pid"]?.int {
                lock.withLock { hostProcess = hostProcess ?? Int32(clamping: pid) }
            } else if let id = message["id"]?.int {
                guard let continuation = take(id) else { continue }
                if let error = message["error"] {
                    continuation.resume(throwing: LSPError.response(code: error["code"]?.int ?? 0, message: error["message"]?.string ?? "error"))
                } else {
                    continuation.resume(returning: message["result"] ?? .null)
                }
            }
        }
    }

    private func track(_ params: JSONValue?) {
        guard let token = params?["token"]?.string ?? params?["token"]?.int.map(String.init), let value = params?["value"] else { return }
        lock.withLock {
            switch value["kind"]?.string {
            case "begin": progress[token] = value["title"]?.string ?? "Working"
            case "end": progress[token] = nil
            default: break
            }
        }
    }

    /// Titles of the server's background work in progress, e.g. ["Indexing"].
    var activity: [String] { lock.withLock { progress.values.sorted() } }

    /// Server-to-client requests. easl has no settings to offer and never applies edits, but
    /// servers wait on these answers, so every request gets one.
    private func answer(id: JSONValue, method: String, params: JSONValue?) {
        var reply: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": id]
        switch method {
        case "workspace/configuration":
            reply["result"] = .array(Array(repeating: .null, count: params?["items"]?.array?.count ?? 0))
        case "workspace/applyEdit":
            reply["result"] = .object(["applied": .bool(false)])
        case "window/workDoneProgress/create", "client/registerCapability", "client/unregisterCapability",
             "window/showMessageRequest", "workspace/semanticTokens/refresh", "workspace/inlayHint/refresh",
             "workspace/codeLens/refresh", "workspace/diagnostic/refresh":
            reply["result"] = .null
        case "workspace/workspaceFolders":
            reply["result"] = .null
        default:
            reply["error"] = .object(["code": .number(-32601), "message": .string("\(method) is not supported")])
        }
        send(.object(reply))
    }

    // MARK: Exit

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    /// SIGTERM, then SIGKILL once `grace` has passed; returns when the process has been reaped
    /// (or a second after SIGKILL, which can't be ignored).
    func terminate(grace: Duration) async {
        terminate()
        if await waitForExit(timeout: grace) { return }
        kill()
        _ = await waitForExit(timeout: .seconds(1))
    }

    /// True once the process has exited; false if `timeout` passed first.
    func waitForExit(timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let id = UUID()
            let done = lock.withLock {
                if exited { return true }
                exitWaiters[id] = continuation
                return false
            }
            if done { return continuation.resume(returning: true) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.seconds) { [weak self] in
                self?.lock.withLock { self?.exitWaiters.removeValue(forKey: id) }?.resume(returning: false)
            }
        }
    }

    private func didExit(_ status: Int32) {
        let name = launch.name
        let (requests, waiters, reason) = lock.withLock {
            let tail = String(decoding: stderrTail, as: UTF8.self)
            let lastLine = tail.split(whereSeparator: \.isNewline).last.map { ": \($0)" } ?? ""
            exited = true
            exitReason = "\(name) exited with status \(status)\(lastLine)"
            let taken = (Array(pending.values), Array(exitWaiters.values), exitReason)
            pending.removeAll()
            timeouts.values.forEach { $0.cancel() }
            timeouts.removeAll()
            exitWaiters.removeAll()
            writer?.close(flags: .stop)
            return taken
        }
        for request in requests { request.resume(throwing: LSPError.serverExited(reason)) }
        for waiter in waiters { waiter.resume(returning: true) }
        onExit(self, reason)
    }
}

/// Every server process that has been spawned and not yet reaped, reachable without the actors
/// so app quit can end them.
final class LiveConnections: @unchecked Sendable {
    private let source: any LanguageSource
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: (connection: LSPConnection, binary: ServerBinary)] = [:]
    private var closed = false

    init(source: any LanguageSource) {
        self.source = source
    }

    /// Admission, spawn and registration share the quit snapshot's lock.
    func start(_ launch: LSPLaunch, binary: ServerBinary, onExit: @escaping LSPConnection.Exit) throws -> LSPConnection {
        try lock.withLock {
            guard !closed else { throw RemoteProcesses.Stopped() }
            let connection = LSPConnection(launch, onExit: onExit)
            do {
                try connection.start()
            } catch {
                connection.kill()
                throw error
            }
            connections[ObjectIdentifier(connection)] = (connection, binary)
            return connection
        }
    }

    func remove(_ connection: LSPConnection) {
        lock.withLock { _ = connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    func terminateAll(grace: Duration) async {
        let all = lock.withLock {
            closed = true
            return Array(connections.values)
        }
        await withTaskGroup(of: Void.self) { group in
            for (connection, binary) in all {
                group.addTask {
                    connection.notify("exit", nil)
                    if connection.launch.remote {
                        if await !connection.waitForExit(timeout: grace) { await connection.terminate(grace: .seconds(1)) }
                        if let pid = connection.serverPID { await self.source.reap(pid, binary: binary) }
                    } else {
                        await connection.terminate(grace: grace)
                    }
                    self.remove(connection)
                }
            }
        }
    }
}

extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
