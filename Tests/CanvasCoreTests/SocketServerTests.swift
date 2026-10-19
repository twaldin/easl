import Darwin
import Foundation
import Testing
import CanvasCore

/// Two app instances sharing a support dir bind the same socket path in turn.
final class SocketServerTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-\(UUID().uuidString.prefix(8))")
    var path: String { dir.appendingPathComponent("s").path }

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// A server that answers every request with its name.
    func start(_ name: String) throws -> SocketServer {
        let server = SocketServer(path: path) { _, _ in .string(name) }
        try server.start()
        return server
    }

    @Test func stoppingLeavesTheSocketAnotherServerBoundThereSince() async throws {
        let first = try start("first")
        let second = try start("second")
        first.stop()

        let client = try LineClient(path: path)
        client.send("{}")
        #expect(try await client.next() == .string("second"))

        second.stop()
        #expect(access(path, F_OK) != 0)
    }

    /// `app.metrics`' `api.<method>` total for `method`.
    func calls(_ method: String) -> JSONValue? {
        Metrics.shared.snapshot()["counters"]?["api.\(method)"]?["total"]
    }

    @Test func repliesSentOutsideTheHandlersReturnAreCounted() async throws {
        let tag = UUID().uuidString.prefix(8)
        let server = SocketServer(path: path) { request, connection in
            let id = request["id"] ?? .null
            switch request["method"]?.string {
            case "direct.\(tag)":
                connection.send(.object(["id": id, "ok": .bool(true), "result": .object([:])]))
            case "deferred.\(tag)":
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    connection.send(.object(["id": id, "ok": .bool(true), "result": .string("late")]))
                }
            default:
                return .object(["id": id, "ok": .bool(true), "result": .null])
            }
            return nil
        }
        try server.start()
        defer { server.stop() }
        let client = try LineClient(path: path)
        client.send(#"{"id":1,"method":"direct.\#(tag)"}"#)
        _ = try await client.next()
        client.send(#"{"id":2,"method":"deferred.\#(tag)"}"#)
        client.send(#"{"id":3,"method":"plain.\#(tag)"}"#)
        #expect(try await client.next()["id"] == .number(3), "the deferred reply comes after the next request's")
        #expect(try await client.next()["result"] == .string("late"))

        #expect(calls("direct.\(tag)")?["n"] == .number(1))
        #expect(calls("plain.\(tag)")?["n"] == .number(1))
        let deferred = try #require(calls("deferred.\(tag)"))
        #expect(deferred["n"] == .number(1))
        #expect((deferred["ms"]?.number ?? 0) >= 150, "timed until the deferred reply was queued")
        #expect((deferred["bytes"]?.number ?? 0) > 0)
    }

    @Test func aPipelinedRequestIsTimedFromItsArrival() async throws {
        let tag = UUID().uuidString.prefix(8)
        let server = SocketServer(path: path) { request, _ in
            if request["method"]?.string == "slow.\(tag)" { try? await Task.sleep(for: .milliseconds(250)) }
            return .object(["id": request["id"] ?? .null, "ok": .bool(true), "result": .null])
        }
        try server.start()
        defer { server.stop() }
        let client = try LineClient(path: path)
        client.send(#"{"id":1,"method":"slow.\#(tag)"}"# + "\n" + #"{"id":2,"method":"quick.\#(tag)"}"#)
        _ = try await client.next()
        _ = try await client.next()
        #expect((calls("quick.\(tag)")?["ms"]?.number ?? 0) >= 200, "its wait behind the slow request counts")
    }

    private func backpressured(timeout: TimeInterval, reply: JSONValue) throws -> (
        SocketServer, SocketSendSignal<Result<SocketBackpressure, any Error>>, SocketSendSignal<Bool>
    ) {
        let prepared = SocketSendSignal<Result<SocketBackpressure, any Error>>()
        let results = SocketSendSignal<Bool>()
        let server = SocketServer(path: path) { request, connection in
            guard request["block"] == .bool(true) else {
                return .object(["reply": .string("ordinary"), "fd": .number(Double(connection.fd))])
            }
            do {
                let filled = try fillSocket(connection.fd)
                let older = connection.send(line: "older")
                let accepted = connection.send(reply, timeout: timeout) { results.append($0) }
                prepared.append(.success(SocketBackpressure(
                    connection: connection, filled: filled, admitted: [older, accepted],
                    afterDeadline: Date().addingTimeInterval(timeout + 0.1)
                )))
            } catch {
                prepared.append(.failure(error))
            }
            return nil
        }
        try server.start()
        return (server, prepared, results)
    }

    @Test func timedSendWaitsForEarlierBytesAndItsEntireJSONLine() async throws {
        let body = String(repeating: "a", count: 1 << 20)
        let (server, prepared, results) = try backpressured(timeout: 5, reply: .string(body))
        defer { server.stop() }
        let client = try LineClient(path: path)
        client.send(#"{"block":true}"#)
        let ready = try await prepared.first().get()
        #expect(ready.admitted == [true, true])
        #expect(results.values == [])
        try #require(ready.filled + 4096 < body.utf8.count)

        #expect(try await client.nextText() == String(repeating: "x", count: ready.filled) + "older")
        #expect(results.values == [], "the large JSON line still cannot fit in the unread socket buffer")
        #expect(try await client.nextText() == "\"" + body + "\"")
        #expect(try await results.first())
        #expect(results.values == [true])

        shutdown(client.fd, SHUT_RDWR)
        var held: [LineClient] = []
        var replacement: LineClient?
        for _ in 0..<32 {
            let candidate = try LineClient(path: path)
            held.append(candidate)
            candidate.send("{}")
            let response = try await candidate.next()
            #expect(response["reply"] == .string("ordinary"))
            if candidate.fd == ready.connection.fd || response["fd"] == .number(Double(ready.connection.fd)) {
                replacement = candidate
                break
            }
        }
        let reused = try #require(replacement, "the closed connection's descriptor must be reused")
        do {
            _ = try await reused.next(timeout: max(0.01, ready.afterDeadline.timeIntervalSinceNow))
            Issue.record("a replacement connection received an unsolicited line")
        } catch let error as POSIXError {
            #expect(error.code == .ETIMEDOUT, "a canceled late timer must not close a reused descriptor")
        }
        reused.send("{}")
        #expect(try await reused.next()["reply"] == .string("ordinary"))
        #expect(results.values == [true], "the canceled timeout must not complete the send again")
        withExtendedLifetime(held) {}
    }

    @Test func timedSendTimeoutInterruptsTheEarlierBlockedWriteWithoutSendingAnAcknowledgement() async throws {
        let (server, prepared, results) = try backpressured(timeout: 0.1, reply: .string("accepted"))
        defer { server.stop() }
        let client = try LineClient(path: path)
        client.send(#"{"block":true}"#)
        let ready = try await prepared.first().get()
        #expect(ready.admitted == [true, true])
        #expect(try await results.first() == false)
        #expect(try await socketBytesUntilEOF(client.fd) == Data(repeating: 0x78, count: ready.filled))
        #expect(results.values == [false])
        #expect(!ready.connection.send(.string("stale")))

        let rejected = SocketSendSignal<Bool>()
        #expect(!ready.connection.send(.string("stale"), timeout: 1) { rejected.append($0) })
        #expect(rejected.values == [false])
        #expect(results.values == [false])
    }

    @Test func disconnectFailsATimedSendQueuedBehindBackpressure() async throws {
        let (server, prepared, results) = try backpressured(timeout: 30, reply: .string("accepted"))
        defer { server.stop() }
        let client = try LineClient(path: path)
        client.send(#"{"block":true}"#)
        let ready = try await prepared.first().get()
        #expect(ready.admitted == [true, true])
        #expect(results.values == [])
        shutdown(client.fd, SHUT_RDWR)
        #expect(try await results.first() == false)

        let replacement = try LineClient(path: path)
        replacement.send("{}")
        #expect(try await replacement.next()["reply"] == .string("ordinary"))
        #expect(results.values == [false])
        #expect(!ready.connection.send(.string("stale")))
    }

    @Test func ordinaryCloseStillDrainsQueuedFireAndForgetBytes() async throws {
        let prepared = SocketSendSignal<Result<(Int, Bool), any Error>>()
        let server = SocketServer(path: path) { _, connection in
            do {
                let filled = try fillSocket(connection.fd)
                prepared.append(.success((filled, connection.send(line: "older"))))
            } catch {
                prepared.append(.failure(error))
            }
            return nil
        }
        try server.start()
        defer { server.stop() }
        let client = try LineClient(path: path)
        client.send("{}")
        let (filled, accepted) = try await prepared.first().get()
        #expect(accepted)
        server.stop()
        #expect(try await socketBytesUntilEOF(client.fd) == Data(repeating: 0x78, count: filled) + Data("older\n".utf8))
    }

    @Test func aCanceledQueuedRefreshDoesNotPrecedeItsMotionReplacement() async throws {
        let prepared = SocketSendSignal<Result<(SocketServer.Connection, Int), any Error>>()
        let revision = SurfaceInputRevision()
        let server = SocketServer(path: path) { _, connection in
            do {
                let filled = try fillSocket(connection.fd)
                connection.send(line: "committed")
                connection.send(encoded: Data("canceled refresh".utf8), whileCurrent: { revision.value == 0 })
                connection.send(encoded: Data("other stream".utf8), whileCurrent: { true })
                prepared.append(.success((connection, filled)))
            } catch {
                prepared.append(.failure(error))
            }
            return nil
        }
        try server.start()
        defer { server.stop() }
        let client = try LineClient(path: path)
        client.send("{}")
        let (connection, filled) = try await prepared.first().get()
        revision.advance()
        #expect(connection.send(line: "replacement motion"))
        #expect(connection.send(line: "after"))
        #expect(try await client.nextText() == String(repeating: "x", count: filled) + "committed")
        #expect(try await client.nextText() == "other stream")
        #expect(try await client.nextText() == "replacement motion")
        #expect(try await client.nextText() == "after")
    }

    @Test func anExpiredDeadlineDoesNotWriteAnyOfTheJSONLine() async throws {
        let admitted = SocketSendSignal<Bool>()
        let results = SocketSendSignal<Bool>()
        let server = SocketServer(path: path) { _, connection in
            admitted.append(connection.send(.string("expired"), timeout: 0) { results.append($0) })
            return nil
        }
        try server.start()
        defer { server.stop() }
        let client = try LineClient(path: path)
        client.send("{}")
        #expect(try await admitted.first())
        #expect(try await results.first() == false)
        #expect(try await socketBytesUntilEOF(client.fd) == Data())
        #expect(results.values == [false])
    }

    @Test func rejectedTimedSendsCompleteOnceWithoutWritingTheirLines() async throws {
        let connections = SocketSendSignal<SocketServer.Connection>()
        let server = SocketServer(path: path) { _, connection in
            connections.append(connection)
            return .string("ready")
        }
        try server.start()
        defer { server.stop() }
        let client = try LineClient(path: path)
        client.send("{}")
        #expect(try await client.next() == .string("ready"))
        let connection = try await connections.first()
        let results = SocketSendSignal<Bool>()

        #expect(!connection.send(.number(.infinity), timeout: 1) { results.append($0) })
        #expect(results.values == [false])
        #expect(connection.send(.string("still-open")))
        #expect(try await client.nextText() == #""still-open""#)

        #expect(!connection.send(.string(String(repeating: "z", count: 32 << 20)), timeout: 1) { results.append($0) })
        #expect(results.values == [false, false])
        #expect(try await socketBytesUntilEOF(client.fd) == Data())
        #expect(!connection.send(.string("closed"), timeout: 1) { results.append($0) })
        #expect(results.values == [false, false, false])
    }
}

private struct SocketBackpressure: Sendable {
    let connection: SocketServer.Connection
    let filled: Int
    let admitted: [Bool]
    let afterDeadline: Date
}

private final class SocketSendSignal<Value: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var stored: [Value] = []

    var values: [Value] {
        condition.lock()
        defer { condition.unlock() }
        return stored
    }

    func append(_ value: Value) {
        condition.lock()
        stored.append(value)
        condition.broadcast()
        condition.unlock()
    }

    func first() async throws -> Value {
        try await socketTestThread {
            self.condition.lock()
            defer { self.condition.unlock() }
            let deadline = Date().addingTimeInterval(10)
            while self.stored.isEmpty {
                guard self.condition.wait(until: deadline) else { throw POSIXError(.ETIMEDOUT) }
            }
            return self.stored[0]
        }
    }
}

private func socketTestThread<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try operation() }) }
    }
}

/// Fill the actual kernel buffer before any outbox job can run. No client reads until signaled.
private func fillSocket(_ fd: Int32) throws -> Int {
    var capacity: Int32 = 4096
    guard setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &capacity, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    defer { _ = fcntl(fd, F_SETFL, flags) }
    let bytes = [UInt8](repeating: 0x78, count: 4096)
    return try bytes.withUnsafeBytes { raw in
        var filled = 0
        var count = raw.count
        while true {
            let written = Darwin.write(fd, raw.baseAddress, count)
            if written > 0 {
                filled += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if count == 1 { return filled }
            count = 1
        }
    }
}

private func socketBytesUntilEOF(_ fd: Int32) async throws -> Data {
    try await socketTestThread {
        let deadline = Date().addingTimeInterval(10)
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard remaining > 0 else { throw POSIXError(.ETIMEDOUT) }
            let ready = poll(&poller, 1, remaining)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw POSIXError(.ETIMEDOUT) }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { return data }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            data.append(contentsOf: bytes[0..<count])
        }
    }
}
