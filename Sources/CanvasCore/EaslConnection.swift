import Darwin
import Foundation

/// One client connection to an easl server's JSON-lines API (docs/contracts.md "Client
/// connection"): requests answered by id, plus the `events.subscribe` stream, over a Unix socket
/// or a relay process's stdio (`ssh -T <host> nc -U <socket>`, `RemoteHost.connection`).
///
/// It connects as soon as it is made and stays connected: when the link drops (the relay exits,
/// the app on the other end quits, the network goes) it reconnects with backoff, re-subscribes,
/// and publishes each `State`. A link counts as `online` once the server answered `system.ping`
/// and every subscription was acknowledged, so a consumer that re-reads on `online` (`board.get`)
/// misses no event. Events sent while offline are not replayed.
///
/// Requests made while `connecting` wait for it; while `offline` they fail at once with
/// `unavailable`. A request whose link dropped after it was written fails `unavailable` too and
/// is never resent: it may or may not have applied. One link carries every request in order (the
/// app answers a connection's requests one at a time), so a long `agent.wait` holds up the rest.
///
/// The server's own calls on the link (`{id: "easld-<n>", method, params}`, docs/design/next.md
/// "Framing": an easld this viewer attached to as its client) go to `serve`'s handler, each in a
/// task of its own, and each answer goes back with the call's id on the link it came on. What
/// answering a call starts (a browser tile's stream) pushes its events on that same link, through
/// the call's `origin`, and nowhere once that link is gone.
///
/// Thread-safe; every link callback runs on one serial queue.
public final class EaslConnection: @unchecked Sendable {
    public enum State: String, Sendable {
        case connecting, online, offline
    }

    /// One `events.subscribe` message: `{event, board, data}`.
    public struct Event: Sendable, Equatable {
        public var name: String
        public var board: BoardID?
        public var data: JSONValue
        var sequence: UInt64 = 0

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name == rhs.name && lhs.board == rhs.board && lhs.data == rhs.data
        }

        public init(name: String, board: BoardID?, data: JSONValue) {
            self.name = name
            self.board = board
            self.data = data
        }
    }

    /// A failed request: the server's `{code, message, data}`, or `unavailable` / `timeout`
    /// from the connection itself.
    public struct Failure: Error, Sendable, Equatable, CustomStringConvertible {
        public var code: String
        public var message: String
        public var data: JSONValue?
        public var isHostResponse: Bool

        public init(_ code: String, _ message: String, data: JSONValue? = nil, isHostResponse: Bool = false) {
            self.code = code
            self.message = message
            self.data = data
            self.isHostResponse = isHostResponse
        }

        public var description: String { "\(code): \(message)" }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.code == rhs.code && lhs.message == rhs.message && lhs.data == rhs.data
        }
    }

    /// A request the server sent on this link: one of `client.attach`'s delegated calls.
    public struct Call: Sendable {
        public var method: String
        public var params: JSONValue
        /// The link the call came on: what answering it starts may push events there
        /// (`Origin.push`), only while that link lasts.
        public let origin: Origin
        /// The surface events the viewer of a relayed `surface.stream` hears on the tile's board
        /// (`surfaceEvents`, beside the call's params): which of its stream's private events it
        /// may be sent. Empty on any other call, and when easld named none.
        public let surfaceEvents: Set<String>
        var eventsThrough: UInt64 = 0

        /// A call that came on no link (tests): its origin is closed.
        public init(method: String, params: JSONValue, surfaceEvents: Set<String> = []) {
            self.init(method: method, params: params, origin: Origin(), surfaceEvents: surfaceEvents)
        }

        init(method: String, params: JSONValue, origin: Origin, surfaceEvents: Set<String>) {
            self.method = method
            self.params = params
            self.origin = origin
            self.surfaceEvents = surfaceEvents
        }
    }

    /// One link of this connection, as a call that came on it knows it. A push goes out on that
    /// link behind what it already queued, or nowhere once the link is gone: a reconnect is a new
    /// link and a new origin, so nothing encoded for an old link reaches the server on the next.
    public struct Origin: Sendable, Hashable {
        private let link: Link?
        private weak var connection: EaslConnection?

        /// No link: closed from the start.
        init() {
            link = nil
            connection = nil
        }

        fileprivate init(_ link: Link, on connection: EaslConnection) {
            self.link = link
            self.connection = connection
        }

        /// False once that link dropped or the connection closed.
        public var isOpen: Bool { link?.isLive == true }

        /// Queues `line` on that link; false, and dropped, once the link is gone. Any thread.
        /// `whileCurrent` may cancel an event until its first byte is written.
        @discardableResult
        public func push(_ line: EventLine, whileCurrent: (@Sendable () -> Bool)? = nil) -> Bool {
            guard let link, link.isLive, let connection else { return false }
            connection.queue.async {
                guard connection.link === link, whileCurrent?() != false else { return }
                for index in link.outboxHead..<link.outbox.count {
                    if index == link.outboxHead, link.written > 0 { continue }
                    if link.outbox[index].whileCurrent?() == false {
                        link.pendingBytes -= link.outbox[index].data.count
                        link.outbox[index] = Link.Output(data: Data(), whileCurrent: nil)
                    }
                }
                connection.write(line.data, on: link, whileCurrent: whileCurrent)
            }
            return true
        }

        public static func == (lhs: Origin, rhs: Origin) -> Bool { lhs.link === rhs.link }

        public func hash(into hasher: inout Hasher) { hasher.combine(link.map { ObjectIdentifier($0) }) }
    }

    /// Waits between attempts: `initial`, doubling after each failed one, at most `maximum`;
    /// back to `initial` once a link came online.
    public struct Backoff: Sendable {
        public var initial: Duration
        public var maximum: Duration

        public init(initial: Duration, maximum: Duration) {
            self.initial = initial
            self.maximum = maximum
        }

        public static let standard = Backoff(initial: .milliseconds(500), maximum: .seconds(30))

        /// The wait after `failures` failed attempts in a row (1 or more).
        public func delay(after failures: Int) -> Duration {
            let doubled = initial.seconds * pow(2, Double(max(0, min(failures - 1, 30))))
            return .milliseconds(Int(min(doubled, maximum.seconds) * 1000))
        }
    }

    public enum Transport: Sendable {
        case unixSocket(String)
        /// A relay: the process's stdin and stdout are the connection, its stderr says why it
        /// ended. `environment` nil inherits this process's.
        case process(executable: String, arguments: [String], environment: [String: String]?)
    }

    public let transport: Transport
    public let backoff: Backoff
    /// How long a new link may take to answer `system.ping` and its subscriptions.
    public let handshakeTimeout: Duration
    /// Where relay processes are tracked, so quitting can end them (`RemoteProcesses.terminateAll`).
    private let processes: RemoteProcesses

    public static func unixSocket(_ path: String, backoff: Backoff = .standard, handshakeTimeout: Duration = .seconds(10)) -> EaslConnection {
        EaslConnection(.unixSocket(path), backoff: backoff, handshakeTimeout: handshakeTimeout)
    }

    public static func process(_ executable: String, _ arguments: [String], _ environment: [String: String]? = nil,
                               backoff: Backoff = .standard, handshakeTimeout: Duration = .seconds(20), processes: RemoteProcesses = .shared) -> EaslConnection {
        EaslConnection(.process(executable: executable, arguments: arguments, environment: environment), backoff: backoff, handshakeTimeout: handshakeTimeout, processes: processes)
    }

    public init(_ transport: Transport, backoff: Backoff = .standard, handshakeTimeout: Duration = .seconds(20), processes: RemoteProcesses = .shared) {
        self.transport = transport
        self.backoff = backoff
        self.handshakeTimeout = handshakeTimeout
        self.processes = processes
        queue.async { self.attempt() }
    }

    deinit {
        link?.tearDown()
        retry?.cancel()
    }

    // MARK: Observing

    /// The current state.
    public var state: State { queue.sync { current } }

    public var schemaVersion: Int? { queue.sync { advertisedSchemaVersion } }

    /// Why the connection isn't online, for the user: the relay's last stderr line (ssh's
    /// "Connection refused", nc's "No such file or directory"), a refused connect, a silent
    /// server. Nil while online.
    public var problem: String? { queue.sync { reason } }

    /// The relay's exit status when the last link ended with its exit; nil for a socket, or a
    /// relay that was still running (a silent server). ssh exits 255 when it couldn't reach or
    /// log in to the host; another status is the remote command's (`nc` finding no easl socket
    /// there exits 1).
    public var relayStatus: Int32? { queue.sync { relayExit } }

    /// The current state, then every change, until `close`.
    public func states() -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream.makeStream(of: State.self)
        let key = UUID()
        continuation.onTermination = { [weak self] _ in self?.queue.async { self?.stateWatchers[key] = nil } }
        queue.async {
            continuation.yield(self.current)
            if self.closed { continuation.finish() } else { self.stateWatchers[key] = continuation }
        }
        return stream
    }

    /// Every event of the connection's subscriptions from now on, until `close`.
    public func events() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        let key = UUID()
        continuation.onTermination = { [weak self] _ in self?.queue.async { self?.eventWatchers[key] = nil } }
        queue.async {
            if self.closed { continuation.finish() } else { self.eventWatchers[key] = continuation }
        }
        return stream
    }

    /// Subscribes to `board`'s events (nil: every board), only those named in `events` (nil:
    /// all), on this link and on every link after it. Each call adds a subscription, and the
    /// server sends an event once per subscription it matches.
    public func subscribe(board: BoardID? = nil, events: [String]? = nil) {
        var params: [String: JSONValue] = [:]
        if let board { params["board"] = .string(board) }
        if let events { params["events"] = .array(events.map(JSONValue.string)) }
        queue.async {
            self.subscriptions.append(.object(params))
            // A link not yet online takes it as part of its handshake, so `online` still means
            // subscribed; a link still to come sends it with the rest.
            guard let link = self.link else { return }
            let id = self.nextHandshakeID()
            if self.current != .online { self.handshake.insert(id) }
            self.write(self.line(id: id, method: "events.subscribe", params: .object(params)), on: link)
        }
    }

    // MARK: Requests

    /// Sends `method` and returns its `result`; throws `Failure` with the server's error, or
    /// `unavailable` (offline, or the link dropped before the reply) or `timeout`.
    public func request(_ method: String, _ params: JSONValue = .object([:]), timeout: Duration? = nil) async throws -> JSONValue {
        let id = ids.withLock { value -> Int in
            value += 1
            return value
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.enqueue(id, method, params, timeout, continuation) }
            }
        } onCancel: {
            queue.async { self.finish(id, .failure(CancellationError())) }
        }
    }

    /// Tries now instead of waiting out the backoff (the user started easl on the host).
    public func reconnect() {
        queue.async {
            guard !self.closed, self.link == nil else { return }
            self.retry?.cancel()
            self.retry = nil
            self.attempt()
        }
    }

    /// Answers the server's calls with `handler` from now on (nil: each fails `unavailable`). Each
    /// runs in a task of its own, so a slow one holds up neither the others nor this link's own
    /// requests and events. An answer goes back on the link its call came on, or nowhere once that
    /// link is gone: the server answered its caller then, and a new link's ids start again.
    public func serve(_ handler: (@Sendable (Call) async -> Result<JSONValue, Failure>)?) {
        queue.async { self.server = handler }
    }

    /// Ends the link and every request, and stops reconnecting. The state ends `offline`, and
    /// `states()` and `events()` finish.
    public func close() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.retry?.cancel()
            self.retry = nil
            self.link?.tearDown()
            self.link = nil
            self.handshake = []
            self.handshakePing = nil
            self.advertisedSchemaVersion = nil
            self.handshakeTimer?.cancel()
            self.failAll(Failure("unavailable", "the connection was closed"))
            self.reason = "closed"
            self.publish(.offline)
            self.stateWatchers.values.forEach { $0.finish() }
            self.eventWatchers.values.forEach { $0.finish() }
            self.stateWatchers = [:]
            self.eventWatchers = [:]
        }
    }

    // MARK: State (all on `queue`)

    private let queue = DispatchQueue(label: "easl.connection")
    private let ids = Locked(0)
    private var current: State = .connecting
    private var reason: String?
    private var relayExit: Int32?
    private var closed = false
    private var link: Link?
    private var generation = 0
    /// Failed attempts since the last link that came online.
    private var failures = 0
    private var retry: DispatchWorkItem?
    private var subscriptions: [JSONValue] = []
    /// The current link's handshake requests not answered yet; online when empty.
    private var handshake: Set<Int> = []
    private var handshakePing: Int?
    private var advertisedSchemaVersion: Int?
    private var handshakeTimer: DispatchWorkItem?
    /// Handshake ids count down from -1, apart from requests' ids.
    private var handshakeIDs = 0
    private var pending: [Int: Pending] = [:]
    /// Requests waiting for the link to come online, oldest first.
    private var queued: [Int] = []
    /// Requests cancelled before they were enqueued.
    private var cancelled: Set<Int> = []
    private var stateWatchers: [UUID: AsyncStream<State>.Continuation] = [:]
    private var eventWatchers: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var eventSequence: UInt64 = 0
    /// What answers the server's calls (`serve`).
    private var server: (@Sendable (Call) async -> Result<JSONValue, Failure>)?

    private struct Pending {
        var method: String
        var line: Data
        var continuation: CheckedContinuation<JSONValue, Error>
        var timer: DispatchWorkItem?
        /// The link generation it was written on; nil while queued.
        var sentOn: Int?
    }

    private func publish(_ state: State) {
        guard current != state else { return }
        current = state
        for watcher in stateWatchers.values { watcher.yield(state) }
    }

    private func nextHandshakeID() -> Int {
        handshakeIDs -= 1
        return handshakeIDs
    }

    private func line(id: Int, method: String, params: JSONValue) -> Data {
        // The schema's ids are strings.
        let message: JSONValue = .object(["id": .string(String(id)), "method": .string(method), "params": params])
        return ((try? JSONEncoder().encode(message)) ?? Data()) + [0x0A]
    }

    /// The answer to the server's call `id`: `{id, ok: true, result}` or `{id, ok: false, error}`.
    private static func answerLine(id: String, _ answer: Result<JSONValue, Failure>) -> Data {
        var message: [String: JSONValue] = ["id": .string(id)]
        switch answer {
        case .success(let result):
            message["ok"] = .bool(true)
            message["result"] = result
        case .failure(let failure):
            var error: [String: JSONValue] = ["code": .string(failure.code), "message": .string(failure.message)]
            if let data = failure.data { error["data"] = data }
            message["ok"] = .bool(false)
            message["error"] = .object(error)
        }
        return ((try? JSONEncoder().encode(JSONValue.object(message))) ?? Data()) + [0x0A]
    }

    private func enqueue(_ id: Int, _ method: String, _ params: JSONValue, _ timeout: Duration?, _ continuation: CheckedContinuation<JSONValue, Error>) {
        if cancelled.remove(id) != nil { return continuation.resume(throwing: CancellationError()) }
        if closed { return continuation.resume(throwing: Failure("unavailable", "the connection was closed (\(method) was not sent)")) }
        if current == .offline {
            return continuation.resume(throwing: Failure("unavailable", "\(reason ?? "offline") (\(method) was not sent)"))
        }
        var request = Pending(method: method, line: line(id: id, method: method, params: params), continuation: continuation)
        if let timeout {
            let timer = DispatchWorkItem { [weak self] in
                self?.finish(id, .failure(Failure("timeout", "\(method) timed out after \(timeout.seconds)s")))
            }
            request.timer = timer
            queue.asyncAfter(deadline: .now() + timeout.seconds, execute: timer)
        }
        if current == .online, let link {
            request.sentOn = link.generation
            pending[id] = request
            write(request.line, on: link)
        } else {
            pending[id] = request
            queued.append(id)
        }
    }

    /// Resolves request `id` once; a later answer, timeout or cancellation finds nothing.
    private func finish(_ id: Int, _ result: Result<JSONValue, Error>) {
        guard let request = pending.removeValue(forKey: id) else {
            if case .failure(let error) = result, error is CancellationError { cancelled.insert(id) }
            return
        }
        request.timer?.cancel()
        if request.sentOn == nil { queued.removeAll { $0 == id } }
        request.continuation.resume(with: result)
    }

    private func failAll(_ failure: Failure) {
        for id in Array(pending.keys) { finish(id, .failure(failure)) }
        queued = []
    }

    // MARK: Links

    private func attempt() {
        guard !closed else { return }
        retry = nil
        generation += 1
        publish(.connecting)
        do {
            let link = try open(generation)
            self.link = link
            startHandshake(on: link)
        } catch {
            lost(generation, reason: (error as? Failure)?.message ?? "\(error)")
        }
    }

    private func open(_ generation: Int) throws -> Link {
        switch transport {
        case .unixSocket(let path):
            let fd = try Self.connect(path)
            let writer = dup(fd)
            return start(Link(generation: generation, readFD: fd, writeFD: writer, process: nil))
        case .process(let executable, let arguments, let environment):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            let link = Link(generation: generation, readFD: dup(output.fileHandleForReading.fileDescriptor), writeFD: dup(input.fileHandleForWriting.fileDescriptor), process: process)
            link.errors = errors
            errors.fileHandleForReading.readabilityHandler = { [weak self, weak link] handle in
                let chunk = handle.availableData
                guard let link else { return }
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    self?.queue.async { self?.relayEnded(link, stderrDone: true) }
                } else {
                    link.appendError(chunk)
                }
            }
            process.terminationHandler = { [weak self, weak link] _ in
                guard let link else { return }
                self?.queue.async { self?.relayEnded(link, exited: true) }
            }
            do {
                try processes.launch(process)
            } catch {
                errors.fileHandleForReading.readabilityHandler = nil
                Darwin.close(link.readFD)
                Darwin.close(link.writeFD)
                throw Failure("unavailable", "cannot run \(executable): \(error.localizedDescription)")
            }
            // The link's copy is the only writer left, so the relay sees EOF when the link closes.
            try? input.fileHandleForWriting.close()
            return start(link)
        }
    }

    /// A connected Unix socket; `unavailable` naming the path when nothing listens there.
    private static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("unavailable", "socket: \(String(cString: strerror(errno)))") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            Darwin.close(fd)
            throw Failure("unavailable", "socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(fd)
            let why = code == ENOENT || code == ECONNREFUSED ? "nothing is listening on \(path)" : "\(path): \(String(cString: strerror(code)))"
            throw Failure("unavailable", why)
        }
        return fd
    }

    /// Starts reading and writing `link`. Each fd is closed by its source's cancel handler: the
    /// read fd's once reading stops, the write fd's once writing stops (`Link.stopWriting`).
    private func start(_ link: Link) -> Link {
        let writeFD = link.writeFD
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        // `write` runs on `queue`, so a full pipe or socket must refuse rather than block it.
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
        let writable = DispatchSource.makeWriteSource(fileDescriptor: writeFD, queue: queue)
        writable.setEventHandler { [weak self, weak link] in
            guard let self, let link else { return }
            self.flush(link)
        }
        writable.setCancelHandler { Darwin.close(writeFD) }
        link.writer = .idle(writable)
        let readFD = link.readFD
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
        source.setEventHandler { [weak self, weak link] in
            guard let self, let link else { return }
            self.read(link)
        }
        source.setCancelHandler { Darwin.close(readFD) }
        link.source = source
        source.resume()
        return link
    }

    private func read(_ link: Link) {
        /// nil while the link is open; else why it ended (EOF is "").
        var ended: String?
        var search = link.buffer.count
        while true {
            let count = link.chunk.withUnsafeMutableBytes { Darwin.read(link.readFD, $0.baseAddress, $0.count) }
            if count > 0 {
                link.buffer.append(contentsOf: link.chunk[0..<count])
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { break }
            ended = count < 0 ? String(cString: strerror(errno)) : ""
            break
        }
        var start = 0
        while let newline = link.buffer[search...].firstIndex(of: 0x0A) {
            let line = link.buffer[start..<newline]
            start = newline + 1
            search = start
            guard !line.isEmpty, let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { continue }
            receive(message, on: link)
            // A message may have dropped this link (a failed handshake).
            guard self.link === link else { return }
        }
        if start > 0 { link.buffer.removeFirst(start) }
        guard let ended else { return }
        link.source?.cancel()
        link.source = nil
        // A relay's exit says why it ended, so that waits for the exit.
        if link.process != nil { return relayEnded(link, stdoutDone: true) }
        lost(link.generation, reason: ended.isEmpty ? "the server closed the connection" : "connection lost: \(ended)")
    }

    private func receive(_ message: JSONValue, on link: Link) {
        if let name = message["event"]?.string {
            guard !eventWatchers.isEmpty else { return }
            eventSequence += 1
            var event = Event(name: name, board: message["board"]?.string, data: message["data"] ?? .null)
            event.sequence = eventSequence
            for watcher in eventWatchers.values { watcher.yield(event) }
            return
        }
        if let method = message["method"]?.string {
            guard let id = message["id"]?.string else { return }
            let heard = Set(message["surfaceEvents"]?.array?.compactMap(\.string) ?? [])
            var call = Call(method: method, params: message["params"] ?? .object([:]), origin: Origin(link, on: self), surfaceEvents: heard)
            call.eventsThrough = eventSequence
            return called(call, id: id, on: link)
        }
        guard let id = message["id"]?.string.flatMap({ Int($0) }) else { return }
        let failure = message["ok"]?.bool == true ? nil : Failure(
            message["error"]?["code"]?.string ?? "internal",
            message["error"]?["message"]?.string ?? "unknown error",
            data: message["error"]?["data"], isHostResponse: true)
        if id < 0 {
            guard handshake.remove(id) != nil else { return }
            // A server that refuses `system.ping` (or a subscription) isn't one to talk to.
            if let failure { return lost(link.generation, reason: "the server refused the handshake: \(failure)") }
            if id == handshakePing {
                advertisedSchemaVersion = message["result"]?["version"]?.int
                handshakePing = nil
            }
            if handshake.isEmpty { cameOnline(link) }
            return
        }
        finish(id, failure.map { .failure($0) } ?? .success(message["result"] ?? .null))
    }

    /// Runs the server's call off this queue (its handler may wait on the main actor, which may be
    /// waiting on this queue), then writes the answer on `link` if that is still the link.
    private func called(_ call: Call, id: String, on link: Link) {
        let handler = server
        Task { [weak self] in
            let answer = await handler?(call) ?? .failure(Failure("unavailable", "this client serves no calls on this connection"))
            guard let self else { return }
            self.queue.async {
                guard self.link === link else { return }
                self.write(Self.answerLine(id: id, answer), on: link)
            }
        }
    }

    private func startHandshake(on link: Link) {
        let ping = nextHandshakeID()
        handshake = [ping]
        handshakePing = ping
        advertisedSchemaVersion = nil
        write(line(id: ping, method: "system.ping", params: .object([:])), on: link)
        for params in subscriptions {
            let id = nextHandshakeID()
            handshake.insert(id)
            write(line(id: id, method: "events.subscribe", params: params), on: link)
        }
        let timer = DispatchWorkItem { [weak self] in
            self?.lost(link.generation, reason: "no answer from easl within \(Int(self?.handshakeTimeout.seconds ?? 0))s")
        }
        handshakeTimer = timer
        queue.asyncAfter(deadline: .now() + handshakeTimeout.seconds, execute: timer)
    }

    private func cameOnline(_ link: Link) {
        handshakeTimer?.cancel()
        handshakeTimer = nil
        failures = 0
        reason = nil
        publish(.online)
        let waiting = queued
        queued = []
        for id in waiting {
            guard var request = pending[id] else { continue }
            request.sentOn = link.generation
            pending[id] = request
            write(request.line, on: link)
        }
    }

    /// Room for ordinary queued output plus one maximum delegated reply and its newline.
    private static let maxPending = SocketServer.Connection.maxPending + DelegatedCalls.maxReply + 1

    /// Sends `line` after what `link` hasn't written yet; dropped once the link stopped writing.
    private func write(_ line: Data, on link: Link, whileCurrent: (@Sendable () -> Bool)? = nil) {
        guard link.writer != nil else { return }
        guard line.count <= Self.maxPending - link.pendingBytes else {
            link.stopWriting()
            let generation = link.generation
            queue.async { [weak self] in self?.lost(generation, reason: "pending output exceeded its byte budget") }
            return
        }
        link.pendingBytes += line.count
        link.outbox.append(Link.Output(data: line, whileCurrent: whileCurrent))
        // Lines already waiting hold the source, which writes this one after them.
        if link.outbox.count == 1 { flush(link) }
    }

    /// Writes `link.outbox` in order until it is empty or the fd is full; a full fd's source calls
    /// this again once the fd takes more. A failure is reported on a later turn of the queue, as
    /// DispatchIO's was, so no caller sees its link dropped in the middle of a write.
    private func flush(_ link: Link) {
        guard let writer = link.writer else { return }
        var done = link.outboxHead
        while done < link.outbox.count {
            let line = link.outbox[done]
            if line.data.isEmpty || (link.written == 0 && line.whileCurrent?() == false) {
                link.pendingBytes -= line.data.count
                link.outbox[done] = Link.Output(data: Data(), whileCurrent: nil)
                done += 1
                continue
            }
            let count = line.data.withUnsafeBytes { bytes in
                let rest = UnsafeRawBufferPointer(rebasing: bytes[link.written...])
                return Darwin.write(link.writeFD, rest.baseAddress, rest.count)
            }
            if count > 0 {
                link.written += count
                if link.written == line.data.count {
                    link.written = 0
                    link.pendingBytes -= line.data.count
                    link.outbox[done] = Link.Output(data: Data(), whileCurrent: nil)
                    done += 1
                }
                continue
            }
            let code = errno
            if code == EINTR { continue }
            if code == EAGAIN {
                link.outboxHead = done
                if case .idle(let source) = writer {
                    source.resume()
                    link.writer = .blocked(source)
                }
                return
            }
            link.stopWriting()
            let generation = link.generation
            let reason = "write failed: \(String(cString: strerror(code)))"
            queue.async { [weak self] in self?.lost(generation, reason: reason) }
            return
        }
        link.outbox.removeAll(keepingCapacity: true)
        link.outboxHead = 0
        if case .blocked(let source) = writer {
            source.suspend()
            link.writer = .idle(source)
        }
    }

    /// A relay ends in three parts (stdout EOF, stderr EOF, exit), in any order; its reason is
    /// whole once it exited and stderr is drained, or a moment after it exited.
    private func relayEnded(_ link: Link, stdoutDone: Bool = false, stderrDone: Bool = false, exited: Bool = false) {
        guard self.link === link else { return }
        if stdoutDone {
            // ssh closes its stdout before it exits with the remote command's status; a SIGTERM
            // in between makes it exit 255, which reads as "host unreachable". Only one that
            // hangs on is ended.
            queue.asyncAfter(deadline: .now() + 2) { [weak self, weak link] in
                guard let self, let link, self.link === link, let process = link.process, process.isRunning else { return }
                process.terminate()
            }
        }
        if stderrDone { link.stderrDone = true }
        if exited {
            link.exited = true
            if !link.stderrDone {
                queue.asyncAfter(deadline: .now() + 0.3) { [weak self, weak link] in
                    guard let self, let link else { return }
                    self.lost(link.generation, reason: link.exitReason())
                }
            }
        }
        if link.exited, link.stderrDone { lost(link.generation, reason: link.exitReason()) }
    }

    /// Link `generation` is gone: fail what it carried, go offline and try again after the
    /// backoff.
    private func lost(_ generation: Int, reason: String) {
        guard generation == self.generation, !closed, retry == nil else { return }
        let wasOnline = current == .online
        relayExit = link?.process.flatMap { $0.isRunning ? nil : $0.terminationStatus }
        link?.tearDown()
        link = nil
        handshake = []
        handshakePing = nil
        advertisedSchemaVersion = nil
        handshakeTimer?.cancel()
        handshakeTimer = nil
        for (id, request) in pending where request.sentOn != nil {
            finish(id, .failure(Failure("unavailable", "the connection was lost after sending \(request.method) (\(reason)); it may or may not have applied: re-read before retrying")))
        }
        for id in queued {
            guard let request = pending[id] else { continue }
            finish(id, .failure(Failure("unavailable", "\(reason) (\(request.method) was not sent)")))
        }
        queued = []
        self.reason = reason
        failures = wasOnline ? 1 : failures + 1
        publish(.offline)
        let next = DispatchWorkItem { [weak self] in self?.attempt() }
        retry = next
        queue.asyncAfter(deadline: .now() + backoff.delay(after: failures).seconds, execute: next)
    }
}

/// One attempt's transport: a socket (read and write fds are duplicates) or a relay process.
/// Only touched on the connection's queue, apart from `appendError` (locked).
private final class Link: @unchecked Sendable {
    let generation: Int
    let readFD: Int32
    let writeFD: Int32
    let process: Process?
    var source: DispatchSourceRead?
    /// The write fd's source, made in `start` and resumed only while `outbox` waits on a full fd,
    /// so a link that never fills it gets no write events. Nil before `start` and once stopped.
    var writer: Writer?
    /// Cleared slots before `outboxHead` avoid shifting pending lines after every partial drain.
    struct Output {
        var data: Data
        var whileCurrent: (@Sendable () -> Bool)?
    }
    var outbox: [Output] = []
    var outboxHead = 0
    var pendingBytes = 0
    var written = 0
    var errors: Pipe?
    var buffer: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    var stderrDone = false
    var exited = false
    private let lock = NSLock()
    private var stderrTail = Data()
    /// Until `tearDown`: the connection's current link, which a call's origin may push on.
    private var live = true

    init(generation: Int, readFD: Int32, writeFD: Int32, process: Process?) {
        self.generation = generation
        self.readFD = readFD
        self.writeFD = writeFD
        self.process = process
        stderrDone = process == nil
    }

    func appendError(_ chunk: Data) {
        lock.withLock {
            stderrTail.append(chunk)
            if stderrTail.count > 4096 { stderrTail.removeFirst(stderrTail.count - 4096) }
        }
    }

    var isLive: Bool { lock.withLock { live } }

    /// "ssh exited with status 255: ssh: connect to host … port 22: Connection refused".
    func exitReason() -> String {
        let tail = lock.withLock { String(decoding: stderrTail, as: UTF8.self) }
        let last = tail.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
        let name = process?.executableURL?.lastPathComponent ?? "relay"
        let status = process.map { $0.isRunning ? "" : " with status \($0.terminationStatus)" } ?? ""
        return "\(name) exited\(status)" + (last.map { ": \($0)" } ?? "")
    }

    enum Writer {
        /// Suspended, or not activated yet.
        case idle(DispatchSourceWrite)
        /// Resumed: fires once the fd takes more.
        case blocked(DispatchSourceWrite)
    }

    func tearDown() {
        lock.withLock { live = false }
        source?.cancel()
        source = nil
        stopWriting()
        errors?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
    }

    /// Drops what wasn't written. The source's cancel handler closes the write fd, and runs only
    /// once the source is resumed, so an idle one is resumed after it is cancelled.
    func stopWriting() {
        switch writer {
        case .idle(let source)?:
            source.cancel()
            source.resume()
        case .blocked(let source)?:
            source.cancel()
        case nil:
            break
        }
        writer = nil
        outbox = []
        outboxHead = 0
        written = 0
        pendingBytes = 0
    }
}

/// A value behind a lock.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&value) }
    }
}
