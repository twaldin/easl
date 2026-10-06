import Darwin
import Foundation

/// Newline-delimited JSON over a Unix domain socket (mode 0600). One request per line;
/// the handler returns a response line, or nil for connections turned into event streams.
public final class SocketServer: @unchecked Sendable {
    public final class Connection: @unchecked Sendable {
        public let fd: Int32
        fileprivate var buffer = Data()
        fileprivate var source: DispatchSourceRead?
        /// Requests in arrival order, with when they arrived; one consumer task handles them
        /// sequentially so pipelined calls (update then get) are answered in order.
        fileprivate let requests: AsyncStream<(request: JSONValue, arrived: Double)>.Continuation
        fileprivate let stream: AsyncStream<(request: JSONValue, arrived: Double)>
        public fileprivate(set) var isOpen = true
        /// Set by handlers that require a login line before requests (the cmux socket's `auth`).
        /// Only the connection's handler touches it, and handlers run one request at a time.
        public var authenticated = false
        /// The terminal tile a cmux client named as its own surface (`browser.open_split`'s
        /// `surface_id`), credited for what the connection later does. Same access rule.
        public var caller: String?
        private let writeLock = NSLock()
        /// Writes happen here, in call order, so a client that stops reading (a full socket
        /// buffer blocks `write`) never blocks the caller: event broadcasts and waiter replies run
        /// on the main thread, and a blocked cooperative thread would starve request handling.
        fileprivate let outbox = DispatchQueue(label: "canvas.socket.outbox")
        /// Bytes queued but not yet written; guarded by `writeLock`.
        private var pending = 0
        /// A client this far behind is stuck: drop it rather than buffer without bound.
        static let maxPending = 32 << 20
        /// Requests not yet answered, oldest first, for `api.<method>` accounting: a reply may be
        /// the handler's result, or sent directly (`events.subscribe`'s acknowledgement, a
        /// deferred `agent.wait`). Guarded by `writeLock`.
        private var unanswered: [(serial: Int, id: JSONValue, method: String, arrived: Double)] = []
        private var serial = 0

        init(fd: Int32) {
            self.fd = fd
            (stream, requests) = AsyncStream.makeStream(of: (request: JSONValue, arrived: Double).self)
        }

        /// Stops further writes; the fd itself is closed by the read source's cancel handler.
        fileprivate func markClosed() -> Bool {
            writeLock.lock()
            defer { writeLock.unlock() }
            guard isOpen else { return false }
            isOpen = false
            return true
        }

        /// Queues one JSON line. Safe from any thread; returns false once the peer is gone. A
        /// reply (`ok`) answers the oldest unanswered request with its `id`.
        @discardableResult
        public func send(_ value: JSONValue) -> Bool {
            send(value, answering: nil)
        }

        @discardableResult
        private func send(_ value: JSONValue, answering serial: Int?) -> Bool {
            guard let data = try? JSONEncoder().encode(value) else { return false }
            // Counted before the line is queued: the outbox can write it, and the client read it and
            // ask `app.metrics`, before this thread would get back here.
            if serial != nil || value["ok"] != nil { answered(serial, id: value["id"] ?? .null, bytes: data.count + 1) }
            return write(data)
        }

        /// A request arrived at `arrived` (`Metrics.now()`); its serial for `reply(_:to:)`.
        fileprivate func expect(_ request: JSONValue, arrived: Double) -> Int? {
            guard let method = request["method"]?.string else { return nil }
            writeLock.lock()
            defer { writeLock.unlock() }
            serial += 1
            unanswered.append((serial, request["id"] ?? .null, method, arrived))
            return serial
        }

        /// The handler's reply to the request `serial`.
        fileprivate func reply(_ value: JSONValue, to serial: Int?) {
            send(value, answering: serial)
        }

        /// Records `api.<method>`: the call, the time from its arrival to its reply (awaits
        /// and waiting behind earlier requests included; the main-thread part is
        /// `api.main.<method>`) and the reply's bytes. Not once the peer is gone: that reply
        /// is never written.
        private func answered(_ serial: Int?, id: JSONValue, bytes: Int) {
            writeLock.lock()
            guard isOpen else { return writeLock.unlock() }
            let index = serial.map { serial in unanswered.firstIndex { $0.serial == serial } } ?? unanswered.firstIndex { $0.id == id }
            let request = index.map { unanswered.remove(at: $0) }
            writeLock.unlock()
            guard let request else { return }
            Metrics.shared.record("api.\(request.method)", ms: (Metrics.now() - request.arrived) * 1000, bytes: bytes)
        }

        /// Queues a line already encoded as JSON (an event sent to several subscribers is encoded
        /// once). Safe from any thread; returns false once the peer is gone.
        @discardableResult
        public func send(encoded line: Data) -> Bool {
            write(line)
        }

        /// Queues one plain-text line (protocols that answer some commands outside JSON).
        @discardableResult
        public func send(line: String) -> Bool {
            write(Data(line.utf8))
        }

        private func write(_ line: Data) -> Bool {
            let data = line + [0x0A]
            writeLock.lock()
            guard isOpen else {
                writeLock.unlock()
                return false
            }
            pending += data.count
            let stuck = pending > Self.maxPending
            writeLock.unlock()
            if stuck {
                shutdown(fd, SHUT_RDWR)
                return false
            }
            outbox.async { [self] in
                let written = data.withUnsafeBytes { raw -> Bool in
                    var offset = 0
                    while offset < raw.count {
                        let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                        if written < 0 {
                            if errno == EINTR { continue }
                            return false
                        }
                        offset += written
                    }
                    return true
                }
                writeLock.lock()
                pending -= data.count
                writeLock.unlock()
                // A failed write means the peer is gone; the read source sees EOF and closes.
                if !written { shutdown(fd, SHUT_RDWR) }
            }
            return true
        }
    }

    public typealias Handler = @Sendable (_ request: JSONValue, _ connection: Connection) async -> JSONValue?

    public let path: String
    private let queue = DispatchQueue(label: "canvas.socket.\(UUID().uuidString)")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    /// The socket file `start` bound (device and inode). Instances sharing a support dir bind
    /// the same path in turn, so `stop` removes the path only while it is still this file.
    private var boundFile: (device: dev_t, inode: ino_t)?
    /// Reused for every read; only touched on `queue`.
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
    private let handler: Handler
    /// Deliver lines that aren't JSON to the handler as `.string(line)` instead of rejecting them.
    private let acceptsTextLines: Bool

    public init(path: String, acceptsTextLines: Bool = false, handler: @escaping Handler) {
        self.path = path
        self.acceptsTextLines = acceptsTextLines
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        listenFD = fd
        var info = stat()
        if lstat(path, &info) == 0 { boundFile = (info.st_dev, info.st_ino) }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for connection in connections.values { closeConnection(connection) }
            connections.removeAll()
            listenFD = -1
        }
        var info = stat()
        if let file = boundFile, lstat(path, &info) == 0, info.st_dev == file.device, info.st_ino == file.inode {
            unlink(path)
        }
        boundFile = nil
    }

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connection = Connection(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, connection] in self?.read(connection) }
        // Queued writes finish (or fail) before the fd closes, so its number can't be reused
        // under a write still waiting in the outbox.
        source.setCancelHandler { [connection] in connection.outbox.async { close(fd) } }
        connection.source = source
        connections[fd] = connection
        let handler = self.handler
        Task {
            for await (request, arrived) in connection.stream {
                let serial = connection.expect(request, arrived: arrived)
                if let response = await handler(request, connection) { connection.reply(response, to: serial) }
            }
        }
        source.resume()
    }

    private func read(_ connection: Connection) {
        let count = readBuffer.withUnsafeMutableBytes { Darwin.read(connection.fd, $0.baseAddress, $0.count) }
        guard count > 0 else {
            closeConnection(connection)
            connections.removeValue(forKey: connection.fd)
            return
        }
        connection.buffer.append(contentsOf: readBuffer[0..<count])
        while let newline = connection.buffer.firstIndex(of: 0x0A) {
            let line = connection.buffer[connection.buffer.startIndex..<newline]
            connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            let request: JSONValue
            do {
                request = try JSONDecoder().decode(JSONValue.self, from: line)
            } catch {
                guard acceptsTextLines, let text = String(data: line, encoding: .utf8) else {
                    connection.send(.object(["ok": .bool(false), "error": .object(["code": .string("invalid_params"), "message": .string("malformed JSON line")])]))
                    continue
                }
                request = .string(text.hasSuffix("\r") ? String(text.dropLast()) : text)
            }
            if let method = request["method"]?.string { Metrics.shared.record("api.in.\(method)", bytes: line.count + 1) }
            connection.requests.yield((request, Metrics.now()))
        }
    }

    private func closeConnection(_ connection: Connection) {
        guard connection.markClosed() else { return }
        connection.requests.finish()
        connection.source?.cancel()
    }
}
