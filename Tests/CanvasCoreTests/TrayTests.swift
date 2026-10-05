import CoreGraphics
import Foundation
import Testing
import CanvasCore

/// The mention tray: chips numbered as the context numbers them, a chip's click revealing what
/// it points at, and chips that come back with ⌘Z.
@MainActor
struct TrayTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-tray-\(UUID().uuidString)")

    func makeBoard() -> Board {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Board(id: "brd_test", root: root)
    }

    func code(_ path: String, on board: Board, x: Double = 0) -> CanvasObject {
        board.create(type: .code, props: .object(["path": .string(path)]), frame: Frame(x: x, y: 0, w: 640, h: 446))
    }

    func line(_ tile: CanvasObject, _ path: String, _ line: Int) -> MentionTarget {
        .code(object: tile.id, path: path, lines: LineRange(start: line, end: line))
    }

    /// The `[n] code <path>` lines of the context the tray drains into, in order.
    func contextNumbers(_ board: Board) async -> [String] {
        await board.drain(peek: true).context.split(separator: "\n").compactMap { row in
            guard row.hasPrefix("["), let close = row.firstIndex(of: "]"), let path = row.split(separator: " ").dropFirst(2).first else { return nil }
            return "\(row[...close]) \(path.split(separator: ":").first ?? path)"
        }
    }

    // MARK: Numbering

    @Test func chipsAreNumberedAsTheContextNumbersThemAndRenumberOnUnstage() async throws {
        let board = makeBoard()
        let tile = code("a.py", on: board)
        for (path, row) in [("a.py", 1), ("b.py", 2), ("c.py", 3)] {
            try board.stage(line(path == "a.py" ? tile : code(path, on: board, x: Double(row) * 700), path, row))
        }
        func chips() -> [String] {
            TrayChips.numbered(board.tray).map { number, mention in
                guard case .code(_, let path, _, _, _, _, _) = mention.target else { return "?" }
                return "\(TrayChips.badge(number)) \(path)"
            }
        }
        #expect(chips() == ["[1] a.py", "[2] b.py", "[3] c.py"])
        #expect(await contextNumbers(board) == chips(), "the chip says the number the agent reads")

        try board.unstage(board.tray[1].id)
        #expect(chips() == ["[1] a.py", "[2] c.py"], "the chips after an unstaged one move up a number")
        #expect(await contextNumbers(board) == chips())
    }

    @Test func aDomChipSaysThePageChangedNotThatItWasEdited() throws {
        let board = makeBoard()
        let page = board.create(type: .browser, props: .object(["url": .string("http://localhost:5173/")]), frame: Frame(x: 0, y: 0, w: 1000, h: 726))
        let note = board.create(type: .note, props: .object(["markdown": .string("one")]), frame: Frame(x: 1100, y: 0, w: 280, h: 200))
        try board.stage(.dom(object: page.id, url: "http://localhost:5173/", selector: "#buy", text: "Buy"))
        try board.stage(.object(note.id))
        #expect(board.tray.allSatisfy { TrayChips.changedNote($0, on: board) == nil }, "nothing changed yet")

        try board.update(page.id, props: .object(["url": .string("http://localhost:5173/checkout")]))
        try board.update(note.id, props: .object(["markdown": .string("two")]))
        #expect(TrayChips.changedNote(board.tray[0], on: board) == "page changed", "a navigation changed the page; nobody edited it")
        #expect(TrayChips.changedNote(board.tray[1], on: board) == "edited")
    }

    @Test func aSecondToggleUnstagesAndSaysWhatItRemoved() throws {
        let board = makeBoard()
        let tile = code("src/cart.ts", on: board)
        guard case .staged(let staged) = board.toggle(line(tile, "src/cart.ts", 18)) else { Issue.record("the first toggle stages"); return }
        #expect(board.toggle(line(tile, "src/cart.ts", 18)) == .unstaged(staged))
        #expect(board.tray.isEmpty)
        #expect(TrayChips.unstagedNotice(staged).contains(staged.label), "the notice names what left the tray")
    }

    @Test func aShrunkCodeChipDropsItsDirectoryFirstAndAlwaysKeepsItsLines() throws {
        let board = makeBoard()
        let tile = code("src/checkout.ts", on: board)
        let range = try board.stage(.code(object: tile.id, path: "src/checkout.ts", lines: LineRange(start: 10, end: 45), symbol: "checkout10"))
        let measure: (String) -> CGFloat = { CGFloat($0.count) * 7 }
        func fitted(_ width: CGFloat) -> String { TrayChips.fittedLabel(range, width: width, measure: measure) }

        #expect(fitted(1000) == "src/checkout.ts:10-45 checkout10", "room to spare: the whole label")
        #expect(fitted(CGFloat("checkout.ts:10-45 checkout10".count) * 7) == "checkout.ts:10-45 checkout10", "the directory goes first")
        #expect(fitted(CGFloat("checkout.ts:10-45".count) * 7) == "checkout.ts:10-45", "then the symbol")
        #expect(fitted(CGFloat("chec…t.ts:10-45".count) * 7) == "chec…t.ts:10-45", "then the middle of the file name")
        // A tight label's room: the token's number and insets take the rest.
        let floor: CGFloat = 70
        #expect(fitted(floor).hasSuffix(":10-45") && !fitted(floor).contains("src/"), "at the floor the lines still show: \(fitted(floor))")
        #expect(measure(fitted(floor)) <= floor)
        #expect(fitted(10).hasSuffix(":10-45"), "however narrow, the lines stay")

        let note = board.create(type: .note, props: .object(["markdown": .string("# Plan\n\ncheck tax")]), frame: Frame(x: 0, y: 600, w: 280, h: 200))
        let block = try board.stage(.note(object: note.id, item: try #require(NoteItem.at(line: 3, in: "# Plan\n\ncheck tax"))))
        #expect(TrayChips.fittedLabel(block, width: 30, measure: measure) == block.label, "a note keeps its label; the chip cuts its tail, keeping the title's start")
    }

    // MARK: Click to reveal

    @Test func aChipRevealsTheLinesOnlyWhileItsTileStillShowsThatFile() throws {
        let board = makeBoard()
        let tile = code("src/cart.ts", on: board)
        let target = line(tile, "src/cart.ts", 18)
        #expect(MentionReveal(target, on: board) == MentionReveal(objects: [tile.id], part: tile.id), "the tile, scrolled to line 18")

        try board.update(tile.id, props: .object(["path": .string("src/other.ts")]))
        #expect(MentionReveal(target, on: board) == MentionReveal(objects: [tile.id], part: nil),
                "a tile re-aimed at another file shows the tile alone, never another file's line 18")

        let changes = board.create(type: .changes, props: .object([:]), frame: Frame(x: 0, y: 600, w: 820, h: 620))
        #expect(MentionReveal(.code(object: changes.id, path: "src/cart.ts", lines: LineRange(start: 3, end: 5), side: "new"), on: board)?.part == changes.id,
                "a changes tile's line range is scrolled to in the changes tile")
    }

    @Test func aChipRevealsNoteBlocksAndWholeObjectsAndWhatIsLeftOfAGroup() throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("# Plan\n\nship it")]), frame: Frame(x: 0, y: 0, w: 280, h: 200))
        let item = try #require(NoteItem.at(line: 3, in: "# Plan\n\nship it"))
        #expect(MentionReveal(.note(object: note.id, item: item), on: board) == MentionReveal(objects: [note.id], part: note.id))
        #expect(MentionReveal(.object(note.id), on: board) == MentionReveal(objects: [note.id], part: nil))

        let a = code("a.py", on: board, x: 400), b = code("b.py", on: board, x: 1100)
        let group = MentionTarget.group(objects: [a.id, b.id, note.id], name: "Work")
        #expect(MentionReveal(group, on: board) == MentionReveal(objects: [a.id, b.id, note.id], part: nil))
        try board.delete(b.id)
        #expect(MentionReveal(group, on: board)?.objects == [a.id, note.id], "a deleted member is left out")
        try board.delete(a.id)
        try board.delete(note.id)
        #expect(MentionReveal(group, on: board) == nil, "nothing left to show")
    }

    @Test func revealingAMentionKeepsTheZoomUnlessATileMustTurnLiveAndNeverPasses100Percent() {
        let clear = CGRect(x: 0, y: 0, width: 1400, height: 800)
        func shown(_ jump: Layout.Jump) -> CGRect {
            CGRect(x: jump.origin.x + clear.minX / jump.zoom, y: jump.origin.y + clear.minY / jump.zoom, width: clear.width / jump.zoom, height: clear.height / jump.zoom)
        }
        let limits: ClosedRange<CGFloat> = 0.1...1
        let tile = CGRect(x: 3000, y: 2000, width: 640, height: 446)

        let inView = Layout.Jump(zoom: 0.8, origin: CGPoint(x: 2900, y: 1900))
        #expect(Layout.revealMention(tile, readable: 0.5, from: inView, clear: clear, padding: 20, zoom: limits) == inView, "in view already: nothing moves")

        let away = Layout.Jump(zoom: 0.8, origin: .zero)
        let panned = Layout.revealMention(tile, readable: 0.5, from: away, clear: clear, padding: 20, zoom: limits)
        #expect(panned.zoom == 0.8, "out of view at a live zoom: a pan, same zoom")
        #expect(shown(panned).contains(tile))

        let overview = Layout.Jump(zoom: 0.2, origin: .zero)
        let lines = Layout.revealMention(tile, readable: 0.5, from: overview, clear: clear, padding: 20, zoom: limits)
        #expect(lines.zoom >= 0.5 && lines.zoom <= 1, "a line needs a live tile: zoomed to at least readable, at most 100%")
        #expect(shown(lines).contains(tile))
        let small = CGRect(x: 3000, y: 2000, width: 200, height: 100)
        #expect(Layout.revealMention(small, readable: 0.5, from: overview, clear: clear, padding: 20, zoom: limits).zoom == 1, "a small tile stops at 100%")

        let whole = Layout.revealMention(tile, readable: nil, from: overview, clear: clear, padding: 20, zoom: limits)
        #expect(whole.zoom == 0.2, "a whole object keeps the overview's zoom")
        #expect(shown(whole).contains(tile))

        let wide = CGRect(x: 0, y: 0, width: 5000, height: 1000)
        let fitted = Layout.revealMention(wide, readable: nil, from: Layout.Jump(zoom: 1, origin: .zero), clear: clear, padding: 20, zoom: limits)
        #expect(fitted.zoom < 1, "a group too big to show whole zooms out to fit")
        #expect(shown(fitted).contains(wide))
    }

    // MARK: Undo

    @Test func undoingADeleteBringsItsChipsBackInPlace() throws {
        let board = makeBoard()
        let a = code("a.py", on: board), b = code("b.py", on: board, x: 700), c = code("c.py", on: board, x: 1400)
        try board.stage(line(a, "a.py", 1))
        try board.stage(line(b, "b.py", 2))
        try board.stage(.object(b.id))
        try board.stage(line(c, "c.py", 3))
        let before = board.tray

        try board.delete(b.id)
        #expect(board.tray.map(\.id) == [before[0].id, before[3].id])
        #expect(board.undo())
        #expect(board.tray == before, "⌘Z puts the tile back and its chips where they were, numbers and all")
        #expect(board.redo())
        #expect(board.tray.map(\.id) == [before[0].id, before[3].id], "⇧⌘Z takes them out again")
    }

    @Test func undoingAHyperVPasteBringsTheChipsBack() async throws {
        let board = makeBoard()
        let shell = board.create(type: .terminal, props: .object(["cwd": .string(root.path), "command": .array([])]), frame: Frame(x: 0, y: 600, w: 800, h: 500))
        let a = code("a.py", on: board), b = code("b.py", on: board, x: 700)
        try board.stage(line(a, "a.py", 1))
        try board.stage(line(b, "b.py", 2))
        let before = board.tray

        let drained = await board.drain(peek: true, caller: shell.id)
        board.commit(drained.mentions.map(\.id), pastedInto: shell.id)
        #expect(board.tray.isEmpty)
        #expect(board.nextUndo?.pastedInto == shell.id, "the paste is the step a ⌘Z in that terminal undoes")
        #expect(board.nextUndo?.title == "Paste of 2 Mentions")
        #expect(board.undo())
        #expect(board.tray == before)
        #expect(board.redo())
        #expect(board.tray.isEmpty)

        try board.stage(line(a, "a.py", 1))
        let steps = board.history.undoSteps.count
        let prompt = await board.drain(caller: shell.id)
        #expect(!prompt.context.isEmpty && board.tray.isEmpty)
        #expect(board.history.undoSteps.count == steps, "an agent's prompt taking the tray is its delivery, not an undo step")
    }
}
