import Foundation
import Testing
@testable import CanvasCore

/// One board per repository (docs/design/repo-boards.md): legacy per-branch boards merge into it
/// once, re-rooted, and a worktree opens its repository's board.
@MainActor
struct RepoBoardTests {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-repo-boards-\(UUID().uuidString)")
    var boards: URL { dir.appendingPathComponent("boards") }

    /// A repository with `src/a.txt` committed on main and a worktree on `feature`.
    func fixture() async throws -> (repo: TempRepo, worktree: URL) {
        let repo = try await TempRepo()
        try await repo.write("src/a.txt", "a\n")
        try await repo.commit("init")
        let worktree = dir.appendingPathComponent("wt-feature")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        return (repo, worktree)
    }

    /// The id easl gave a board opened at `root` before boards were per repository: git's
    /// common dir and branch (or, detached, its top level), as the old `BoardStore` asked git.
    func legacyID(_ root: URL) async throws -> BoardID {
        let lines = try await TempRepo.run(["rev-parse", "--path-format=absolute", "--git-common-dir", "--abbrev-ref", "HEAD", "--show-toplevel"], in: root)
            .split(separator: "\n").map(String.init)
        return BoardStore.hashedID("\(lines[0])\n\(lines[1] == "HEAD" ? lines[2] : lines[1])")
    }

    /// Writes a legacy board file (no `repo`) the way the old store saved it.
    func legacyBoard(_ root: URL, _ build: (Board) throws -> Void) async throws -> Board {
        let board = Board(id: try await legacyID(root), root: root)
        try build(board)
        BoardStore(directory: boards).save(board)
        return board
    }

    func arrow(_ board: Board, from: ObjectID, to: ObjectID) -> CanvasObject {
        board.create(type: .arrow, props: .object(["from": .object(["object": .string(from)]), "to": .object(["object": .string(to)])]))
    }

    func stored(_ id: BoardID) throws -> BoardSnapshot {
        try RepoBoardMigration.decoder.decode(BoardSnapshot.self, from: Data(contentsOf: boards.appendingPathComponent("\(id).json")))
    }

    func real(_ path: String) -> String { GitDiffEngine.realPath(URL(fileURLWithPath: path)).path }

    @Test func twoBranchBoardsMergeIntoOneRepositoryBoardWithTheirArrowsAndARegionForTheBranch() async throws {
        let (repo, worktree) = try await fixture()
        // The main checkout's board was opened at a subdirectory: its paths are relative to it.
        let main = try await legacyBoard(repo.url("src")) { board in
            let code = board.create(type: .code, props: .object(["path": .string("a.txt")]), frame: Frame(x: 0, y: 0, w: 400, h: 300))
            let note = board.create(type: .note, props: .object(["markdown": .string("main")]), frame: Frame(x: 500, y: 0, w: 200, h: 100))
            _ = arrow(board, from: code.id, to: note.id)
        }
        let feature = try await legacyBoard(worktree) { board in
            let code = board.create(type: .code, props: .object(["path": .string("src/a.txt")]), frame: Frame(x: 0, y: 0, w: 400, h: 300))
            let note = board.create(type: .note, props: .object(["markdown": .string("feature")]), frame: Frame(x: 0, y: 400, w: 200, h: 100))
            board.create(type: .group, props: .object(["members": .array([.string(note.id)]), "title": .string("inner")]))
            _ = arrow(board, from: code.id, to: note.id)
            board.create(type: .arrow, props: .object(["from": .object(["object": .string(code.id)]), "to": .object(["point": .array([.number(900), .number(50)])])]))
            board.create(type: .terminal, props: .object(["cwd": .string(worktree.path)]), frame: Frame(x: 500, y: 0, w: 300, h: 200))
            board.create(type: .changes, props: .object(["paths": .array([.string("src")])]), frame: Frame(x: 900, y: 0, w: 300, h: 200))
        }
        let before = main.snapshot.objects + feature.snapshot.objects

        let store = BoardStore(directory: boards)
        let report = try #require(store.migrateToRepoBoards())
        let id = BoardStore.repoID(commonDir: try #require(GitWorktree.containing(repo.root.path)).commonDir)
        #expect(report.repos.map(\.board) == [id])
        #expect(report.repos.first?.legacy.map(\.status) == ["merged", "merged"])
        #expect(report.notice(for: id) == "Boards are per repository now: merged feature in as regions; from temporary worktrees, delete if unneeded: feature",
                "the fixture's worktree is in the temporary directory")
        #expect(!FileManager.default.fileExists(atPath: boards.appendingPathComponent("\(main.id).json").path))
        #expect(FileManager.default.fileExists(atPath: boards.appendingPathComponent("pre-repo-migration/\(feature.id).json").path))

        let registry = BoardRegistry(store: store)
        let board = registry.open(root: worktree)
        #expect(board.id == id)
        #expect(real(board.root.path) == real(repo.root.path), "rooted at the main checkout, whichever worktree opens it")
        #expect(Set(board.objects.keys).isSuperset(of: before.map(\.id)), "every object keeps its id")
        #expect(board.objects.count == before.count + 1, "one region for the feature branch")

        // The main checkout's objects stay where they were, their paths now relative to the repository.
        for object in main.snapshot.objects where object.type != .arrow { #expect(board.objects[object.id]?.frame == object.frame) }
        let mainCode = try #require(main.snapshot.objects.first { $0.type == .code })
        #expect(board.objects[mainCode.id]?.props["path"] == .string("src/a.txt"))
        #expect(board.objects[mainCode.id]?.props["ref"] == nil)

        // The feature board's objects form a region beside them, anchored to the branch.
        let region = try #require(board.objects.values.first { $0.props["key"] == .string("branch:feature") })
        #expect(region.props["title"] == .string("feature"))
        #expect(board.attention[region.id] != nil, "a region from a temporary worktree is marked for the user")
        let mainExtent = try #require(RepoBoardMigration.extent(of: main.snapshot.objects))
        #expect(!region.frame.intersects(mainExtent))
        let featureCode = try #require(feature.snapshot.objects.first { $0.type == .code })
        let inner = try #require(feature.snapshot.objects.first { $0.type == .group })
        let terminal = try #require(feature.snapshot.objects.first { $0.type == .terminal })
        let members = Set(GroupSpec(region.props)?.members ?? [])
        #expect(members.isSuperset(of: [featureCode.id, inner.id, terminal.id]), "top-level objects")
        #expect(!members.contains { [.arrow, .note].contains(board.objects[$0]?.type) }, "not arrows or what an inner group holds")
        let moved = try #require(board.objects[featureCode.id])
        let dx = moved.frame.x - featureCode.frame.x, dy = moved.frame.y - featureCode.frame.y
        #expect(moved.props["path"] == .string("src/a.txt"))
        #expect(moved.props["ref"] == .string("feature"))
        #expect(moved.props["refSha"] == .string(try await repo.git("rev-parse", "feature")))
        #expect(board.objects[terminal.id]?.props["branch"] == .string("feature"))
        let changesID = try #require(feature.snapshot.objects.first { $0.type == .changes }).id
        let changes = try #require(board.objects[changesID])
        #expect(changes.props["ref"] == .string("feature"))
        #expect(changes.props["base"] == .string("HEAD"), "still the branch's uncommitted work, as it reviewed its own worktree")
        #expect(changes.props["paths"] == .array([.string("src")]))

        // Arrows keep their ends; a free end moves with its region.
        for arrow in before where arrow.type == .arrow {
            let merged = try #require(board.objects[arrow.id])
            #expect(merged.props["from"] == arrow.props["from"])
            if let point = arrow.props["to"]?["point"]?.array {
                #expect(merged.props["to"]?["point"] == .array([.number(point[0].number! + dx), .number(point[1].number! + dy)]))
            } else {
                #expect(merged.props["to"] == arrow.props["to"])
            }
        }

        // The worktree is an attribute of the board: listed with its branch and region, and the
        // branch filter answers its part of the board.
        let router = ApiRouter(registry: registry)
        let listed = try #require(try router.dispatch("board.list", .object([:]))["boards"]?.array?.first { $0["board"] == .string(id) })
        let entry = try #require(listed["worktrees"]?.array?.first { $0["branch"] == .string("feature") })
        #expect(entry["live"] == .bool(true))
        #expect(entry["region"] == .string(region.id))
        let got = try router.dispatch("board.get", .object(["board": .string(id), "branch": .string("feature")]))
        let part = try #require(got["objects"]?.array)
        #expect(got["regions"] == .array([.string(region.id)]))
        // Terminals started before the migration still name their old board (EASL_BOARD_ID).
        #expect(try router.dispatch("board.get", .object(["board": .string(feature.id)]))["board"] == .string(id))
        #expect(Set(part.compactMap { $0["id"]?.string }) == Set(feature.snapshot.objects.map(\.id) + [region.id]))
        // A branch without a region still says so, and the whole board lists none.
        #expect(try router.dispatch("board.get", .object(["board": .string(id), "branch": .string("no-such-branch")]))["regions"] == .array([]))
        #expect(try router.dispatch("board.get", .object(["board": .string(id)]))["regions"] == nil)
    }

    @Test func runningAgainMergesNothingTwice() async throws {
        let (_, worktree) = try await fixture()
        let feature = try await legacyBoard(worktree) { board in
            board.create(type: .note, props: .object(["markdown": .string("feature")]))
        }
        let store = BoardStore(directory: boards)
        let first = try #require(store.migrateToRepoBoards())
        let id = try #require(first.repos.first?.board)
        let merged = try stored(id)

        #expect(BoardStore(directory: boards).migrateToRepoBoards() == nil, "a store migrates once")
        // A legacy file back in the store (a run interrupted after writing the repository board)
        // is only backed up again.
        try FileManager.default.copyItem(at: boards.appendingPathComponent("pre-repo-migration/\(feature.id).json"),
                                         to: boards.appendingPathComponent("\(feature.id).json"))
        let again = RepoBoardMigration.run(directory: boards)
        #expect(again.repos.first?.legacy.map(\.status) == ["alreadyMerged"])
        #expect(try stored(id).objects.map(\.id).sorted() == merged.objects.map(\.id).sorted())
        #expect(!FileManager.default.fileExists(atPath: boards.appendingPathComponent("\(feature.id).json").path))
    }

    @Test func aKeyTwoBranchBoardsHoldStaysWithTheBoardSavedLastAndTheOtherIsRenamed() async throws {
        let (repo, worktree) = try await fixture()
        let main = try await legacyBoard(repo.root) { $0.create(type: .group, props: .object(["members": .array([]), "key": .string("REL-1")])) }
        let feature = try await legacyBoard(worktree) { board in
            let note = board.create(type: .note, props: .object(["markdown": .string("ticket")]))
            board.create(type: .group, props: .object(["members": .array([.string(note.id)]), "key": .string("REL-1")]))
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: boards.appendingPathComponent("\(main.id).json").path)
        let report = try #require(BoardStore(directory: boards).migrateToRepoBoards())
        let renames = try #require(report.repos.first?.keyRenames)
        let mainGroup = try #require(main.snapshot.objects.first).id
        #expect(renames == [.init(object: mainGroup, board: main.id, from: "REL-1", to: "REL-1@main")])
        let board = BoardRegistry(store: BoardStore(directory: boards)).open(root: repo.root)
        #expect(try board.holder(ofKey: "REL-1")?.id == feature.snapshot.objects.first { $0.type == .group }?.id)
        #expect(try board.holder(ofKey: "REL-1@main")?.id == mainGroup)
    }

    @Test func aDetachedWorktreesBoardKeepsItsPathsInThatWorktree() async throws {
        let (repo, worktree) = try await fixture()
        try await TempRepo.run(["checkout", "-q", "--detach"], in: worktree)
        let detached = try await legacyBoard(worktree) { board in
            board.create(type: .code, props: .object(["path": .string("src/a.txt")]))
            board.create(type: .note, props: .object(["markdown": .string("detached")]))
        }
        let report = BoardStore(directory: boards).migrateToRepoBoards()
        let legacy = try #require(report?.repos.first?.legacy.first)
        #expect(legacy.board == detached.id)
        #expect(legacy.anchor == "worktree")
        let board = BoardRegistry(store: BoardStore(directory: boards)).open(root: repo.root)
        let code = try #require(board.objects.values.first { $0.type == .code })
        #expect(code.props["path"] == .string(worktree.appendingPathComponent("src/a.txt").path))
        #expect(code.props["ref"] == nil)
        #expect(board.objects.values.first { $0.type == .note }?.props["root"] == .string(worktree.path))
        #expect(board.objects.values.contains { $0.props["key"] == .string("detached:wt-feature") })
    }

    @Test func aDeletedWorktreesBoardIsFoundByItsBranchAndReadsTheBranch() async throws {
        let (repo, worktree) = try await fixture()
        _ = try await legacyBoard(repo.root) { $0.create(type: .note, props: .object(["markdown": .string("main")])) }
        let gone = try await legacyBoard(worktree) { board in
            board.create(type: .code, props: .object(["path": .string("src/a.txt")]))
            board.create(type: .image, props: .object(["path": .string("shot.png")]))
        }
        try await repo.git("worktree", "remove", "--force", worktree.path)

        let report = try #require(BoardStore(directory: boards).migrateToRepoBoards())
        let legacy = try #require(report.repos.first?.legacy.first { $0.board == gone.id })
        #expect(legacy.branch == "feature")
        #expect(legacy.worktreeLive == false)
        #expect(legacy.unanchored == ["\(gone.snapshot.objects.first { $0.type == .image }!.id) image: \(worktree.appendingPathComponent("shot.png").path)"],
                "the image has no branch to read instead")
        let board = BoardRegistry(store: BoardStore(directory: boards)).open(root: repo.root)
        let code = try #require(board.objects.values.first { $0.type == .code })
        #expect(code.props["path"] == .string("src/a.txt"))
        #expect(code.props["ref"] == .string("feature"))
        let entry = try #require(board.repo?.worktreeList(objects: board.objects).first { $0.branch == "feature" })
        #expect(entry.live == false)
        #expect(entry.path == worktree.path)
    }

    @Test func boardsOutsideGitAreLeftAlone() async throws {
        let plain = dir.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let store = BoardStore(directory: boards)
        let board = store.load(root: plain)
        board.create(type: .note, props: .object(["markdown": .string("kept")]))
        store.save(board)
        let file = boards.appendingPathComponent("\(board.id).json")
        let bytes = try Data(contentsOf: file)

        let report = try #require(BoardStore(directory: boards).migrateToRepoBoards())
        #expect(report.nonGit == [board.id])
        #expect(report.repos.isEmpty)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(BoardRegistry(store: BoardStore(directory: boards)).open(root: plain).id == board.id)
    }

    /// Before its first commit git named no branch, so the old store keyed the board by path.
    @Test func aBoardOfARepositoryWithoutCommitsBecomesItsRepositoryBoard() async throws {
        let repo = try await TempRepo()
        let store = BoardStore(directory: boards)
        let old = Board(id: BoardStore.pathID(repo.root), root: repo.root)
        let note = old.create(type: .note, props: .object(["markdown": .string("before the first commit")]))
        store.save(old)

        let report = try #require(BoardStore(directory: boards).migrateToRepoBoards())
        #expect(report.nonGit.isEmpty)
        #expect(report.repos.first?.legacy.map(\.anchor) == ["main"])
        let board = BoardRegistry(store: BoardStore(directory: boards)).open(root: repo.root)
        #expect(board.id != old.id)
        #expect(board.objects[note.id]?.frame == note.frame, "placed as it was: it is the main checkout's board")
    }

    /// A plain folder's board (keyed by its path) with a note and a code tile, saved; a launch
    /// migrates the store, leaving it alone as a board outside git.
    func folderBoard() throws -> (folder: URL, board: Board) {
        let folder = dir.appendingPathComponent("tiktok")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        let store = BoardStore(directory: boards)
        let board = store.load(root: folder)
        board.create(type: .note, props: .object(["markdown": .string("made before git init")]), frame: Frame(x: 40, y: 60, w: 300, h: 200))
        board.create(type: .code, props: .object(["path": .string("src/a.txt")]), frame: Frame(x: 400, y: -80, w: 500, h: 300))
        store.save(board)
        #expect(board.id == BoardStore.pathID(folder))
        #expect(try #require(store.migrateToRepoBoards()).nonGit == [board.id])
        return (folder, board)
    }

    /// `git init` and a first commit in `folder`; its repository's common git directory.
    func makeRepository(_ folder: URL) async throws -> String {
        try "a\n".write(to: folder.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q", "--template=", "-b", "main"], ["add", "-A"], ["commit", "-q", "-m", "init"]] {
            try await TempRepo.run(arguments, in: folder)
        }
        return try #require(GitWorktree.containing(folder.path)).commonDir
    }

    /// `board` is `old`'s folder's repository board holding `old`, as it was: same objects, ids
    /// and frames, the code tile's path unchanged; `old`'s file is backed up and the ledger
    /// records the merge.
    func expectAdopted(_ old: Board, by board: Board, commonDir: String) throws {
        #expect(board.id == BoardStore.repoID(commonDir: commonDir))
        #expect(board.objects.count == old.objects.count)
        for object in old.snapshot.objects {
            #expect(board.objects[object.id]?.frame == object.frame, "\(object.type) placed as it was")
        }
        #expect(board.objects.values.first { $0.type == .code }?.props["path"] == .string("src/a.txt"))
        #expect(board.repo?.merged == [old.id])
        #expect(try stored(board.id).objects.map(\.id).sorted() == old.snapshot.objects.map(\.id).sorted(), "written to the repository board's file")
        #expect(!FileManager.default.fileExists(atPath: boards.appendingPathComponent("\(old.id).json").path))
        #expect(FileManager.default.fileExists(atPath: boards.appendingPathComponent("pre-repo-migration/\(old.id).json").path))
        let ledger = try RepoBoardMigration.decoder.decode(RepoBoardMigration.Ledger.self, from: Data(contentsOf: RepoBoardMigration.ledgerURL(boards)))
        let run = try #require(ledger.runs.last?.repos.first)
        #expect(run.board == board.id && run.legacy.map(\.board) == [old.id] && run.legacy.map(\.status) == ["merged"] && run.legacy.map(\.anchor) == ["main"])
    }

    /// easl#79: `~/dev/tiktok` had a board, then `git init`; relaunched, easl opened an empty
    /// repository board instead of it.
    @Test func aFoldersBoardIsKeptWhenTheFolderBecomesARepository() async throws {
        let (folder, old) = try folderBoard()
        let commonDir = try await makeRepository(folder)

        let store = BoardStore(directory: boards)
        #expect(store.migrateToRepoBoards() == nil, "the store migrated at an earlier launch")
        let board = BoardRegistry(store: store).open(root: folder)
        try expectAdopted(old, by: board, commonDir: commonDir)

        // The next launch finds nothing more to merge.
        let runs = try RepoBoardMigration.decoder.decode(RepoBoardMigration.Ledger.self, from: Data(contentsOf: RepoBoardMigration.ledgerURL(boards))).runs.count
        let again = BoardRegistry(store: BoardStore(directory: boards)).open(root: folder)
        #expect(again.objects.count == old.objects.count && again.repo?.merged == [old.id])
        #expect(try RepoBoardMigration.decoder.decode(RepoBoardMigration.Ledger.self, from: Data(contentsOf: RepoBoardMigration.ledgerURL(boards))).runs.count == runs)
    }

    /// easl 0.2.3 saved the empty repository board it opened in place of the folder's board.
    @Test func aFoldersBoardMergesIntoTheEmptyRepositoryBoardALaunchSavedInstead() async throws {
        let (folder, old) = try folderBoard()
        let commonDir = try await makeRepository(folder)
        let empty = Board(id: BoardStore.repoID(commonDir: commonDir), root: folder)
        empty.repo = RepoRecord(commonDir: commonDir)
        BoardStore(directory: boards).save(empty)

        let store = BoardStore(directory: boards)
        #expect(store.migrateToRepoBoards() == nil)
        try expectAdopted(old, by: BoardRegistry(store: store).open(root: folder), commonDir: commonDir)
    }

    /// The folder's board is open when the folder becomes a repository and is opened again: it
    /// stays as it is (its next save would bring its file back), and the next launch merges it.
    @Test func aFoldersBoardOpenWhenItsRepositoryBoardLoadsWaitsForTheNextLaunch() async throws {
        let (folder, old) = try folderBoard()
        let registry = BoardRegistry(store: BoardStore(directory: boards, debounce: 60))
        #expect(registry.open(root: folder).id == old.id)
        let commonDir = try await makeRepository(folder)
        #expect(registry.open(root: folder).objects.isEmpty)
        #expect(FileManager.default.fileExists(atPath: boards.appendingPathComponent("\(old.id).json").path))

        try expectAdopted(old, by: BoardRegistry(store: BoardStore(directory: boards)).open(root: folder), commonDir: commonDir)
    }

    /// `folder`'s repository board, already holding `old`'s objects (so `old` conflicts), saved.
    func conflictingRepositoryBoard(_ folder: URL, _ old: Board) async throws -> BoardSnapshot {
        let commonDir = try await makeRepository(folder)
        var copy = old.snapshot
        copy.id = BoardStore.repoID(commonDir: commonDir)
        copy.repo = RepoRecord(commonDir: commonDir)
        try RepoBoardMigration.encoder.encode(copy).write(to: boards.appendingPathComponent("\(copy.id).json"))
        return copy
    }

    func ledgerRuns() throws -> Int {
        try RepoBoardMigration.decoder.decode(RepoBoardMigration.Ledger.self, from: Data(contentsOf: RepoBoardMigration.ledgerURL(boards))).runs.count
    }

    /// A folder board whose objects the repository board already holds stays as it is (a
    /// conflict): reported by the launch that first finds it, not by every launch after.
    @Test func aFoldersBoardThatConflictsIsReportedOnceNotAtEveryLaunch() async throws {
        let (folder, old) = try folderBoard()
        let copy = try await conflictingRepositoryBoard(folder, old)
        let before = try ledgerRuns()

        for _ in 1...3 { _ = BoardRegistry(store: BoardStore(directory: boards)).open(root: folder) }
        #expect(try ledgerRuns() == before + 1)
        #expect(RepoBoardMigration.pending(in: boards).unresolved == [old.id], "left in the store")
        #expect(FileManager.default.fileExists(atPath: boards.appendingPathComponent("\(old.id).json").path))
        #expect(try stored(copy.id).revision == copy.revision, "the repository board isn't rewritten")
    }

    /// Two repositories' conflicting folder boards: each repository's load leaves both in the
    /// store, so launches that open both add nothing after the first.
    @Test func twoRepositoriesConflictingFolderBoardsAreReportedOnce() async throws {
        let (first, firstOld) = try folderBoard()
        let second = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: second.appendingPathComponent("src"), withIntermediateDirectories: true)
        let store = BoardStore(directory: boards)
        let secondOld = store.load(root: second)
        secondOld.create(type: .note, props: .object(["markdown": .string("the other folder")]))
        store.save(secondOld)
        _ = try await conflictingRepositoryBoard(first, firstOld)
        _ = try await conflictingRepositoryBoard(second, secondOld)

        func launch() {
            let registry = BoardRegistry(store: BoardStore(directory: boards))
            registry.open(root: first)
            registry.open(root: second)
        }
        launch()
        let runs = try ledgerRuns()
        launch()
        launch()
        #expect(try ledgerRuns() == runs)
        #expect(RepoBoardMigration.pending(in: boards).unresolved == [firstOld.id, secondOld.id].sorted())
    }

    /// `proj/app`'s board (keyed by its path) with what `build` makes, saved; a launch leaves it
    /// alone; then `proj` becomes a repository with a commit and opens. The repository board.
    func adoptedSubfolderBoard(_ build: (Board) throws -> Void) async throws -> Board {
        let project = dir.appendingPathComponent("proj"), app = project.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "a\n".write(to: app.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        let store = BoardStore(directory: boards)
        let old = store.load(root: app)
        try build(old)
        store.save(old)
        #expect(store.migrateToRepoBoards()?.nonGit == [old.id])
        for arguments in [["init", "-q", "--template=", "-b", "main"], ["add", "-A"], ["commit", "-q", "-m", "init"]] {
            try await TempRepo.run(arguments, in: project)
        }
        let board = BoardRegistry(store: BoardStore(directory: boards)).open(root: project)
        #expect(board.repo?.merged == [old.id])
        return board
    }

    /// A message queued for a terminal of the folder's board, not yet taken, stays queued (its
    /// mention's path now the repository board's), and the terminal's old name still reaches it.
    @Test func anAdoptedBoardsQueuedMessagesAndOldTerminalNamesComeWithIt() async throws {
        var terminal: ObjectID = ""
        let board = try await adoptedSubfolderBoard { old in
            terminal = old.create(type: .terminal, props: .object(["cwd": .string(old.root.path)])).id
            let mention = Mention(id: "men_1", target: .code(object: terminal, path: "src/a.txt", lines: LineRange(start: 1, end: 1)), label: "a.txt:1", stagedAt: Date())
            old.messages[terminal] = [AgentMessage(text: "look at this", from: nil, label: "ci", when: .now, mentions: [mention])]
            old.aliases["reviewer"] = terminal
        }
        #expect(board.aliases["reviewer"] == terminal)
        let queued = try #require(board.messages[terminal]?.first)
        #expect(queued.text == "look at this" && queued.label == "ci")
        guard case .code(_, let path, _, _, _, _, _) = queued.mentions.first?.target else {
            Issue.record("the code mention is gone: \(queued.mentions)")
            return
        }
        #expect(path == "app/src/a.txt")
    }

    /// A note of `proj/app`'s board read its links in `proj/app`; on `proj`'s board it still does.
    @Test func anAdoptedSubfoldersNotesStillReadTheirFolder() async throws {
        var note: ObjectID = "", html: ObjectID = ""
        let board = try await adoptedSubfolderBoard { old in
            note = old.create(type: .note, props: .object(["markdown": .string("see src/a.txt:1")])).id
            html = old.create(type: .html, props: .object(["html": .string("<img src=\"shot.png\">")])).id
        }
        #expect(board.objects[note]?.props["root"] == .string("app"))
        #expect(board.objects[html]?.props["root"] == .string("app"))
    }

    /// A diagram of `proj/app`'s board: its file, the graph it last drew (a node in `app`, and one
    /// in `proj/lib` that `app`'s board named by absolute path), the node it expanded and arrows
    /// bound to nodes all name them as `proj`'s board's next build will (`app/…`, `lib/…`).
    @Test func anAdoptedSubfoldersDiagramKeepsItsFileNodesAndBoundArrows() async throws {
        var diagram: ObjectID = "", arrow: ObjectID = "", outside = ""
        let node = "src/a.txt#run", moved = "app/src/a.txt#run"
        let board = try await adoptedSubfolderBoard { old in
            outside = old.root.deletingLastPathComponent().appendingPathComponent("lib/b.txt").path + "#helper"
            let graph: JSONValue = .object(["aim": .object(["kind": .string("calls"), "path": .string("src/a.txt")]), "root": .string(node),
                                            "nodes": .array([.object(["id": .string(node), "name": .string("run"), "path": .string("src/a.txt")]),
                                                             .object(["id": .string(outside), "name": .string("helper"), "path": .string(String(outside.prefix { $0 != "#" }))])]),
                                            "edges": .array([.object(["from": .string(node), "to": .string(outside), "lines": .array([.number(1)])])]),
                                            "computedAt": .string("2026-10-07T00:00:00Z")])
            diagram = old.create(type: .diagram, props: .object(["kind": .string("calls"), "path": .string("src/a.txt"), "symbol": .string("run"),
                                                                 "expanded": .array([.string(node), .string(outside)]), "graph": graph])).id
            arrow = old.create(type: .arrow, props: .object(["from": .object(["object": .string(diagram), "node": .string(node)]),
                                                             "to": .object(["object": .string(diagram), "node": .string(outside)])])).id
        }
        let props = try #require(board.objects[diagram]?.props)
        #expect(props["path"] == .string("app/src/a.txt"))
        #expect(props["expanded"] == .array([.string(moved), .string("lib/b.txt#helper")]))
        #expect(props["graph"]?["aim"]?["path"] == .string("app/src/a.txt"))
        #expect(props["graph"]?["root"] == .string(moved))
        #expect(props["graph"]?["nodes"]?.array?.map { $0["id"] } == [.string(moved), .string("lib/b.txt#helper")])
        #expect(props["graph"]?["nodes"]?.array?.map { $0["path"] } == [.string("app/src/a.txt"), .string("lib/b.txt")])
        #expect(props["graph"]?["edges"]?.array?.first?["from"] == .string(moved))
        #expect(props["graph"]?["edges"]?.array?.first?["to"] == .string("lib/b.txt#helper"))
        #expect(board.objects[arrow]?.props["from"]?["node"] == .string(moved))
        #expect(board.objects[arrow]?.props["to"]?["node"] == .string("lib/b.txt#helper"))
    }

    /// A diagram's persisted graph names its nodes by file and symbol, including an external
    /// file: only the paths beneath the destination board root should become relative.
    func diagramProps(_ path: String, external: String) -> JSONValue {
        let node = path + "#run", other = external + "#helper"
        return .object(["kind": .string("calls"), "path": .string(path), "symbol": .string("run"),
                        "expanded": .array([.string(node), .string(other)]),
                        "graph": .object(["aim": .object(["kind": .string("calls"), "path": .string(path)]), "root": .string(node),
                                          "nodes": .array([.object(["id": .string(node), "path": .string(path)]),
                                                           .object(["id": .string(other), "path": .string(external)])]),
                                          "edges": .array([.object(["from": .string(node), "to": .string(other)])])])])
    }

    /// A linked checkout nested beneath the main checkout, or a symlink spelling of a source
    /// file: the adopted graph and bound arrow keep the ids the destination board builds next.
    @Test(arguments: [false, true])
    func anAdoptedDiagramKeepsItsIdentitiesRelativeToItsDestinationRoot(aliased: Bool) async throws {
        let repo = try await TempRepo()
        try await repo.write("src/a.txt", "a\n")
        try await repo.commit("init")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source: URL, path: String, expected: String
        if aliased {
            source = repo.root
            let alias = dir.appendingPathComponent("repo-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repo.root)
            path = alias.appendingPathComponent("src/./a.txt").path
            expected = "src/a.txt"
        } else {
            source = repo.url(".worktrees/topic")
            try await repo.git("worktree", "add", "-q", "-b", "topic", source.path)
            path = "src/a.txt"
            expected = ".worktrees/topic/src/a.txt"
        }
        let external = dir.appendingPathComponent("external/b.txt").path
        let old = Board(id: BoardStore.pathID(source), root: source)
        let diagram = old.create(type: .diagram, props: diagramProps(path, external: external))
        let arrow = old.create(type: .arrow, props: .object(["from": .object(["object": .string(diagram.id), "node": .string(path + "#run")]),
                                                            "to": .object(["object": .string(diagram.id), "node": .string(external + "#helper")])]))
        BoardStore(directory: boards).save(old)
        let board = BoardRegistry(store: BoardStore(directory: boards)).open(root: source)
        #expect(real(board.root.path) == real(repo.root.path))
        #expect(board.repo?.merged == [old.id])
        #expect(board.objects[diagram.id]?.props == diagramProps(expected, external: external))
        #expect(board.objects[arrow.id]?.props["from"]?["node"] == .string(expected + "#run"))
        #expect(board.objects[arrow.id]?.props["to"]?["node"] == .string(external + "#helper"))
    }

    @Test func aTerminalRecordsTheWorktreeAndBranchItStartsIn() async throws {
        let (repo, worktree) = try await fixture()
        let registry = BoardRegistry(store: BoardStore(directory: boards, debounce: 60))
        let board = registry.open(root: worktree)
        #expect(board.workingRoot.path == worktree.path, "opened from the worktree, New Terminal starts there")
        let there = board.create(type: .terminal, props: .object(["cwd": .string(worktree.appendingPathComponent("src").path)]))
        #expect(there.props["worktree"] == .string(worktree.path))
        #expect(there.props["branch"] == .string("feature"))
        let home = board.create(type: .terminal, props: .object(["cwd": .string(repo.root.path)]))
        #expect(home.props["branch"] == .string("main"))
        #expect(registry.open(root: repo.root) === board)
        #expect(board.workingRoot.path == board.root.path)
    }

    /// A terminal made at the board root in which `cd <directory> && <kind>` runs an agent: the
    /// shell reports nothing until the agent exits, the agent's process works in `directory`
    /// (read from the process table, as the app reads it).
    func agent(_ kind: String, in directory: URL, on board: Board) throws -> ObjectID {
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(board.root.path)])).id
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.currentDirectoryURL = directory
        try process.run()
        defer { process.terminate() }
        board.terminalWorks(terminal, in: try #require(SessionProcesses.directory(of: process.processIdentifier)))
        try board.reportLifecycle(tile: terminal, kind: kind, state: .idle, message: nil, seq: 1, source: "canvas-\(kind)")
        return terminal
    }

    @Test func aTerminalBelongsToTheWorktreeItsAgentWorksInAndThatWorktreesMentionsGoThere() async throws {
        let (repo, worktree) = try await fixture()
        let other = dir.appendingPathComponent("wt-other")
        try await repo.git("worktree", "add", "-q", "-b", "other", other.path)
        let board = BoardRegistry(store: BoardStore(directory: boards, debounce: 60)).open(root: repo.root)
        let codex = try agent("codex", in: worktree.appendingPathComponent("src"), on: board)
        let claude = try agent("claude", in: other, on: board)
        #expect(board.objects[codex]?.props["worktree"] == .string(GitWorktree.normalized(worktree.path)))
        #expect(board.objects[codex]?.props["branch"] == .string("feature"))
        #expect(board.objects[claude]?.props["branch"] == .string("other"))
        #expect(board.repo?.worktrees.contains { $0.branch == "other" } == true, "recorded on the board")
        #expect(board.objects(ofBranch: "feature").contains(codex))

        // A line of wt-feature's file staged while claude is the target goes to codex.
        let file = worktree.appendingPathComponent("src/a.txt").path
        let code = board.create(type: .code, props: .object(["path": .string(file)]))
        let checkout = try #require(PromptTarget.checkout(of: .code(object: code.id, path: file, lines: LineRange(start: 1, end: 1)), on: board))
        #expect(PromptTarget.affinity(checkout: checkout, current: claude, checkouts: PromptTarget.checkouts(on: board), objects: board.objects) == codex)

        // Back in the board's checkout it is main's again; outside the repository nothing changes.
        board.terminalWorks(codex, in: repo.root.path)
        #expect(board.objects[codex]?.props["branch"] == .string("main"))
        board.terminalWorks(codex, in: "/")
        #expect(board.objects[codex]?.props["branch"] == .string("main"))
    }

    @Test func reviewChangesAndReviewBranchReviewTheWorktreeOfTheTerminalTheyGoBy() async throws {
        let (repo, worktree) = try await fixture()
        let board = BoardRegistry(store: BoardStore(directory: boards, debounce: 60)).open(root: repo.root)
        let codex = try agent("codex", in: worktree, on: board)
        let shell = board.create(type: .terminal, props: .object(["cwd": .string(repo.root.path)])).id
        #expect(board.reviewRoot(terminal: codex).map(GitWorktree.normalized) == GitWorktree.normalized(worktree.path))
        #expect(board.reviewRoot(terminal: shell) == nil, "a terminal in the board's checkout reviews that")
        #expect(board.reviewRoot(terminal: nil) == nil, "nothing to go by: the board's own checkout")
        // With nothing to go by, Review Branch of main against main would be empty: it offers the worktrees.
        #expect(board.branchReviewChoices.map { GitWorktree.normalized($0.toplevel) } == [GitWorktree.normalized(worktree.path)])
        try await repo.git("switch", "-q", "-c", "topic")
        #expect(board.branchReviewChoices.isEmpty, "the board's own branch is what it reviews")
    }
}
