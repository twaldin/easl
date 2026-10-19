import Darwin
import Foundation
import Testing
@testable import CanvasCore

@Suite(.serialized)
@MainActor
final class BoardAnchorLoadTests {
    let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-anchor-load-\(UUID().uuidString.prefix(8))")

    deinit { try? FileManager.default.removeItem(at: directory) }

    func store() -> BoardStore { BoardStore(directory: directory.appendingPathComponent("boards"), debounce: 60) }

    func makeBoard(root: URL? = nil) throws -> Board {
        let root = root ?? directory.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Board(id: BoardStore.boardID(for: root), root: root)
    }

    func persist(_ snapshot: BoardSnapshot, in store: BoardStore) throws {
        try FileManager.default.createDirectory(at: store.url(for: snapshot.id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try BoardStore.encoder.encode(snapshot).write(to: store.url(for: snapshot.id), options: .atomic)
    }

    @Test func loadScrubsOnlyMetadataBeforeFirstReplyAndPersistsExactlyOnce() async throws {
        let store = store()
        let board = try makeBoard()
        try "outside\n".write(to: directory.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: board.root.appendingPathComponent("escape.txt").path, withDestinationPath: "../outside.txt")
        let markdown = "Authored anchor=prose\r\n\r\n- > ~~~txt file=../outside.txt#L1 anchor=\"LEAKED_NOTE\"  caption='keep' anchor='DUPLICATE'\r\n  > authored anchor=body\r\n  > ~~~\r\n\r\n```txt file=escape.txt#L1 anchor=LEAKED_SYMLINK\r\n```\r\n\r\n```txt file=missing.txt#L1 anchor=KEEP_MISSING\r\n```\r\n"
        let cleaned = "Authored anchor=prose\r\n\r\n- > ~~~txt file=../outside.txt#L1   caption='keep' \r\n  > authored anchor=body\r\n  > ~~~\r\n\r\n```txt file=escape.txt#L1 \r\n```\r\n\r\n```txt file=missing.txt#L1 anchor=KEEP_MISSING\r\n```\r\n"
        let note = board.create(type: .note, props: .object(["markdown": .string(markdown), "caption": "Authored caption"]))
        let code = board.create(type: .code, props: .object(["path": "../outside.txt", "anchor": "LEAKED_CODE", "caption": "Authored code caption"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let terminal = board.create(type: .terminal, props: .object(["lifecycle": .object(["state": "working"])]))
        try board.stage(.object(note.id))
        var snapshot = board.snapshot
        snapshot.format = 1
        try persist(snapshot, in: store)
        snapshot = try BoardStore.decoder.decode(BoardSnapshot.self, from: Data(contentsOf: store.url(for: board.id)))
        let persistedNote = try #require(snapshot.objects.first { $0.id == note.id })
        var expected = snapshot
        for index in expected.objects.indices {
            if expected.objects[index].id == note.id { expected.objects[index].props = note.props.merging(.object(["markdown": .string(cleaned)])) }
            if expected.objects[index].id == code.id {
                var props = try #require(code.props.object)
                props.removeValue(forKey: "anchor")
                expected.objects[index].props = .object(props)
            }
        }

        let registry = BoardRegistry(store: store)
        let loaded = await registry.open(root: board.root)
        #expect(try loaded.object(note.id).props["markdown"] == .string(cleaned))
        #expect(try loaded.object(code.id).props["anchor"] == nil)
        #expect(loaded.revision == snapshot.revision)
        #expect(try loaded.object(note.id).rev == note.rev)
        #expect(try loaded.object(note.id).updatedAt == persistedNote.updatedAt)
        #expect(loaded.tray.map(\.id) == (snapshot.tray ?? []).map(\.id))
        #expect(!loaded.history.canUndo)
        #expect(try loaded.object(terminal.id).props["lifecycle"]?["restored"] == .bool(true))
        #expect(try Data(contentsOf: store.url(for: board.id)) == BoardStore.encoder.encode(expected), "persist the normalized snapshot, not unrelated live-board migrations")

        let router = ApiRouter(registry: registry)
        let socket = directory.appendingPathComponent("s").path
        let server = SocketServer(path: socket) { request, connection in await router.handle(request, connection: connection) }
        try server.start()
        defer { server.stop() }
        for (method, params) in [("board.get", ["board": JSONValue.string(board.id)]), ("object.get", ["id": JSONValue.string(note.id)]), ("object.get", ["id": JSONValue.string(code.id)])] {
            let client = try LineClient(path: socket)
            client.send(String(decoding: try JSONEncoder().encode(JSONValue.object(["id": "1", "method": .string(method), "params": .object(params)])), as: UTF8.self))
            let reply = try await client.next()
            #expect(reply["ok"] == .bool(true))
            let text = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
            #expect(!text.contains("LEAKED_") && !text.contains("DUPLICATE"))
        }

        let sentinel = Date(timeIntervalSince1970: 1234567890)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: store.url(for: board.id).path)
        let again = await store.load(root: board.root)
        #expect(try again.object(note.id).props["markdown"] == .string(cleaned))
        #expect(try store.url(for: board.id).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == sentinel)
        #expect(try Data(contentsOf: store.url(for: board.id)) == BoardStore.encoder.encode(expected))
    }

    @Test func encodedAttributesAndQuotesPreserveEveryOtherByte() async throws {
        let store = store()
        let board = try makeBoard()
        let markdown = #"~~~txt file=../outside.txt#L1 an&#99;hor=&quot;ENTITY value&quot; title="keep anchor=fake" anchor="first \\\" quoted" anchor=''  "# + "\r\nbody anchor=authored\r\n~~~\r\n" + #"```txt file=../outside.txt#L1 anchor\=&quot;ESCAPED key&quot; caption='stay'"# + "\r\n```\r\n"
        let expected = #"~~~txt file=../outside.txt#L1  title="keep anchor=fake"    "# + "\r\nbody anchor=authored\r\n~~~\r\n```txt file=../outside.txt#L1  caption='stay'\r\n```\r\n"
        let note = board.create(type: .note, props: .object(["markdown": .string(markdown)]))
        try persist(board.snapshot, in: store)
        let loaded = await store.load(root: board.root)
        #expect(try loaded.object(note.id).props["markdown"] == .string(expected))
    }

    @Test func insideReadFailuresAndOutsideLinkRootsAreDistinguished() async throws {
        let store = store()
        let board = try makeBoard()
        try Data([0xff]).write(to: board.root.appendingPathComponent("binary.txt"))
        try FileManager.default.createDirectory(at: board.root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let inside = "```txt file=missing.txt#L1 anchor=missing\n```\n```txt file=binary.txt#L1 anchor=binary\n```\n```txt file=folder#L1 anchor=directory\n```\n"
        let kept = board.create(type: .note, props: .object(["markdown": .string(inside)]))
        let outside = board.create(type: .note, props: .object(["root": "..", "markdown": "```txt file=root/missing.txt#L1 anchor=DROP\n```\n"]))
        let code = board.create(type: .code, props: .object(["path": "missing.txt", "anchor": "keep missing"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        try persist(board.snapshot, in: store)
        let loaded = await store.load(root: board.root)
        #expect(try loaded.object(kept.id).props == kept.props)
        #expect(try loaded.object(code.id).props == code.props)
        #expect(try loaded.object(outside.id).props["markdown"] == "```txt file=root/missing.txt#L1 \n```\n")
    }

    @Test func refsPinnedSymlinksAndRegisteredWorktreesUseTheSharedPolicy() async throws {
        let repo = try await TempRepo()
        let worktree = URL(fileURLWithPath: repo.root.path + "-load-wt")
        defer { for url in [repo.root, worktree] { try? FileManager.default.removeItem(at: url) } }
        try await repo.write("src/a.txt", "committed\n")
        try FileManager.default.createSymbolicLink(atPath: repo.url("link.txt").path, withDestinationPath: "src/a.txt")
        let sha = try await repo.commit("base")
        try await repo.git("branch", "snapshot")
        try await repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        try FileManager.default.removeItem(at: repo.url("src/a.txt"))
        try FileManager.default.createSymbolicLink(atPath: repo.url("src/a.txt").path, withDestinationPath: directory.appendingPathComponent("outside.txt").path)
        let store = store()
        let board = try makeBoard(root: repo.root)
        let markdown = "```txt file=src/a.txt@\(sha)#L1 anchor=KEEP_PINNED_REGULAR\n```\n```txt file=link.txt@\(sha)#L1 anchor=DROP_PINNED_SYMLINK\n```\n```txt file=missing.txt@\(sha)#L1 anchor=KEEP_PINNED_MISSING\n```\n"
        let pinned = board.create(type: .note, props: .object(["markdown": .string(markdown)]))
        let atRef = board.create(type: .note, props: .object(["ref": "snapshot", "root": "..", "markdown": "```txt file=src/a.txt#L1 anchor=KEEP_REF\n```\n```txt file=link.txt#L1 anchor=DROP_REF_SYMLINK\n```\n"]))
        let live = board.create(type: .note, props: .object(["ref": "feature", "markdown": .string("```txt file=src/a.txt#L1 anchor=KEEP_WORKTREE\n```\n```txt file=\(repo.url("src/a.txt").path)#L1 anchor=KEEP_REROOTED\n```\n")]))
        let rooted = board.create(type: .note, props: .object(["root": .string(worktree.path), "markdown": "```txt file=src/a.txt#L1 anchor=KEEP_ROOT\n```\n"]))
        let code = board.create(type: .code, props: .object(["path": "link.txt", "pinnedCommit": .string(sha), "anchor": "DROP_CODE_PINNED"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let refCode = board.create(type: .code, props: .object(["path": "src/a.txt", "ref": "snapshot", "anchor": "KEEP_CODE_REF"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        try persist(board.snapshot, in: store)
        let loaded = await store.load(root: repo.root)
        await loaded.waitForAnchorScrub()
        #expect(try loaded.object(pinned.id).props["markdown"] == .string(markdown.replacingOccurrences(of: "anchor=DROP_PINNED_SYMLINK", with: "")))
        #expect(try loaded.object(atRef.id).props["markdown"] == "```txt file=src/a.txt#L1 anchor=KEEP_REF\n```\n```txt file=link.txt#L1 \n```\n")
        #expect(try loaded.object(live.id).props == live.props)
        #expect(try loaded.object(rooted.id).props == rooted.props)
        #expect(try loaded.object(code.id).props["anchor"] == nil)
        #expect(try loaded.object(refCode.id).props == refCode.props)
    }

    @Test func mixedLineEndingsPreserveAllowedAnchorsAndAuthoredBytes() async throws {
        let store = store()
        let board = try makeBoard()
        let markdown = "a\rb\rc\n```txt file=../outside.txt#L1 anchor=DROP\n```\n```txt file=inside.txt#L1 anchor=KEEP\n```\n"
        let note = board.create(type: .note, props: .object(["markdown": .string(markdown)]))
        let malformed = board.create(type: .note, props: .object(["markdown": "~~~txt file=../outside.txt#L1 anchor=\"DROP\r\nAuthored body\r\n~~~\r\n"]))
        try FileManager.default.createSymbolicLink(atPath: board.root.appendingPathComponent("dangling.txt").path, withDestinationPath: "../gone.txt")
        let dangling = board.create(type: .code, props: .object(["path": "dangling.txt", "anchor": "DROP"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        try persist(board.snapshot, in: store)
        let loaded = await store.load(root: board.root)
        #expect(try loaded.object(note.id).props["markdown"] == "a\rb\rc\n```txt file=../outside.txt#L1 \n```\n```txt file=inside.txt#L1 anchor=KEEP\n```\n")
        #expect(try loaded.object(malformed.id).props["markdown"] == "~~~txt file=../outside.txt#L1 \r\nAuthored body\r\n~~~\r\n")
        #expect(try loaded.object(dangling.id).props["anchor"] == nil)
    }

    @Test func orderedListParenthesesDoNotHideFenceMetadata() async throws {
        let store = store()
        let board = try makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": "1) ~~~txt file=../outside.txt#L1 anchor=DROP\n   authored body\n   ~~~\n"]))
        try persist(board.snapshot, in: store)
        let loaded = await store.load(root: board.root)
        #expect(try loaded.object(note.id).props["markdown"] == "1) ~~~txt file=../outside.txt#L1 \n   authored body\n   ~~~\n")
    }

    @Test func invalidRevisionsDoNotAuthorizeOutsideMetadata() async throws {
        let store = store()
        let board = try makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": "```txt file=../outside.txt commit=-invalid anchor=DROP\n```\n```txt file=inside.txt commit=-invalid anchor=KEEP\n```\n"]))
        let outside = board.create(type: .code, props: .object(["path": "../outside.txt", "pinnedCommit": "-invalid", "anchor": "DROP"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let inside = board.create(type: .code, props: .object(["path": "inside.txt", "pinnedCommit": "-invalid", "anchor": "KEEP"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let empty = board.create(type: .code, props: .object(["path": "", "anchor": "DROP"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        try persist(board.snapshot, in: store)
        let loaded = await store.load(root: board.root)
        await loaded.waitForAnchorScrub()
        #expect(try loaded.object(note.id).props["markdown"] == "```txt file=../outside.txt commit=-invalid \n```\n```txt file=inside.txt commit=-invalid anchor=KEEP\n```\n")
        #expect(try loaded.object(outside.id).props["anchor"] == nil)
        #expect(try loaded.object(inside.id).props == inside.props)
        #expect(try loaded.object(empty.id).props["anchor"] == nil)
    }

    @Test(.timeLimit(.minutes(1))) func gitContentionPublishesSafeRepliesAndPreservesEditsBeforeRestoringAnchors() async throws {
        let fixture = try await gitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.repo.root) }
        let holds = GitLoadHolds()
        defer { holds.release() }
        try await holds.occupy(in: directory)
        let registry = BoardRegistry(store: fixture.store)
        let router = ApiRouter(registry: registry)
        let socket = directory.appendingPathComponent("s").path
        let server = SocketServer(path: socket) { request, connection in await router.handle(request, connection: connection) }
        try server.start()
        defer { server.stop() }
        let client = try LineClient(path: socket)
        #expect(try await call(client, "board.open", ["root": .string(fixture.repo.root.path)])["result"]?["board"] == .string(fixture.board.id))
        let loaded = try #require(registry.boards[fixture.board.id])
        #expect(Set(loaded.objects.keys) == Set(fixture.board.objects.keys))
        #expect(loaded.isAnchorScrubPending(fixture.allowed.id))
        #expect(loaded.isAnchorScrubPending(fixture.code.id))
        #expect(!loaded.isAnchorScrubPending(fixture.outside.id))
        #expect(try loaded.object(fixture.allowed.id).props["markdown"] == .string(fixture.quarantined))
        #expect(try loaded.object(fixture.outside.id).props["markdown"] == "```txt file=../outside.txt#L1 \n```\n")
        #expect(loaded.revision == fixture.board.revision)
        #expect(!loaded.history.canUndo)

        let boardReply = try await call(client, "board.get", ["board": .string(loaded.id)])
        #expect(boardReply["result"]?["objects"]?.array?.count == fixture.board.objects.count)
        for object in [fixture.code, fixture.denied, fixture.outside] {
            let reply = try await call(client, "object.get", ["id": .string(object.id)])
            #expect(reply["result"]?["object"]?["id"] == .string(object.id))
            #expect(!encoded(reply).contains("KEEP_") && !encoded(reply).contains("LEAKED_"))
        }
        #expect(!encoded(boardReply).contains("KEEP_") && !encoded(boardReply).contains("LEAKED_"))

        try fixture.store.saveChecked(loaded)
        let pending = try saved(loaded.id, in: fixture.store)
        #expect(pending.objects.first { $0.id == fixture.allowed.id }?.props["markdown"] == fixture.allowed.props["markdown"], "a save before git settles must not erase recoverable anchors")
        let subscriber = try LineClient(path: socket)
        #expect(try await call(subscriber, "events.subscribe", ["board": .string(loaded.id), "events": ["object.updated"]])["ok"] == .bool(true))
        let frame = Frame(x: 40, y: 70, w: 500, h: 260)
        let moved = try loaded.update(fixture.allowed.id, frame: frame, props: .object(["caption": "moved while git waits"]))
        let event = try await subscriber.next()
        #expect(event["event"] == "object.updated")
        #expect(event["data"]?["id"] == .string(fixture.allowed.id))
        #expect(event["data"]?["props"]?["markdown"] == .string(fixture.quarantined))
        #expect(!encoded(event).contains("KEEP_") && !encoded(event).contains("LEAKED_"))
        let authored = "New authored text wins.\n```txt file=a.txt#L1\n```\n"
        let edited = try loaded.update(fixture.edited.id, props: .object(["markdown": .string(authored)]))
        let editedEvent = try await subscriber.next()
        #expect(editedEvent["data"]?["id"] == .string(fixture.edited.id))
        #expect(editedEvent["data"]?["props"]?["markdown"] == .string(authored))
        let revision = loaded.revision
        try fixture.store.saveChecked(loaded)

        try await holds.finish()
        await loaded.waitForAnchorScrub()
        let restoredEvents = [try await subscriber.next(), try await subscriber.next()]
        #expect(Set(restoredEvents.compactMap { $0["data"]?["id"]?.string }) == [fixture.allowed.id, fixture.code.id])
        for restored in restoredEvents { #expect(!encoded(restored).contains("LEAKED_")) }
        #expect(restoredEvents.first { $0["data"]?["id"] == .string(fixture.allowed.id) }?["data"]?["props"]?["markdown"] == .string(fixture.accepted))
        #expect(restoredEvents.first { $0["data"]?["id"] == .string(fixture.code.id) }?["data"]?["props"]?["anchor"] == "KEEP_CODE")
        #expect(!loaded.isAnchorScrubPending(fixture.allowed.id))
        #expect(try loaded.object(fixture.allowed.id).props["markdown"] == .string(fixture.accepted))
        #expect(try loaded.object(fixture.allowed.id).props["caption"] == "moved while git waits")
        #expect(try loaded.object(fixture.allowed.id).frame == frame)
        #expect(try loaded.object(fixture.allowed.id).rev == moved.rev)
        #expect(try loaded.object(fixture.allowed.id).updatedAt == moved.updatedAt)
        #expect(try loaded.object(fixture.edited.id).props["markdown"] == .string(authored))
        #expect(try loaded.object(fixture.edited.id).rev == edited.rev)
        #expect(try loaded.object(fixture.edited.id).updatedAt == edited.updatedAt)
        #expect(try loaded.object(fixture.code.id).props["anchor"] == "KEEP_CODE")
        #expect(try loaded.object(fixture.denied.id).props["anchor"] == nil)
        #expect(loaded.revision == revision + 2, "restoration advances only the board event cursor, not object revisions")
        fixture.store.flush([loaded])
        let settled = try saved(loaded.id, in: fixture.store)
        #expect(settled.objects.first { $0.id == fixture.allowed.id }?.frame == frame)
        #expect(settled.objects.first { $0.id == fixture.edited.id }?.props["markdown"] == .string(authored))
        #expect(!String(decoding: try BoardStore.encoder.encode(settled), as: UTF8.self).contains("LEAKED_"))
        #expect(loaded.undo())
        #expect(try loaded.object(fixture.edited.id).props["markdown"] == .string(fixture.accepted))
        #expect(loaded.undo())
        #expect(try loaded.object(fixture.allowed.id).frame == fixture.allowed.frame)
        #expect(try loaded.object(fixture.allowed.id).props["caption"] == nil)
        #expect(try loaded.object(fixture.allowed.id).props["markdown"] == .string(fixture.accepted))
        #expect(loaded.redo())
        #expect(try loaded.object(fixture.allowed.id).frame == frame)
        #expect(try loaded.object(fixture.allowed.id).props["markdown"] == .string(fixture.accepted))
        #expect(loaded.redo())
        #expect(try loaded.object(fixture.edited.id).props["markdown"] == .string(authored))
    }

    @Test(.timeLimit(.minutes(1))) func viewerUndoAndRedoKeepAuthorizedAnchorsAcrossScrub() async throws {
        let fixture = try await gitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.repo.root) }
        let holds = GitLoadHolds()
        defer { holds.release() }
        try await holds.occupy(in: directory)
        let registry = BoardRegistry(store: fixture.store)
        let router = ApiRouter(registry: registry)
        let socket = directory.appendingPathComponent("s").path
        let server = SocketServer(path: socket) { request, connection in await router.handle(request, connection: connection) }
        try server.start()
        defer { server.stop() }
        let client = try LineClient(path: socket)
        @MainActor func request(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
            let reply = try await call(client, method, params)
            try #require(reply["ok"] == .bool(true), "\(method): \(reply)")
            return try #require(reply["result"])
        }
        @MainActor func replay(_ viewer: String, redo: Bool = false) async throws {
            let result = try await request(redo ? "board.redo" : "board.undo", ["board": .string(fixture.board.id), "viewer": .string(viewer), "step": 1])
            #expect(result["kept"] == .array([]))
            #expect(result["pushed"] == .bool(true))
            #expect(!encoded(result).contains("LEAKED_"))
        }
        _ = try await request("board.open", ["root": .string(fixture.repo.root.path)])
        let loaded = try #require(registry.boards[fixture.board.id])
        #expect(loaded.isAnchorScrubPending(fixture.allowed.id))
        let authored = "The remote viewer's authored text."
        for (object, viewer) in [(fixture.allowed, "vw_anchor_edit"), (fixture.edited, "vw_anchor_redo")] {
            _ = try await request("object.update", ["id": .string(object.id), "props": .object(["markdown": .string(authored)]), "viewer": .string(viewer), "step": 1])
        }
        try await replay("vw_anchor_redo")
        #expect(try loaded.object(fixture.edited.id).props["markdown"] == .string(fixture.quarantined))
        _ = try await request("object.delete", ["id": .string(fixture.code.id), "viewer": "vw_anchor_delete", "step": 1])
        #expect(!encoded(try await request("board.get", ["board": .string(loaded.id)])).contains("KEEP_"))
        try await holds.finish()
        await loaded.waitForAnchorScrub()
        try await replay("vw_anchor_edit")
        #expect(try loaded.object(fixture.allowed.id).props["markdown"] == .string(fixture.accepted))
        try await replay("vw_anchor_redo", redo: true)
        #expect(try loaded.object(fixture.edited.id).props["markdown"] == .string(authored))
        try await replay("vw_anchor_delete")
        #expect(try loaded.object(fixture.code.id).props["anchor"] == "KEEP_CODE")
        try fixture.store.saveChecked(loaded)
        let persisted = try saved(loaded.id, in: fixture.store)
        #expect(persisted.objects.first { $0.id == fixture.allowed.id }?.props["markdown"] == .string(fixture.accepted))
        #expect(persisted.objects.first { $0.id == fixture.code.id }?.props["anchor"] == "KEEP_CODE")
        #expect(!String(decoding: try BoardStore.encoder.encode(persisted), as: UTF8.self).contains("LEAKED_"))
        try await replay("vw_anchor_edit", redo: true)
        #expect(try loaded.object(fixture.allowed.id).props["markdown"] == .string(authored))
        try await replay("vw_anchor_redo")
        #expect(try loaded.object(fixture.edited.id).props["markdown"] == .string(fixture.accepted))
        try await replay("vw_anchor_delete", redo: true)
        #expect(loaded.objects[fixture.code.id] == nil)
    }

    @Test(.timeLimit(.minutes(1))) func closingAndReopeningDuringGitScrubCannotResurrectOrOverwriteObjects() async throws {
        let fixture = try await gitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.repo.root) }
        let holds = GitLoadHolds()
        defer { holds.release() }
        try await holds.occupy(in: directory)
        let registry = BoardRegistry(store: fixture.store)
        let first = await registry.open(root: fixture.repo.root)
        #expect(first.isAnchorScrubPending(fixture.allowed.id))
        try registry.close(first.id)
        #expect(try saved(first.id, in: fixture.store).objects.first { $0.id == fixture.allowed.id }?.props["markdown"] == fixture.allowed.props["markdown"])
        let replacement = await registry.open(root: fixture.repo.root)
        #expect(replacement !== first)
        #expect(replacement.isAnchorScrubPending(fixture.allowed.id))
        let authored = "Only the reopened board's edit survives."
        _ = try replacement.update(fixture.allowed.id, props: .object(["markdown": .string(authored)]))
        try replacement.delete(fixture.code.id)
        try fixture.store.saveChecked(replacement)
        let revision = replacement.revision

        try await holds.finish()
        await first.waitForAnchorScrub()
        await replacement.waitForAnchorScrub()
        #expect(registry.boards[first.id] === replacement)
        #expect(try replacement.object(fixture.allowed.id).props["markdown"] == .string(authored))
        #expect(replacement.objects[fixture.code.id] == nil)
        #expect(replacement.revision == revision + 1)
        #expect(try replacement.object(fixture.edited.id).props["markdown"] == .string(fixture.accepted))
        let beforeFlush = try saved(replacement.id, in: fixture.store)
        #expect(beforeFlush.objects.first { $0.id == fixture.allowed.id }?.props["markdown"] == .string(authored))
        #expect(beforeFlush.objects.first { $0.id == fixture.code.id } == nil)
        fixture.store.flush([replacement])
        let persisted = try saved(replacement.id, in: fixture.store)
        #expect(persisted.objects.first { $0.id == fixture.allowed.id }?.props["markdown"] == .string(authored))
        #expect(persisted.objects.first { $0.id == fixture.code.id } == nil)
        #expect(persisted.revision == revision + 1)
        #expect(!String(decoding: try BoardStore.encoder.encode(persisted), as: UTF8.self).contains("LEAKED_"))
    }

    @Test(.timeLimit(.minutes(1))) func aQuietGitScrubPersistsOnlyNormalizedOriginalBytesAndDoesNotRewriteAgain() async throws {
        let fixture = try await gitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.repo.root) }
        var original = fixture.board.snapshot
        original.format = 1
        try persist(original, in: fixture.store)
        original = try saved(fixture.board.id, in: fixture.store)
        var expected = original
        for index in expected.objects.indices {
            let id = expected.objects[index].id
            if id == fixture.allowed.id || id == fixture.edited.id {
                expected.objects[index].props = expected.objects[index].props.merging(.object(["markdown": .string(fixture.accepted)]))
            }
            if id == fixture.outside.id {
                expected.objects[index].props = expected.objects[index].props.merging(.object(["markdown": "```txt file=../outside.txt#L1 \n```\n"]))
            }
            if id == fixture.denied.id {
                var props = try #require(expected.objects[index].props.object)
                props.removeValue(forKey: "anchor")
                expected.objects[index].props = .object(props)
            }
        }
        let registry = BoardRegistry(store: fixture.store)
        let loaded = await registry.open(root: fixture.repo.root)
        await loaded.waitForAnchorScrub()
        let url = fixture.store.url(for: loaded.id)
        #expect(try Data(contentsOf: url) == BoardStore.encoder.encode(expected))
        #expect(loaded.revision == original.revision + 3)
        #expect(!loaded.history.canUndo)
        let sentinel = Date(timeIntervalSince1970: 1234567890)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: url.path)
        let again = await fixture.store.load(root: fixture.repo.root)
        await again.waitForAnchorScrub()
        #expect(try again.object(fixture.allowed.id).props["markdown"] == .string(fixture.accepted))
        #expect(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == sentinel)
        #expect(try Data(contentsOf: url) == BoardStore.encoder.encode(expected))
    }

    @Test(.timeLimit(.minutes(1))) func concurrentCheckoutsPublishOneBoardWhileGitIsStillHeld() async throws {
        let fixture = try await gitFixture()
        let worktree = URL(fileURLWithPath: fixture.repo.root.path + "-load-wt")
        defer {
            try? FileManager.default.removeItem(at: worktree)
            try? FileManager.default.removeItem(at: fixture.repo.root)
        }
        try await fixture.repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        let holds = GitLoadHolds()
        defer { holds.release() }
        try await holds.occupy(in: directory)
        let registry = BoardRegistry(store: fixture.store)
        async let main = registry.open(root: fixture.repo.root)
        async let linked = registry.open(root: worktree)
        let (fromMain, fromWorktree) = await (main, linked)
        #expect(fromMain === fromWorktree)
        #expect(registry.boards.count == 1)
        #expect(fromMain.id == fixture.board.id)
        #expect(Set(fromMain.objects.keys) == Set(fixture.board.objects.keys))
        #expect(fromMain.isAnchorScrubPending(fixture.allowed.id))
        #expect(try fromMain.object(fixture.allowed.id).props["markdown"] == .string(fixture.quarantined))
        try await holds.finish()
        await fromMain.waitForAnchorScrub()
        #expect(try fromMain.object(fixture.allowed.id).props["markdown"] == .string(fixture.accepted))
    }

    @Test(.timeLimit(.minutes(1))) func aRefShaRefreshDuringScrubKeepsRecoverableAnchors() async throws {
        let fixture = try await gitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.repo.root) }
        let sha = try await fixture.repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown = "```txt file=a.txt#L1 anchor=KEEP_REF\n```\n"
        let note = fixture.board.create(type: .note, props: .object(["ref": "main", "markdown": .string(markdown)]))
        try persist(fixture.board.snapshot, in: fixture.store)
        let holds = GitLoadHolds()
        defer { holds.release() }
        try await holds.occupy(in: directory)
        let loaded = await BoardRegistry(store: fixture.store).open(root: fixture.repo.root)
        #expect(loaded.isAnchorScrubPending(note.id))
        let session = NoteEditSession(try loaded.object(note.id))
        let moved = try loaded.update(note.id, rev: loaded.object(note.id).rev, frame: Frame(x: 40, y: 50, w: 400, h: 300))
        session.observe(moved)
        loaded.recordRefSha(note.id, ref: "main", sha: sha)
        try fixture.store.saveChecked(loaded)
        #expect(try saved(loaded.id, in: fixture.store).objects.first { $0.id == note.id }?.props["markdown"] == .string(markdown))
        try await holds.finish()
        await loaded.waitForAnchorScrub()
        #expect(try loaded.object(note.id).props["markdown"] == .string(markdown))
        fixture.store.flush([loaded])
        #expect(try loaded.object(note.id).props["refSha"] == .string(sha))
        #expect(try saved(loaded.id, in: fixture.store).objects.first { $0.id == note.id }?.props["markdown"] == .string(markdown))
        session.observe(try loaded.object(note.id))
        #expect(!session.conflicted)
        let typed = "Typed while the board was checking anchors."
        #expect(try session.commit(typed, confirmed: false, on: loaded) == .saved)
        try fixture.store.saveChecked(loaded)
        #expect(try saved(loaded.id, in: fixture.store).objects.first { $0.id == note.id }?.props["markdown"] == .string(typed))
    }

    struct GitFixture {
        let repo: TempRepo
        let store: BoardStore
        let board: Board
        let allowed: CanvasObject
        let edited: CanvasObject
        let outside: CanvasObject
        let code: CanvasObject
        let denied: CanvasObject
        let quarantined: String
        let accepted: String
    }

    func gitFixture() async throws -> GitFixture {
        let repo = try await TempRepo()
        try await repo.write("a.txt", "committed\n")
        try FileManager.default.createSymbolicLink(atPath: repo.url("link.txt").path, withDestinationPath: "a.txt")
        let sha = try await repo.commit("base")
        let board = try makeBoard(root: repo.root)
        board.repo = RepoRecord(commonDir: try #require(GitWorktree.containing(repo.root.path)).commonDir)
        let markdown = "```txt file=a.txt@\(sha)#L1 anchor=KEEP_NOTE\n```\n```txt file=link.txt@\(sha)#L1 anchor=LEAKED_PINNED_SYMLINK\n```\n"
        let quarantined = "```txt file=a.txt@\(sha)#L1 \n```\n```txt file=link.txt@\(sha)#L1 \n```\n"
        let accepted = markdown.replacingOccurrences(of: "anchor=LEAKED_PINNED_SYMLINK", with: "")
        let allowed = board.create(type: .note, props: .object(["markdown": .string(markdown)]))
        let edited = board.create(type: .note, props: .object(["markdown": .string(markdown)]))
        let outside = board.create(type: .note, props: .object(["markdown": "```txt file=../outside.txt#L1 anchor=LEAKED_OUTSIDE\n```\n"]))
        let code = board.create(type: .code, props: .object(["path": "a.txt", "pinnedCommit": .string(sha), "anchor": "KEEP_CODE"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let denied = board.create(type: .code, props: .object(["path": "link.txt", "pinnedCommit": .string(sha), "anchor": "LEAKED_CODE_SYMLINK"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let store = store()
        try persist(board.snapshot, in: store)
        return GitFixture(repo: repo, store: store, board: board, allowed: allowed, edited: edited, outside: outside, code: code, denied: denied, quarantined: quarantined, accepted: accepted)
    }

    func saved(_ id: BoardID, in store: BoardStore) throws -> BoardSnapshot {
        try BoardStore.decoder.decode(BoardSnapshot.self, from: Data(contentsOf: store.url(for: id)))
    }

    func encoded(_ value: JSONValue) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    func call(_ client: LineClient, _ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        client.send(encoded(.object(["id": "1", "method": .string(method), "params": .object(params)])))
        return try await client.next()
    }

}

@MainActor
private final class GitLoadHolds {
    private var readers: [Int32] = []
    private var writers: [Int32] = []
    private var tasks: [Task<Data, Error>] = []

    func occupy(in directory: URL) async throws {
        for index in 0..<2 {
            let gate = directory.appendingPathComponent("git-gate-\(index)").path
            let ready = directory.appendingPathComponent("git-ready-\(index)").path
            try #require(mkfifo(gate, 0o600) == 0)
            try #require(mkfifo(ready, 0o600) == 0)
            let reader = open(gate, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            try #require(reader >= 0)
            readers.append(reader)
            let writer = open(gate, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            try #require(writer >= 0)
            writers.append(writer)
            let readyReader = open(ready, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            try #require(readyReader >= 0)
            defer { close(readyReader) }
            let readyWriter = open(ready, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            try #require(readyWriter >= 0)
            defer { close(readyWriter) }
            tasks.append(Task {
                try await GitRunner.shared.run(["-c", #"alias.hold=!f() { exec 3< "$1"; printf r > "$2"; cat <&3; }; f"#, "hold", gate, ready], in: directory, timeout: 20)
            })
            let started = await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    var descriptor = pollfd(fd: readyReader, events: Int16(POLLIN), revents: 0)
                    var byte: UInt8 = 0
                    let signaled = poll(&descriptor, 1, 10_000) > 0 && Darwin.read(readyReader, &byte, 1) == 1 && byte == 114
                    continuation.resume(returning: signaled)
                }
            }
            try #require(started, "the real shared GitRunner slot must be held before opening the board")
        }
    }

    func release() {
        for writer in writers { close(writer) }
        writers.removeAll()
    }

    func finish() async throws {
        release()
        for task in tasks { _ = try await task.value }
        tasks.removeAll()
    }

    deinit {
        for writer in writers { close(writer) }
        for reader in readers { close(reader) }
        for task in tasks { task.cancel() }
    }
}
