import Foundation
import Testing
@testable import CanvasCore

extension ApiRouterTests {
    @Test(arguments: ["unknown", "newer", "newer-unknown", "truncated"])
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
            if kind.hasPrefix("newer") {
                json = json.merging(.object(["format": 99]))
            }
            if kind.contains("unknown") {
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
        let reason = try #require(opened["error"]?["message"]?.string)
        #expect(reason.contains(kind.hasPrefix("newer") ? "newer easl" : "unreadable"))
        #expect(registry.store.list().allSatisfy { $0.id != id })
        let copies = try unreadableCopies(of: file)
        let copy = try #require(copies.count == 1 ? copies.first : nil)
        #expect(try Data(contentsOf: copy) == original)
        let retried = try await call(client, "board.open", ["root": .string(root.path)])
        #expect(retried["error"]?["code"] == "unavailable")
        #expect(try unreadableCopies(of: file) == copies)
        if let accidentallyOpened = registry.boards[id] {
            registry.store.save(accidentallyOpened)
        }
        _ = try await call(client, "board.close", ["board": .string(id)])
        registry.store.flush(Array(registry.boards.values))
        #expect(try Data(contentsOf: file) == original)
        #expect(try Data(contentsOf: copy) == original)

        let repaired = Board(id: id, root: root)
        let kept = repaired.create(type: .note, props: .object(["markdown": "repaired board"]))
        try BoardStore.encoder.encode(repaired.snapshot).write(to: file, options: .atomic)
        let recovered = try await registry.open(root: root)
        #expect(recovered.objects[kept.id]?.props["markdown"] == "repaired board")
        try registry.close(id)
        registry.store.flush(Array(registry.boards.values))
        #expect(try Data(contentsOf: copy) == original)
        #expect(try unreadableCopies(of: file) == copies)
    }

    @Test func concurrentUnreadableOpensRefuseAndThenAllowRepair() async throws {
        let root = dir.appendingPathComponent("concurrent-unreadable")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = BoardStore.pathID(root)
        let file = registry.store.url(for: id)
        let original = Data("broken".utf8)
        try original.write(to: file)
        @MainActor func refused() async -> Bool {
            do {
                _ = try await registry.open(root: root)
                return false
            } catch is BoardFile.Unreadable {
                return true
            } catch {
                Issue.record(error)
                return false
            }
        }
        async let first = refused()
        async let second = refused()
        #expect(await first)
        #expect(await second)
        #expect(registry.boards[id] == nil)
        let copies = try unreadableCopies(of: file)
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: file) == original)
        let repaired = Board(id: id, root: root)
        try BoardStore.encoder.encode(repaired.snapshot).write(to: file, options: .atomic)
        let opened = try await registry.open(root: root)
        #expect(opened.id == id && opened.objects.isEmpty)
        #expect(try unreadableCopies(of: file) == copies)
    }

    @Test func concurrentReadersPreserveOneCompleteCopy() async throws {
        let file = registry.store.directory.appendingPathComponent("concurrent-read.json")
        let original = Data(#"{"format":3,"objects":["#.utf8)
        try original.write(to: file)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        _ = try BoardFile.read(file)
                        Issue.record("damaged board was readable")
                    } catch is BoardFile.Unreadable {
                    } catch {
                        Issue.record(error)
                    }
                }
            }
        }
        let copies = try unreadableCopies(of: file)
        let copy = try #require(copies.count == 1 ? copies.first : nil)
        #expect(try Data(contentsOf: copy) == original)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func unreadableCopyCollisionKeepsBothVersionsUnchanged() throws {
        let file = registry.store.directory.appendingPathComponent("collision.json")
        let timestamp = Date(timeIntervalSince1970: 1_234_567_890)
        let first = Data("first damaged board".utf8)
        let second = Data("second damaged board".utf8)
        try first.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
        #expect(throws: BoardFile.Unreadable.self) { _ = try BoardFile.read(file) }
        let firstCopies = try unreadableCopies(of: file)
        let originalCopy = try #require(firstCopies.count == 1 ? firstCopies.first : nil)
        try second.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
        #expect(throws: BoardFile.Unreadable.self) { _ = try BoardFile.read(file) }
        #expect(throws: BoardFile.Unreadable.self) { _ = try BoardFile.read(file) }
        let copies = try unreadableCopies(of: file)
        #expect(copies.count == 2)
        #expect(try Data(contentsOf: originalCopy) == first)
        #expect(try copies.filter { $0 != originalCopy }.map { try Data(contentsOf: $0) } == [second])
        #expect(try Data(contentsOf: file) == second)
    }

    @Test func missingBoardOpensEmptyButExistingNonfileRefuses() async throws {
        let missingRoot = dir.appendingPathComponent("missing-board")
        let missing = try await registry.open(root: missingRoot)
        #expect(missing.objects.isEmpty)
        let blockedRoot = dir.appendingPathComponent("blocked-board")
        let id = BoardStore.pathID(blockedRoot)
        let file = registry.store.url(for: id)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        await #expect(throws: BoardFile.Unreadable.self) { _ = try await registry.open(root: blockedRoot) }
        #expect(registry.boards[id] == nil)
        #expect(BoardStore.isDirectory(file.path))
    }

    private func unreadableCopies(of file: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(file.lastPathComponent + ".unreadable-") }
            .sorted { $0.path < $1.path }
    }
}
