import Foundation
import Testing
@testable import CanvasCore

@MainActor
struct BoardStackingMigrationTests {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-stacking-\(UUID().uuidString)")

    func snapshot(format: Int?, root: URL) -> BoardSnapshot {
        let at = Date(timeIntervalSince1970: 1_760_000_000)
        func object(_ id: String, _ type: ObjectType, _ z: Double, _ props: JSONValue) -> CanvasObject {
            CanvasObject(id: id, type: type, frame: Frame(x: 0, y: 0, w: 200, h: 100), z: z, rev: 7,
                         createdBy: .user, createdAt: at, props: props)
        }
        return BoardSnapshot(format: format, id: "brd_stacking", root: root.path, revision: 19, objects: [
            object("obj_tile_z", .browser, 500, .object(["url": "https://example.com"])),
            object("obj_shape_b", .shape, -40, .object(["kind": "rect"])),
            object("obj_group_z", .group, 900, .object(["members": .array([])])),
            object("obj_arrow", .arrow, -10, ArrowSpec(from: .point(CGPoint(x: 0, y: 0)), to: .point(CGPoint(x: 200, y: 100))).props),
            object("obj_tile_low", .note, 200, .object(["markdown": "tile"])),
            object("obj_text", .shape, 5, .object(["kind": "text", "text": "label"])),
            object("obj_group_a", .group, 700, .object(["members": .array([])])),
            object("obj_ink_a", .shape, -40, ShapeSpec(kind: .ink, points: [InkPoint(x: 0, y: 0), InkPoint(x: 200, y: 100)]).props),
            object("obj_tile_a", .code, 500, .object(["path": "a.swift"])),
        ])
    }

    @Test func legacySavedBoardsKeepTheirVisibleTiersAndSameTierOrder() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        for format in [nil, 1, 2] as [Int?] {
            let root = directory.appendingPathComponent("format-\(format ?? 0)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = BoardStore(directory: root.appendingPathComponent("boards"))
            let original = snapshot(format: format, root: root)
            try BoardStore.encoder.encode(original).write(to: store.url(for: original.id))

            let board = store.load(root: root, id: original.id)
            let saved = board.snapshot
            #expect(saved.format == 3)
            #expect(saved.objects.map(\.id) == ["obj_group_a", "obj_group_z", "obj_tile_low", "obj_tile_a", "obj_tile_z", "obj_ink_a", "obj_shape_b", "obj_arrow", "obj_text"])
            #expect(saved.objects.map(\.z) == [1, 2, 3, 4, 5, 6, 7, 8, 9])
            #expect(board.revision == 19 && !board.history.canUndo)
            for object in original.objects {
                var expected = object
                expected.z = try board.object(object.id).z
                if (format ?? 1) < 2, RenderMath.isTile(object.type) { expected.frame.h = 126 }
                #expect(try board.object(object.id) == expected)
            }
            var reordered = original
            reordered.objects.reverse()
            #expect(Board(snapshot: reordered).objects == board.objects)

            try store.saveChecked(board)
            let onDisk = try BoardStore.decoder.decode(BoardSnapshot.self, from: Data(contentsOf: store.url(for: board.id)))
            #expect(onDisk.format == 3 && onDisk.objects == saved.objects)
            let reopened = BoardStore(directory: store.directory).load(root: root, id: board.id)
            #expect(reopened.objects == board.objects)
            #expect(reopened.revision == 19 && !reopened.history.canUndo)
        }
    }

    @Test func format3KeepsLiteralZAcrossRestackingSavingAndReopening() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = snapshot(format: 3, root: directory)
        let board = Board(snapshot: original)
        for object in original.objects { #expect(try board.object(object.id) == object) }
        #expect(board.snapshot.objects.map(\.id) == ["obj_ink_a", "obj_shape_b", "obj_arrow", "obj_text", "obj_tile_low", "obj_tile_a", "obj_tile_z", "obj_group_a", "obj_group_z"])

        try board.update("obj_tile_low", z: -100)
        let store = BoardStore(directory: directory.appendingPathComponent("boards"))
        try store.saveChecked(board)
        let reopened = BoardStore(directory: store.directory).load(root: directory, id: board.id)
        #expect(reopened.objects == board.objects)
        #expect(reopened.snapshot.objects.map(\.id) == ["obj_tile_low", "obj_ink_a", "obj_shape_b", "obj_arrow", "obj_text", "obj_tile_a", "obj_tile_z", "obj_group_a", "obj_group_z"])
        #expect(try reopened.object("obj_tile_low").z == -100)
        #expect(try reopened.object("obj_shape_b").z == -40)
        try reopened.update("obj_shape_b", z: -200)
        #expect(reopened.snapshot.objects.first?.id == "obj_shape_b")
        #expect(reopened.undo())
        #expect(try reopened.object("obj_shape_b").z == -40)
        #expect(reopened.snapshot.objects.first?.id == "obj_tile_low")
    }

    @Test func remoteHostObjectsKeepTheirLiteralZAndFrames() throws {
        let remote = Board(remote: "brd_remote", root: directory, host: nil)
        let original = snapshot(format: nil, root: directory)
        for object in original.objects { remote.applyHost(object) }
        for object in original.objects { #expect(try remote.object(object.id) == object) }
        #expect(remote.snapshot.objects.map(\.id) == ["obj_ink_a", "obj_shape_b", "obj_arrow", "obj_text", "obj_tile_low", "obj_tile_a", "obj_tile_z", "obj_group_a", "obj_group_z"])
        var updated = try remote.object("obj_tile_low")
        updated.z = -100
        updated.rev = 8
        remote.applyHost(updated)
        #expect(try remote.object("obj_tile_low") == updated)
        #expect(remote.snapshot.objects.first?.id == "obj_tile_low")
        #expect(!remote.history.canUndo)
    }
}
