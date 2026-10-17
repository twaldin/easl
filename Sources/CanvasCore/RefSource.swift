import Foundation

/// What a tile anchored to a branch (`props.ref` on a code, note, or HTML tile) reads right now
/// (docs/contracts.md, "Branch-anchored tiles"): the working tree of the worktree that has the
/// ref checked out, else git objects at the commit `GitRefs` settles on.
public struct RefSource: Equatable, Sendable {
    public var ref: String
    public var resolution: GitRefs.Resolution
    /// Where relative paths resolve: the board root's place in the live worktree, else the board
    /// root (whose repository holds the objects).
    public var root: URL
    /// The top level of the checkout `root` lies in: an absolute path in any worktree of the
    /// repository is taken relative to its own worktree and re-rooted here.
    public var toplevel: URL
    /// The commit files are read at: nil while live (the working tree), the commit that merged
    /// the branch once it is merged and gone, else the resolved SHA.
    public var commit: String?

    /// `props.ref`, when set.
    public static func ref(of props: JSONValue) -> String? {
        props["ref"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Resolves `ref` in the repository of `boardRoot`, falling back to `lastKnownSha` (the
    /// tile's `props.refSha`) once the ref is gone.
    public static func resolve(ref: String, lastKnownSha: String?, boardRoot: URL) async throws -> RefSource {
        let resolution = try await GitRefs.resolve(repo: boardRoot, ref: ref, lastKnownSha: lastKnownSha)
        let board = boardRoot.standardizedFileURL
        let commit: String? = switch resolution.state {
        case .live: nil
        case .objects, .missing: resolution.sha
        case .merged(let merge): merge
        }
        guard let worktree = resolution.worktree, let checkout = GitWorktree.containing(board.path) else {
            let toplevel = GitWorktree.containing(board.path).map { URL(fileURLWithPath: $0.toplevel) } ?? board
            return RefSource(ref: ref, resolution: resolution, root: board, toplevel: toplevel, commit: commit)
        }
        let place = checkout.relativePath(of: board.path)
        return RefSource(ref: ref, resolution: resolution, root: place.map { worktree.appendingPathComponent($0) } ?? worktree, toplevel: worktree, commit: commit)
    }

    /// The board root's place in the worktree that has `ref` checked out, read from the
    /// filesystem alone (no git, so the main actor may ask); nil when no worktree has it.
    public static func liveRoot(ref: String, boardRoot: URL) -> URL? {
        let board = boardRoot.standardizedFileURL
        guard let checkout = GitWorktree.containing(board.path) else { return nil }
        guard let live = GitRefs.liveWorktree(ref, in: checkout) else { return nil }
        let top = URL(fileURLWithPath: live.toplevel)
        return checkout.relativePath(of: board.path).map { top.appendingPathComponent($0) } ?? top
    }

    /// The file a tile `path` names under this ref: a relative path under `root`, an absolute
    /// one in any worktree of the repository at the same place under `toplevel`.
    public func url(for path: String) -> URL {
        guard path.hasPrefix("/") else { return root.appendingPathComponent(path) }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let worktree = GitWorktree.containing(url.path), let relative = worktree.relativePath(of: url.path),
              let here = GitWorktree.containing(toplevel.path), here.commonDir == worktree.commonDir else { return url }
        return toplevel.appendingPathComponent(relative)
    }

    /// `fence` (a code tile's range, a note's excerpt) read under this ref, against `root`: an
    /// absolute path re-rooted (`url(for:)`), read at the ref's commit unless it names its own.
    public func fence(_ fence: NoteFence) -> NoteFence {
        var fence = fence
        if let path = fence.path, path.hasPrefix("/") { fence.path = url(for: path).path }
        if fence.commit?.isEmpty ?? true { fence.commit = commit }
        return fence
    }

    /// A note's fences read under this ref (`fence(_:)`).
    public func fences(_ fences: [NoteMarkdown.AnchoredFence]) -> [NoteMarkdown.AnchoredFence] {
        fences.map { anchored in
            var anchored = anchored
            anchored.fence = fence(anchored.fence)
            return anchored
        }
    }

    /// The header's words for the state: `live in <worktree>`, `<ref> @ <sha>`, `merged in <sha>`,
    /// `branch gone, showing <sha>`.
    public var label: String { Self.label(ref: ref, resolution: resolution) }

    /// `label` for `ref` resolved to `resolution`, here or on a remote board's host.
    public static func label(ref: String, resolution: GitRefs.Resolution) -> String {
        switch resolution.state {
        case .live: "live in \(resolution.worktree?.lastPathComponent ?? "worktree")"
        case .objects: "\(ref) @ \(resolution.sha.prefix(7))"
        case .merged(let merge): "merged in \(merge.prefix(7))"
        case .missing: "branch gone, showing \(resolution.sha.prefix(7))"
        }
    }

    /// Why a ref can't be read, in the header's and the API's words.
    public static func describe(_ failure: Error, ref: String) -> String {
        switch failure as? GitRefs.Failure {
        case .notRevision?: "\"\(ref)\" is not a ref"
        case .notRepository?: "not in a git repository"
        case .unknownRef?, nil: "unknown ref \(ref)"
        }
    }
}

/// Where a note's or HTML tile's referenced files are read (`Board.linkSource`): its link root,
/// and with a `ref`, where the ref is now.
public struct LinkReading: Sendable {
    public var root: URL
    public var ref: RefSource?
    /// A ref that can't be read (`RefSource.describe`): its fences read at the ref's name, and
    /// fail saying so, instead of quietly reading the board's checkout.
    public var failure: (ref: String, reason: String)?

    public init(root: URL, ref: RefSource? = nil, failure: (ref: String, reason: String)? = nil) {
        self.root = root
        self.ref = ref
        self.failure = failure
    }

    /// The commit files without their own are read at; nil for the working tree.
    public var commit: String? { ref?.commit ?? failure?.ref }

    public func fences(_ fences: [NoteMarkdown.AnchoredFence]) -> [NoteMarkdown.AnchoredFence] {
        if let ref { return ref.fences(fences) }
        guard let failure else { return fences }
        return fences.map { anchored in
            var anchored = anchored
            if anchored.fence.commit?.isEmpty ?? true { anchored.fence.commit = failure.ref }
            return anchored
        }
    }

    /// The text of `path` (relative to `root`, or absolute) as read here.
    public func read(_ path: String) async throws -> String {
        let file = path.hasPrefix("/") ? (ref?.url(for: path).path ?? path) : path
        return try await NoteSource.read(file, commit: commit, root: root)
    }
}

extension Board {
    /// Where `props` (a note's or HTML tile's) read the files they name. Without a `ref`, the
    /// link root; with one, resolved now (`RefSource`). Records nothing: `linkSource(of:)` does.
    public func linkSource(props: JSONValue) async -> LinkReading {
        guard let ref = RefSource.ref(of: props) else { return LinkReading(root: linkRoot(props: props)) }
        do {
            let source = try await RefSource.resolve(ref: ref, lastKnownSha: props["refSha"]?.string, boardRoot: root)
            return LinkReading(root: source.root, ref: source)
        } catch {
            return LinkReading(root: root, failure: (ref, RefSource.describe(error, ref: ref)))
        }
    }

    /// `linkSource(props:)` for an object on the board, recording its `props.refSha`.
    public func linkSource(of object: CanvasObject) async -> LinkReading {
        let reading = await linkSource(props: object.props)
        if let source = reading.ref { recordRefSha(object.id, ref: source.ref, sha: source.resolution.sha) }
        return reading
    }

    /// Resolves `object`'s `props.ref` (nil without one) and records the SHA it resolved to as
    /// `props.refSha` (bookkeeping, no undo step), so the tile still reads once its worktree and
    /// branch are deleted.
    public func resolveRef(of object: CanvasObject) async throws -> RefSource? {
        guard let ref = RefSource.ref(of: object.props) else { return nil }
        let source = try await RefSource.resolve(ref: ref, lastKnownSha: object.props["refSha"]?.string, boardRoot: root)
        recordRefSha(object.id, ref: ref, sha: source.resolution.sha)
        return source
    }

    /// Writes `props.refSha` while the object still anchors to `ref`.
    public func recordRefSha(_ id: ObjectID, ref: String, sha: String) {
        guard let before = objects[id], RefSource.ref(of: before.props) == ref, before.props["refSha"]?.string != sha else { return }
        commitBookkeeping(before, props: .object(["refSha": .string(sha)]))
    }
}
