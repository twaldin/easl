import Foundation
import Testing
@testable import CanvasCore

@MainActor
struct ContentAgePersistenceTests {
    private let now = Date()
    private let root = URL(fileURLWithPath: "/tmp/content-marker-\(UUID().uuidString)")

    private func storedBoard(marker: String, type: ObjectType = .note) async throws -> (BoardStore, Board, ObjectID) {
        let store = BoardStore(directory: root.appendingPathComponent("boards"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let initial = Board(id: BoardStore.boardID(for: root), root: root)
        let object = initial.create(type: type, props: .object([:]))
        var snapshot = initial.snapshot
        snapshot.objects[0].rev = 7
        snapshot.objects[0].updatedAt = now
        snapshot.objects[0].contentUpdatedAt = now.addingTimeInterval(-8 * 86400)
        snapshot.objects[0].contentRev = 7
        switch marker {
        case "missing": snapshot.objects[0].contentRev = nil
        case "zero": snapshot.objects[0].contentRev = 0
        case "negative": snapshot.objects[0].contentRev = -1
        case "mismatched": snapshot.objects[0].contentRev = 6
        case "missing-time": snapshot.objects[0].contentUpdatedAt = nil
        case "legacy":
            snapshot.objects[0].contentUpdatedAt = nil
            snapshot.objects[0].contentRev = nil
        default: break
        }
        var file = try #require(JSONDecoder().decode(JSONValue.self, from: BoardStore.encoder.encode(snapshot)).object)
        if marker == "null" {
            var entry = try #require(file["objects"]?.array?.first?.object)
            entry["contentRev"] = .null
            file["objects"] = .array([.object(entry)])
        }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(JSONValue.object(file)).write(to: store.url(for: initial.id), options: .atomic)
        return (store, try await store.load(root: root), object.id)
    }

    private func untouched(_ board: Board) -> Set<ObjectID> {
        Set((board.staleObjects(now: now)["objects"]?.array ?? []).compactMap { entry in
            entry["reasons"]?.array?.contains("untouched") == true ? entry["id"]?.string : nil
        })
    }

    @Test(arguments: ["matching", "missing", "null", "zero", "negative", "mismatched", "missing-time", "legacy"])
    func storedContentAgeRequiresMatchingRevisionAndTimestamp(marker: String) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, board, id) = try await storedBoard(marker: marker)
        let expected: Set<ObjectID> = marker == "matching" ? [id] : []
        #expect(untouched(board) == expected)
        _ = try board.update(id, frame: Frame(x: 800, y: 500, w: 300, h: 200))
        #expect(untouched(board) == expected)
        try store.saveChecked(board)
        let reloaded = try await store.load(root: root)
        #expect(reloaded.snapshot.format == 3)
        #expect(untouched(reloaded) == expected)
    }

    @Test(arguments: ["matching", "missing", "mismatched"])
    func rollbackAndDeletedObjectRecreationPreserveEffectiveAgeAcrossReload(marker: String) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, board, id) = try await storedBoard(marker: marker)
        let expected: Set<ObjectID> = marker == "matching" ? [id] : []
        do {
            try board.atomically {
                _ = try board.update(id, props: .object(["markdown": "aborted"]))
                throw BoardError.invalidParams("abort")
            }
            Issue.record("batch should fail")
        } catch BoardError.invalidParams { }
        #expect(try board.object(id).props["markdown"] == nil)
        #expect(untouched(board) == expected)
        try board.delete(id)
        #expect(board.undo())
        #expect(untouched(board) == expected)
        try store.saveChecked(board)
        let reloaded = try await store.load(root: root)
        #expect(untouched(reloaded) == expected)
    }

    @Test(arguments: ["name", "command"])
    func terminalBookkeepingPreservesAgeButAuthoredNameAndCommandRefreshIt(prop: String) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, board, id) = try await storedBoard(marker: "matching", type: .terminal)
        let revision = try board.object(id).rev
        try board.writeBookkeeping(id, props: .object(["title": "reported title"]))
        #expect(try board.object(id).rev == revision)
        try store.saveChecked(board)
        let reloaded = try await store.load(root: root)
        #expect(untouched(reloaded) == [id])
        let value: JSONValue = prop == "command" ? .array(["/bin/sh"]) : "authored"
        _ = try reloaded.update(id, props: .object([prop: value]))
        #expect(untouched(reloaded).isEmpty)
    }
}
