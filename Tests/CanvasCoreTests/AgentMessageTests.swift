import Foundation
import Testing
import CanvasCore

/// Out-of-band `agent.prompt` and agent addresses (docs/contracts.md, Peer messages, Agent
/// addresses), driven over the real socket the way integrations and agents use it.
@MainActor
final class AgentMessageTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let router: ApiRouter
    let server: SocketServer
    let board: Board
    var typed: [String] = []

    init() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("other"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards")))
        board = registry.open(root: dir.appendingPathComponent("root"))
        let router = ApiRouter(registry: registry)
        self.router = router
        server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        router.submitToTerminal = { [unowned self] _, _, text in
            typed.append(text)
            return true
        }
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func connect() throws -> LineClient { try LineClient(path: dir.appendingPathComponent("s").path) }

    func call(_ client: LineClient, _ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let request: JSONValue = .object(["id": .string(method), "method": .string(method), "params": .object(params)])
        client.send(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        return try await client.next()
    }

    func terminal(_ name: String?, on board: Board? = nil) -> ObjectID {
        var props: [String: JSONValue] = ["cwd": .string(dir.path)]
        if let name { props["name"] = .string(name) }
        return (board ?? self.board).create(type: .terminal, props: .object(props)).id
    }

    /// An omp whose extension takes messages, in `state`.
    func omp(_ tile: ObjectID, _ state: LifecycleState, seq: Int, on board: Board? = nil) throws {
        try (board ?? self.board).reportLifecycle(tile: tile, kind: "omp", state: state, message: nil, seq: seq, source: "canvas-omp", protocol: 1)
    }

    @Test func aPromptToAnIntegrationThatTakesMessagesIsQueuedForItAndNeverTyped() async throws {
        let reviewer = terminal("reviewer"), lead = terminal("lead")
        let note = board.create(type: .note, props: .object(["markdown": .string("The cache key must include the locale.")])).id
        try omp(reviewer, .idle, seq: 1)
        try omp(lead, .working, seq: 1)
        // A blocked target too: the message never reaches its dialog.
        try board.reportLifecycle(tile: reviewer, kind: "omp", state: .blocked, message: "Deploy?", seq: 2, source: "canvas-omp", protocol: 1)
        let agent = try connect(), integration = try connect(), other = try connect()

        let sent = try await call(agent, "agent.prompt", ["target": .string("reviewer"), "text": .string("Check the cache key."), "caller": .string(lead),
                                                          "mentions": .array([.object(["object": .string(note)])])])
        #expect(sent["result"]?["delivery"] == .string("message"), "\(sent)")
        #expect(sent["result"]?["mentions"]?.array?.count == 1)
        #expect(typed.isEmpty, "nothing typed into the terminal")
        let id = try #require(sent["result"]?["message"]?.string)

        let taken = try await call(integration, "agent.inbox", ["tile": .string(reviewer)])
        let message = try #require(taken["result"]?["messages"]?.array?.first)
        #expect(message["id"] == .string(id) && message["text"] == .string("Check the cache key."))
        #expect(message["attribution"] == .string("agent") && message["when"] == .string("now"))
        #expect(message["from"] == .object(["tile": .string(lead), "name": .string("lead"), "address": .string("lead@root"), "board": .string(board.id)]))
        let context = try #require(message["context"]?.string)
        #expect(context.contains("Attached by terminal \(lead) \"lead\" to its prompt to you (agent.prompt):"))
        #expect(context.contains("The cache key must include the locale."))
        // Held by the integration's connection until it acks.
        #expect(try await call(other, "agent.inbox", ["tile": .string(reviewer)])["result"]?["messages"] == .array([]))
        #expect(try await call(agent, "agent.read", ["target": .string("reviewer"), "final": .bool(true)])["error"]?["message"]?.string?.contains("(prompted)") == true)

        // agent.wait waits while the message is undelivered, then for the turn it started.
        try board.reportLifecycle(tile: reviewer, kind: "omp", state: .idle, message: nil, seq: 3, source: "canvas-omp", protocol: 1)
        agent.send(#"{"id":"w","method":"agent.wait","params":{"target":"reviewer"}}"#)
        #expect(try await call(integration, "agent.inbox", ["tile": .string(reviewer), "ack": .array([.string(id)]), "started": .bool(true)])["result"]?["messages"] == .array([]))
        #expect(board.messages[reviewer] == nil)
        agent.send(#"{"id":"ping","method":"system.ping","params":{}}"#)
        #expect(try await agent.next()["id"] == .string("ping"), "the idle from before the delivery doesn't answer")
        try omp(reviewer, .working, seq: 4)
        try board.reportLifecycle(tile: reviewer, kind: "omp", state: .idle, message: nil, seq: 5, source: "canvas-omp", final: "Done.", protocol: 1)
        let waited = try await agent.next()
        #expect(waited["id"] == .string("w") && waited["result"]?["agent"]?["lifecycle"]?["state"] == .string("done"), "\(waited)")
        #expect(typed.isEmpty)
    }

    @Test func aScriptsMessageIsTheUsersAndALongPollTakesItAsItArrives() async throws {
        let reviewer = terminal("reviewer"), lead = terminal("lead")
        try omp(reviewer, .working, seq: 1)
        let script = try connect(), integration = try connect()
        integration.send(#"{"id":"poll","method":"agent.inbox","params":{"tile":"\#(reviewer)","waitMs":10000}}"#)
        integration.send(#"{"id":"ping","method":"system.ping","params":{}}"#)
        #expect(try await integration.next()["id"] == .string("ping"), "nothing waits yet")

        // `from` names a script even when a caller (filled from EASL_TILE_ID) comes along.
        let sent = try await call(script, "agent.prompt", ["target": .string("reviewer@root"), "text": .string("Nightly failed."), "from": .string("machine-watch"),
                                                           "when": .string("next-turn"), "caller": .string(lead)])
        #expect(sent["result"]?["delivery"] == .string("message"), "\(sent)")
        let polled = try await integration.next()
        let message = try #require(polled["result"]?["messages"]?.array?.first, "\(polled)")
        #expect(message["from"] == .object(["name": .string("machine-watch")]))
        #expect(message["attribution"] == .string("user") && message["when"] == .string("next-turn"))

        // Released: what is queued is dropped.
        try board.releaseAgent(tile: reviewer)
        #expect(board.messages[reviewer] == nil)

        // No message integration: next-turn into a working agent would join its turn when typed.
        let claude = terminal("claude")
        try board.reportLifecycle(tile: claude, kind: "claude", state: .working, message: nil, seq: 1, source: "canvas-claude")
        let refused = try await call(script, "agent.prompt", ["target": .string("claude"), "text": .string("after this"), "when": .string("next-turn")])
        #expect(refused["error"]?["code"] == .string("conflict"), "\(refused)")
        #expect(try await call(script, "agent.prompt", ["target": .string("claude"), "text": .string("now then")])["result"]?["delivery"] == .string("typed"))
        #expect(typed == ["now then"])
        #expect(try await call(script, "agent.prompt", ["target": .string("claude"), "text": .string("x"), "when": .string("later")])["error"]?["code"] == .string("invalid_params"))
    }

    @Test func aMessageHeldByAConnectionThatClosesIsOfferedAgain() async throws {
        let reviewer = terminal("reviewer")
        try omp(reviewer, .idle, seq: 1)
        let script = try connect()
        _ = try await call(script, "agent.prompt", ["target": .string(reviewer), "text": .string("one")])
        var first: LineClient? = try connect()
        #expect(try await call(first!, "agent.inbox", ["tile": .string(reviewer)])["result"]?["messages"]?.array?.count == 1)
        first = nil
        try await Task.sleep(for: .milliseconds(200))
        let next = try connect()
        let again = try await call(next, "agent.inbox", ["tile": .string(reviewer)])
        #expect(again["result"]?["messages"]?.array?.first?["text"] == .string("one"), "\(again)")
    }

    @Test func addressesAreNameAtBoardWithAliasesAndTheCallersBoardFirst() async throws {
        let client = try connect()
        func resolved(_ target: String, caller: ObjectID? = nil) async throws -> JSONValue {
            var params: [String: JSONValue] = ["target": .string(target), "until": .array([.string("unknown")])]
            if let caller { params["caller"] = .string(caller) }
            let reply = try await call(client, "agent.wait", params)
            return reply["result"]?["agent"]?["tile"] ?? reply["error"] ?? .null
        }
        let other = registry.open(root: dir.appendingPathComponent("other"))
        let here = terminal("reviewer"), there = terminal("reviewer", on: other), lead = terminal("lead")

        #expect(try await resolved("reviewer@root") == .string(here))
        #expect(try await resolved("reviewer@other") == .string(there))
        #expect(try await resolved("reviewer@\(other.id)") == .string(there))
        #expect(try await resolved("reviewer", caller: lead) == .string(here), "the caller's board first")
        let ambiguous = try await resolved("reviewer")
        #expect(ambiguous["code"] == .string("ambiguous"))
        #expect(ambiguous["message"]?.string?.contains("reviewer@other (\(there)), reviewer@root (\(here))") == true, "\(ambiguous)")
        #expect(try await resolved("reviewer@nowhere")["message"] == .string("no open board named nowhere (open boards: other, root)"))
        #expect(try await resolved("nobody@root")["code"] == .string("not_found"))

        // Renamed: the old name is an alias, listed with the agent, until another terminal takes it.
        _ = try board.update(here, props: .object(["name": .string("critic")]))
        #expect(try await resolved("reviewer", caller: lead) == .string(here))
        let listed = try await call(client, "agent.list", [:])["result"]?["agents"]?.array?.first { $0["tile"] == .string(here) }
        #expect(listed?["address"] == .string("critic@root") && listed?["aliases"] == .array([.string("reviewer")]), "\(String(describing: listed))")
        let taker = terminal("reviewer")
        #expect(try await resolved("reviewer", caller: lead) == .string(taker))
        #expect(board.aliases(of: here).isEmpty)

        // Saved with the board.
        _ = try board.update(taker, props: .object(["name": .string("auditor")]))
        let reloaded = Board(snapshot: board.snapshot)
        #expect(reloaded.aliases(of: taker) == ["reviewer"])
    }
}
