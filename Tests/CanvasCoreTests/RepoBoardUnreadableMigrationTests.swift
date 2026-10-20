import Foundation
import Testing
@testable import CanvasCore

@MainActor
struct RepoBoardUnreadableMigrationTests {
    func corrupted(_ snapshot: BoardSnapshot, kind: String) throws -> Data {
        let bytes = try BoardStore.encoder.encode(snapshot)
        if kind == "truncated" { return Data(bytes.prefix(bytes.count / 2)) }
        var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        if kind == "newer" {
            json["format"] = 99
        } else {
            var objects = try #require(json["objects"] as? [[String: Any]])
            try #require(!objects.isEmpty)
            objects[objects.count - 1]["type"] = "future-canvas-object"
            json["objects"] = objects
        }
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    @Test(arguments: ["unknown", "newer", "truncated"], ["launch", "repository", "dry-run"])
    func unreadableCanonicalTargetBlocksEveryLegacySource(kind: String, mode: String) async throws {
        let fixture = RepoBoardTests()
        let (repo, worktree) = try await fixture.fixture()
        defer {
            try? FileManager.default.removeItem(at: repo.root)
            try? FileManager.default.removeItem(at: fixture.dir)
        }
        let common = try #require(GitWorktree.containing(repo.root.path)).commonDir
        let store = BoardStore(directory: fixture.boards)
        let main = try await fixture.legacyBoard(repo.root) { board in
            board.create(type: .note, props: .object(["markdown": "main source"]))
        }
        let feature = try await fixture.legacyBoard(worktree) { board in
            board.create(type: .note, props: .object(["markdown": "feature source"]))
        }
        let sources = try [main.id, feature.id].map { id in (store.url(for: id), try Data(contentsOf: store.url(for: id))) }
        let target = Board(id: BoardStore.repoID(commonDir: common), root: repo.root)
        target.repo = RepoRecord(commonDir: common)
        target.create(type: .note, props: .object(["markdown": "existing target"]))
        let targetURL = store.url(for: target.id)
        let bad = try corrupted(target.snapshot, kind: kind)
        try bad.write(to: targetURL)
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.boards.path).sorted()

        for _ in 0..<2 {
            let report = RepoBoardMigration.run(directory: fixture.boards, only: mode == "repository" ? common : nil, dryRun: mode == "dry-run")
            #expect(report.repos.isEmpty)
            #expect(Set(report.unresolved.map(\.board)).isSuperset(of: [main.id, feature.id]))
            #expect(try Data(contentsOf: targetURL) == bad)
            for (url, bytes) in sources { #expect(try Data(contentsOf: url) == bytes) }
            let backups = fixture.boards.appendingPathComponent(RepoBoardMigration.backupFolder)
            for source in [main, feature] {
                #expect(!FileManager.default.fileExists(atPath: backups.appendingPathComponent("\(source.id).json").path))
            }
        }
        if mode == "dry-run" {
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.boards.path).sorted() == before)
        } else {
            #expect(Set(RepoBoardMigration.pending(in: fixture.boards).unresolved).isSuperset(of: [main.id, feature.id]))
            try BoardStore.encoder.encode(target.snapshot).write(to: targetURL)
            let repaired = RepoBoardMigration.run(directory: fixture.boards)
            #expect(repaired.repos.first?.legacy.map(\.status) == ["merged", "merged"])
            let merged = try #require(try BoardFile.read(targetURL))
            #expect(Set(merged.objects.map(\.id)).isSuperset(of: main.objects.keys))
            #expect(Set(merged.objects.map(\.id)).isSuperset(of: feature.objects.keys))
        }
    }

    @Test(arguments: ["unknown", "newer", "truncated"])
    func openingRepositoryCannotOverwriteBadTargetOrMoveFolderSource(kind: String) async throws {
        let fixture = RepoBoardTests()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let (folder, source) = try await fixture.folderBoard()
        let common = try await fixture.makeRepository(folder)
        let store = BoardStore(directory: fixture.boards)
        let sourceURL = store.url(for: source.id)
        let sourceBytes = try Data(contentsOf: sourceURL)
        let ledgerURL = RepoBoardMigration.ledgerURL(fixture.boards)
        let ledgerBytes = try Data(contentsOf: ledgerURL)
        let target = Board(id: BoardStore.repoID(commonDir: common), root: folder)
        target.repo = RepoRecord(commonDir: common)
        target.create(type: .note, props: .object(["markdown": "must survive opening"]))
        let targetURL = store.url(for: target.id)
        let bad = try corrupted(target.snapshot, kind: kind)
        try bad.write(to: targetURL)
        let registry = BoardRegistry(store: store)

        do {
            _ = try await registry.open(root: folder)
            Issue.record("An unreadable repository target opened as a writable board")
        } catch {
            #expect(error is BoardFile.Unreadable)
        }
        #expect(registry.board(id: target.id) == nil)
        #expect(try Data(contentsOf: targetURL) == bad)
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
        #expect(try Data(contentsOf: ledgerURL) == ledgerBytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.boards.appendingPathComponent("\(RepoBoardMigration.backupFolder)/\(source.id).json").path))

        try BoardStore.encoder.encode(target.snapshot).write(to: targetURL)
        let reopened = try await registry.open(root: folder)
        #expect(Set(reopened.objects.keys).isSuperset(of: source.objects.keys))
        #expect(reopened.repo?.merged?.contains(source.id) == true)
    }

    @Test(arguments: ["unknown", "newer", "truncated"], [false, true])
    func unreadableSourceIsNotPartiallyMergedOrMoved(kind: String, dryRun: Bool) async throws {
        let fixture = RepoBoardTests()
        let (repo, _) = try await fixture.fixture()
        defer {
            try? FileManager.default.removeItem(at: repo.root)
            try? FileManager.default.removeItem(at: fixture.dir)
        }
        let common = try #require(GitWorktree.containing(repo.root.path)).commonDir
        let store = BoardStore(directory: fixture.boards)
        let source = try await fixture.legacyBoard(repo.root) { board in
            board.create(type: .terminal, props: .object(["name": "not partially recoverable"]))
            board.create(type: .note, props: .object(["markdown": "unrecognized later object"]))
        }
        let sourceURL = store.url(for: source.id)
        let bad = try corrupted(source.snapshot, kind: kind)
        try bad.write(to: sourceURL)
        let target = Board(id: BoardStore.repoID(commonDir: common), root: repo.root)
        target.repo = RepoRecord(commonDir: common)
        target.create(type: .note, props: .object(["markdown": "existing board"]))
        store.save(target)
        let targetURL = store.url(for: target.id)
        let targetBytes = try Data(contentsOf: targetURL)
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.boards.path).sorted()

        let report = RepoBoardMigration.run(directory: fixture.boards, dryRun: dryRun)
        #expect(report.repos.isEmpty)
        #expect(report.unresolved.map(\.board).contains(source.id))
        #expect(try Data(contentsOf: sourceURL) == bad)
        #expect(try Data(contentsOf: targetURL) == targetBytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.boards.appendingPathComponent("\(RepoBoardMigration.backupFolder)/\(source.id).json").path))
        if dryRun {
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.boards.path).sorted() == before)
        } else {
            let opened = try await BoardRegistry(store: store).open(root: repo.root)
            #expect(Set(opened.objects.keys) == Set(target.objects.keys))
            #expect(try Data(contentsOf: sourceURL) == bad)
            #expect(try Data(contentsOf: targetURL) == targetBytes)
        }
    }

    @Test(arguments: ["unknown", "newer", "truncated"])
    func closedTerminalInspectionSkipsEntireUnsafeBoard(kind: String) async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("easl-closed-unreadable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BoardStore(directory: directory)
        let good = Board(id: BoardStore.pathID(directory.appendingPathComponent("good")), root: directory.appendingPathComponent("good"))
        let visible = good.create(type: .terminal, props: .object(["name": "visible"]))
        store.save(good)
        let badBoard = Board(id: BoardStore.pathID(directory.appendingPathComponent("bad")), root: directory.appendingPathComponent("bad"))
        badBoard.create(type: .terminal, props: .object(["name": "must not leak from a partial decode"]))
        badBoard.create(type: .note, props: .object(["markdown": "unknown trailing object"]))
        let badURL = store.url(for: badBoard.id)
        let bytes = try corrupted(badBoard.snapshot, kind: kind)
        try bytes.write(to: badURL)
        let router = ApiRouter(registry: BoardRegistry(store: store))

        for _ in 0..<2 {
            let entries = try #require(await router.agentList()["agents"]?.array)
            #expect(entries.compactMap { $0["tile"]?.string } == [visible.id])
            #expect(entries.first?["open"] == .bool(false))
            #expect(try Data(contentsOf: badURL) == bytes)
        }
    }
}
