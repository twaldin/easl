import Foundation
import Testing
import CanvasCore

/// agent.read, board.list, and board.export over the real socket.
@MainActor
final class AgentBoardApiTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let router: ApiRouter
    let server: SocketServer
    let board: Board
    /// Session text per terminal tile; tiles without an entry have no session.
    var sessions: [ObjectID: String] = [:]
    /// Line caps the router asked the app to read.
    var readLimits: [Int] = []

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
        router.readTerminal = { [unowned self] _, tile, lines in
            readLimits.append(lines)
            guard let text = sessions[tile] else { return nil }
            var tail = TerminalTail(limit: lines)
            tail.append(Data(text.utf8))
            return tail.finish()
        }
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func call(_ method: String, _ params: String = "{}") async throws -> JSONValue {
        let client = try LineClient(path: dir.appendingPathComponent("s").path)
        client.send(#"{"id":"1","method":"\#(method)","params":\#(params)}"#)
        return try await client.next()
    }

    func terminal(name: String? = nil) -> ObjectID {
        var props: [String: JSONValue] = ["cwd": .string(dir.path)]
        if let name { props["name"] = .string(name) }
        return board.create(type: .terminal, props: .object(props)).id
    }

    // MARK: agent.read

    @Test func readReturnsTheTailWithoutTrailingBlankLines() async throws {
        let tile = terminal()
        sessions[tile] = (1...150).map { "line \($0)   " }.joined(separator: "\n") + "\n\n   \n"
        let reply = try await call("agent.read", #"{"target":"\#(tile)","lines":3}"#)
        #expect(reply["result"]?["text"] == .string("line 148\nline 149\nline 150"))
        #expect(reply["result"]?["lines"] == .number(3))
        #expect(reply["result"]?["agent"]?["tile"] == .string(tile))

        let defaulted = try await call("agent.read", #"{"target":"\#(tile)"}"#)
        #expect(defaulted["result"]?["lines"] == .number(100))
        #expect(defaulted["result"]?["text"]?.string?.hasPrefix("line 51\n") == true)
    }

    @Test func readResolvesAgentsByName() async throws {
        _ = terminal(name: "reviewer-a")
        let reviewer = terminal(name: "reviewer")
        sessions[reviewer] = "ready"
        let reply = try await call("agent.read", #"{"target":"reviewer"}"#)
        #expect(reply["result"]?["agent"]?["tile"] == .string(reviewer))
        #expect(reply["result"]?["text"] == .string("ready"))
    }

    @Test func readCapsLongTails() async throws {
        let tile = terminal()
        sessions[tile] = (1...5000).map(String.init).joined(separator: "\n")
        let reply = try await call("agent.read", #"{"target":"\#(tile)","lines":100000}"#)
        #expect(readLimits == [2000], "the app never reads more than the cap")
        #expect(reply["result"]?["lines"] == .number(2000))
        #expect(reply["result"]?["text"]?.string?.hasPrefix("3001\n") == true)
    }

    @Test func readFailsForUnknownTargetsNonTerminalsAndMissingSessions() async throws {
        #expect(try await call("agent.read", #"{"target":"nobody"}"#)["error"]?["code"] == .string("not_found"))
        let note = board.create(type: .note, props: .object(["markdown": .string("x")])).id
        #expect(try await call("agent.read", #"{"target":"\#(note)"}"#)["error"]?["code"] == .string("not_found"))
        let tile = terminal()
        #expect(try await call("agent.read", #"{"target":"\#(tile)"}"#)["error"]?["code"] == .string("unavailable"))
        sessions[tile] = "x"
        #expect(try await call("agent.read", #"{"target":"\#(tile)","lines":0}"#)["error"]?["code"] == .string("invalid_params"))
    }

    /// agent.prompt to `tile` whose session reads `after` once the prompt is in.
    func prompt(_ tile: ObjectID, _ text: String, after: String) async throws {
        router.submitToTerminal = { [unowned self] _, target, _ in
            sessions[target] = after
            return true
        }
        #expect(try await call("agent.prompt", #"{"target":"\#(tile)","text":"\#(text)"}"#)["ok"] == .bool(true))
    }

    @Test func readSincePromptReturnsOnlyWhatFollowedIt() async throws {
        let shell = terminal()
        #expect(try await call("agent.read", #"{"target":"\#(shell)","since":"prompt"}"#)["error"]?["code"] == .string("not_found"), "nothing was prompted yet")
        sessions[shell] = "Last login\n$ ls\na b\n$"
        try await prompt(shell, "make", after: "Last login\n$ ls\na b\n$ make\nbuilding\ndone\n$")
        let reply = try await call("agent.read", #"{"target":"\#(shell)","since":"prompt"}"#)
        #expect(reply["result"]?["text"] == .string("$ make\nbuilding\ndone\n$"), "from the line the prompt changed")
        #expect(reply["result"]?["truncated"] == .bool(false))

        // A TUI redraws its input box where the reply goes: the reply starts where the old screen changed.
        let tui = terminal()
        sessions[tui] = "old answer\n\n╭────╮\n│ >  │\n╰────╯\nmodel · 12%"
        try await prompt(tui, "explain", after: "old answer\n\n› explain\n\nreply one\nreply two\n\n╭────╮\n│ >  │\n╰────╯\nmodel · 14%")
        let answer = try await call("agent.read", #"{"target":"\#(tui)","since":"prompt"}"#)
        #expect(answer["result"]?["text"]?.string?.hasPrefix("› explain\n\nreply one\nreply two\n") == true)
        #expect(answer["result"]?["text"]?.string?.contains("old answer") == false)

        let capped = try await call("agent.read", #"{"target":"\#(tui)","since":"prompt","lines":2}"#)
        #expect(capped["result"]?["text"] == .string("╰────╯\nmodel · 14%"))
        #expect(capped["result"]?["truncated"] == .bool(true))
        #expect(try await call("agent.read", #"{"target":"\#(tui)","since":"start"}"#)["error"]?["code"] == .string("invalid_params"))
    }

    @Test func aReplyLongerThanTheTailIsReturnedWholeUpToTheCapAndMarkedTruncated() async throws {
        let tile = terminal()
        sessions[tile] = "$"
        let output = (1...3000).map { "row \($0)" }.joined(separator: "\n")
        try await prompt(tile, "seq", after: "$ seq\n" + output + "\n$")
        let reply = try await call("agent.read", #"{"target":"\#(tile)","since":"prompt"}"#)
        #expect(reply["result"]?["lines"] == .number(2000))
        #expect(reply["result"]?["text"]?.string?.hasSuffix("row 3000\n$") == true)
        #expect(reply["result"]?["truncated"] == .bool(true))
    }

    // MARK: board.list

    @Test func listMarksBoardsWhoseRootIsGoneAsArchived() async throws {
        board.create(type: .note, props: .object(["markdown": .string("kept")]))
        let worktree = dir.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let doomed = registry.open(root: worktree)
        doomed.create(type: .note, props: .object(["markdown": .string("a")]))
        doomed.create(type: .note, props: .object(["markdown": .string("b")]))
        registry.store.flush([doomed])
        try registry.close(doomed.id)
        try FileManager.default.removeItem(at: worktree)
        let sub = dir.appendingPathComponent("root/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let fresh = registry.open(root: sub)

        let boards = try #require(try await call("board.list")["result"]?["boards"]?.array)
        let byID = Dictionary(uniqueKeysWithValues: boards.map { ($0["board"]?.string ?? "", $0) })
        #expect(byID.count == 3)
        #expect(byID[doomed.id]?["archived"] == .bool(true))
        #expect(byID[doomed.id]?["open"] == .bool(false))
        #expect(byID[doomed.id]?["objects"] == .number(2))
        #expect(byID[doomed.id]?["updatedAt"]?.string != nil)
        #expect(byID[board.id]?["archived"] == .bool(false))
        #expect(byID[board.id]?["open"] == .bool(true))
        #expect(byID[board.id]?["objects"] == .number(1), "unsaved changes of open boards are counted")
        #expect(byID[fresh.id]?["updatedAt"] == nil, "a board never saved has no save time")
        #expect(byID[fresh.id]?["archived"] == .bool(false))
    }

    @Test func aWorktreeOpensItsRepositorysBoardAndIsListedWhereItIsNow() async throws {
        let repo = dir.appendingPathComponent("repo")
        let before = dir.appendingPathComponent("wt-before")
        let after = dir.appendingPathComponent("wt-after")
        try git("init", "-q", "-b", "main", repo.path)
        try git("-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
        try git("-C", repo.path, "worktree", "add", "-q", "-b", "feature", before.path)
        let original = registry.open(root: before)
        #expect(original.root.path == repo.path, "rooted at the main checkout")
        original.create(type: .note, props: .object(["markdown": .string("n")]))
        registry.store.flush([original])
        try registry.close(original.id)
        let savedAt = try #require(registry.store.list().first { $0.id == original.id }?.updatedAt)

        try git("-C", repo.path, "worktree", "move", before.path, after.path)
        let moved = registry.open(root: after)
        #expect(moved.id == original.id, "a board follows its repository, not a worktree's path")
        #expect(registry.open(root: repo) === moved)

        let boards = try #require(try await call("board.list")["result"]?["boards"]?.array)
        let entry = try #require(boards.first { $0["board"] == .string(moved.id) })
        #expect(entry["root"] == .string(repo.path))
        #expect(entry["archived"] == .bool(false))
        #expect(entry["open"] == .bool(true))
        #expect(entry["objects"] == .number(1))
        #expect(entry["updatedAt"] == .string(savedAt.formatted(.iso8601)), "the save time is the disk's")
        let worktrees = try #require(entry["worktrees"]?.array)
        #expect(worktrees.first { $0["path"] == .string(after.path) }?["branch"] == .string("feature"))
        #expect(worktrees.first { $0["path"] == .string(after.path) }?["live"] == .bool(true))
        #expect(worktrees.first { $0["path"] == .string(before.path) }?["live"] == .bool(false), "seen there, gone since")
        #expect(worktrees.first { $0["main"] == .bool(true) }?["path"] == .string(repo.path))
    }

    func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"]) }
    }

    // MARK: agent.prompt mentions, agent.read final

    /// A terminal whose agent reports its lifecycle (as its integration does).
    func agent(name: String) throws -> ObjectID {
        let tile = terminal(name: name)
        try board.reportLifecycle(tile: tile, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        return tile
    }

    func showTray(to target: ObjectID?) {
        router.viewState = { _ in
            ViewState(viewport: Viewport(rect: Frame(x: 0, y: 0, w: 1000, h: 800), zoom: 1), promptTarget: target, focused: nil, selection: [], enteredGroup: nil, visible: true, appearance: "dark")
        }
    }

    @Test func promptRefusesWhenTheForegroundProgramIsNotTheAgent() async throws {
        let tile = try agent(name: "omp-in-tmux")
        var typed: [String] = []
        router.submitToTerminal = { _, _, text in typed.append(text); return true }
        var program: String? = "tmux"
        router.terminalStatus = { _, _ in TerminalStatus(program: program) }
        let refused = try await call("agent.prompt", #"{"target":"\#(tile)","text":"what does walk.rs do?"}"#)
        #expect(refused["error"]?["code"] == .string("conflict"))
        #expect(refused["error"]?["message"]?.string?.contains("foreground program is tmux, not omp") == true)
        #expect(typed.isEmpty, "nothing reached tmux's active pane")
        #expect(try await call("agent.prompt", #"{"target":"\#(tile)","text":"anyway","force":true}"#)["ok"] == .bool(true))
        program = "omp"
        #expect(try await call("agent.prompt", #"{"target":"\#(tile)","text":"next"}"#)["ok"] == .bool(true))
        #expect(typed == ["anyway", "next"])
        // A plain shell (no agent reporting) takes whatever the caller types, as before.
        let shell = terminal()
        program = "npm run dev"
        #expect(try await call("agent.prompt", #"{"target":"\#(shell)","text":"rs"}"#)["ok"] == .bool(true))
    }

    @Test func mentionsGivenToAPromptReachOnlyTheTargetsNextDrain() async throws {
        let source = dir.appendingPathComponent("root/src/a.ts")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "import x\n\nexport function load() {\n  return 1\n}\n".write(to: source, atomically: true, encoding: .utf8)
        let code = board.create(type: .code, props: .object(["path": "src/a.ts", "range": .object(["start": 3, "end": 5])])).id
        let note = board.create(type: .note, props: .object(["markdown": "# Findings\n1. load returns a constant"])).id
        let lead = try agent(name: "lead")
        let reviewer = try agent(name: "reviewer")
        let bystander = try agent(name: "bystander")
        showTray(to: lead)
        let own = try board.stage(.object(note))
        router.submitToTerminal = { _, _, _ in true }

        let mentions = #"[{"object":"\#(code)","lines":{"start":4,"end":4}},{"object":"\#(code)"},{"object":"\#(note)"}]"#
        let sent = try await call("agent.prompt", #"{"target":"reviewer","text":"check the findings","caller":"\#(lead)","mentions":\#(mentions)}"#)
        #expect(sent["result"]?["mentions"]?.array?.count == 3)
        #expect(board.tray == [own], "the user's tray neither shows nor loses anything")

        let theirs = try await call("tray.drain", #"{"caller":"\#(lead)","peek":true}"#)
        #expect(theirs["result"]?["mentions"]?.array?.map { $0["id"] } == [.string(own.id)], "the sender's own prompt gets only the tray")
        let others = try await call("tray.drain", #"{"caller":"\#(bystander)","peek":true}"#)
        #expect(others["result"]?["context"] == .string(""))
        let script = try await call("tray.drain", #"{"peek":true}"#)
        #expect(script["result"]?["mentions"]?.array?.count == 1, "a script without a caller drains the tray only")

        let drained = try #require(try await call("tray.drain", #"{"caller":"\#(reviewer)","peek":true}"#)["result"])
        #expect(drained["held"] == .number(1), "the tray still waits for its own target")
        let context = try #require(drained["context"]?.string)
        #expect(context.hasPrefix("<canvas-mentions board=\"\(board.id)\" root=\"\(board.root.path)\" from=\"\(lead)\">\nAttached by terminal \(lead) \"lead\" to its prompt to you (agent.prompt):\n"))
        #expect(context.contains("[1] code src/a.ts:4-4 · tile \(code)\n    1    import x\n"), "\(context)")
        #expect(context.contains("  > 4      return 1\n"), "the given line, marked like a staged one")
        #expect(context.contains("[2] code src/a.ts:3-5 · tile \(code)\n"), "a code tile without lines mentions the range it shows")
        #expect(context.contains("[3] note \(note) \"Findings\"") && context.contains("1. load returns a constant\n"), "the whole note, titled by its first line")

        let ids = try #require(drained["mentions"]?.array?.compactMap { $0["id"]?.string })
        #expect(ids.count == 3)
        _ = try await call("tray.commit", #"{"ids":[\#(ids.map { "\"\($0)\"" }.joined(separator: ","))]}"#)
        let again = try await call("tray.drain", #"{"caller":"\#(reviewer)","peek":true}"#)
        #expect(again["result"]?["context"] == .string(""), "delivered once")
        #expect(board.tray == [own])
    }

    @Test func promptMentionsAreRefusedWhereNothingWouldTakeThem() async throws {
        let reviewer = try agent(name: "reviewer")
        let shell = terminal(name: "shell")
        let note = board.create(type: .note, props: .object(["markdown": "n"])).id
        router.submitToTerminal = { _, _, _ in true }
        func send(_ target: String, _ mentions: String) async throws -> JSONValue {
            try await call("agent.prompt", #"{"target":"\#(target)","text":"x","mentions":\#(mentions)}"#)
        }
        #expect(try await send(shell, #"[{"object":"\#(note)"}]"#)["error"]?["code"] == .string("unavailable"), "a shell never drains")
        #expect(try await send(reviewer, #"[{"object":"\#(note)","lines":{"start":1,"end":1}}]"#)["error"]?["code"] == .string("invalid_params"))
        #expect(try await send(reviewer, #"[{"object":"\#(note)","range":1}]"#)["error"]?["code"] == .string("invalid_params"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("other"), withIntermediateDirectories: true)
        let elsewhere = registry.open(root: dir.appendingPathComponent("other")).create(type: .note, props: .object(["markdown": "o"])).id
        #expect(try await send(reviewer, #"[{"object":"\#(elsewhere)"}]"#)["error"]?["code"] == .string("not_found"), "objects come from the target's board")

        router.submitToTerminal = { _, _, _ in false }
        #expect(try await send(reviewer, #"[{"object":"\#(note)"}]"#)["error"]?["code"] == .string("unavailable"))
        #expect(await board.drain(peek: true, caller: reviewer).mentions.isEmpty, "a prompt that never went in takes its mentions back")
    }

    @Test func readFinalReturnsTheLastReportedAnswerUntilTheNextTurn() async throws {
        let tile = try agent(name: "reviewer")
        let read = { try await self.call("agent.read", #"{"target":"reviewer","final":true}"#) }
        #expect(try await read()["error"]?["code"] == .string("unavailable"), "never reported")

        try board.reportLifecycle(tile: tile, kind: "codex", state: .working, message: nil, seq: nil, source: nil)
        let early = try await call("agent.report", #"{"tile":"\#(tile)","kind":"codex","state":"working","final":"x"}"#)
        #expect(early["error"]?["code"] == .string("invalid_params"), "an answer comes only with idle")
        try board.reportLifecycle(tile: tile, kind: "codex", state: .idle, message: nil, seq: nil, source: nil, final: "Verdict: low.\nSee a.ts:4")
        let answer = try await read()
        #expect(answer["result"]?["text"] == .string("Verdict: low.\nSee a.ts:4"))
        #expect(answer["result"]?["lines"] == .number(2))
        #expect(answer["result"]?["agent"]?["tile"] == .string(tile))
        #expect(try await call("agent.read", #"{"target":"reviewer","final":true,"lines":5}"#)["error"]?["code"] == .string("invalid_params"))

        // A prompt sent but not yet started, then a turn in progress: the old answer is not this turn's.
        router.submitToTerminal = { _, _, _ in true }
        _ = try await call("agent.prompt", #"{"target":"reviewer","text":"again"}"#)
        #expect(try await read()["error"]?["code"] == .string("unavailable"))
        try board.reportLifecycle(tile: tile, kind: "codex", state: .working, message: nil, seq: nil, source: nil)
        #expect(try await read()["error"]?["message"]?.string?.contains("still in its turn") == true)
        // An interrupted turn ends without an answer.
        try board.reportLifecycle(tile: tile, kind: "codex", state: .idle, message: nil, seq: nil, source: nil)
        #expect(try await read()["error"]?["code"] == .string("unavailable"))
        try board.reportLifecycle(tile: tile, kind: "codex", state: .working, message: nil, seq: nil, source: nil)
        try board.reportLifecycle(tile: tile, kind: "codex", state: .idle, message: nil, seq: nil, source: nil, final: "second")
        #expect(try await read()["result"]?["text"] == .string("second"))
    }

    /// soak study: an omp turn that died on "Anthropic stream error (overloaded_error)" showed as
    /// green done, and `final` returned the truncated text as if it were the answer.
    @Test func aTurnThatEndedOnAnErrorIsIdleWithWhyAndItsAnswerIsCutOff() async throws {
        let tile = try agent(name: "reviewer")
        func state() -> JSONValue? { board.objects[tile]?.props["lifecycle"] }
        try board.reportLifecycle(tile: tile, kind: "omp", state: .working, message: nil, seq: nil, source: nil)
        let failed = try await call("agent.report", #"{"tile":"\#(tile)","kind":"omp","state":"idle","final":"The fee math is","error":"Anthropic stream error (overloaded_error)"}"#)
        #expect(failed["ok"] == .bool(true))
        #expect(state() == .object(["state": "idle", "seen": .bool(false), "message": "Anthropic stream error (overloaded_error)", "error": "Anthropic stream error (overloaded_error)"]), "not done: the user reads why")
        let read = try await call("agent.read", #"{"target":"reviewer","final":true}"#)
        #expect(read["result"]?["text"] == "The fee math is" && read["result"]?["cutOff"] == "Anthropic stream error (overloaded_error)")
        #expect(try await call("agent.report", #"{"tile":"\#(tile)","kind":"omp","state":"working","error":"x"}"#)["error"]?["code"] == "invalid_params")
        // Reports that start no turn leave it, the user seeing the tile too: an agent relaunched
        // after the error (agent.restart) reports a plain `idle`, an aider an `unknown`.
        board.markSeen(tile)
        try board.reportLifecycle(tile: tile, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        #expect(state() == .object(["state": "idle", "seen": .bool(true), "message": "Anthropic stream error (overloaded_error)", "error": "Anthropic stream error (overloaded_error)"]))
        try board.reportLifecycle(tile: tile, kind: "omp", state: .unknown, message: nil, seq: nil, source: nil)
        #expect(state() == .object(["state": "idle", "seen": .bool(true), "message": "Anthropic stream error (overloaded_error)", "error": "Anthropic stream error (overloaded_error)", "via": "notifications"]))

        // The next turn finishes: done, and its answer is whole.
        try board.reportLifecycle(tile: tile, kind: "omp", state: .working, message: nil, seq: nil, source: nil)
        try board.reportLifecycle(tile: tile, kind: "omp", state: .idle, message: nil, seq: nil, source: nil, final: "Fixed.")
        #expect(state() == .object(["state": "done", "seen": .bool(false)]))
        let whole = try await call("agent.read", #"{"target":"reviewer","final":true}"#)
        #expect(whole["result"]?["text"] == "Fixed." && whole["result"]?["cutOff"] == nil)

        // Aborted before any text: no answer, and the error says why.
        try board.reportLifecycle(tile: tile, kind: "omp", state: .working, message: nil, seq: nil, source: nil)
        try board.reportLifecycle(tile: tile, kind: "omp", state: .idle, message: nil, seq: nil, source: nil, error: "interrupted")
        let none = try await call("agent.read", #"{"target":"reviewer","final":true}"#)
        #expect(none["error"]?["message"]?.string?.contains("ended on an error before any answer: interrupted") == true)
    }

    // MARK: board.export

    @Test func exportWritesAReadableSnapshotThatLoadsBack() async throws {
        let tile = terminal()
        let note = board.create(type: .note, props: .object(["markdown": .string("# Plan ✓\nsee src/a/b.ts:12")]), caller: tile)
        _ = try board.stage(.object(note.id))

        let reply = try await call("board.export")
        let path = dir.appendingPathComponent("root/.easl/board.json").standardizedFileURL.path
        #expect(reply["result"]?["path"] == .string(path))
        #expect(reply["result"]?["objects"] == .number(2))

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\n  \"id\" : \"\(board.id)\""), "pretty-printed")
        #expect(text.contains("src/a/b.ts:12"), "slashes unescaped for readable diffs")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(BoardSnapshot.self, from: data)
        #expect(snapshot.tray == nil, "the personal tray stays out of the repo")
        let restored = Board(snapshot: snapshot)
        #expect(restored.id == board.id)
        #expect(Set(restored.objects.keys) == Set(board.objects.keys))
        #expect(restored.objects[note.id]?.props == note.props)
        #expect(restored.objects[note.id]?.frame == note.frame)
        #expect(restored.objects[note.id]?.createdBy == .agent(tile: tile))
    }

    @Test func exportHonorsRelativeAndAbsolutePaths() async throws {
        board.create(type: .note, props: .object(["markdown": .string("x")]))
        let relative = try await call("board.export", #"{"path":"docs/canvas.json"}"#)
        #expect(relative["result"]?["path"] == .string(dir.appendingPathComponent("root/docs/canvas.json").standardizedFileURL.path))
        let absolute = dir.appendingPathComponent("elsewhere/b.json").path
        _ = try await call("board.export", #"{"path":"\#(absolute)"}"#)
        #expect(FileManager.default.fileExists(atPath: absolute))
    }
}
