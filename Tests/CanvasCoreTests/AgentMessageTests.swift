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
        integration.send(#"{"id":"poll","method":"agent.inbox","params":{"tile":"\#(reviewer)","waitMs":60000}}"#)
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

        // Released: what is queued bounces; a script's into the board's history.
        try board.releaseAgent(tile: reviewer)
        #expect(board.messages[reviewer] == nil)
        #expect(board.activity.query(since: nil, limit: 10, kinds: [.message]).entries.map(\.summary) == ["undelivered to reviewer@root: Nightly failed. (from machine-watch)"])

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

    /// `agent.prompt` once more with its outcome: the error code, else the delivery.
    func sent(_ client: LineClient, _ params: [String: JSONValue]) async throws -> JSONValue {
        let reply = try await call(client, "agent.prompt", params)
        return reply["error"]?["code"] ?? reply["result"]?["delivery"] ?? .null
    }

    @Test func aSessionThatEndsWhileAMessageIsSentGetsNothingAndTheSenderIsTold() async throws {
        let reviewer = terminal("reviewer")
        try omp(reviewer, .idle, seq: 1)
        try board.reportSession(tile: reviewer, kind: "omp", sessionId: "ses_1", sessionPath: nil)
        let client = try connect()
        // The terminal's text is read before the message is queued: the agent exits meanwhile.
        router.readTerminal = { board, tile, _ in
            try? board.releaseAgent(tile: tile)
            return nil
        }
        #expect(try await sent(client, ["target": .string(reviewer), "text": "one"]) == "unavailable")
        #expect(board.messages[reviewer] == nil)

        // Another conversation started there meanwhile: not the session it was sent to.
        try omp(reviewer, .idle, seq: 2)
        try board.reportSession(tile: reviewer, kind: "omp", sessionId: "ses_1", sessionPath: nil)
        router.readTerminal = { board, tile, _ in
            try? board.reportSession(tile: tile, kind: "omp", sessionId: "ses_2", sessionPath: nil)
            return nil
        }
        #expect(try await sent(client, ["target": .string(reviewer), "text": "two"]) == "unavailable")
        #expect(board.messages[reviewer] == nil)

        router.readTerminal = nil
        #expect(try await sent(client, ["target": .string(reviewer), "text": "three"]) == "message")
        #expect(board.messages[reviewer]?.map(\.text) == ["three"])
        #expect(typed.isEmpty)
    }

    @Test func aMessageSentAgainWithItsIdIsQueuedOnceAlsoWhileTheFirstStillReadsTheTerminal() async throws {
        let reviewer = terminal("reviewer"), lead = terminal("lead")
        try omp(reviewer, .idle, seq: 1)
        try omp(lead, .working, seq: 1)
        let first = try connect(), again = try connect()
        let params: [String: JSONValue] = ["target": "reviewer", "text": "Check the cache key.", "caller": .string(lead), "message": "msg_write_toolu_01"]
        // A terminal on another machine has its text read over ssh before the message is queued
        // (2.6 to 10 s to deckbox): the sender's call times out meanwhile, and it sends again.
        var retried: JSONValue?
        router.readTerminal = { [unowned self] _, _, _ in
            guard retried == nil else { return nil }
            retried = .null
            retried = try? await call(again, "agent.prompt", params)
            return nil
        }
        let answered = try await call(first, "agent.prompt", params)
        #expect(retried?["result"]?["message"] == "msg_write_toolu_01" && retried?["result"]?["duplicate"] == nil, "\(String(describing: retried))")
        #expect(answered["result"]?["message"] == "msg_write_toolu_01" && answered["result"]?["duplicate"] == .bool(true), "\(answered)")
        #expect(board.messages[reviewer]?.map(\.id) == ["msg_write_toolu_01"])

        // Queued, it answers a later attempt at once, without reading the terminal again.
        router.readTerminal = { _, _, _ in
            Issue.record("the terminal was read for a message already queued")
            return nil
        }
        let late = try await call(again, "agent.prompt", params)
        #expect(late["result"]?["message"] == "msg_write_toolu_01" && late["result"]?["duplicate"] == .bool(true), "\(late)")
        let taken = try await call(try connect(), "agent.inbox", ["tile": .string(reviewer)])
        #expect(taken["result"]?["messages"]?.array?.map { $0["id"] } == [.string("msg_write_toolu_01")])
        #expect(try await sent(again, ["target": .string(reviewer), "text": "x", "message": "not an id"]) == "invalid_params")
        #expect(typed.isEmpty)
    }

    @Test func oneIdSentToSeveralTerminalsIsAMessageToEachHeldAckedAndBouncedApart() async throws {
        let reviewer = terminal("reviewer"), tester = terminal("tester"), lead = terminal("lead")
        let script = try connect()
        var integrations: [ObjectID: LineClient] = [:]
        for tile in [reviewer, tester, lead] {
            try omp(tile, .idle, seq: 1)
            let sent = try await call(script, "agent.prompt", ["target": .string(tile), "text": "Check the cache key.", "message": "msg_write_toolu_02"])
            #expect(sent["result"]?["message"] == "msg_write_toolu_02" && sent["result"]?["duplicate"] == nil, "\(sent)")
            integrations[tile] = try connect()
        }
        // Each integration takes its own terminal's message while another terminal's of that id is held.
        for (tile, integration) in integrations {
            let taken = try await call(integration, "agent.inbox", ["tile": .string(tile)])
            #expect(taken["result"]?["messages"]?.array?.map { $0["id"] } == [.string("msg_write_toolu_02")], "\(tile): \(taken)")
        }
        // Another terminal's ack, or its bounce, lets go of no other terminal's message.
        let other = try connect(), ack: [String: JSONValue] = ["tile": .string(reviewer), "ack": .array([.string("msg_write_toolu_02")])]
        #expect(try await call(try #require(integrations[reviewer]), "agent.inbox", ack)["result"]?["messages"] == .array([]))
        #expect(try await call(other, "agent.inbox", ["tile": .string(tester)])["result"]?["messages"] == .array([]), "offered again once reviewer acked its own")
        try board.releaseAgent(tile: lead)
        #expect(try await call(other, "agent.inbox", ["tile": .string(tester)])["result"]?["messages"] == .array([]), "offered again once lead's bounced")
        #expect(typed.isEmpty)
    }

    @Test func anIdleIntegrationKilledWithoutItsReleaseTakesNothingMoreAndWhatWaitedBounces() async throws {
        let reviewer = terminal("reviewer"), lead = terminal("lead")
        try omp(reviewer, .idle, seq: 1)
        try omp(lead, .working, seq: 1)
        let client = try connect()
        #expect(try await sent(client, ["target": "reviewer", "text": "Check the cache key.", "caller": .string(lead)]) == "message")

        // SIGKILL: its shell is back at the prompt, with no agent.release.
        board.terminalProgram(reviewer, is: nil)
        #expect(board.objects[reviewer]?.props["agent"]?["kind"] == "omp" && board.objects[reviewer]?.props["agent"]?["protocol"] == nil, "it takes no messages")
        #expect(board.objects[reviewer]?.props["lifecycle"]?["state"] == .string("idle"), "its last state and answer stay")
        #expect(board.messages[reviewer] == nil)
        #expect(board.messages[lead]?.map(\.text) == ["undelivered to reviewer@root: Check the cache key."])
        let refused = try await call(client, "agent.prompt", ["target": "reviewer", "text": "again", "caller": .string(lead)])
        #expect(refused["error"]?["code"] == "unavailable")
        #expect(refused["error"]?["message"]?.string?.contains("exited without releasing the terminal") == true, "\(refused)")
        #expect(try await call(client, "agent.wait", ["target": "reviewer"])["error"]?["code"] == "unavailable")
        #expect(typed.isEmpty, "nothing typed into its shell either")

        // An omp starting there again takes messages.
        try omp(reviewer, .idle, seq: 2)
        #expect(try await sent(client, ["target": "reviewer", "text": "welcome back"]) == "message")
    }

    @Test func aBounceGoesBackToASendingTerminalThatTakesMessagesElseIntoTheBoardsHistory() async throws {
        let reviewer = terminal("reviewer"), lead = terminal("lead"), shell = terminal("shell")
        try omp(reviewer, .working, seq: 1)
        try omp(lead, .idle, seq: 1)
        let client = try connect(), integration = try connect()
        _ = try await sent(client, ["target": "reviewer", "text": "Check the cache key.\nThen the locale.", "caller": .string(lead)])
        _ = try await sent(client, ["target": "reviewer", "text": "From a plain shell.", "caller": .string(shell)])
        _ = try await sent(client, ["target": "reviewer", "text": "Nightly failed.", "from": "machine-watch"])
        try board.releaseAgent(tile: reviewer)

        // The lead's omp takes it as a message from easl, on the user's behalf.
        let back = try await call(integration, "agent.inbox", ["tile": .string(lead)])
        let bounce = try #require(back["result"]?["messages"]?.array?.first, "\(back)")
        #expect(back["result"]?["messages"]?.array?.count == 1)
        #expect(bounce["text"] == "undelivered to reviewer@root: Check the cache key.…")
        #expect(bounce["from"] == .object(["name": "easl"]) && bounce["attribution"] == "user")
        // A terminal that takes no messages, and a script: logged with the receiver's board.
        let logged = board.activity.query(since: nil, limit: 10, kinds: [.message]).entries
        #expect(logged.map(\.summary) == ["undelivered to reviewer@root: From a plain shell. (from shell@root)",
                                          "undelivered to reviewer@root: Nightly failed. (from machine-watch)"])
        #expect(logged.allSatisfy { $0.id == reviewer })
        let history = try await call(client, "board.history", ["board": .string(board.id), "kinds": ["message"]])
        #expect(history["result"]?["entries"]?.array?.count == 2, "\(history)")
    }

    @Test func aFailedBatchPutsBackTheQueueAndOldNamesOfATerminalItDeleted() async throws {
        let reviewer = terminal("reviewer"), lead = terminal("lead")
        try omp(reviewer, .idle, seq: 1)
        try omp(lead, .idle, seq: 1)
        _ = try board.update(reviewer, props: .object(["name": "critic"]))
        let client = try connect()
        #expect(try await sent(client, ["target": "reviewer", "text": "one", "caller": .string(lead)]) == "message")
        let queued = board.messages[reviewer]

        let batch = try await call(client, "object.batch", ["board": .string(board.id), "ops": .array([
            .object(["method": "object.delete", "params": .object(["id": .string(reviewer)])]),
            .object(["method": "object.update", "params": .object(["id": "obj_missing", "props": .object(["x": 1])])]),
        ])])
        #expect(batch["error"] != nil, "\(batch)")
        #expect(board.objects[reviewer] != nil)
        #expect(board.messages[reviewer] == queued)
        #expect(board.aliases(of: reviewer) == ["reviewer"])
        #expect(board.messages[lead] == nil, "nothing bounced")

        // Deleted for good, it bounces under the name it had.
        _ = try await call(client, "object.delete", ["id": .string(reviewer)])
        #expect(board.messages[lead]?.map(\.text) == ["undelivered to critic@root: one"])
    }

    @Test func aBareNameIsEachBoardsCurrentNameElseItsAliasAndMatchesOnTwoBoardsAreAmbiguous() async throws {
        let client = try connect()
        func resolved(_ target: String, caller: ObjectID? = nil) async throws -> JSONValue {
            var params: [String: JSONValue] = ["target": .string(target), "until": ["unknown"]]
            if let caller { params["caller"] = .string(caller) }
            let reply = try await call(client, "agent.wait", params)
            return reply["result"]?["agent"]?["tile"] ?? reply["error"] ?? .null
        }
        let other = registry.open(root: dir.appendingPathComponent("other"))
        let renamed = terminal("reviewer"), elsewhere = terminal("reviewer", on: other)
        let lead = terminal("lead"), scout = terminal("scout", on: other)
        _ = try board.update(renamed, props: .object(["name": "critic"]))

        // root reaches `reviewer` by its alias, other by its name: neither wins for a script.
        let ambiguous = try await resolved("reviewer")
        #expect(ambiguous["code"] == "ambiguous")
        #expect(ambiguous["message"]?.string?.contains("critic@root (\(renamed)), reviewer@other (\(elsewhere))") == true, "\(ambiguous)")
        // The caller's own board first, its alias included.
        #expect(try await resolved("reviewer", caller: lead) == .string(renamed))
        #expect(try await resolved("reviewer", caller: scout) == .string(elsewhere))
        #expect(try await resolved("reviewer@root") == .string(renamed))
    }

    @Test func anAddressReachesItsTerminalAloneWhereFolderNamesRepeatOrABoardsFolderIsGone() async throws {
        let client = try connect()
        let roots = ["a/client", "b/client", "gone"].map { dir.appendingPathComponent($0) }
        for root in roots { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let (first, second, archived) = (registry.open(root: roots[0]), registry.open(root: roots[1]), registry.open(root: roots[2]))
        try FileManager.default.removeItem(at: roots[2])
        let tiles: [(ObjectID, String)] = [
            (terminal("reviewer", on: first), "reviewer@\(first.id)"),
            (terminal("lead", on: second), "lead@\(second.id)"),
            (terminal("scout", on: archived), "scout@\(archived.id)"),
            (terminal("solo"), "solo@root"),
        ]
        let twin = terminal("twin")
        _ = terminal("twin")
        let listed = try #require(try await call(client, "agent.list", [:])["result"]?["agents"]?.array)
        func address(_ tile: ObjectID) -> JSONValue? { listed.first { $0["tile"] == .string(tile) }?["address"] }
        for (tile, expected) in tiles {
            #expect(address(tile) == .string(expected))
            let reached = try await call(client, "agent.wait", ["target": .string(expected), "until": ["unknown"]])
            #expect(reached["result"]?["agent"]?["tile"] == .string(tile), "\(expected): \(reached)")
        }
        #expect(address(twin) == .string(twin), "a name shared on its board: the tile id")

        // A message's reply address is one of these.
        let receiver = terminal("receiver")
        try omp(receiver, .idle, seq: 1)
        _ = try await sent(client, ["target": .string(receiver), "text": "hi", "caller": .string(tiles[1].0)])
        let taken = try await call(client, "agent.inbox", ["tile": .string(receiver)])
        #expect(taken["result"]?["messages"]?.array?.first?["from"]?["address"] == .string("lead@\(second.id)"), "\(taken)")
    }

    @Test func queuedMessagesAreSavedWithTheBoardAndLeftOutOfItsExport() async throws {
        let reviewer = terminal("reviewer"), lead = terminal("lead")
        let note = board.create(type: .note, props: .object(["markdown": "The cache key must include the locale."])).id
        try omp(reviewer, .working, seq: 1)
        let client = try connect()
        _ = try await sent(client, ["target": "reviewer", "text": "Check the key.", "caller": .string(lead), "mentions": [.object(["object": .string(note)])]])
        _ = try await sent(client, ["target": "reviewer", "text": "Nightly failed.", "from": "machine-watch", "when": "next-turn"])
        registry.store.save(board)

        let reloaded = registry.store.load(root: dir.appendingPathComponent("root"))
        let saved = try #require(board.messages[reviewer]), loaded = try #require(reloaded.messages[reviewer])
        #expect(loaded.map(\.id) == saved.map(\.id))
        for (was, now) in zip(saved, loaded) {
            #expect(now.text == was.text && now.from == was.from && now.label == was.label && now.when == was.when && now.mentions.map(\.id) == was.mentions.map(\.id))
            #expect(abs(now.queuedAt.timeIntervalSince(was.queuedAt)) < 1, "ISO 8601 to the second")
        }
        let exported = dir.appendingPathComponent("export.json")
        try BoardStore.export(board, to: exported)
        #expect(!(try String(contentsOf: exported, encoding: .utf8)).contains("Nightly failed."))
    }
}
