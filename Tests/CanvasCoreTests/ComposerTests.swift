import Foundation
import Testing
import CanvasCore

/// The composer's tokens and the tray stay one-to-one and in one order, so the `[n]` the prompt
/// says is the `[n]` the context gives every agent it goes to.
@MainActor
struct ComposerTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-composer-\(UUID().uuidString)")
    let mark = ComposerDraft.mark

    func makeBoard() -> Board {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Board(id: "brd_test", root: root)
    }

    func code(_ path: String, on board: Board, x: Double) -> CanvasObject {
        board.create(type: .code, props: .object(["path": .string(path)]), frame: Frame(x: x, y: 0, w: 640, h: 446))
    }

    func line(_ tile: CanvasObject, _ path: String) -> MentionTarget {
        .code(object: tile.id, path: path, lines: LineRange(start: 1, end: 1))
    }

    /// `[n] path` for each mention in a context block, in order.
    func numbered(_ context: String) -> [String] {
        context.split(separator: "\n").compactMap { row in
            guard row.hasPrefix("["), let close = row.firstIndex(of: "]"), let path = row.split(separator: " ").dropFirst(2).first else { return nil }
            return "\(row[...close]) \(path.split(separator: ":").first ?? path)"
        }
    }

    /// The `[n]` tokens of a prompt with the file each stands for, as the user reads them.
    func tokens(_ draft: ComposerDraft) -> [String] {
        draft.tokens.enumerated().map { index, mention in
            guard case .code(_, let path, _, _, _, _, _) = mention.target else { return "?" }
            return "[\(index + 1)] \(path)"
        }
    }

    /// The user's edit as the text view makes it: the same draft with one token's mark (and the
    /// space after it) taken out of the text.
    func deleting(_ index: Int, from draft: ComposerDraft) -> ComposerDraft {
        var edited = draft
        var caret: Int?
        edited.removeTokens(at: [index], caret: &caret)
        return edited
    }

    @Test func aTokenLandsAtTheCaretAndTheTrayTakesTheTokenOrder() async throws {
        let board = makeBoard()
        let a = code("a.py", on: board, x: 0), b = code("b.py", on: board, x: 700), c = code("c.py", on: board, x: 1400)
        var draft = ComposerDraft()
        try board.stage(line(a, "a.py"))
        try board.stage(line(b, "b.py"))
        _ = ComposerSync.trayChanged(&draft, caret: nil, on: board)
        #expect(draft.text == "\(mark) \(mark) ", "unfocused, each Hyper-click's token goes at the end")
        draft.text = "\(mark) make this green \(mark) drop this row"

        try board.stage(line(c, "c.py"))
        let caret = ComposerSync.trayChanged(&draft, caret: 0, on: board)
        #expect(draft.prompt == "[1] [2] make this green [3] drop this row")
        #expect(caret == 2, "the note for the new token is typed right after it")
        #expect(tokens(draft) == ["[1] c.py", "[2] a.py", "[3] b.py"])
        #expect(board.tray.map(\.id) == draft.tokens.map(\.id), "the chip order is the token order")
        #expect(numbered(await board.drain(peek: true).context) == tokens(draft), "the context numbers each mention as the prompt does")
    }

    @Test func deletingATokenUnstagesItAndTheRestRenumberInBoth() async throws {
        let board = makeBoard()
        let a = code("a.py", on: board, x: 0), b = code("b.py", on: board, x: 700), c = code("c.py", on: board, x: 1400)
        var draft = ComposerDraft()
        for (tile, path) in [(a, "a.py"), (b, "b.py"), (c, "c.py")] { try board.stage(line(tile, path)) }
        _ = ComposerSync.trayChanged(&draft, caret: nil, on: board)
        draft.text = "\(mark) one \(mark) two \(mark) three"
        let removed = draft.tokens[1]

        var edited = deleting(1, from: draft)
        var caret: Int?
        ComposerSync.edited(&edited, previous: draft, caret: &caret, on: board)
        #expect(!board.tray.contains { $0.id == removed.id }, "deleting a token unstages its mention")
        #expect(edited.prompt == "[1] one two [2] three")
        #expect(numbered(await board.drain(peek: true).context) == ["[1] a.py", "[2] c.py"])

        // ⌘Z puts the token back: its mention is staged again, where the token is.
        var undone = draft
        ComposerSync.edited(&undone, previous: edited, caret: &caret, on: board)
        #expect(tokens(undone) == ["[1] a.py", "[2] b.py", "[3] c.py"])
        #expect(board.tray.map(\.id) == undone.tokens.map(\.id))
        #expect(numbered(await board.drain(peek: true).context) == tokens(undone))
    }

    @Test func unstagingElsewhereTakesTheTokenOutAndKeepsTheWords() async throws {
        let board = makeBoard()
        let a = code("a.py", on: board, x: 0), b = code("b.py", on: board, x: 700)
        var draft = ComposerDraft()
        try board.stage(line(a, "a.py"))
        try board.stage(line(b, "b.py"))
        _ = ComposerSync.trayChanged(&draft, caret: nil, on: board)
        draft.text = "\(mark) make this green \(mark) drop this row"

        try board.unstage(draft.tokens[0].id)
        let caret = ComposerSync.trayChanged(&draft, caret: (draft.text as NSString).length, on: board)
        #expect(draft.prompt == "make this green [1] drop this row")
        #expect(caret == (draft.text as NSString).length, "the caret stays where the user was typing")
        #expect(numbered(await board.drain(peek: true).context) == ["[1] b.py"])

        // A prompt typed in the terminal takes the tray: only the words are left, and a draft
        // of nothing but tokens empties.
        _ = await board.drain()
        _ = ComposerSync.trayChanged(&draft, caret: nil, on: board)
        #expect(draft.prompt == "make this green drop this row")
        var tokensOnly = ComposerDraft()
        try board.stage(line(a, "a.py"))
        _ = ComposerSync.trayChanged(&tokensOnly, caret: nil, on: board)
        _ = await board.drain()
        _ = ComposerSync.trayChanged(&tokensOnly, caret: nil, on: board)
        #expect(tokensOnly.isEmpty && tokensOnly.text.isEmpty)
    }

    @Test func aDamagedSavedDraftKeepsItsWordsAndNeverTrapsTheBoardOpening() throws {
        let board = makeBoard()
        let a = code("a.py", on: board, x: 0)
        try board.stage(line(a, "a.py"))
        // A valid file whose draft has a mark but no token, and a target listed twice.
        let saved = #"{"draft":{"text":"\#(mark) fix this","tokens":[]},"history":[{"text":"\#(mark)\#(mark)","tokens":[]}],"alsoTo":["obj_B","obj_B","obj_C"]}"#
        let state = try JSONDecoder().decode(ComposerState.self, from: Data(saved.utf8)).repaired
        #expect(state.draft == ComposerDraft(text: " fix this"), "the words stay; the orphan mark goes")
        #expect(state.history.allSatisfy { $0.tokens.isEmpty && !$0.text.contains(mark) })
        #expect(state.alsoTo == ["obj_B", "obj_C"], "each target once, so a send never types into one twice")

        var draft = state.draft
        _ = ComposerSync.trayChanged(&draft, caret: nil, on: board)
        #expect(draft.prompt == "fix this [1]", "the staged mention gets its token")
        #expect(board.tray.map(\.id) == draft.tokens.map(\.id))
    }

    @Test func aRecalledPromptStagesItsTokensAgainWithItsNumbers() async throws {
        let board = makeBoard()
        let a = code("a.py", on: board, x: 0), b = code("b.py", on: board, x: 700)
        var state = ComposerState()
        try board.stage(line(a, "a.py"))
        try board.stage(line(b, "b.py"))
        _ = ComposerSync.trayChanged(&state.draft, caret: nil, on: board)
        state.draft.text = "\(mark) this \(mark) that"
        state.record(state.draft)
        _ = await board.drain()
        state.draft = ComposerDraft()
        _ = ComposerSync.trayChanged(&state.draft, caret: nil, on: board)
        #expect(state.draft.isEmpty && board.tray.isEmpty, "sent: the tray went with the prompt")

        let previous = state.draft
        var recalled = try #require(state.history.last)
        var caret: Int?
        ComposerSync.edited(&recalled, previous: previous, caret: &caret, on: board)
        #expect(recalled.prompt == "[1] this [2] that")
        #expect(board.tray.map(\.id) == recalled.tokens.map(\.id))
        #expect(numbered(await board.drain(peek: true).context) == ["[1] a.py", "[2] b.py"])

        // ↓ back to an empty composer unstages what the recall staged.
        var empty = ComposerDraft()
        ComposerSync.edited(&empty, previous: recalled, caret: &caret, on: board)
        #expect(board.tray.isEmpty)
    }
}
