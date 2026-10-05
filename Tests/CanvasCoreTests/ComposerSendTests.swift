import Foundation
import Testing
import CanvasCore

/// The composer's ⌘↩ through the router (`ComposerSend`, `ApiRouter.composerPrompt`) and the
/// drains its targets' integrations make over the socket: each integration's submission drain
/// (with the text it submits, however the agent rewrote it) claims the oldest prompt the composer
/// typed there, with that prompt's own mentions numbered from 1; every other drain takes the tray
/// as it always did.
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

    func agent(_ tile: ObjectID, _ kind: String, _ state: LifecycleState, _ message: String? = nil) throws {
        try board.reportLifecycle(tile: tile, kind: kind, state: state, message: message, seq: nil, source: nil)
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
        #expect(try await drain(beta, "[1] one [2] two") == ["[1] a.py", "[2] b.py"], "beta's prompt gets its own, not the tray's new [1]")
        #expect(board.tray.map(\.label) == ["c.py:1"], "the mention staged meanwhile waits for the next prompt")
        #expect(board.delivered == delivered + 4)
        #expect(try await drain(alpha, "[1] again").isEmpty, "delivered once: alpha isn't the tray's prompt target any more")
        #expect(try await drain(beta, "[1] next") == ["[1] c.py"], "the next prompt in beta takes the tray again")
    }

    @Test func aPromptTheAgentRewroteStillTakesItsOwnMentions() async throws {
        let claude = try terminal("claude"), codex = try terminal("codex"), omp = try terminal("omp"), opencode = try terminal("opencode")
        try agent(claude, "claude", .idle)
        try agent(codex, "codex", .idle)
        try agent(opencode, "opencode", .idle)
        let a = code("a.py"), x = code("x.py")
        let long = "Summarize:\nalpha\nbeta\ngamma"
        for (tile, text) in [(claude, "\(long) [1]"), (codex, "fix [1]"), (omp, "Review :) [1]"), (opencode, "review [1]")] {
            try board.stage(line(a, "a.py"))
            try await send(ComposerDraft(text: text.replacingOccurrences(of: "[1]", with: mark), tokens: board.tray), to: [tile])
        }
        showTray(to: claude)
        try board.stage(line(x, "x.py"))
        // What each agent's integration sees: Claude Code's paste wrapper, Codex's IDE context,
        // omp's emoji, text already in opencode's editor ahead of the paste.
        #expect(try await drain(claude, "<pasted_content id=\"1\">\n\(long) [1]\n</pasted_content>") == ["[1] a.py"])
        #expect(try await drain(codex, "# Context from my IDE setup:\n## Open tabs:\n- a.py\n## My request for Codex:\nfix [1]") == ["[1] a.py"])
        #expect(try await drain(omp, "Review 🙂 [1]") == ["[1] a.py"])
        #expect(try await drain(opencode, "Please review [1]") == ["[1] a.py"])
        #expect(board.tray.map(\.label) == ["x.py:1"] && board.composerPrompts.isEmpty)
    }

    @Test func promptsQueuedMidTurnDrainInTheOrderTheyWereSent() async throws {
        let alpha = try terminal("alpha")
        let a = code("a.py"), b = code("b.py"), x = code("x.py")
        showTray(to: alpha)
        try agent(alpha, "omp", .working)
        try board.stage(line(a, "a.py"))
        try await send(draft(["first"]), to: [alpha])
        try board.stage(line(b, "b.py"))
        try await send(draft(["second"]), to: [alpha])
        try board.stage(line(x, "x.py"))
        #expect(typed[alpha] == ["[1] first", "[1] second"])

        // The turn runs 15 minutes before the agent submits them.
        board.expireComposerPrompts(now: Date().addingTimeInterval(15 * 60))
        #expect(board.composerPrompts[alpha]?.count == 2 && board.tray.map(\.label) == ["x.py:1"])
        #expect(try await drain(alpha, "[1] first") == ["[1] a.py"])
        #expect(try await drain(alpha, "[1] second") == ["[1] b.py"], "the second's [1] is b, as its text says")
        #expect(try await drain(alpha, "[1] then") == ["[1] x.py"], "then the tray again")
    }

    @Test func aSlashCommandOrShellEscapeTakesNoMentionsWhereItsIntegrationSkipsIt() async throws {
        let claude = try terminal("claude"), omp = try terminal("omp"), opencode = try terminal("opencode")
        try agent(claude, "claude", .idle)
        try agent(opencode, "opencode", .idle)
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
        try await send(ComposerDraft(text: "$ ls"), to: [omp])
        try await send(ComposerDraft(text: "$5 budget"), to: [claude])
        #expect(board.composerPrompts[omp] == nil && board.composerPrompts[claude]?.map(\.prompt) == ["$5 budget"])

        // opencode takes pasted `!…` and `/…` text as a prompt: its mentions go with it.
        showTray(to: opencode)
        try board.stage(line(a, "a.py"))
        var bang = ComposerDraft(text: "!x ")
        bang.insert(board.tray[0], at: nil)
        let (pasted, _, _) = try await send(bang, to: [opencode])
        #expect(pasted.takesMentions && typed[opencode] == ["!x [1]"] && board.tray.isEmpty)
        #expect(try await drain(opencode, "!x [1]") == ["[1] a.py"])
    }

    @Test func peeksAndDrainsWithoutAPromptNeverTouchTheComposersPrompts() async throws {
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
        try agent(alpha, "omp", .idle)
        try board.stage(line(b, "b.py"))
        try await send(draft(["one", "two"]), to: [alpha])
        board.terminalProgram(alpha, is: nil)
        #expect(board.tray.map(\.label) == ["a.py:1", "b.py:1"] && board.composerPrompts[alpha] == nil, "exited to the shell")

        try agent(alpha, "omp", .idle)
        try await send(draft(["one", "two"]), to: [alpha])
        board.expireComposerPrompts(now: Date().addingTimeInterval(ComposerPrompt.lifetime + 1))
        #expect(board.tray.map(\.label) == ["a.py:1", "b.py:1"] && board.composerPrompts[alpha] == nil, "nor after the safety cap")
        #expect(returned.count == 3)
    }

    @Test func aDialogAnswerGoesOnceTheAgentIsPastTheQuestion() async throws {
        let claude = try terminal("claude")
        let a = code("a.py"), b = code("b.py")
        showTray(to: claude)
        try agent(claude, "claude", .blocked, "Allow?")
        try board.stage(line(a, "a.py"))
        let staged = board.tray

        #expect(try await call("agent.prompt", #"{"target":"\#(claude)","text":"2"}"#)["error"]?["code"] == .string("conflict"), "an agent can't answer for the user")
        var answer = ComposerDraft(text: "2 ")
        answer.insert(staged[0], at: nil)
        let (sent, remaining, _) = try await send(answer, to: [claude])
        #expect(!sent.takesMentions && typed[claude] == ["2 [1]"])
        #expect(remaining.tokens.map(\.id) == staged.map(\.id) && board.tray == staged, "the tokens stay staged for the next prompt")
        #expect(board.composerPrompts[claude]?.map(\.answer) == [true])

        // The dialog takes it: no drain, the call finishes and the turn goes on.
        board.expireComposerPrompts(now: Date().addingTimeInterval(60))
        #expect(board.composerPrompts[claude]?.count == 1, "still blocked: the answer waits")
        try agent(claude, "claude", .working)
        board.expireComposerPrompts(now: Date().addingTimeInterval(ComposerPrompt.answerGrace + 1))
        #expect(board.composerPrompts[claude] == nil)
        try board.stage(line(b, "b.py"))
        #expect(try await drain(claude, "now the tests") == ["[1] a.py", "[2] b.py"], "the prompt typed next takes the live tray")
    }

    @Test func aCodexAnswerAsAPromptTakesNothingAndThePromptAfterItKeepsItsOwn() async throws {
        let codex = try terminal("codex")
        let a = code("a.py"), b = code("b.py")
        showTray(to: codex)
        try agent(codex, "codex", .blocked, "Which color?")
        try board.stage(line(a, "a.py"))
        try await send(draft(["blue"]), to: [codex])
        #expect(board.composerPrompts[codex]?.map(\.answer) == [true] && board.tray.map(\.label) == ["a.py:1"])
        // Codex's answer arrives as a prompt: its hook reports working, then drains.
        try agent(codex, "codex", .working)
        #expect(try await drain(codex, "blue [1]").isEmpty, "the answer's drain takes nothing")
        #expect(board.tray.map(\.label) == ["a.py:1"])

        // The composer prompt after it, queued mid-turn: its drain takes its own mention.
        try await send(draft(["use it"]), to: [codex])
        try board.stage(line(b, "b.py"))
        #expect(try await drain(codex, "[1] use it") == ["[1] a.py"], "the prompt after it keeps its mention")
        #expect(board.tray.map(\.label) == ["b.py:1"] && board.composerPrompts[codex] == nil)
    }

    @Test func mentionsComeBackWhenOnlyAnAnswerWentIn() async throws {
        let codex = try terminal("codex"), alpha = try terminal("alpha")
        let a = code("a.py")
        showTray(to: alpha)
        try agent(codex, "codex", .blocked, "Which color?")
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
