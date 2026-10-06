import CryptoKit
import Foundation

/// The app's end of a host's relay (easld `relay.open`; docs/contracts.md "Hosted terminals"):
/// ssh forwards a loopback TCP port on the host to this unix socket, and the host's easld passes
/// each connection to its sockets on through it. Every user of the host can reach that port, and
/// once a forward is gone anyone can listen on it, so neither end sends the token: easld opens
/// with `<name> <nonce>`, the gate answers `<its nonce> <proof>`, easld answers with its own
/// proof (`proof`), and only then is the connection spliced to `targets[name]` (the API's socket,
/// cmux's). Each new connection to the host gets a new token (`rotate`), so whatever easld may
/// have told a listener on an old port is worthless at the gate.
public final class RelayGate: @unchecked Sendable {
    public let path: String
    private let targets: [String: String]
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var current: String

    public init(path: String, token: String = RelayGate.newToken(), targets: [String: String]) {
        self.path = path
        self.current = token
        self.targets = targets
    }

    /// The token easld must prove, for `relay.open`.
    public var token: String { lock.withLock { current } }

    /// A new token, which alone opens the gate from now on: called before each new forward to it
    /// is made, so the previous forward and port (and what easld kept dialing there after the
    /// connection dropped) no longer get through.
    @discardableResult
    public func rotate() -> String {
        let token = Self.newToken()
        lock.withLock { current = token }
        return token
    }

    /// 64 random hex digits.
    public static func newToken() -> String { randomHex(32) }

    /// `role`'s proof ("easld" or "gate") that it holds `token`, for a connection to socket `name`
    /// that easld started with nonce `easld` and the gate answered with nonce `gate`: HMAC-SHA256
    /// keyed by the token, in hex (easld's `relay.Proof`).
    public static func proof(token: String, role: String, name: String, easld: String, gate: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("easl-relay \(role) \(name) \(easld) \(gate)".utf8), using: SymmetricKey(data: Data(token.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
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

    /// The handshake (each line within 5 s), then the target connected and both ways copied.
    private func pass(_ client: Int32) {
        defer { close(client) }
        Self.noSigPipe(client)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let token = token
        guard let hello = Self.line(client) else { return }
        let words = hello.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count == 2, let target = targets[words[0]], Self.isHex(words[1], count: 32) else { return }
        let name = words[0], theirs = words[1], ours = Self.randomHex(16)
        let answer = "\(ours) \(Self.proof(token: token, role: "gate", name: name, easld: theirs, gate: ours))\n"
        guard Self.send(answer, to: client), let proof = Self.line(client),
              Self.same(proof, Self.proof(token: token, role: "easld", name: name, easld: theirs, gate: ours)) else { return }
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

    /// One line from `fd` (at most 256 bytes, without its newline), read a byte at a time so
    /// nothing after it is consumed; nil when it doesn't come.
    private static func line(_ fd: Int32) -> String? {
        var bytes = [UInt8](), byte: UInt8 = 0
        while bytes.count < 256, read(fd, &byte, 1) == 1 {
            if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        return nil
    }

    private static func send(_ text: String, to fd: Int32) -> Bool {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            sent += written
        }
        return true
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

    private static func randomHex(_ bytes: Int) -> String {
        SymmetricKey(size: SymmetricKeySize(bitCount: bytes * 8)).withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    }

    private static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
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
