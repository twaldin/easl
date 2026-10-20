import Foundation
import Testing
@testable import CanvasCore

/// A repository with uncommitted work across several files, as an agent leaves it: two
/// separate edits in one file, an untracked file, a deleted file, and one hunk already staged.
private func workRepo() async throws -> TempRepo {
    let repo = try await TempRepo()
    try await repo.write("app.txt", numbered(1...30))
    try await repo.write("gone.txt", numbered(1...3))
    try await repo.write("staged.txt", numbered(1...5))
    try await repo.commit("base")
    var lines = (1...30).map { "line \($0)" }
    lines[2] = "line 3 changed"
    lines.insert("inserted after 20", at: 20)
    try await repo.write("app.txt", lines.joined(separator: "\n") + "\n")
    try await repo.write("new.txt", "fresh\nfile\n")
    let gone = repo.url("gone.txt")
    try await offPool { Result { try FileManager.default.removeItem(at: gone) } }.get()
    try await repo.write("staged.txt", numbered(1...6))
    try await repo.git("add", "staged.txt")
    return repo
}

/// `git diff` hunk headers without git's function context (`@@ -1,6 +1,6 @@ line 3` → `@@ -1,6 +1,6 @@`).
private func gitHeaders(_ repo: TempRepo, _ args: String...) async throws -> [String] {
    let output = try await TempRepo.run(["diff", "--no-color", "-U3"] + args, in: repo.root)
    return output.split(separator: "\n").filter { $0.hasPrefix("@@") }.map { line in
        let parts = line.components(separatedBy: " @@")
        return parts[0] + " @@"
    }
}

private func read(_ url: URL) async -> String? {
    await offPool { try? String(contentsOf: url, encoding: .utf8) }
}

@MainActor
struct ChangeSetTests {
    @Test func listsEveryChangedFileWithGitsHunks() async throws {
        let repo = try await workRepo()
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object([:])), highlight: false, engine: GitDiffEngine(watchesRepositories: false))
        #expect(set.notice == nil)
        #expect(set.baseLabel == "HEAD")
        #expect(set.files.map(\.path) == ["app.txt", "gone.txt", "new.txt", "staged.txt"])
        #expect(set.files.map(\.status) == [.modified, .deleted, .added, .modified])
        let app = set.files[0]
        #expect(app.added == 2 && app.removed == 1)
        #expect(app.hunks.map(\.header) == (try await gitHeaders(repo, "HEAD", "--", "app.txt")))
        // Hunk rows: 3 lines of context around each change, removed before added.
        #expect(app.hunks[0].lines.map(\.kind) == [.context, .context, .removed, .added, .context, .context, .context])
        #expect(app.hunks[0].lines[2] == ChangeLine(kind: .removed, old: 3, new: nil))
        #expect(app.hunks[0].lines[3] == ChangeLine(kind: .added, old: nil, new: 3))
        #expect(set.files[1].removed == 3 && set.files[1].hunks.map(\.header) == ["@@ -1,3 +0,0 @@"])
        #expect(set.files[2].added == 2 && !set.files[2].tracked && set.files[2].hunks.map(\.header) == ["@@ -0,0 +1,2 @@"])
        // What the index holds: the staged file's hunk, nothing else.
        #expect(set.files.flatMap { $0.hunks.map(\.status) } == [.unstaged, .unstaged, .unstaged, .unstaged, .staged])
    }

    @Test func pathsLimitTheListAndNeverLeaveTheRepository() async throws {
        let repo = try await workRepo()
        let engine = GitDiffEngine(watchesRepositories: false)
        let limited = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object(["paths": ["new.txt", "app.txt"]])), highlight: false, engine: engine)
        #expect(limited.files.map(\.path) == ["app.txt", "new.txt"])
        let outside = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object(["paths": ["../elsewhere"]])), highlight: false, engine: engine)
        #expect(outside.files.isEmpty)
        #expect(outside.notice?.contains("outside the repository") == true)
    }

    @Test func aBaseOlderThanHeadMarksCommittedHunks() async throws {
        let repo = try await TempRepo()
        try await repo.write("a.txt", numbered(1...20))
        let first = try await repo.commit("one")
        try await repo.write("a.txt", numbered(1...20).replacingOccurrences(of: "line 2\n", with: "line two\n"))
        try await repo.commit("two")
        try await repo.write("a.txt", numbered(1...20).replacingOccurrences(of: "line 2\n", with: "line two\n").replacingOccurrences(of: "line 18\n", with: "line eighteen\n"))
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object(["base": .string(first)])), highlight: false, engine: GitDiffEngine(watchesRepositories: false))
        #expect(set.files.first?.hunks.map(\.status) == [.committed, .unstaged])
    }

    /// ⇧⌘M and `m` in a changes tile: the selected lines, else the hunk, named on the side they are on.
    @Test func keyboardMentionsNameTheSelectedLinesOrTheHunk() async throws {
        let repo = try await workRepo()
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object([:])), highlight: false, engine: GitDiffEngine(watchesRepositories: false))
        // app.txt's first hunk: context 1–2, line 3 removed then added, context 4–6.
        let whole = try #require(set.mention(file: 0, hunk: 0, lines: nil))
        #expect(whole.path == "app.txt" && whole.lines == LineRange(start: 3, end: 3) && whole.side == .new)
        #expect(whole.detail == "whole hunk +1 −1 · unstaged")
        let edited = try #require(set.mention(file: 0, hunk: 0, lines: [2, 3]))
        #expect(edited.lines == LineRange(start: 3, end: 3) && edited.side == .new && edited.detail == "changed lines · unstaged hunk")
        let removed = try #require(set.mention(file: 0, hunk: 0, lines: [2]))
        #expect(removed.side == .old && removed.lines == LineRange(start: 3, end: 3) && removed.detail == "removed line · unstaged hunk")
        let gapped = try #require(set.mention(file: 0, hunk: 0, lines: [0, 1, 3, 5]))
        #expect(gapped.lines == LineRange(start: 1, end: 5) && gapped.side == .new, "working-tree lines, the removed one left out")
        let deleted = try #require(set.mention(file: 1, hunk: 0, lines: nil))
        #expect(deleted.path == "gone.txt" && deleted.side == .old && deleted.lines == LineRange(start: 1, end: 3))
        #expect(set.mention(file: 0, hunk: 9, lines: nil) == nil)
    }
}

@MainActor
struct ReviewPatchTests {
    @Test func patchTextIsWhatGitDiffPrints() async throws {
        // Changes 7 unchanged lines apart are two hunks (6 apart would share their context).
        let old = SideText("a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n")
        let new = SideText("a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nnew")
        let text = ReviewPatch.text(path: "dir/f.txt", old: old, new: new, mappings: [
            LineRangeMapping(original: 2..<3, modified: 2..<3),
            LineRangeMapping(original: 11..<11, modified: 11..<12),
        ])
        #expect(text == """
        diff --git a/dir/f.txt b/dir/f.txt
        --- a/dir/f.txt
        +++ b/dir/f.txt
        @@ -1,5 +1,5 @@
         a
        -b
        +B
         c
         d
         e
        @@ -8,3 +8,4 @@
         h
         i
         j
        +new
        \\ No newline at end of file

        """)
        let created = ReviewPatch.text(path: "n.txt", old: nil, new: SideText("x\r\n"), newMode: "100755", mappings: [LineRangeMapping(original: 1..<1, modified: 1..<2)])
        #expect(created == "diff --git a/n.txt b/n.txt\nnew file mode 100755\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1 @@\n+x\r\n")
    }

    @Test func revertThenUndoPutsTheHunkBackExactly() async throws {
        let repo = try await workRepo()
        let engine = GitDiffEngine(watchesRepositories: false)
        let git = ReviewGit()
        let board = Board(id: "brd_t", root: repo.root)
        let tile = board.create(type: .changes, props: .object([:]))
        let before = try #require(await read(repo.url("app.txt")))
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(tile.props), highlight: false, engine: engine)
        let app = set.files[0]

        let patch = try ReviewPatch.revert([app.hunks[0]], of: app, in: try #require(set.repository))
        try await git.apply(patch)
        try board.recordReview(tile: tile.id, entry: .object(["action": "revert", "path": "app.txt", "header": .string(app.hunks[0].header)]), patch: patch, git: git)
        let reverted = try #require(await read(repo.url("app.txt")))
        #expect(reverted.contains("line 3\n") && !reverted.contains("line 3 changed"))
        #expect(reverted.contains("inserted after 20"))
        #expect(try await gitHeaders(repo, "--", "app.txt").count == 1)
        #expect(board.objects[tile.id]?.props["reviewed"]?.array?.count == 1)

        #expect(board.undo())
        await git.settled()
        #expect(await read(repo.url("app.txt")) == before)
        #expect(board.objects[tile.id]?.props["reviewed"] == nil)

        #expect(board.redo())
        await git.settled()
        #expect(await read(repo.url("app.txt")) == reverted)
    }

    @Test func stageThenUndoLeavesTheIndexAsItWas() async throws {
        let repo = try await workRepo()
        let engine = GitDiffEngine(watchesRepositories: false)
        let git = ReviewGit()
        let board = Board(id: "brd_t", root: repo.root)
        let tile = board.create(type: .changes, props: .object([:]))
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(tile.props), highlight: false, engine: engine)
        let top = try #require(set.repository)
        let cachedBefore = try await TempRepo.run(["diff", "--cached"], in: repo.root)

        // One hunk of a modified file: only it reaches the index.
        let app = set.files[0]
        let patch = try await ReviewPatch.stage([app.hunks[1]], of: app, in: top)
        try await git.apply(patch)
        try board.recordReview(tile: tile.id, entry: .object(["action": "stage", "path": "app.txt"]), patch: patch, git: git)
        #expect(try await gitHeaders(repo, "--cached", "--", "app.txt") == [app.hunks[1].header])
        #expect(try await gitHeaders(repo, "--", "app.txt") == [app.hunks[0].header])
        let reloaded = await ChangeSet.load(root: repo.root, spec: ChangesSpec(tile.props), highlight: false, engine: engine)
        #expect(reloaded.files[0].hunks.map(\.status) == [.unstaged, .staged])
        // Staging it again is refused.
        await #expect(throws: ChangesFailure.self) { try await ReviewPatch.stage([reloaded.files[0].hunks[1]], of: reloaded.files[0], in: top) }

        #expect(board.undo())
        await git.settled()
        #expect(try await TempRepo.run(["diff", "--cached"], in: repo.root) == cachedBefore)

        // An untracked file is added whole, and undo makes it untracked again.
        let fresh = set.files[2]
        let add = try await ReviewPatch.stage(nil, of: fresh, in: top)
        try await git.apply(add)
        try board.recordReview(tile: tile.id, entry: .object(["action": "stage", "path": "new.txt"]), patch: add, git: git)
        #expect(try await repo.git("ls-files", "new.txt") == "new.txt")
        #expect(board.undo())
        await git.settled()
        #expect(try await repo.git("ls-files", "new.txt") == "")
        #expect(FileManager.default.fileExists(atPath: repo.url("new.txt").path))
    }

    @Test func revertingCreatedAndDeletedFilesDeletesAndRestoresThem() async throws {
        let repo = try await workRepo()
        let git = ReviewGit()
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object([:])), highlight: false, engine: GitDiffEngine(watchesRepositories: false))
        let top = try #require(set.repository)
        let gone = set.files[1], fresh = set.files[2]

        let restore = try ReviewPatch.revert(gone.hunks, of: gone, in: top)
        try await git.apply(restore)
        #expect(await read(repo.url("gone.txt")) == numbered(1...3))
        try await git.apply(restore.inverse)
        #expect(!FileManager.default.fileExists(atPath: repo.url("gone.txt").path))

        let remove = try ReviewPatch.revert(fresh.hunks, of: fresh, in: top)
        try await git.apply(remove)
        #expect(!FileManager.default.fileExists(atPath: repo.url("new.txt").path))
        try await git.apply(remove.inverse)
        #expect(await read(repo.url("new.txt")) == "fresh\nfile\n")
    }

    @Test func aHunkThatNoLongerAppliesIsRefused() async throws {
        let repo = try await workRepo()
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object([:])), highlight: false, engine: GitDiffEngine(watchesRepositories: false))
        let app = set.files[0]
        // Someone edits the hunk's lines after the tile loaded.
        let edited = try #require(await read(repo.url("app.txt"))).replacingOccurrences(of: "line 3 changed", with: "line 3 edited again")
        try await repo.write("app.txt", edited)
        let patch = try ReviewPatch.revert([app.hunks[0]], of: app, in: try #require(set.repository))
        await #expect(throws: ChangesFailure.self) { try await ReviewGit().apply(patch) }
        #expect(await read(repo.url("app.txt")) == edited)
    }

    @Test func patchesNeverNameFilesOutsideTheRepository() {
        #expect(throws: ChangesFailure.self) { try ReviewPatch.checkPath("../x") }
        #expect(throws: ChangesFailure.self) { try ReviewPatch.checkPath("/etc/hosts") }
        #expect(throws: ChangesFailure.self) { try ReviewPatch.checkPath("a/.git/config") }
    }
}

/// `object.get` of a changes tile over the socket, as an agent reads what the user kept.
@MainActor
final class ChangesApiTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-changes-\(UUID().uuidString.prefix(8))")

    @Test func objectGetListsFilesHunksAndReviewedActions() async throws {
        let repo = try await workRepo()
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
            let reply = try await client.next()
            #expect(reply["ok"] == .bool(true), "\(method): \(reply["error"] ?? .null)")
            return reply["result"] ?? .null
        }
        let created = try await call("object.create", .object(["board": .string(board.id), "type": "changes", "props": .object(["paths": ["app.txt", "new.txt"]])]))
        let id = try #require(created["object"]?["id"]?.string)
        let git = ReviewGit()
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object(["paths": ["app.txt"]])), highlight: false, engine: GitDiffEngine(watchesRepositories: false))
        let patch = try ReviewPatch.revert([set.files[0].hunks[1]], of: set.files[0], in: try #require(set.repository))
        try await git.apply(patch)
        try board.recordReview(tile: id, entry: .object(["action": "revert", "path": "app.txt", "header": .string(set.files[0].hunks[1].header)]), patch: patch, git: git)

        let got = try await call("object.get", .object(["id": .string(id)]))
        let files = try #require(got["changes"]?["files"]?.array)
        #expect(files.map { $0["path"]?.string } == ["app.txt", "new.txt"])
        #expect(files.map { $0["status"]?.string } == ["modified", "added"])
        let hunks = try #require(files[0]["hunks"]?.array)
        #expect(hunks.count == 1)
        #expect(hunks[0]["header"]?.string == "@@ -1,6 +1,6 @@")
        #expect(hunks[0]["new"]?["start"]?.int == 1 && hunks[0]["added"]?.int == 1 && hunks[0]["status"]?.string == "unstaged")
        #expect(got["object"]?["props"]?["reviewed"]?.array?.first?["action"]?.string == "revert")

        // The hunk's text, so an agent reads the diff without rendering it.
        #expect(hunks[0]["lines"]?.array?.compactMap(\.string) == [" line 1", " line 2", "-line 3", "+line 3 changed", " line 4", " line 5", " line 6"])
        #expect(hunks[0]["truncated"] == nil && hunks[0]["id"]?.string?.isEmpty == false)

        // An agent asking again for the tile it made gets that tile back, refitted.
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(repo.root.path), "command": .array([])]))
        let first = try await call("object.create", .object(["board": .string(board.id), "type": "changes", "caller": .string(terminal.id), "size": "fit",
                                                            "props": .object(["paths": ["new.txt"], "title": "mine"])]))
        let again = try await call("object.create", .object(["board": .string(board.id), "type": "changes", "caller": .string(terminal.id), "size": "fit",
                                                            "props": .object(["paths": ["new.txt"], "title": "mine, again"])]))
        #expect(again["reused"] == .bool(true))
        #expect(again["object"]?["id"] == first["object"]?["id"])
        #expect(again["object"]?["props"]?["title"]?.string == "mine, again")
        #expect(first["reused"] == nil)
        let other = try await call("object.create", .object(["board": .string(board.id), "type": "changes", "caller": .string(terminal.id), "props": .object(["paths": ["app.txt"]])]))
        #expect(other["reused"] == nil && other["object"]?["id"] != first["object"]?["id"], "other paths are another tile")
        #expect(board.objects.values.filter { $0.type == .changes }.count == 3)
    }
}

@MainActor
struct ChangesReviewTests {
    @Test func aTileReviewsAnotherWorktreeOfTheBoardsRepositoryAndNothingElse() async throws {
        let repo = try await TempRepo()
        try await repo.write("src/fees.ts", numbered(1...10))
        try await repo.write("docs/a.md", "a\n")
        try await repo.commit("init")
        let worktree = URL(fileURLWithPath: repo.root.path + "-wt/fees")
        try await repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        let file = worktree.appendingPathComponent("src/fees.ts")
        let edited = numbered(1...10).replacingOccurrences(of: "line 5\n", with: "line five\n")
        try edited.write(to: file, atomically: true, encoding: .utf8)
        try "b\n".write(to: worktree.appendingPathComponent("docs/a.md"), atomically: true, encoding: .utf8)
        let engine = GitDiffEngine(watchesRepositories: false)

        // Absolute, or relative to the board root; paths then resolve inside the worktree.
        for root in [worktree.path, "../\(repo.root.lastPathComponent)-wt/fees"] {
            let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object(["root": .string(root), "paths": ["src"]])), highlight: false, engine: engine)
            #expect(set.notice == nil)
            #expect(set.files.map(\.boardPath) == [file.standardizedFileURL.path], "outside the board root, paths are absolute, as the board writes them")
            #expect(set.worktree == "fees (feature)")
        }
        #expect(await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object([:])), highlight: false, engine: engine).files.isEmpty, "the board's own checkout is clean")

        // Discard acts in that worktree, and its undo puts the line back there.
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object(["root": .string(worktree.path), "paths": ["src"]])), highlight: false, engine: engine)
        let fees = set.files[0]
        let git = ReviewGit()
        let board = Board(id: "brd_t", root: repo.root)
        let tile = board.create(type: .changes, props: .object(["root": .string(worktree.path)]))
        let patch = try ReviewPatch.revert([fees.hunks[0]], of: fees, in: try #require(set.repository))
        try await git.apply(patch)
        try board.recordReview(tile: tile.id, entry: ReviewPatch.entry("revert", file: fees, hunk: fees.hunks[0], lines: nil, patch: patch), patch: patch, git: git)
        #expect(await read(file) == numbered(1...10))
        #expect(await read(repo.url("src/fees.ts")) == numbered(1...10))
        #expect(board.undo())
        await git.settled()
        #expect(await read(file) == edited)

        // Paths beyond the worktree, and other repositories, are refused.
        let outside = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object(["root": .string(worktree.path), "paths": [.string(repo.root.path)]])), highlight: false, engine: engine)
        #expect(outside.files.isEmpty && outside.notice?.contains("outside the repository") == true)
        let other = try await TempRepo()
        try await other.write("x.txt", "x\n")
        try await other.commit("other")
        try await other.write("x.txt", "y\n")
        let refused = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object(["root": .string(other.root.path)])), highlight: false, engine: engine)
        #expect(refused.files.isEmpty && refused.notice?.contains("not a worktree") == true)
    }

    @Test func pickedLinesOfAHunkKeepTheirPairsAndLeaveTheRestAsTheTargetHasIt() {
        let old = SideText("a\nb\nc\nd\n"), new = SideText("a\nB\nC\nd\n")
        let mappings = [LineRangeMapping(original: 2..<4, modified: 2..<4)]
        let pick = ReviewPatch.LinePick(removed: [2], added: [2])
        let header = "diff --git a/f b/f\n--- a/f\n+++ b/f\n"
        // Staging b → B: c stays (context), C isn't added.
        #expect(ReviewPatch.text(path: "f", old: old, new: new, mappings: mappings, pick: pick) == header + "@@ -1,4 +1,4 @@\n a\n-b\n+B\n c\n d\n")
        // Discarding b → B (applied reversed to the working tree): C stays, c isn't brought back.
        #expect(ReviewPatch.text(path: "f", old: old, new: new, mappings: mappings, pick: pick, reverse: true) == header + "@@ -1,4 +1,4 @@\n a\n-b\n+B\n C\n d\n")
        // Only an added line: the others are as the target has them.
        #expect(ReviewPatch.text(path: "f", old: old, new: new, mappings: mappings, pick: .init(removed: [], added: [3])) == header + "@@ -1,4 +1,5 @@\n a\n b\n c\n+C\n d\n")
        #expect(ReviewPatch.text(path: "f", old: old, new: new, mappings: mappings, pick: .init(removed: [], added: [])).isEmpty, "nothing picked, no patch")
    }

    @Test func stagingAndDiscardingSomeLinesOfAHunkTouchOnlyThoseAndUndoExactly() async throws {
        // Two tweaks three lines apart: one hunk.
        let repo = try await TempRepo()
        try await repo.write("style.css", numbered(1...12))
        try await repo.commit("base")
        let tweaked = numbered(1...12).replacingOccurrences(of: "line 3\n", with: "line 3 pink\n").replacingOccurrences(of: "line 6\n", with: "line 6 dark\n")
        try await repo.write("style.css", tweaked)
        let engine = GitDiffEngine(watchesRepositories: false)
        let git = ReviewGit()
        let board = Board(id: "brd_t", root: repo.root)
        let tile = board.create(type: .changes, props: .object([:]))
        func load() async -> ChangeSet { await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object([:])), highlight: false, engine: engine) }
        // The user picks the edited line as it reads now; its old version comes with it.
        func rows(_ hunk: ChangeHunk, _ line: Int) -> Set<Int> {
            hunk.pairedRows(Set(hunk.lines.indices.filter { hunk.lines[$0].new == line && hunk.lines[$0].kind == .added }))
        }
        var set = await load()
        let top = try #require(set.repository)
        #expect(set.files[0].hunks.count == 1)
        #expect(rows(set.files[0].hunks[0], 3).map { set.files[0].hunks[0].lines[$0].kind }.sorted { "\($0)" < "\($1)" } == [.added, .removed])

        // Stage the pink tweak only.
        var hunk = set.files[0].hunks[0]
        let stage = try await ReviewPatch.stage([hunk], of: set.files[0], in: top, lines: rows(hunk, 3))
        try await git.apply(stage)
        try board.recordReview(tile: tile.id, entry: ReviewPatch.entry("stage", file: set.files[0], hunk: hunk, lines: rows(hunk, 3), patch: stage), patch: stage, git: git)
        let cached = try await TempRepo.run(["diff", "--cached", "-U0"], in: repo.root)
        #expect(cached.contains("-line 3\n+line 3 pink") && !cached.contains("dark"))
        let unstaged = try await TempRepo.run(["diff", "-U0"], in: repo.root)
        #expect(unstaged.contains("-line 6\n+line 6 dark") && !unstaged.contains("pink"))
        let entry = try #require(board.objects[tile.id]?.props["reviewed"]?.array?.last)
        #expect(entry["scope"] == "lines" && entry["hunk"]?.string == hunk.id && entry["added"]?.int == 1 && entry["removed"]?.int == 1)
        #expect(entry["patch"]?.string?.contains("+line 3 pink\n") == true && entry["patch"]?.string?.contains("dark") == false)

        // Discard the dark tweak only: the pink one stays on disk.
        set = await load()
        hunk = set.files[0].hunks[0]
        let discard = try ReviewPatch.revert([hunk], of: set.files[0], in: top, lines: rows(hunk, 6))
        try await git.apply(discard)
        try board.recordReview(tile: tile.id, entry: ReviewPatch.entry("revert", file: set.files[0], hunk: hunk, lines: rows(hunk, 6), patch: discard), patch: discard, git: git)
        #expect(await read(repo.url("style.css")) == numbered(1...12).replacingOccurrences(of: "line 3\n", with: "line 3 pink\n"))

        // Each is one undo step.
        #expect(board.undo())
        await git.settled()
        #expect(await read(repo.url("style.css")) == tweaked)
        #expect(try await TempRepo.run(["diff", "--cached", "-U0"], in: repo.root) == cached)
        #expect(board.undo())
        await git.settled()
        #expect(try await TempRepo.run(["diff", "--cached"], in: repo.root) == "")
    }

    @Test func aHunkStagedThenEditedIsPartlyStaged() async throws {
        let repo = try await TempRepo()
        try await repo.write("a.txt", numbered(1...30))
        try await repo.commit("base")
        let staged = numbered(1...30).replacingOccurrences(of: "line 5\n", with: "line 5 staged\n").replacingOccurrences(of: "line 25\n", with: "line 25 staged\n")
        try await repo.write("a.txt", staged)
        try await repo.git("add", "a.txt")
        // An agent edits the first staged hunk again; the second stays as staged; a third is new.
        try await repo.write("a.txt", staged.replacingOccurrences(of: "line 6\n", with: "line 6 edited\n").replacingOccurrences(of: "line 15\n", with: "line 15 new\n"))
        let engine = GitDiffEngine(watchesRepositories: false)
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object([:])), highlight: false, engine: engine)
        #expect(set.files[0].hunks.map(\.status) == [.partial, .unstaged, .staged])
        #expect(set.files[0].json()["hunks"]?.array?.map { $0["status"]?.string } == ["partial", "unstaged", "staged"])
        #expect(set.mentionDetail(file: 0, hunk: 0, lines: nil)?.contains("partly staged") == true)
    }

    @Test func fittingAccountsForWrappedLines() async throws {
        let repo = try await TempRepo()
        try await repo.write("long.txt", "short\n")
        try await repo.commit("base")
        try await repo.write("long.txt", "short\n" + String(repeating: "word ", count: 120) + "\n")
        let set = await ChangeSet.load(root: repo.root, spec: ChangesSpec(.object([:])), highlight: false, engine: GitDiffEngine(watchesRepositories: false))
        let wide = ChangesMetrics.fit(set, maxWidth: 6000), narrow = ChangesMetrics.fit(set, maxWidth: 480)
        let columns = ChangesMetrics.textColumns(width: narrow.width, digits: ChangesMetrics.digits(set))
        let rows = Int((Double(600) / Double(columns)).rounded(.up))
        #expect(narrow.width == 480)
        #expect(narrow.height - wide.height >= CGFloat(rows - 1) * ChangesMetrics.lineHeight - 1, "the long line's continuation rows count")
    }
}

@MainActor
struct ChangesTileGrowthTests {
    /// Persona study B9: an agent's fitted changes tile grew down over the terminal below it.
    @Test func aFittedTileGrowsIntoFreeSpaceNeverOverItsNeighbours() throws {
        let board = Board(id: "brd_t", root: URL(fileURLWithPath: NSTemporaryDirectory()))
        let tile = board.create(type: .changes, props: .object([:]), frame: Frame(x: 0, y: 0, w: 600, h: 300))
        let terminal = board.create(type: .note, props: .object(["markdown": .string("agent")]), frame: Frame(x: 0, y: 340, w: 600, h: 400))
        board.create(type: .note, props: .object(["markdown": .string("above")]), frame: Frame(x: 0, y: -500, w: 600, h: 460))
        board.create(type: .note, props: .object(["markdown": .string("left")]), frame: Frame(x: -700, y: -500, w: 660, h: 1300))

        board.growFitted(tile.id, toward: CGSize(width: 600, height: 900))
        let hemmed = try board.object(tile.id).frame
        #expect(!hemmed.intersects(try board.object(terminal.id).frame))
        #expect(hemmed.h >= 300)

        try board.delete(terminal.id)
        board.growFitted(tile.id, toward: CGSize(width: 600, height: 900))
        #expect(try board.object(tile.id).frame == Frame(x: 0, y: 0, w: 600, h: 900), "with room it shows the whole diff")
    }
}

struct DiscardQuestionTests {
    let lines = DiscardQuestion.Target(path: "inventory/forecast.py", hunk: "h1", lines: [4, 5])
    let hunk = DiscardQuestion.Target(path: "inventory/forecast.py", hunk: "h1", lines: nil)

    /// Persona study B11: "Discard?" went back to "Discard" after ~3 s under its hint, and the
    /// confirming click only asked again.
    @Test func aQuestionLastsUntilAnsweredWithItsHint() {
        var question = DiscardQuestion()
        #expect(question.press(lines, by: .click) == .asked)
        #expect(question.hint == "click Discard again to discard 2 selected lines from your files")
        #expect(question.press(lines, by: .click) == .confirmed)
        #expect(question.target == nil && question.hint == nil)
    }

    @Test func anotherTargetOrMovingOnAsksAgain() {
        var question = DiscardQuestion()
        _ = question.press(lines, by: .click)
        #expect(question.press(hunk, by: .click) == .asked, "the whole hunk isn't the lines asked about")
        #expect(question.hint == "click Discard again to discard this hunk from your files")
        question.drop()
        #expect(question.target == nil && question.hint == nil)
        #expect(question.press(hunk, by: .key) == .asked)
        #expect(question.hint == "⌘⌫ discards this hunk from your files · any other key keeps it")
        #expect(question.press(hunk, by: .key) == .asked, "a second r never discards")
        #expect(question.press(hunk, by: .confirm) == .confirmed, "⌘⌫ does")
        _ = question.press(hunk, by: .key)
        #expect(question.press(DiscardQuestion.Target(path: "inventory/forecast.py", hunk: nil, lines: nil), by: .click) == .asked)
        #expect(question.hint == "click Discard again to discard all of inventory/forecast.py from your files")
    }
}
