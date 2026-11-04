import CoreFoundation
import Foundation

/// Persists boards under Application Support: one per git repository (its common git
/// directory, whichever worktree or branch opens it; docs/design/repo-boards.md), one per
/// directory outside git. Loads and the migration touch the files off the main actor (`Files`).
@MainActor
public final class BoardStore {
    public let directory: URL
    private let files: Files
    private var pendingSaves: [BoardID: DispatchWorkItem] = [:]
    private var saves: [BoardID: Save] = [:]
    private var flushes: [Flush] = []
    private let debounce: TimeInterval

    @MainActor private final class Save {
        let board: Board
        let onChange: (() -> Void)?
        var version = 0
        var completedVersion = -1
        var isWriting = false
        var checked = 0
        var waiters: [(version: Int, continuation: CheckedContinuation<Void, Error>)] = []

        init(_ board: Board) {
            self.board = board
            onChange = board.onChange
        }
    }
    private struct Flush {
        let boards: [Board]
        let completion: @MainActor @Sendable () -> Void
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Easl/boards", isDirectory: true)
    }

    /// Makes no directory: loads and the migration make it off the main actor, else the first save.
    public init(directory: URL = BoardStore.defaultDirectory, debounce: TimeInterval = 0.5) {
        self.directory = directory
        self.debounce = debounce
        files = Files(directory: directory)
    }

    init(directory: URL, debounce: TimeInterval = 0.5,
         write: @escaping @Sendable (Data, URL, Data.WritingOptions) throws -> Void) {
        self.directory = directory
        self.debounce = debounce
        files = Files(directory: directory, write: write)
    }

    /// Stable board id for a root directory: its repository's (`repoID`), else its path's.
    /// Reads the directory's git files: off the main actor.
    nonisolated public static func boardID(for root: URL) -> BoardID {
        GitWorktree.containing(root.standardizedFileURL.path).map { repoID(commonDir: $0.commonDir) } ?? pathID(root)
    }

    /// Where a board opened at `root` is rooted: the repository's canonical root
    /// (`GitWorktree.canonicalRoot`), else `root`. Reads the directory's git files: off the main actor.
    nonisolated public static func boardRoot(for root: URL) -> URL {
        GitWorktree.containing(root.standardizedFileURL.path).map { URL(fileURLWithPath: $0.canonicalRoot) } ?? root
    }

    nonisolated public func url(for id: BoardID) -> URL {
        files.url(for: id)
    }

    public func owns(_ id: BoardID) -> Bool {
        let file = url(for: id)
        let migrated = directory.appendingPathComponent(RepoBoardMigration.backupFolder).appendingPathComponent(file.lastPathComponent)
        return FileManager.default.fileExists(atPath: file.path) || FileManager.default.fileExists(atPath: migrated.path)
    }

    /// The board for a directory: a repository's board, rooted at its canonical root
    /// (`boardRoot`), else the directory's. The registry passes what it already worked out: the
    /// board root, `id`, and the repository's common git directory (`repo`). A repository board
    /// first takes in the boards of the store that belong to it (`Files.mergeIntoRepositoryBoard`).
    /// The board comes back as soon as its file is read: anchors only git can check are held
    /// back until it has (`hold`).
    public func load(root opened: URL, id known: BoardID? = nil, repo knownRepo: String? = nil) async throws -> Board {
        let found = try await files.load(root: opened, id: known, repo: knownRepo)
        let board = found.prepared.map { Board(snapshot: $0.published) } ?? Board(id: found.id, root: found.root)
        if let commonDir = found.commonDir, board.repo?.commonDir != commonDir {
            board.repo = RepoRecord(commonDir: commonDir, worktrees: board.repo?.worktrees ?? [], merged: board.repo?.merged)
        }
        board.onChange = { [weak self, weak board] in
            guard let self, let board else { return }
            self.scheduleSave(board)
        }
        if let prepared = found.prepared, let areas = prepared.areas, !prepared.held.isEmpty {
            hold(board, prepared, areas: areas, read: found.read)
        }
        return board
    }

    /// `board` published without the anchors `prepared` held back while git checks them; then
    /// the allowed ones come back (`Board.settleAnchors`). If nothing wrote the board's file
    /// since its load read it (`read`) and no save is due, the file becomes the stored board less
    /// the refused anchors, when that is any change; a board saved meanwhile is saved again when
    /// git refused any. A closed board gets nothing.
    private func hold(_ board: Board, _ prepared: BoardAnchorScrub.Prepared, areas: BoardAreas, read: Int) {
        let held = prepared.held, stored = prepared.stored, changed = prepared.changed, files = files
        board.heldAnchors = held
        board.anchorScrub = Task { [weak self, weak board] in
            let checked = await BoardAnchorScrub.check(held, boardRoot: URL(fileURLWithPath: stored.root), areas: areas)
            guard let self, let board, !board.isClosed, !Task.isCancelled else { return }
            board.settleAnchors(checked)
            saves[board.id]?.version += 1
            let refused = checked.contains { held[$0.key]?.stored != $0.value }
            // A save is due: it writes the board as it is now.
            guard pendingSaves[board.id] == nil, saves[board.id] == nil else { return }
            let writes = await files.writes(of: board.id)
            guard !board.isClosed, !Task.isCancelled,
                  pendingSaves[board.id] == nil, saves[board.id] == nil else { return }
            if writes != read {
                if refused { scheduleSave(board) }
            } else if changed || refused {
                await files.write(id: board.id, unlessWrittenSince: read) { BoardAnchorScrub.settled(stored, checked) }
            }
        }
    }

    /// Folds the store's legacy per-branch boards into repository boards (`RepoBoardMigration`),
    /// once: later calls only re-try the ones it left unresolved, and adopt boards of directories
    /// that became repositories since, when the repository loads (`Files.mergeIntoRepositoryBoard`).
    /// `knownRoots`: directories whose repositories to try beyond the stored boards' roots (the
    /// saved tabs). A repository's board loaded before it runs would save over what it merged:
    /// then it waits for the next launch.
    @discardableResult
    public func migrateToRepoBoards(knownRoots: [URL] = []) async -> RepoBoardMigration.Report? {
        await files.migrate(knownRoots: knownRoots)
    }

    public func scheduleSave(_ board: Board) {
        guard !board.isClosed else { return }
        Metrics.shared.record("save.scheduled")
        if let pending = pendingSaves.removeValue(forKey: board.id) {
            pending.cancel()
            Metrics.shared.record("save.coalesced")
        }
        if let saving = saves[board.id] {
            saving.version += 1
            Metrics.shared.record("save.coalesced")
            if !saving.isWriting { write(saving) }
            return
        }
        let work = DispatchWorkItem { [weak self, weak board] in
            guard let self, let board else { return }
            self.enqueue(board)
        }
        pendingSaves[board.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    public func save(_ board: Board) async {
        try? await saveChecked(board)
    }

    /// Saves the latest state before a close can discard its in-memory board. While git checks
    /// anchors the load held back, the file keeps the stored ones (`BoardAnchorScrub.keepStored`).
    public func saveChecked(_ board: Board) async throws {
        guard !board.isClosed else { throw BoardError.notFound("board \(board.id) is closed") }
        let saving = track(board)
        saving.checked += 1
        defer {
            saving.checked -= 1
            retire(saving)
        }
        repeat {
            guard !board.isClosed else { throw BoardError.notFound("board \(board.id) is closed") }
            try await withCheckedThrowingContinuation { continuation in
                enqueue(board, continuation: continuation)
            }
        } while hasSave(board.id)
    }

    private func enqueue(_ board: Board, continuation: CheckedContinuation<Void, Error>? = nil) {
        pendingSaves.removeValue(forKey: board.id)?.cancel()
        guard !board.isClosed else {
            continuation?.resume(throwing: BoardError.notFound("board \(board.id) is closed"))
            return
        }
        let saving = track(board)
        if let continuation {
            saving.version += 1
            saving.waiters.append((saving.version, continuation))
        }
        if !saving.isWriting { write(saving) }
    }

    private func track(_ board: Board) -> Save {
        if let saving = saves[board.id] { return saving }
        let saving = Save(board)
        saves[board.id] = saving
        board.onChange = { [weak saving] in
            saving?.version += 1
            saving?.onChange?()
        }
        return saving
    }

    private func snapshot(_ board: Board) -> BoardSnapshot {
        var snapshot = board.snapshot
        if !board.heldAnchors.isEmpty { BoardAnchorScrub.keepStored(board.heldAnchors, in: &snapshot) }
        return snapshot
    }

    private func write(_ saving: Save) {
        saving.isWriting = true
        let version = saving.version
        files.save(snapshot(saving.board)) { [self, saving] result in
            let board = saving.board
            if case .failure(let error) = result {
                let failed = saving.waiters.filter { $0.version <= version }
                saving.waiters.removeAll { $0.version <= version }
                for waiter in failed { waiter.continuation.resume(throwing: error) }
            }
            if !board.isClosed, saving.version != version {
                write(saving)
                return
            }
            saving.isWriting = false
            saving.completedVersion = version
            let completion: Result<Void, Error> = board.isClosed
                ? .failure(BoardError.notFound("board \(board.id) is closed")) : result
            for waiter in saving.waiters { waiter.continuation.resume(with: completion) }
            saving.waiters.removeAll()
            retire(saving)
            finishFlushes()
        }
    }

    private func retire(_ saving: Save) {
        guard !saving.isWriting else { return }
        if !saving.board.isClosed, saving.version != saving.completedVersion {
            write(saving)
            return
        }
        guard saving.checked == 0 else { return }
        saves.removeValue(forKey: saving.board.id)
        if !saving.board.isClosed { saving.board.onChange = saving.onChange }
    }

    private func hasSave(_ id: BoardID) -> Bool {
        if pendingSaves[id] != nil { return true }
        guard let saving = saves[id] else { return false }
        return saving.isWriting || (!saving.board.isClosed && saving.version != saving.completedVersion)
    }

    public func flush(_ boards: [Board]) async {
        await withCheckedContinuation { continuation in
            beginFlush(boards) { continuation.resume() }
        }
    }

    /// Starts the same save pipeline synchronously, including during AppKit's deferred quit.
    public func beginFlush(_ boards: [Board], completion: @escaping @MainActor @Sendable () -> Void) {
        flushes.append(Flush(boards: boards, completion: completion))
        finishFlushes()
    }

    private func finishFlushes() {
        for flush in flushes {
            for board in flush.boards where hasSave(board.id) { enqueue(board) }
        }
        let finished = flushes.filter { flush in
            !flush.boards.contains { hasSave($0.id) }
        }
        flushes.removeAll { flush in
            !flush.boards.contains { hasSave($0.id) }
        }
        for flush in finished { flush.completion() }
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
            guard let snapshot = try? BoardFile.read(file) else { return nil }
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
    public static func export(_ board: Board, to url: URL) async throws {
        var snapshot = board.snapshot
        snapshot.tray = nil
        snapshot.attention = nil
        snapshot.finalAnswers = nil
        snapshot.turnErrors = nil
        snapshot.lifecycleSeq = nil
        snapshot.repo = nil
        snapshot.messages = nil
        snapshot.htmlMessages = nil
        snapshot.relaunchedAgents = nil
        try await Files.export(snapshot, to: url)
    }

    nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// A store's directory off the main actor. Loads and the migration run on `queue`, one at a
/// time, which alone touches what the store knows of its files. Every board file write is
/// counted (`writes(of:)`), so a load's later write never lands on a save made since it read.
final class Files: @unchecked Sendable {
    let directory: URL
    private static let queue = DispatchQueue(label: "easl.board-store", qos: .userInitiated)
    private let atomicWrite: @Sendable (Data, URL, Data.WritingOptions) throws -> Void

    @MainActor private final class SaveCompletion {
        private var body: (@MainActor @Sendable (Result<Void, Error>) -> Void)?

        init(_ body: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
            self.body = body
        }

        func finish(_ result: Result<Void, Error>) {
            guard let body else { return }
            self.body = nil
            body(result)
        }
    }

    /// Legacy boards the migration left unresolved, re-tried when a repository's board loads;
    /// nil until read.
    private var unresolvedLegacy: [BoardID]?
    private var pathBoards: [BoardID: (root: String, file: URL)]?
    /// Boards loaded this session. Their files are never merged away while they may be open
    /// (the board's next save would bring the file back), and a repository board takes in other
    /// boards on its first load only.
    private var loaded: Set<BoardID> = []
    /// A repository's board has loaded: the launch migration would merge under it.
    private var repositoryLoaded = false
    private var written = Written()

    private struct Written {
        var directory = false
        var count: [BoardID: Int] = [:]
    }

    init(directory: URL,
         write: @escaping @Sendable (Data, URL, Data.WritingOptions) throws -> Void = { try $0.write(to: $1, options: $2) }) {
        self.directory = directory
        atomicWrite = write
    }

    func url(for id: BoardID) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    /// A board's file as `load` reads it.
    struct Loaded: Sendable {
        var id: BoardID
        var root: URL
        var commonDir: String?
        /// The stored board with its anchors checked short of git; nil when none is stored.
        var prepared: BoardAnchorScrub.Prepared?
        /// The file's writes when it was read (`writes(of:)`).
        var read: Int
    }

    func load(root opened: URL, id known: BoardID?, repo knownRepo: String?) async throws -> Loaded {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result { try self.read(root: opened, id: known, repo: knownRepo) })
            }
        }
    }

    func migrate(knownRoots: [URL]) async -> RepoBoardMigration.Report? {
        await Self.run { () -> RepoBoardMigration.Report? in
            self.makeDirectory()
            let pending = RepoBoardMigration.pending(in: self.directory)
            guard !pending.ran, !self.repositoryLoaded else {
                self.unresolvedLegacy = pending.unresolved
                return nil
            }
            let report = RepoBoardMigration.run(directory: self.directory, knownRoots: knownRoots)
            self.unresolvedLegacy = report.unresolved.map(\.board)
            return report
        }
    }

    @MainActor func save(_ snapshot: BoardSnapshot, completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        let completion = SaveCompletion(completion)
        Self.queue.async {
            let result = Result<Void, Error> {
                let start = Metrics.now()
                defer {
                    let ms = (Metrics.now() - start) * 1000
                    if ms >= 250 { Metrics.shared.record("save.slow250", ms: ms) }
                }
                let data = try Metrics.shared.span("save", "save.encode", detail: snapshot.id) {
                    try BoardStore.encoder.encode(snapshot)
                }
                try Metrics.shared.span("save", "save.write", detail: snapshot.id, bytes: data.count) {
                    _ = try self.write(data, id: snapshot.id)
                }
            }
            DispatchQueue.main.async { completion.finish(result) }
            // AppKit's deferred-quit loop must finish saves without running MainActor tasks.
            RunLoop.main.perform(inModes: [.default, RunLoop.Mode(rawValue: "NSModalPanelRunLoopMode")]) {
                MainActor.assumeIsolated { completion.finish(result) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    @MainActor static func export(_ snapshot: BoardSnapshot, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                continuation.resume(with: Result {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    var data = try encoder.encode(snapshot)
                    data.append(0x0A)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                })
            }
        }
    }

    /// Writes what `snapshot` makes as board `id`'s file, unless the file was written since a
    /// load read it after `read` writes.
    func write(id: BoardID, unlessWrittenSince read: Int, _ snapshot: @escaping @Sendable () -> BoardSnapshot) async {
        await Self.run { () -> Void in
            guard let data = try? BoardStore.encoder.encode(snapshot()) else { return }
            _ = try? self.write(data, id: id, unlessWrittenSince: read)
        }
    }

    /// Writes board `id`'s file (making the directory first, once), unless `read` is given and
    /// the file has had other than `read` writes; whether it wrote.
    @discardableResult
    private func write(_ data: Data, id: BoardID, unlessWrittenSince read: Int? = nil) throws -> Bool {
        if let read, written.count[id, default: 0] != read { return false }
        written.count[id, default: 0] += 1
        try make(&written)
        try atomicWrite(data, url(for: id), .atomic)
        return true
    }

    /// How many times board `id`'s file has been written this session.
    func writes(of id: BoardID) async -> Int {
        await Self.run { self.written.count[id, default: 0] }
    }

    private static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private func make(_ written: inout Written) throws {
        guard !written.directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        written.directory = true
    }

    private func makeDirectory() {
        _ = try? make(&written)
    }

    /// On `queue`: the board for a directory (`BoardStore.load`), read with its anchors checked
    /// short of git (`BoardAnchorScrub.prepare`). When that refused any and none waits for git,
    /// the file is written without them here.
    private func read(root opened: URL, id known: BoardID?, repo knownRepo: String?) throws -> Loaded {
        let worktree = knownRepo == nil ? GitWorktree.containing(opened.standardizedFileURL.path) : nil
        let commonDir = knownRepo ?? worktree?.commonDir
        let root = worktree.map { URL(fileURLWithPath: $0.canonicalRoot) } ?? opened
        let id = known ?? commonDir.map(BoardStore.repoID(commonDir:)) ?? BoardStore.pathID(root)
        var stored = try BoardFile.read(url(for: id))
        makeDirectory()
        if !loaded.contains(id), let commonDir,
           try mergeIntoRepositoryBoard(commonDir: commonDir, stored: stored != nil) {
            stored = try BoardFile.read(url(for: id))
        }
        loaded.insert(id)
        if commonDir != nil { repositoryLoaded = true }
        let read = written.count[id, default: 0]
        guard var snapshot = stored else {
            return Loaded(id: id, root: root, commonDir: commonDir, prepared: nil, read: read)
        }
        // The root may have moved (renamed checkout); the board follows its identity.
        snapshot.root = root.path
        let archived = snapshot.archiveDueQuestions(now: Date())
        var prepared = BoardAnchorScrub.prepare(snapshot)
        prepared.changed = prepared.changed || archived
        if prepared.changed, prepared.held.isEmpty, let data = try? BoardStore.encoder.encode(prepared.stored) {
            _ = try? write(data, id: id, unlessWrittenSince: read)
        }
        return Loaded(id: id, root: root, commonDir: commonDir, prepared: prepared, read: read)
    }

    /// Before repository `commonDir`'s board first loads, merges into it (`RepoBoardMigration`,
    /// for this repository only) the stored boards that belong to it: the boards of directories
    /// in it that were made before they were in git (a folder's board, then `git init`), and,
    /// when the repository board isn't stored yet, legacy boards the launch migration couldn't
    /// place. Boards loaded this session are left for the next launch. Starts no git process:
    /// a path-keyed board costs the walk up its directory for `.git` (`GitWorktree.containing`).
    private func mergeIntoRepositoryBoard(commonDir: String, stored: Bool) throws -> Bool {
        if unresolvedLegacy == nil { unresolvedLegacy = RepoBoardMigration.pending(in: directory).unresolved }
        var adopting = false
        for (id, candidate) in storedPathBoards() {
            guard !loaded.contains(id), BoardStore.isDirectory(candidate.root),
                  GitWorktree.containing(URL(fileURLWithPath: candidate.root).standardizedFileURL.path)?.commonDir == commonDir else { continue }
            _ = try BoardFile.read(candidate.file)
            adopting = true
        }
        guard adopting || (!stored && unresolvedLegacy?.isEmpty == false) else { return false }
        let report = RepoBoardMigration.run(directory: directory, only: commonDir, skipping: loaded)
        unresolvedLegacy = report.unresolved.map(\.board)
        for legacy in report.repos.flatMap(\.legacy) where legacy.status != "conflict" { pathBoards?[legacy.board] = nil }
        return true
    }

    /// `pathBoards`, read from the store's files the first time.
    private func storedPathBoards() -> [BoardID: (root: String, file: URL)] {
        if let pathBoards { return pathBoards }
        struct Header: Decodable {
            var id: BoardID
            var root: String
            var repo: RepoRecord?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var found: [BoardID: (root: String, file: URL)] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let header = try? decoder.decode(Header.self, from: data),
                  header.repo == nil, header.id == BoardStore.pathID(URL(fileURLWithPath: header.root)) else { continue }
            found[header.id] = (header.root, file)
        }
        pathBoards = found
        return found
    }
}
