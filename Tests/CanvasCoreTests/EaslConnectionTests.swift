import Darwin
import Foundation
import Testing
import CanvasCore

/// The client connection remote boards use: a Unix socket, or a relay process's stdio (the tests
/// relay with `nc -U`, as `ssh <host> nc -U` does on the host).
final class EaslConnectionTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("ec-\(UUID().uuidString.prefix(8))")
    var path: String { dir.appendingPathComponent("s").path }
    let fast = EaslConnection.Backoff(initial: .milliseconds(50), maximum: .milliseconds(400))

    init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: dir) }

    /// A stand-in for easl's socket: `system.ping`, `events.subscribe` (remembered, so the test
    /// can push events), `echo` (its params), `later` (answered after `ms`, out of order), `fail`.
    final class FakeServer: @unchecked Sendable {
        /// What the server was asked, shared with its handler.
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var subscribers: [(SocketServer.Connection, JSONValue)] = []
            var methods: [String] = []
        }

        let server: SocketServer
        private let log = Log()

        init(path: String) throws {
            let log = log
            server = SocketServer(path: path) { request, connection in
                let id = request["id"] ?? .null
                let method = request["method"]?.string ?? ""
                let params = request["params"] ?? .object([:])
                log.lock.withLock { log.methods.append(method) }
                switch method {
                case "events.subscribe":
                    log.lock.withLock { log.subscribers.append((connection, params)) }
                    return .object(["id": id, "ok": .bool(true), "result": .object([:])])
                case "later":
                    let ms = params["ms"]?.int ?? 0
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(ms)) {
                        connection.send(.object(["id": id, "ok": .bool(true), "result": params]))
                    }
                    return nil
                case "fail":
                    return .object(["id": id, "ok": .bool(false), "error": .object(["code": .string("not_found"), "message": .string("no such object")])])
                case "hang":
                    return nil
                default:
                    return .object(["id": id, "ok": .bool(true), "result": params])
                }
            }
            try server.start()
        }

        func stop() { server.stop() }

        var calls: [String] { log.lock.withLock { log.methods } }
        var subscriptions: [JSONValue] { log.lock.withLock { log.subscribers.map(\.1) } }

        /// Sends `name` on `board` to every subscriber whose board matches, as the app does.
        func emit(_ name: String, board: String, data: JSONValue) {
            let receivers = log.lock.withLock { log.subscribers.filter { $0.1["board"]?.string == nil || $0.1["board"]?.string == board }.map(\.0) }
            for connection in receivers {
                connection.send(.object(["event": .string(name), "board": .string(board), "data": data]))
            }
        }
    }

    /// The first state in `states` that is `wanted`, within `seconds`: long, since the whole
    /// suite starts at once and a CI runner can stall every test for seconds; only a failing
    /// test waits it out.
    func reach(_ wanted: EaslConnection.State, _ connection: EaslConnection, within seconds: Double = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if connection.state == wanted { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// `body`'s answer, or nil after `seconds`: a stream that never yields fails the test
    /// instead of hanging the suite.
    func within<T: Sendable>(_ seconds: Double = 30, _ body: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func relay() -> EaslConnection {
        .process("/usr/bin/nc", ["-U", path], backoff: fast, handshakeTimeout: .seconds(60))
    }

    @Test(arguments: ["socket", "relay"])
    func answersGoToTheRequestThatAskedEvenOutOfOrder(_ transport: String) async throws {
        let server = try FakeServer(path: path)
        defer { server.stop() }
        let connection = transport == "socket" ? EaslConnection.unixSocket(path, backoff: fast) : relay()
        defer { connection.close() }
        async let slow = connection.request("later", .object(["ms": .number(300), "tag": .string("slow")]))
        try await Task.sleep(for: .milliseconds(50))
        async let quick = connection.request("echo", .object(["tag": .string("quick")]))
        let (first, second) = try await (slow, quick)
        #expect(first["tag"] == .string("slow"))
        #expect(second["tag"] == .string("quick"))
        #expect(server.calls.first == "system.ping", "a link is online once the server answered a ping")
    }

    @Test func aServerErrorKeepsItsCodeAndMessage() async throws {
        let server = try FakeServer(path: path)
        defer { server.stop() }
        let connection = EaslConnection.unixSocket(path, backoff: fast)
        defer { connection.close() }
        await #expect(throws: EaslConnection.Failure("not_found", "no such object")) {
            try await connection.request("fail")
        }
    }

    @Test func eventsArriveOnlyForTheSubscribedBoard() async throws {
        let server = try FakeServer(path: path)
        defer { server.stop() }
        let connection = relay()
        defer { connection.close() }
        connection.subscribe(board: "brd_a", events: ["object.updated"])
        let events = connection.events()
        #expect(await reach(.online, connection))
        #expect(server.subscriptions == [.object(["board": .string("brd_a"), "events": .array([.string("object.updated")])])])
        server.emit("object.updated", board: "brd_b", data: .object(["id": .string("obj_other")]))
        server.emit("object.updated", board: "brd_a", data: .object(["id": .string("obj_1")]))
        let event = await within { await events.first { _ in true } }
        #expect(event == EaslConnection.Event(name: "object.updated", board: "brd_a", data: .object(["id": .string("obj_1")])))
    }

    @Test func aDroppedLinkReconnectsAndSubscribesAgainBeforeItIsOnline() async throws {
        var server = try FakeServer(path: path)
        let connection = relay()
        defer { connection.close() }
        connection.subscribe(board: "brd_a")
        let states = connection.states()
        #expect(await reach(.online, connection))
        server.stop()
        #expect(await reach(.offline, connection))
        #expect(connection.problem != nil)
        server = try FakeServer(path: path)
        defer { server.stop() }
        #expect(await reach(.online, connection))
        #expect(server.calls.prefix(2) == ["system.ping", "events.subscribe"], "the new link pings and re-subscribes first")
        #expect(connection.problem == nil)
        let events = connection.events()
        server.emit("object.created", board: "brd_a", data: .null)
        #expect(await within { await events.first { _ in true } }?.name == "object.created")
        // connecting → online → offline → (connecting → offline)* → connecting → online
        let seen: [EaslConnection.State] = await within { () async -> [EaslConnection.State]? in
            var seen: [EaslConnection.State] = []
            for await state in states {
                seen.append(state)
                if seen.count > 3, state == .online { break }
            }
            return seen
        } ?? []
        #expect(Array(seen.prefix(3)) == [.connecting, .online, .offline])
        #expect(Array(seen.suffix(2)) == [.connecting, .online])
    }

    @Test func attemptsBackOffAndTheRelaysLastWordIsTheProblem() async throws {
        let log = dir.appendingPathComponent("attempts").path
        // A relay that can't reach its host, as ssh says it; each attempt logs its time.
        let script = "perl -MTime::HiRes=time -e 'printf \"%.3f\\n\", time' >> '\(log)'; echo 'ssh: connect to host work port 22: Connection refused' >&2; exit 255"
        let connection = EaslConnection.process("/bin/sh", ["-c", script], backoff: .init(initial: .milliseconds(100), maximum: .milliseconds(400)))
        defer { connection.close() }
        // Waits only ever run long (a busy machine), so each gap is at least its backoff.
        var times: [Double] = []
        let deadline = Date().addingTimeInterval(20)
        while times.count < 5, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            times = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Double($0) }
        }
        #expect(connection.state != .online)
        let problem = try #require(connection.problem)
        #expect(problem == "sh exited with status 255: ssh: connect to host work port 22: Connection refused")
        try #require(times.count >= 5, "attempts: \(times.count)")
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        for (gap, wait) in zip(gaps, [0.1, 0.2, 0.4, 0.4]) {
            #expect(gap >= wait - 0.02, "100, 200, 400, 400 ms at least: \(gaps)")
        }
    }

    @Test func offlineRequestsFailAtOnce() async throws {
        let connection = EaslConnection.unixSocket(path, backoff: .init(initial: .seconds(5), maximum: .seconds(5)))
        defer { connection.close() }
        #expect(await reach(.offline, connection))
        #expect(connection.problem == "nothing is listening on \(path)")
        await #expect(throws: EaslConnection.Failure("unavailable", "nothing is listening on \(path) (echo was not sent)")) {
            try await connection.request("echo")
        }
    }

    @Test func requestsMadeWhileConnectingWaitForTheLink() async throws {
        let server = try FakeServer(path: path)
        defer { server.stop() }
        // A relay slow to reach its host, as ssh is.
        let connection = EaslConnection.process("/bin/sh", ["-c", "sleep 0.3; exec /usr/bin/nc -U '\(path)'"], backoff: fast)
        defer { connection.close() }
        #expect(connection.state == .connecting)
        let answer = try await connection.request("echo", .object(["n": .number(1)]))
        #expect(answer["n"] == .number(1))
        #expect(connection.state == .online)
    }

    @Test func aRequestWhoseLinkDroppedIsNeverResent() async throws {
        let server = try FakeServer(path: path)
        let connection = EaslConnection.unixSocket(path, backoff: fast)
        defer { connection.close() }
        #expect(await reach(.online, connection))
        async let hanging = connection.request("hang")
        let deadline = Date().addingTimeInterval(10)
        while !server.calls.contains("hang"), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        server.stop()
        do {
            _ = try await hanging
            Issue.record("expected the request to fail")
        } catch let failure as EaslConnection.Failure {
            #expect(failure.code == "unavailable")
            #expect(failure.message.contains("may or may not have applied"))
        }
        let again = try FakeServer(path: path)
        defer { again.stop() }
        #expect(await reach(.online, connection))
        #expect(!again.calls.contains("hang"))
    }

    @Test func aTimedOutRequestFailsAndItsLateAnswerIsDropped() async throws {
        let server = try FakeServer(path: path)
        defer { server.stop() }
        let connection = EaslConnection.unixSocket(path, backoff: fast)
        defer { connection.close() }
        await #expect(throws: EaslConnection.Failure("timeout", "later timed out after 0.1s")) {
            try await connection.request("later", .object(["ms": .number(300)]), timeout: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await connection.request("echo", .object(["n": .number(2)]))["n"] == .number(2))
    }

    @Test func closingEndsTheStreamsAndStopsReconnecting() async throws {
        let server = try FakeServer(path: path)
        defer { server.stop() }
        let connection = EaslConnection.unixSocket(path, backoff: fast)
        let states = connection.states()
        let events = connection.events()
        #expect(await reach(.online, connection))
        connection.close()
        let seen = await within { () async -> [EaslConnection.State]? in
            var seen: [EaslConnection.State] = []
            for await state in states { seen.append(state) }
            return seen
        }
        #expect(seen?.last == .offline, "the states stream finished")
        let ended = await within { () async -> Bool? in
            for await _ in events {}
            return true
        }
        #expect(ended == true, "the events stream finished")
        let pings = server.calls.filter { $0 == "system.ping" }.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.calls.filter { $0 == "system.ping" }.count == pings)
        await #expect(throws: EaslConnection.Failure.self) { try await connection.request("echo") }
    }

    @Test func backoffDoublesUpToItsMaximum() {
        let backoff = EaslConnection.Backoff(initial: .milliseconds(500), maximum: .seconds(30))
        #expect((1...8).map { backoff.delay(after: $0) } == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
    }
}
