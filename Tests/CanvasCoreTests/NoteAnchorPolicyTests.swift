import Foundation
import Testing
@testable import CanvasCore

/// What the app writes into a note (`anchor=`) and reports for it (`object.get`'s `fences`)
/// stays inside the board's areas (`BoardAreas`), whatever file the note names or its tile shows.
@MainActor
final class NoteAnchorPolicyTests {
    static let marker = "DO_NOT_SHOW_OUTSIDE_HOST_68c1"
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-policy-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let router: ApiRouter
    let server: SocketServer
    let board: Board

    init() async throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("board/src"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards"), debounce: 60))
        board = await registry.open(root: dir.appendingPathComponent("board"))
        let router = ApiRouter(registry: registry)
        self.router = router
        server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func write(_ url: URL, _ lines: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// One API call; its result, with the whole reply's text to search.
    func call(_ method: String, _ params: [String: JSONValue]) async throws -> (result: JSONValue, text: String) {
        let client = try LineClient(path: dir.appendingPathComponent("s").path)
        client.send(String(decoding: try JSONEncoder().encode(JSONValue.object(["id": "1", "method": .string(method), "params": .object(params)])), as: UTF8.self))
        let reply = try await client.next()
        #expect(reply["ok"] == .bool(true), "\(method): \(reply["error"] ?? .null)")
        return (reply["result"] ?? .null, String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))
    }

    func stored(_ props: [String: JSONValue], on board: Board) async throws -> String {
        let created = try await call("object.create", ["board": .string(board.id), "type": "note", "props": .object(props)])
        #expect(!created.text.contains(Self.marker))
        return try #require(created.result["object"]?["props"]?["markdown"]?.string)
    }

    @Test func absoluteTraversalAndSymlinkFencesGetNoAnchorAndObjectGetRefusesThem() async throws {
        try write(dir.appendingPathComponent("outside.rs"), [Self.marker])
        try write(board.root.appendingPathComponent("src/inside.rs"), ["fn inside() {}"])
        try FileManager.default.createSymbolicLink(atPath: board.root.appendingPathComponent("escape.rs").path, withDestinationPath: "../outside.rs")
        let outside = "```rs file=\(dir.path)/outside.rs#L1\n```\n\n```rs file=../outside.rs#L1\n```\n\n```rs file=escape.rs#L1\n```\n\n"
        let markdown = "Authored prose\n\n" + outside + "```rs file=src/inside.rs#L1\n```\n"
        let anchored = "Authored prose\n\n" + outside + "```rs file=src/inside.rs#L1 anchor=\"fn inside() {}\"\n```\n"

        let created = try await call("object.create", ["board": .string(board.id), "type": "note", "props": .object(["markdown": .string(markdown)])])
        #expect(created.result["object"]?["props"]?["markdown"] == .string(anchored))
        #expect(!created.text.contains(Self.marker))
        let id = try #require(created.result["object"]?["id"]?.string)
        let updated = try await call("object.update", ["id": .string(id), "rev": created.result["object"]?["rev"] ?? .null, "props": .object(["markdown": .string(markdown)])])
        #expect(updated.result["object"]?["props"]?["markdown"] == .string(anchored))
        #expect(!updated.text.contains(Self.marker))

        let got = try await call("object.get", ["id": .string(id)])
        let fences = try #require(got.result["fences"]?.array)
        #expect(fences.map { $0["state"]?.string } == ["stale", "stale", "stale", "live"])
        #expect(fences.map { $0["reason"]?.string } == [NoteSource.refusal, NoteSource.refusal, NoteSource.refusal, nil])
        #expect(fences.prefix(3).allSatisfy { $0["range"] == nil && $0["written"] == nil })
        #expect(!got.text.contains(Self.marker))
        let listed = try await call("board.get", ["board": .string(board.id)])
        #expect(!listed.text.contains(Self.marker))

        let shown = await NoteSource.excerpt(for: NoteFence(info: "rs file=../outside.rs#L1"), root: board.root, captured: nil)
        #expect(shown.lines == [Self.marker], "the tile itself still shows any file on this Mac")

        // A tile that shows every fence (here: as moved) is believed only where the board permits.
        let cache = Dictionary(uniqueKeysWithValues: NoteMarkdown.anchoredFences(in: NoteMarkdown.parse(anchored)).map { fence in
            (fence.key, NoteExcerpt(path: fence.fence.path ?? "", range: LineRange(start: 2, end: 2), lines: [Self.marker], status: .relocated(from: LineRange(start: 1, end: 1))))
        })
        router.noteExcerpts = { _, _ in cache }
        let cached = try #require(try await call("object.get", ["id": .string(id)]).result["fences"]?.array)
        #expect(cached.map { $0["state"]?.string } == ["stale", "stale", "stale", "relocated"])
        #expect(cached.map { $0["reason"]?.string } == [NoteSource.refusal, NoteSource.refusal, NoteSource.refusal, nil])
    }

    @Test func insideAnchorsRelocateAndRender() async throws {
        let file = board.root.appendingPathComponent("src/inside.rs")
        try write(file, ["fn inside() {", "    body()", "}"])
        let markdown = try await stored(["markdown": "```rs file=src/inside.rs#L1-3\n```\n"], on: board)
        #expect(markdown == "```rs file=src/inside.rs#L1-3 anchor=\"fn inside() {\"\n```\n")
        let id = try #require(board.objects.values.first { $0.type == .note }?.id)

        try write(file, ["// moved", "", "fn inside() {", "    body()", "}"])
        let fence = try #require(try await call("object.get", ["id": .string(id)]).result["fences"]?.array?.first)
        #expect(fence["state"] == "relocated" && fence["range"] == LineRange(start: 3, end: 5).json && fence["written"] == LineRange(start: 1, end: 3).json)

        let document = NoteMarkdown.parse(markdown)
        let excerpts = await NoteSource.excerpts(for: NoteMarkdown.anchoredFences(in: document), root: board.root, within: BoardAreas(boardRoot: board.root))
        let rendered = NoteRenderer(excerpts: excerpts, width: 400).render(document, placeholder: "").string
        #expect(rendered.contains("body()") && !rendered.contains("// moved"))
    }

    @Test func registeredWorktreesPinnedRevisionsRefsAndRootsStayInsideTheBoard() async throws {
        let outside = dir.appendingPathComponent("outside.rs")
        try write(outside, [Self.marker])
        let repo = try await TempRepo()
        let worktree = URL(fileURLWithPath: repo.root.path + "-wt")
        defer { for url in [repo.root, worktree] { try? FileManager.default.removeItem(at: url) } }
        try await repo.write("src/a.txt", "committed\n")
        try FileManager.default.createSymbolicLink(atPath: repo.url("link.txt").path, withDestinationPath: outside.path)
        let sha = try await repo.commit("base")
        try await repo.git("branch", "snapshot")
        try await repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        try "worktree\n".write(to: worktree.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repo.url("src/a.txt"))
        try FileManager.default.createSymbolicLink(atPath: repo.url("src/a.txt").path, withDestinationPath: outside.path)
        let clone = try await TempRepo(cloning: repo)
        defer { try? FileManager.default.removeItem(at: clone.root) }
        try await clone.write("src/a.txt", Self.marker + "\n")
        let board = await registry.open(root: repo.root)

        let live = "```txt file=src/a.txt#L1\n```\n\n```txt file=\(worktree.path)/src/a.txt#L1\n```\n\n```txt file=\(clone.root.path)/src/a.txt#L1\n```\n"
        #expect(try await stored(["markdown": .string(live)], on: board)
                == "```txt file=src/a.txt#L1\n```\n\n```txt file=\(worktree.path)/src/a.txt#L1 anchor=\"worktree\"\n```\n\n```txt file=\(clone.root.path)/src/a.txt#L1\n```\n",
                "a registered worktree is the board's; a live symlink out of it and another repository are not")
        #expect(try await stored(["markdown": "```txt file=src/a.txt#L1\n```\n", "root": .string(worktree.path)], on: board)
                == "```txt file=src/a.txt#L1 anchor=\"worktree\"\n```\n", "a link root in a registered worktree reads there")

        let atRef = "```txt file=src/a.txt#L1\n```\n\n```txt file=link.txt#L1\n```\n\n```txt file=../outside.rs#L1\n```\n"
        #expect(try await stored(["markdown": .string(atRef), "ref": "snapshot"], on: board)
                == "```txt file=src/a.txt#L1 anchor=\"committed\"\n```\n\n```txt file=link.txt#L1\n```\n\n```txt file=../outside.rs#L1\n```\n",
                "at a commit: the committed file despite the live symlink, never a committed symlink or a path out")

        let pinned = "```txt file=src/a.txt@\(sha)#L1\n```\n\n```txt file=link.txt@\(sha)#L1\n```\n\n```txt file=src/a.txt#L1\n```\n"
        #expect(try await stored(["markdown": .string(pinned)], on: board) == pinned)
        let id = try #require(board.objects.values.first { $0.props["markdown"]?.string == pinned }?.id)
        let got = try await call("object.get", ["id": .string(id)])
        let fences = try #require(got.result["fences"]?.array)
        #expect(fences.map { $0["state"]?.string } == ["live", "stale", "stale"])
        #expect(fences.map { $0["reason"]?.string } == [nil, NoteSource.refusal, NoteSource.refusal])
        #expect(!got.text.contains(Self.marker))
        let listed = try await call("board.get", ["board": .string(board.id)])
        #expect(!listed.text.contains(Self.marker))
    }

    @Test func aSubdirectoryBoardPermitsItsPlaceInEachWorktreeAndNoOtherSourceRoot() async throws {
        let repo = try await TempRepo()
        let worktree = URL(fileURLWithPath: repo.root.path + "-wt")
        defer { for url in [repo.root, worktree] { try? FileManager.default.removeItem(at: url) } }
        try await repo.write("nested/a.txt", "nested\n")
        try await repo.write("outside.txt", Self.marker + "\n")
        try await repo.commit("base")
        try await repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        try "worktree nested\n".write(to: worktree.appendingPathComponent("nested/a.txt"), atomically: true, encoding: .utf8)
        let areas = BoardAreas(boardRoot: repo.url("nested"))
        func anchored(_ markdown: String, root: URL) async -> String {
            await NoteMarkdown.anchoringRanges(markdown, reading: LinkReading(root: root), within: areas)
        }

        #expect(await anchored("```txt file=\(worktree.path)/nested/a.txt#L1\n```\n", root: repo.url("nested"))
                == "```txt file=\(worktree.path)/nested/a.txt#L1 anchor=\"worktree nested\"\n```\n")
        #expect(await anchored("```txt file=a.txt#L1\n```\n", root: worktree.appendingPathComponent("nested"))
                == "```txt file=a.txt#L1 anchor=\"worktree nested\"\n```\n")
        let beside = "```txt file=\(worktree.path)/outside.txt#L1\n```\n"
        #expect(await anchored(beside, root: repo.url("nested")) == beside, "the worktree beyond the board's place in it")
        let traversal = "```txt file=../outside.txt#L1\n```\n"
        #expect(await anchored(traversal, root: repo.url("nested")) == traversal)
        let fromTop = "```txt file=nested/a.txt#L1\n```\n"
        #expect(await anchored(fromTop, root: repo.root) == fromTop, "a source root outside the areas anchors nothing, even a file inside")
    }

    @Test func capturedTextKeepsAMovedRangeUnanchoredAndNeverAnchorsOutside() async throws {
        let areas = BoardAreas(boardRoot: board.root)
        let reading = LinkReading(root: board.root)
        try write(board.root.appendingPathComponent("src/a.txt"), ["zero", "one", "two"])
        let markdown = "```txt file=src/a.txt#L2\n```\n"
        let key = try #require(NoteMarkdown.anchoredFences(in: NoteMarkdown.parse(markdown)).first?.key)
        #expect(await NoteMarkdown.anchoringRanges(markdown, reading: reading, within: areas, captured: [key: ["two"]]) == markdown,
                "the tile captured \"two\" here before a line went in above it")
        #expect(await NoteMarkdown.anchoringRanges(markdown, reading: reading, within: areas) == "```txt file=src/a.txt#L2 anchor=\"one\"\n```\n")

        try write(dir.appendingPathComponent("outside.rs"), [Self.marker])
        let outside = "```rs file=../outside.rs#L1\n```\n"
        let outsideKey = try #require(NoteMarkdown.anchoredFences(in: NoteMarkdown.parse(outside)).first?.key)
        #expect(await NoteMarkdown.anchoringRanges(outside, reading: reading, within: areas, captured: [outsideKey: [Self.marker]]) == outside)
    }
}
