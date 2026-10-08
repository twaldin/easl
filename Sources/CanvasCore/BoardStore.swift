import Foundation

/// Persists boards under Application Support: one per git repository (its common git
/// directory, whichever worktree or branch opens it; docs/design/repo-boards.md), one per
/// directory outside git.
@MainActor
public final class BoardStore {
    public let directory: URL
    private var pendingSaves: [BoardID: DispatchWorkItem] = [:]
    /// Legacy boards the migration left unresolved, re-tried when a repository's board loads;
    /// nil until read.
    private var unresolvedLegacy: [BoardID]?
    /// The stored boards of directories outside git (path-keyed), id → root, read when a
    /// repository's board first loads: one whose directory has since become part of that
    /// repository is merged into its board. Nil until read.
    private var pathBoards: [BoardID: String]?
    /// Boards loaded this session. Their files are never merged away while they may be open
    /// (the board's next save would bring the file back), and a repository board takes in other
    /// boards on its first load only.
    private var loaded: Set<BoardID> = []
    private let debounce: TimeInterval

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Easl/boards", isDirectory: true)
    }

    public init(directory: URL = BoardStore.defaultDirectory, debounce: TimeInterval = 0.5) {
        self.directory = directory
        self.debounce = debounce
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Stable board id for a root directory: its repository's (`repoID`), else its path's.
    public static func boardID(for root: URL) -> BoardID {
        GitWorktree.containing(root.standardizedFileURL.path).map { repoID(commonDir: $0.commonDir) } ?? pathID(root)
    }

    /// Where a board opened at `root` is rooted: the repository's canonical root
    /// (`GitWorktree.canonicalRoot`), else `root`.
    public static func boardRoot(for root: URL) -> URL {
        GitWorktree.containing(root.standardizedFileURL.path).map { URL(fileURLWithPath: $0.canonicalRoot) } ?? root
    }

    public func url(for id: BoardID) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    /// The board for a directory: a repository's board, rooted at its canonical root
    /// (`boardRoot`), else the directory's. The registry passes what it already worked out: the
    /// board root, `id`, and the repository's common git directory (`repo`). A repository board
    /// first takes in the boards of the store that belong to it (`mergeIntoRepositoryBoard`).
    public func load(root opened: URL, id known: BoardID? = nil, repo knownRepo: String? = nil) -> Board {
        let worktree = knownRepo == nil ? GitWorktree.containing(opened.standardizedFileURL.path) : nil
        let commonDir = knownRepo ?? worktree?.commonDir
        let root = worktree.map { URL(fileURLWithPath: $0.canonicalRoot) } ?? opened
        let id = known ?? commonDir.map(Self.repoID(commonDir:)) ?? Self.pathID(root)
        if loaded.insert(id).inserted, let commonDir {
            mergeIntoRepositoryBoard(commonDir: commonDir, stored: FileManager.default.fileExists(atPath: url(for: id).path))
        }
        let board: Board
        if let data = try? Data(contentsOf: url(for: id)), var snapshot = try? Self.decoder.decode(BoardSnapshot.self, from: data) {
            // The root may have moved (renamed checkout); the board follows its identity.
            snapshot.root = root.path
            board = Board(snapshot: snapshot)
        } else {
            board = Board(id: id, root: root)
        }
        if let commonDir, board.repo?.commonDir != commonDir {
            board.repo = RepoRecord(commonDir: commonDir, worktrees: board.repo?.worktrees ?? [], merged: board.repo?.merged)
        }
        board.onChange = { [weak self, weak board] in
            guard let self, let board else { return }
            self.scheduleSave(board)
        }
        return board
    }

    /// Folds the store's legacy per-branch boards into repository boards (`RepoBoardMigration`),
    /// once: later calls only re-try the ones it left unresolved, and adopt boards of directories
    /// that became repositories since, when the repository loads (`mergeIntoRepositoryBoard`).
    /// `knownRoots`: directories whose repositories to try beyond the stored boards' roots (the
    /// saved tabs).
    @discardableResult
    public func migrateToRepoBoards(knownRoots: [URL] = []) -> RepoBoardMigration.Report? {
        let pending = RepoBoardMigration.pending(in: directory)
        guard !pending.ran else {
            unresolvedLegacy = pending.unresolved
            return nil
        }
        let report = RepoBoardMigration.run(directory: directory, knownRoots: knownRoots)
        unresolvedLegacy = report.unresolved.map(\.board)
        return report
    }

    /// Before repository `commonDir`'s board first loads, merges into it (`RepoBoardMigration`,
    /// for this repository only) the stored boards that belong to it: the boards of directories
    /// in it that were made before they were in git (a folder's board, then `git init`), and,
    /// when the repository board isn't stored yet, legacy boards the launch migration couldn't
    /// place. Boards loaded this session are left for the next launch. Starts no git process:
    /// a path-keyed board costs the walk up its directory for `.git` (`GitWorktree.containing`).
    private func mergeIntoRepositoryBoard(commonDir: String, stored: Bool) {
        if unresolvedLegacy == nil { unresolvedLegacy = RepoBoardMigration.pending(in: directory).unresolved }
        let adopting = storedPathBoards().contains { id, root in
            !loaded.contains(id) && Self.isDirectory(root) && GitWorktree.containing(URL(fileURLWithPath: root).standardizedFileURL.path)?.commonDir == commonDir
        }
        guard adopting || (!stored && unresolvedLegacy?.isEmpty == false) else { return }
        let report = RepoBoardMigration.run(directory: directory, only: commonDir, skipping: loaded)
        unresolvedLegacy = report.unresolved.map(\.board)
        for legacy in report.repos.flatMap(\.legacy) where legacy.status != "conflict" { pathBoards?[legacy.board] = nil }
    }

    /// `pathBoards`, read from the store's files the first time.
    private func storedPathBoards() -> [BoardID: String] {
        if let pathBoards { return pathBoards }
        /// What tells a path-keyed board from a repository's or a legacy one.
        struct Header: Decodable {
            var id: BoardID
            var root: String
            var repo: RepoRecord?
        }
        var found: [BoardID: String] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let header = try? Self.decoder.decode(Header.self, from: data),
                  header.repo == nil, header.id == Self.pathID(URL(fileURLWithPath: header.root)) else { continue }
            found[header.id] = header.root
        }
        pathBoards = found
        return found
    }

    public func scheduleSave(_ board: Board) {
        Metrics.shared.record("save.scheduled")
        if let pending = pendingSaves[board.id] {
            pending.cancel()
            Metrics.shared.record("save.coalesced")
        }
        let work = DispatchWorkItem { [weak self, weak board] in
            guard let self, let board else { return }
            self.save(board)
        }
        pendingSaves[board.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    public func save(_ board: Board) {
        pendingSaves.removeValue(forKey: board.id)?.cancel()
        guard let data = Metrics.shared.span("save", "save.encode", detail: board.id, { try? Self.encoder.encode(board.snapshot) }) else { return }
        Metrics.shared.span("save", "save.write", detail: board.id, bytes: data.count) { _ = try? data.write(to: url(for: board.id), options: .atomic) }
    }

    public func flush(_ boards: [Board]) {
        for board in boards where pendingSaves[board.id] != nil { save(board) }
    }

    /// A board as stored on disk, whether or not it is open.
    public struct Stored: Equatable, Sendable {
        public var id: BoardID
        public var root: String
        /// The root directory is gone (deleted worktree, removed checkout); the board is kept.
        public var archived: Bool
        public var updatedAt: Date?
        public var objectCount: Int
        /// A repository board's common git directory and worktrees (`RepoRecord.worktreeList`).
        public var repo: String?
        public var worktrees: [WorktreeInfo]?
    }

    /// Every board file in the store, sorted by id. Unreadable files are skipped.
    public func list() -> [Stored] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file -> Stored? in
            guard let data = try? Data(contentsOf: file), let snapshot = try? Self.decoder.decode(BoardSnapshot.self, from: data) else { return nil }
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let objects = Dictionary(snapshot.objects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return Stored(id: snapshot.id, root: snapshot.root, archived: !Self.isDirectory(snapshot.root), updatedAt: modified, objectCount: snapshot.objects.count,
                          repo: snapshot.repo?.commonDir, worktrees: snapshot.repo?.worktreeList(objects: objects))
        }.sorted { $0.id < $1.id }
    }

    nonisolated public static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Writes a human-readable snapshot (for committing to the repo). The selection tray,
    /// attention markers, agents' last answers, their undelivered messages and pending relaunches
    /// are personal, transient state, so they are left out.
    public static func export(_ board: Board, to url: URL) throws {
        var snapshot = board.snapshot
        snapshot.tray = nil
        snapshot.attention = nil
        snapshot.finalAnswers = nil
        snapshot.turnErrors = nil
        snapshot.lifecycleSeq = nil
        snapshot.repo = nil
        snapshot.messages = nil
        snapshot.relaunchedAgents = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(snapshot)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
