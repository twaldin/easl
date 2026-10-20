import Foundation
import Testing
@testable import CanvasCore

extension ApiRouterTests {
    @Test(arguments: ["unknown", "newer", "truncated"])
    func unreadableBoardNeverOpensOrOverwritesItsFile(_ kind: String) async throws {
        let root = dir.appendingPathComponent(kind)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = BoardStore.pathID(root)
        let file = registry.store.url(for: id)
        let original: Data
        if kind == "truncated" {
            original = Data(#"{"format":3,"objects":["#.utf8)
        } else {
            let stored = Board(id: id, root: root)
            _ = stored.create(type: .note, props: .object(["markdown": "must survive"]))
            var json = try JSONValue.encode(stored.snapshot)
            if kind == "newer" {
                json = json.merging(.object(["format": 99]))
            } else {
                var objects = try #require(json["objects"]?.array)
                objects[0] = objects[0].merging(.object(["type": "hologram"]))
                json = json.merging(.object(["objects": .array(objects)]))
            }
            original = try JSONEncoder().encode(json)
        }
        try original.write(to: file)
        let client = try connect()
        let opened = try await call(client, "board.open", ["root": .string(root.path)])
        #expect(opened["error"]?["code"] == "unavailable")
        #expect(opened["error"]?["message"]?.string?.contains(file.path) == true)
        #expect(registry.boards[id] == nil)
        if let accidentallyOpened = registry.boards[id] {
            registry.store.save(accidentallyOpened)
        }
        _ = try await call(client, "board.close", ["board": .string(id)])
        registry.store.flush(Array(registry.boards.values))
        #expect(try Data(contentsOf: file) == original)
    }
}
