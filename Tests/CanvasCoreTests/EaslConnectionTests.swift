import Darwin
import Foundation
import Testing
@testable import CanvasCore

/// The client connection remote boards use: a Unix socket, or a relay process's stdio (the tests
/// relay with `nc -U`, as `ssh <host> nc -U` does on the host).
final class EaslConnectionTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("ec-\(UUID().uuidString.prefix(8))")
    var path: String { dir.appendingPathComponent("s").path }
    let fast = EaslConnection.Backoff(initial: .milliseconds(50), maximum: .milliseconds(400))

    init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: dir) }

    /// A stand-in for easl's socket: `system.ping`, `events.subscribe` (remembered, so the test
    /// can push events), `echo` (its params), `later` (answered after `ms`, out of order), `fail`;
    /// and easld's own calls to the client (`call`), whose answers it keeps, as it keeps the
    /// events the client pushes.
    final class FakeServer: @unchecked Sendable {
        /// What the server was asked, shared with its handler.
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var subscribers: [(SocketServer.Connection, JSONValue)] = []
            var methods: [String] = []
            var boardLists = 0
            /// Each link, by its ping.
            var links: [SocketServer.Connection] = []
            /// The client's answers to `call`s, in the order they came.
            var answers: [JSONValue] = []
            /// The events the client pushed, in the order they came.
            var pushes: [JSONValue] = []
        }

        let server: SocketServer
        private let log = Log()

        init(path: String) throws {
            let log = log
            server = SocketServer(path: path) { request, connection in
                let id = request["id"] ?? .null
                guard let method = request["method"]?.string else {
                    if request["event"] != nil {
                        log.lock.withLock { log.pushes.append(request) }
                    } else {
                        log.lock.withLock { log.answers.append(request) }
                    }
                    return nil
                }
                let params = request["params"] ?? .object([:])
                log.lock.withLock { log.methods.append(method) }
                switch method {
                case "system.ping":
                    log.lock.withLock { log.links.append(connection) }
                    return .object(["id": id, "ok": .bool(true), "result": params])
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
                case "board.list":
                    // The first one fails, as a host that was busy.
                    let first = log.lock.withLock { () -> Bool in
                        log.boardLists += 1
                        return log.boardLists == 1
                    }
                    if first { return .object(["id": id, "ok": .bool(false), "error": .object(["code": .string("internal"), "message": .string("busy")])]) }
                    let board: JSONValue = .object(["board": .string("brd_a"), "root": .string("/Users/tim/dev/alpha"), "open": .bool(true), "archived": .bool(false)])
                    return .object(["id": id, "ok": .bool(true), "result": .object(["boards": .array([board])])])
                case "agent.list":
                    return .object(["id": id, "ok": .bool(true), "result": .object(["agents": .array([])])])
                case "hang":
                    return nil
                default:
                    return .object(["id": id, "ok": .bool(true), "result": params])
                }
            }
            try server.start()
        }

        func stop() { server.stop() }

        /// Sends the client a call of easld's on the latest link; `surfaceEvents` goes beside its
        /// params, as easld sends a relayed `surface.stream`.
        func call(_ id: String, _ method: String, _ params: JSONValue, surfaceEvents: [String]? = nil) {
            var message: [String: JSONValue] = ["id": .string(id), "method": .string(method), "params": params]
            if let surfaceEvents { message["surfaceEvents"] = .array(surfaceEvents.map(JSONValue.string)) }
            log.lock.withLock { log.links.last }?.send(.object(message))
        }

        /// The client's answers once there are `count` (or what came within 30 s).
        func answers(_ count: Int) async -> [JSONValue] {
            let deadline = Date().addingTimeInterval(30)
            while log.lock.withLock({ log.answers.count }) < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            return log.lock.withLock { log.answers }
        }

        /// The events the client pushed once there are `count` (or what came within 30 s).
        func pushes(_ count: Int) async -> [JSONValue] {
            let deadline = Date().addingTimeInterval(30)
            while log.lock.withLock({ log.pushes.count }) < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            return log.lock.withLock { log.pushes }
        }

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
    func largeAndSmallConcurrentRequestsArriveWholeWithoutInterleaving(_ transport: String) async throws {
        let server = try FakeServer(path: path)
        defer { server.stop() }
        let connection = transport == "socket" ? EaslConnection.unixSocket(path) : relay()
        defer { connection.close() }
        let text = "begin\n" + String(repeating: "0123456789abcdef", count: 65_536) + "\nend"
        async let large = connection.request("echo", .object(["text": .string(text)]), timeout: .seconds(10))
        async let next = connection.request("echo", .object(["after": "large request"]), timeout: .seconds(10))
        let (whole, following) = try await (large, next)
        #expect(whole == .object(["text": .string(text)]))
        #expect(following == .object(["after": "large request"]))
    }

    @Test func theFirstSocketHandshakeGoesOnlineWhileGlobalWorkersAreBlocked() async throws {
        let isolated = try await runIsolatedTestIfParallel("theFirstSocketHandshakeGoesOnlineWhileGlobalWorkersAreBlocked")
        if isolated { return }
        let server = try FakeServer(path: path)
        defer { server.stop() }
        let path = path
        typealias Observation = (saturated: Bool, first: EaslConnection.State?, ping: String?, reader: Task<Void, Never>?)
        let result: Observation = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let observe = { () -> Observation in
                    let release = DispatchSemaphore(value: 0)
                    let blockers = DispatchGroup()
                    let started = Locked(0)
                    // Darwin's constrained worker cap is max(64, 5 * CPUs). Queue more without
                    // depending on the capacity this particular runner actually grants.
                    let count = max(128, ProcessInfo.processInfo.activeProcessorCount * 5 + 16)
                    for _ in 0..<count {
                        blockers.enter()
                        DispatchQueue.global().async {
                            defer { blockers.leave() }
                            started.withLock { $0 += 1 }
                            release.wait()
                        }
                    }
                    var connection: EaslConnection?
                    defer {
                        for _ in 0..<count { release.signal() }
                        blockers.wait()
                        connection?.close()
                        if let connection { _ = connection.state }
                    }

                    let setupDeadline = ContinuousClock.now + .seconds(15)
                    var lastCount = 0
                    var lastChange = ContinuousClock.now
                    var saturated = false
                    while ContinuousClock.now < setupDeadline {
                        let currentCount = started.withLock { $0 }
                        if currentCount != lastCount {
                            lastCount = currentCount
                            lastChange = .now
                        }
                        if currentCount > 0, ContinuousClock.now - lastChange >= .seconds(2) {
                            saturated = true
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.01)
                    }

                    guard saturated else {
                        return (saturated: false, first: nil, ping: nil, reader: nil)
                    }
                    let first = Locked<EaslConnection.State?>(nil)
                    let deadline = ContinuousClock.now + .seconds(10)
                    let client = EaslConnection.unixSocket(path)
                    connection = client
                    let states = client.states()
                    let reader = Task {
                        for await state in states {
                            if state == .online || state == .offline {
                                first.withLock { $0 = state }
                                break
                            }
                        }
                    }
                    while first.withLock({ $0 == nil }), ContinuousClock.now < deadline {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    let outcome = first.withLock { $0 }
                    let ping = server.calls.first
                    reader.cancel()
                    return (saturated: true, first: outcome, ping: ping, reader: reader)
                }
                continuation.resume(returning: observe())
            }
        }
        await result.reader?.value
        try #require(result.saturated, "global blockers did not reach a stable started count within 15 seconds")
        #expect(result.first == .online, "the first handshake must finish before its unchanged 10-second deadline")
        #expect(result.ping == "system.ping")
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

    /// ssh closes its stdout before it exits with the remote command's status (nc finding no
    /// socket on the host exits 1); that status, not a kill's, says the host was reached.
    @Test func aRelayThatClosesItsOutputFirstReportsItsOwnExit() async throws {
        let connection = EaslConnection.process("/bin/sh", ["-c", "exec >&-; sleep 0.5; exit 1"], backoff: .init(initial: .seconds(30), maximum: .seconds(30)))
        defer { connection.close() }
        #expect(await reach(.offline, connection))
        #expect(connection.relayStatus == 1)
        #expect(connection.problem == "sh exited with status 1")
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

    /// Retry on a live link: a failed `board.list` leaves the link `online`, where `reconnect()`
    /// sends nothing, so the picker asks again.
    @Test func aFailedBoardListLeavesTheLinkOnlineSoRetryLoadsItAgain() async throws {
        let server = try FakeServer(path: path)
        defer { server.stop() }
        let connection = relay()
        defer { connection.close() }
        #expect(await reach(.online, connection))
        await #expect(throws: EaslConnection.Failure("internal", "busy")) { try await RemoteBoard.load(on: connection) }
        #expect(RemoteBoard.Retry(connection: connection.state) == .reload)
        let boards = try await RemoteBoard.load(on: connection)
        #expect(boards.map(\.name) == ["alpha"])
        #expect(connection.state == .online)
    }

    @Test func retryReloadsAnOnlineLinkAndReconnectsADownOne() {
        #expect(RemoteBoard.Retry(connection: .online) == .reload)
        #expect(RemoteBoard.Retry(connection: .offline) == .reconnect)
        #expect(RemoteBoard.Retry(connection: .connecting) == .reconnect)
        #expect(RemoteBoard.Retry(connection: nil) == .discover, "the host wasn't found: there's no connection")
    }

    /// What quitting does: the relay is gone when `terminateAll` returns (not left to see its
    /// stdin close), and nothing starts another.
    @Test func terminatingEveryRelayEndsThemBeforeReturningAndStartsNoOther() async throws {
        let file = dir.appendingPathComponent("pid").path
        let processes = RemoteProcesses()
        let connection = EaslConnection.process("/bin/sh", ["-c", "echo $$ > '\(file)'; exec sleep 60"], backoff: fast, handshakeTimeout: .seconds(60), processes: processes)
        defer { connection.close() }
        var pid: Int32?
        for _ in 0..<3000 where pid == nil {
            pid = (try? String(contentsOfFile: file, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if pid == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let relay = try #require(pid)
        #expect(processes.count == 1)
        processes.terminateAll()
        #expect(kill(relay, 0) == -1 && errno == ESRCH, "reaped before terminateAll returned")
        // The link notices and reconnects with backoff: the relay it asks for isn't started.
        let refused = await within { () async -> Bool? in
            while connection.problem?.contains("quitting") != true { try? await Task.sleep(for: .milliseconds(10)) }
            return true
        }
        #expect(refused == true)
        #expect(processes.count == 0)
    }

    @Test func backoffDoublesUpToItsMaximum() {
        let backoff = EaslConnection.Backoff(initial: .milliseconds(500), maximum: .seconds(30))
        #expect((1...8).map { backoff.delay(after: $0) } == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
    }

    // MARK: easld's calls (client.attach)

    /// easld writes its calls on the client's own link; each is answered with its id as it
    /// finishes, in any order, while the link's own requests go on.
    @Test func easldsCallsAreAnsweredWithTheirIdsAsEachFinishesAndTheLinkGoesOn() async throws {
        let server = try FakeServer(path: path)
        defer { server.stop() }
        let connection = EaslConnection.unixSocket(path, backoff: fast)
        defer { connection.close() }
        let (held, release) = AsyncStream.makeStream(of: Void.self)
        connection.serve { call in
            switch call.method {
            case "view.snapshot":
                for await _ in held {}
                return .success(.object(["path": "/tmp/easl-renders/snapshot.png"]))
            case "agent.prompt":
                return .failure(EaslConnection.Failure("conflict", "obj_t is blocked"))
            default:
                return .success(call.params)
            }
        }
        #expect(await reach(.online, connection))
        server.call("easld-1", "view.snapshot", .object(["board": "brd_a"]))
        server.call("easld-2", "view.get", .object(["board": "brd_a"]))
        server.call("easld-3", "agent.prompt", .object(["target": "obj_t", "text": "hi"]))
        let first = await server.answers(2)
        let echoed = try await connection.request("echo", .object(["n": 4]))
        #expect(echoed["n"] == .number(4), "a call still out holds up none of the link's own requests")
        release.finish()
        let all = await server.answers(3)
        let viewGet: JSONValue = .object(["id": "easld-2", "ok": .bool(true), "result": .object(["board": "brd_a"])])
        let refused: JSONValue = .object(["id": "easld-3", "ok": .bool(false), "error": .object(["code": "conflict", "message": "obj_t is blocked"])])
        #expect(first.count == 2 && first.contains(viewGet) && first.contains(refused))
        #expect(all.count == 3)
        #expect(all.last == .object(["id": "easld-1", "ok": .bool(true), "result": .object(["path": "/tmp/easl-renders/snapshot.png"])]))
    }

    /// An answer whose link dropped goes nowhere: a new link's ids start again, so the old answer
    /// would answer another call there.
    @Test func anAnswerWhoseLinkDroppedIsNotWrittenOnTheNextLink() async throws {
        var server = try FakeServer(path: path)
        let connection = EaslConnection.unixSocket(path, backoff: fast)
        defer { connection.close() }
        let (held, release) = AsyncStream.makeStream(of: Void.self)
        let started = Locked(false), finished = Locked(false)
        connection.serve { call in
            if call.method == "agent.read" {
                started.withLock { $0 = true }
                for await _ in held {}
                finished.withLock { $0 = true }
            }
            return .success(.object(["answers": .string(call.method)]))
        }
        #expect(await reach(.online, connection))
        server.call("easld-1", "agent.read", .object(["target": "obj_t"]))
        let deadline = Date().addingTimeInterval(30)
        while !started.withLock({ $0 }), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        server.stop()
        #expect(await reach(.offline, connection))
        server = try FakeServer(path: path)
        defer { server.stop() }
        #expect(await reach(.online, connection))
        release.finish()
        while !finished.withLock({ $0 }), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(200))
        server.call("easld-1", "view.get", .object(["board": "brd_a"]))
        #expect(await server.answers(1) == [.object(["id": "easld-1", "ok": .bool(true), "result": .object(["answers": "view.get"])])])
        try await Task.sleep(for: .milliseconds(200))
        #expect(await server.answers(1).count == 1, "the dropped link's agent.read answer never reached the new link")
    }

    /// Before anything serves easld's calls (a viewer that hasn't attached), one is refused at once
    /// rather than left to easld's deadline.
    @Test func aCallNothingServesIsAnsweredUnavailable() async throws {
        let server = try FakeServer(path: path)
        defer { server.stop() }
        let connection = EaslConnection.unixSocket(path, backoff: fast)
        defer { connection.close() }
        #expect(await reach(.online, connection))
        server.call("easld-7", "view.get", .object(["board": "brd_a"]))
        let answers = await server.answers(1)
        #expect(answers.map { $0["id"] } == [.string("easld-7")])
        #expect(answers.first?["ok"] == .bool(false) && answers.first?["error"]?["code"] == .string("unavailable"))
    }

    /// A stream answering one of easld's calls pushes its events on the link that call came on,
    /// and on no other: once that link drops, its origin is closed and a push goes nowhere, so
    /// nothing encoded for it reaches the server on the next link.
    @Test func anOriginPushesOnlyOnTheLinkItsCallCameOn() async throws {
        var server = try FakeServer(path: path)
        let connection = EaslConnection.unixSocket(path, backoff: fast)
        defer { connection.close() }
        let calls = Locked<[EaslConnection.Call]>([])
        connection.serve { call in
            calls.withLock { $0.append(call) }
            return .success(.object(["stream": "str_1"]))
        }
        #expect(await reach(.online, connection))
        server.call("easld-1", "surface.stream", .object(["id": "obj_page"]), surfaceEvents: ["surface.frame", "surface.notice"])
        _ = await server.answers(1)
        let opened = try #require(calls.withLock { $0.first })
        #expect(opened.surfaceEvents == ["surface.frame", "surface.notice"])
        #expect(opened.origin.isOpen)
        let notice = try EventLine("surface.notice", board: "brd_a", SurfaceEvent.notice(stream: "str_1", kind: .refused, reason: "menu"))
        #expect(opened.origin.push(notice))
        #expect(await server.pushes(1) == [.object(["event": "surface.notice", "board": "brd_a", "data": .object(["stream": "str_1", "kind": "refused", "reason": "menu"])])])

        server.stop()
        #expect(await reach(.offline, connection))
        #expect(!opened.origin.isOpen)
        server = try FakeServer(path: path)
        defer { server.stop() }
        #expect(await reach(.online, connection))
        #expect(!opened.origin.push(notice), "a reconnect is a new link")
        server.call("easld-1", "surface.ack", .object(["stream": "str_1", "frame": 0]))
        _ = await server.answers(1)
        let next = try #require(calls.withLock { $0.last })
        #expect(next.origin != opened.origin && next.origin.isOpen)
        #expect(next.surfaceEvents.isEmpty, "only a relayed open says what its viewer hears")
        try await Task.sleep(for: .milliseconds(200))
        #expect(await server.pushes(0).isEmpty, "nothing pushed for the dropped link reached the next one")
    }

    func blockedRelay(callID: String = "open", method: String = "surface.stream") throws ->
        (connection: EaslConnection, request: URL, gate: URL, captured: URL) {
        let request = dir.appendingPathComponent("request")
        let gate = dir.appendingPathComponent("release")
        let captured = dir.appendingPathComponent("captured")
        try #require(mkfifo(gate.path, 0o600) == 0)
        try #require(mkfifo(request.path, 0o600) == 0)
        let script = """
        IFS= read -r ping
        printf '%s\\n' '{"id":"-1","ok":true,"result":{}}'
        IFS= read -r start < '\(request.path)'
        printf '%s\\n' '{"id":"\(callID)","method":"\(method)","params":{}}'
        IFS= read -r release < '\(gate.path)'
        exec 3>&1
        exec cat > '\(captured.path)'
        """
        return (EaslConnection.process("/bin/sh", ["-c", script], backoff: fast), request, gate, captured)
    }

    func releaseBlockedRelay(_ gate: URL) throws {
        let release = try FileHandle(forWritingTo: gate)
        try release.write(contentsOf: Data("go\n".utf8))
        try release.close()
    }

    @Test func aDelegatedReplyLargerThan32MiBArrivesWholeAndItsOriginStillPushes() async throws {
        let (connection, request, gate, captured) = try blockedRelay(callID: "render", method: "view.render")
        defer { connection.close() }
        let text = String(repeating: "/", count: 33 << 19) + "é\nend"
        let encodedText = try JSONEncoder().encode(text)
        let emptyAnswer: JSONValue = .object(["id": "render", "ok": .bool(true), "result": ""])
        let answerBytes = try JSONEncoder().encode(emptyAnswer).count - 2 + encodedText.count + 1
        let origins = Locked<[EaslConnection.Origin]>([])
        let (held, releaseAnswer) = AsyncStream.makeStream(of: Void.self)
        defer { releaseAnswer.finish() }
        connection.serve { call in
            origins.withLock { $0.append(call.origin) }
            for await _ in held {}
            return .success(.string(text))
        }
        try #require(await reach(.online, connection))
        try releaseBlockedRelay(request)
        let deadline = Date().addingTimeInterval(30)
        while origins.withLock({ $0.isEmpty }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let origin = try #require(origins.withLock { $0.first })
        try releaseBlockedRelay(gate)
        releaseAnswer.finish()
        while Date() < deadline {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: captured.path)[.size] as? NSNumber)?.intValue ?? 0
            if bytes >= answerBytes || connection.state == .offline { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let received = (try? Data(contentsOf: captured)) ?? Data()
        try #require(received.count == answerBytes)
        #expect(received.last == 0x0A)
        let result = try #require(received.range(of: Data(#""result":"#.utf8)))
        let scalar = received[result.upperBound...].prefix(encodedText.count)
        #expect(scalar.elementsEqual(encodedText))
        let message = try JSONDecoder().decode(JSONValue.self, from: received.dropLast())
        let correctAnswer = message == .object(["id": "render", "ok": .bool(true), "result": .string(text)])
        #expect(correctAnswer)

        let after = try EventLine("surface.notice", board: "brd_a",
                                  SurfaceEvent.notice(stream: "str_a", kind: .refused, reason: "after render"))
        #expect(origin.isOpen)
        #expect(origin.push(after))
        var following = Data()
        let arrival = Date().addingTimeInterval(30)
        repeat {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: captured.path)[.size] as? NSNumber)?.intValue ?? 0
            if bytes >= answerBytes + after.data.count {
                following = try Data(contentsOf: captured).dropFirst(answerBytes)
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        } while Date() < arrival
        #expect(following.elementsEqual(after.data))
        #expect(connection.state == .online)
    }

    @Test func aBlockedOriginStillDropsItsLinkWhenAggregateOutputExceedsTheBudget() async throws {
        let (connection, request, _, _) = try blockedRelay()
        defer { connection.close() }
        let origins = Locked<[EaslConnection.Origin]>([])
        connection.serve { call in
            origins.withLock { $0.append(call.origin) }
            return .success(.object(["stream": "str_a"]))
        }
        try #require(await reach(.online, connection))
        try releaseBlockedRelay(request)
        let deadline = Date().addingTimeInterval(30)
        while origins.withLock({ $0.isEmpty }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let origin = try #require(origins.withLock { $0.first })
        let line = try EventLine("surface.frame", board: "brd_a",
                                 .object(["data": .string(String(repeating: "x", count: 40 << 20))]))
        #expect(origin.push(line))
        #expect(origin.push(line))
        #expect(connection.state == .online)
        #expect(origin.push(line))
        while origin.isOpen, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!origin.isOpen)
    }

    @Test func aBlockedOriginDropsCanceledRefreshBeforeItsMotionReplacement() async throws {
        let (connection, request, gate, captured) = try blockedRelay()
        defer { connection.close() }
        let calls = Locked<[EaslConnection.Call]>([])
        connection.serve { call in
            calls.withLock { $0.append(call) }
            return .success(.object(["stream": "str_a"]))
        }
        try #require(await reach(.online, connection))
        try releaseBlockedRelay(request)
        let deadline = Date().addingTimeInterval(30)
        while calls.withLock({ $0.isEmpty }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let origin = try #require(calls.withLock { $0.first?.origin })
        let revision = SurfaceInputRevision()
        func line(_ label: String, stream: String = "str_a", bytes: Int = 0) throws -> EventLine {
            try EventLine("surface.frame", board: "brd_a", .object([
                "stream": .string(stream), "label": .string(label),
                "data": .string(String(repeating: "x", count: bytes)),
            ]))
        }
        #expect(origin.push(try line("committed", bytes: 1 << 20)))
        #expect(origin.push(try line("canceled"), whileCurrent: { revision.value == 0 }))
        #expect(origin.push(try line("other", stream: "str_b"), whileCurrent: { true }))
        #expect(connection.state == .online)
        revision.advance()
        #expect(origin.push(try line("motion")))
        let after = try line("after")
        #expect(origin.push(after))
        try releaseBlockedRelay(gate)
        var received = Data()
        let arrival = Date().addingTimeInterval(30)
        repeat {
            received = (try? Data(contentsOf: captured)) ?? Data()
            if received.suffix(after.data.count) == after.data { break }
            try await Task.sleep(for: .milliseconds(10))
        } while Date() < arrival
        try #require(received.suffix(after.data.count) == after.data)
        let messages = try received.split(separator: 0x0A).map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0))
        }
        #expect(messages.filter { $0["event"] != nil }.map { $0["data"]?["label"] } ==
            [.string("committed"), .string("other"), .string("motion"), .string("after")])
    }
    /// easld tells a pushed event from a request by its first bytes alone, so `event` leads.
    @Test func anEventLineLeadsWithItsEvent() throws {
        let line = try EventLine("surface.dialog", board: "brd_a",
                                 SurfaceEvent.dialog(stream: "str_1", dialog: "dlg_1", kind: .confirm, origin: "https://a.example", message: "Leave?"))
        let text = String(decoding: line.data, as: UTF8.self)
        #expect(text.hasPrefix(#"{"event":"surface.dialog","board":"brd_a","data":{"#))
        #expect(text.hasSuffix("}\n") && text.filter { $0 == "\n" }.count == 1)
        #expect(line.line.count == line.data.count - 1 && line.line.last == UInt8(ascii: "}"), "a socket adds its own newline")
        #expect(try JSONDecoder().decode(JSONValue.self, from: line.line) == .object([
            "event": "surface.dialog", "board": "brd_a",
            "data": .object(["stream": "str_1", "dialog": "dlg_1", "kind": "confirm", "origin": "https://a.example", "message": "Leave?"]),
        ]))
    }
}
