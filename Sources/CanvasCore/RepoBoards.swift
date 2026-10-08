import CryptoKit
import Foundation

/// One board per git repository (docs/design/repo-boards.md): the repository's common git
/// directory is the board's identity, and the worktrees and branches it was opened from, or that
/// its terminals started in, are attributes of it.
public struct RepoRecord: Codable, Equatable, Sendable {
    /// The repository's common git directory, as `GitWorktree` finds it.
    public var commonDir: String
    /// Every linked worktree the board has seen, with the branch it had, one entry per worktree
    /// and branch (a worktree that switched branch has one per branch).
    public var worktrees: [WorktreeRecord]
    /// Legacy per-branch boards merged into this one (`RepoBoardMigration`).
    public var merged: [BoardID]?

    public init(commonDir: String, worktrees: [WorktreeRecord] = [], merged: [BoardID]? = nil) {
        self.commonDir = commonDir
        self.worktrees = worktrees
        self.merged = merged
    }
}

public struct WorktreeRecord: Codable, Equatable, Sendable {
    /// The worktree's top level.
    public var path: String
    /// The branch checked out there when seen; nil on a detached HEAD or when unknown.
    public var branch: String?
    /// The group holding what a merged legacy board of this worktree and branch held.
    public var region: ObjectID?

    public init(path: String, branch: String?, region: ObjectID? = nil) {
        self.path = path
        self.branch = branch
        self.region = region
    }
}

/// A worktree as `board.list` and `board.open` report it.
public struct WorktreeInfo: Equatable, Sendable {
    public var path: String
    public var branch: String?
    /// The directory is a worktree of this repository with `branch` checked out (for a record
    /// without a branch: the directory is still a worktree of it).
    public var live: Bool
    /// The repository's main checkout (the board root).
    public var main: Bool
    public var region: ObjectID?

    public var json: JSONValue {
        var info: [String: JSONValue] = ["path": .string(path), "live": .bool(live), "main": .bool(main)]
        if let branch { info["branch"] = .string(branch) }
        if let region { info["region"] = .string(region) }
        return .object(info)
    }
}

extension RepoRecord {
    /// The worktrees to report: the live ones of the repository (main checkout first) and every
    /// recorded one, without repeats; `objects` are the board's (a record's region must exist).
    public func worktreeList(objects: [ObjectID: CanvasObject]) -> [WorktreeInfo] {
        let live = GitWorktree.worktrees(commonDir: commonDir)
        var list = live.map { worktree in
            let path = GitWorktree.normalized(worktree.toplevel)
            return WorktreeInfo(path: path, branch: worktree.branch, live: true, main: worktree.isMain,
                                region: region(branch: worktree.branch, path: path, objects: objects))
        }
        for record in worktrees where !list.contains(where: { $0.path == record.path && ($0.branch == record.branch || ($0.live && record.branch == nil)) }) {
            let region = record.region.flatMap { objects[$0] != nil ? $0 : nil }
            let checkout = GitWorktree.containing(record.path).flatMap { $0.commonDir == commonDir && GitWorktree.normalized($0.toplevel) == record.path ? $0 : nil }
            list.append(WorktreeInfo(path: record.path, branch: record.branch, live: checkout != nil && record.branch == nil, main: false, region: region))
        }
        return list
    }

    /// The region of `branch` (any worktree it was in), else a branchless region at `path`;
    /// detached HEAD uses only its path. Missing groups aren't regions.
    public func region(branch: String?, path: String, objects: [ObjectID: CanvasObject]) -> ObjectID? {
        if let branch, let region = worktrees.first(where: { $0.branch == branch && $0.region.map { objects[$0] != nil } == true })?.region {
            return region
        }
        return worktrees.first(where: { $0.path == path && $0.branch == nil && $0.region.map { objects[$0] != nil } == true })?.region
    }

    /// Records the worktree at `path` (`GitWorktree.normalized`) with the branch it has now;
    /// false when it was already recorded so.
    mutating func record(path: String, branch: String?) -> Bool {
        let path = GitWorktree.normalized(path)
        guard !worktrees.contains(where: { $0.path == path && $0.branch == branch }) else { return false }
        worktrees.append(WorktreeRecord(path: path, branch: branch))
        return true
    }
}

extension Board {
    /// The board was opened from `worktree` (a directory in it): a linked worktree becomes the
    /// working worktree and is recorded; the main checkout clears the working worktree.
    public func opened(from worktree: GitWorktree) {
        guard repo?.commonDir == worktree.commonDir else { return }
        workingWorktree = worktree.isMain ? nil : worktree
        if !worktree.isMain { record(worktree) }
    }

    /// The checkout the user opened the board from: the board root's place in the working
    /// worktree, else the board root. New Terminal starts there and Go to lists its files.
    public var workingRoot: URL {
        workingWorktree.flatMap { GitWorktree.counterpart(of: root.path, toward: $0.toplevel) }.map(URL.init(fileURLWithPath:)) ?? root
    }

    /// The region to show for the worktree the board was opened from (`opened(from:)`).
    public func region(for worktree: GitWorktree) -> ObjectID? {
        repo?.region(branch: worktree.branch, path: GitWorktree.normalized(worktree.toplevel), objects: objects)
    }

    /// Worktree and branch a terminal created with `props` starts in, stamped on its props
    /// (`worktree`, `branch`) when its `cwd` lies in the board's repository; a linked worktree is
    /// recorded on the board. `terminalWorks(_:in:)` keeps them current.
    func stampingWorktree(_ props: JSONValue) -> JSONValue {
        guard var fields = props.object else { return props }
        fields.removeValue(forKey: "worktree")
        fields.removeValue(forKey: "branch")
        guard let cwd = fields["cwd"]?.string, !cwd.isEmpty, let stamp = worktreeStamp(absoluteURL(cwd).standardizedFileURL.path) else { return .object(fields) }
        fields.merge(stamp.filter { $0.value != .null }) { $1 }
        return .object(fields)
    }

    /// Terminal `tile` works in `directory` now: its foreground program's current directory, else
    /// its shell's (the app reads them from the process table as a program starts and at each
    /// prompt). `workingDirectory(of:)` answers it, and the terminal's `worktree` and `branch`
    /// follow the checkout it lies in when that is one of the board's repository, so after
    /// `cd ../wt && codex` the terminal and its agent are `wt`'s: worktree affinity routes that
    /// worktree's mentions there and Review Changes reviews it. Written as bookkeeping (no rev,
    /// undo step or log); a directory outside the repository leaves them as they were.
    public func terminalWorks(_ tile: ObjectID, in directory: String) {
        guard let terminal = objects[tile], terminal.type == .terminal else { return }
        workingDirectories[tile] = directory
        guard let stamp = worktreeStamp(directory) else { return }
        commitBookkeeping(terminal, props: .object(stamp))
    }

    /// `worktree` and `branch` (null on a detached HEAD) of the checkout `directory` lies in when
    /// that is one of the board's repository, a linked one recorded on the board; else nil.
    private func worktreeStamp(_ directory: String) -> [String: JSONValue]? {
        guard let repo, let worktree = GitWorktree.containing(directory), worktree.commonDir == repo.commonDir else { return nil }
        if !worktree.isMain { record(worktree) }
        return ["worktree": .string(GitWorktree.normalized(worktree.toplevel)), "branch": worktree.branch.map(JSONValue.string) ?? .null]
    }

    /// The checkout Review Changes and Review Branch review, as a changes tile's `root`: the
    /// linked worktree of the board's repository `terminal` works in (the terminal holding the
    /// keyboard, else the one selected), else the working worktree (`opened(from:)`); nil for
    /// the board's own checkout.
    public func reviewRoot(terminal: ObjectID?) -> String? {
        let own = GitWorktree.containing(root.path)
        let worked = terminal.flatMap { objects[$0]?.type == .terminal ? GitWorktree.containing(workingDirectory(of: $0)) : nil }
        guard let worktree = worked ?? workingWorktree, let own, worktree.commonDir == own.commonDir, worktree.gitDir != own.gitDir else { return nil }
        return worktree.toplevel
    }

    /// What Review Branch offers to pick from when it has no worktree to go by (`reviewRoot`
    /// nil) and the board's own checkout is on the default branch, which it would only review
    /// against itself: the repository's other worktrees. Empty otherwise.
    public var branchReviewChoices: [GitWorktree] {
        guard let own = GitWorktree.containing(root.path), let branch = own.branch, let base = own.defaultBranch,
              base == branch || base == "origin/\(branch)" else { return [] }
        return own.siblings.filter { $0.gitDir != own.gitDir }
    }

    private func record(_ worktree: GitWorktree) {
        guard var record = repo, record.record(path: worktree.toplevel, branch: worktree.branch) else { return }
        repo = record
        onChange?()
    }

    /// The regions of branch `name`: groups keyed `branch:<name>`, by id.
    public func regions(ofBranch name: String) -> [ObjectID] {
        objects.values.filter { $0.type == .group && $0.props["key"]?.string == "branch:\(name)" }.map(\.id).sorted()
    }

    /// The objects of branch `name` (`board.get` `branch`): its regions (`regions(ofBranch:)`)
    /// and what they hold (nested groups too), objects whose `ref` is the branch, terminals that
    /// started on it, and arrows between those.
    public func objects(ofBranch name: String) -> Set<ObjectID> {
        var found = Set<ObjectID>()
        var pending = regions(ofBranch: name) + objects.values.filter { object in
            object.props["ref"]?.string == name || (object.type == .terminal && object.props["branch"]?.string == name)
        }.map(\.id)
        while let id = pending.popLast() {
            guard found.insert(id).inserted, let object = objects[id] else { continue }
            if object.type == .group { pending += GroupSpec(object.props)?.members ?? [] }
        }
        for arrow in objects.values where arrow.type == .arrow {
            // Every bound end among them (a free end is a point, anywhere).
            let ends = [arrow.props["from"]?["object"]?.string, arrow.props["to"]?["object"]?.string].compactMap { $0 }
            if !ends.isEmpty, ends.allSatisfy(found.contains) { found.insert(arrow.id) }
        }
        return found.filter { objects[$0] != nil }
    }
}

extension BoardStore {
    /// `brd_` + 20 hex digits of SHA-256 of `identity`.
    nonisolated static func hashedID(_ identity: String) -> BoardID {
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "brd_\(digest.prefix(20))"
    }

    /// The board id of a repository: its common git directory.
    nonisolated public static func repoID(commonDir: String) -> BoardID { hashedID(commonDir) }

    /// The board id of a directory outside git: its path.
    nonisolated public static func pathID(_ root: URL) -> BoardID { hashedID(root.standardizedFileURL.path) }
}
