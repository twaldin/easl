import Foundation
import Testing
import CanvasCore

/// Agent control over the real socket: agent.list's pid, focus, draft and closed boards, and
/// agent.restart.
@MainActor
final class AgentControlTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let router: ApiRouter
    let server: SocketServer
    let board: Board
    /// The terminal the app says has keyboard focus.
    var focused: ObjectID?
    /// Each terminal's foreground process, as its tile knows it.
    var foreground: [ObjectID: Int32] = [:]
    /// What the app relaunched: tile and argv.
    var restarted: [(ObjectID, [String])] = []
    /// The hosts agent.list asked for their sessions.
    var hostsAsked: [[String]] = []

    init() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards"), debounce: 60))
        board = registry.open(root: dir.appendingPathComponent("root"))
        let router = ApiRouter(registry: registry)
        self.router = router
        server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        router.terminalStatus = { [unowned self] _, tile in TerminalStatus(pid: foreground[tile], focused: tile == focused) }
        router.restartTerminal = { [unowned self] _, tile, argv, killing, ended in
            try killing()
            ended()
            restarted.append((tile, argv))
        }
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        let client = try LineClient(path: dir.appendingPathComponent("s").path)
        let request: JSONValue = .object(["id": "1", "method": .string(method), "params": .object(params)])
        client.send(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        return try await client.next()
    }

    func terminal(on board: Board? = nil, name: String? = nil, command: [String] = []) -> ObjectID {
        var props: [String: JSONValue] = ["cwd": .string(dir.path), "command": .array(command.map(JSONValue.string))]
        if let name { props["name"] = .string(name) }
        return (board ?? self.board).create(type: .terminal, props: .object(props)).id
    }

    func listed() async throws -> [ObjectID: JSONValue] {
        let agents = try await call("agent.list")["result"]?["agents"]?.array ?? []
        return Dictionary(uniqueKeysWithValues: agents.compactMap { entry in entry["tile"]?.string.map { ($0, entry) } })
    }

    func report(_ tile: ObjectID, _ state: String, seq: Int, _ extra: [String: JSONValue] = [:]) async throws {
        let params: [String: JSONValue] = ["tile": .string(tile), "kind": "omp", "state": .string(state), "seq": .number(Double(seq)), "source": "canvas-omp"]
        #expect(try await call("agent.report", params.merging(extra) { _, new in new })["ok"] == .bool(true))
    }

    static let alive = Double(ProcessInfo.processInfo.processIdentifier)
    /// No process has it (beyond macOS's pid range).
    static let dead = Double(Int32.max - 1)

    // MARK: agent.list

    @Test func everyReportSaysTheDraftAndPidAndOneWithoutThemForgetsThem() async throws {
        let tile = terminal()
        try await report(tile, "idle", seq: 1, ["draft": .bool(true), "pid": .number(Self.alive)])
        var entry = try #require(try await listed()[tile])
        #expect(entry["draft"] == .bool(true) && entry["pid"] == .number(Self.alive), "\(entry)")
        #expect(board.objects[tile]?.props["agent"]?["draft"] == .bool(true))

        // The user sent it: the editor is empty again.
        try await report(tile, "working", seq: 2, ["draft": .bool(false), "pid": .number(Self.alive)])
        entry = try #require(try await listed()[tile])
        #expect(entry["draft"] == .bool(false) && entry["lifecycle"]?["state"] == "working")

        // A report that doesn't say: unknown, and the tile's own foreground process stands in.
        foreground[tile] = 4242
        try await report(tile, "idle", seq: 3)
        entry = try #require(try await listed()[tile])
        #expect(entry["draft"] == nil && entry["pid"] == .number(4242), "\(entry)")
        #expect(board.objects[tile]?.props["agent"]?["draft"] == nil && board.objects[tile]?.props["agent"]?["pid"] == nil)
        // A reported pid whose process is gone isn't the agent's.
        try await report(tile, "idle", seq: 4, ["pid": .number(Self.dead)])
        #expect(try await listed()[tile]?["pid"] == .number(4242))
    }

    @Test func modelAndThinkingStayUntilTheAgentReportsOthers() async throws {
        let tile = terminal()
        let session: [String: JSONValue] = ["tile": .string(tile), "kind": "omp", "sessionId": "s1"]
        _ = try await call("agent.report_session", session.merging(["model": "anthropic/claude-opus-4-5", "thinking": "high"]) { _, new in new })
        _ = try await call("agent.report_session", session.merging(["sessionId": "s2"]) { _, new in new })
        var entry = try #require(try await listed()[tile])
        #expect(entry["model"] == "anthropic/claude-opus-4-5" && entry["thinking"] == "high" && entry["sessionId"] == "s2", "\(entry)")
        _ = try await call("agent.report_session", session.merging(["thinking": "low"]) { _, new in new })
        entry = try #require(try await listed()[tile])
        #expect(entry["model"] == "anthropic/claude-opus-4-5" && entry["thinking"] == "low")
    }

    @Test func focusedIsTheTerminalWithKeyboardFocusAlone() async throws {
        let a = terminal(), b = terminal()
        focused = a
        var agents = try await listed()
        #expect(agents[a]?["focused"] == .bool(true) && agents[b]?["focused"] == .bool(false))
        #expect(agents[a]?["open"] == .bool(true))
        focused = b
        agents = try await listed()
        #expect(agents[a]?["focused"] == .bool(false) && agents[b]?["focused"] == .bool(true))
    }

    @Test func aClosedBoardsTilesComeFromItsFileWithTheirSessionsLiveness() async throws {
        let otherRoot = dir.appendingPathComponent("lindy")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let other = registry.open(root: otherRoot)
        let reviewer = terminal(on: other, name: "reviewer"), shell = terminal(on: other)
        try other.reportLifecycle(tile: reviewer, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp", pid: Int(Self.alive))
        try other.reportSession(tile: reviewer, kind: "omp", sessionId: "s1", sessionPath: nil, model: "openai/gpt-5.2", thinking: "medium")
        try other.reportLifecycle(tile: shell, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp", draft: true)
        let otherID = other.id
        registry.close(otherID)
        let here = terminal()

        // zmx knows the reviewer's session (running its agent) and not the shell's.
        router.terminalSessions = { [reviewer] in [reviewer: TerminalSession(board: otherID, pid: 5151)] }
        let agents = try await call("agent.list")["result"]?["agents"]?.array ?? []
        #expect(agents.compactMap { $0["tile"]?.string } == [here, min(reviewer, shell), max(reviewer, shell)], "open boards first")
        let byTile = Dictionary(uniqueKeysWithValues: agents.compactMap { entry in entry["tile"]?.string.map { ($0, entry) } })
        let closed = try #require(byTile[reviewer])
        #expect(closed["open"] == .bool(false) && closed["focused"] == .bool(false) && closed["live"] == .bool(true))
        #expect(closed["board"] == .string(otherID) && closed["root"] == .string(otherRoot.path) && closed["address"] == "reviewer@lindy")
        #expect(closed["lifecycle"]?["state"] == "working" && closed["lifecycle"]?["restored"] == .bool(true), "unconfirmed since the board closed")
        #expect(closed["model"] == "openai/gpt-5.2" && closed["thinking"] == "medium" && closed["sessionId"] == "s1" && closed["kind"] == "omp")
        #expect(closed["pid"] == .number(Self.alive), "the agent's own pid while its process lives")
        let dead = try #require(byTile[shell])
        #expect(dead["live"] == .bool(false) && dead["pid"] == nil && dead["draft"] == .bool(true) && dead["address"] == .string(shell))
        #expect(byTile[here]?["open"] == .bool(true) && byTile[here]?["live"] == .bool(false))

        // Opened again, they are its open board's.
        _ = registry.open(root: otherRoot)
        let reopened = try await listed()
        #expect(reopened[reviewer]?["open"] == .bool(true) && reopened.count == 3)
    }

    @Test func aHostedTerminalIsLiveByItsHostsSessionsAndHasNoPidOfThisMac() async throws {
        let hosted = board.create(type: .terminal, props: .object(["cwd": "/home/tim", "host": "deckbox", "command": ["omp"]])).id
        try await report(hosted, "idle", seq: 1, ["pid": .number(Self.alive)])
        // Even a foreground pid this Mac's process table happened to give is no process of the host's.
        foreground[hosted] = 4242
        router.terminalSessions = { [:] }
        router.hostedSessions = { [unowned self] hosts in
            hostsAsked.append(hosts)
            return ["deckbox": [hosted]]
        }
        var entry = try #require(try await listed()[hosted])
        #expect(entry["live"] == .bool(true) && entry["pid"] == nil, "\(entry)")
        #expect(hostsAsked == [["deckbox"]])
        router.hostedSessions = { _ in [:] }
        entry = try #require(try await listed()[hosted])
        #expect(entry["live"] == nil && entry["pid"] == nil, "its host can't be asked: unknown, never this Mac's zmx")
    }

    // MARK: agent.restart

    @Test func restartRefusesWhatWouldLoseWorkUnlessForced() async throws {
        let tile = terminal(name: "worker", command: ["omp"])
        _ = try await call("agent.report_session", ["tile": .string(tile), "kind": "omp", "sessionId": "s1"])
        func restart(_ extra: [String: JSONValue] = [:]) async throws -> JSONValue {
            try await call("agent.restart", ["target": "worker", "mode": "resume"].merging(extra) { _, new in new })
        }
        func refusal() async throws -> String? {
            let reply = try await restart()
            #expect(reply["error"]?["code"] == "conflict", "\(reply)")
            return reply["error"]?["message"]?.string
        }
        try await report(tile, "blocked", seq: 1, ["message": "approve bash?", "draft": .bool(true)])
        #expect(try await refusal() == "\(tile) is blocked, waiting on its user (“approve bash?”): restarting would drop that dialog; force: true restarts anyway")
        try await report(tile, "working", seq: 2, ["draft": .bool(true)])
        #expect(try await refusal() == "\(tile) is working: restarting would kill its turn. Wait for it (agent.wait), or force: true restarts anyway")
        try await report(tile, "idle", seq: 3, ["draft": .bool(true)])
        #expect(try await refusal() == "\(tile)'s input editor holds a draft the user hasn't sent: restarting would lose it; force: true restarts anyway")
        try await report(tile, "idle", seq: 4)
        #expect(try await refusal() == "nothing in \(tile) reports whether its input holds a draft the user hasn't sent (omp's easl extension does), so restarting could lose one; force: true restarts anyway",
                "a draft nothing reports is one the user may have")
        try await report(tile, "idle", seq: 5, ["draft": .bool(false)])
        focused = tile
        #expect(try await refusal() == "\(tile) has keyboard focus: the user may be typing in it; force: true restarts anyway")
        #expect(restarted.isEmpty)

        try await report(tile, "working", seq: 6, ["draft": .bool(true)])
        let forced = try await restart(["force": .bool(true)])
        #expect(forced["ok"] == .bool(true), "\(forced)")
        #expect(restarted.map(\.0) == [tile])
    }

    @Test func restartWaitsForAPromptsTurnToStartAsAgentWaitDoes() async throws {
        let tile = terminal(name: "worker", command: ["omp"])
        _ = try await call("agent.report_session", ["tile": .string(tile), "kind": "omp", "sessionId": "s1"])
        try await report(tile, "idle", seq: 1, ["draft": .bool(false)])
        router.submitToTerminal = { _, _, _ in true }
        let restart = { try await self.call("agent.restart", ["target": "worker", "mode": "resume"]) }
        #expect(try await call("agent.prompt", ["target": "worker", "text": "run the tests"])["result"]?["delivery"] == "typed")
        #expect(try await restart()["error"]?["message"]
                == .string("\(tile) was just prompted and hasn't started that turn: restarting would lose the prompt. Wait for it (agent.wait), or force: true restarts anyway"))
        try await report(tile, "working", seq: 2, ["draft": .bool(false)])
        #expect(try await restart()["error"]?["code"] == "conflict")
        try await report(tile, "idle", seq: 3, ["draft": .bool(false)])
        #expect(try await restart()["ok"] == .bool(true))

        // A prompt that started no turn within agent.wait's grace never will.
        try await report(tile, "idle", seq: 4, ["draft": .bool(false)])
        #expect(try await call("agent.prompt", ["target": "worker", "text": "/compact"])["ok"] == .bool(true))
        #expect(try await restart()["error"]?["code"] == "conflict")
        router.promptStartGrace = 0
        #expect(try await restart()["ok"] == .bool(true))
        #expect(restarted.count == 2)
    }

    @Test func aPromptBeingTypedHoldsOffEvenAForcedRestartAndGoesOnlyToItsSession() async throws {
        let tile = terminal(name: "worker", command: ["omp"])
        _ = try await call("agent.report_session", ["tile": .string(tile), "kind": "omp", "sessionId": "s1"])
        try await report(tile, "idle", seq: 1, ["draft": .bool(false)])
        var typed: [String] = []
        router.submitToTerminal = { _, _, text in
            typed.append(text)
            return true
        }
        // While the prompt reads the screen before pasting, a forced restart arrives.
        var forced: JSONValue?
        router.readTerminal = { [unowned self] _, _, _ in
            forced = try? await call("agent.restart", ["target": "worker", "mode": "resume", "force": .bool(true)])
            return nil
        }
        #expect(try await call("agent.prompt", ["target": "worker", "text": "run the tests"])["result"]?["delivery"] == "typed")
        #expect(forced?["error"]?["code"] == "conflict" && forced?["error"]?["message"]
                == .string("\(tile) is being prompted right now (agent.prompt is typing into it): restarting would cut that prompt off; try again in a moment"))
        #expect(typed == ["run the tests"] && restarted.isEmpty)

        // The agent session the prompt was for ends meanwhile (another session took the tile): nothing is typed.
        try await report(tile, "working", seq: 2, ["draft": .bool(false)])
        try await report(tile, "idle", seq: 3, ["draft": .bool(false)])
        router.readTerminal = { [unowned self] _, _, _ in
            _ = try? await call("agent.report_session", ["tile": .string(tile), "kind": "omp", "sessionId": "s2"])
            return nil
        }
        let late = try await call("agent.prompt", ["target": "worker", "text": "and the docs"])
        #expect(late["error"]?["code"] == "unavailable", "\(late)")
        #expect(typed == ["run the tests"])
    }

    @Test func nothingReachesARestartingTerminalAndTheKillChecksAgain() async throws {
        let worker = terminal(name: "worker", command: ["omp"])
        try board.reportLifecycle(tile: worker, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp", protocol: 1, draft: false)
        try board.reportSession(tile: worker, kind: "omp", sessionId: "s1", sessionPath: nil)
        #expect(try await call("agent.prompt", ["target": "worker", "text": "Nightly failed.", "from": "machine-watch"])["result"]?["delivery"] == "message")
        let restarting = "\(worker) is restarting (agent.restart): nothing reaches it until its agent is relaunched; send again once it reports"

        // While the app kills and relaunches it: no message, typed prompt, delivery or other restart.
        var during: [String: JSONValue] = [:]
        router.restartTerminal = { [unowned self] _, tile, argv, killing, ended in
            during["message"] = try await call("agent.prompt", ["target": "worker", "text": "Also this.", "from": "machine-watch"])
            during["composer"] = try await call("agent.prompt", ["target": "worker", "text": "and this", "composer": .bool(true)])
            during["inbox"] = try await call("agent.inbox", ["tile": .string(tile)])
            during["restart"] = try await call("agent.restart", ["target": "worker", "mode": "fresh", "force": .bool(true)])
            try killing()
            ended()
            restarted.append((tile, argv))
        }
        #expect(try await call("agent.restart", ["target": "worker", "mode": "resume"])["ok"] == .bool(true))
        for refused in [during["message"], during["composer"]] {
            #expect(refused?["error"]?["code"] == "conflict" && refused?["error"]?["message"] == .string(restarting), "\(String(describing: refused))")
        }
        #expect(during["inbox"]?["result"]?["messages"] == .array([]), "\(String(describing: during["inbox"]))")
        #expect(during["restart"]?["error"]?["message"] == .string("\(worker) is already restarting (another agent.restart): wait for that one to finish"))
        #expect(restarted.count == 1)
        #expect(board.messages[worker] == nil, "what was queued for the killed session bounced")

        // A turn that started after the first check calls the restart off at the kill.
        try board.reportLifecycle(tile: worker, kind: "omp", state: .idle, message: nil, seq: 2, source: "canvas-omp", protocol: 1, draft: false)
        #expect(try await call("agent.prompt", ["target": "worker", "text": "Welcome back.", "from": "machine-watch"])["result"]?["delivery"] == "message")
        var killed = false
        router.restartTerminal = { [unowned self] _, tile, _, killing, ended in
            try board.reportLifecycle(tile: tile, kind: "omp", state: .working, message: nil, seq: 3, source: "canvas-omp", protocol: 1, draft: false)
            try killing()
            killed = true
            ended()
        }
        let generation = board.agentSession(of: worker)
        let refused = try await call("agent.restart", ["target": "worker", "mode": "resume"])
        #expect(refused["error"]?["message"] == .string("\(worker) is working: restarting would kill its turn. Wait for it (agent.wait), or force: true restarts anyway"))
        #expect(!killed && board.agentSession(of: worker) == generation)
        #expect(try await call("agent.inbox", ["tile": .string(worker)])["result"]?["messages"]?.array?.count == 1, "offered again once the restart is off")
    }

    @Test func whatTheRelaunchedAgentReportsWhileItStartsStays() async throws {
        let tile = terminal(name: "worker", command: ["omp"])
        _ = try await call("agent.report_session", ["tile": .string(tile), "kind": "omp", "sessionId": "s1", "model": "anthropic/claude-opus-4-5", "thinking": "auto"])
        try await report(tile, "idle", seq: 1, ["draft": .bool(false)])
        router.restartTerminal = { [unowned self] _, tile, argv, killing, ended in
            try killing()
            ended()
            // A hosted relaunch reports through the relay before the host's session.spawn answers.
            _ = try await call("agent.report_session", ["tile": .string(tile), "kind": "omp", "sessionId": "s2", "model": "anthropic/claude-opus-4-5", "thinking": "auto"])
            try await report(tile, "working", seq: 2, ["draft": .bool(false), "pid": .number(Self.alive)])
            restarted.append((tile, argv))
        }
        let reply = try await call("agent.restart", ["target": "worker", "mode": "fresh"])
        #expect(reply["result"]?["command"] == ["omp", "--model=anthropic/claude-opus-4-5", "--thinking=auto"], "\(reply)")
        let agent = try #require(board.objects[tile]?.props["agent"])
        #expect(agent["sessionId"] == "s2" && agent["thinking"] == "auto" && agent["pid"] == .number(Self.alive))
        #expect(board.objects[tile]?.props["lifecycle"]?["state"] == "working")
        #expect(reply["result"]?["agent"]?["lifecycle"]?["state"] == "working")
    }

    @Test func restartBouncesWhatWasQueuedForTheKilledSessionBeforeTheRelaunchStarts() async throws {
        let worker = terminal(name: "worker", command: ["omp"])
        try board.reportLifecycle(tile: worker, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp", protocol: 1, draft: false)
        try board.reportSession(tile: worker, kind: "omp", sessionId: "s1", sessionPath: nil)
        let queued = try await call("agent.prompt", ["target": "worker", "text": "Nightly failed.", "from": "machine-watch"])
        #expect(queued["result"]?["delivery"] == "message", "\(queued)")

        // The app fails before it kills anything: the session goes on, and its queue with it.
        router.restartTerminal = { _, tile, _, _, _ in throw ApiRouter.Failure("unavailable", "terminal \(tile) isn't shown in a window") }
        var generation = board.agentSession(of: worker)
        #expect(try await call("agent.restart", ["target": "worker", "mode": "resume"])["error"]?["code"] == "unavailable")
        #expect(board.messages[worker]?.map(\.text) == ["Nightly failed."] && board.agentSession(of: worker) == generation)

        // Killed: what was queued for the old session bounced before the relaunch started.
        var queuedAtRelaunch: [String]? = ["not asked"]
        router.restartTerminal = { [unowned self] _, tile, argv, killing, ended in
            try killing()
            ended()
            queuedAtRelaunch = board.messages[tile]?.map(\.text)
            restarted.append((tile, argv))
        }
        generation = board.agentSession(of: worker)
        let resumed = try await call("agent.restart", ["target": "worker", "mode": "resume"])
        #expect(resumed["ok"] == .bool(true), "\(resumed)")
        #expect(queuedAtRelaunch == nil && board.agentSession(of: worker) == generation + 1)
        #expect(board.activity.query(since: nil, limit: 10, kinds: [.message]).entries.map(\.summary) == ["undelivered to worker@root: Nightly failed. (from machine-watch)"])
        #expect(try await call("agent.inbox", ["tile": .string(worker)])["result"]?["messages"] == .array([]), "the resumed agent gets none of it")

        // The relaunched agent reports its resumed session: what it is sent from then on is its own.
        try board.reportSession(tile: worker, kind: "omp", sessionId: "s1", sessionPath: nil)
        try board.reportLifecycle(tile: worker, kind: "omp", state: .idle, message: nil, seq: 2, source: "canvas-omp", protocol: 1)
        #expect(try await call("agent.prompt", ["target": "worker", "text": "Welcome back.", "from": "machine-watch"])["result"]?["delivery"] == "message")
        #expect(board.messages[worker]?.map(\.text) == ["Welcome back."])
    }

    @Test func resumeRelaunchesTheRecordedSessionWithItsModelAndThinking() async throws {
        let tile = terminal(name: "worker", command: ["omp", "-e", "/src/easl.ts", "--model=old", "write the tests"])
        _ = try await call("agent.report_session", ["tile": .string(tile), "kind": "omp", "sessionId": "s1", "sessionPath": "/sessions/s1.jsonl",
                                                     "model": "anthropic/claude-opus-4-5", "thinking": "high"])
        try await report(tile, "idle", seq: 1, ["draft": .bool(false), "pid": .number(Self.alive)])
        let reply = try await call("agent.restart", ["target": .string(tile), "mode": "resume", "args": ["--plan"]])
        let argv = ["omp", "-e", "/src/easl.ts", "--model=anthropic/claude-opus-4-5", "--thinking=high", "--plan", "--resume=/sessions/s1.jsonl"]
        #expect(reply["result"]?["command"] == .array(argv.map(JSONValue.string)), "\(reply)")
        #expect(restarted.first?.1 == argv)
        let props = try #require(board.objects[tile]?.props)
        #expect(props["command"] == .array(argv.dropLast().map(JSONValue.string)), "a reboot reruns it and resumes the session it records")
        #expect(props["lifecycle"] == nil, "unknown until the new agent reports")
        #expect(props["agent"] == .object(["kind": "omp", "sessionId": "s1", "sessionPath": "/sessions/s1.jsonl",
                                           "model": "anthropic/claude-opus-4-5", "thinking": "high"]))
        #expect(props["name"] == "worker")
        #expect(reply["result"]?["agent"]?["lifecycle"]?["state"] == "unknown")
    }

    @Test func freshRelaunchesWithoutTheSessionAndAShellRerunsItsCommand() async throws {
        let tile = terminal(command: ["omp", "--resume=s0"])
        _ = try await call("agent.report_session", ["tile": .string(tile), "kind": "omp", "sessionId": "s1", "model": "openai/gpt-5.2"])
        let reply = try await call("agent.restart", ["target": .string(tile), "mode": "fresh", "force": .bool(true)])
        #expect(reply["result"]?["command"] == ["omp", "--model=openai/gpt-5.2"], "\(reply)")
        #expect(board.objects[tile]?.props["agent"] == .object(["kind": "omp", "model": "openai/gpt-5.2"]))

        let server = terminal(command: ["npm", "run", "dev"])
        let rerun = try await call("agent.restart", ["target": .string(server), "mode": "fresh", "args": ["--", "--port", "3001"], "force": .bool(true)])
        #expect(rerun["result"]?["command"] == ["npm", "run", "dev", "--", "--port", "3001"], "\(rerun)")
        #expect(board.objects[server]?.props["agent"] == nil)
    }

    @Test func restartSaysWhyItCannot() async throws {
        let shell = terminal()
        let noSession = try await call("agent.restart", ["target": .string(shell), "mode": "resume", "force": .bool(true)])
        #expect(noSession["error"]?["code"] == "unavailable")
        #expect(noSession["error"]?["message"] == .string("\(shell) has no recorded agent session to resume (its agent never reported one, or it exited); mode fresh starts it anew"))
        let nothing = try await call("agent.restart", ["target": .string(shell), "mode": "fresh", "force": .bool(true)])
        #expect(nothing["error"]?["message"] == .string("\(shell) runs no known agent and has no command to relaunch"))
        #expect(try await call("agent.restart", ["target": .string(shell), "mode": "restart"])["error"]?["message"] == "mode is resume or fresh, not restart")
        #expect(try await call("agent.restart", ["target": .string(shell), "mode": "fresh", "args": [1]])["error"]?["message"] == "args is an array of strings")
        #expect(try await call("agent.restart", ["target": "nobody", "mode": "fresh"])["error"]?["code"] == "not_found")
        router.restartTerminal = nil
        let headless = try await call("agent.restart", ["target": .string(terminal(command: ["make"])), "mode": "fresh", "force": .bool(true)])
        #expect(headless["error"]?["message"] == "restarting needs the app UI")
        #expect(restarted.isEmpty)
    }

    @Test func eachAgentNamesItsModelItsOwnWay() {
        #expect(AgentResume.relaunch(kind: "codex", command: ["codex", "-c", "x=1", "-m", "gpt-5"], session: "t-1", model: "gpt-6", thinking: "high", args: [])?.argv
                == ["codex", "resume", "-c", "x=1", "-m", "gpt-6", "t-1"], "codex has no thinking option to give")
        #expect(AgentResume.relaunch(kind: "claude", command: [], session: nil, model: "opus", thinking: nil, args: [])?.argv == ["claude", "--model", "opus"])
        #expect(AgentResume.relaunch(kind: "omp", command: ["omp", "--thinking", "low"], session: nil, model: nil, thinking: "max", args: [])?.command == ["omp", "--thinking=max"])
        #expect(AgentResume.relaunch(kind: nil, command: [], session: nil, model: nil, thinking: nil, args: ["x"]) == nil)
    }
}
