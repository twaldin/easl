import Foundation
import Testing
@testable import CanvasCore

/// The single code view: gitsigns against the diff base, peek rows, plain-source fallbacks, and
/// what one write changed.
struct GitSignTests {
    @Test func signsMarkAddedModifiedAndDeletedLinesIncludingFileEdges() async throws {
        let repo = try await TempRepo()
        try await repo.write("f.txt", numbered(1...40))
        try await repo.commit("base")
        var lines = (1...40).map { "line \($0)" }
        lines[4] = "line 5 changed"
        lines.insert(contentsOf: ["new a", "new b"], at: 10)
        lines.removeSubrange(21...22) // old 20-21
        lines.removeLast() // old 40, the last line
        lines.removeFirst() // old 1, the first line
        try await repo.write("f.txt", lines.joined(separator: "\n") + "\n")

        let diff = await GitDiffEngine(watchesRepositories: false).diff(file: repo.url("f.txt"), base: .head)
        let document = CodeDocument(path: "f.txt", diff: diff)
        #expect(document.text.lineCount == 38)
        #expect(document.signs == [
            GitSign(kind: .deleted, lines: 1..<1, old: 1..<2),
            GitSign(kind: .modified, lines: 4..<5, old: 5..<6),
            GitSign(kind: .added, lines: 10..<12, old: 11..<11),
            GitSign(kind: .deleted, lines: 21..<21, old: 20..<22),
            GitSign(kind: .deleted, lines: 39..<39, old: 40..<41),
        ])
        #expect(document.text.line(4) == "line 5 changed" && document.text.line(21) == "line 22", "a deletion's wedge sits on the top edge of the line after it")
        #expect(document.sign(at: 1) == 0, "the file-start wedge belongs to line 1")
        #expect(document.sign(at: 11) == 2 && document.sign(at: 12) == nil)
        #expect(document.sign(at: 39) == 4, "the file-end wedge sits below the last line")
        #expect(document.warning == nil && document.mentionCommit == diff.base)

        #expect(document.changeLine(after: 4, forward: true) == 10)
        #expect(document.changeLine(after: 4, forward: false) == 1)
        #expect(document.changeLine(after: 38, forward: true) == 1, "↓ wraps to the first change")
        #expect(document.changeLine(after: 1, forward: false) == 38, "↑ wraps; the end-of-file wedge jumps to the last line")
    }

    @Test func crlfAndMissingFinalNewlineSignsPeekTheBaseLinesWithoutTheirBreaks() async throws {
        let repo = try await TempRepo()
        try await repo.git("config", "core.autocrlf", "false")
        try await repo.writeData("crlf.txt", Data("keep\r\nold one\r\nold two\r\nkeep\r\nlast".utf8))
        try await repo.writeData("eof.txt", Data("a\nb".utf8))
        try await repo.commit("base")
        try await repo.writeData("crlf.txt", Data("keep\r\nnew one\r\nkeep\r\nlast".utf8))
        try await repo.writeData("eof.txt", Data("a\nb\nc".utf8))
        let engine = GitDiffEngine(watchesRepositories: false)

        let crlf = CodeDocument(path: "crlf.txt", diff: await engine.diff(file: repo.url("crlf.txt"), base: .head))
        #expect(crlf.signs == [GitSign(kind: .modified, lines: 2..<3, old: 2..<4)])
        let rows = CodeRows(lineCount: crlf.text.lineCount, signs: crlf.signs, peeked: [0])
        #expect((0..<rows.count).compactMap(rows.row) == [.line(1), .peek(old: 2, sign: 0), .peek(old: 3, sign: 0), .line(2), .line(3), .line(4)])
        #expect(crlf.diff.old.line(3) == "old two" && crlf.text.line(2) == "new one")

        let eof = CodeDocument(path: "eof.txt", diff: await engine.diff(file: repo.url("eof.txt"), base: .head))
        #expect(eof.text.lineCount == 3)
        #expect(eof.signs == [GitSign(kind: .modified, lines: 2..<4, old: 2..<3)], "b gained a newline and c follows it")
        #expect(eof.diff.old.line(2) == "b")
    }

    @Test func peekRowsExpandAboveTheirChangeAndCollapse() {
        let signs = [
            GitSign(kind: .deleted, lines: 1..<1, old: 1..<3),
            GitSign(kind: .modified, lines: 4..<6, old: 5..<6),
            GitSign(kind: .added, lines: 8..<9, old: 10..<10),
            GitSign(kind: .deleted, lines: 11..<11, old: 12..<14),
        ]
        let closed = CodeRows(lineCount: 10, signs: signs)
        #expect(closed.count == 10 && closed.row(3) == .line(4) && closed.row(10) == nil)

        let open = CodeRows(lineCount: 10, signs: signs, peeked: [0, 1, 2, 3])
        #expect(open.peekedSigns == [0, 1, 3], "additions have no base lines to peek")
        #expect(open.count == 15)
        #expect((0..<open.count).compactMap(open.row) == [
            .peek(old: 1, sign: 0), .peek(old: 2, sign: 0),
            .line(1), .line(2), .line(3),
            .peek(old: 5, sign: 1),
            .line(4), .line(5), .line(6), .line(7), .line(8), .line(9), .line(10),
            .peek(old: 12, sign: 3), .peek(old: 13, sign: 3),
        ])
        #expect(open.index(ofLine: 1) == 2 && open.index(ofLine: 4) == 6 && open.index(ofLine: 10) == 12)
        #expect(open.index(ofPeek: 1, old: 5) == 5 && open.index(ofPeek: 3, old: 13) == 14)
        #expect(open.index(ofPeek: 1, old: 6) == nil && open.index(ofPeek: 2, old: 10) == nil)

        let one = CodeRows(lineCount: 10, signs: signs, peeked: [1])
        #expect(one.index(ofLine: 3) == 2 && one.index(ofLine: 4) == 4, "only rows below a peek shift")
    }

    @Test func peekRowsTakeBaseSideHighlighting() {
        let old = SideText("let a = 1\nlet b = \"x\"\n")
        let new = SideText("let a = 1\nvar b = 2\n")
        let diff = FileDiff(state: .modified, base: "abc", baseLabel: "HEAD", old: old, new: new, hunks: [DiffHunk(mappings: [LineRangeMapping(original: 2..<3, modified: 2..<3)])])
        let document = CodeDocument(path: "a.swift", diff: diff)
        func style(_ lines: SyntaxLines, line: Int, at offset: Int) -> SyntaxStyle? {
            lines.runs(line: line).first { $0.start <= offset && offset < $0.end }?.style
        }
        #expect(style(document.oldSyntax, line: 2, at: 9) == .string, "the peeked base line keeps its string highlight")
        #expect(style(document.syntax, line: 2, at: 0) == .keyword)
        #expect(style(document.syntax, line: 2, at: 8) == .number)
    }

    @Test func noCommitsNoDefaultBranchAndOversizedDiffsShowPlainSource() async throws {
        let engine = GitDiffEngine(watchesRepositories: false)

        let unborn = try await TempRepo()
        try await unborn.write("a.py", "print(1)\nprint(2)\n")
        let fresh = CodeDocument(path: "a.py", diff: await engine.diff(file: unborn.url("a.py"), base: .mergeBase))
        #expect(fresh.diff.state == .noBase && fresh.signs.isEmpty && fresh.text.lineCount == 2)
        #expect(fresh.mentionCommit == nil)

        let branchOnly = try await TempRepo(branch: "dev")
        try await branchOnly.write("a.txt", numbered(1...3))
        try await branchOnly.commit("base")
        try await branchOnly.write("a.txt", numbered(1...4))
        let orphan = CodeDocument(path: "a.txt", diff: await engine.diff(file: branchOnly.url("a.txt"), base: .mergeBase))
        #expect(orphan.diff.state == .noBase && orphan.signs.isEmpty && orphan.text.lineCount == 4)
        let head = CodeDocument(path: "a.txt", diff: await engine.diff(file: branchOnly.url("a.txt"), base: .head))
        #expect(head.signs == [GitSign(kind: .added, lines: 4..<5, old: 4..<4)], "HEAD is still a base without a default branch")

        let big = try await TempRepo()
        try await big.write("big.txt", String(repeating: "0123456789abcdef\n", count: (GitDiffEngine.maxFileSize / 17) + 10))
        try await big.commit("base")
        try await big.write("big.txt", "small now\n")
        let shrunk = CodeDocument(path: "big.txt", diff: await engine.diff(file: big.url("big.txt"), base: .head))
        #expect(shrunk.diff.state == .diffTooLarge && shrunk.signs.isEmpty)
        #expect(shrunk.text.line(1) == "small now")
    }

    @Test func deletedFilesShowTheBaseVersionReadOnly() async throws {
        let repo = try await TempRepo()
        try await repo.write("gone.txt", numbered(1...3))
        let base = try await repo.commit("base")
        try FileManager.default.removeItem(at: repo.url("gone.txt"))
        let document = CodeDocument(path: "gone.txt", diff: await GitDiffEngine(watchesRepositories: false).diff(file: repo.url("gone.txt"), base: .head))
        #expect(document.side == .old && document.text.line(3) == "line 3")
        #expect(document.signs.isEmpty)
        #expect(document.mentionCommit == base, "its lines are mentioned at the base they come from")
    }
}

/// A code tile pinned to a commit (`pinnedCommit`) shows the file as of that commit.
struct PinnedCodeTests {
    @Test func aPinnedTileShowsTheFileAtItsCommitReadOnlyWithoutADiff() async throws {
        let repo = try await TempRepo()
        try await repo.write("f.txt", numbered(1...10))
        let old = try await repo.commit("old")
        try await repo.git("tag", "v1")
        var lines = (1...10).map { "line \($0)" }
        lines[2] = "line 3 changed"
        lines.append("line 11")
        try await repo.write("f.txt", lines.joined(separator: "\n") + "\n")
        try await repo.commit("new")
        try await repo.write("f.txt", "working tree only\n")
        let engine = GitDiffEngine(watchesRepositories: false)

        for revision in [old, String(old.prefix(9)), "v1", "HEAD~1"] {
            let document = CodeDocument(path: "f.txt", diff: await engine.pinned(file: repo.url("f.txt"), revision: revision))
            #expect(document.isPinned && document.text.text == numbered(1...10), "\(revision)")
            #expect(document.signs.isEmpty && document.notice == nil, "no working-tree diff gutter")
            #expect(document.mentionCommit == old, "mentions read the pinned lines at the commit")
        }
        let head = CodeDocument(path: "f.txt", diff: await engine.pinned(file: repo.url("f.txt"), revision: "HEAD"))
        #expect(head.text.lineCount == 11 && head.text.line(3) == "line 3 changed")

        for (revision, path) in [("0000000", "f.txt"), ("--output=x", "f.txt"), (old, "g.txt")] {
            let document = CodeDocument(path: path, diff: await engine.pinned(file: repo.url(path), revision: revision))
            #expect(!document.isPinned && document.notice != nil && document.text.lineCount == 0, "\(revision) \(path)")
        }
    }
}

struct EditFlashTests {
    @Test func aWriteFlashesOnlyTheLinesItInsertedOrReplaced() throws {
        let before = SideText(numbered(1...20))
        var lines = (1...20).map { "line \($0)" }
        lines[2] = "three"
        lines.insert(contentsOf: ["x", "y"], at: 10)
        let after = SideText(lines.joined(separator: "\n") + "\n")
        let edit = try #require(CodeEdits.changes(from: before, to: after))
        #expect(edit.lines == [3..<4, 11..<13], "unchanged lines between two edits don't flash")
        #expect(edit.first == 3)

        lines.removeSubrange(15...16)
        let deleted = try #require(CodeEdits.changes(from: after, to: SideText(lines.joined(separator: "\n") + "\n")))
        #expect(deleted.lines.isEmpty && deleted.first == 16, "a pure deletion flashes nothing and jumps to where it was")

        #expect(CodeEdits.changes(from: before, to: SideText(numbered(1...20))) == nil)
        #expect(CodeEdits.changes(from: SideText("a\r\nb\r\n"), to: SideText("a\r\nb")) == nil, "line breaks alone change no row")

        let fresh = try #require(CodeEdits.changes(from: SideText(""), to: SideText("one\ntwo\n")))
        #expect(fresh.lines == [1..<3] && fresh.first == 1, "a new file flashes every line")
    }

    @Test func consecutiveLoadsOfAnEditedFileFlashTheEdit() async throws {
        let repo = try await TempRepo()
        try await repo.write("f.swift", numbered(1...30))
        try await repo.commit("base")
        try await repo.write("f.swift", numbered(1...30).replacingOccurrences(of: "line 7\n", with: "line seven\n"))
        let engine = GitDiffEngine(watchesRepositories: false)
        let first = CodeDocument(path: "f.swift", diff: await engine.diff(file: repo.url("f.swift"), base: .head))
        // The agent's next edit, on top of an earlier one the gutter already shows.
        try await repo.write("f.swift", numbered(1...30).replacingOccurrences(of: "line 7\n", with: "line seven\n").replacingOccurrences(of: "line 20\n", with: "line 20\nextra\n"))
        let second = CodeDocument(path: "f.swift", diff: await engine.diff(file: repo.url("f.swift"), base: .head))
        let edit = try #require(CodeEdits.changes(from: first.text, to: second.text))
        #expect(edit.lines == [21..<22] && edit.first == 21, "only this edit flashes, not every change since the base")
        #expect(second.signs.map(\.kind) == [.modified, .added])
    }
}

struct FollowLockTests {
    @Test func interactionHoldsReaimsThenResumesAtTheNewest() {
        var lock = FollowLock(showing: "a.swift:1", hold: 10)
        #expect(lock.aim("a.swift:5", at: 0) == "a.swift:5", "not held: re-aims show at once")

        lock.interact(at: 1)
        #expect(lock.isHeld(at: 10.9) && !lock.isHeld(at: 11))
        #expect(lock.aim("b.swift:2", at: 2) == nil)
        #expect(lock.aim("b.swift:2", at: 3) == nil)
        #expect(lock.aim("c.swift:9", at: 4) == nil)
        #expect(lock.missed == 2 && lock.shown == "a.swift:5", "repeats of the newest aim aren't new")

        lock.interact(at: 8)
        #expect(lock.resume(at: 11) == nil, "interacting again extends the hold")
        #expect(lock.resume(at: 18) == "c.swift:9")
        #expect(lock.missed == 0 && !lock.isHeld(at: 18))
        #expect(lock.aim("d.swift:1", at: 19) == "d.swift:1")
    }

    @Test func catchingUpAndAimingByHandEndTheQueue() {
        var lock = FollowLock(showing: "a:1", hold: 10)
        lock.interact(at: 0)
        _ = lock.aim("b:1", at: 1)
        #expect(lock.catchUp() == "b:1")
        #expect(!lock.isHeld(at: 2) && lock.aim("c:1", at: 2) == "c:1")

        lock.interact(at: 3)
        _ = lock.aim("d:1", at: 4)
        lock.userAimed("a:40")
        #expect(lock.shown == "a:40" && lock.missed == 0, "the user's own jump drops the agent's queue")
        #expect(lock.isHeld(at: 5), "and keeps holding while they read")
        #expect(lock.resume(at: 13) == nil && lock.shown == "a:40")
        #expect(lock.catchUp() == nil)
    }
}

@MainActor
struct CodeTileBoardTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-tests-\(UUID().uuidString)")

    @Test func followTilesAndPinsCarryNoViewMode() throws {
        let board = Board(id: "brd_test", root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("a.ts").path, contents: Data("x\n".utf8))
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/"), "command": .array([])]))
        let follow = try #require(try board.follow(tile: terminal.id, path: "a.ts", range: LineRange(start: 3, end: 4), action: "write"))
        #expect(Set(follow.props.object?.keys.map { $0 } ?? []) == ["path", "range", "followOf", "lastAction", "history", "diffBase"])
        #expect(follow.props["lastAction"] == .string("write"))
        try board.update(follow.id, props: .object(["diffBase": .string("head")]))

        // The user held the tile on an earlier location; the pin keeps what they see.
        let pinned = try board.pin(follow.id, path: "b.ts", range: LineRange(start: 7, end: 7))
        #expect(pinned.type == .code)
        #expect(pinned.props == .object(["path": .string("b.ts"), "range": .object(["start": .number(7), "end": .number(7)]), "diffBase": .string("head")]))
        #expect(!pinned.frame.intersects(follow.frame), "the pin opens beside the follow tile")
    }
}

/// What `view.render` reports for a code tile: the range it is aimed at, as `size: "fit"` sizes it.
@MainActor
struct CodeContentTests {
    @Test func renderContentIsTheRangeMeasureFitsNotTheWholeFile() async throws {
        let repo = try await TempRepo()
        var lines = (1...300).map { "line \($0)" }
        lines[11] = "\t" + String(repeating: "x", count: 60)
        lines[199] = String(repeating: "y", count: 400)
        try await repo.write("f.txt", lines.joined(separator: "\n") + "\n")
        _ = try await repo.commit("base")
        let document = CodeDocument(path: "f.txt", diff: await GitDiffEngine(watchesRepositories: false).diff(file: repo.url("f.txt"), base: .head))
        let header = CodeMetrics.headerHeight
        func body(_ start: Int, _ end: Int) async throws -> (content: CGSize, measured: CGSize) {
            let props: JSONValue = .object(["path": "f.txt", "range": .object(["start": .number(Double(start)), "end": .number(Double(end))])])
            let measured = try await ObjectMeasure.size(type: .code, props: props, width: nil, root: repo.root)
            let rows = document.rows(peeked: [], width: measured.width)
            return (document.content(range: LineRange(start: start, end: end), rows: rows, width: measured.width, headerHeight: header), measured)
        }

        let (content, measured) = try await body(10, 19)
        #expect(content.width == measured.width && content.height + CodeMetrics.titleHeight == measured.height, "a fit tile's body has no overflow")
        // Line 200's 400 columns wrap at the default 1546 pt (200 columns, continuation rows 198)
        // onto 3 rows; the fit tile and its render agree on them.
        let (wrapped, wrappedFit) = try await body(195, 204)
        #expect(wrappedFit.width == CodeMetrics.defaultFitWidth && wrapped.height == header + 2 * CodeMetrics.verticalPadding + 12 * CodeMetrics.rowHeight)
        #expect(wrapped.height + CodeMetrics.titleHeight == wrappedFit.height)

        let whole = document.content(range: nil, rows: document.rows(peeked: [], width: 960), width: 960, headerHeight: header)
        #expect(whole.height == header + 2 * CodeMetrics.verticalPadding + 303 * CodeMetrics.rowHeight && whole.width == 960, "never wider than the tile: rows wrap")
        #expect(content.height < whole.height / 20 && content.width < whole.width / 1.5, "the range, not the file's 300 rows and 400-column line 200")
    }
}
