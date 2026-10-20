import Foundation
import Testing
@testable import CanvasCore

/// An agent working in a `git worktree` of the board's repository: another directory sharing
/// the repository's common git directory, outside the board root.
@MainActor
struct WorktreeTests {
    /// The board's repository with one commit, and a linked worktree of it (branch `feature`)
    /// in a sibling directory named `fees`.
    func fixture() async throws -> (repo: TempRepo, worktree: URL) {
        let repo = try await TempRepo()
        try await repo.write("src/fees.ts", "one\ntwo\nthree\n")
        try await repo.commit("init")
        let worktree = URL(fileURLWithPath: repo.root.path + "-wt/fees")
        try await repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        return (repo, worktree)
    }

    @Test func followShowsAnotherWorktreesFileWithItsOwnChanges() async throws {
        let (repo, worktree) = try await fixture()
        let board = Board(id: "brd_test", root: repo.root)
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(repo.root.path), "command": .array([])]))
        let file = worktree.appendingPathComponent("src/fees.ts")
        try "one\nTWO\nthree\n".write(to: file, atomically: true, encoding: .utf8)

        let follow = try #require(try board.follow(tile: terminal.id, path: file.path, range: LineRange(start: 2, end: 2), action: "edit"))
        #expect(follow.props["path"]?.string == file.path, "outside the root the path stays absolute")
        // Its gutter comes from its own worktree: the edit shows there, the board's copy is clean.
        let engine = GitDiffEngine(watchesRepositories: false)
        #expect(await engine.diff(file: file, base: .head).state == .modified)
        #expect(await engine.diff(file: repo.url("src/fees.ts"), base: .head).state == .unchanged)

        // Another repository is still outside the project.
        let other = try await TempRepo()
        try await other.write("src/fees.ts", "x\n")
        #expect(try board.follow(tile: terminal.id, path: other.url("src/fees.ts").path, range: nil, action: "read") == nil)
        #expect(board.objects[follow.id]?.props["path"]?.string == file.path)
    }

    @Test func aPinnedCommitReadsAnotherWorktreesFileAndMissingOnesAreNotFound() async throws {
        let (repo, worktree) = try await fixture()
        let file = worktree.appendingPathComponent("src/fees.ts")
        try "one\nfeature two\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        try await TempRepo.run(["commit", "-q", "-a", "-m", "feature"], in: worktree)
        let sha = try await TempRepo.run(["rev-parse", "HEAD"], in: worktree)
        try "changed on disk\n".write(to: file, atomically: true, encoding: .utf8)

        let pinned = await NoteSource.excerpt(for: NoteFence(path: file.path, commit: sha, lines: LineRange(start: 2, end: 2)), root: repo.root, captured: nil)
        #expect(pinned.lines == ["feature two"])

        func failure(_ path: String, commit: String?) async -> ObjectMeasure.Failure? {
            var props: [String: JSONValue] = ["path": .string(path), "range": .object(["start": .number(1), "end": .number(1)])]
            if let commit { props["pinnedCommit"] = .string(commit) }
            do {
                _ = try await ObjectMeasure.codeExcerpt(.object(props), root: repo.root)
                return nil
            } catch {
                return error as? ObjectMeasure.Failure
            }
        }
        try "new\n".write(to: worktree.appendingPathComponent("src/new.ts"), atomically: true, encoding: .utf8)
        let untracked = worktree.appendingPathComponent("src/new.ts").path
        #expect(await failure(untracked, commit: sha) == .notFound("\(untracked) does not exist at \(sha)"))
        #expect(await failure(file.path, commit: "0123456") == .notFound("unknown commit 0123456"))
        #expect(await failure("src/gone.ts", commit: nil) == .notFound("no file src/gone.ts"))
        #expect(await failure(untracked, commit: nil) == nil, "on disk it reads")
    }

    @Test func filesOutsideTheRootAreNamedByTheirWorktreeAndRepoPath() async throws {
        let (repo, worktree) = try await fixture()
        let file = worktree.appendingPathComponent("src/fees.ts").path
        #expect(PathLabel.short(file) == "fees/src/fees.ts")
        #expect(PathLabel.short("src/fees.ts") == "src/fees.ts", "paths under the root are already short")
        #expect(PathLabel.short(repo.url("src/fees.ts").path) == "\(repo.root.lastPathComponent)/src/fees.ts")
        let loose = NSTemporaryDirectory() + "no-repo-\(UUID().uuidString)/a.ts"
        #expect(PathLabel.short(loose) == loose, "outside git the path is all there is")

        // Tray chips; the mention itself keeps the absolute path for the agent.
        let board = Board(id: "brd_test", root: repo.root)
        let tile = board.create(type: .code, props: .object(["path": .string(file)]))
        let line = try board.stage(.code(object: tile.id, path: file, lines: LineRange(start: 2, end: 2), symbol: "fee"))
        #expect(line.label == "fees/src/fees.ts:2 fee")
        #expect(try board.stage(.object(tile.id)).label == "code fees/src/fees.ts")
        let drained = await board.drain(peek: true)
        #expect(drained.context.contains("code \(file):2-2"))
    }

    /// An agent terminal working in `directory` (its `props.cwd`; the app adds the shell's
    /// reported directory).
    func agent(on board: Board, in directory: URL, frame: Frame? = nil) -> CanvasObject {
        board.create(type: .terminal, props: .object([
            "cwd": .string(directory.path), "command": .array([]),
            "agent": .object(["kind": .string("omp")]), "lifecycle": .object(["state": .string("idle")]),
        ]), frame: frame)
    }

    @Test func aMentionFromAnotherWorktreeTargetsTheOneAgentWorkingThere() async throws {
        let (repo, worktree) = try await fixture()
        let second = URL(fileURLWithPath: repo.root.path + "-wt/other")
        try await repo.git("worktree", "add", "-q", "-b", "other", second.path)
        let board = Board(id: "brd_test", root: repo.root)
        let main = agent(on: board, in: repo.root)
        let fees = agent(on: board, in: worktree.appendingPathComponent("src"))
        let shell = board.create(type: .terminal, props: .object(["cwd": .string(worktree.path), "command": .array([])]))
        let review = board.create(type: .changes, props: .object(["root": .string(worktree.path)]))
        let checkouts = Dictionary(uniqueKeysWithValues: [main, fees, shell].map { ($0.id, GitWorktree.containing(board.workingDirectory(of: $0.id))!) })
        func target(_ mention: MentionTarget, current: ObjectID?) -> ObjectID? {
            PromptTarget.checkout(of: mention, on: board).flatMap { PromptTarget.affinity(checkout: $0, current: current, checkouts: checkouts, objects: board.objects) }
        }

        // The worktree's changes tile, or a line of a file in it (/private/tmp spelling too):
        // its agent, not the plain shell in the same checkout.
        #expect(target(.object(review.id), current: main.id) == fees.id)
        let line = MentionTarget.code(object: review.id, path: "/private" + worktree.appendingPathComponent("src/fees.ts").path, lines: LineRange(start: 2, end: 2))
        #expect(target(line, current: main.id) == fees.id)
        #expect(target(line, current: nil) == fees.id, "no target yet")
        // Already the right agent, or a mention in the target's own checkout: nothing moves.
        #expect(target(line, current: fees.id) == nil)
        #expect(target(.code(object: review.id, path: "src/fees.ts", lines: LineRange(start: 1, end: 1)), current: main.id) == nil)
        // Back in the board's checkout from the worktree agent: the one agent there.
        #expect(target(.code(object: review.id, path: "src/fees.ts", lines: LineRange(start: 1, end: 1)), current: fees.id) == main.id)
        // A checkout nobody's agent works in, and one two agents work in: the target stays.
        let otherReview = board.create(type: .changes, props: .object(["root": .string(second.path)]))
        #expect(target(.object(otherReview.id), current: main.id) == nil)
        let twin = agent(on: board, in: worktree)
        var both = checkouts
        both[twin.id] = GitWorktree.containing(worktree.path)
        #expect(PromptTarget.affinity(checkout: GitWorktree.containing(worktree.path)!, current: main.id, checkouts: both, objects: board.objects) == nil)
        // Pages, terminals and drawings name no checkout.
        #expect(PromptTarget.checkout(of: .terminal(object: fees.id, text: "x"), on: board) == nil)
    }

    @Test func aWorktreeAgentsNotesResolveAgainstItsCheckout() async throws {
        let (repo, worktree) = try await fixture()
        let board = Board(id: "brd_test", root: repo.root)
        let main = agent(on: board, in: repo.root)
        let fees = agent(on: board, in: worktree.appendingPathComponent("src"))

        // The default: the creating agent's checkout when it isn't the board's.
        #expect(board.callerCheckout(for: fees.id) == worktree.path)
        #expect(board.callerCheckout(for: main.id) == nil)
        #expect(board.callerCheckout(for: nil) == nil, "the user's notes resolve against the board root")
        // Where it works now (its program's or shell's directory) wins over props.cwd.
        board.terminalWorks(main.id, in: worktree.path)
        #expect(board.callerCheckout(for: main.id) == worktree.path)
        board.terminalWorks(main.id, in: repo.root.path)

        // Links written in the worktree agent's note open its checkout's file; absolute ones stay.
        let note = board.create(type: .note, props: .object(["markdown": .string("tests/x.ts:16"), "root": .string(worktree.path)]))
        #expect(board.linkRoot(of: note).path == worktree.path)
        #expect(board.boardPath("src/fees.ts", linkRoot: board.linkRoot(of: note)) == worktree.appendingPathComponent("src/fees.ts").path)
        #expect(board.boardPath("src/fees.ts", linkRoot: board.root) == "src/fees.ts")
        let relative = board.create(type: .html, props: .object(["html": .string(""), "root": .string("../\(repo.root.lastPathComponent)-wt/fees")]))
        #expect(board.linkRoot(of: relative).path == worktree.path, "board-relative roots resolve against the board root")

        // Only the board's own repository and its worktrees.
        try board.checkLinkRoot(worktree.path)
        try board.checkLinkRoot(repo.root.appendingPathComponent("src").path)
        let stranger = try await TempRepo()
        #expect(throws: BoardError.self) { try board.checkLinkRoot(stranger.root.path) }
        #expect(throws: BoardError.self) { try board.checkLinkRoot(worktree.appendingPathComponent("missing").path) }
        #expect(throws: BoardError.self) { try board.checkLinkRoot(worktree.appendingPathComponent("src/fees.ts").path) }
    }

    @Test func aBoardRootedInASubdirectoryMapsTheWorktreeToTheSamePlace() async throws {
        let (repo, worktree) = try await fixture()
        let board = Board(id: "brd_test", root: repo.root.appendingPathComponent("src"))
        let fees = agent(on: board, in: worktree)
        #expect(board.callerCheckout(for: fees.id) == worktree.appendingPathComponent("src").path)
    }

    /// The hero take: Claude, working in a worktree, made code tiles of `Sources/…` and a
    /// diagram, and they read the main checkout. A worktree agent's relative paths are its own
    /// checkout's, as its notes' links already were; the user's and the main checkout's agents'
    /// stay board-relative, and a tile anchored to a branch keeps its repo path.
    @Test func aWorktreeAgentsTilesReadItsCheckout() async throws {
        let (repo, worktree) = try await fixture()
        let home = URL(fileURLWithPath: "/tmp/cv-wt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = BoardRegistry(store: BoardStore(directory: home.appendingPathComponent("boards"), debounce: 60))
        let board = try await registry.open(root: repo.root)
        let router = ApiRouter(registry: registry)
        let server = SocketServer(path: home.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        defer { server.stop() }
        let fees = agent(on: board, in: worktree.appendingPathComponent("src"))
        let main = agent(on: board, in: repo.root)
        func call(_ method: String, _ params: String, caller: ObjectID?) async throws -> JSONValue {
            let client = try LineClient(path: home.appendingPathComponent("s").path)
            let from = caller.map { #","caller":"\#($0)""# } ?? ""
            client.send(#"{"id":"1","method":"\#(method)","params":{\#(params)\#(from)}}"#)
            let reply = try await client.next()
            #expect(reply["ok"] == .bool(true), "\(reply["error"] ?? .null)")
            return reply["result"]?["object"] ?? .null
        }
        func create(_ type: String, _ props: String, caller: ObjectID?) async throws -> JSONValue {
            try await call("object.create", #""type":"\#(type)","props":\#(props)"#, caller: caller)
        }
        let inWorktree = worktree.appendingPathComponent("src/fees.ts").path

        let code = try await create("code", #"{"path":"src/fees.ts"}"#, caller: fees.id)
        #expect(code["props"]?["path"] == .string(inWorktree))
        #expect(try await create("diagram", #"{"symbol":"fee","path":"src/fees.ts"}"#, caller: fees.id)["props"]?["path"] == .string(inWorktree))
        #expect(try await create("changes", #"{"base":"merge-base"}"#, caller: fees.id)["props"]?["root"] == .string(worktree.path), "its branch, not main against main")
        #expect(try await create("note", #"{"markdown":"src/fees.ts:2"}"#, caller: fees.id)["props"]?["root"] == .string(worktree.path))
        // Re-aimed by a relative path: still its checkout.
        let id = try #require(code["id"]?.string)
        try "x\n".write(toFile: worktree.appendingPathComponent("src/b.ts").path, atomically: true, encoding: .utf8)
        let reaimed = try await call("object.update", #""id":"\#(id)","props":{"path":"src/b.ts"}"#, caller: fees.id)
        #expect(reaimed["props"]?["path"] == .string(worktree.appendingPathComponent("src/b.ts").path))

        // A branch-anchored tile, the main checkout's agent and the user: board-relative.
        #expect(try await create("code", #"{"path":"src/fees.ts","ref":"feature"}"#, caller: fees.id)["props"]?["path"] == .string("src/fees.ts"))
        #expect(try await create("code", #"{"path":"src/fees.ts"}"#, caller: main.id)["props"]?["path"] == .string("src/fees.ts"))
        #expect(try await create("code", #"{"path":"src/fees.ts"}"#, caller: nil)["props"]?["path"] == .string("src/fees.ts"))
        #expect(try await create("changes", #"{"base":"merge-base"}"#, caller: main.id)["props"]?["root"] == nil)
    }

    /// Hover and ⌘-click on a worktree's tiles said "No definition found": its files' server was
    /// rooted at the file's directory, not the worktree's package, so it had no build index.
    @Test func aWorktreesFilesAreReadAsThatCheckoutsProject() async throws {
        let (repo, _) = try await fixture()
        // Not beside the main checkout: a path sharing its prefix hid the bug.
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)")
        try await repo.git("worktree", "add", "-q", "-b", "lsp", worktree.path)
        defer { try? FileManager.default.removeItem(at: worktree) }
        for checkout in [repo.root, worktree] {
            try "// swift-tools-version: 6.0\n".write(to: checkout.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        }
        let file = worktree.appendingPathComponent("src/a.hang")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x\n".write(to: file, atomically: true, encoding: .utf8)
        // A server that never answers: only where it was started is looked at.
        let config = LanguageServerConfig(language: "hang", command: "/bin/sh", arguments: ["-c", "exec /usr/bin/tail -f /dev/null"],
                                          languageIDs: ["hang": "hang"], rootMarkers: ["Package.swift"])
        let service = LanguageService(configs: [config])
        let asking = Task { try? await service.hover(file: file, boardRoot: repo.root, at: LSPPosition(line: 0, character: 0)) }
        var server: LanguageServer?
        for _ in 0..<100 where server == nil {
            server = await service.existingServer(for: file, boardRoot: repo.root)
            if server == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(server?.root == GitDiffEngine.realPath(worktree))
        asking.cancel()
        await service.stopAll()
    }

    /// A diagram is of the checkout its root's file lies in, else its agent's, else the one the
    /// user opened the board from.
    @Test func aDiagramIsOfItsRootsCheckout() async throws {
        let (repo, worktree) = try await fixture()
        let board = try await BoardRegistry(store: BoardStore(directory: URL(fileURLWithPath: repo.root.path + "-boards"), debounce: 60)).open(root: repo.root)
        let fees = agent(on: board, in: worktree)
        let languages = LanguageService(configs: [])
        func scope(_ props: JSONValue, caller: ObjectID? = nil) async throws -> String {
            try await DiagramRefresh.scope(of: board.create(type: .diagram, props: props, caller: caller), on: board, languages: languages).path
        }
        #expect(try await scope(.object(["symbol": .string("fee"), "path": .string(worktree.appendingPathComponent("src/fees.ts").path)])) == worktree.path)
        #expect(try await scope(.object(["symbol": .string("fee"), "path": .string("src/fees.ts")])) == board.root.path)
        #expect(try await scope(.object(["symbol": .string("fee")]), caller: fees.id) == worktree.path, "a bare symbol: where its agent works")
        #expect(try await scope(.object(["symbol": .string("fee")])) == board.root.path)
        board.opened(from: WorktreeVisit(try #require(GitWorktree.containing(worktree.path))))
        #expect(board.workingRoot.path == worktree.path)
        #expect(try await scope(.object(["symbol": .string("fee")])) == worktree.path, "the user's: the checkout they opened")
    }
}
