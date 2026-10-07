import AppKit
import Testing
import CanvasCore

@MainActor
struct BoardTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-tests-\(UUID().uuidString)")

    func makeBoard() -> Board {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Board(id: "brd_test", root: root)
    }

    /// The API reports objects (`board.get`, write results, events) without encoding them; what
    /// it reports must be exactly their encoded form, optional fields and dates included.
    @Test func objectsReportAsTheirEncodedForm() throws {
        let board = makeBoard()
        let group = board.create(type: .group, props: .object(["members": .array([]), "title": .string("lane")]))
        let props: JSONValue = .object(["markdown": .string("hi"), "nested": .object(["a": .array([.number(1.5), .bool(true), .null, .number(3)])])])
        let note = board.create(type: .note, props: props, frame: Frame(x: 1.25, y: -3, w: 200, h: 100), parent: group.id, caller: "obj_agent")
        let byUser = try board.update(note.id, props: .object(["markdown": .string("bye")]))
        let byAgent = try board.update(note.id, frame: Frame(x: 0.1, y: 7, w: 320, h: 90.5), caller: "obj_agent")
        for object in [group, note, byUser, byAgent] {
            #expect(JSONValue(object) == (try JSONValue.encode(object)))
        }
    }

    @Test func peekDrainKeepsTrayUntilCommit() async throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("hypothesis")]))
        let mention = try board.stage(.object(note.id))

        let peeked = await board.drain(peek: true)
        #expect(peeked.mentions.map(\.id) == [mention.id])
        #expect(peeked.context.contains("hypothesis"))
        #expect(board.tray.count == 1, "a peek must not lose the mention if the prompt is cancelled")

        // A mention staged after the peek survives the commit of the peeked ids.
        let other = board.create(type: .note, props: .object(["markdown": .string("later")]))
        let late = try board.stage(.object(other.id))
        board.commit(peeked.mentions.map(\.id))
        #expect(board.tray.map(\.id) == [late.id])
    }

    @Test func emptyTrayDrainsToEmptyContext() async {
        let board = makeBoard()
        #expect(await board.drain().context == "")
    }

    /// Servers and shells report resolved paths: /private/var/… under a /var/… root is still the board's.
    @Test func pathsReachedThroughASymlinkAreBoardRelative() {
        let board = makeBoard()
        #expect(root.path.hasPrefix("/var/"), "NSTemporaryDirectory sits behind the /var → /private/var link")
        #expect(board.relativePath("/private" + root.path + "/src/a.ts") == "src/a.ts")
        #expect(board.relativePath(root.path + "/src/a.ts") == "src/a.ts")
        #expect(board.relativePath("/etc/hosts") == "/etc/hosts")
    }

    @Test func stagedMentionsSurviveSaveAndReload() async throws {
        let store = BoardStore(directory: root.appendingPathComponent("boards"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = store.load(root: root)
        let note = board.create(type: .note, props: .object(["markdown": .string("keep me staged")]))
        let mention = try board.stage(.object(note.id))
        store.save(board)

        let reloaded = store.load(root: root)
        #expect(reloaded.tray.map(\.id) == [mention.id])
        #expect(await reloaded.drain().context.contains("keep me staged"))
    }

    @Test func unseenMarkersSurviveSaveAndReloadWithTheirTurn() throws {
        let store = BoardStore(directory: root.appendingPathComponent("boards"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = store.load(root: root)
        let agent = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]))
        let old = board.create(type: .note, props: .object(["markdown": .string("old")]))
        let seen = board.create(type: .note, props: .object(["markdown": .string("seen")]))
        let gone = board.create(type: .note, props: .object(["markdown": .string("gone")]))
        try board.reportLifecycle(tile: agent.id, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        for id in [old.id, seen.id, gone.id] { try board.raiseAttention(id, message: "look at \(id)", caller: agent.id) }
        board.clearAttention(seen.id)
        try board.delete(gone.id)
        try board.reportLifecycle(tile: agent.id, kind: "omp", state: .idle, message: nil, seq: 2, source: "canvas-omp")
        try board.reportLifecycle(tile: agent.id, kind: "omp", state: .working, message: nil, seq: 3, source: "canvas-omp")
        store.save(board)

        let reloaded = store.load(root: root)
        #expect(Array(reloaded.attention.keys) == [old.id], "seen and deleted objects' markers are gone")
        #expect(reloaded.attention[old.id]?.message == "look at \(old.id)")
        // Still a marker from an earlier turn after the restart: the agent's next one replaces it.
        let fresh = reloaded.create(type: .note, props: .object(["markdown": .string("new")]))
        #expect(try reloaded.raiseAttention(fresh.id, message: nil, caller: agent.id).cleared == [old.id])

        // A stored marker whose object isn't on the board is dropped on load.
        var snapshot = reloaded.snapshot
        snapshot.attention = [Attention(object: "obj_missing", message: nil, raisedBy: nil, raisedAt: Date())]
        #expect(Board(snapshot: snapshot).attention.isEmpty)
    }

    @Test func deletingAnObjectRemovesItsMentions() throws {
        let board = makeBoard()
        let a = board.create(type: .shape, props: .object(["kind": .string("rect")]))
        let b = board.create(type: .shape, props: .object(["kind": .string("rect")]))
        try board.stage(.object(a.id))
        try board.stage(.group(objects: [a.id, b.id], name: nil))
        try board.stage(.object(b.id))
        try board.delete(a.id)
        #expect(board.tray.count == 1)
        #expect(board.tray.first?.target == .object(b.id))
    }

    @Test func editingAStagedObjectMarksItEditedButKeepsIt() async throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("v1")]))
        try board.stage(.object(note.id))
        try board.update(note.id, props: .object(["markdown": .string("v2")]))
        #expect(board.tray.count == 1)
        #expect(board.tray[0].edited)
        #expect(await board.drain().context.contains("(edited)"))
    }

    @Test func movingScalingOrRestackingAStagedTileIsNotAnEdit() throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("v1")]))
        try board.stage(.object(note.id))
        try board.update(note.id, frame: Frame(x: 400, y: 300, w: 640, h: 480))
        try board.update(note.id, z: 99)
        try board.update(note.id, props: .object(["zoom": .number(2)]))
        #expect(!board.tray[0].edited)
        try board.update(note.id, props: .object(["markdown": .string("v2")]))
        #expect(board.tray[0].edited)
    }

    /// A changes-tile mention of `a.txt` lines 10–12 turns "edited" only when a review action
    /// touches those lines of that file (debugger study round 7: staging another file did).
    @Test func changesMentionIsEditedOnlyByActionsOnItsOwnLines() throws {
        let board = makeBoard()
        let tile = board.create(type: .changes, props: .object([:]))
        try board.stage(.code(object: tile.id, path: "a.txt", lines: LineRange(start: 10, end: 12), diff: "added line · unstaged hunk"))
        func entry(_ path: String, _ header: String?, scope: String = "hunk") -> JSONValue {
            var entry: [String: JSONValue] = ["action": "stage", "path": .string(path), "scope": .string(scope)]
            if let header { entry["header"] = .string(header) }
            return .object(entry)
        }
        var reviewed: [JSONValue] = []
        func review(_ next: JSONValue) throws {
            reviewed.append(next)
            try board.update(tile.id, props: .object(["reviewed": .array(reviewed)]))
        }
        try review(entry("b.txt", nil, scope: "file"))
        try review(entry("b.txt", "@@ -8,6 +8,8 @@"))
        try review(entry("a.txt", "@@ -30,3 +30,4 @@"))
        try board.update(tile.id, props: .object(["viewed": .object(["a.txt": "f1"])]))
        try board.update(tile.id, frame: Frame(x: 0, y: 0, w: 900, h: 700))
        #expect(!board.tray[0].edited, "other files, other hunks, Viewed and moves leave the lines as they were")

        try review(entry("a.txt", "@@ -8,4 +8,6 @@"))
        #expect(board.tray[0].edited, "a Stage of the hunk holding the lines")
    }

    @Test func undoingAnotherFilesReviewLeavesTheMentionButUndoingItsOwnEditsIt() throws {
        let board = makeBoard()
        let tile = board.create(type: .changes, props: .object([:]))
        let other: JSONValue = .object(["action": "stage", "path": "b.txt", "scope": "file"])
        let own: JSONValue = .object(["action": "revert", "path": "a.txt", "scope": "file"])
        try board.update(tile.id, props: .object(["reviewed": .array([other])]))
        try board.stage(.code(object: tile.id, path: "a.txt", lines: LineRange(start: 3, end: 3)))
        _ = board.undo()
        #expect(!board.tray[0].edited)
        try board.update(tile.id, props: .object(["reviewed": .array([own])]))
        _ = board.undo()
        #expect(board.tray[0].edited)
    }

    @Test func updateWithStaleRevConflicts() throws {
        let board = makeBoard()
        let note = board.create(type: .note, props: .object(["markdown": .string("v1")]))
        try board.update(note.id, rev: 1, props: .object(["markdown": .string("v2")]))
        #expect(throws: BoardError.self) { try board.update(note.id, rev: 1, props: .object(["markdown": .string("v3")])) }
    }

    @Test func agentObjectsPlaceBesideTheirTerminalWithoutOverlap() {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/"), "command": .array([])]), frame: Frame(x: 0, y: 0, w: 800, h: 500))
        let first = board.create(type: .note, props: .object(["markdown": .string("a")]), caller: terminal.id)
        let second = board.create(type: .note, props: .object(["markdown": .string("b")]), caller: terminal.id)
        #expect(first.frame.x >= terminal.frame.maxX)
        #expect(!first.frame.intersects(second.frame))
        #expect(first.createdBy == .agent(tile: terminal.id))
    }

    @Test func viewportPlacementSlidesPastTilesButNotDrawings() {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: -400, y: -250, w: 800, h: 500))
        let lasso = board.create(type: .shape, props: .object(["kind": .string("rect")]), frame: Frame(x: -2000, y: -2000, w: 4000, h: 4000))
        let first = board.create(type: .code, props: .object(["path": .string("a.swift")]))
        let second = board.create(type: .code, props: .object(["path": .string("b.swift")]))
        #expect(!first.frame.intersects(terminal.frame))
        #expect(!second.frame.intersects(first.frame) && !second.frame.intersects(terminal.frame))
        #expect(lasso.frame.contains(first.frame), "a user drawing around the area doesn't push tiles away")
        #expect(board.place(Frame(x: 5000.4, y: -3000.6, w: 100, h: 100)) == Frame(x: 5000, y: -3001, w: 100, h: 100), "a free spot stays put, on whole points")
    }

    @Test func idleAfterUnseenWorkIsDoneUntilSeen() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/"), "command": .array([])]))
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .idle, message: nil, seq: 2, source: "canvas-omp")
        #expect(board.objects[terminal.id]?.props["lifecycle"]?["state"]?.string == "done")
        board.markSeen(terminal.id)
        #expect(board.objects[terminal.id]?.props["lifecycle"]?["state"]?.string == "idle")
    }

    @Test func lookingAtAnAgentAtWorkDoesNotSeeTheAnswerItHasNotGivenYet() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/"), "command": .array([])]))
        func lifecycle() -> JSONValue? { board.objects[terminal.id]?.props["lifecycle"] }
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        board.markSeen(terminal.id)
        #expect(lifecycle()?["state"] == .string("working"), "seeing it work changes nothing")
        // The user looked away; the turn ends off-screen.
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .idle, message: nil, seq: 2, source: "canvas-omp")
        #expect(lifecycle()?["state"] == .string("done"))
        #expect(lifecycle()?["seen"] == .bool(false))
        #expect(NeedsYou.of(board.objects.values) == NeedsYou(level: .done, terminals: [terminal.id], message: nil), "⌘J goes there")
        board.markSeen(terminal.id)
        #expect(lifecycle()?["state"] == .string("idle"), "seen once it has answered")
        #expect(lifecycle()?["seen"] == .bool(true))

        // Seen while it waited on an approval and after, then answered once the user left: done too.
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .working, message: nil, seq: 3, source: "canvas-omp")
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .blocked, message: "approve Edit?", seq: 4, source: "canvas-omp", call: "c1")
        board.markSeen(terminal.id)
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .working, message: nil, seq: 5, source: "canvas-omp", call: "c1")
        board.markSeen(terminal.id)
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .idle, message: nil, seq: 6, source: "canvas-omp")
        #expect(lifecycle()?["state"] == .string("done"))
    }

    @Test func staleLifecycleSeqIsIgnored() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/"), "command": .array([])]))
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .blocked, message: "approve?", seq: 5, source: "canvas-omp")
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .working, message: nil, seq: 4, source: "canvas-omp")
        #expect(board.objects[terminal.id]?.props["lifecycle"]?["state"]?.string == "blocked")
    }

    @Test func followReusesOneTilePerTerminalAndIgnoresFilesOutsideTheProject() throws {
        let board = makeBoard()
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("follow-cwd-\(UUID().uuidString)")
        for file in [root.appendingPathComponent("src/a.ts"), root.appendingPathComponent("src/b.ts"), worktree.appendingPathComponent("lib/c.ts")] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x\n".write(to: file, atomically: true, encoding: .utf8)
        }
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(worktree.path), "command": .array([])]))
        let first = try #require(try board.follow(tile: terminal.id, path: root.appendingPathComponent("src/a.ts").path, range: LineRange(start: 1, end: 10), action: "read"))
        let second = try #require(try board.follow(tile: terminal.id, path: "src/b.ts", range: nil, action: "edit"))
        #expect(first.id == second.id)
        #expect(board.objects.values.filter { $0.type == .code }.count == 1)
        #expect(second.props["path"]?.string == "src/b.ts")
        #expect(first.props["path"]?.string == "src/a.ts", "absolute paths under the root are stored relative")

        let inCwd = worktree.appendingPathComponent("lib/c.ts").path
        #expect(try board.follow(tile: terminal.id, path: inCwd, range: nil, action: "read")?.id == first.id, "the terminal's cwd counts as the project")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent(".tmp-render.png"))
        #expect(try board.follow(tile: terminal.id, path: ".tmp-render.png", range: nil, action: "read") == nil, "an agent's own render")
        #expect(try board.follow(tile: terminal.id, path: "src/gone.ts", range: nil, action: "read") == nil)
        #expect(try board.follow(tile: terminal.id, path: root.path + "-sibling/a.ts", range: nil, action: "read") == nil, "a name prefix is not containment")
        #expect(board.objects[first.id]?.props["path"]?.string == inCwd, "ignored reads leave the follow tile where it was")
    }

    @Test func followShowsOnlyExistingTextFilesInTheProject() throws {
        let project = root.appendingPathComponent("repo")
        let scratch = root.appendingPathComponent("scratch")
        func file(_ path: String, _ data: Data = Data("let a = 1\n".utf8)) throws -> String {
            let url = URL(fileURLWithPath: path.hasPrefix("/") ? path : project.appendingPathComponent(path).path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url.path
        }
        let projects = [project.path]
        #expect(FollowFilter.follows(try file("src/main.rs"), projects: projects))
        #expect(FollowFilter.follows(try file("Makefile"), projects: projects), "no extension is fine")
        for scratchRender in [".tmp-bug-render.png", ".omp-shots/home.PNG", "target/x.png", "docs/spec.pdf", "dist/app.tar.gz"] {
            #expect(!FollowFilter.follows(try file(scratchRender), projects: projects), "\(scratchRender)")
        }
        #expect(!FollowFilter.follows(try file("data/blob.dat", Data([0x41, 0, 0x42])), projects: projects), "a NUL byte marks a binary")
        #expect(!FollowFilter.follows(project.appendingPathComponent("src/deleted.rs").path, projects: projects))
        #expect(!FollowFilter.follows(project.appendingPathComponent("src").path, projects: projects), "a directory")
        #expect(!FollowFilter.follows(try file(scratch.appendingPathComponent("a.rs").path), projects: projects), "outside the project")

        // The temp directory holds scratch files unless the project itself lives there.
        let temp = [root.path]
        #expect(!FollowFilter.follows(scratch.appendingPathComponent("a.rs").path, projects: ["/"], tempDirectories: temp))
        #expect(FollowFilter.follows(try file("src/main.rs"), projects: projects, tempDirectories: temp))
    }

    @Test func followSkipsFilesTooLargeForACodeTile() throws {
        // The data-science study: following a 14 MB CSV left the tile on "file too large to show" for 50 minutes.
        let board = makeBoard()
        try "x\n".write(to: root.appendingPathComponent("a.ts"), atomically: true, encoding: .utf8)
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path), "command": .array([])]))
        let follow = try #require(try board.follow(tile: terminal.id, path: "a.ts", range: nil, action: "read"))
        // Text up front, the rest a hole: sparse, so the test writes a few KiB, not 4 MiB.
        func sized(_ name: String, _ size: Int) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(String(repeating: "year,co2\n", count: 1000).utf8).write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(size))
            try handle.close()
            return url
        }
        let big = try sized("owid-co2-data.csv", GitDiffEngine.maxFileSize + 1)
        let limit = try sized("at-limit.csv", GitDiffEngine.maxFileSize)
        defer { try? FileManager.default.removeItem(at: big); try? FileManager.default.removeItem(at: limit) }

        #expect(try board.follow(tile: terminal.id, path: "owid-co2-data.csv", range: nil, action: "read") == nil)
        #expect(board.objects[follow.id]?.props["path"]?.string == "a.ts", "the tile keeps its last file")
        #expect(try board.follow(tile: terminal.id, path: "at-limit.csv", range: nil, action: "read")?.props["path"]?.string == "at-limit.csv",
                "a file of exactly the limit still shows")
    }

    @Test func closingAFollowTileStopsItsTerminalFollowingUntilTurnedBackOn() throws {
        let board = makeBoard()
        try "x\n".write(to: root.appendingPathComponent("a.ts"), atomically: true, encoding: .utf8)
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path), "command": .array([])]))
        let follow = try #require(try board.follow(tile: terminal.id, path: "a.ts", range: nil, action: "read"))

        try board.delete(follow.id)
        #expect(board.objects[terminal.id]?.props["follow"] == .bool(false))
        #expect(try board.follow(tile: terminal.id, path: "a.ts", range: nil, action: "read") == nil)
        #expect(board.followTiles(of: terminal.id).isEmpty)

        #expect(board.undo())
        #expect(board.objects[follow.id] != nil && board.objects[terminal.id]?.props["follow"] == nil, "one undo brings the tile back and following on")
        #expect(board.redo())
        #expect(board.objects[follow.id] == nil && board.objects[terminal.id]?.props["follow"] == .bool(false))

        try board.setFollowing(terminal.id, true)
        #expect(board.followTiles(of: terminal.id).isEmpty, "turning it on waits for the next report")
        let back = try #require(try board.follow(tile: terminal.id, path: "a.ts", range: nil, action: "read"))
        try board.setFollowing(terminal.id, false)
        #expect(board.objects[back.id] == nil && board.objects[terminal.id]?.props["follow"] == .bool(false))
        #expect(board.undo())
        #expect(board.objects[back.id] != nil && board.objects[terminal.id]?.props["follow"] == .bool(true), "turning it off is one undo step")
    }

    /// vim study: omp wrote tests/zz_probe.rs and removed it with `rm`; its follow tile sat on
    /// "file not found". A deleted file steps the tile back to the newest place still there,
    /// and drops the entries that are gone; nothing left closes it with following still on.
    @Test func aFollowTileWhoseFileVanishedStepsBackToTheNewestPlaceStillThere() throws {
        let board = makeBoard()
        for name in ["a.ts", "b.ts", "c.ts", "probe.rs", "scratch.ts"] { try "x\ny\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path), "command": .array([])]))
        _ = try board.follow(tile: terminal.id, path: "a.ts", range: LineRange(start: 1, end: 2), action: "read")
        _ = try board.follow(tile: terminal.id, path: "b.ts", range: nil, action: "edit")
        _ = try board.follow(tile: terminal.id, path: "scratch.ts", range: nil, action: "write")
        _ = try board.follow(tile: terminal.id, path: "c.ts", range: nil, action: "read")
        let follow = try #require(try board.follow(tile: terminal.id, path: "probe.rs", range: nil, action: "write"))
        let steps = board.history.undoSteps.count

        // probe.rs and scratch.ts are gone; the newest place left is c.ts.
        #expect(board.codeFileVanished(follow.id, path: "probe.rs", existing: ["a.ts", "b.ts", "c.ts"]) == .steppedBack(path: "c.ts"))
        let back = try board.object(follow.id)
        #expect(back.props["path"] == "c.ts" && back.props["range"] == nil && back.props["lastAction"] == "read")
        #expect(back.props["history"]?.array?.compactMap { $0["path"]?.string } == ["c.ts", "b.ts", "a.ts"], "dead entries dropped, order kept")
        #expect(board.codeFileVanished(follow.id, path: "probe.rs", existing: ["a.ts"]) == .kept, "it no longer shows the vanished file")

        _ = try board.follow(tile: terminal.id, path: "a.ts", range: LineRange(start: 1, end: 2), action: "read")
        #expect(board.codeFileVanished(follow.id, path: "a.ts", existing: ["b.ts"]) == .steppedBack(path: "b.ts"))
        #expect(try board.object(follow.id).props["lastAction"] == "edit", "what the agent did there")

        #expect(board.codeFileVanished(follow.id, path: "b.ts", existing: []) == .closed)
        #expect(board.objects[follow.id] == nil)
        #expect(board.objects[terminal.id]?.props["follow"] == nil, "still following: the next report brings the tile back")
        #expect(try board.follow(tile: terminal.id, path: "c.ts", range: nil, action: "read") != nil)
        #expect(board.history.undoSteps.count == steps, "nobody chose any of it: no undo step")

        // The user's own tile showing a missing file stays as it is.
        let mine = board.create(type: .code, props: .object(["path": "gone.ts"]))
        #expect(board.codeFileVanished(mine.id, path: "gone.ts", existing: []) == .kept && board.objects[mine.id] != nil)
    }

    /// Codex daily F1: a ⌘-click re-aiming the terminal's preview is navigation (Back re-aims it
    /// back), so the next ⌘Z undoes the user's change before it, not the re-aim.
    @Test func aCommandClickPreviewReaimIsNavigationNotTheNextUndo() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path), "command": .array([])]))
        let preview = board.openCode(path: root.appendingPathComponent("a.ts").path, lines: LineRange(start: 1, end: 1), beside: terminal.id)
        let note = board.create(type: .note, props: .object(["markdown": "x"]), frame: Frame(x: -2000, y: 0, w: 200, h: 100))
        try board.update(note.id, frame: Frame(x: -1500, y: 0, w: 200, h: 100))
        let reaimed = board.openCode(path: root.appendingPathComponent("b.ts").path, lines: LineRange(start: 5, end: 5), beside: terminal.id)
        #expect(reaimed.id == preview.id && reaimed.reaim?.after == CodeAim(path: "b.ts", range: LineRange(start: 5, end: 5)))
        #expect(board.undo())
        #expect(board.objects[note.id]?.frame.x == -2000, "the user's move is what ⌘Z undid")
        #expect(board.objects[preview.id]?.props["path"] == "b.ts", "the preview keeps its aim")
        #expect(board.restoreAim(try #require(reaimed.reaim).inverted) && board.objects[preview.id]?.props["path"] == "a.ts", "Back re-aims it")
        #expect(board.openCode(path: root.appendingPathComponent("c.ts").path, lines: nil, beside: terminal.id).id == preview.id, "after Back, still the terminal's one preview")
    }

    @Test func aCommandClickPreviewWhoseFileVanishedClosesButAKeptOneStays() throws {
        let board = makeBoard()
        for name in ["a.ts", "b.ts"] { try "x\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path), "command": .array([])]))
        let preview = board.openCode(path: root.appendingPathComponent("a.ts").path, lines: LineRange(start: 1, end: 1), beside: terminal.id)
        #expect(board.codeFileVanished(preview.id, path: "a.ts", existing: []) == .closed && board.objects[preview.id] == nil)
        let kept = board.openCode(path: root.appendingPathComponent("b.ts").path, lines: LineRange(start: 1, end: 1), beside: terminal.id)
        board.keepCode(kept.id)
        #expect(board.codeFileVanished(kept.id, path: "b.ts", existing: []) == .kept && board.objects[kept.id] != nil)
    }

    /// A new code tile without a frame is as wide as its file's longest line needs at its zoom
    /// (200 columns at most), never narrower than the default, so lines don't wrap where they
    /// needn't. The same files, and widths, as easld's TestANewCodeTileWithoutAFrameWidensToItsFilesLongestLine.
    @Test func aNewCodeTileWithoutAFrameWidensToItsFilesLongestLine() throws {
        let board = makeBoard()
        func write(_ name: String, _ bytes: [UInt8]) throws { try Data(bytes).write(to: root.appendingPathComponent(name)) }
        let a = [UInt8](repeating: UInt8(ascii: "a"), count: 100)
        try write("wide.ts", Array("short\r\n\t\(String(repeating: "x", count: 150))\r\nshort\r\n".utf8))  // CRLF dropped, the tab 4: 154 columns
        try write("cr.ts", a + Array("\ry\n".utf8))  // a lone CR stays a column, as the rows draw it: 102
        try write("bad.ts", a + [0xE2, 0x82, 0x0A])  // one U+FFFD for the cut-off sequence: 101
        try write("huge.js", Array("\(String(repeating: "y", count: 300))\n".utf8))
        try write("short.ts", Array("let a = 1\n".utf8))
        func width(_ columns: Int, lines: Int) -> Double {
            Double((CodeMetrics.gutterWidth(lineCount: lines) + CGFloat(columns) * CodeMetrics.charAdvance + CodeMetrics.trailingPadding).rounded(.up))
        }
        func created(_ props: [String: JSONValue], frame: Frame? = nil) -> Double { board.create(type: .code, props: .object(props), frame: frame).frame.w }
        let fallback = Board.defaultSize(.code).w
        #expect(created(["path": "wide.ts"]) == width(154, lines: 3), "the 154-column line fits unwrapped")
        #expect(created(["path": "cr.ts"]) == width(102, lines: 1) && created(["path": "bad.ts"]) == width(101, lines: 1))
        #expect(created(["path": "wide.ts", "zoom": .number(1.5)]) == (width(154, lines: 3) * 1.5).rounded(.up), "content drawn bigger needs a wider frame")
        #expect(created(["path": "huge.js"]) == Double(CodeMetrics.defaultFitWidth), "past 200 columns it stops; the rest wraps")
        #expect(created(["path": "short.ts"]) == fallback, "never narrower than the default")
        #expect(created(["path": "gone.ts"]) == fallback, "a missing file keeps the default")
        #expect(created(["path": "wide.ts", "pinnedCommit": "HEAD"]) == fallback && created(["path": "wide.ts", "ref": "main"]) == fallback,
                "a tile from git isn't measured from the working tree")
        #expect(created(["path": "wide.ts", "followOf": "obj_t"]) == fallback, "a follow tile keeps its size")
        #expect(created(["path": "wide.ts"], frame: Frame(x: 0, y: 0, w: 500, h: 300)) == 500, "a given frame stays")
        // A ⌘-click opens it as wide, also where only a narrower slot is in view: only its height is cut down.
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path), "command": .array([])]), frame: Frame(x: 0, y: 0, w: 1000, h: 620))
        board.viewport = { Frame(x: 0, y: 0, w: 1500, h: 700) }
        let opened = board.openCode(path: root.appendingPathComponent("wide.ts").path, lines: LineRange(start: 2, end: 2), beside: terminal.id)
        #expect(board.objects[opened.id]?.frame.w == width(154, lines: 3))
    }

    @Test func deletingATerminalDeletesItsFollowTileInTheSameUndoStep() throws {
        let board = makeBoard()
        try "x\n".write(to: root.appendingPathComponent("a.ts"), atomically: true, encoding: .utf8)
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path), "command": .array([])]))
        let other = board.create(type: .terminal, props: .object(["cwd": .string(root.path), "command": .array([])]))
        let follow = try #require(try board.follow(tile: terminal.id, path: "a.ts", range: nil, action: "read"))
        let kept = try #require(try board.follow(tile: other.id, path: "a.ts", range: nil, action: "read"))

        try board.delete(terminal.id)
        #expect(board.objects[follow.id] == nil)
        #expect(board.objects[kept.id] != nil, "other terminals' follow tiles stay")
        #expect(board.undo())
        #expect(board.objects[terminal.id] != nil && board.objects[follow.id] != nil)
        #expect(board.objects[terminal.id]?.props["follow"] == nil, "the cascade didn't turn following off")
    }
    @Test func placementKeepsClearOfOtherGroupsAndPrefersTheViewport() {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: 0, y: 0, w: 800, h: 500))
        // Another agent's group right of the terminal: only its padded region reaches the slot
        // beside the terminal, its member doesn't.
        let member = board.create(type: .note, props: .object(["markdown": .string("theirs")]), frame: Frame(x: 1500, y: -100, w: 300, h: 700))
        let group = board.create(type: .group, props: .object(["members": .array([.string(member.id)]), "padding": .number(60)]))
        let beside = board.place(width: 640, height: 446, near: terminal.id)
        #expect(!beside.intersects(group.frame) && !beside.intersects(terminal.frame))
        #expect(beside == Frame(x: 0, y: 524, w: 640, h: 446), "the next nearest slot: below the terminal")

        // On screen, a slot wholly in view beats a nearer one past the window's edge.
        board.viewport = { Frame(x: -1000, y: -100, w: 1900, h: 1000) }
        let inView = board.place(width: 640, height: 446, near: terminal.id)
        #expect(inView == Frame(x: -664, y: 0, w: 640, h: 446), "left of the terminal, the only side with room on screen")
        // A terminal the user isn't looking at keeps its tile beside it.
        board.viewport = { Frame(x: 5000, y: 5000, w: 1000, h: 800) }
        #expect(board.place(width: 640, height: 446, near: terminal.id) == beside)
    }

    @Test func anInViewSpotFarFromTheAuthorLosesToOneBesideItOutOfView() {
        // The orchestrator study: the agent's terminal sat at the top of the view with the
        // user's tiles left, right and below it; its note went to the only room in view,
        // 1,600 pt away beside another agent's terminal.
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: 0, y: 0, w: 1000, h: 620))
        board.create(type: .changes, props: .object([:]), frame: Frame(x: 1024, y: 0, w: 1000, h: 1300))
        board.create(type: .changes, props: .object([:]), frame: Frame(x: -1024, y: 0, w: 1000, h: 1300))
        board.create(type: .code, props: .object(["path": .string("a.ts")]), frame: Frame(x: 0, y: 644, w: 1000, h: 700))
        board.viewport = { Frame(x: -2600, y: -50, w: 5000, h: 1400) }
        let note = board.place(width: 640, height: 446, near: terminal.id)
        #expect(note == Frame(x: 0, y: -470, w: 640, h: 446), "above the terminal, mostly out of view, not in view \(Int(Board.nearbyDistance))+ pt away")

        // Within the cap the view still wins: with room in view 300 pt left of the terminal
        // (the left tile gone), that beats the nearer slot above.
        let close = makeBoard()
        let agent = close.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: 0, y: 0, w: 1000, h: 620))
        close.create(type: .changes, props: .object([:]), frame: Frame(x: 1024, y: 0, w: 1000, h: 1300))
        close.create(type: .code, props: .object(["path": .string("a.ts")]), frame: Frame(x: -300, y: 0, w: 276, h: 1344))
        close.create(type: .code, props: .object(["path": .string("b.ts")]), frame: Frame(x: 0, y: 644, w: 1000, h: 700))
        close.viewport = { Frame(x: -2600, y: -50, w: 5000, h: 1400) }
        let inView = close.place(width: 640, height: 446, near: agent.id)
        #expect(inView == Frame(x: -964, y: 0, w: 640, h: 446), "left of the tile beside the terminal, 324 pt from it, wholly in view")
    }

    @Test func userObjectsWithoutAFrameLandWhollyInViewWhenThereIsRoom() {
        let board = makeBoard()
        // A terminal in the middle of the view; the nearest free spot to the view center is just
        // above it, past the view's top edge, while there's room left and right of it.
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: -400, y: -250, w: 800, h: 500))
        let view = Frame(x: -1200, y: -700, w: 2400, h: 1400)
        board.viewport = { view }
        let code = board.create(type: .code, props: .object(["path": .string("main.ts")]))
        let inset = Frame(x: view.x + Board.placementGap, y: view.y + Board.placementGap, w: view.w - 2 * Board.placementGap, h: view.h - 2 * Board.placementGap)
        #expect(inset.contains(code.frame), "wholly inside the view, clear of its edges")
        #expect(!code.frame.intersects(terminal.frame))
        #expect(code.frame == Frame(x: -1064, y: -223, w: 640, h: 446), "the in-view spot nearest the center: left of the terminal, level with the center")
        #expect(code.createdBy == .user)

        // Beside a tile the user works in (Edit Here's terminal next to its code tile): in view too.
        let editor = board.place(width: 1000, height: 620, near: code.id)
        #expect(!editor.intersects(code.frame) && !editor.intersects(terminal.frame))
        #expect(inset.contains(editor) == false, "no room for a terminal that size in this view")
        #expect(editor.intersects(view), "partly in view beats wholly out of it when nothing fits")
    }

    @Test func partlyVisibleSlotsBeatOffscreenOnesOnlyWhenNothingFits() {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: -500, y: -310, w: 1000, h: 620))
        // A view barely larger than the terminal: no 640×446 slot fits in it.
        let view = Frame(x: -720, y: -435, w: 1440, h: 870)
        board.viewport = { view }
        let code = board.place(width: 640, height: 446, near: nil)
        #expect(!code.intersects(terminal.frame))
        #expect(code.intersects(Frame(x: view.x + Board.placementGap, y: view.y + Board.placementGap, w: view.w - 2 * Board.placementGap, h: view.h - 2 * Board.placementGap)),
                "part of it shows, so the user sees where it went")
        // Away from the view, the nearest free spot wins as before.
        board.viewport = { nil }
        #expect(board.place(width: 640, height: 446, near: nil) == Frame(x: -320, y: -780, w: 640, h: 446))
    }

    @Test func aPartlyVisibleSlotShowsItsTitleBar() {
        // The aider study: a terminal created through the API without a frame, on a view mostly
        // filled by another terminal, landed above it with its title bar under the toolbar.
        let board = makeBoard()
        board.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: -500, y: -310, w: 1000, h: 620))
        board.viewport = { Frame(x: -720, y: -435, w: 1440, h: 870) }
        #expect(board.place(width: 640, height: 446, near: nil) == Frame(x: -320, y: 334, w: 640, h: 446),
                "below the terminal, its title bar in view, not the as-near slot above with its top cut off")
    }

    @Test func aSpotChosenNearTheViewsEdgeStillLandsWhollyInTheView() {
        // New Terminal Here near the bottom-right of the view: the terminal's top-left at the
        // click would put its bottom under the tray and its right side past the window.
        let board = makeBoard()
        let view = Frame(x: -720, y: -380, w: 1440, h: 760)
        board.viewport = { view }
        let placed = board.place(Frame(x: 30, y: 70, w: 1000, h: 620))
        let inset = Frame(x: view.x + Board.placementGap, y: view.y + Board.placementGap, w: view.w - 2 * Board.placementGap, h: view.h - 2 * Board.placementGap)
        #expect(inset.contains(placed), "\(placed) is not wholly inside \(inset)")
    }

    @Test func aFollowTileBesideATerminalOnScreenLandsWhollyInViewShrunkWhenItMustBe() throws {
        // The codex2 study: a default 1000×620 terminal in the middle of a wide view left room for
        // only part of a 640-pt follow tile; it landed half off-screen.
        let board = makeBoard()
        try "x\n".write(to: root.appendingPathComponent("a.ts"), atomically: true, encoding: .utf8)
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]), frame: Frame(x: -500, y: -310, w: 1000, h: 620))
        let view = Frame(x: -988, y: -435, w: 1976, h: 870)
        board.viewport = { view }
        let follow = try #require(try board.follow(tile: terminal.id, path: "a.ts", range: nil, action: "read"))
        #expect(follow.frame == Frame(x: 524, y: -310, w: 440, h: 446), "right of the terminal, as wide as the view leaves, full height")
        #expect(Frame(x: view.x + Board.placementGap, y: view.y + Board.placementGap, w: view.w - 2 * Board.placementGap, h: view.h - 2 * Board.placementGap).contains(follow.frame))
        #expect(board.objects[follow.id]?.frame == follow.frame)

        // A sliver too narrow to read code in (198 pt in a 1492-pt view) is not worth it: full size beside the terminal.
        let narrow = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]), frame: Frame(x: -500, y: 2000, w: 1000, h: 620))
        board.viewport = { Frame(x: -746, y: 1875, w: 1492, h: 870) }
        #expect(try board.follow(tile: narrow.id, path: "a.ts", range: nil, action: "read")?.frame == Frame(x: 524, y: 2000, w: 640, h: 446))

        // With room in view, the full size; with the terminal offscreen, full size beside it.
        let wide = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]), frame: Frame(x: 3000, y: 0, w: 1000, h: 620))
        board.viewport = { Frame(x: 2900, y: -100, w: 2000, h: 900) }
        #expect(try board.follow(tile: wide.id, path: "a.ts", range: nil, action: "read")?.frame == Frame(x: 4024, y: 0, w: 640, h: 446))
        let away = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]), frame: Frame(x: 9000, y: 0, w: 1000, h: 620))
        #expect(try board.follow(tile: away.id, path: "a.ts", range: nil, action: "read")?.frame == Frame(x: 10024, y: 0, w: 640, h: 446))
    }

    /// An agent's frameless HTML answer.
    private func answer(on board: Board, by agent: CanvasObject) -> CanvasObject {
        board.create(type: .html, props: .object(["html": .string("<p>answer</p>")]), caller: agent.id)
    }

    @Test func anAgentsAnswersStackBelowTheFirstInsteadOfGoingRoundTheTerminal() {
        // The study: consecutive answers landed right, below, left of the terminal in turn.
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: 0, y: 0, w: 1000, h: 620))
        let answers = (0..<3).map { _ in answer(on: board, by: terminal).frame }
        #expect(answers == [Frame(x: 1024, y: 0, w: 640, h: 506), Frame(x: 1024, y: 530, w: 640, h: 506), Frame(x: 1024, y: 1060, w: 640, h: 506)])

        // Below the last one taken: right of it.
        let other = board.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: 0, y: 3000, w: 1000, h: 620))
        let first = answer(on: board, by: other)
        board.create(type: .note, props: .object(["markdown": .string("mine")]), frame: Frame(x: 1024, y: 3530, w: 640, h: 200))
        #expect(answer(on: board, by: other).frame == Frame(x: first.frame.maxX + Board.placementGap, y: 3000, w: 640, h: 506))
    }

    @Test func onlyTheAgentsOwnRecentLiveAnswersAreStackedOn() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: 0, y: 0, w: 1000, h: 620))
        _ = answer(on: board, by: terminal)
        let second = answer(on: board, by: terminal)
        // A deleted answer doesn't count: the next one takes its place under the first.
        try board.delete(second.id)
        #expect(answer(on: board, by: terminal).frame == second.frame)

        // Older than the window: beside the terminal again (right is taken, so below it).
        var snapshot = board.snapshot
        for index in snapshot.objects.indices where snapshot.objects[index].id != terminal.id {
            snapshot.objects[index].createdAt = Date().addingTimeInterval(-Board.answerStackWindow - 60)
        }
        let later = Board(snapshot: snapshot)
        #expect(answer(on: later, by: terminal).frame == Frame(x: 0, y: 644, w: 640, h: 506))

        // Another agent's object and the user's don't count. Theirs is taller than the terminal, so
        // below it is not a slot beside the terminal.
        let mixed = makeBoard()
        let mine = mixed.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: 0, y: 0, w: 1000, h: 620))
        let theirs = mixed.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: 5000, y: 0, w: 1000, h: 620))
        mixed.create(type: .html, props: .object(["html": .string("theirs")]), frame: Frame(x: 1024, y: 0, w: 640, h: 700), caller: theirs.id)
        mixed.create(type: .note, props: .object(["markdown": .string("user's")]), frame: Frame(x: -400, y: 0, w: 300, h: 300))
        #expect(answer(on: mixed, by: mine).frame == Frame(x: 0, y: 644, w: 640, h: 506), "below the terminal, not under theirs")
    }

    @Test func followTilesNeitherStackNorAreStackedOn() throws {
        let board = makeBoard()
        try "x\n".write(to: root.appendingPathComponent("a.ts"), atomically: true, encoding: .utf8)
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]), frame: Frame(x: 0, y: 0, w: 1000, h: 620))
        // Taller than the terminal: under it is not beside the terminal.
        board.create(type: .html, props: .object(["html": .string("first")]), frame: Frame(x: 1024, y: 0, w: 640, h: 700), caller: terminal.id)
        let follow = try #require(try board.follow(tile: terminal.id, path: "a.ts", range: nil, action: "read"))
        #expect(follow.frame == Frame(x: 0, y: 644, w: 640, h: 446), "beside the terminal, not under the answer")
        #expect(answer(on: board, by: terminal).frame == Frame(x: 1024, y: 724, w: 640, h: 506), "the follow tile isn't the last answer")

        // A short terminal: under its follow tile is not beside the terminal.
        let fresh = makeBoard()
        let agent = fresh.create(type: .terminal, props: .object(["cwd": .string(root.path)]), frame: Frame(x: 0, y: 0, w: 1000, h: 300))
        let followFirst = try #require(try fresh.follow(tile: agent.id, path: "a.ts", range: nil, action: "read"))
        #expect(followFirst.frame == Frame(x: 1024, y: 0, w: 640, h: 446))
        #expect(answer(on: fresh, by: agent).frame == Frame(x: 0, y: 324, w: 640, h: 506), "no answer yet: beside the terminal")
    }

    @Test func stackedAnswersStillPreferTheView() {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: 0, y: 0, w: 1000, h: 620))
        // A tall view: the stack stays in it.
        board.viewport = { Frame(x: -100, y: -100, w: 2000, h: 1800) }
        #expect((0..<3).map { _ in answer(on: board, by: terminal).frame.y } == [0, 530, 1060])

        // A short wide view: under the last answer is partly off-screen; left of the terminal fits.
        let wide = makeBoard()
        let agent = wide.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: 0, y: 0, w: 1000, h: 620))
        #expect(answer(on: wide, by: agent).frame == Frame(x: 1024, y: 0, w: 640, h: 506))
        wide.viewport = { Frame(x: -800, y: -100, w: 3000, h: 900) }
        #expect(answer(on: wide, by: agent).frame == Frame(x: -664, y: 0, w: 640, h: 506))

        // The last answer scrolled out of view, the terminal in it: beside the terminal, in view.
        let scrolled = makeBoard()
        let busy = scrolled.create(type: .terminal, props: .object(["cwd": .string("/")]), frame: Frame(x: 0, y: 0, w: 1000, h: 620))
        #expect(answer(on: scrolled, by: busy).frame == Frame(x: 1024, y: 0, w: 640, h: 506))
        scrolled.viewport = { Frame(x: -800, y: -100, w: 1820, h: 900) }
        #expect(answer(on: scrolled, by: busy).frame == Frame(x: -664, y: 0, w: 640, h: 506))
    }

    @Test func aBoardNeedsYouWhenAnAgentIsBlockedElseWhenOneFinishedUnseen() throws {
        let board = makeBoard()
        let a = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]))
        let b = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]))
        #expect(NeedsYou.of(board.objects.values) == nil, "no agents: nothing")
        try board.reportLifecycle(tile: a.id, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        try board.reportLifecycle(tile: b.id, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp")
        #expect(NeedsYou.of(board.objects.values) == nil, "working and idle say nothing")

        try board.reportLifecycle(tile: a.id, kind: "omp", state: .idle, message: nil, seq: 2, source: "canvas-omp")
        #expect(NeedsYou.of(board.objects.values) == NeedsYou(level: .done, terminals: [a.id], message: nil), "finished while nobody looked")

        try board.reportLifecycle(tile: b.id, kind: "omp", state: .blocked, message: "approve Edit?", seq: 2, source: "canvas-omp")
        #expect(NeedsYou.of(board.objects.values) == NeedsYou(level: .blocked, terminals: [b.id], message: "approve Edit?"), "blocked outranks done")

        try board.reportLifecycle(tile: b.id, kind: "omp", state: .working, message: nil, seq: 3, source: "canvas-omp")
        board.markSeen(a.id)
        #expect(NeedsYou.of(board.objects.values) == nil, "approved and seen: quiet again")
    }

    @Test func aGeminiApprovalCancelledWithEscEndsTheWaitWhenGeminiSaysItIsReady() throws {
        let board = makeBoard()
        let gemini = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]))
        let omp = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]))
        let start = 1_790_652_000_000_000
        func state(_ tile: CanvasObject) -> String? { board.objects[tile.id]?.props["lifecycle"]?["state"]?.string }
        try board.reportLifecycle(tile: gemini.id, kind: "gemini", state: .working, message: nil, seq: start, source: "canvas-gemini")
        board.terminalTitled(gemini.id, title: "✦  Working… (canvas)")
        try board.reportLifecycle(tile: gemini.id, kind: "gemini", state: .blocked, message: "Apply this change? (note.json)", seq: start + 1, source: "canvas-gemini", call: "c1")
        board.terminalTitled(gemini.id, title: "✋  Action Required (canvas)                ")
        #expect(NeedsYou.of(board.objects.values)?.terminals == [gemini.id])

        // Esc: "Request cancelled.", and no hook fires. Gemini's title is all that says so.
        board.terminalTitled(gemini.id, title: "◇  Ready (canvas)                                                               ", now: Date(timeIntervalSince1970: 1_790_652_001))
        #expect(state(gemini) == "idle")
        #expect(board.objects[gemini.id]?.props["lifecycle"]?["message"] == nil, "not the cancelled question")
        #expect(NeedsYou.of(board.objects.values) == nil, "⌘J has nowhere to go")
        try board.reportLifecycle(tile: gemini.id, kind: "gemini", state: .blocked, message: "Apply this change? (note.json)", seq: start + 1, source: "canvas-gemini", call: "c1")
        #expect(state(gemini) == "idle", "the dialog's report, replayed late, is older")

        // Only gemini, and only its wait for the user: a title never ends a turn or another agent's wait.
        try board.reportLifecycle(tile: gemini.id, kind: "gemini", state: .working, message: nil, seq: start + 2_000_000, source: "canvas-gemini")
        board.terminalTitled(gemini.id, title: "◇  Ready (canvas)")
        #expect(state(gemini) == "working")
        try board.reportLifecycle(tile: omp.id, kind: "omp", state: .blocked, message: "approve bash?", seq: 1, source: "canvas-omp")
        board.terminalTitled(omp.id, title: "◇  Ready (canvas)")
        #expect(state(omp) == "blocked")
    }

    @Test func clearingAllMarkersClearsEveryOneWithItsEvent() throws {
        let board = makeBoard()
        let notes = (0..<3).map { board.create(type: .note, props: .object(["markdown": .string("n\($0)")])) }
        for note in notes { try board.raiseAttention(note.id, message: nil, caller: nil) }
        var cleared: [ObjectID] = []
        board.onEvent = { event in
            if case .attentionChanged(let id, nil) = event { cleared.append(id) }
        }
        #expect(board.clearAllAttention() == notes.map(\.id).sorted())
        #expect(board.attention.isEmpty)
        #expect(cleared.sorted() == notes.map(\.id).sorted(), "each marker's view goes")
        #expect(board.clearAllAttention().isEmpty)
    }

    @Test func codeMentionContextIncludesTheRealExcerpt() async throws {
        let board = makeBoard()
        let file = root.appendingPathComponent("restore.ts")
        try "line one\nexport function restoreSnapshot() {\n  return 1\n}\n".write(to: file, atomically: true, encoding: .utf8)
        let code = board.create(type: .code, props: .object(["path": .string("restore.ts")]))
        try board.stage(.code(object: code.id, path: "restore.ts", lines: LineRange(start: 2, end: 3), side: nil, symbol: "restoreSnapshot"))
        let context = await board.drain().context
        #expect(context.contains("restore.ts:2-3 (symbol restoreSnapshot)"))
        #expect(context.contains("  > 2    export function restoreSnapshot() {"))
        #expect(context.contains("  > 3      return 1"))
        #expect(context.contains("    1    line one"), "short mentions carry unmarked surrounding lines")

        let long = root.appendingPathComponent("long.txt")
        try (1...40).map { "row \($0)" }.joined(separator: "\n").write(to: long, atomically: true, encoding: .utf8)
        let tile = board.create(type: .code, props: .object(["path": .string("long.txt")]))
        try board.stage(.code(object: tile.id, path: "long.txt", lines: LineRange(start: 5, end: 30), side: nil, symbol: nil))
        let capped = await board.drain().context
        #expect(capped.contains("  > 16   row 16"))
        #expect(!capped.contains("row 17") && !capped.contains("row 4\n"), "long ranges cap at 12 lines with no extra context")
        #expect(capped.contains("    …"))
    }

    @Test func domChipsLeadWithTextTagAndTileAndEndWithTheSelector() throws {
        let board = makeBoard()
        let page = board.create(type: .browser, props: .object(["url": .string("http://localhost:3000/blog"), "title": .string("Blog")]))
        func label(_ selector: String, _ text: String?) throws -> String {
            try board.stage(.dom(object: page.id, url: "http://localhost:3000/blog", selector: selector, text: text)).label
        }
        #expect(try label("body > main > div:nth-of-type(2) > strong", "navigation") == "\"navigation\" · strong · Blog · body > main > div:nth-of-type(2) > strong")
        #expect(try label("#discussion_r1 > div > p:nth-of-type(1)", nil) == "p · Blog · #discussion_r1 > div > p:nth-of-type(1)", "no text: the tag leads")
        #expect(try label("#submit", "Sign in") == "\"Sign in\" · Blog · #submit", "an id selector names no tag")
        #expect(try label("a[aria-label=\"a > b\"]", "Next") == "\"Next\" · a · Blog · a[aria-label=\"a > b\"]", "attribute values may contain ` > `")
    }

    @Test func drawnShapeMentionDescribesWhatItEnclosesAndWhatItIsDrawnOn() async throws {
        let board = makeBoard()
        let inner = board.create(type: .note, props: .object(["markdown": .string("inside")]), frame: Frame(x: 20, y: 20, w: 50, h: 50))
        let box = board.create(type: .shape, props: .object(["kind": .string("rect"), "text": .string("auth path?")]), frame: Frame(x: 0, y: 0, w: 200, h: 200))
        try board.stage(.object(box.id))
        let context = await board.drain().context
        #expect(context.contains("drawn by user"))
        #expect(context.contains("encloses \(inner.id)"))
        #expect(!context.contains("· over"), "nothing lies under the box")

        let page = board.create(type: .browser, props: .object(["url": .string("http://localhost/")]), frame: Frame(x: 1000, y: 0, w: 600, h: 400))
        let upper = board.create(type: .browser, props: .object(["url": .string("http://localhost/b")]), frame: Frame(x: 1000, y: 0, w: 600, h: 400))
        let circle = board.create(type: .shape, props: .object(["kind": .string("ellipse")]), frame: Frame(x: 1240, y: 226, w: 125, h: 120))
        let straddling = board.create(type: .shape, props: .object(["kind": .string("rect")]), frame: Frame(x: 1500, y: 300, w: 200, h: 50))
        try board.stage(.object(circle.id))
        try board.stage(.object(straddling.id))
        let over = await board.drain().context
        #expect(over.contains("\(circle.id) \"ellipse\" (drawn by user) · over browser \(upper.id) at (240, 200) 125×120"), "the topmost containing tile, in its local units (below its title bar)")
        #expect(!over.contains(page.id))
        #expect(!over.contains("\(straddling.id) \"rect\" (drawn by user) · over"), "a box that only partly covers a tile isn't drawn on it")

        // On a tile whose content is at 2×, the same spot is half as many content points in, below the 1× title bar.
        let zoomed = board.create(type: .browser, props: .object(["url": .string("http://localhost/c"), "zoom": .number(2)]), frame: Frame(x: 3000, y: 0, w: 1200, h: 800))
        let mark = board.create(type: .shape, props: .object(["kind": .string("ellipse")]), frame: Frame(x: 3480, y: 426, w: 250, h: 240))
        try board.stage(.object(mark.id))
        let onZoomed = await board.drain().context
        #expect(onZoomed.contains("\(mark.id) \"ellipse\" (drawn by user) · over browser \(zoomed.id) at (240, 200) 125×120"))
    }

    @Test func drawingMentionsCarryTheWholeNoteWhatTheyAreOnAndThePageUnderThem() async throws {
        let board = makeBoard()
        let page = board.create(type: .browser, props: .object(["url": .string("http://localhost/gui")]), frame: Frame(x: 0, y: 0, w: 400, h: 900))
        let note = "dots dangle at line ends: keep link + dot together, one per line on phone?\nand the footer"
        // Two thirds of the note lies on the page.
        let text = board.create(type: .shape, props: ShapeSpec(kind: .text, text: note).props, frame: Frame(x: -100, y: 300, w: 300, h: 60))
        try board.stage(.object(text.id))
        let context = await board.drain().context
        #expect(context.contains("\"dots dangle at line ends: keep link + dot together, one per line on phone?\\nand the footer\" (drawn by user)"), "all of the note")
        #expect(context.contains("· partly over browser \(page.id) at (0, 274) 200×60"), "the part on the page, in the page tile's units")

        var asked: (ObjectID, CGRect)?
        board.pageElements = { id, rect in
            asked = (id, rect)
            return PageElements(url: "http://localhost/gui", elements: [.init(selector: "ul > li:nth-of-type(1) > a", text: "resume (pdf)"), .init(selector: "ul > li:nth-of-type(2) > a", text: "")], more: 3)
        }
        let box = board.create(type: .shape, props: .object(["kind": .string("rect")]), frame: Frame(x: 20, y: 600, w: 200, h: 100))
        try board.stage(.object(box.id))
        let listed = await board.drain().context
        #expect(asked?.0 == page.id && asked?.1 == CGRect(x: 20, y: 600, width: 200, height: 100), "the page is asked about the box's region")
        #expect(listed.contains("""
                                    page elements under it (http://localhost/gui):
                                      ul > li:nth-of-type(1) > a "resume (pdf)"
                                      ul > li:nth-of-type(2) > a
                                      … 3 more
                                """))
    }

    @Test func hyperClickingADrawingTakesItsSelectionOrItsDrawingGroup() throws {
        let board = makeBoard()
        let tile = board.create(type: .note, props: .object(["markdown": .string("n")]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        func ink(_ x: Double) -> CanvasObject {
            board.create(type: .shape, props: ShapeSpec(kind: .ink, points: [InkPoint(x: 0, y: 0), InkPoint(x: 40, y: 2)]).props, frame: Frame(x: x, y: 300, w: 40, h: 4))
        }
        let first = ink(0), second = ink(60), lone = ink(120)
        let arrow = board.create(type: .arrow, props: ArrowSpec(from: .object(first.id), to: .object(tile.id)).props)
        _ = board.create(type: .group, props: .object(["members": .array([first.id, second.id, arrow.id].map(JSONValue.string)), "title": .string("underline")]))
        _ = board.create(type: .group, props: .object(["members": .array([lone.id, tile.id].map(JSONValue.string))]))

        #expect(MentionContext.drawingTarget(first.id, selection: [], on: board) == .group(objects: [first.id, second.id, arrow.id], name: "underline"),
                "a stroke of a group of drawings: the whole sketch")
        #expect(MentionContext.drawingTarget(lone.id, selection: [], on: board) == .object(lone.id), "a group with a tile in it isn't a sketch")
        #expect(MentionContext.drawingTarget(lone.id, selection: [lone.id, second.id], on: board) == .group(objects: [lone.id, second.id].sorted(), name: nil),
                "part of a selection of several: all of it")
        #expect(MentionContext.drawingTarget(lone.id, selection: [second.id, first.id], on: board) == .object(lone.id), "a selection it isn't part of doesn't count")
    }

    @Test func boardsSavedBeforeFormat2GrowTileFramesByTheTitleBarOnce() throws {
        // Format 1 stored a tile's body; its 26 pt title bar drew above it. Shapes were exact.
        let legacy = """
        {"id":"brd_old","root":"/tmp","revision":3,"objects":[
          {"id":"obj_code","type":"code","frame":{"x":10,"y":20,"w":640,"h":240},"z":1,"rev":1,"createdBy":{"kind":"user"},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","props":{"path":"a.swift"}},
          {"id":"obj_note","type":"note","frame":{"x":700,"y":20,"w":280,"h":240},"z":2,"rev":1,"createdBy":{"kind":"user"},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","props":{"markdown":"n"}},
          {"id":"obj_box","type":"shape","frame":{"x":0,"y":400,"w":100,"h":50},"z":3,"rev":1,"createdBy":{"kind":"user"},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","props":{"kind":"rect"}},
          {"id":"obj_lane","type":"group","frame":{"x":0,"y":0,"w":0,"h":0},"z":4,"rev":1,"createdBy":{"kind":"user"},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","props":{"members":["obj_code"],"padding":24}}
        ]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(BoardSnapshot.self, from: Data(legacy.utf8))
        #expect(snapshot.format == nil)
        let board = Board(snapshot: snapshot)
        #expect(try board.object("obj_code").frame == Frame(x: 10, y: 20, w: 640, h: 266), "the same box on screen, now all of it")
        #expect(try board.object("obj_note").frame.h == 266)
        #expect(try board.object("obj_box").frame == Frame(x: 0, y: 400, w: 100, h: 50), "shapes were already their drawn box")
        let lane = try board.object("obj_lane").frame
        #expect(lane.maxY == 20 + 266 + 24, "groups wrap the migrated tile, bottom padding intact")

        let saved = board.snapshot
        #expect(saved.format == Board.format)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reloaded = Board(snapshot: try decoder.decode(BoardSnapshot.self, from: try encoder.encode(saved)))
        #expect(try reloaded.object("obj_code").frame.h == 266, "a format-2 board loads as saved")
    }

    @Test func savedScaleBecomesZoomWithTheFrameKeptAndReloadingChangesNothing() throws {
        // Before zoom, `scale` magnified a tile's title bar and content inside its frame, and a
        // text shape's font.
        func object(_ id: String, _ type: String, _ frame: String, _ props: String) -> String {
            #"{"id":"\#(id)","type":"\#(type)","frame":\#(frame),"z":1,"rev":1,"createdBy":{"kind":"user"},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","props":\#(props)}"#
        }
        let saved = """
        {"format":2,"id":"brd_scaled","root":"/tmp","revision":3,"objects":[
          \(object("obj_term", "terminal", #"{"x":0,"y":0,"w":1500,"h":930}"#, #"{"cwd":"/","scale":1.5}"#)),
          \(object("obj_code", "code", #"{"x":1600,"y":0,"w":640,"h":446}"#, #"{"path":"a.swift","scale":0.75,"zoom":1.25}"#)),
          \(object("obj_page", "browser", #"{"x":0,"y":1000,"w":1000,"h":726}"#, #"{"url":"http://localhost/","scale":1}"#)),
          \(object("obj_pic", "image", #"{"x":1100,"y":1000,"w":640,"h":506}"#, #"{"path":"a.png","scale":2}"#)),
          \(object("obj_text", "shape", #"{"x":0,"y":2000,"w":90,"h":58}"#, #"{"kind":"text","text":"hi","scale":2}"#)),
          \(object("obj_box", "shape", #"{"x":200,"y":2000,"w":100,"h":50}"#, #"{"kind":"rect","scale":2}"#))
        ]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let board = Board(snapshot: try decoder.decode(BoardSnapshot.self, from: Data(saved.utf8)))
        let terminal = try board.object("obj_term")
        #expect(terminal.frame == Frame(x: 0, y: 0, w: 1500, h: 930), "the tile keeps its size on screen")
        #expect(terminal.props == .object(["cwd": "/", "zoom": .number(1.5)]) && terminal.zoom == 1.5, "its content keeps its size")
        #expect(try board.object("obj_code").props == .object(["path": "a.swift", "zoom": .number(1.25)]), "a zoom already there wins")
        #expect(try board.object("obj_page").props == .object(["url": "http://localhost/"]), "1 is no zoom")
        #expect(try board.object("obj_pic").props == .object(["path": "a.png"]), "images don't zoom")
        let text = try board.object("obj_text")
        #expect(text.props == .object(["kind": "text", "text": "hi", "textSize": 2]) && text.frame == Frame(x: 0, y: 2000, w: 90, h: 58))
        #expect(try board.object("obj_box").props == .object(["kind": "rect"]))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reloaded = Board(snapshot: try decoder.decode(BoardSnapshot.self, from: try encoder.encode(board.snapshot)))
        #expect(reloaded.objects == board.objects, "migrating again is a no-op")
    }

    @Test func aRenamedTextShapeDrawsItsTextAtTheSameSize() async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = #"{"format":2,"id":"brd_text","root":"/tmp","revision":1,"objects":[{"id":"obj_text","type":"shape","frame":{"x":0,"y":0,"w":90,"h":58},"z":1,"rev":1,"createdBy":{"kind":"user"},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","props":{"kind":"text","text":"Deploy step","scale":1.5}}]}"#
        let text = try Board(snapshot: try decoder.decode(BoardSnapshot.self, from: Data(saved.utf8))).object("obj_text")
        let spec = try #require(ShapeSpec(text.props))
        // What `scale: 1.5` drew: the 20-point text font at 30 points.
        #expect(DrawingStyle.textPointSize * spec.textSize == 30)
        let label = DrawingStyle.text("Deploy step", size: 30, color: .labelColor).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).size
        let measured = try await ObjectMeasure.size(type: .shape, props: text.props, width: nil, root: root)
        #expect(measured.width >= label.width && measured.width <= label.width + 4 && measured.height >= label.height && measured.height <= label.height + 4)
        #expect(TextShapeLayout.size("Deploy step", textSize: spec.textSize, wrapWidth: nil) == measured, "typing into it keeps that size")
    }

    @Test func zoomingATerminalsContentGivesItFewerBiggerCellsInTheSameFrame() throws {
        let board = makeBoard()
        let terminal = board.create(type: .terminal, props: .object(["cwd": "/"]), frame: Frame(x: 0, y: 0, w: 1000, h: 620))
        let cell = CGSize(width: 8.4, height: 17), padding = CGSize(width: 2, height: 2)
        let actual = TerminalGrid.size(of: terminal, cell: cell, padding: padding)
        #expect(actual.columns == 118 && actual.rows == 34)
        let zoomed = try board.update(terminal.id, props: .object(["zoom": .number(1.5)]))
        #expect(zoomed.frame == terminal.frame)
        let grid = TerminalGrid.size(of: zoomed, cell: cell, padding: padding)
        #expect(grid.columns == 78 && grid.rows == 23, "the body is 666 × 396 content points at 150%")
        let out = try board.update(terminal.id, props: .object(["zoom": .number(0.67)]))
        #expect(TerminalGrid.size(of: out, cell: cell, padding: padding).columns == 177 && out.frame == terminal.frame)
    }

    @Test func aTileIsReadableAtTheBoardsMagnificationTimesItsContentZoom() {
        let board = makeBoard()
        let plain = board.create(type: .terminal, props: .object(["cwd": "/"]), frame: Frame(x: 0, y: 0, w: 1000, h: 620))
        let zoomedIn = board.create(type: .terminal, props: .object(["cwd": "/", "zoom": 2]), frame: Frame(x: 0, y: 700, w: 1000, h: 620))
        let zoomedOut = board.create(type: .code, props: .object(["path": "a.swift", "zoom": .number(0.5)]), frame: Frame(x: 1100, y: 0, w: 640, h: 446))
        let picture = board.create(type: .image, props: .object(["path": "a.png", "zoom": 2]), frame: Frame(x: 1100, y: 700, w: 640, h: 506))
        #expect(RenderMath.isZoomedOut(plain, magnification: 0.2) && !RenderMath.isZoomedOut(zoomedIn, magnification: 0.2), "200% content on a 20% board shows at 40%")
        #expect(!RenderMath.isZoomedOut(plain, magnification: 0.5) && RenderMath.isZoomedOut(zoomedOut, magnification: 0.5), "50% content on a 50% board shows at 25%")
        #expect(RenderMath.isZoomedOut(picture, magnification: 0.2), "an image doesn't zoom")
    }
}
