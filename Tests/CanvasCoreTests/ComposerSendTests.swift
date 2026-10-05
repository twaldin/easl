import Foundation
import Testing
import CanvasCore

/// The composer's ⌘↩ through the router (`ComposerSend`, `ApiRouter.composerPrompt`) and the
/// drains its targets' integrations make over the socket with the text they submit: each sent
/// prompt keeps its own mentions, numbered from 1, for the terminal it went to, whatever happens
/// before its drain; every other drain takes the tray as it always did.
@MainActor
final class ComposerSendTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cs-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let router: ApiRouter
    let server: SocketServer
    let board: Board
    let mark = ComposerDraft.mark
    /// What each terminal was sent, in order.
    var typed: [ObjectID: [String]] = [:]

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
        router.submitToTerminal = { [unowned self] _, tile, text in
            typed[tile, default: []].append(text)
            return true
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

    func terminal(_ name: String, agent: Bool = true) throws -> ObjectID {
        let tile = board.create(type: .terminal, props: .object(["cwd": .string(dir.path), "name": .string(name)])).id
        if agent { try board.reportLifecycle(tile: tile, kind: "omp", state: .idle, message: nil, seq: nil, source: nil) }
        return tile
    }

    func code(_ path: String) -> CanvasObject {
        board.create(type: .code, props: .object(["path": .string(path)]))
    }

    func line(_ tile: CanvasObject, _ path: String) -> MentionTarget {
        .code(object: tile.id, path: path, lines: LineRange(start: 1, end: 1))
    }

    func showTray(to target: ObjectID?) {
        router.viewState = { _ in
            ViewState(viewport: Viewport(rect: Frame(x: 0, y: 0, w: 1000, h: 800), zoom: 1), promptTarget: target, focused: nil, selection: [], enteredGroup: nil, visible: true, appearance: "dark")
        }
    }

    /// A draft of the staged mentions' tokens with `notes` after them, as the composer holds it.
    func draft(_ notes: [String]) -> ComposerDraft {
        var draft = ComposerDraft()
        _ = ComposerSync.trayChanged(&draft, caret: nil, on: board)
        draft.text = zip(draft.tokens, notes).map { "\(mark) \($1)" }.joined(separator: " ")
        return draft
    }

    /// ⌘↩: what the controller does, through the router, until every target was tried. Returns
    /// the targets the text went into.
    @discardableResult
    func send(_ draft: ComposerDraft, to targets: [ObjectID]) async throws -> (send: ComposerSend, remaining: ComposerDraft, reached: Set<ObjectID>) {
        let begun = try #require(ComposerSend.begin(draft, targets: targets, on: board))
        var reached: Set<ObjectID> = []
        for delivery in begun.send.deliveries {
            do {
                try await router.composerPrompt(await begun.send.text(for: delivery, on: board), to: delivery.terminal, on: board, mentions: delivery.mentions, answer: delivery.answer)
                reached.insert(delivery.terminal)
            } catch is ApiRouter.Failure {}
        }
        return (begun.send, begun.remaining, reached)
    }

    /// `tray.drain` from `caller` over the socket: `prompt` the text its integration submits
    /// (nil: Hyper-V, a script, an older hook), `commit` false a peek left uncommitted. The
    /// `[n] path` rows of its context.
    func drain(_ caller: ObjectID, _ prompt: String?, commit: Bool = true) async throws -> [String] {
        let text = try prompt.map { #","prompt":"# + String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? ""
        let drained = try #require(try await call("tray.drain", #"{"caller":"\#(caller)","peek":true\#(text)}"#)["result"])
        let ids = drained["mentions"]?.array?.compactMap { $0["id"]?.string } ?? []
        if commit, !ids.isEmpty { _ = try await call("tray.commit", #"{"ids":[\#(ids.map { "\"\($0)\"" }.joined(separator: ","))]}"#) }
        return Self.rows(drained["context"]?.string ?? "")
    }

    static func rows(_ context: String) -> [String] {
        context.split(separator: "\n").compactMap { row in
            guard row.hasPrefix("["), let close = row.firstIndex(of: "]"), let path = row.split(separator: " ").dropFirst(2).first else { return nil }
            return "\(row[...close]) \(path.split(separator: ":").first ?? path)"
        }
    }

    @Test func aSentPromptsMentionsStayWithItsTerminalsNumberedFromOneWhateverHappensBeforeTheDrain() async throws {
        let alpha = try terminal("alpha"), beta = try terminal("beta")
        let a = code("a.py"), b = code("b.py"), c = code("c.py")
        showTray(to: alpha)
        try board.stage(line(a, "a.py"))
        try board.stage(line(b, "b.py"))
        let delivered = board.delivered

        let (_, remaining, _) = try await send(draft(["one", "two"]), to: [alpha, beta])
        #expect(typed[alpha] == ["[1] one [2] two"] && typed[beta] == ["[1] one [2] two"])
        #expect(remaining.isEmpty && board.tray.isEmpty, "the sent mentions left the composer and the tray at once")

        // Before either integration drains: a new mention, and the tray retargeted to beta.
        try board.stage(line(c, "c.py"))
        showTray(to: beta)
        #expect(try await drain(alpha, "[1] one [2] two") == ["[1] a.py", "[2] b.py"], "alpha's prompt keeps its mentions though the tray now shows beta")
        #expect(try await drain(beta, " [1] one\n[2] two\n") == ["[1] a.py", "[2] b.py"], "beta's prompt gets its own, not the tray's new [1], however its agent spaced the text")
        #expect(board.tray.map(\.label) == ["c.py:1"], "the mention staged meanwhile waits for the next prompt")
        #expect(board.delivered == delivered + 4)
        #expect(try await drain(alpha, "[1] one [2] two").isEmpty, "delivered once: the same text again isn't the tray's prompt target")
        #expect(try await drain(beta, "[1] next") == ["[1] c.py"], "the next prompt in beta takes the tray again")
    }

    @Test func eachPromptsDrainTakesItsOwnMentionsInWhateverOrderTheyCome() async throws {
        let alpha = try terminal("alpha")
        let a = code("a.py"), b = code("b.py")
        showTray(to: alpha)
        try board.stage(line(a, "a.py"))
        try await send(draft(["first"]), to: [alpha])
        try board.stage(line(b, "b.py"))
        try await send(draft(["second"]), to: [alpha])
        #expect(typed[alpha] == ["[1] first", "[1] second"])
        #expect(try await drain(alpha, "[1] second") == ["[1] b.py"], "the second's [1] is b, as its text says")
        #expect(try await drain(alpha, "[1] first") == ["[1] a.py"])
        #expect(board.composerPrompts[alpha] == nil)
    }

    @Test func aSlashCommandOrShellEscapeTakesNoMentionsAndLeavesNothingWaiting() async throws {
        let claude = try terminal("claude")
        try board.reportLifecycle(tile: claude, kind: "claude", state: .idle, message: nil, seq: nil, source: nil)
        let a = code("a.py"), b = code("b.py")
        showTray(to: claude)
        try board.stage(line(a, "a.py"))
        let staged = board.tray

        var escape = ComposerDraft(text: "!echo ")
        escape.insert(staged[0], at: nil)
        let (sent, remaining, reached) = try await send(escape, to: [claude])
        #expect(reached == [claude] && typed[claude] == ["!echo [1]"])
        #expect(!sent.takesMentions && board.tray == staged && remaining.tokens.map(\.id) == staged.map(\.id), "the tokens stay staged")
        #expect(board.composerPrompts[claude] == nil, "its hook drains nothing, so nothing waits for it")
        await #expect(throws: ApiRouter.Failure.self, "the router refuses mentions with one") {
            try await self.router.composerPrompt("!ls [1]", to: claude, on: self.board, mentions: staged, answer: false)
        }

        // The next prose takes both mentions, numbered as its text says.
        try board.stage(line(b, "b.py"))
        try await send(draft(["fix", "and"]), to: [claude])
        #expect(try await drain(claude, "[1] fix [2] and") == ["[1] a.py", "[2] b.py"])

        // omp skips `$…` too; Claude Code reads it as a prompt.
        let omp = try terminal("omp")
        try await send(ComposerDraft(text: "$ ls"), to: [omp])
        try await send(ComposerDraft(text: "$5 budget"), to: [claude])
        #expect(board.composerPrompts[omp] == nil && board.composerPrompts[claude]?.map(\.prompt) == ["$5 budget"])
        showTray(to: omp)
        try board.stage(line(a, "a.py"))
        #expect(try await drain(omp, "what changed?") == ["[1] a.py"], "prose typed in omp afterwards takes the tray")
    }

    @Test func peeksAndHyperVNeverTakeAPromptsMentions() async throws {
        let alpha = try terminal("alpha")
        let a = code("a.py"), x = code("x.py")
        showTray(to: alpha)
        try board.stage(line(a, "a.py"))
        try await send(draft(["fix"]), to: [alpha])
        try await send(ComposerDraft(text: "go on"), to: [alpha])
        try board.stage(line(x, "x.py"))
        let queued = board.composerPrompts[alpha]

        #expect(try await drain(alpha, nil, commit: false) == ["[1] x.py"], "a peek without the prompt (the CLI) sees the tray")
        #expect(board.composerPrompts[alpha] == queued, "and leaves the composer's prompts alone")
        #expect(try await drain(alpha, "[1] fix", commit: false) == ["[1] a.py"])
        #expect(try await drain(alpha, "[1] fix", commit: false) == ["[1] a.py"], "a peek holds the prompt's mentions until they are committed")

        // Hyper-V pastes the tray into the terminal, whatever waits for its prompts.
        let pasted = await board.drain(peek: true, caller: alpha)
        #expect(Self.rows(pasted.context) == ["[1] x.py"])
        board.commit(pasted.mentions.map(\.id), pastedInto: alpha)
        #expect(board.tray.isEmpty && board.composerPrompts[alpha] == queued)

        #expect(try await drain(alpha, "[1] fix") == ["[1] a.py"])
        try board.stage(line(x, "x.py"))
        #expect(try await drain(alpha, "go on").isEmpty, "a prompt without tokens keeps the tray out of its drain")
        #expect(board.tray.map(\.label) == ["x.py:1"] && board.composerPrompts[alpha] == nil)
    }

    @Test func aPromptItsAgentNeverDrainedReturnsItsMentionsToTheTray() async throws {
        let alpha = try terminal("alpha")
        let a = code("a.py"), b = code("b.py")
        showTray(to: alpha)
        var returned: [(ObjectID, [String])] = []
        board.onComposerMentionsReturned = { terminal, mentions in returned.append((terminal, mentions.map(\.label))) }

        try board.stage(line(a, "a.py"))
        try await send(draft(["fix"]), to: [alpha])
        #expect(board.tray.isEmpty)
        _ = try await call("agent.release", #"{"tile":"\#(alpha)","kind":"omp"}"#)
        #expect(board.tray.map(\.label) == ["a.py:1"] && board.composerPrompts[alpha] == nil, "released, its agent will never drain it")
        #expect(returned.map(\.0) == [alpha] && returned.map(\.1) == [["a.py:1"]])

        // A new agent in that terminal: its prompts take the tray, never the last agent's.
        try board.reportLifecycle(tile: alpha, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        try board.stage(line(b, "b.py"))
        try await send(draft(["one", "two"]), to: [alpha])
        board.terminalProgram(alpha, is: nil)
        #expect(board.tray.map(\.label) == ["a.py:1", "b.py:1"] && board.composerPrompts[alpha] == nil, "exited to the shell")

        try board.reportLifecycle(tile: alpha, kind: "omp", state: .idle, message: nil, seq: nil, source: nil)
        try await send(draft(["one", "two"]), to: [alpha])
        board.expireComposerPrompts(now: Date().addingTimeInterval(ComposerPrompt.lifetime + 1))
        #expect(board.tray.map(\.label) == ["a.py:1", "b.py:1"] && board.composerPrompts[alpha] == nil, "nor after waiting too long")
        #expect(returned.count == 3)
    }

    @Test func anAnswerTakesNothingAndThePromptsAroundItKeepTheirOwn() async throws {
        let codex = try terminal("codex")
        let a = code("a.py"), b = code("b.py")
        showTray(to: codex)
        try board.reportLifecycle(tile: codex, kind: "codex", state: .blocked, message: "Which color?", seq: nil, source: nil)
        try board.stage(line(a, "a.py"))
        let staged = board.tray

        #expect(try await call("agent.prompt", #"{"target":"\#(codex)","text":"blue"}"#)["error"]?["code"] == .string("conflict"), "an agent can't answer for the user")
        var answer = ComposerDraft(text: "blue ")
        answer.insert(staged[0], at: nil)
        let (sent, remaining, _) = try await send(answer, to: [codex])
        #expect(!sent.takesMentions && typed[codex] == ["blue [1]"])
        #expect(remaining.tokens.map(\.id) == staged.map(\.id) && board.tray == staged, "the tokens stay staged for the next prompt")

        // Codex takes its queued question's answer as a prompt, and may drain it after the user
        // sent the next prompt from the composer.
        try board.reportLifecycle(tile: codex, kind: "codex", state: .working, message: nil, seq: nil, source: nil)
        try await send(draft(["use it"]), to: [codex])
        #expect(try await drain(codex, "blue [1]").isEmpty, "the answer's drain takes nothing")
        #expect(try await drain(codex, "[1] use it") == ["[1] a.py"], "the prompt after it keeps its mention")

        // Claude Code's dialogs take an answer without any drain: the prose typed after it in the
        // terminal takes the tray.
        let claude = try terminal("claude")
        try board.reportLifecycle(tile: claude, kind: "claude", state: .blocked, message: "Allow?", seq: nil, source: nil)
        try await send(ComposerDraft(text: "2"), to: [claude])
        showTray(to: claude)
        try board.stage(line(b, "b.py"))
        #expect(try await drain(claude, "now the tests") == ["[1] b.py"])
    }

    @Test func mentionsComeBackWhenOnlyAnAnswerWentIn() async throws {
        let codex = try terminal("codex"), alpha = try terminal("alpha")
        let a = code("a.py")
        showTray(to: alpha)
        try board.reportLifecycle(tile: codex, kind: "codex", state: .blocked, message: "Which color?", seq: nil, source: nil)
        // Alpha's agent was working when easl last closed, and hasn't reported since: refused.
        _ = try board.update(alpha, props: .object(["lifecycle": .object(["state": .string("working"), "restored": .bool(true)])]), caller: alpha)
        try board.stage(line(a, "a.py"))

        let (sent, remaining, reached) = try await send(draft(["blue"]), to: [alpha, codex])
        #expect(sent.takesMentions && remaining.isEmpty && board.tray.isEmpty)
        #expect(reached == [codex] && typed[alpha] == nil)
        let settled = sent.settle(reached: reached, into: remaining, on: board)
        #expect(settled.sent && settled.mentionsReturned, "the answer went in; the mentions went nowhere")
        #expect(board.tray.map(\.label) == ["a.py:1"] && settled.draft.tokens.map(\.id) == board.tray.map(\.id))
        #expect(board.composerPrompts[alpha] == nil)
    }

    @Test func nothingTakenPutsTheDraftBackAheadOfWhatWasTypedSince() async throws {
        let alpha = try terminal("alpha")
        let a = code("a.py"), b = code("b.py")
        showTray(to: alpha)
        try board.stage(line(a, "a.py"))
        let begun = try #require(ComposerSend.begin(draft(["fix"]), targets: [alpha], on: board))
        #expect(board.tray.isEmpty)

        // While it goes in, the user Hyper-clicks b and types: the next draft's.
        try board.stage(line(b, "b.py"))
        var current = begun.remaining
        _ = ComposerSync.trayChanged(&current, caret: nil, on: board)
        current.text += "and this"
        router.submitToTerminal = { _, _, _ in false }
        let delivery = try #require(begun.send.deliveries.first)
        await #expect(throws: ApiRouter.Failure.self) {
            try await self.router.composerPrompt(begun.send.draft.prompt, to: alpha, on: self.board, mentions: delivery.mentions, answer: false)
        }
        #expect(board.composerPrompts[alpha] == nil, "a prompt that never went in leaves nothing queued")

        let settled = begun.send.settle(reached: [], into: current, on: board)
        #expect(!settled.sent && settled.draft.prompt == "[1] fix [2] and this")
        #expect(board.tray.map(\.id) == settled.draft.tokens.map(\.id), "both tokens staged, in their order")
        #expect(board.tray.map(\.label) == ["a.py:1", "b.py:1"])
    }

    @Test func aDraftStillGoingOutWhenTheAppQuitComesBack() async throws {
        let alpha = try terminal("alpha")
        let a = code("a.py")
        showTray(to: alpha)
        try board.stage(line(a, "a.py"))
        let begun = try #require(ComposerSend.begin(draft(["fix"]), targets: [alpha], on: board))
        var state = ComposerState(draft: begun.remaining)
        state.sending(begun.send.draft)
        state.draft = ComposerDraft(text: "later")
        // Quit before the text went in: saved, read back on the next launch.
        var relaunched = try JSONDecoder().decode(ComposerState.self, from: JSONEncoder().encode(state))
        relaunched.recoverOutgoing(on: board)
        #expect(relaunched.draft.prompt == "[1] fix later" && relaunched.outgoing.isEmpty)
        #expect(board.tray.map(\.label) == ["a.py:1"] && relaunched.draft.tokens.map(\.id) == board.tray.map(\.id))

        // One that went in is history, not a draft to restore.
        state.reached(begun.send.draft)
        #expect(state.outgoing.isEmpty && state.history == [begun.send.draft])
    }

    @Test func aTerminalWithoutAnIntegrationGetsTheContextAheadOfTheText() async throws {
        let shell = try terminal("zsh", agent: false)
        let a = code("a.py")
        try board.stage(line(a, "a.py"))
        let (sent, _, _) = try await send(draft(["why?"]), to: [shell, shell])
        #expect(sent.deliveries.count == 1, "a target listed twice gets the text once")
        let text = try #require(typed[shell]?.first)
        #expect(typed[shell]?.count == 1)
        #expect(text.hasPrefix("<canvas-mentions board=\"\(board.id)\"") && text.contains("[1] code a.py:1-1") && text.hasSuffix("</canvas-mentions>\n[1] why?"))
        #expect(board.composerPrompts[shell] == nil, "nothing there drains")
    }
}
