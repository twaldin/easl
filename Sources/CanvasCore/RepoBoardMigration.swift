import Foundation

/// Folds the per-branch boards easl kept before boards were per repository (legacy boards,
/// identified by `<common dir>\n<branch>` or, detached, `<common dir>\n<worktree>`) into one
/// board per repository: each legacy board's objects become a region of the repository board,
/// re-rooted onto its canonical root. One-time and idempotent: merged files move to
/// `pre-repo-migration/`, and the repository board lists what it merged. The policy is
/// docs/design/repo-boards.md "Migration".
public enum RepoBoardMigration {
    public static let backupFolder = "pre-repo-migration"
    public static let reportFile = "migration.json"
    /// Space between regions placed side by side.
    static let gap = 200.0

    public struct Report: Codable, Equatable, Sendable {
        public var ranAt: Date
        public var dryRun: Bool
        public var repos: [RepoReport]
        /// Boards of directories outside git: left as they are.
        public var nonGit: [BoardID]
        /// Legacy boards this run left in the store, by id: their repository isn't known (root
        /// gone), they are another repository's (run for one), or they conflict. The same set
        /// whichever repository a run is for.
        public var unresolved: [Unresolved]
    }

    public struct RepoReport: Codable, Equatable, Sendable {
        public var board: BoardID
        public var root: String
        public var commonDir: String
        /// Objects on the repository board before this run (0 when it is new) and after.
        public var objectsBefore: Int
        public var objectsAfter: Int
        public var legacy: [LegacyReport]
        /// Keys two merged boards both held (`props.key` is unique per board): the object of the
        /// board saved last keeps the key, the others' become `<key>@<branch>`.
        public var keyRenames: [KeyRename]
    }

    public struct KeyRename: Codable, Equatable, Sendable {
        public var object: ObjectID
        /// The legacy board it came from; the repository board's own id for an object already on it.
        public var board: BoardID
        public var from: String
        public var to: String
    }

    public struct LegacyReport: Codable, Equatable, Sendable {
        public var board: BoardID
        public var root: String
        /// What its region is titled: the branch, else the worktree's directory name.
        public var label: String
        public var branch: String?
        /// main: the main checkout's current branch, placed as it was; branch: anchored by `ref`;
        /// worktree: detached, branch unknown or path-keyed linked checkout; paths absolute there.
        public var anchor: String
        public var worktree: String?
        public var worktreeLive: Bool
        /// The worktree is (was) in a temporary directory (`/tmp`, `/var/folders`): likely a
        /// throwaway checkout whose region the user may want to delete.
        public var temporary: Bool
        /// merged, alreadyMerged (backed up only), conflict (object ids already on the target: left as is).
        public var status: String
        public var objectsBefore: Int
        /// Objects it contributes to the repository board (a region adds its group).
        public var objectsAfter: Int
        public var region: ObjectID?
        public var offset: [Double]?
        /// Paths that stay tied to a worktree that is gone (or will be): no branch to anchor them.
        public var unanchored: [String]
    }

    public struct Unresolved: Codable, Equatable, Sendable {
        public var board: BoardID
        public var root: String
        public var objects: Int
    }

    /// The ledger in `pre-repo-migration/migration.json`: every run's report, latest last.
    struct Ledger: Codable {
        var runs: [Report]
    }

    /// Whether a migration has ever run on `directory`; the legacy boards it left unresolved.
    public static func pending(in directory: URL) -> (ran: Bool, unresolved: [BoardID]) {
        guard let data = try? Data(contentsOf: ledgerURL(directory)), let ledger = try? decoder.decode(Ledger.self, from: data) else { return (false, []) }
        return (true, ledger.runs.last?.unresolved.map(\.board) ?? [])
    }

    static func ledgerURL(_ directory: URL) -> URL {
        directory.appendingPathComponent(backupFolder, isDirectory: true).appendingPathComponent(reportFile)
    }

    // MARK: Run

    /// Migrates the store at `directory`. `knownRoots` name repositories beyond those of the
    /// stored boards' roots (the saved tabs), for legacy boards whose worktree is gone. With
    /// `only`, merges just that repository's legacy boards (it is being loaded). Legacy boards in
    /// `skipping` (open in the app, which would save them back) are left as if not stored. A dry
    /// run writes nothing.
    public static func run(directory: URL, knownRoots: [URL] = [], only: String? = nil, skipping: Set<BoardID> = [], dryRun: Bool = false, now: Date = Date()) -> Report {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var repoBoards: [String: (url: URL, snapshot: BoardSnapshot)] = [:]
        var nonGit: [BoardID] = []
        var legacy: [(url: URL, snapshot: BoardSnapshot)] = []
        for file in files {
            guard let data = try? Data(contentsOf: file), let snapshot = try? decoder.decode(BoardSnapshot.self, from: data) else { continue }
            if let repo = snapshot.repo {
                repoBoards[repo.commonDir] = (file, snapshot)
            } else if skipping.contains(snapshot.id) {
                continue
            } else if snapshot.id == BoardStore.pathID(URL(fileURLWithPath: snapshot.root)),
                      !BoardStore.isDirectory(snapshot.root) || GitWorktree.containing(URL(fileURLWithPath: snapshot.root).standardizedFileURL.path) == nil {
                // A path id in git (a repository with no commit yet, where git named no branch,
                // or a directory that became a repository after its board was made) is a legacy
                // board of the directory; elsewhere a board outside git.
                nonGit.append(snapshot.id)
            } else {
                legacy.append((file, snapshot))
            }
        }

        var commons = Set(repoBoards.keys)
        for root in legacy.map({ $0.snapshot.root }) + knownRoots.map(\.path) {
            if let worktree = GitWorktree.containing(URL(fileURLWithPath: root).standardizedFileURL.path) { commons.insert(worktree.commonDir) }
        }
        if let only { commons.insert(only) }

        var byRepo: [String: [Legacy]] = [:]
        var unresolved: [Unresolved] = []
        for (url, snapshot) in legacy {
            if let found = identify(snapshot, url: url, commons: commons.sorted()), only == nil || found.commonDir == only {
                byRepo[found.commonDir, default: []].append(found)
            } else {
                unresolved.append(Unresolved(board: snapshot.id, root: snapshot.root, objects: snapshot.objects.count))
            }
        }

        var reports: [RepoReport] = []
        for commonDir in byRepo.keys.sorted() {
            let existing = repoBoards[commonDir]
            var (target, report, merged) = merge(byRepo[commonDir]!, into: existing?.snapshot, modified: existing.map { modified($0.url) } ?? .distantPast,
                                                 commonDir: commonDir, now: now)
            reports.append(report)
            for entry in report.legacy where entry.status == "conflict" {
                unresolved.append(Unresolved(board: entry.board, root: entry.root, objects: entry.objectsBefore))
            }
            // Nothing merged or backed up (every board a conflict): the target stays as it is.
            guard !dryRun, !merged.isEmpty else { continue }
            target.revision += 1
            guard let data = try? encoder.encode(target),
                  (try? data.write(to: directory.appendingPathComponent("\(target.id).json"), options: .atomic)) != nil else { continue }
            for url in merged { backUp(url, in: directory) }
        }
        unresolved.sort { $0.board < $1.board }
        let report = Report(ranAt: now, dryRun: dryRun, repos: reports, nonGit: nonGit, unresolved: unresolved)
        // A repository's load that changed nothing (its boards still conflict, the same ones
        // left unresolved) adds no run: each launch would add the same one.
        let changedNothing = only != nil && reports.allSatisfy { $0.legacy.allSatisfy { $0.status == "conflict" } }
            && unresolved.map(\.board) == pending(in: directory).unresolved
        if !dryRun, !changedNothing { appendToLedger(report, in: directory) }
        return report
    }

    // MARK: Identifying legacy boards

    enum Identity: Equatable {
        case branch(String)
        case detached(top: String)
        case unknown
        /// Keyed by its directory's path: opened before its repository had a commit, or before
        /// the directory was in a repository at all.
        case path
    }

    struct Legacy {
        var url: URL
        var snapshot: BoardSnapshot
        var commonDir: String
        var identity: Identity
        /// The worktree's top level (as it was when gone); the root's worktree otherwise.
        var top: String
        var live: Bool
        /// When its file was last saved: the latest board's object keeps a key two boards hold.
        var modified: Date { RepoBoardMigration.modified(url) }

        var isDetached: Bool {
            if case .detached = identity { return true }
            return false
        }
    }

    static func identify(_ snapshot: BoardSnapshot, url: URL, commons: [String]) -> Legacy? {
        let root = URL(fileURLWithPath: snapshot.root).standardizedFileURL.path
        if BoardStore.isDirectory(root), let worktree = GitWorktree.containing(root) {
            let identity = snapshot.id == BoardStore.pathID(URL(fileURLWithPath: root)) ? .path
                : match(snapshot.id, commonDir: worktree.commonDir, root: root, extraBranches: []) ?? .unknown
            return Legacy(url: url, snapshot: snapshot, commonDir: worktree.commonDir, identity: identity, top: worktree.toplevel, live: true)
        }
        for common in commons {
            // A worktree deleted without `git worktree prune` still has its entry, naming its
            // top level and the branch it had.
            let stale = staleWorktrees(commonDir: common).first { root == $0.top || root.hasPrefix($0.top + "/") }
            if let identity = match(snapshot.id, commonDir: common, root: root, extraBranches: stale?.branch.map { [$0] } ?? []) ?? (stale != nil ? .unknown : nil) {
                let top: String
                if case .detached(let found) = identity { top = found } else { top = stale?.top ?? root }
                return Legacy(url: url, snapshot: snapshot, commonDir: common, identity: identity, top: top, live: false)
            }
        }
        return nil
    }

    /// Which legacy identity of repository `commonDir` hashes to `id`: one of its branches, or a
    /// detached worktree at `root` or above it. Git printed paths with symlinks resolved.
    static func match(_ id: BoardID, commonDir: String, root: String, extraBranches: [String]) -> Identity? {
        let commons = unique([commonDir, GitDiffEngine.realPath(URL(fileURLWithPath: commonDir)).path])
        let branches = unique(GitWorktree.branches(commonDir: commonDir) + extraBranches)
        var tops: [String] = []
        for start in unique([root, GitDiffEngine.realPath(URL(fileURLWithPath: root)).path]) {
            var directory = URL(fileURLWithPath: start)
            while directory.path != "/" {
                tops.append(directory.path)
                directory.deleteLastPathComponent()
            }
        }
        for common in commons {
            for branch in branches where [branch, "heads/" + branch].contains(where: { BoardStore.hashedID("\(common)\n\($0)") == id }) {
                return .branch(branch)
            }
            for top in tops where BoardStore.hashedID("\(common)\n\(top)") == id { return .detached(top: top) }
        }
        return nil
    }

    /// Linked worktrees whose directory is gone but whose entry git still has.
    static func staleWorktrees(commonDir: String) -> [(top: String, branch: String?)] {
        let linked = URL(fileURLWithPath: commonDir).appendingPathComponent("worktrees")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: linked.path)) ?? []
        return names.compactMap { name in
            let entry = linked.appendingPathComponent(name)
            guard let text = try? String(contentsOf: entry.appendingPathComponent("gitdir"), encoding: .utf8) else { return nil }
            let dotGit = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !FileManager.default.fileExists(atPath: dotGit.path) else { return nil }
            let head = (try? String(contentsOf: entry.appendingPathComponent("HEAD"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = head.flatMap { $0.hasPrefix("ref: refs/heads/") ? String($0.dropFirst("ref: refs/heads/".count)) : nil }
            return (dotGit.deletingLastPathComponent().standardizedFileURL.path, branch)
        }
    }

    // MARK: Merging

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func merge(_ boards: [Legacy], into existing: BoardSnapshot?, modified existingModified: Date = .distantPast, commonDir: String, now: Date) -> (BoardSnapshot, RepoReport, [URL]) {
        let canonical = GitWorktree.canonicalRoot(commonDir: commonDir)
        let main = GitWorktree.containing(canonical).flatMap { $0.isMain && $0.commonDir == commonDir ? $0 : nil }
        var target = existing ?? BoardSnapshot(format: Board.format, id: BoardStore.repoID(commonDir: commonDir), root: canonical, revision: 0, objects: [])
        target.root = canonical
        var repo = target.repo ?? RepoRecord(commonDir: commonDir)
        let before = target.objects.count

        func isMainCheckout(_ legacy: Legacy) -> Bool {
            guard let main else { return false }
            let top = GitDiffEngine.realPath(URL(fileURLWithPath: legacy.top)).path
            return top == GitDiffEngine.realPath(URL(fileURLWithPath: main.toplevel)).path
        }
        func isBase(_ legacy: Legacy) -> Bool {
            guard isMainCheckout(legacy), let main else { return false }
            switch legacy.identity {
            case .branch(let name): return name == main.branch
            case .detached: return main.branch == nil
            case .path: return true
            case .unknown: return false
            }
        }
        let base = target.objects.isEmpty ? boards.first(where: isBase) : nil
        let ordered = (base.map { [$0] } ?? []) + boards.filter { $0.url != base?.url }.sorted { label(of: $0) < label(of: $1) }

        var reports: [LegacyReport] = []
        var merged: [URL] = []
        var placed = extent(of: target.objects)
        // Where each object came from, for keys two boards hold.
        var sources: [ObjectID: (board: BoardID, modified: Date, label: String?)] = [:]
        for object in target.objects { sources[object.id] = (target.id, existingModified, nil) }
        for legacy in ordered {
            let snapshot = legacy.snapshot
            let anchor: Rerooter.Anchor
            let branch: String?
            switch legacy.identity {
            case .branch(let name):
                branch = name
                anchor = legacy.url == base?.url || (isMainCheckout(legacy) && name == main?.branch) ? .main
                    : .branch(name, sha: GitWorktree.branchSha(commonDir: commonDir, branch: name))
            case .path:
                branch = legacy.live ? GitWorktree.containing(legacy.top).flatMap { $0.commonDir == commonDir ? $0.branch : nil } : nil
                anchor = legacy.url == base?.url || isMainCheckout(legacy) ? .main : .absolute
            case .detached, .unknown:
                branch = nil
                anchor = legacy.url == base?.url ? .main : .absolute
            }
            var entry = LegacyReport(board: snapshot.id, root: snapshot.root, label: label(of: legacy), branch: branch, anchor: anchor.name,
                                     worktree: legacy.top, worktreeLive: legacy.live, temporary: isTemporary(legacy.top), status: "merged", objectsBefore: snapshot.objects.count,
                                     objectsAfter: 0, region: nil, offset: nil, unanchored: [])
            if repo.merged?.contains(snapshot.id) == true {
                entry.status = "alreadyMerged"
                reports.append(entry)
                merged.append(legacy.url)
                continue
            }
            let taken = Set(target.objects.map(\.id))
            if snapshot.objects.contains(where: { taken.contains($0.id) }) {
                entry.status = "conflict"
                reports.append(entry)
                continue
            }

            // A folder's live HEAD belongs to the worktree record, not its objects' anchors.
            let rerootBranch = legacy.identity == .path ? nil : branch
            var rerooter = Rerooter(oldRoot: URL(fileURLWithPath: snapshot.root).standardizedFileURL.path, top: legacy.top, live: legacy.live, anchor: anchor,
                                    destinationRoot: URL(fileURLWithPath: target.root))
            var objects = snapshot.objects.map { object -> CanvasObject in
                var object = object
                if (snapshot.format ?? 1) < 2, RenderMath.isTile(object.type) { object.frame.h += RenderMath.tileTitleHeight }
                return rerooter.reroot(object, branch: rerootBranch)
            }
            let tray = (snapshot.tray ?? []).map { rerooter.reroot($0) }
            let messages = (snapshot.messages ?? [:]).mapValues { $0.map { rerooter.reroot($0) } }

            var region: CanvasObject?
            if legacy.url != base?.url, !objects.isEmpty {
                // Every object of the board moves right of what is placed, top-aligned with it,
                // inside a group titled with its branch.
                let grouped = Set(objects.filter { $0.type == .group }.flatMap { GroupSpec($0.props)?.members ?? [] })
                let members = objects.filter { !grouped.contains($0.id) && $0.type != .arrow }.map(\.id)
                let bounds = union(objects.filter { members.contains($0.id) }.map(\.frame)) ?? union(objects.map(\.frame))!
                let inset = GroupSpec.defaultPadding
                var dx = 0.0, dy = 0.0
                if let placed {
                    dx = placed.maxX + gap - (bounds.x - inset)
                    dy = placed.y - (bounds.y - inset - GroupSpec.titleHeight)
                }
                let zShift = (target.objects.map(\.z).max() ?? 0) + 1 - (objects.map(\.z).min() ?? 0)
                objects = objects.map { shifted($0, dx: dx, dy: dy, dz: target.objects.isEmpty ? 0 : zShift) }
                if !members.isEmpty {
                    let frame = Frame(x: bounds.x + dx - inset, y: bounds.y + dy - inset - GroupSpec.titleHeight,
                                      w: bounds.w + 2 * inset, h: bounds.h + 2 * inset + GroupSpec.titleHeight)
                    let key: String
                    if case .branch(let name) = legacy.identity { key = "branch:\(name)" }
                    else { key = "\(legacy.isDetached ? "detached" : "worktree"):\(label(of: legacy))" }
                    region = CanvasObject(id: IDs.make("obj"), type: .group, frame: frame, z: (objects.map(\.z).max() ?? 0) + 1, createdBy: .user, createdAt: now,
                                          props: .object(["members": .array(members.map(JSONValue.string)), "title": .string(label(of: legacy)), "key": .string(key)]))
                }
                entry.offset = [dx, dy]
            }
            if let region {
                objects.append(region)
                // A throwaway checkout's region stays marked until the user has seen it.
                if entry.temporary {
                    target.attention = (target.attention ?? []) + [Attention(object: region.id, message: "From a temporary worktree (\(legacy.top)): delete this region if you don't need it",
                                                                            raisedBy: nil, raisedAt: now)]
                }
            }
            for object in objects { sources[object.id] = (snapshot.id, legacy.modified, label(of: legacy)) }
            target.objects += objects
            placed = union([placed, extent(of: objects)].compactMap { $0 })

            target.tray = unique((target.tray ?? []) + tray, by: \.id)
            target.attention = unique((target.attention ?? []) + (snapshot.attention ?? []), by: \.object).nilIfEmpty
            target.finalAnswers = (target.finalAnswers ?? [:]).merging(snapshot.finalAnswers ?? [:]) { old, _ in old }.nilIfEmpty
            target.turnErrors = (target.turnErrors ?? [:]).merging(snapshot.turnErrors ?? [:]) { old, _ in old }.nilIfEmpty
            target.lifecycleSeq = (target.lifecycleSeq ?? [:]).merging(snapshot.lifecycleSeq ?? [:]) { old, _ in old }.nilIfEmpty
            target.relaunchedAgents = Array(Set((target.relaunchedAgents ?? []) + (snapshot.relaunchedAgents ?? []))).sorted().nilIfEmpty
            if let theirs = snapshot.promptTarget {
                var ours = target.promptTarget ?? PromptTarget.State()
                // The base board's terminals stay the most recently focused.
                ours.focusOrder = legacy.url == base?.url ? ours.focusOrder + theirs.focusOrder : theirs.focusOrder + ours.focusOrder
                ours.chosen = ours.chosen ?? theirs.chosen
                target.promptTarget = ours
            }
            // Old names keep reaching their terminals; messages not yet taken stay queued.
            target.aliases = (target.aliases ?? [:]).merging(snapshot.aliases ?? [:]) { old, _ in old }.nilIfEmpty
            target.messages = (target.messages ?? [:]).merging(messages) { old, new in old + new }.nilIfEmpty
            target.revision = max(target.revision, snapshot.revision)
            if !(anchor == .main && isMainCheckout(legacy)) || region != nil {
                let path = GitWorktree.normalized(legacy.top)
                if let index = repo.worktrees.firstIndex(where: { $0.path == path && $0.branch == branch }) {
                    repo.worktrees[index].region = region?.id ?? repo.worktrees[index].region
                } else {
                    repo.worktrees.append(WorktreeRecord(path: path, branch: branch, region: region?.id))
                }
            }
            repo.merged = (repo.merged ?? []) + [snapshot.id]
            entry.objectsAfter = objects.count
            entry.region = region?.id
            entry.unanchored = rerooter.unanchored
            reports.append(entry)
            merged.append(legacy.url)
        }
        let renames = uniqueKeys(&target.objects, sources: sources)
        target.format = Board.format
        target.repo = repo
        let report = RepoReport(board: target.id, root: canonical, commonDir: commonDir, objectsBefore: before, objectsAfter: target.objects.count, legacy: reports,
                                keyRenames: renames)
        return (target, report, merged)
    }

    /// One holder per `props.key`: the object from the board saved last keeps it, every other
    /// becomes `<key>@<its board's branch>` (a further `-2`, `-3` when that is taken too).
    static func uniqueKeys(_ objects: inout [CanvasObject], sources: [ObjectID: (board: BoardID, modified: Date, label: String?)]) -> [KeyRename] {
        var holders: [String: [Int]] = [:]
        for (index, object) in objects.enumerated() {
            if let key = object.props["key"]?.string, !key.isEmpty { holders[key, default: []].append(index) }
        }
        var taken = Set(holders.keys)
        var renames: [KeyRename] = []
        for key in holders.keys.sorted() {
            guard let indices = holders[key], indices.count > 1 else { continue }
            let ranked = indices.sorted { a, b in
                let x = sources[objects[a].id]?.modified ?? .distantPast, y = sources[objects[b].id]?.modified ?? .distantPast
                return x != y ? x > y : objects[a].id < objects[b].id
            }
            for index in ranked.dropFirst() {
                let source = sources[objects[index].id]
                let base = "\(key)@\(source?.label ?? "repo")"
                var renamed = base, n = 2
                while taken.contains(renamed) {
                    renamed = "\(base)-\(n)"
                    n += 1
                }
                taken.insert(renamed)
                var props = objects[index].props.object ?? [:]
                props["key"] = .string(renamed)
                objects[index].props = .object(props)
                renames.append(KeyRename(object: objects[index].id, board: source?.board ?? "", from: key, to: renamed))
            }
        }
        return renames
    }

    static func isTemporary(_ path: String) -> Bool {
        let real = GitDiffEngine.realPath(URL(fileURLWithPath: path)).path
        return ["/private/tmp/", "/private/var/folders/"].contains { real.hasPrefix($0) }
    }

    static func label(of legacy: Legacy) -> String {
        if case .branch(let name) = legacy.identity { return name }
        return (legacy.top as NSString).lastPathComponent
    }

    /// Moves an object by (dx, dy) and its z by dz; an arrow's point-bound ends move with it.
    static func shifted(_ object: CanvasObject, dx: Double, dy: Double, dz: Double) -> CanvasObject {
        var object = object
        object.frame.x += dx
        object.frame.y += dy
        object.z += dz
        if object.type == .arrow, var props = object.props.object {
            for end in ["from", "to"] {
                guard let point = props[end]?["point"]?.array, point.count == 2, let x = point[0].number, let y = point[1].number else { continue }
                props[end] = .object(["point": .array([.number(x + dx), .number(y + dy)])])
            }
            object.props = .object(props)
        }
        return object
    }

    /// The bounds of what the objects draw (arrows follow their ends, so they don't count).
    static func extent(of objects: [CanvasObject]) -> Frame? {
        union(objects.filter { $0.type != .arrow }.map(\.frame)) ?? union(objects.map(\.frame))
    }

    static func union(_ frames: [Frame]) -> Frame? {
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { a, b in
            let x = min(a.x, b.x), y = min(a.y, b.y)
            return Frame(x: x, y: y, w: max(a.maxX, b.maxX) - x, h: max(a.maxY, b.maxY) - y)
        }
    }

    // MARK: Files

    static func backUp(_ url: URL, in directory: URL) {
        let backups = directory.appendingPathComponent(backupFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        var destination = backups.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = backups.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(Int(Date().timeIntervalSince1970)).json")
        }
        try? FileManager.default.moveItem(at: url, to: destination)
    }

    static func appendToLedger(_ report: Report, in directory: URL) {
        let url = ledgerURL(directory)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var ledger = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Ledger.self, from: $0) } ?? Ledger(runs: [])
        ledger.runs.append(report)
        let pretty = JSONEncoder()
        pretty.dateEncodingStrategy = .iso8601
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? pretty.encode(ledger) { try? data.write(to: url, options: .atomic) }
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

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    static func unique<T, K: Hashable>(_ values: [T], by key: KeyPath<T, K>) -> [T] {
        var seen = Set<K>()
        return values.filter { seen.insert($0[keyPath: key]).inserted }
    }
}

/// Rewrites a legacy board's paths for the repository board's root (the design's "Re-rooting").
struct Rerooter {
    enum Anchor: Equatable {
        /// The main checkout on the branch it has now: paths relative to the new root.
        case main
        /// A branch: relative paths within the repository, tiles `ref`-anchored.
        case branch(String, sha: String?)
        /// No branch: paths absolute in the worktree.
        case absolute

        var name: String {
            switch self {
            case .main: "main"
            case .branch: "branch"
            case .absolute: "worktree"
            }
        }
    }

    let oldRoot: String
    let top: String
    let live: Bool
    let anchor: Anchor
    /// The board that will build the diagram next, not necessarily this legacy worktree's top.
    let destinationRoot: URL
    var unanchored: [String] = []

    /// `path` as written on the legacy board, absolute.
    func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : URL(fileURLWithPath: oldRoot).appendingPathComponent(path).standardizedFileURL.path
    }

    /// `path` relative to the repository's top level, when it lies in the legacy board's worktree.
    func repoRelative(_ path: String) -> String? {
        let absolute = absolute(path)
        return absolute.hasPrefix(top + "/") ? String(absolute.dropFirst(top.count + 1)) : nil
    }

    /// Where the legacy board's root is in its worktree ("" at the top): what its relative paths
    /// were relative to, beyond the top.
    var place: String { oldRoot.hasPrefix(top + "/") ? String(oldRoot.dropFirst(top.count + 1)) : "" }

    /// A path as the destination board's next diagram build writes it (`CallGraphBuilder`):
    /// relative to that board's root when beneath it, including nested linked worktrees and
    /// symlink aliases; standardized and absolute otherwise.
    func moved(_ path: String) -> String {
        Board.relativePath(absolute(path), root: destinationRoot)
    }

    /// A diagram node's id, `<path>#<symbol>` (`CallGraphBuilder`), with its path moved as the
    /// node's is, so the diagram's next build finds its nodes, expansions and bound arrows again.
    func nodeID(_ id: String) -> String {
        guard let hash = id.firstIndex(of: "#") else { return id }
        return moved(String(id[..<hash])) + id[hash...]
    }

    /// A path a tile with `ref` can read: relative stays relative (to the repository), anchored
    /// by the tile's branch; without a branch it becomes absolute in the worktree.
    mutating func tilePath(_ path: String, what: String) -> String {
        guard !path.hasPrefix("/") else { return path }
        switch anchor {
        case .main, .branch:
            if let relative = repoRelative(path) { return relative }
            return pinned(absolute(path), what: what)
        case .absolute:
            return pinned(absolute(path), what: what)
        }
    }

    /// A path nothing anchors by branch (an image, a terminal's directory): relative to the new
    /// root only from the main checkout, else absolute in the worktree.
    mutating func worktreePath(_ path: String, what: String) -> String {
        guard !path.hasPrefix("/") else { return path }
        if anchor == .main, let relative = repoRelative(path) { return relative }
        return pinned(absolute(path), what: what)
    }

    /// An absolute path in the legacy worktree: reported when that worktree is gone (or, with no
    /// branch to read instead, will be when it's deleted).
    private mutating func pinned(_ path: String, what: String) -> String {
        if !live || !FileManager.default.fileExists(atPath: path) { unanchored.append("\(what): \(path)") }
        return path
    }

    /// A `root` prop: relative to the new root when it is in the main checkout, else absolute.
    mutating func rootPath(_ path: String, what: String) -> String {
        if anchor == .main, let relative = repoRelative(path) { return relative.isEmpty ? "." : relative }
        let absolute = absolute(path)
        if !FileManager.default.fileExists(atPath: absolute) { unanchored.append("\(what): \(absolute)") }
        return absolute
    }

    mutating func reroot(_ object: CanvasObject, branch: String?) -> CanvasObject {
        guard var props = object.props.object else { return object }
        let what = "\(object.id) \(object.type.rawValue)"
        var refAnchor: Bool {
            if case .branch = anchor { return props["ref"] == nil && props["root"] == nil && props["pinnedCommit"] == nil }
            return false
        }
        func setRef() {
            guard case .branch(let name, let sha) = anchor else { return }
            props["ref"] = .string(name)
            if let sha { props["refSha"] = .string(sha) }
        }
        switch object.type {
        case .code:
            let relative = props["path"]?.string.map { !$0.hasPrefix("/") } ?? false
            let anchorByRef = relative && refAnchor
            if let path = props["path"]?.string { props["path"] = .string(tilePath(path, what: what)) }
            if let history = props["history"]?.array {
                props["history"] = .array(history.map { entry in
                    guard var fields = entry.object, let path = fields["path"]?.string else { return entry }
                    fields["path"] = .string(tilePath(path, what: "\(what) history"))
                    return .object(fields)
                })
            }
            if anchorByRef { setRef() }
        case .note, .html:
            if let root = props["root"]?.string, !root.isEmpty {
                props["root"] = .string(rootPath(root, what: what))
            } else if refAnchor && place.isEmpty {
                setRef()
            } else if anchor == .absolute || !place.isEmpty {
                // Its relative links meant the legacy board's root, which the repository
                // board's isn't (a `ref` reads from the top, so it can't say where either).
                props["root"] = .string(rootPath(oldRoot, what: what))
            }
        case .changes:
            if let root = props["root"]?.string, !root.isEmpty {
                props["root"] = .string(rootPath(root, what: what))
            } else {
                // Paths and Viewed keys were relative to the old root.
                func inPlace(_ path: String) -> String {
                    guard !path.hasPrefix("/") else { return path }
                    if anchor == .absolute { return absolute(path) }
                    return place.isEmpty ? path : (place as NSString).appendingPathComponent(path)
                }
                if anchor == .absolute {
                    props["root"] = .string(rootPath(oldRoot, what: what))
                } else {
                    if let paths = props["paths"]?.array { props["paths"] = .array(paths.map { $0.string.map { .string(inPlace($0)) } ?? $0 }) }
                    if refAnchor {
                        // A ref'd changes tile defaults to the branch's merge-base view; keep the
                        // uncommitted work it showed.
                        if props["base"] == nil { props["base"] = .string("HEAD") }
                        setRef()
                    }
                }
                if let viewed = props["viewed"]?.object {
                    props["viewed"] = .object(Dictionary(viewed.map { (inPlace($0.key), $0.value) }, uniquingKeysWith: { a, _ in a }))
                }
            }
        case .image:
            if let path = props["path"]?.string { props["path"] = .string(worktreePath(path, what: what)) }
        case .diagram:
            // Its file, the graph as last computed (node paths and ids, its aim) and the nodes
            // it expanded, as the repository board's next build writes them (`moved`), so that
            // build finds them again: nothing anchors a diagram by branch.
            if let path = props["path"]?.string {
                let rebased = moved(path)
                props["path"] = .string(rebased.hasPrefix("/") && !path.hasPrefix("/") ? pinned(rebased, what: what) : rebased)
            }
            if let expanded = props["expanded"]?.array { props["expanded"] = .array(expanded.map { $0.string.map { .string(nodeID($0)) } ?? $0 }) }
            if var graph = props["graph"]?.object {
                if var aim = graph["aim"]?.object, let path = aim["path"]?.string {
                    aim["path"] = .string(moved(path))
                    graph["aim"] = .object(aim)
                }
                if let root = graph["root"]?.string { graph["root"] = .string(nodeID(root)) }
                if let nodes = graph["nodes"]?.array {
                    graph["nodes"] = .array(nodes.map { node in
                        guard var fields = node.object else { return node }
                        if let id = fields["id"]?.string { fields["id"] = .string(nodeID(id)) }
                        if let path = fields["path"]?.string { fields["path"] = .string(moved(path)) }
                        return .object(fields)
                    })
                }
                if let edges = graph["edges"]?.array {
                    graph["edges"] = .array(edges.map { edge in
                        guard var fields = edge.object else { return edge }
                        for end in ["from", "to"] { if let id = fields[end]?.string { fields[end] = .string(nodeID(id)) } }
                        return .object(fields)
                    })
                }
                props["graph"] = .object(graph)
            }
        case .arrow:
            // An end bound to a diagram's node names it by id.
            for end in ["from", "to"] {
                guard var binding = props[end]?.object, let node = binding["node"]?.string else { continue }
                binding["node"] = .string(nodeID(node))
                props[end] = .object(binding)
            }
        case .terminal:
            if let cwd = props["cwd"]?.string, !cwd.isEmpty {
                let directory = absolute(cwd)
                props["cwd"] = .string(directory)
                if !live || !BoardStore.isDirectory(directory) { unanchored.append("\(what) cwd: \(directory)") }
                if props["worktree"] == nil, directory == top || directory.hasPrefix(top + "/") {
                    props["worktree"] = .string(GitWorktree.normalized(top))
                    if let branch { props["branch"] = .string(branch) }
                }
            }
        default:
            break
        }
        var object = object
        object.props = .object(props)
        return object
    }

    /// A staged mention's path, rewritten as its tile's.
    mutating func reroot(_ mention: Mention) -> Mention {
        var mention = mention
        switch mention.target {
        case .code(let object, let path, let lines, let side, let symbol, let commit, let diff):
            mention.target = .code(object: object, path: tilePath(path, what: "tray \(mention.id)"), lines: lines, side: side, symbol: symbol, commit: commit, diff: diff)
        case .image(let object, let path, let x, let y):
            mention.target = .image(object: object, path: worktreePath(path, what: "tray \(mention.id)"), x: x, y: y)
        default:
            break
        }
        return mention
    }

    /// A queued peer message, its mentions rewritten as staged ones.
    mutating func reroot(_ message: AgentMessage) -> AgentMessage {
        var message = message
        message.mentions = message.mentions.map { reroot($0) }
        return message
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

private extension Dictionary {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

extension RepoBoardMigration.Report {
    /// What to tell the user on repository board `board` after this run: the regions merged into
    /// it, and those from temporary worktrees, to delete when not needed; nil when nothing was.
    public func notice(for board: BoardID) -> String? {
        guard let repo = repos.first(where: { $0.board == board }) else { return nil }
        let regions = repo.legacy.filter { $0.status == "merged" && $0.region != nil }
        guard !regions.isEmpty else { return nil }
        var text = "Boards are per repository now: merged \(regions.map(\.label).joined(separator: ", ")) in as regions"
        let temporary = regions.filter(\.temporary)
        if !temporary.isEmpty { text += "; from temporary worktrees, delete if unneeded: \(temporary.map(\.label).joined(separator: ", "))" }
        return text
    }
}
