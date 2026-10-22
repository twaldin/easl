import Foundation
import Testing
@testable import CanvasCore

/// A throwaway git repository in a temp directory. Every fixture step runs on GCD: blocking a
/// Swift task (Process, pipes, large writes) parks the cooperative pool the socket tests need.
struct TempRepo: Sendable {
    let root: URL

    init(branch: String = "main") async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // No template: copying git's sample hooks made `init` the slowest step of these suites.
        try await git("init", "-q", "--template=", "-b", branch)
    }

    init(cloning origin: TempRepo) async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-git-\(UUID().uuidString)")
        try await TempRepo.run(["clone", "-q", "--template=", origin.root.path, root.path], in: origin.root)
    }

    @discardableResult
    func git(_ args: String...) async throws -> String {
        try await TempRepo.run(args, in: root)
    }

    @discardableResult
    static func run(_ args: [String], in directory: URL) async throws -> String {
        let result: Result<String, Error> = await offPool {
            Result {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                // No auto-maintenance: every commit would start another git in the background.
                process.arguments = ["-c", "user.name=easl Tests", "-c", "user.email=tests@canvas.invalid", "-c", "commit.gpgsign=false", "-c", "maintenance.auto=false"] + args
                process.currentDirectoryURL = directory
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                try process.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw GitError.failed(status: process.terminationStatus, stderr: args.joined(separator: " ")) }
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return try result.get()
    }

    func write(_ path: String, _ text: String) async throws {
        try await writeData(path, Data(text.utf8))
    }

    func writeData(_ path: String, _ data: Data) async throws {
        let url = root.appendingPathComponent(path)
        try await offPool {
            Result {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
        }.get()
    }

    @discardableResult
    func commit(_ message: String) async throws -> String {
        try await git("add", "-A")
        try await git("commit", "-q", "-m", message)
        return try await git("rev-parse", "HEAD")
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
}

func numbered(_ range: ClosedRange<Int>) -> String {
    range.map { "line \($0)\n" }.joined()
}

struct GitBaseTests {
    @Test func mergeBaseUsesMainWhenThereIsNoRemote() async throws {
        let repo = try await TempRepo(branch: "main")
        try await repo.write("a.txt", numbered(1...3))
        let fork = try await repo.commit("base")
        try await repo.git("checkout", "-q", "-b", "feature")
        try await repo.write("a.txt", numbered(1...4))
        try await repo.commit("feature work")
        let resolved = await GitDiffEngine(watchesRepositories: false).resolvedBase(for: repo.url("a.txt"), base: .mergeBase)
        #expect(resolved == .init(sha: fork, label: "merge-base with main"))
        #expect(GitWorktree.containing(repo.root.path)?.defaultBranch == "main", "the picker names the branch merge-base picks")
    }

    @Test func mergeBaseFallsBackToMaster() async throws {
        let repo = try await TempRepo(branch: "master")
        try await repo.write("a.txt", numbered(1...3))
        let fork = try await repo.commit("base")
        try await repo.git("checkout", "-q", "-b", "topic")
        try await repo.write("b.txt", "new\n")
        try await repo.commit("topic")
        try await repo.git("checkout", "-q", "master")
        try await repo.write("a.txt", numbered(1...5))
        try await repo.commit("master moved on")
        try await repo.git("checkout", "-q", "topic")
        try await repo.git("pack-refs", "--all")
        let resolved = await GitDiffEngine(watchesRepositories: false).resolvedBase(for: repo.url("b.txt"), base: .mergeBase)
        #expect(resolved == .init(sha: fork, label: "merge-base with master"))
        #expect(GitWorktree.containing(repo.root.path)?.defaultBranch == "master", "a packed branch counts")
    }

    @Test func withoutMainMasterOrOriginThereIsNoDefaultBranch() async throws {
        let repo = try await TempRepo(branch: "dev")
        try await repo.write("a.txt", "a\n")
        let engine = GitDiffEngine(watchesRepositories: false)
        #expect(await engine.resolvedBase(for: repo.url("a.txt"), base: .mergeBase) == .init(sha: nil, label: "no commits yet"), "no commits comes first")
        try await repo.commit("one")
        #expect(await engine.resolvedBase(for: repo.url("a.txt"), base: .mergeBase) == .init(sha: nil, label: "no default branch"))
        #expect(GitWorktree.containing(repo.root.path)?.defaultBranch == nil)
    }

    @Test func originHeadWinsOverLocalBranches() async throws {
        let origin = try await TempRepo(branch: "trunk")
        try await origin.write("a.txt", numbered(1...3))
        let shared = try await origin.commit("shared")
        let clone = try await TempRepo(cloning: origin)
        // A local `main` that diverged from the remote default branch must not be the base.
        try await clone.git("checkout", "-q", "-b", "main")
        try await clone.write("a.txt", numbered(1...9))
        try await clone.commit("unrelated local main")
        try await clone.git("checkout", "-q", "-b", "feature", "origin/trunk")
        try await clone.write("b.txt", "feature\n")
        try await clone.commit("feature")
        let resolved = await GitDiffEngine(watchesRepositories: false).resolvedBase(for: clone.url("b.txt"), base: .mergeBase)
        #expect(resolved == .init(sha: shared, label: "merge-base with origin/trunk"))
        #expect(GitWorktree.containing(clone.root.path)?.defaultBranch == "origin/trunk", "origin/HEAD wins over a local main")
    }

    @Test func committingOnTheBaseBranchReResolvesTheBase() async throws {
        let repo = try await TempRepo(branch: "main")
        try await repo.write("a.txt", numbered(1...3))
        let first = try await repo.commit("one")
        try await repo.write("a.txt", numbered(1...4))
        let engine = GitDiffEngine()
        let held = try #require(await engine.retain(containing: repo.url("a.txt")))
        let before = await engine.diff(file: repo.url("a.txt"), base: .mergeBase)
        #expect(before.state == .modified && before.base == first)

        var second = ""
        let heard = try await announced(repo) { second = try await repo.commit("two") }
        #expect(heard, "a commit on the base branch must re-resolve the merge-base")
        let after = await engine.diff(file: repo.url("a.txt"), base: .mergeBase)
        #expect(after.base == second)
        #expect(after.state == .unchanged)

        await engine.release(held)
        #expect(await engine.watchedRepositoryCount == 0, "the last live holder going away stops the stream")
    }

    /// The study: on a feature branch, a new file's tile said "not tracked by git yet" after it
    /// was committed, in that tile and in any new one, until relaunch: the cached diff kept git
    /// status's `??` because neither the base nor the content had changed.
    @Test func committingANewFileOnABranchIsNoLongerUntracked() async throws {
        let repo = try await TempRepo(branch: "main")
        try await repo.write("a.txt", numbered(1...3))
        try await repo.commit("base")
        try await repo.git("checkout", "-q", "-b", "feature")
        try await repo.write("new.txt", numbered(1...5))
        let engine = GitDiffEngine()
        let held = try #require(await engine.retain(containing: repo.url("new.txt")))
        let fresh = await engine.diff(file: repo.url("new.txt"), base: .mergeBase)
        #expect(fresh.state == .added && fresh.untracked)

        let heard = try await announced(repo) { try await repo.commit("new file") }
        #expect(heard, "tiles showing it hear that its tracked state changed")
        let committed = await engine.diff(file: repo.url("new.txt"), base: .mergeBase)
        #expect(committed.state == .added && !committed.untracked, "new on the branch, and tracked")
        await engine.release(held)
    }

    /// The incident study: a follow tile re-aiming cancelled its load mid-resolution, the shared
    /// repository record kept "no commits yet", and every tile of the repository showed it.
    @Test func aCancelledResolutionIsNeitherNoCommitsNorKept() async throws {
        let repo = try await TempRepo(branch: "main")
        try await repo.write("a.txt", numbered(1...3))
        let fork = try await repo.commit("base")
        try await repo.git("checkout", "-q", "-b", "feature")
        try await repo.write("a.txt", numbered(1...4))
        try await repo.commit("feature work")
        let engine = GitDiffEngine(watchesRepositories: false)
        let held = try #require(await engine.retain(containing: repo.url("a.txt")))
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.diff(file: repo.url("a.txt"), base: .mergeBase)
        }.value
        #expect(cancelled.state == .noBase && cancelled.baseLabel == "git failed: cancelled")
        let next = await engine.diff(file: repo.url("a.txt"), base: .mergeBase)
        #expect(next.state == .modified && next.base == fork && next.baseLabel == "merge-base with main")
        await engine.release(held)
    }

    /// Without a watcher to announce the first commit, the next load still finds it.
    @Test func aBaseWithoutACommitIsAskedAgainOnTheNextLoad() async throws {
        let repo = try await TempRepo(branch: "main")
        try await repo.write("a.txt", numbered(1...3))
        let engine = GitDiffEngine(watchesRepositories: false)
        let held = try #require(await engine.retain(containing: repo.url("a.txt")))
        let unborn = await engine.diff(file: repo.url("a.txt"), base: .head)
        #expect(unborn.state == .noBase && unborn.baseLabel == "no commits yet")
        let first = try await repo.commit("first")
        let committed = await engine.diff(file: repo.url("a.txt"), base: .head)
        #expect(committed.state == .unchanged && committed.base == first)
        await engine.release(held)
    }
}

/// Whether `.gitDiffBaseChanged` is posted for `repo` within 10 s of `change`.
private func announced(_ repo: TempRepo, by change: () async throws -> Void) async throws -> Bool {
    let toplevel = try await repo.git("rev-parse", "--show-toplevel")
    let heard = Task {
        for await note in NotificationCenter.default.notifications(named: .gitDiffBaseChanged) where note.object as? String == toplevel { return true }
        return false
    }
    // Cancelling ends the wait for notifications, answering false.
    let deadline = Task {
        try? await Task.sleep(for: .seconds(10))
        heard.cancel()
    }
    defer {
        deadline.cancel()
        heard.cancel()
    }
    try await change()
    return await heard.value
}

struct GitDiffTests {
    @Test func modifiedFileMapsEveryHunkToOldAndNewLines() async throws {
        let repo = try await TempRepo()
        try await repo.write("f.txt", numbered(1...40))
        let base = try await repo.commit("base")
        // Change line 2, insert two lines after 10, delete 37-38, and append at the end.
        var lines = (1...40).map { "line \($0)" }
        lines[1] = "line 2 changed"
        lines.insert(contentsOf: ["new a", "new b"], at: 10)
        lines.removeSubrange(38...39)
        lines.append("tail")
        try await repo.write("f.txt", lines.joined(separator: "\n") + "\n")

        let diff = await GitDiffEngine(watchesRepositories: false).diff(file: repo.url("f.txt"), base: .mergeBase)
        #expect(diff.state == .modified)
        #expect(diff.base == base)
        #expect(diff.mappings == [
            LineRangeMapping(original: 2..<3, modified: 2..<3),
            LineRangeMapping(original: 11..<11, modified: 11..<13),
            LineRangeMapping(original: 37..<39, modified: 39..<39),
            LineRangeMapping(original: 41..<41, modified: 41..<42),
        ])
        #expect(diff.hunks.map(\.mappings.count) == [1, 1, 2], "changes within 6 lines of each other share a hunk, like git -U3")
        #expect(diff.hunks[2].mentionLines.side == .new && diff.hunks[2].mentionLines.lines == LineRange(start: 39, end: 41))
        #expect(diff.old.text == numbered(1...40), "the old side is the base version of the file")
    }

    @Test func pureDeletionHunkIsMentionedOnTheOldSide() async throws {
        let repo = try await TempRepo()
        try await repo.write("f.txt", numbered(1...30))
        try await repo.commit("base")
        var lines = (1...30).map { "line \($0)" }
        lines.removeSubrange(19...21)
        try await repo.write("f.txt", lines.joined(separator: "\n") + "\n")
        let diff = await GitDiffEngine(watchesRepositories: false).diff(file: repo.url("f.txt"), base: .head)
        let hunk = try #require(diff.hunks.first)
        #expect(diff.hunks.count == 1)
        #expect(hunk.mentionLines.side == .old && hunk.mentionLines.lines == LineRange(start: 20, end: 22))
    }

    @Test func untrackedAddedDeletedBinaryAndMissingFilesHaveClearStates() async throws {
        let repo = try await TempRepo()
        try await repo.write("keep.txt", "same\n")
        try await repo.write("gone.txt", numbered(1...3))
        try await repo.write(".gitignore", "node_modules/\n")
        try await repo.commit("base")
        try await repo.write("fresh.txt", "one\ntwo\n")
        try await repo.write("added.txt", "staged\n")
        try await repo.git("add", "added.txt")
        try await repo.write("node_modules/dep/index.js", numbered(1...4))
        try await offPool { Result { try FileManager.default.removeItem(at: repo.url("gone.txt")) } }.get()
        try await repo.writeData("image.png", Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]))
        let engine = GitDiffEngine(watchesRepositories: false)

        let fresh = await engine.diff(file: repo.url("fresh.txt"), base: .mergeBase)
        #expect(fresh.state == .added && fresh.untracked)
        #expect(CodeDocument(path: "fresh.txt", diff: fresh).signs == [GitSign(kind: .added, lines: 1..<3, old: 1..<1)])
        let added = await engine.diff(file: repo.url("added.txt"), base: .mergeBase)
        #expect(added.state == .added && !added.untracked, "a new file in the index is tracked")

        // A dependency git ignores is no change of the branch's: plain source, no signs.
        let ignored = await engine.diff(file: repo.url("node_modules/dep/index.js"), base: .mergeBase)
        #expect(ignored.state == .ignored && ignored.new.lineCount == 4)
        let dependency = CodeDocument(path: "node_modules/dep/index.js", diff: ignored)
        #expect(dependency.signs.isEmpty && dependency.warning == nil)

        let gone = await engine.diff(file: repo.url("gone.txt"), base: .mergeBase)
        #expect(gone.state == .deleted && gone.old.lineCount == 3)

        #expect(await engine.diff(file: repo.url("keep.txt"), base: .mergeBase).state == .unchanged)
        #expect(await engine.diff(file: repo.url("image.png"), base: .mergeBase).state == .binary)
        #expect(await engine.diff(file: repo.url("never.txt"), base: .mergeBase).state == .missing)

        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-plain-\(UUID().uuidString).txt")
        try await offPool { Result { try "plain\n".write(to: outside, atomically: true, encoding: .utf8) } }.get()
        let plain = await engine.diff(file: outside, base: .mergeBase)
        #expect(plain.state == .notRepository && plain.new.lineCount == 1)
    }

    @Test func unchangedContentIsServedFromCacheWithoutGit() async throws {
        let repo = try await TempRepo()
        try await repo.write("f.txt", numbered(1...5))
        try await repo.commit("base")
        try await repo.write("f.txt", numbered(1...6))
        let engine = GitDiffEngine(watchesRepositories: false)
        let first = await engine.diff(file: repo.url("f.txt"), base: .mergeBase)
        let runs = await engine.diffRuns
        let again = await engine.diff(file: repo.url("f.txt"), base: .mergeBase)
        #expect(again == first)
        #expect(await engine.diffRuns == runs, "same base and content must not run git diff again")

        try await repo.write("f.txt", numbered(1...7))
        let changed = await engine.diff(file: repo.url("f.txt"), base: .mergeBase)
        #expect(await engine.diffRuns == runs + 1)
        #expect(changed.mappings == [LineRangeMapping(original: 6..<6, modified: 6..<8)])
    }

    @Test func basesOnTheSameCommitShareTheDiffButNameTheirOwnBase() async throws {
        let repo = try await TempRepo()
        try await repo.write("f.txt", numbered(1...5))
        let head = try await repo.commit("base")
        try await repo.write("f.txt", numbered(1...6))
        let engine = GitDiffEngine(watchesRepositories: false)
        let mergeBase = await engine.diff(file: repo.url("f.txt"), base: .mergeBase)
        let atHead = await engine.diff(file: repo.url("f.txt"), base: .head)
        #expect(mergeBase.base == head && atHead.base == head, "on main, HEAD is the merge-base")
        #expect(mergeBase.baseLabel == "merge-base with main")
        #expect(atHead.baseLabel == "HEAD", "the header names the base the tile chose")
        #expect(atHead.hunks == mergeBase.hunks)
    }

    @Test func filesRequestedTogetherShareOneGitDiff() async throws {
        // The 20 ms admission window must not include unrelated suites' executor backlog.
        let isolated = try await runIsolatedTestIfParallel("filesRequestedTogetherShareOneGitDiff")
        if isolated { return }
        let repo = try await TempRepo()
        for name in ["a", "b", "c"] { try await repo.write("\(name) file.txt", numbered(1...3)) }
        try await repo.commit("base")
        for name in ["a", "b", "c"] { try await repo.write("\(name) file.txt", numbered(1...4)) }
        let engine = GitDiffEngine(watchesRepositories: false)
        // Live tiles hold their repository, so its base is resolved once for all of them.
        _ = await engine.retain(containing: repo.url("a file.txt"))
        _ = await engine.resolvedBase(for: repo.url("a file.txt"), base: .mergeBase)
        let diffs = await withTaskGroup(of: FileDiff.self) { group in
            for name in ["a", "b", "c"] { group.addTask { await engine.diff(file: repo.url("\(name) file.txt"), base: .mergeBase) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(diffs.allSatisfy { $0.mappings == [LineRangeMapping(original: 4..<4, modified: 4..<5)] })
        #expect(await engine.diffRuns == 1)
    }

    @Test func groupedDeletionsAreMentionedOnTheOldSide() async throws {
        let repo = try await TempRepo()
        try await repo.write("f.txt", numbered(1...30))
        try await repo.commit("base")
        var lines = (1...30).map { "line \($0)" }
        lines.remove(at: 13)
        lines.remove(at: 9)
        try await repo.write("f.txt", lines.joined(separator: "\n") + "\n")
        let diff = await GitDiffEngine(watchesRepositories: false).diff(file: repo.url("f.txt"), base: .head)
        let hunk = try #require(diff.hunks.first)
        #expect(diff.hunks.count == 1 && hunk.mappings.count == 2)
        #expect(hunk.mentionLines.side == .old && hunk.mentionLines.lines == LineRange(start: 10, end: 14))
    }

    @Test func crlfLinesAndMissingFinalNewlinesRoundTrip() async throws {
        let repo = try await TempRepo()
        try await repo.git("config", "core.autocrlf", "false")
        let base = "keep\r\nold one\r\nold two\r\nkeep\r\nlast"
        try await repo.writeData("crlf.txt", Data(base.utf8))
        try await repo.writeData("eof.txt", Data("a\nb".utf8))
        try await repo.commit("base")
        try await repo.writeData("crlf.txt", Data("keep\r\nnew one\r\nkeep\r\nlast".utf8))
        try await repo.writeData("eof.txt", Data("a\nb\n".utf8))
        let engine = GitDiffEngine(watchesRepositories: false)

        let crlf = await engine.diff(file: repo.url("crlf.txt"), base: .head)
        #expect(crlf.mappings == [LineRangeMapping(original: 2..<4, modified: 2..<3)])
        #expect(crlf.old.text == base, "removed CRLF lines keep their CR and stay separate records")
        #expect(crlf.old.line(3) == "old two")

        let eof = await engine.diff(file: repo.url("eof.txt"), base: .head)
        #expect(eof.state == .modified)
        #expect(eof.old.text == "a\nb", "the base's missing final newline is preserved")
    }

    @Test func userInterHunkContextConfigDoesNotInventChanges() async throws {
        let repo = try await TempRepo()
        try await repo.git("config", "diff.interHunkContext", "10")
        try await repo.write("f.txt", numbered(1...20))
        try await repo.commit("base")
        var lines = (1...20).map { "line \($0)" }
        lines[2] = "three"
        lines[7] = "eight"
        try await repo.write("f.txt", lines.joined(separator: "\n") + "\n")
        let diff = await GitDiffEngine(watchesRepositories: false).diff(file: repo.url("f.txt"), base: .head)
        #expect(diff.mappings == [LineRangeMapping(original: 3..<4, modified: 3..<4), LineRangeMapping(original: 8..<9, modified: 8..<9)])
        #expect(diff.old.text == numbered(1...20))
    }

    @Test func modeOnlyChangesAndQuotedNamesAreNotMisread() async throws {
        let repo = try await TempRepo()
        try await repo.write("tool.sh", "echo hi\n")
        try await repo.write("a\"b\tc.txt", numbered(1...3))
        try await repo.commit("base")
        try await repo.git("update-index", "--chmod=+x", "tool.sh")
        _ = chmod(repo.url("tool.sh").path, 0o755)
        try await repo.write("a\"b\tc.txt", numbered(1...4))
        let engine = GitDiffEngine(watchesRepositories: false)
        #expect(await engine.diff(file: repo.url("tool.sh"), base: .head).state == .unchanged, "an exec-bit change is not a new file")
        let quoted = await engine.diff(file: repo.url("a\"b\tc.txt"), base: .head)
        #expect(quoted.state == .modified)
        #expect(quoted.mappings == [LineRangeMapping(original: 4..<4, modified: 4..<5)])
    }

    @Test func submodulesAndOversizedBasesGetExplicitStates() async throws {
        let inner = try await TempRepo()
        try await inner.write("x.txt", "x\n")
        try await inner.commit("inner")
        let repo = try await TempRepo()
        try await repo.write("big.txt", String(repeating: "0123456789abcdef\n", count: (GitDiffEngine.maxFileSize / 17) + 10))
        try await repo.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", inner.root.path, "sub")
        try await repo.commit("base")
        try await inner.write("x.txt", "y\n")
        let moved = try await inner.commit("moved")
        try await TempRepo.run(["-c", "protocol.file.allow=always", "fetch", "-q", "origin"], in: repo.url("sub"))
        try await TempRepo.run(["checkout", "-q", moved], in: repo.url("sub"))
        try FileManager.default.removeItem(at: repo.url("big.txt"))

        let engine = GitDiffEngine(watchesRepositories: false)
        #expect(await engine.diff(file: repo.url("sub"), base: .head).state == .submodule)
        try FileManager.default.removeItem(at: repo.url("sub"))
        #expect(await engine.diff(file: repo.url("sub"), base: .head).state == .submodule, "a gitlink in the base is not text even when absent on disk")
        #expect(await engine.diff(file: repo.url("big.txt"), base: .head).state == .tooLarge, "a deleted file larger than the limit is never loaded")
    }

    @Test func patchesThatDontDescribeTheCapturedTextAreRejected() throws {
        let new = SideText("one\n")
        // A patch taken after the file grew to three lines.
        let patch = Data("@@ -1,0 +2,2 @@\n+two\n+three\n".utf8)
        #expect(UnifiedDiff.reconstructOld(new: new, parsed: UnifiedDiff.parse(patch)) == nil)
        // A gitlink's short diff against an empty working-tree view.
        let gitlink = Data("@@ -1 +1 @@\n-Subproject commit 1111111111111111111111111111111111111111\n+Subproject commit 2222222222222222222222222222222222222222\n".utf8)
        #expect(UnifiedDiff.reconstructOld(new: SideText(""), parsed: UnifiedDiff.parse(gitlink)) == nil)
    }
}
