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
}
