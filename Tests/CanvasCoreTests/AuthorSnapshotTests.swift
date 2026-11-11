import Foundation
import Testing
@testable import CanvasCore

@MainActor
struct AuthorSnapshotTests {
    @Test func creationCapturesNamePrecedenceAndNeverTheLiveTitle() throws {
        let board = Board(id: "brd_author", root: URL(fileURLWithPath: "/tmp"))
        let terminal = board.create(type: .terminal, props: .object(["name": "  Named  ", "title": "Title", "agent": .object(["kind": "omp"])]))
        board.authorProgram = { _ in "cargo test" }
        board.terminalLabel = { _ in "spinner frame" }
        #expect(terminal.authorName == "you")
        for type in ObjectType.allCases {
            #expect(board.create(type: type, props: .object([:]), caller: terminal.id).authorName == "Named")
        }
        _ = try board.update(terminal.id, props: .object(["name": .null]))
        #expect(board.create(type: .note, props: .object([:]), caller: terminal.id).authorName == "cargo test")
        board.authorProgram = nil
        #expect(board.create(type: .note, props: .object([:]), caller: terminal.id).authorName == "Title")
        _ = try board.update(terminal.id, props: .object(["title": .null]))
        #expect(board.create(type: .note, props: .object([:]), caller: terminal.id).authorName == "omp")
        _ = try board.update(terminal.id, props: .object(["agent": .null]))
        #expect(board.create(type: .note, props: .object([:]), caller: terminal.id).authorName == "Terminal")
    }

    @Test func crossBoardCreationAndLegacyRoundTripDoNotBackfill() async throws {
        let root = URL(fileURLWithPath: "/tmp/author-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRoot = root.appendingPathComponent("first")
        let secondRoot = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let store = BoardStore(directory: root.appendingPathComponent("boards"))
        let registry = BoardRegistry(store: store)
        let first = try await registry.open(root: firstRoot)
        let second = try await registry.open(root: secondRoot)
        let terminal = first.create(type: .terminal, props: .object(["name": "Captured"]))
        let output = second.create(type: .note, props: .object([:]), caller: terminal.id)
        #expect(output.authorName == "Captured")
        #expect(JSONValue(output)["authorName"] == "Captured")
        _ = try first.update(terminal.id, props: .object(["name": "Renamed"]))
        try first.delete(terminal.id)
        _ = try second.update(output.id, props: .object(["markdown": "edited"]))
        try await store.saveChecked(second)
        let reloaded = try await store.load(root: secondRoot)
        #expect(reloaded.objects[output.id]?.authorName == "Captured")
        var snapshot = reloaded.snapshot
        snapshot.objects[0].authorName = nil
        let legacy = Board(snapshot: try JSONDecoder().decode(BoardSnapshot.self, from: JSONEncoder().encode(snapshot)))
        #expect(legacy.objects[output.id]?.authorName == nil)
        #expect(JSONValue(try legacy.object(output.id))["authorName"] == nil)
        _ = try legacy.update(output.id, props: .object(["markdown": "still legacy"]))
        try await store.saveChecked(legacy)
        #expect(try await store.load(root: secondRoot).objects[output.id]?.authorName == nil)
    }
}
