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
    /// that isn't stored yet first takes in legacy boards the launch migration couldn't place.
    public func load(root opened: URL, id known: BoardID? = nil, repo knownRepo: String? = nil) -> Board {
        let worktree = knownRepo == nil ? GitWorktree.containing(opened.standardizedFileURL.path) : nil
        let commonDir = knownRepo ?? worktree?.commonDir
        let root = worktree.map { URL(fileURLWithPath: $0.canonicalRoot) } ?? opened
        let id = known ?? commonDir.map(Self.repoID(commonDir:)) ?? Self.pathID(root)
        if let commonDir, !FileManager.default.fileExists(atPath: url(for: id).path) { migratePending(commonDir: commonDir) }
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
    /// once: later calls only re-try the ones it left unresolved, when a repository they may
    /// belong to loads. `knownRoots`: directories whose repositories to try beyond the stored
    /// boards' roots (the saved tabs).
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

    private func migratePending(commonDir: String) {
        if unresolvedLegacy == nil { unresolvedLegacy = RepoBoardMigration.pending(in: directory).unresolved }
        guard unresolvedLegacy?.isEmpty == false else { return }
        unresolvedLegacy = RepoBoardMigration.run(directory: directory, only: commonDir).unresolved.map(\.board)
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
    /// attention markers, agents' last answers and their undelivered messages are personal,
    /// transient state, so they are left out.
    public static func export(_ board: Board, to url: URL) throws {
        var snapshot = board.snapshot
        snapshot.tray = nil
        snapshot.attention = nil
        snapshot.finalAnswers = nil
        snapshot.turnErrors = nil
        snapshot.lifecycleSeq = nil
        snapshot.repo = nil
        snapshot.messages = nil
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
