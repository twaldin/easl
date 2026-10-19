import Foundation
import Testing
import CanvasCore

/// `board.history`: the activity log agents read to learn what happened on the board.
@MainActor
struct ActivityTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-activity-\(UUID().uuidString)")

    func makeBoard() -> Board {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Board(id: "brd_test", root: root)
    }

    /// A clock the test advances by hand.
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    func viewport(_ x: Double, zoom: Double = 1) -> Viewport {
        Viewport(rect: Frame(x: x, y: 0, w: 1200, h: 800), zoom: zoom)
    }

    @Test func changesAreLoggedInOrderWithTheirActor() throws {
        let board = makeBoard()
        let agent = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]))
        let note = board.create(type: .note, props: .object(["markdown": .string("# Plan\nsteps")]), frame: Frame(x: 10, y: 20, w: 280, h: 240), caller: agent.id)
        try board.update(note.id, frame: Frame(x: 50, y: 20, w: 280, h: 240))
        try board.delete(note.id, caller: agent.id)

        let entries = board.activity.query(since: nil, limit: 100).entries
        #expect(entries.map(\.kind) == [.created, .created, .updated, .deleted])
        #expect(entries.map(\.seq) == [1, 2, 3, 4])
        #expect(entries.map(\.actor) == [.user, .agent(agent.id), .user, .agent(agent.id)])
        #expect(entries[1].summary == "created note \"# Plan\" at (10, 20) 280×240")
        #expect(entries[2].summary.contains("moved (10, 20) → (50, 20)"))
        #expect(entries[3].id == note.id && entries[3].type == .note)
        #expect(entries.last?.rev == board.revision)
    }

    @Test func objectsThatExistedForSecondsStayInTheLog() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]))
        try board.delete(terminal.id)
        #expect(board.objects[terminal.id] == nil)
        let entries = board.activity.query(since: nil, limit: 100).entries.filter { $0.id == terminal.id }
        #expect(entries.map(\.kind) == [.created, .deleted])
    }

    @Test func sinceReturnsOnlyNewerEntries() throws {
        let clock = Clock()
        let log = ActivityLog(clock: { clock.now })
        log.record(.created, actor: .user, rev: 1, id: "obj_a", summary: "a")
        clock.advance(5)
        let middle = clock.now
        log.record(.created, actor: .user, rev: 2, id: "obj_b", summary: "b")
        clock.advance(5)
        log.record(.deleted, actor: .user, rev: 3, id: "obj_a", summary: "a gone")

        let cursor = log.query(since: .seq(2), limit: 100)
        #expect(cursor.entries.map(\.summary) == ["a gone"])
        #expect(cursor.cursor == 3 && !cursor.truncated && !cursor.restarted)
        #expect(log.query(since: .seq(3), limit: 100).entries.isEmpty)
        #expect(log.query(since: .time(middle), limit: 100).entries.map(\.summary) == ["a gone"])
        #expect(log.query(since: nil, limit: 100, kinds: [.deleted]).entries.map(\.summary) == ["a gone"])

        let limited = log.query(since: nil, limit: 2)
        #expect(limited.entries.map(\.summary) == ["b", "a gone"], "a limit keeps the newest entries")
        #expect(limited.truncated)
    }

    @Test func viewportIsLoggedOnceTheViewSettles() {
        let clock = Clock()
        let log = ActivityLog(clock: { clock.now })
        // A pan: many positions in quick succession.
        for x in stride(from: 0.0, through: 900, by: 100) {
            log.viewportChanged(viewport(x), actor: .user, rev: 7)
            clock.advance(0.05)
        }
        #expect(log.query(since: nil, limit: 100).entries.isEmpty, "still moving")
        clock.advance(ActivityLog.settleInterval)
        let settled = log.query(since: nil, limit: 100).entries
        #expect(settled.count == 1)
        #expect(settled.first?.kind == .viewport)
        #expect(settled.first?.viewport == viewport(900), "the resting place, not the path")
        #expect(settled.first?.rev == 7)

        // Coming back to rest at the same place isn't news.
        log.viewportChanged(viewport(900.4), actor: .user, rev: 7)
        clock.advance(ActivityLog.settleInterval)
        #expect(log.query(since: .seq(1), limit: 100).entries.isEmpty)

        log.viewportChanged(viewport(900, zoom: 0.5), actor: .user, rev: 7)
        clock.advance(ActivityLog.settleInterval)
        #expect(log.query(since: .seq(1), limit: 100).entries.map(\.viewport) == [viewport(900, zoom: 0.5)])
    }

    @Test func settledViewportIsOrderedBeforeLaterChanges() {
        let clock = Clock()
        let log = ActivityLog(clock: { clock.now })
        log.viewportChanged(viewport(100), actor: .user, rev: 1)
        clock.advance(ActivityLog.settleInterval + 1)
        log.record(.created, actor: .user, rev: 2, id: "obj_a", summary: "a")
        #expect(log.query(since: nil, limit: 100).entries.map(\.kind) == [.viewport, .created])
    }

    @Test func selectionIsLoggedWhenItSettles() {
        let clock = Clock()
        let log = ActivityLog(clock: { clock.now })
        log.selectionChanged(["obj_b"], actor: .user, rev: 1)
        log.selectionChanged(["obj_b", "obj_a"], actor: .user, rev: 1)
        clock.advance(ActivityLog.settleInterval)
        let entries = log.query(since: nil, limit: 100).entries
        #expect(entries.map(\.selection) == [["obj_a", "obj_b"]])
        log.selectionChanged([], actor: .user, rev: 1)
        clock.advance(ActivityLog.settleInterval)
        #expect(log.query(since: .seq(1), limit: 100).entries.map(\.summary) == ["selection cleared"])
    }

    @Test func theLogKeepsOnlyTheNewestEntries() {
        let log = ActivityLog(capacity: 5)
        for index in 1...8 { log.record(.created, actor: .user, rev: index, summary: "\(index)") }
        #expect(log.count == 5)
        #expect(log.entries.map(\.seq) == [4, 5, 6, 7, 8])
        let behind = log.query(since: .seq(1), limit: 100)
        #expect(behind.entries.map(\.seq) == [4, 5, 6, 7, 8])
        #expect(behind.truncated, "entries 2 and 3 were dropped before the caller saw them")
        #expect(!log.query(since: .seq(3), limit: 100).truncated)
    }

    @Test func appStartIsMarkedAndAnOldCursorReportsTheRestart() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards")))
        let board = await registry.open(root: dir.appendingPathComponent("root"))
        board.create(type: .note, props: .object(["markdown": .string("x")]))

        let first = board.activity.query(since: nil, limit: 100).entries.first
        #expect(first?.kind == .restart)
        #expect(first?.actor == .system)
        // A cursor from before the restart is newer than anything this log issued.
        let stale = board.activity.query(since: .seq(500), limit: 100)
        #expect(stale.restarted)
        #expect(stale.entries.map(\.kind) == [.restart, .created])
    }

    @Test func bookkeepingIsNotLoggedButFollowReaimsAre() throws {
        let board = makeBoard()
        FileManager.default.createFile(atPath: root.appendingPathComponent("a.swift").path, contents: Data("let a = 1\n".utf8))
        let agent = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]))
        let before = board.activity.cursor
        try board.reportLifecycle(tile: agent.id, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        try board.reportSession(tile: agent.id, kind: "omp", sessionId: "s1", sessionPath: nil)
        #expect(board.activity.cursor == before, "lifecycle and session reports are terminal bookkeeping")

        let follow = try #require(try board.follow(tile: agent.id, path: "a.swift", range: LineRange(start: 1, end: 1), action: "read"))
        try board.follow(tile: agent.id, path: "a.swift", range: nil, action: "edit")
        let entries = board.activity.query(since: .seq(before), limit: 100).entries
        #expect(entries.map(\.kind) == [.follow, .follow], "one entry per re-aim, not the create/update underneath")
        #expect(entries.allSatisfy { $0.actor == .agent(agent.id) && $0.id == follow.id })
        #expect(entries.map(\.summary) == ["follow tile created at a.swift:1-1 (read)", "follow tile re-aimed at a.swift (edit)"])
    }

    @Test func undoIsCreditedToTheUser() throws {
        let board = makeBoard()
        let agent = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]))
        let shape = board.create(type: .shape, props: .object(["kind": .string("rect")]), frame: Frame(x: 0, y: 0, w: 10, h: 10), caller: agent.id)
        let before = board.activity.cursor
        #expect(board.undo())
        let entries = board.activity.query(since: .seq(before), limit: 100).entries
        #expect(entries.map(\.kind) == [.deleted])
        #expect(entries.first?.actor == .user)
        #expect(entries.first?.id == shape.id)
        #expect(entries.first?.summary.hasPrefix("undo: deleted shape rect") == true)
    }

    /// B5: an agent's batch deletes tiles that arrows point at and that a group holds. The arrow
    /// rewrites and the group re-fit are the agent's doing, not the user's, and each object
    /// gets one entry for the revision however many of the batch's ops touched it.
    @Test func cascadesOfABatchAreCreditedToItsActorOncePerObject() throws {
        let board = makeBoard()
        let agent = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]), frame: Frame(x: 5000, y: 5000, w: 800, h: 500))
        func note(_ x: Double, _ y: Double) -> CanvasObject {
            board.create(type: .note, props: .object(["markdown": .string("n")]), frame: Frame(x: x, y: y, w: 200, h: 100), caller: agent.id)
        }
        func arrow(_ from: CanvasObject, _ to: CanvasObject) -> CanvasObject {
            board.create(type: .arrow, props: .object(["from": .object(["object": .string(from.id)]), "to": .object(["object": .string(to.id)])]), caller: agent.id)
        }
        let a = note(0, 0), b = note(300, 0), d = note(600, 0), c = note(0, 400)
        let lane = board.create(type: .group, props: .object(["members": .array([.string(a.id), .string(b.id), .string(d.id)])]), caller: agent.id)
        let toC = arrow(a, c), between = arrow(a, b)
        let before = board.activity.cursor

        try board.atomically {
            try board.delete(a.id, caller: agent.id)
            try board.delete(b.id, caller: agent.id)
        }
        let entries = board.activity.query(since: .seq(before), limit: 100).entries
        #expect(entries.allSatisfy { $0.actor == .agent(agent.id) && $0.rev == board.revision }, "\(entries.map { "\($0.actor.name) \($0.summary)" })")
        #expect(entries.filter { $0.kind == .deleted }.compactMap(\.id) == [a.id, b.id])
        let updates = entries.filter { $0.kind == .updated }
        #expect(updates.compactMap(\.id).sorted() == [toC.id, between.id, lane.id].sorted(), "one entry each, though `between` lost both ends and the lane two members")
        #expect(updates.first { $0.id == between.id }?.cause == "bound object \(a.id) deleted")
        let refit = try #require(updates.first { $0.id == lane.id })
        #expect(refit.cause == GroupSpec.refitCause)
        #expect(refit.summary.hasSuffix("moved (-24, -56) → (576, -56); resized 848×180 → 248×180"), "the net change: \(refit.summary)")

        #expect(board.undo())
        #expect(try board.object(lane.id).frame == lane.frame)
        #expect(try board.object(between.id).props == between.props)
    }

    /// Moving a lane moves its members one by one; the lane is logged once, at its net move.
    @Test func aMovedGroupIsLoggedOnceAtItsNetChange() throws {
        let board = makeBoard()
        let agent = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]), frame: Frame(x: 5000, y: 5000, w: 800, h: 500))
        let members = (0..<3).map { board.create(type: .note, props: .object(["markdown": .string("n")]), frame: Frame(x: Double($0) * 300, y: 0, w: 200, h: 100)) }
        let lane = board.create(type: .group, props: .object(["members": .array(members.map { .string($0.id) })]))
        let before = board.activity.cursor
        try board.stack([lane.id], direction: .row, origin: CGPoint(x: -24, y: 944), caller: agent.id)
        let laneEntries = board.activity.query(since: .seq(before), limit: 100).entries.filter { $0.id == lane.id }
        #expect(laneEntries.count == 1)
        #expect(laneEntries.first?.summary == "group (3 members): moved (-24, -56) → (-24, 944)")
        #expect(laneEntries.first?.actor == .agent(agent.id))
    }
}
