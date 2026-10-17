import Foundation
import Testing
@testable import CanvasCore

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
        let loaded = registry.open(root: board.root)
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
        let again = store.load(root: board.root)
        #expect(try again.object(note.id).props["markdown"] == .string(cleaned))
        #expect(try store.url(for: board.id).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == sentinel)
        #expect(try Data(contentsOf: store.url(for: board.id)) == BoardStore.encoder.encode(expected))
    }

    @Test func encodedAttributesAndQuotesPreserveEveryOtherByte() throws {
        let store = store()
        let board = try makeBoard()
        let markdown = #"~~~txt file=../outside.txt#L1 an&#99;hor=&quot;ENTITY value&quot; title="keep anchor=fake" anchor="first \\\" quoted" anchor=''  "# + "\r\nbody anchor=authored\r\n~~~\r\n" + #"```txt file=../outside.txt#L1 anchor\=&quot;ESCAPED key&quot; caption='stay'"# + "\r\n```\r\n"
        let expected = #"~~~txt file=../outside.txt#L1  title="keep anchor=fake"    "# + "\r\nbody anchor=authored\r\n~~~\r\n```txt file=../outside.txt#L1  caption='stay'\r\n```\r\n"
        let note = board.create(type: .note, props: .object(["markdown": .string(markdown)]))
        try persist(board.snapshot, in: store)
        let loaded = store.load(root: board.root)
        #expect(try loaded.object(note.id).props["markdown"] == .string(expected))
    }

    @Test func insideReadFailuresAndOutsideLinkRootsAreDistinguished() throws {
        let store = store()
        let board = try makeBoard()
        try Data([0xff]).write(to: board.root.appendingPathComponent("binary.txt"))
        try FileManager.default.createDirectory(at: board.root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let inside = "```txt file=missing.txt#L1 anchor=missing\n```\n```txt file=binary.txt#L1 anchor=binary\n```\n```txt file=folder#L1 anchor=directory\n```\n"
        let kept = board.create(type: .note, props: .object(["markdown": .string(inside)]))
        let outside = board.create(type: .note, props: .object(["root": "..", "markdown": "```txt file=root/missing.txt#L1 anchor=DROP\n```\n"]))
        let code = board.create(type: .code, props: .object(["path": "missing.txt", "anchor": "keep missing"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        try persist(board.snapshot, in: store)
        let loaded = store.load(root: board.root)
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
        let loaded = store.load(root: repo.root)
        #expect(try loaded.object(pinned.id).props["markdown"] == .string(markdown.replacingOccurrences(of: "anchor=DROP_PINNED_SYMLINK", with: "")))
        #expect(try loaded.object(atRef.id).props["markdown"] == "```txt file=src/a.txt#L1 anchor=KEEP_REF\n```\n```txt file=link.txt#L1 \n```\n")
        #expect(try loaded.object(live.id).props == live.props)
        #expect(try loaded.object(rooted.id).props == rooted.props)
        #expect(try loaded.object(code.id).props["anchor"] == nil)
        #expect(try loaded.object(refCode.id).props == refCode.props)
    }

    @Test func mixedLineEndingsPreserveAllowedAnchorsAndAuthoredBytes() throws {
        let store = store()
        let board = try makeBoard()
        let markdown = "a\rb\rc\n```txt file=../outside.txt#L1 anchor=DROP\n```\n```txt file=inside.txt#L1 anchor=KEEP\n```\n"
        let note = board.create(type: .note, props: .object(["markdown": .string(markdown)]))
        let malformed = board.create(type: .note, props: .object(["markdown": "~~~txt file=../outside.txt#L1 anchor=\"DROP\r\nAuthored body\r\n~~~\r\n"]))
        try FileManager.default.createSymbolicLink(atPath: board.root.appendingPathComponent("dangling.txt").path, withDestinationPath: "../gone.txt")
        let dangling = board.create(type: .code, props: .object(["path": "dangling.txt", "anchor": "DROP"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        try persist(board.snapshot, in: store)
        let loaded = store.load(root: board.root)
        #expect(try loaded.object(note.id).props["markdown"] == "a\rb\rc\n```txt file=../outside.txt#L1 \n```\n```txt file=inside.txt#L1 anchor=KEEP\n```\n")
        #expect(try loaded.object(malformed.id).props["markdown"] == "~~~txt file=../outside.txt#L1 \r\nAuthored body\r\n~~~\r\n")
        #expect(try loaded.object(dangling.id).props["anchor"] == nil)
    }

    @Test func orderedListParenthesesDoNotHideFenceMetadata() throws {
        let store = store()
        let board = try makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": "1) ~~~txt file=../outside.txt#L1 anchor=DROP\n   authored body\n   ~~~\n"]))
        try persist(board.snapshot, in: store)
        let loaded = store.load(root: board.root)
        #expect(try loaded.object(note.id).props["markdown"] == "1) ~~~txt file=../outside.txt#L1 \n   authored body\n   ~~~\n")
    }

    @Test func invalidRevisionsDoNotAuthorizeOutsideMetadata() throws {
        let store = store()
        let board = try makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": "```txt file=../outside.txt commit=-invalid anchor=DROP\n```\n```txt file=inside.txt commit=-invalid anchor=KEEP\n```\n"]))
        let outside = board.create(type: .code, props: .object(["path": "../outside.txt", "pinnedCommit": "-invalid", "anchor": "DROP"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let inside = board.create(type: .code, props: .object(["path": "inside.txt", "pinnedCommit": "-invalid", "anchor": "KEEP"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let empty = board.create(type: .code, props: .object(["path": "", "anchor": "DROP"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        try persist(board.snapshot, in: store)
        let loaded = store.load(root: board.root)
        #expect(try loaded.object(note.id).props["markdown"] == "```txt file=../outside.txt commit=-invalid \n```\n```txt file=inside.txt commit=-invalid anchor=KEEP\n```\n")
        #expect(try loaded.object(outside.id).props["anchor"] == nil)
        #expect(try loaded.object(inside.id).props == inside.props)
        #expect(try loaded.object(empty.id).props["anchor"] == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aSynchronousLoadsGitGoesAheadOfQueuedGit() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let directory = directory
        let gate = directory.appendingPathComponent("gate").path
        let started = directory.appendingPathComponent("started")
        let served = directory.appendingPathComponent("served")
        try #require(mkfifo(gate, 0o600) == 0)
        let reader = open(gate, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        try #require(reader >= 0)
        defer { close(reader) }
        var writer = open(gate, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        try #require(writer >= 0)
        var tasks: [Task<Void, Error>] = []
        defer {
            if writer >= 0 { close(writer) }
            for task in tasks { task.cancel() }
        }
        let runner = GitRunner(limit: 1)
        func request(_ name: String, load: Bool) async -> Task<Void, Error> {
            var task: Task<Void, Error>!
            await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
                task = GitRunner.$synchronousLoad.withValue(load) {
                    Task {
                        try await recordLoadRequest(name, directory: directory, served: served, runner: runner, entered: entered)
                    }
                }
            }
            return task
        }
        let holder = Task { _ = try await runner.run(["-c", #"alias.hold=!f() { exec 3< "$1"; printf ready > "$2"; cat <&3; }; f"#, "hold", gate, started.path], in: directory) }
        tasks.append(holder)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: started.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: started.path))
        let queued = await request("queued", load: false)
        tasks.append(queued)
        let first = await request("first load", load: true)
        tasks.append(first)
        let cancelled = await request("cancelled load", load: true)
        tasks.append(cancelled)
        let second = await request("second load", load: true)
        tasks.append(second)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        close(writer)
        writer = -1
        try await holder.value
        for task in [queued, first, second] { try await task.value }
        #expect(try String(contentsOf: served, encoding: .utf8).split(separator: "\n").map(String.init) == ["first load", "second load", "queued"])
    }
}

private func recordLoadRequest(_ name: String, directory: URL, served: URL, runner: isolated GitRunner, entered: CheckedContinuation<Void, Never>) async throws {
    entered.resume()
    _ = try await runner.run(["-c", #"alias.record=!f() { printf '%s\n' "$1" >> "$2"; }; f"#, "record", name, served.path], in: directory)
}
