import Foundation
import Testing
@testable import CanvasCore

@MainActor
final class CodeAnchorPolicyTests {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-code-policy-\(UUID().uuidString)")
    let board: Board

    init() throws {
        let root = dir.appendingPathComponent("board")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        board = Board(id: "brd_code_policy", root: root)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func props(_ path: String, start: Int = 1, end: Int = 1) -> JSONValue {
        .object(["path": .string(path), "range": LineRange(start: start, end: end).json])
    }

    @Test func createUpdateAndReloadRefuseOutsideAnchorsButKeepLocalReadsAndAuthoredAnchors() async throws {
        let outside = dir.appendingPathComponent("outside.txt")
        try write(outside, "OUTSIDE_CODE_MARKER\n")
        try write(board.root.appendingPathComponent("inside.txt"), "inside\n")
        try FileManager.default.createSymbolicLink(atPath: board.root.appendingPathComponent("escape.txt").path, withDestinationPath: outside.path)
        for path in [outside.path, "../outside.txt", "escape.txt"] {
            let tile = board.create(type: .code, props: props(path))
            let refused = try #require(try await board.reanchor(tile.id, captured: ["OUTSIDE_CODE_MARKER"]))
            #expect(refused.refused && refused.lines == [] && refused.range == nil)
            #expect(refused.status == .stale("path refused"))
            #expect(board.objects[tile.id]?.props == tile.props)

            try board.update(tile.id, props: props("inside.txt"))
            try await board.reanchor(tile.id)
            #expect(board.objects[tile.id]?.props["anchor"] == "inside")
            let updated = try board.update(tile.id, props: props(path))
            try await board.reanchor(tile.id)
            #expect(board.objects[tile.id]?.props == updated.props)

            let authored = try board.update(tile.id, props: .object(["anchor": "explicit authored anchor"]))
            try await board.reanchor(tile.id, captured: ["OUTSIDE_CODE_MARKER"])
            #expect(board.objects[tile.id]?.props == authored.props)
            let unanchored = await NoteSource.excerpt(for: try #require(CodeAnchor.fence(props(path))), root: board.root, captured: nil)
            #expect(unanchored.lines == ["OUTSIDE_CODE_MARKER"], "local display is intentionally broader than persisted metadata")
        }
    }

    @Test func insideCapturedTextRelocatesAndResizesAsBookkeeping() async throws {
        let file = board.root.appendingPathComponent("inside.txt")
        try write(file, "start\nbody\nend\n")
        let tile = board.create(type: .code, props: props("inside.txt", end: 3))
        let first = try #require(try await board.reanchor(tile.id))
        #expect(first.lines == ["start", "body", "end"] && first.range == LineRange(start: 1, end: 3))
        #expect(board.objects[tile.id]?.props["anchor"] == "start")
        let steps = board.history.undoSteps.count
        try write(file, "start\nunrelated\n\nstart\nbody\ninserted\nend\n")
        let moved = try #require(try await board.reanchor(tile.id, captured: first.lines))
        #expect(moved.range == LineRange(start: 4, end: 7))
        #expect(moved.lines == ["start", "body", "inserted", "end"])
        #expect(board.objects[tile.id]?.props["range"] == LineRange(start: 4, end: 7).json)
        #expect(board.objects[tile.id]?.props["anchor"] == "start")
        #expect(board.objects[tile.id]?.rev == tile.rev)
        #expect(board.history.undoSteps.count == steps)
    }

    @Test func metadataReadsTheAuthorizedFileNotAnEarlierUnrestrictedDisplay() async throws {
        let file = board.root.appendingPathComponent("inside.txt")
        let outside = dir.appendingPathComponent("outside.txt")
        try write(file, "safe\n")
        try write(outside, "OUTSIDE_CODE_MARKER\n")
        let tile = board.create(type: .code, props: props("inside.txt"))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: outside.path)
        let display = await NoteSource.excerpt(for: try #require(CodeAnchor.fence(tile.props)), root: board.root, captured: nil)
        #expect(display.lines == ["OUTSIDE_CODE_MARKER"])
        try FileManager.default.removeItem(at: file)
        try write(file, "safe now\n")
        let reread = try #require(try await board.reanchor(tile.id))
        #expect(reread.lines == ["safe now"])
        #expect(board.objects[tile.id]?.props["anchor"] == "safe now")

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: outside.path)
        let before = try board.object(tile.id)
        let refused = try #require(try await board.reanchor(tile.id, captured: reread.lines))
        #expect(refused.status == .stale("path refused"))
        #expect(board.objects[tile.id] == before)
    }

    @Test func registeredWorktreesRefsAndCommitFallbackUseOnlyTheBoardsPlace() async throws {
        let repo = try await TempRepo()
        let worktree = URL(fileURLWithPath: repo.root.path + "-code-policy")
        defer { for root in [repo.root, worktree] { try? FileManager.default.removeItem(at: root) } }
        try await repo.write("nested/a.txt", "committed\nbody\n")
        try await repo.write("outside.txt", "OUTSIDE_CODE_MARKER\n")
        try FileManager.default.createSymbolicLink(atPath: repo.url("nested/escape.txt").path, withDestinationPath: "../outside.txt")
        let sha = try await repo.commit("base")
        try await repo.git("worktree", "add", "-q", "-b", "code-policy", worktree.path)
        let board = Board(id: "brd_nested", root: repo.url("nested"))
        let file = worktree.appendingPathComponent("nested/a.txt")
        try write(file, "live\nbody\n")
        let direct = board.create(type: .code, props: props(file.path, end: 2))
        let first = try #require(try await board.reanchor(direct.id))
        #expect(first.lines == ["live", "body"])
        try write(file, "inserted\nlive\nbody\n")
        let moved = try #require(try await board.reanchor(direct.id, captured: first.lines))
        #expect(moved.range == LineRange(start: 2, end: 3))
        #expect(board.objects[direct.id]?.props["range"] == LineRange(start: 2, end: 3).json)
        #expect(board.objects[direct.id]?.props["anchor"] == "live")

        let branch = board.create(type: .code, props: props(repo.url("nested/a.txt").path, start: 2, end: 3).merging(.object(["ref": "code-policy", "refSha": .string(sha)])))
        try await board.reanchor(branch.id)
        #expect(board.objects[branch.id]?.props["anchor"] == "live")
        for path in ["../outside.txt", worktree.appendingPathComponent("outside.txt").path, "escape.txt"] {
            let tile = board.create(type: .code, props: props(path).merging(.object(["ref": "code-policy", "anchor": "authored"])))
            let refusal = try #require(try await board.reanchor(tile.id))
            #expect(refusal.refused && refusal.status == .stale("path refused"))
            #expect(board.objects[tile.id]?.props == tile.props)
        }

        try await repo.git("worktree", "remove", "--force", worktree.path)
        try await repo.git("branch", "-D", "code-policy")
        let fallback = board.create(type: .code, props: props("a.txt", end: 2).merging(.object(["ref": "code-policy", "refSha": .string(sha)])))
        let committed = try #require(try await board.reanchor(fallback.id))
        #expect(committed.lines == ["committed", "body"])
        #expect(board.objects[fallback.id]?.props["anchor"] == "committed")
        let link = board.create(type: .code, props: props("escape.txt").merging(.object(["ref": "code-policy", "refSha": .string(sha), "anchor": "authored"])))
        let refused = try #require(try await board.reanchor(link.id))
        #expect(refused.refused && refused.lines == [])
        #expect(board.objects[link.id]?.props == link.props)
        let beside = board.create(type: .code, props: props("../outside.txt").merging(.object(["ref": "code-policy", "refSha": .string(sha)])))
        #expect(try await board.reanchor(beside.id)?.refused == true)
        #expect(board.objects[beside.id]?.props == beside.props)
    }

    @Test func aSuspendedReadCannotOverwriteANewPathRangeOrRef() async throws {
        let repo = try await TempRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        try await repo.write("a.txt", "first\nsecond\n")
        try await repo.write("b.txt", "other\n")
        try await repo.commit("base")
        try await repo.git("branch", "snapshot")
        let board = Board(id: "brd_fresh", root: repo.root)
        let changes: [JSONValue] = [
            .object(["path": "b.txt", "anchor": "authored path"]),
            .object(["range": LineRange(start: 2, end: 2).json, "anchor": "authored range"]),
            .object(["ref": .null, "anchor": "authored ref"]),
        ]
        for change in changes {
            let tile = board.create(type: .code, props: props("a.txt").merging(.object(["ref": "snapshot"])))
            var pending: Task<NoteExcerpt?, Error>!
            await withCheckedContinuation { started in
                pending = Task { @MainActor in
                    started.resume()
                    return try await board.reanchor(tile.id)
                }
            }
            let updated = try board.update(tile.id, props: change)
            #expect(try await pending.value == nil)
            #expect(board.objects[tile.id]?.props == updated.props)
            try board.update(tile.id, props: .object(["anchor": .null]))
            try await board.reanchor(tile.id)
            #expect(board.objects[tile.id]?.props["anchor"] == (change["path"] != nil ? "other" : change["range"] != nil ? "second" : "first"))
        }
    }

    @Test func pinnedAndFollowTilesStayExcludedAndCancelledReadsDoNotWrite() async throws {
        try write(board.root.appendingPathComponent("inside.txt"), "inside\n")
        for exclusion in [JSONValue.object(["pinnedCommit": "HEAD"]), .object(["followOf": "obj_terminal"])] {
            let tile = board.create(type: .code, props: props("inside.txt").merging(exclusion))
            await #expect(throws: BoardError.self) { try await board.reanchor(tile.id) }
            #expect(board.objects[tile.id]?.props == tile.props)
        }
        let tile = board.create(type: .code, props: props("inside.txt"))
        let pending = Task { try await board.reanchor(tile.id) }
        pending.cancel()
        #expect(try await pending.value == nil)
        #expect(board.objects[tile.id]?.props == tile.props)
        try await board.reanchor(tile.id)
        #expect(board.objects[tile.id]?.props["anchor"] == "inside")
    }
}
