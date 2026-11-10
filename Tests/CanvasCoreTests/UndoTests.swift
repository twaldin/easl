import Foundation
import Testing
import CanvasCore

@MainActor
struct UndoTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-undo-\(UUID().uuidString)")

    func makeBoard() -> Board {
        Board(id: "brd_test", root: root)
    }

    func terminal(on board: Board) -> CanvasObject {
        board.create(type: .terminal, props: .object(["cwd": .string(root.path), "command": .array([])]), frame: Frame(x: 0, y: 0, w: 800, h: 500))
    }
    @Test func htmlStateTransactionsUndoAndRedoExactSnapshots() throws {
        let board = makeBoard()
        let initial: JSONValue = .object(["draft": "saved", "cards": "keep"])
        let page = board.create(type: .html, props: .object(["state": initial]))
        for patch in [
            JSONValue.object(["draft": "edited", "new": "added"]),
            .object(["draft": .null]),
            .object(["draft": .null, "submitted": .object(["id": "sub_test"]), "pending": .bool(true)]),
            .null,
            .object([:])
        ] {
            let before = try board.object(page.id).props
            _ = try board.update(page.id, props: .object(["state": patch]))
            let after = try board.object(page.id).props
            if before == after { continue }
            #expect(board.undo())
            #expect(try board.object(page.id).props == before)
            #expect(board.redo())
            #expect(try board.object(page.id).props == after)
        }
    }


    @Test func userUndoesAnAgentsEdit() throws {
        let board = makeBoard()
        let agent = terminal(on: board)
        let note = board.create(type: .note, props: .object(["markdown": .string("mine")]), frame: Frame(x: 900, y: 0, w: 320, h: 200))
        try board.update(note.id, props: .object(["markdown": .string("rewritten by agent")]), caller: agent.id)

        #expect(board.undo())
        let restored = try board.object(note.id)
        #expect(restored.props["markdown"]?.string == "mine")
        #expect(restored.rev > 2, "undo is a new revision, so an agent holding rev 2 gets a conflict")
        #expect(throws: BoardError.self) { try board.update(note.id, rev: 2, props: .object(["markdown": .string("stale")]), caller: agent.id) }

        #expect(board.redo())
        #expect(try board.object(note.id).props["markdown"]?.string == "rewritten by agent")
    }

    @Test func undoingADeleteRestoresTheSameObjectAndStacking() throws {
        let board = makeBoard()
        let bottom = board.create(type: .note, props: .object(["markdown": .string("bottom")]))
        let middle = board.create(type: .code, props: .object(["path": .string("a.swift")]))
        _ = board.create(type: .note, props: .object(["markdown": .string("top")]))
        var events: [String] = []
        board.onEvent = { events.append($0.name) }

        try board.delete(middle.id)
        #expect(board.objects[middle.id] == nil)
        board.undo()

        let restored = try board.object(middle.id)
        #expect(restored.z == middle.z)
        #expect(restored.z > bottom.z)
        #expect(restored.frame == middle.frame)
        #expect(restored.props == middle.props)
        #expect(events == ["object.deleted", "object.created"], "the UI re-creates the tile from the ordinary created event")
    }

    @Test func undoingACreateRemovesItAndRedoBringsItBack() throws {
        let board = makeBoard()
        let agent = terminal(on: board)
        let created = board.create(type: .html, props: .object(["html": .string("<p>hi</p>")]), caller: agent.id)
        try board.stage(.object(created.id))

        board.undo()
        #expect(board.objects[created.id] == nil)
        #expect(board.tray.isEmpty, "an undone object takes its staged mentions with it, like any delete")

        board.redo()
        #expect(try board.object(created.id).props["html"]?.string == "<p>hi</p>")
    }

    @Test func transactionIsOneStep() throws {
        let board = makeBoard()
        let a = board.create(type: .note, props: .object([:]), frame: Frame(x: 0, y: 0, w: 100, h: 100))
        let b = board.create(type: .note, props: .object([:]), frame: Frame(x: 200, y: 0, w: 100, h: 100))
        let group = board.create(type: .group, props: .object(["members": .array([.string(a.id), .string(b.id)])]))

        // Move both, then ungroup, as one gesture.
        board.transaction {
            _ = try? board.update(a.id, frame: Frame(x: 50, y: 50, w: 100, h: 100))
            _ = try? board.update(b.id, frame: Frame(x: 250, y: 50, w: 100, h: 100))
            try? board.delete(group.id)
        }

        #expect(board.undo())
        #expect(try board.object(a.id).frame.x == 0)
        #expect(try board.object(b.id).frame.x == 200)
        #expect(board.objects[group.id] != nil)
        // The step before the gesture is the group's creation.
        #expect(board.undo())
        #expect(board.objects[group.id] == nil)
        #expect(board.objects[a.id] != nil)
    }

    @Test func nestedTransactionsCloseOnceAndEmptyOnesRecordNothing() throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("v1")]))
        board.transaction {
            board.transaction { _ = try? board.update(note.id, props: .object(["markdown": .string("v2")])) }
            _ = try? board.update(note.id, props: .object(["markdown": .string("v3")]))
        }
        board.transaction {}

        board.undo()
        #expect(try board.object(note.id).props["markdown"]?.string == "v1")
    }

    @Test func terminalBookkeepingIsNeitherRecordedNorRewound() throws {
        let board = makeBoard()
        let agent = terminal(on: board)
        let note = board.create(type: .note, props: .object(["markdown": .string("x")]))
        try board.update(agent.id, frame: Frame(x: 40, y: 40, w: 800, h: 500))
        try board.reportLifecycle(tile: agent.id, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        try board.reportSession(tile: agent.id, kind: "omp", sessionId: "s1", sessionPath: nil)
        try board.update(agent.id, props: .object(["title": .string("omp: fixing tests")]), caller: agent.id)

        // ⌘Z skips the bookkeeping and reverts the move, leaving lifecycle and session intact.
        board.undo()
        let reverted = try board.object(agent.id)
        #expect(reverted.frame.x == 0)
        #expect(reverted.props["lifecycle"]?["state"]?.string == "working")
        #expect(reverted.props["agent"]?["sessionId"]?.string == "s1")
        #expect(reverted.props["title"]?.string == "omp: fixing tests")
        #expect(board.objects[note.id] != nil)
    }

    @Test func followReportsAndWriteBacksAreNotTheUsersUndoSteps() throws {
        let board = makeBoard()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a.py", "b.py"] { try "one\ntwo\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let agent = terminal(on: board)
        let page = board.create(type: .browser, props: .object(["url": .string("http://localhost:3000")]))
        let follow = try #require(try board.follow(tile: agent.id, path: "a.py", range: LineRange(start: 1, end: 1), action: "read"))
        let steps = board.history.undoSteps.count
        #expect(steps == 2, "the follow tile appearing is no step")

        // The user moves the follow tile aside, then does something of their own.
        try board.update(follow.id, frame: Frame(x: 3000, y: 0, w: follow.frame.w, h: follow.frame.h))
        let note = board.create(type: .note, props: .object(["markdown": .string("mine")]))
        // Meanwhile the agent re-aims its follow tile, the page retitles itself, and the app
        // writes back what a note resolved.
        try board.follow(tile: agent.id, path: "b.py", range: LineRange(start: 2, end: 2), action: "edit")
        try board.writeBookkeeping(page.id, props: .object(["pageTitle": .string("Dashboard")]))
        try board.update(note.id, props: .object(["markdown": .string("mine, anchored")]), actor: .system)
        try board.follow(tile: agent.id, path: "a.py", range: LineRange(start: 2, end: 2), action: "read")
        #expect(board.history.undoSteps.count == steps + 2)

        #expect(board.undo())
        #expect(board.objects[note.id] == nil, "⌘Z undoes the user's last own action")
        #expect(board.objects[page.id]?.props["pageTitle"]?.string == "Dashboard")
        #expect(board.undo())
        let back = try board.object(follow.id)
        #expect(back.frame.x == follow.frame.x, "the user's move is undone")
        #expect(back.props["path"]?.string == "a.py" && back.props["range"]?["start"]?.int == 2, "but not the agent's latest aim")
        #expect(back.props["history"]?.array?.count == 3, "every report since stays listed")
        #expect(board.redo() && board.redo())
        #expect(try board.object(follow.id).frame.x == 3000)

        // Undoing the terminal's creation takes its follow tile along.
        while board.undo() {}
        #expect(board.objects.isEmpty)
    }

    @Test func aPagesOwnTitleIsBookkeepingThatNeverFightsTheAgent() throws {
        // Seen in use: the page's title replaced the agent's `title` and bumped `rev`, so the
        // creator's `object.update rev: 1` failed with a conflict.
        let board = makeBoard()
        let agent = terminal(on: board)
        let page = board.create(type: .browser, props: .object(["url": .string("http://localhost:5173/gui"), "title": .string("/gui at phone width (390)")]),
                                frame: Frame(x: 900, y: 0, w: 390, h: 800), caller: agent.id)
        var announced: [ObjectID] = []
        board.onEvent = { if case .objectUpdated(let object) = $0 { announced.append(object.id) } }
        var saves = 0
        board.onChange = { saves += 1 }
        let revision = board.revision, logged = board.activity.cursor, steps = board.history.undoSteps.count

        try board.writeBookkeeping(page.id, props: .object(["pageTitle": .string("GUI")]))
        let titled = try board.object(page.id)
        #expect(titled.rev == 1 && titled.updatedBy == nil, "not a revision of the object")
        #expect(titled.props["title"]?.string == "/gui at phone width (390)" && titled.props["pageTitle"]?.string == "GUI")
        #expect(board.changed(since: revision) == [page.id] && announced == [page.id] && saves == 1, "shown, persisted, and seen by board.get since")
        #expect(board.history.undoSteps.count == steps, "no undo step")
        #expect(board.activity.cursor == logged, "not logged")
        #expect(throws: BoardError.self) { try board.writeBookkeeping(page.id, props: .object(["title": .string("x")])) }

        // The creator's update at the rev it got still lands; undoing it keeps the live page title.
        try board.update(page.id, rev: 1, frame: Frame(x: 900, y: 0, w: 390, h: 844), caller: agent.id)
        try board.writeBookkeeping(page.id, props: .object(["pageTitle": .string("GUI · cart")]))
        #expect(board.undo())
        let undone = try board.object(page.id)
        #expect(undone.frame.h == 800 && undone.props["pageTitle"]?.string == "GUI · cart" && undone.props["title"]?.string == "/gui at phone width (390)")
        #expect(board.redo())
        #expect(try board.object(page.id).props["pageTitle"]?.string == "GUI · cart")
    }

    @Test func aNewChangeAfterUndoDropsTheRedoBranch() throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("a")]))
        try board.update(note.id, props: .object(["markdown": .string("b")]))
        board.undo()
        #expect(board.history.canRedo)
        try board.update(note.id, props: .object(["markdown": .string("c")]))
        #expect(!board.history.canRedo)
        #expect(!board.redo())
    }

    @Test func zOrderChangesAreUndoable() throws {
        let board = makeBoard()
        let back = board.create(type: .note, props: .object([:]))
        let front = board.create(type: .note, props: .object([:]))
        try board.update(back.id, z: front.z + 1)
        board.undo()
        #expect(try board.object(back.id).z < board.object(front.id).z)
    }

    @Test func recreatedObjectsNeverReuseARevision() throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("v1")]))
        try board.update(note.id, props: .object(["markdown": .string("v2")]))
        board.undo()
        var highest = try board.object(note.id).rev
        #expect(highest == 3)

        // Undo the create, then redo it, several times: each incarnation is newer than the last.
        for _ in 0..<3 {
            board.undo()
            #expect(board.objects[note.id] == nil)
            board.redo()
            let rev = try board.object(note.id).rev
            #expect(rev > highest)
            highest = rev
        }
        #expect(throws: BoardError.self, "a writer still holding rev 2 must conflict") {
            try board.update(note.id, rev: 2, props: .object(["markdown": .string("stale")]))
        }
    }

    @Test func undoingATerminalsCreationKeepsItsLatestBookkeepingForRedo() throws {
        let board = makeBoard()
        let agent = terminal(on: board)
        try board.reportSession(tile: agent.id, kind: "omp", sessionId: "s-42", sessionPath: "/tmp/s-42.jsonl")
        try board.reportLifecycle(tile: agent.id, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        try board.update(agent.id, props: .object(["title": .string("omp: refactor")]), caller: agent.id)

        board.undo()
        #expect(board.objects[agent.id] == nil)
        board.redo()
        let back = try board.object(agent.id)
        #expect(back.props["agent"]?["sessionId"]?.string == "s-42", "resume metadata survives undo/redo")
        #expect(back.props["lifecycle"]?["state"]?.string == "working")
        #expect(back.props["title"]?.string == "omp: refactor")

        // Same for redoing a delete after the restored terminal reports again.
        try board.delete(agent.id)
        board.undo()
        try board.reportSession(tile: agent.id, kind: "omp", sessionId: "s-43", sessionPath: nil)
        board.redo()
        board.undo()
        #expect(try board.object(agent.id).props["agent"]?["sessionId"]?.string == "s-43")
    }

    @Test func historyIsBounded() throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["n": .number(0)]))
        for n in 1...(board.history.limit + 20) {
            try board.update(note.id, props: .object(["n": .number(Double(n))]))
        }
        var undone = 0
        while board.undo() { undone += 1 }
        #expect(undone == board.history.limit)
        #expect(board.objects[note.id] != nil, "the oldest steps (including the create) fell off the end")
    }
}

struct LassoTests {
    /// A "U" shape: two prongs joined at the bottom, open at the top middle.
    let horseshoe = Lasso(points: [(0, 0), (100, 0), (100, 100), (200, 100), (200, 0), (300, 0), (300, 300), (0, 300)])

    @Test func selectsOnlyFramesWhollyInside() {
        #expect(horseshoe.contains(Frame(x: 10, y: 10, w: 50, h: 50)))
        #expect(horseshoe.contains(Frame(x: 20, y: 150, w: 260, h: 100)))
        #expect(!horseshoe.contains(Frame(x: -10, y: 10, w: 50, h: 50)), "overlapping the outline is not enough")
        #expect(!horseshoe.contains(Frame(x: 400, y: 400, w: 10, h: 10)))
    }

    @Test func concaveNotchBetweenCornersRejectsTheFrame() {
        // All four corners are inside the U, but the notch cuts through the middle.
        #expect(!horseshoe.contains(Frame(x: 50, y: 50, w: 200, h: 100)))
    }

    @Test func degenerateLassoSelectsNothing() {
        #expect(!Lasso(points: [(0, 0), (100, 100)]).contains(Frame(x: 10, y: 10, w: 1, h: 1)))
    }
}
