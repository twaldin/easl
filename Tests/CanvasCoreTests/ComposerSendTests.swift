import Foundation
import Testing
import CanvasCore

/// The composer's ⌘↩ through the router (`ComposerSend`, `ApiRouter.composerPrompt`) and the
/// drains its targets' integrations make over the socket: each sent prompt keeps its own
/// mentions, numbered from 1, for the terminal it went to, whatever happens before the drain.
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

    /// ⌘↩: what the controller does, through the router, until every target was tried.
    @discardableResult
    func send(_ draft: ComposerDraft, to targets: [ObjectID]) async throws -> (send: ComposerSend, remaining: ComposerDraft) {
        let begun = try #require(ComposerSend.begin(draft, targets: targets, on: board))
        for delivery in begun.send.deliveries {
            try await router.composerPrompt(await begun.send.text(for: delivery, on: board), to: delivery.terminal, on: board, mentions: delivery.mentions, answer: delivery.answer)
        }
        return begun
    }

    /// An integration's drain for `caller` (peek, then commit), as the hooks make it: the
    /// `[n] path` rows of its context.
    func drain(_ caller: ObjectID) async throws -> [String] {
        let drained = try #require(try await call("tray.drain", #"{"caller":"\#(caller)","peek":true}"#)["result"])
        let ids = drained["mentions"]?.array?.compactMap { $0["id"]?.string } ?? []
        if !ids.isEmpty { _ = try await call("tray.commit", #"{"ids":[\#(ids.map { "\"\($0)\"" }.joined(separator: ","))]}"#) }
        return (drained["context"]?.string ?? "").split(separator: "\n").compactMap { row in
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

        let (_, remaining) = try await send(draft(["one", "two"]), to: [alpha, beta])
        #expect(typed[alpha] == ["[1] one [2] two"] && typed[beta] == ["[1] one [2] two"])
        #expect(remaining.isEmpty && board.tray.isEmpty, "the sent mentions left the composer and the tray at once")

        // Before either integration drains: a new mention, and the tray retargeted to beta.
        try board.stage(line(c, "c.py"))
        showTray(to: beta)
        #expect(try await drain(alpha) == ["[1] a.py", "[2] b.py"], "alpha's prompt keeps its mentions though the tray now shows beta")
        #expect(try await drain(beta) == ["[1] a.py", "[2] b.py"], "beta's prompt gets its own, not the tray's new [1]")
        #expect(board.tray.map(\.label) == ["c.py:1"], "the mention staged meanwhile waits for the next prompt")
        #expect(board.delivered == delivered + 4)
        #expect(try await drain(alpha).isEmpty, "delivered once")
        #expect(try await drain(beta) == ["[1] c.py"], "the next prompt in beta takes the tray again")
    }

    @Test func twoPromptsSentBeforeAnyDrainEachKeepTheirOwnNumbers() async throws {
        let alpha = try terminal("alpha")
        let a = code("a.py"), b = code("b.py")
        showTray(to: alpha)
        try board.stage(line(a, "a.py"))
        try await send(draft(["first"]), to: [alpha])
        try board.stage(line(b, "b.py"))
        try await send(draft(["second"]), to: [alpha])
        #expect(typed[alpha] == ["[1] first", "[1] second"])
        #expect(try await drain(alpha) == ["[1] a.py"], "the first prompt's drain takes the first prompt's mention")
        #expect(try await drain(alpha) == ["[1] b.py"], "the second's [1] is b, as its text says")
    }

    @Test func anAnswerToABlockedAgentKeepsTheTrayOutOfItsDrain() async throws {
        let codex = try terminal("codex")
        let a = code("a.py")
        showTray(to: codex)
        try board.reportLifecycle(tile: codex, kind: "codex", state: .blocked, message: "Which color?", seq: nil, source: nil)
        try board.stage(line(a, "a.py"))
        let staged = board.tray

        #expect(try await call("agent.prompt", #"{"target":"\#(codex)","text":"blue"}"#)["error"]?["code"] == .string("conflict"), "an agent can't answer for the user")
        let (sent, remaining) = try await send(draft(["blue"]), to: [codex])
        #expect(sent.answersOnly && typed[codex] == ["[1] blue"])
        #expect(remaining.tokens.map(\.id) == staged.map(\.id) && board.tray == staged, "the tokens stay staged for the next prompt")
        #expect(try await drain(codex).isEmpty, "Codex's answer arrives as a prompt: its drain takes nothing")
        #expect(board.tray == staged)
        #expect(try await drain(codex) == ["[1] a.py"], "the prompt after it takes the tray")

        // An answer typed into a dialog causes no drain: it stops counting after its lifetime.
        try board.stage(line(code("b.py"), "b.py"))
        board.queueComposerPrompt(to: codex, mentions: [], answer: true, now: Date().addingTimeInterval(-ComposerPrompt.answerLifetime - 1))
        #expect(try await drain(codex) == ["[1] b.py"])
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

        let restored = begun.send.restore(into: current, on: board)
        #expect(restored.prompt == "[1] fix [2] and this")
        #expect(board.tray.map(\.id) == restored.tokens.map(\.id), "both tokens staged, in their order")
        #expect(board.tray.map(\.label) == ["a.py:1", "b.py:1"])
    }

    @Test func aTerminalWithoutAnIntegrationGetsTheContextAheadOfTheText() async throws {
        let shell = try terminal("zsh", agent: false)
        let a = code("a.py")
        try board.stage(line(a, "a.py"))
        let (sent, _) = try await send(draft(["why?"]), to: [shell, shell])
        #expect(sent.deliveries.count == 1, "a target listed twice gets the text once")
        let text = try #require(typed[shell]?.first)
        #expect(typed[shell]?.count == 1)
        #expect(text.hasPrefix("<canvas-mentions board=\"\(board.id)\"") && text.contains("[1] code a.py:1-1") && text.hasSuffix("</canvas-mentions>\n[1] why?"))
        #expect(board.composerPrompts[shell] == nil, "nothing there drains")
    }
}
