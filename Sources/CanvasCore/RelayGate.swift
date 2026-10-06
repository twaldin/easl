import Foundation

/// The app's end of a host's relay (easld `relay.open`; docs/contracts.md "Hosted terminals"):
/// ssh forwards a loopback TCP port on the host to this unix socket, and the host's easld passes
/// each connection to its sockets on through it, first sending `<token> <name>\n`. A connection
/// with the token is spliced to `targets[name]` (the API's socket, cmux's); any other closes,
/// since every user of the host can reach that port and only easld has the token.
public final class RelayGate: @unchecked Sendable {
    public let path: String
    public let token: String
    private let targets: [String: String]
    private let lock = NSLock()
    private var listenFD: Int32 = -1

    public init(path: String, token: String = RelayGate.newToken(), targets: [String: String]) {
        self.path = path
        self.token = token
        self.targets = targets
    }

    /// 64 random hex digits.
    public static func newToken() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    public func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard Self.withAddress(path, { bind(fd, $0, $1) }) == 0, chmod(path, 0o600) == 0, listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        lock.withLock { listenFD = fd }
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                Thread.detachNewThread { [self] in pass(client) }
            }
        }
    }

    public func stop() {
        let fd = lock.withLock { () -> Int32 in
            defer { listenFD = -1 }
            return listenFD
        }
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }

    /// Checks the first line (within 5 s), connects its target, and copies both ways.
    private func pass(_ client: Int32) {
        defer { close(client) }
        Self.noSigPipe(client)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var header = [UInt8](), byte: UInt8 = 0
        while header.count < 256, read(client, &byte, 1) == 1, byte != 0x0A { header.append(byte) }
        let words = String(decoding: header, as: UTF8.self).split(separator: " ", maxSplits: 1).map(String.init)
        guard byte == 0x0A, words.count == 2, Self.same(words[0], token), let target = targets[words[1]] else { return }
        var none = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        let upstream = socket(AF_UNIX, SOCK_STREAM, 0)
        guard upstream >= 0 else { return }
        defer { close(upstream) }
        Self.noSigPipe(upstream)
        guard Self.withAddress(target, { connect(upstream, $0, $1) }) == 0 else { return }
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            Self.copy(from: client, to: upstream)
            done.signal()
        }
        Self.copy(from: upstream, to: client)
        done.wait()
    }

    /// Copies until `from` ends, then ends `to`'s writing side.
    private static func copy(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        copying: while true {
            let count = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            var sent = 0
            while sent < count {
                let written = buffer.withUnsafeBytes { write(to, $0.baseAddress! + sent, count - sent) }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { break copying }
                sent += written
            }
        }
        shutdown(to, SHUT_WR)
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}
