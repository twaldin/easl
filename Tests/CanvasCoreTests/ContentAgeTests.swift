import Foundation
import Testing
@testable import CanvasCore

@MainActor
struct ContentAgeTests {
    private let now = Date()
    private let root = URL(fileURLWithPath: "/tmp/content-age-\(UUID().uuidString)")

    private func aged(_ board: Board) throws -> Board {
        var fields = try #require(JSONValue.encode(board.snapshot).object)
        fields["objects"] = .array(try board.snapshot.objects.map { object in
            var entry = try #require(JSONValue.encode(object).object)
            entry["createdAt"] = .number(now.addingTimeInterval(-30 * 86400).timeIntervalSinceReferenceDate)
            entry["updatedAt"] = .number(now.addingTimeInterval(-8 * 86400).timeIntervalSinceReferenceDate)
            entry.removeValue(forKey: "contentUpdatedAt")
            entry.removeValue(forKey: "contentRev")
            return .object(entry)
        })
        return Board(snapshot: try JSONValue.object(fields).decode(BoardSnapshot.self))
    }

    private func untouched(_ board: Board) -> Set<String> {
        Set((board.staleObjects(now: now)["objects"]?.array ?? []).compactMap { entry in
            entry["reasons"]?.array?.contains("untouched") == true ? entry["id"]?.string : nil
        })
    }

    @Test func staleContentSurvivesMoveResizeAndPersistenceUntilMarkdownEdit() async throws {
        let initial = Board(id: BoardStore.boardID(for: root), root: root)
        let note = initial.create(type: .note, props: .object(["markdown": "old content"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let board = try aged(initial)
        let old = try board.object(note.id)
        #expect(untouched(board) == [note.id])
        let moved = try board.update(note.id, frame: Frame(x: 500, y: 300, w: 200, h: 100))
        #expect(moved.updatedAt > old.updatedAt)
        #expect(untouched(board) == [note.id])
        let resized = try board.update(note.id, frame: Frame(x: 500, y: 300, w: 400, h: 250))
        #expect(resized.updatedAt >= moved.updatedAt)
        #expect(untouched(board) == [note.id])
        let entry = try #require(board.staleObjects(now: now)["objects"]?.array?.first)
        #expect(entry["updatedAt"] == .number(resized.updatedAt.timeIntervalSinceReferenceDate))
        let store = BoardStore(directory: root.appendingPathComponent("boards"))
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await store.saveChecked(board)
        let reloaded = try await store.load(root: root)
        #expect(reloaded.snapshot.format == 3)
        #expect(untouched(reloaded) == [note.id])
        #expect(reloaded.staleObjects(now: now)["objects"]?.array?.first?["reasons"] == entry["reasons"])
        _ = try reloaded.update(note.id, props: .object(["markdown": "new content"]))
        #expect(untouched(reloaded).isEmpty)
    }

    @Test func staleGroupSurvivesMemberMotionAndMembershipOnlyChanges() throws {
        let initial = Board(id: "brd_group_age", root: root)
        let a = initial.create(type: .note, props: .object(["markdown": "a"]))
        let b = initial.create(type: .note, props: .object(["markdown": "b"]))
        let group = initial.create(type: .group, props: .object(["title": "old group", "members": .array([.string(a.id)])]))
        let board = try aged(initial)
        let oldGroup = try board.object(group.id)
        _ = try board.update(a.id, frame: Frame(x: 1500, y: 1000, w: 200, h: 100))
        #expect(try board.object(group.id).updatedAt > oldGroup.updatedAt)
        #expect(untouched(board) == [a.id, b.id, group.id])
        _ = try board.update(group.id, props: .object(["members": .array([.string(a.id), .string(b.id)])]))
        #expect(untouched(board) == [a.id, b.id, group.id])
        #expect(board.undo())
        #expect(untouched(board) == [a.id, b.id, group.id])
        _ = try board.update(group.id, props: .object(["title": "new title"]))
        #expect(untouched(board) == [a.id, b.id])
    }

    @Test func legacyFallbackUsesUpdatedAtAndNoOpDoesNotRefreshContent() throws {
        let initial = Board(id: "brd_legacy_age", root: root)
        let note = initial.create(type: .note, props: .object(["markdown": "same"]))
        let board = try aged(initial)
        _ = try board.update(note.id, props: .object(["markdown": "same", "absent": .null]))
        #expect(untouched(board) == [note.id])
        #expect(board.undo() == false)
        _ = try board.update(note.id, z: 20, expires: .set(ObjectExpiry(now.addingTimeInterval(86400))))
        #expect(untouched(board) == [note.id])
        #expect(board.undo())
        #expect(untouched(board) == [note.id])
        var snapshot = board.snapshot
        var recentObject = try #require(JSONValue.encode(snapshot.objects[0]).object)
        recentObject.removeValue(forKey: "contentUpdatedAt")
        recentObject.removeValue(forKey: "contentRev")
        recentObject["updatedAt"] = .number(now.timeIntervalSinceReferenceDate)
        snapshot.objects[0] = try JSONValue.object(recentObject).decode(CanvasObject.self)
        let recent = Board(snapshot: snapshot)
        #expect(untouched(recent).isEmpty)
    }

    @Test func staleLayoutUndoStaysOldButContentUndoAndRedoAreFresh() throws {
        let initial = Board(id: "brd_undo_age", root: root)
        let note = initial.create(type: .note, props: .object(["markdown": "old"]))
        let board = try aged(initial)
        _ = try board.update(note.id, frame: Frame(x: 20, y: 30, w: 400, h: 200))
        #expect(board.undo())
        #expect(untouched(board) == [note.id])
        #expect(board.redo())
        #expect(untouched(board) == [note.id])
        _ = try board.update(note.id, props: .object(["markdown": "new"]))
        #expect(untouched(board).isEmpty)
        #expect(board.undo())
        #expect(try board.object(note.id).props["markdown"] == "old")
        #expect(untouched(board).isEmpty)
        #expect(board.redo())
        #expect(untouched(board).isEmpty)
    }

    @Test func failedBatchRestoresContentAgeWithoutRewindingUpdatedAt() throws {
        let initial = Board(id: "brd_rollback_age", root: root)
        let note = initial.create(type: .note, props: .object(["markdown": "old"]))
        let board = try aged(initial)
        let before = try board.object(note.id)
        do {
            try board.atomically {
                _ = try board.update(note.id, props: .object(["markdown": "aborted"]))
                throw BoardError.invalidParams("abort")
            }
            Issue.record("batch should fail")
        } catch BoardError.invalidParams { }
        #expect(try board.object(note.id).props == before.props)
        #expect(try board.object(note.id).updatedAt > before.updatedAt)
        #expect(untouched(board) == [note.id])
    }

    @Test func normalPropWritesRefreshAgeButArrowRoutingDoesNot() throws {
        let initial = Board(id: "brd_boundaries_age", root: root)
        let terminal = initial.create(type: .terminal, props: .object([:]))
        let browser = initial.create(type: .browser, props: .object(["url": "https://example.com"]))
        let follow = initial.create(type: .code, props: .object(["followOf": .string(terminal.id), "path": "a.swift"]))
        let diagram = initial.create(type: .diagram, props: .object([:]))
        let left = initial.create(type: .shape, props: .object(["kind": "rect"]), frame: Frame(x: 0, y: 0, w: 100, h: 100))
        let right = initial.create(type: .shape, props: .object(["kind": "rect"]), frame: Frame(x: 300, y: 0, w: 100, h: 100))
        let arrow = initial.create(type: .arrow, props: ArrowSpec(from: .object(left.id), to: .object(right.id)).props)
        let board = try aged(initial)
        let all = Set(initial.objects.keys)
        let unchanged = all.subtracting([terminal.id, browser.id, follow.id, diagram.id])
        _ = try board.update(terminal.id, props: .object(["title": "reported", "agent": .object(["kind": "codex"]), "lifecycle": .object(["state": "idle"])]))
        _ = try board.update(browser.id, props: .object(["pageTitle": "reported"]))
        _ = try board.update(follow.id, props: .object(["path": "b.swift", "range": .object(["start": 2, "end": 3]), "lastAction": "read", "lastChanges": .array([]), "history": .array([])]))
        _ = try board.update(diagram.id, props: .object(["graph": .object(["nodes": .array([])])]))
        let beforeArrow = try board.object(arrow.id)
        _ = try board.update(left.id, frame: Frame(x: 50, y: 150, w: 200, h: 150))
        _ = board.reported(try board.object(arrow.id))
        #expect(try board.object(arrow.id).props == beforeArrow.props)
        #expect(untouched(board) == unchanged)
        try board.delete(right.id)
        #expect(ArrowSpec(try board.object(arrow.id).props)?.to.objectID == nil)
        #expect(untouched(board) == unchanged.subtracting([right.id, arrow.id]))
        #expect(board.undo())
        #expect(ArrowSpec(try board.object(arrow.id).props)?.to.objectID == right.id)
        #expect(!untouched(board).contains(arrow.id))
    }

    @Test(arguments: ["point", "endpoint", "label", "style"])
    func arrowCoordinatesAreGeometryButBindingsLabelsAndStyleAreContent(edit: String) throws {
        let initial = Board(id: "brd_arrow_age", root: root)
        let arrow = initial.create(type: .arrow, props: ArrowSpec(from: .point(CGPoint(x: 0, y: 0)), to: .point(CGPoint(x: 300, y: 100))).props)
        let target = initial.create(type: .shape, props: .object(["kind": "rect"]))
        let board = try aged(initial)
        _ = try board.translate([arrow.id], dx: 50, dy: 25)
        #expect(untouched(board).contains(arrow.id))
        let patch: JSONValue = switch edit {
        case "point": .object(["to": ArrowBinding.point(CGPoint(x: 400, y: 200)).json])
        case "endpoint": .object(["to": ArrowBinding.object(target.id).json])
        case "label": .object(["label": "authored"])
        default: .object(["color": "red"])
        }
        _ = try board.update(arrow.id, props: patch)
        #expect(untouched(board).contains(arrow.id) == (edit == "point"))
    }

}
