import Foundation
import Testing
@testable import CanvasCore

/// Code and note tiles anchored to a branch (`props.ref`) through a worktree's life: live edits
/// while it is checked out, the ref's objects once the worktree is deleted, the merge commit once
/// the branch is merged and deleted, the last SHA once a squashed branch is deleted.
@MainActor
struct RefTileTests {
    /// `main` with `src/a.txt`, and branch `feature` changing its line 2, checked out in a linked
    /// worktree that also has an uncommitted edit of that line.
    func fixture() async throws -> (repo: TempRepo, worktree: URL, tip: String) {
        let repo = try await TempRepo()
        try await repo.write("src/a.txt", "one\ntwo\nthree\nfour\nfive\n")
        try await repo.commit("init")
        let worktree = URL(fileURLWithPath: repo.root.path + "-wt/feature")
        try await repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        let file = worktree.appendingPathComponent("src/a.txt")
        try "one\nfeature two\nthree\nfour\nfive\n".write(to: file, atomically: true, encoding: .utf8)
        try await TempRepo.run(["commit", "-q", "-a", "-m", "feature"], in: worktree)
        let tip = try await TempRepo.run(["rev-parse", "HEAD"], in: worktree)
        try "one\nlive two\nthree\nfour\nfive\n".write(to: file, atomically: true, encoding: .utf8)
        return (repo, worktree, tip)
    }

    @Test func aCodeTileReadsTheLiveWorktreeThenTheRefThenItsMergeCommit() async throws {
        let (repo, worktree, tip) = try await fixture()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-ref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards")))
        let board = try await registry.open(root: repo.root)
        let router = ApiRouter(registry: registry)
        let server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        let client = try LineClient(path: dir.appendingPathComponent("s").path)
        func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            client.send(String(decoding: try JSONEncoder().encode(JSONValue.object(["id": "1", "method": .string(method), "params": params])), as: UTF8.self))
            return try await client.next()
        }
        func line(_ line: Int) async throws -> String? {
            var props = try #require(board.objects.values.first { $0.type == .code }).props
            props = props.merging(.object(["range": .object(["start": .number(Double(line)), "end": .number(Double(line))])]))
            return try await ObjectMeasure.codeExcerpt(props, root: board.root).lines.first
        }

        let created = try await call("object.create", .object(["board": .string(board.id), "type": "code", "props": .object(["path": "src/a.txt", "ref": "feature"])]))
        #expect(created["result"]?["object"]?["props"]?["refSha"]?.string == tip, "the SHA it resolved to is recorded")
        #expect(try await line(2) == "live two", "checked out: the worktree's uncommitted text")

        try await repo.git("worktree", "remove", "--force", worktree.path)
        #expect(try await line(2) == "feature two", "worktree gone: the branch's commit")

        // main changes line 5 before merging, and again after: the merge commit holds both sides.
        try await repo.write("src/a.txt", "one\ntwo\nthree\nfour\nmain five\n")
        try await repo.commit("main five")
        try await repo.git("merge", "-q", "--no-ff", "-m", "merge feature", "feature")
        try await repo.write("src/a.txt", "one\nfeature two\nthree\nfour\nlater five\n")
        try await repo.commit("later")
        try await repo.git("branch", "-d", "feature")
        #expect(try await line(2) == "feature two")
        #expect(try await line(5) == "main five", "merged and gone: the file at the merge commit, not main now")

        let unknown = try await call("object.create", .object(["board": .string(board.id), "type": "code", "props": .object(["path": "src/a.txt", "ref": "nope"])]))
        #expect(unknown["error"]?["code"]?.string == "not_found")
    }

    @Test func aNoteReadsItsFencesAtTheRefAndASquashedBranchIsGone() async throws {
        let (repo, worktree, tip) = try await fixture()
        let board = Board(id: "brd_test", root: repo.root)
        let markdown = "```txt file=src/a.txt#L2\n```\n"
        let note = board.create(type: .note, props: .object(["markdown": .string(markdown), "ref": "feature"]))
        func excerpt() async throws -> (line: String?, reading: LinkReading) {
            let reading = await board.linkSource(of: try board.object(note.id))
            let fences = NoteMarkdown.anchoredFences(in: NoteMarkdown.parse(markdown))
            let results = await NoteSource.excerpts(for: reading.fences(fences), root: reading.root)
            return (results.values.first?.lines.first, reading)
        }

        let live = try await excerpt()
        #expect(live.line == "live two")
        #expect(live.reading.ref?.label == "live in feature")
        #expect(board.objects[note.id]?.props["refSha"]?.string == tip)

        try await repo.git("worktree", "remove", "--force", worktree.path)
        let objects = try await excerpt()
        #expect(objects.line == "feature two")
        #expect(objects.reading.ref?.label == "feature @ \(tip.prefix(7))")

        try await repo.git("merge", "-q", "--squash", "feature")
        try await repo.git("commit", "-q", "-m", "squashed")
        try await repo.git("branch", "-D", "feature")
        let gone = try await excerpt()
        #expect(gone.line == "feature two", "the last SHA still reads")
        #expect(gone.reading.ref?.label == "branch gone, showing \(tip.prefix(7))")
    }
}
