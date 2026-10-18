import Foundation

/// A remote board's git (docs/design.md "Client mode"), run where the board's files are. Each
/// call is one host process over the host's ssh master (`HostFiles.execute`): it runs the git
/// commands a local code or changes tile runs, reads working-tree files with the no-follow
/// descriptor reader, and sends their output back, which the parsers and models here turn into
/// the same `CodeDocument` and `ChangeSet` a local tile draws. A listing is one process however
/// many files it shows. Paths are checked on the host, as written and resolved, inside the
/// board's place in a worktree of its repository. Bytes stay in memory.
public struct HostGit: Sendable {
    public let files: HostFiles

    public init(files: HostFiles) {
        self.files = files
    }

    public var hostName: String { files.hostName }


    /// A code tile's file as one host process reads it: against its diff base, at its pinned
    /// commit, or where its ref is now. A ref that can't be read and a path the host refuses come
    /// back as the document saying so; only an unreachable host throws (`unavailable`).
    public func code(_ read: HostCodeRead) async throws -> HostCodeLoad {
        func unavailable(_ reason: String, _ state: FileDiff.State = .pinUnavailable) -> FileDiff {
            FileDiff(state: state, base: nil, baseLabel: reason, old: SideText(""), new: SideText(""), hunks: [])
        }
        let ref = read.pinned == nil ? read.ref : nil
        if let pinned = read.pinned, !NoteSource.isRevision(pinned) {
            return await HostCodeLoad(read: read, diff: unavailable("not a revision: \(pinned)"))
        }
        if let ref, !NoteSource.isRevision(ref) {
            return await HostCodeLoad(read: read, diff: unavailable("\"\(ref)\" is not a ref"), ref: ref)
        }
        var request = Request(op: "code", boardRoot: read.boardRoot)
        request.path = read.path
        request.base = Base(read.base)
        request.pinned = read.pinned
        request.ref = ref
        request.refSha = read.refSha.flatMap { NoteSource.isRevision($0) ? $0 : nil }
        let reply: CodeReply = try await call(request, retryTransport: true)
        let probe = reply.watch.map { HostGitProbe(boardRoot: read.boardRoot, spec: $0) }
        let baseline = reply.baseline.map(HostGitStamp.digest)
        guard reply.ok else {
            switch HostFileError(code: reply.code, message: reply.message, limit: reply.limit) {
            case .unavailable(let message): throw HostFileError.unavailable(message)
            case .ref(let message): return await HostCodeLoad(read: read, diff: unavailable(message), ref: ref, probe: probe, baseline: baseline)
            case let error: return await HostCodeLoad(read: read, diff: unavailable(Self.refusal(error), .unreadable), probe: probe, baseline: baseline)
            }
        }
        let resolution = ref == nil ? nil : reply.ref?.resolution
        let diff: FileDiff
        if let commit = reply.commit {
            diff = await Self.pinned(commit)
        } else {
            diff = await Self.live(reply)
        }
        var load = await HostCodeLoad(read: read, diff: diff, ref: resolution.map { RefSource.label(ref: ref ?? "", resolution: $0) },
                                      readPath: resolution == nil ? nil : reply.file.map { Board.hostRelativePath($0, root: read.boardRoot) },
                                      probe: probe, baseline: baseline)
        load.defaultBranch = reply.defaultBranch
        load.refSha = resolution?.sha
        return load
    }

    private static func pinned(_ commit: CodeReply.Commit) async -> FileDiff {
        func unavailable(_ reason: String) -> FileDiff {
            FileDiff(state: .pinUnavailable, base: nil, baseLabel: reason, old: SideText(""), new: SideText(""), hunks: [])
        }
        guard let sha = commit.sha else { return unavailable(commit.label) }
        guard let data = commit.data.flatMap({ Data(base64Encoded: $0) }) else { return unavailable("not in \(sha.prefix(7))") }
        if GitDiffEngine.looksBinary(data) { return unavailable("binary at \(sha.prefix(7))") }
        let text = await offPool { SideText(String(decoding: data, as: UTF8.self)) }
        return FileDiff(state: .pinned, base: sha, baseLabel: commit.label, old: SideText(""), new: text, hunks: [])
    }

    private static func live(_ reply: CodeReply) async -> FileDiff {
        func state(_ state: FileDiff.State, new: SideText = SideText("")) -> FileDiff {
            FileDiff(state: state, base: nil, baseLabel: nil, old: SideText(""), new: new, hunks: [])
        }
        guard let read = reply.read else { return state(.unstable) }
        switch read.kind {
        case "tooLarge": return state(.tooLarge)
        case "unstable": return state(.unstable)
        default: break
        }
        let data = read.kind == "regular" ? read.data.flatMap { Data(base64Encoded: $0) } : nil
        let new = await offPool { SideText(data.map { String(decoding: $0, as: UTF8.self) } ?? "") }
        guard reply.repository == true else {
            return state(read.kind == "regular" ? .notRepository : .missing, new: new)
        }
        if read.kind == "directory" || read.kind == "submodule" { return state(read.kind == "submodule" ? .submodule : .missing) }
        guard let base = reply.base else { return state(.unstable) }
        guard let sha = base.sha else { return GitDiffEngine.sourceOnly(data: data, new: new, label: base.label, toplevel: nil) }
        let path = reply.rel ?? ""
        let tree = bytes(reply.tree), status = bytes(reply.status), patch = bytes(reply.patch), tooLarge = reply.patchTooLarge == true
        let result = await offPool {
            GitDiffEngine.patchResults([path], entries: GitDiffEngine.parseTree(tree), codes: GitDiffEngine.parseStatus(status),
                                       sections: GitDiffEngine.split(patch), diffTooLarge: tooLarge)[path]
        }
        return await GitDiffEngine.diff(data: data, new: new, base: sha, label: base.label, patch: result ?? .init(), toplevel: nil) ?? state(.unstable)
    }

    /// Why a host read a tile's path no further, in the tile's words.
    public static func refusal(_ error: HostFileError) -> String {
        switch error {
        case .refused: "refused by the host: outside the board"
        case .notFound: "not found on the host"
        case .tooLarge(let limit): "too large on the host (over \(limit >> 20) MiB)"
        case .unreadable: "unreadable on the host"
        case .ref(let message): message
        case .unavailable(let message): "host unavailable: \(message)"
        }
    }


    /// A changes tile's listing as one host process reads it, whatever the file count: a
    /// worktree's changes with what Stage, Unstage, and Discard need of each file, or two commits
    /// compared. What can't be listed comes back as the set's notice; only an unreachable host
    /// throws (`unavailable`). The set's `repository` is nil: its paths aren't this Mac's.
    public func changes(boardRoot: String, spec: ChangesSpec, highlight: Bool = true) async throws -> HostChangesLoad {
        if spec.head != nil, spec.ref != nil { return HostChangesLoad(set: ChangeSet(notice: "give head or ref, not both")) }
        if spec.ref != nil, spec.root != nil { return HostChangesLoad(set: ChangeSet(notice: "give ref or root, not both")) }
        if let ref = spec.ref, !NoteSource.isRevision(ref) { return HostChangesLoad(set: ChangeSet(notice: "not a ref: \(ref)", branch: ref)) }
        var request = Request(op: "changes", boardRoot: boardRoot)
        request.spec = Spec(root: spec.root, ref: spec.ref, refSha: spec.refSha.flatMap { NoteSource.isRevision($0) ? $0 : nil }, head: spec.head,
                            base: Base(spec.base), baseProp: spec.baseProp, paths: spec.paths)
        let reply: ChangesReply = try await call(request, retryTransport: true)
        var load = HostChangesLoad(set: ChangeSet())
        load.probe = reply.watch.map { HostGitProbe(boardRoot: boardRoot, spec: $0) }
        load.baseline = reply.baseline.map(HostGitStamp.digest)
        guard reply.ok else {
            let error = HostFileError(code: reply.code, message: reply.message, limit: reply.limit)
            if case .unavailable = error { throw error }
            load.set = ChangeSet(notice: Self.refusal(error))
            return load
        }
        load.defaultBranch = reply.defaultBranch
        let top = reply.top ?? "", names = reply.boardPaths ?? [:]
        let boardPath: @Sendable (String) -> String = { path in names[path] ?? Board.hostRelativePath(top + "/" + path, root: boardRoot) }
        switch reply.kind {
        case "worktree":
            let worktree = reply.label.map { label in label.branch.map { "\(label.name) (\($0))" } ?? label.name }
            if let notice = reply.notice {
                load.set = ChangeSet(baseLabel: reply.base?.label ?? "", notice: Self.text(notice, head: reply.branch, baseLabel: reply.base?.label ?? spec.baseProp),
                                     worktree: worktree, branch: reply.branch)
            } else {
                let listing = await Self.worktree(reply, boardPath: boardPath)
                load.set = ChangeSet(base: reply.base?.sha, baseLabel: reply.base?.label ?? "", files: listing.files, omitted: reply.omitted ?? 0,
                                     worktree: worktree, head: reply.head, branch: reply.branch)
                load.sides = listing.sides
                load.checkout = reply.top
            }
        case "commits":
            let label = reply.baseLabel ?? spec.baseProp
            let gone: ChangeSet.Gone? = reply.gone.map { $0.merged.map(ChangeSet.Gone.merged) ?? .deleted }
            load.set = ChangeSet(base: reply.baseSha, baseLabel: label, files: await Self.commits(reply, boardPath: boardPath),
                                 notice: reply.notice.map { Self.text($0, head: reply.branch, baseLabel: label) }, omitted: reply.omitted ?? 0,
                                 head: reply.head, branch: reply.branch, commits: reply.baseTip.map { ChangeSet.Commits(baseTip: $0, gone: gone) })
        default:
            load.set = ChangeSet(notice: reply.notice.map { Self.text($0, head: reply.branch, baseLabel: spec.baseProp) } ?? "not comparable", branch: reply.branch)
        }
        load.set.refSha = reply.ref?.sha
        if highlight { load.set = await offPool { [set = load.set] in set.highlighted() } }
        return load
    }

    private static func text(_ notice: ChangesReply.Notice, head: String?, baseLabel: String) -> String {
        if let missing = notice.missing {
            return "no commit \(missing) here; fetch it: \(ChangeSet.fetchCommand(for: missing, remotes: notice.remotes ?? []))"
        }
        if notice.unrelated == true { return "\(head ?? "HEAD") shares no history with \(ChangeSet(baseLabel: baseLabel).baseName)" }
        return notice.text ?? "not comparable"
    }

    private static func worktree(_ reply: ChangesReply, boardPath: (String) -> String) async -> (files: [ChangedFile], sides: [String: ReviewSides]) {
        guard let base = reply.base, let sha = base.sha else { return ([], [:]) }
        let raw = bytes(reply.raw), others = bytes(reply.others), tree = bytes(reply.tree), status = bytes(reply.status), patch = bytes(reply.patch)
        let unstagedPatch = bytes(reply.unstaged), stagedPatch = bytes(reply.staged), headPatch = bytes(reply.againstHead), blobData = bytes(reply.blobs)
        let selectedPaths = reply.selected ?? [], tooLarge = reply.patchTooLarge == true
        let parsed = await offPool { () -> (entries: [ChangeSet.Entry], unstaged: [String: UnifiedDiff.Parsed], staged: [String: UnifiedDiff.Parsed],
                                            head: [String: UnifiedDiff.Parsed], results: [String: GitDiffEngine.PatchResult], blobs: [String: Data]) in
            var entries: [String: ChangeSet.Entry] = [:]
            for entry in ChangeSet.parseRaw(raw) { entries[entry.path] = entry }
            for record in others.split(separator: 0) {
                let path = String(decoding: record, as: UTF8.self)
                if entries[path] == nil { entries[path] = ChangeSet.Entry(status: .added, path: path, oldPath: nil, oldMode: nil, newMode: nil, tracked: false) }
            }
            let selected = selectedPaths.compactMap { entries[$0] }
            let plain = selected.filter { $0.status != .renamed || $0.oldPath == nil }.map(\.path)
            let results = GitDiffEngine.patchResults(plain, entries: GitDiffEngine.parseTree(tree), codes: GitDiffEngine.parseStatus(status),
                                                     sections: GitDiffEngine.split(patch), diffTooLarge: tooLarge)
            func parse(_ patch: Data) -> [String: UnifiedDiff.Parsed] { GitDiffEngine.split(patch).mapValues(UnifiedDiff.parse) }
            return (selected, parse(unstagedPatch), parse(stagedPatch), parse(headPatch), results,
                    Dictionary(ChangeSet.parseBatch(blobData), uniquingKeysWith: { first, _ in first }))
        }
        let headChanges = reply.head.flatMap { $0 == sha ? nil : parsed.head.mapValues(\.mappings) }
        var files: [ChangedFile] = []
        var sides: [String: ReviewSides] = [:]
        for entry in parsed.entries {
            let read = reply.files?[entry.path]
            let data = read?.kind == "regular" ? read?.data.flatMap { Data(base64Encoded: $0) } : nil
            let new = await offPool { SideText(data.map { String(decoding: $0, as: UTF8.self) } ?? "") }
            func state(_ state: FileDiff.State, _ label: String? = nil) -> FileDiff {
                FileDiff(state: state, base: sha, baseLabel: label, old: SideText(""), new: SideText(""), hunks: [])
            }
            let diff: FileDiff
            switch read?.kind ?? "" {
            case "refused": diff = state(.unreadable, "refused by the host: outside the board")
            case "unreadable": diff = state(.unreadable, "unreadable on the host")
            case "unstable": diff = state(.unstable)
            case "tooLarge": diff = state(.tooLarge)
            case "directory": diff = state(.missing)
            case "submodule": diff = state(.submodule)
            default:
                if entry.status == .renamed, entry.oldPath != nil {
                    let rename = reply.renames?[entry.path]
                    let old = rename?.old.flatMap { Data(base64Encoded: $0) }
                    let oldText = await offPool { old.map { SideText(String(decoding: $0, as: UTF8.self)) } }
                    diff = await ChangeSet.renamedDiff(old: oldText, data: data, patch: rename?.patch.flatMap { Data(base64Encoded: $0) }, base: sha, toplevel: nil)
                } else {
                    diff = await GitDiffEngine.diff(data: data, new: new, base: sha, label: base.label, patch: parsed.results[entry.path] ?? .init(), toplevel: nil)
                        ?? state(.unstable)
                }
            }
            let mode = read?.exec.map { $0 ? "100755" : "100644" }
            guard let file = ChangeSet.changed(entry, diff: diff, workingMode: mode, unstaged: parsed.unstaged[entry.path]?.mappings ?? [],
                                               staged: parsed.staged[entry.path]?.mappings ?? [], head: headChanges.map { $0[entry.path] ?? [] }, boardPath: boardPath) else { continue }
            files.append(file)
            if let read, let found = reply.sides?[entry.path],
               let review = await Self.sides(found, read: read, text: new, blobs: parsed.blobs, unstaged: parsed.unstaged[entry.path], staged: parsed.staged[entry.path],
                                             againstHead: parsed.head[entry.path]) {
                sides[entry.path] = review
            }
        }
        return (files, sides)
    }

    private enum CapturedSide {
        case read(ReviewSides.Side?)
        case omitted
    }

    private static func sides(_ found: ChangesReply.Sides, read: ChangesReply.Read, text: SideText, blobs: [String: Data], unstaged: UnifiedDiff.Parsed?,
                              staged: UnifiedDiff.Parsed?, againstHead: UnifiedDiff.Parsed?) async -> ReviewSides? {
        func side(_ listed: ChangesReply.Sides.Entry?) async -> CapturedSide {
            guard let listed else { return .read(nil) }
            guard let data = blobs[listed.oid] else { return .omitted }
            let text = await offPool { SideText(String(decoding: data, as: UTF8.self)) }
            return .read(ReviewSides.Side(text: text, mode: listed.mode, id: listed.oid))
        }
        guard case .read(let head) = await side(found.head), case .read(let index) = await side(found.index) else { return nil }
        var worktree: ReviewSides.Side?
        switch read.kind {
        case "regular":
            guard let id = read.sha else { return nil }
            worktree = ReviewSides.Side(text: text, mode: read.exec == true ? "100755" : "100644", id: id)
        case "missing": worktree = nil
        default: return nil
        }
        return ReviewSides(head: head, index: index, worktree: worktree, unstaged: unstaged ?? .init(), staged: staged ?? .init(), againstHead: againstHead ?? .init())
    }

    private static func commits(_ reply: ChangesReply, boardPath: @escaping @Sendable (String) -> String) async -> [ChangedFile] {
        let raw = bytes(reply.raw), blobData = bytes(reply.blobs), changes = bytes(reply.changes)
        let selectedPaths = reply.selected ?? [], renamePatches = reply.renamePatches ?? [:]
        return await offPool {
            var entries: [String: ChangeSet.Entry] = [:]
            for entry in ChangeSet.parseRaw(raw) { entries[entry.path] = entry }
            var blobs: [String: ChangeSet.Blob] = [:]
            for (id, data) in ChangeSet.parseBatch(blobData) {
                blobs[id] = GitDiffEngine.looksBinary(data) ? .binary : .text(SideText(String(decoding: data, as: UTF8.self)))
            }
            let mappings = GitDiffEngine.split(changes).mapValues { UnifiedDiff.parse($0).mappings }
            return selectedPaths.compactMap { entries[$0] }.map { entry in
                let known = mappings[entry.path] ?? renamePatches[entry.path].flatMap { Data(base64Encoded: $0) }.map { UnifiedDiff.parse($0).mappings }
                return ChangeSet.file(entry, blobs: blobs, mappings: known, boardPath: boardPath)
            }
        }
    }


    /// What a live tile's poll sees now (`HostFileWatch`): nil only when cancelled.
    public func stamp(_ probe: HostGitProbe) async -> HostGitStamp? {
        var request = Request(op: "stamp", boardRoot: probe.boardRoot)
        request.watch = probe.spec
        do {
            let reply: StampReply = try await call(request, retryTransport: true)
            guard reply.ok, let digest = reply.digest else { return .failure(HostFileError(code: reply.code, message: reply.message, limit: reply.limit)) }
            return .digest(digest)
        } catch is CancellationError {
            return nil
        } catch let error as HostFileError {
            return .failure(error)
        } catch {
            return .failure(.unavailable(String(describing: error)))
        }
    }

    /// Applies a Stage, Unstage, or Discard built from a listing (`ReviewPatch.stage(_:of:sides:onHost:)`
    /// and the like) on the host: there HEAD, the index, and the working tree of `file` are read
    /// again and must still be the `sides` the patch was built from, then `git apply` takes the
    /// patch on its stdin. Never retried: a lost reply is reconciled by the tile's next poll.
    public func apply(_ patch: ReviewPatch, to file: ChangedFile, sides: ReviewSides, boardRoot: String) async throws {
        guard case .host(let toplevel) = patch.checkout else { throw ChangesFailure("this patch applies on this Mac, not on \(hostName)") }
        try ReviewPatch.checkPath(file.path)
        var request = Request(op: "apply", boardRoot: boardRoot)
        request.toplevel = toplevel
        request.target = patch.target.rawValue
        request.reverse = patch.reverse
        request.patch = patch.text
        request.expect = [Expect(path: file.path, head: sides.head.map(SideIdentity.init), index: sides.index.map(SideIdentity.init),
                                 worktree: sides.worktree.map(SideIdentity.init))]
        let reply: ApplyReply = try await call(request)
        guard reply.ok else {
            switch reply.code {
            case "stale": throw ChangesFailure("\(file.boardPath) changed since the tile read it; try again")
            case "apply": throw ChangesFailure(ReviewGit.reason(reply.message ?? ""))
            case "refused": throw ChangesFailure("refusing to patch \(file.path): outside the repository")
            default: throw HostFileError(code: reply.code, message: reply.message, limit: reply.limit)
            }
        }
    }

    func call<Reply: Decodable>(_ request: some Encodable, timeout: TimeInterval = 60, retryTransport: Bool = false) async throws -> Reply {
        let output = try await files.execute(Self.program, request: JSONEncoder().encode(request), timeout: timeout, retryTransport: retryTransport, what: "host git")
        do {
            return try JSONDecoder().decode(Reply.self, from: Data(output.utf8))
        } catch {
            throw HostFileError.unavailable("invalid host git reply")
        }
    }

    private static func bytes(_ base64: String?) -> Data {
        base64.flatMap { Data(base64Encoded: $0) } ?? Data()
    }

    private struct Request: Encodable {
        var op: String
        var boardRoot: String
        var limits = Limits()
        var path: String?
        var base: Base?
        var pinned: String?
        var ref: String?
        var refSha: String?
        var spec: Spec?
        var watch: JSONValue?
        var toplevel: String?
        var target: String?
        var reverse: Bool?
        var patch: String?
        var expect: [Expect]?

        init(op: String, boardRoot: String) {
            self.op = op
            self.boardRoot = boardRoot
        }
    }

    struct Limits: Encodable {
        var file = GitDiffEngine.maxFileSize
        var total = NoteSource.maxOutput
        var reply = 3 * NoteSource.maxOutput
        var maxFiles = ChangeSet.maxFiles
        var changeRecords = GitDiffEngine.changeRecords
        var renameRecords = ChangeSet.renameRecords
    }

    private struct Base: Encodable {
        var kind: String
        var revision: String?

        init(_ base: DiffBase) {
            switch base {
            case .mergeBase: kind = "mergeBase"
            case .head: kind = "head"
            case .commit(let revision):
                kind = "commit"
                self.revision = revision
            }
        }
    }

    private struct Spec: Encodable {
        var root: String?
        var ref: String?
        var refSha: String?
        var head: String?
        var base: Base
        var baseProp: String
        var paths: [String]
    }

    private struct Expect: Encodable {
        var path: String
        var head: SideIdentity?
        var index: SideIdentity?
        var worktree: SideIdentity?
    }

    private struct SideIdentity: Encodable {
        var mode: String
        var id: String

        init(_ side: ReviewSides.Side) {
            mode = side.mode
            id = side.id
        }
    }

    private struct RefState: Decodable {
        var state: String
        var sha: String
        var merge: String?
        var worktree: String?

        var resolution: GitRefs.Resolution? {
            switch state {
            case "live": GitRefs.Resolution(worktree: worktree.map { URL(fileURLWithPath: $0, isDirectory: true) }, sha: sha, state: .live)
            case "objects": GitRefs.Resolution(worktree: nil, sha: sha, state: .objects)
            case "merged": GitRefs.Resolution(worktree: nil, sha: sha, state: .merged(merge ?? sha))
            case "missing": GitRefs.Resolution(worktree: nil, sha: sha, state: .missing)
            default: nil
            }
        }
    }

    private struct BaseReply: Decodable {
        var sha: String?
        var label: String
    }

    private struct CodeReply: Decodable {
        var ok: Bool
        var code: String?
        var message: String?
        var limit: Int?
        var watch: JSONValue?
        var baseline: String?
        var file: String?
        var ref: RefState?
        var defaultBranch: String?
        var read: Read?
        var repository: Bool?
        var base: BaseReply?
        var rel: String?
        var tree: String?
        var status: String?
        var patch: String?
        var patchTooLarge: Bool?
        var commit: Commit?

        struct Read: Decodable {
            var kind: String
            var data: String?
        }

        struct Commit: Decodable {
            var sha: String?
            var label: String
            var data: String?
        }
    }

    private struct ChangesReply: Decodable {
        var ok: Bool
        var code: String?
        var message: String?
        var limit: Int?
        var watch: JSONValue?
        var baseline: String?
        var kind: String?
        var notice: Notice?
        var branch: String?
        var top: String?
        var defaultBranch: String?
        var ref: RefState?
        var label: Label?
        var base: BaseReply?
        var head: String?
        var raw: String?
        var others: String?
        var selected: [String]?
        var boardPaths: [String: String]?
        var omitted: Int?
        var files: [String: Read]?
        var tree: String?
        var status: String?
        var patch: String?
        var patchTooLarge: Bool?
        var renames: [String: Rename]?
        var unstaged: String?
        var staged: String?
        var againstHead: String?
        var sides: [String: Sides]?
        var blobs: String?
        var baseLabel: String?
        var baseTip: String?
        var baseSha: String?
        var gone: Gone?
        var changes: String?
        var renamePatches: [String: String]?

        struct Notice: Decodable {
            var text: String?
            var missing: String?
            var remotes: [String]?
            var unrelated: Bool?
        }

        struct Label: Decodable {
            var name: String
            var branch: String?
        }

        struct Read: Decodable {
            var kind: String
            var data: String?
            var exec: Bool?
            var sha: String?
        }

        struct Rename: Decodable {
            var old: String?
            var patch: String?
        }

        struct Sides: Decodable {
            var head: Entry?
            var index: Entry?

            struct Entry: Decodable {
                var mode: String
                var oid: String
            }
        }

        struct Gone: Decodable {
            var merged: String?
        }
    }

    private struct StampReply: Decodable {
        var ok: Bool
        var code: String?
        var message: String?
        var limit: Int?
        var digest: String?
    }

    private struct ApplyReply: Decodable {
        var ok: Bool
        var code: String?
        var message: String?
        var limit: Int?
    }
}

/// What a code tile asks of its remote board's host (`HostGit.code`).
public struct HostCodeRead: Sendable, Equatable {
    public var boardRoot: String
    /// The tile's path: relative to the board root, or absolute on the host.
    public var path: String
    public var base: DiffBase
    /// `props.pinnedCommit`, which wins over `ref`.
    public var pinned: String?
    public var ref: String?
    /// The commit `ref` last resolved to, read once the branch is gone.
    public var refSha: String?

    public init(boardRoot: String, path: String, base: DiffBase, pinned: String?, ref: String?, refSha: String?) {
        self.boardRoot = boardRoot
        self.path = path
        self.base = base
        self.pinned = pinned
        self.ref = ref
        self.refSha = refSha
    }
}

/// A code tile's file as its host read it.
public struct HostCodeLoad: Sendable {
    public var document: CodeDocument
    /// The default branch the base picker names (`origin/main`).
    public var defaultBranch: String?
    /// The commit the tile's `ref` resolved to.
    public var refSha: String?
    /// What the tile polls while live; nil when nothing moves it (a pinned commit).
    public var probe: HostGitProbe?
    /// The poll's observation taken in the same host process as the bytes.
    public var baseline: HostGitStamp?

    init(read: HostCodeRead, diff: FileDiff, ref: String? = nil, readPath: String? = nil, probe: HostGitProbe? = nil, baseline: HostGitStamp? = nil) async {
        let path = read.path
        document = await offPool { CodeDocument(path: path, diff: diff, readPath: readPath, ref: ref) }
        self.probe = probe
        self.baseline = baseline
    }
}

/// A changes tile's listing as its host read it.
public struct HostChangesLoad: Sendable {
    public var set: ChangeSet
    /// The default branch the base picker names (`origin/main`).
    public var defaultBranch: String?
    /// The worktree on the host a patch of this listing applies in; nil when nothing in it can
    /// be staged or discarded (commits compared, a notice).
    public var checkout: String?
    /// What Stage, Unstage, and Discard build their patches from, by repository path; a file
    /// missing here can't be staged from this listing.
    public var sides: [String: ReviewSides] = [:]
    public var probe: HostGitProbe?
    public var baseline: HostGitStamp?

    init(set: ChangeSet) {
        self.set = set
    }
}

/// What a live remote tile polls: the host checks it again on every poll.
public struct HostGitProbe: Sendable, Equatable {
    let boardRoot: String
    let spec: JSONValue
}

/// One poll's observation: a digest of what the tile's text depends on, or why the host
/// couldn't say.
public enum HostGitStamp: Sendable, Equatable {
    case digest(String)
    case failure(HostFileError)
}

extension HostGit {
    static let program = HostProgram(HostFiles.prelude + #"""
    const crypto = require('node:crypto');
    const limits = req.limits;
    let budget = limits.total, room = limits.reply;
    let watch = null, baseline = null;
    const unsettled = 'unsettled';
    const oversized = { limit: limits.reply, message: 'the listing is too large for one host reply' };
    const empty = Buffer.alloc(0);
    const b64 = data => data == null ? null : Buffer.from(data).toString('base64');
    const sha256 = data => crypto.createHash('sha256').update(data).digest('hex');
    const gitEnv = { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_TERMINAL_PROMPT: '0', GIT_NO_LAZY_FETCH: '1' };
    // Keyed by repository path, which may be any name (`__proto__` too).
    const byName = () => Object.create(null);
    function run(dir, args, { max = 1 << 20, allowed = [0], input } = {}) {
      const r = cp.spawnSync('git', ['-c', 'core.quotepath=off', '--no-pager', '-C', dir, ...args], {
        env: gitEnv, input, maxBuffer: max, timeout: 20000, stdio: [input == null ? 'ignore' : 'pipe', 'pipe', 'pipe']
      });
      if (r.error?.code === 'ENOBUFS') return { tooLarge: true };
      if (r.error?.code === 'ENOENT') fail('unavailable', { message: 'git is unavailable' });
      if (r.error) fail('unavailable', { message: 'git failed: ' + (r.error.code || r.error.message) });
      if (!allowed.includes(r.status)) return { failed: true, status: r.status, err: r.stderr.toString('utf8') };
      return { status: r.status, out: r.stdout };
    }
    function capture(dir, args, max) {
      const fits = Math.floor(room / 4) * 3;
      const r = run(dir, args, { max: Math.min(max, fits) });
      if (r.tooLarge && fits < max) fail('too_large', oversized);
      if (r.out) room -= 4 * Math.ceil(r.out.length / 3);
      return r;
    }
    const output = r => r.out ?? empty;
    class GitFailed { constructor(r) { this.r = r; } }
    const failure = r => r.tooLarge ? 'git failed: too much output' : 'git failed: ' + (r.err.trim().split('\n')[0] || 'exit ' + r.status);
    function verify(dir, rev) {
      const r = run(dir, ['rev-parse', '--verify', '--quiet', '--end-of-options', rev + '^{commit}']);
      if (r.failed) { if (r.status === 1) return null; throw new GitFailed(r); }
      return r.out.toString('utf8').trim() || null;
    }
    const tryVerify = (dir, rev) => { try { return verify(dir, rev) || '-'; } catch { return '?'; } };
    function defaultRef(top) {
      const r = run(top, ['for-each-ref', '--format=%(refname)%09%(symref)', 'refs/remotes/origin/HEAD', 'refs/heads/main', 'refs/heads/master']);
      if (r.failed) throw new GitFailed(r);
      const refs = byName();
      for (const line of r.out.toString('utf8').split('\n')) {
        if (!line) continue;
        const [name, target = ''] = line.split('\t');
        refs[name] = target;
      }
      if (refs['refs/remotes/origin/HEAD']) return refs['refs/remotes/origin/HEAD'];
      if ('refs/heads/main' in refs) return 'refs/heads/main';
      if ('refs/heads/master' in refs) return 'refs/heads/master';
      return null;
    }
    const shortName = ref => ref.replace('refs/remotes/', '').replace('refs/heads/', '');
    const defaultBranch = top => { try { const ref = defaultRef(top); return ref ? shortName(ref) : null; } catch { return null; } };
    function resolveBase(top, base) {
      try {
        if (base.kind === 'head') { const sha = verify(top, 'HEAD'); return { sha, label: sha ? 'HEAD' : 'no commits yet' }; }
        if (base.kind === 'commit') { const sha = verify(top, base.revision); return { sha, label: sha ? base.revision : 'unknown commit ' + base.revision }; }
        const branch = defaultRef(top);
        if (!branch) return { sha: null, label: verify(top, 'HEAD') ? 'no default branch' : 'no commits yet' };
        const r = run(top, ['merge-base', branch, 'HEAD'], { allowed: [0, 1] });
        if (r.failed) {
          if (verify(top, 'HEAD')) throw new GitFailed(r);
          return { sha: null, label: 'no commits yet' };
        }
        const sha = r.out.toString('utf8').trim();
        return sha ? { sha, label: 'merge-base with ' + shortName(branch) } : { sha: null, label: 'no merge-base with ' + shortName(branch) };
      } catch (e) {
        if (e instanceof GitFailed) return { sha: null, label: failure(e.r) };
        throw e;
      }
    }
    const isDir = p => { try { return fs.statSync(p).isDirectory(); } catch { return false; } };
    function repository(dir) {
      while (!isDir(dir) && dir !== '/') dir = path.dirname(dir);
      const r = run(dir, ['rev-parse', '--path-format=absolute', '--show-toplevel', '--git-dir', '--git-common-dir']);
      if (r.failed) return null;
      const [top, gitDir, commonDir] = r.out.toString('utf8').replace(/\n$/, '').split('\n');
      return top && gitDir && commonDir ? { top, gitDir, commonDir } : null;
    }
    function branchOf(top) {
      const ref = text(top, ['symbolic-ref', '--quiet', 'HEAD']);
      return ref?.startsWith('refs/heads/') ? ref.slice(11) : null;
    }
    const remotes = dir => (text(dir, ['remote']) || '').split('\n').filter(Boolean);
    function worktreeEntries(top) {
      const entries = [];
      for (const block of (text(top, ['worktree', 'list', '--porcelain', '-z']) || '').split('\0\0')) {
        const lines = block.split('\0');
        const entry = lines.find(l => l.startsWith('worktree '))?.slice(9);
        if (entry && !lines.some(l => l.startsWith('prunable')) && real(entry)) entries.push(entry);
      }
      return entries;
    }
    function areasOf(boardRoot) {
      const lex = path.resolve(boardRoot);
      const areas = [{ lex, real: resolved(lex) }];
      const top = text(lex, ['rev-parse', '--show-toplevel']);
      if (!top) return areas;
      const place = path.relative(real(top) || top, areas[0].real);
      if (place === '..' || place.startsWith('../') || path.isAbsolute(place)) return areas;
      for (const entry of worktreeEntries(top)) {
        const area = path.join(entry, place), canonical = path.join(real(entry), place);
        if (resolved(area) === canonical && !areas.some(a => a.lex === area)) areas.push({ lex: area, real: canonical });
      }
      return areas;
    }
    const written = (area, lex) => inside(area.lex, lex) ? area.lex : inside(area.real, lex) ? area.real : null;
    const areaOf = (areas, p) => {
      const lex = path.resolve(p), res = resolved(lex);
      return areas.find(a => written(a, lex) && inside(a.real, res));
    };
    function target(requested, areas, root, reroot) {
      if (typeof requested !== 'string' || !requested || requested.includes('\0') || requested.startsWith('~')) fail('refused');
      if (!path.isAbsolute(requested)) {
        if (requested.split('/').includes('..')) fail('refused');
        return path.join(root, requested);
      }
      const lex = path.resolve(requested);
      const area = areas.find(a => written(a, lex) && lex !== written(a, lex));
      if (!area) fail('refused');
      return reroot ? path.join(root, path.relative(written(area, lex), lex)) : lex;
    }
    function readPaths(paths, areas, want, spend = false) {
      const requests = [], slots = [];
      const results = paths.map((abs, i) => {
        const area = areaOf(areas, abs);
        if (!area) return { kind: 'refused' };
        const p = resolved(abs);
        if (isDir(p)) return { kind: fs.existsSync(path.join(p, '.git')) ? 'submodule' : 'directory' };
        requests.push({ path: p, roots: [area.real], bytes: true, digest: want === 'digest', limit: limits.file, metadataLimit: false });
        slots.push(i);
        return null;
      });
      readFiles(requests, want === 'bytes' && spend ? budget : null).forEach((reply, j) => {
        const i = slots[j];
        if (reply.ok) {
          const data = want === 'bytes' ? Buffer.from(reply.data, 'base64') : null;
          if (data && spend) budget -= data.length;
          results[i] = { kind: 'regular', data, exec: reply.exec, digest: data ? sha256(data) : reply.sha256 };
        } else if (reply.code === 'unavailable') {
          fail('unavailable', { message: reply.message });
        } else {
          results[i] = { kind: { not_found: 'missing', too_large: 'tooLarge' }[reply.code] || reply.code };
        }
      });
      return results;
    }
    const same = (a, b) => a.kind === b.kind && a.digest === b.digest;
    function statusPaths(listing) {
      const records = listing.toString('utf8').split('\0'), paths = [];
      for (let i = 0; i < records.length; i++) {
        if (records[i].length < 4) continue;
        paths.push(records[i].slice(3));
        if (records[i][0] === 'R' || records[i][0] === 'C') i++;
      }
      return paths;
    }
    function stamps(paths, areas) {
      const out = paths.map(() => 'refused'), requests = [], slots = [];
      paths.forEach((p, i) => {
        const area = typeof p === 'string' && areaOf(areas, p);
        if (!area) return;
        requests.push({ path: resolved(p), roots: [area.real], bytes: false, limit: null, metadataLimit: false });
        slots.push(i);
      });
      readFiles(requests).forEach((reply, j) => { out[slots[j]] = reply.ok ? reply.stamp : reply.code; });
      return paths.map((p, i) => p + ' ' + out[i]);
    }
    function observed(spec, areas) {
      if (typeof spec?.dir !== 'string' || !areaOf(areas, spec.dir)) fail('refused');
      const parts = [];
      const where = run(spec.dir, ['rev-parse', '--path-format=absolute', '--git-dir', '--show-toplevel']);
      const [gitDir, top] = where.failed ? [] : where.out.toString('utf8').replace(/\n$/, '').split('\n');
      parts.push('top ' + (top || '-'));
      if (top) {
        if (spec.index) {
          try { const s = fs.statSync(path.join(gitDir, 'index'), { bigint: true }); parts.push('index ' + [s.dev, s.ino, s.size, s.mtimeNs, s.ctimeNs].join(':')); }
          catch { parts.push('index -'); }
        }
        for (const rev of spec.revisions || []) if (typeof rev === 'string' && !rev.includes('\0')) parts.push('rev ' + rev + ' ' + tryVerify(spec.dir, rev));
        if (spec.refs) {
          let ref;
          try { ref = defaultRef(top); } catch { ref = '?'; }
          parts.push('default ' + ref + ' ' + (ref && ref !== '?' ? tryVerify(top, ref) : '-'));
        }
        if (spec.worktrees) parts.push('worktrees ' + (text(top, ['worktree', 'list', '--porcelain', '-z']) || ''));
        if (Array.isArray(spec.status)) {
          const r = run(top, ['--literal-pathspecs', 'status', '--porcelain=v1', '-z', '--untracked-files=all', '--', ...spec.status.map(String)], { max: 64 << 20 });
          if (!r.out) parts.push('status ?');
          else {
            parts.push('status ' + r.out.toString('utf8'));
            parts.push(...stamps(statusPaths(r.out).slice(0, 2000).map(p => path.join(top, p)), areas));
          }
        }
      }
      if (Array.isArray(spec.files) && spec.files.length) parts.push(...stamps(spec.files, areas));
      return parts;
    }
    const observe = (spec, areas) => sha256(observed(spec, areas).join('\0'));
    function patches(top, sha, paths) {
      if (!paths.length) return { tree: empty, status: empty, patch: empty, tooLarge: false };
      const tree = output(capture(top, ['--literal-pathspecs', 'ls-tree', '-l', '-z', '--full-tree', sha, '--', ...paths], 64 << 20));
      const entries = byName();
      for (const record of tree.toString('utf8').split('\0')) {
        const tab = record.indexOf('\t');
        if (tab < 0) continue;
        const meta = record.slice(0, tab).split(' ').filter(Boolean);
        if (meta.length >= 4) entries[record.slice(tab + 1)] = { type: meta[1], size: Number(meta[3]) || 0 };
      }
      const diffed = paths.filter(p => !entries[p] || (entries[p].type !== 'commit' && !(entries[p].type === 'blob' && entries[p].size > limits.file)));
      const absent = paths.filter(p => !entries[p]);
      const status = absent.length
        ? output(capture(top, ['--literal-pathspecs', 'status', '--porcelain=v1', '-z', '--ignored=matching', '--untracked-files=all', '--', ...absent], 64 << 20))
        : empty;
      let patch = empty, tooLarge = false;
      if (diffed.length) {
        const r = capture(top, [...limits.changeRecords, sha, '--', ...diffed], diffed.length * 3 * limits.file);
        if (r.tooLarge) tooLarge = true;
        else patch = output(r);
      }
      return { tree, status, patch, tooLarge };
    }
    function liveRead(abs, areas) {
      const [file] = readPaths([abs], areas, 'bytes');
      if (file.kind === 'refused' || file.kind === 'unreadable') fail(file.kind);
      const read = { kind: file.kind, data: b64(file.data) };
      if (file.kind === 'tooLarge') return { read };
      const repo = repository(path.dirname(abs));
      if (!repo) return { read, repository: false };
      const found = { read, repository: true, defaultBranch: defaultBranch(repo.top) };
      if (file.kind === 'directory' || file.kind === 'submodule') return found;
      const base = resolveBase(repo.top, req.base);
      if (!base.sha) return { ...found, base };
      const rel = path.relative(real(repo.top) || repo.top, resolved(abs));
      if (!rel || rel === '..' || rel.startsWith('../')) return { read, repository: false };
      const captured = patches(repo.top, base.sha, [rel]);
      const [again] = readPaths([abs], areas, 'digest');
      if (!same(file, again)) return { read: { kind: 'moved' } };
      return { ...found, base, rel, tree: b64(captured.tree), status: b64(captured.status), patch: b64(captured.patch), patchTooLarge: captured.tooLarge };
    }
    function commitRead(abs, revision, areas) {
      const area = areas.find(a => written(a, abs) && abs !== written(a, abs));
      if (!area) fail('refused');
      const dir = written(area, abs);
      const repo = repository(dir);
      if (!repo) return { commit: { sha: null, label: 'not in a git repository' } };
      const base = resolveBase(repo.top, { kind: 'commit', revision });
      const found = { defaultBranch: defaultBranch(repo.top) };
      if (!base.sha) return { ...found, commit: { sha: null, label: base.label } };
      const name = path.join(path.relative(real(repo.top) || repo.top, resolved(dir)), path.relative(dir, abs));
      if (name === '..' || name.startsWith('../')) return { ...found, commit: { sha: null, label: 'not in a git repository' } };
      const r = run(repo.top, ['cat-file', 'blob', '--end-of-options', base.sha + ':' + name], { max: limits.file });
      return { ...found, commit: { sha: base.sha, label: revision, data: r.out ? b64(r.out) : null } };
    }
    function settled(resolve, source) {
      let now;
      try { now = resolve(); }
      catch (e) {
        if (e.code !== 'ref') throw e;
        now = e;
      }
      return JSON.stringify(now) === JSON.stringify(source);
    }
    function code() {
      const areas = areasOf(req.boardRoot);
      const board = areas[0].lex;
      const reroot = !!req.ref && !req.pinned;
      const resolve = () => reroot ? resolveSource({ kind: 'ref', root: board, ref: req.ref, sha: req.refSha }) : { root: board };
      let source;
      try { source = resolve(); }
      catch (e) {
        if (e.code === 'ref') {
          watch = { dir: board, revisions: [req.ref], refs: true, worktrees: true };
          baseline = observe(watch, areas);
          if (!settled(resolve, e)) baseline = unsettled;
        }
        throw e;
      }
      for (let attempt = 0; ; attempt++) {
        room = limits.reply;
        const abs = target(req.path, areas, source.root, reroot);
        const commit = req.pinned || source.commit || null;
        const dir = (areas.find(a => inside(a.lex, abs)) || areas[0]).lex;
        const revisions = ['HEAD', ...(reroot ? [req.ref] : []), ...(req.base.kind === 'commit' ? [req.base.revision] : [])];
        watch = req.pinned ? null : { dir: commit ? board : dir, files: commit ? [] : [abs], revisions, refs: true, index: !commit, worktrees: reroot };
        baseline = watch && observe(watch, areas);
        const now = resolve();
        if (JSON.stringify(now) !== JSON.stringify(source)) {
          if (attempt < 2) {
            source = now;
            continue;
          }
          baseline = unsettled;
        }
        const ref = reroot ? { state: source.state, sha: source.sha, merge: source.merge, worktree: source.worktree } : null;
        const reply = commit ? commitRead(abs, commit, areas) : liveRead(abs, areas);
        if (reply.read?.kind === 'moved') {
          if (attempt < 2) continue;
          reply.read = { kind: 'unstable' };
        }
        return { ok: true, file: abs, ref, ...reply };
      }
    }
    function pathspecs(paths, reviewed, area, top) {
      const specs = [];
      for (const p of paths.length ? paths : [reviewed]) {
        const abs = path.isAbsolute(p) ? path.resolve(p) : path.resolve(reviewed, p), res = resolved(abs);
        if (!written(area, abs) || !inside(area.real, res)) return p + ' is outside the board';
        if (res === top) specs.push('.');
        else if (inside(top, res)) specs.push(path.relative(top, res));
        else return p + ' is outside the repository ' + top;
      }
      return specs;
    }
    function parseRaw(listing) {
      const fields = listing.toString('utf8').split('\0'), entries = [];
      const blob = id => /^0+$/.test(id) ? null : id;
      for (let i = 0; i < fields.length;) {
        const meta = fields[i++];
        if (!meta.startsWith(':')) continue;
        const parts = meta.slice(1).split(' ');
        if (parts.length < 5) continue;
        const letter = parts[4][0], two = letter === 'R' || letter === 'C';
        if (i + (two ? 1 : 0) >= fields.length) break;
        const first = fields[i], second = two ? fields[i + 1] : null;
        i += two ? 2 : 1;
        const oldMode = parts[0] === '000000' ? null : parts[0], newMode = parts[1] === '000000' ? null : parts[1];
        const oldBlob = blob(parts[2]), newBlob = blob(parts[3]);
        if (letter === 'A' || letter === 'C') entries.push({ path: second ?? first, status: 'added', newMode, newBlob });
        else if (letter === 'D') entries.push({ path: first, status: 'deleted', oldMode, oldBlob });
        else if (letter === 'M' || letter === 'T') entries.push({ path: first, status: 'modified', oldMode, newMode, oldBlob, newBlob });
        else if (letter === 'R') entries.push({ path: second ?? first, oldPath: first, status: 'renamed', oldMode, newMode, oldBlob, newBlob });
      }
      return entries;
    }
    const byPath = (a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0;
    function boardPaths(top, entries, board) {
      const names = byName(), topReal = real(top) || top;
      for (const p of entries.flatMap(e => e.oldPath ? [e.path, e.oldPath] : [e.path])) {
        const abs = path.join(topReal, p);
        names[p] = abs !== board.real && inside(board.real, abs) ? path.relative(board.real, abs) : path.join(top, p);
      }
      return names;
    }
    function sidesOf(top, head, paths) {
      const sides = byName();
      for (const p of paths) sides[p] = { head: null, index: null };
      if (!paths.length) return { sides, blobs: empty };
      const index = output(run(top, ['--literal-pathspecs', 'ls-files', '-s', '-z', '--', ...paths], { max: 64 << 20 }));
      for (const record of index.toString('utf8').split('\0')) {
        const tab = record.indexOf('\t');
        if (tab < 0) continue;
        const [mode, oid] = record.slice(0, tab).split(' '), p = record.slice(tab + 1);
        if (sides[p] && !sides[p].index) sides[p].index = { mode, oid };
      }
      if (head) {
        const tree = output(run(top, ['--literal-pathspecs', 'ls-tree', '-z', '--full-tree', head, '--', ...paths], { max: 64 << 20 }));
        for (const record of tree.toString('utf8').split('\0')) {
          const tab = record.indexOf('\t');
          if (tab < 0) continue;
          const [mode, , oid] = record.slice(0, tab).split(' '), p = record.slice(tab + 1);
          if (sides[p]) sides[p].head = { mode, oid };
        }
      }
      const ids = [...new Set(Object.values(sides).flatMap(s => [s.head?.oid, s.index?.oid]).filter(Boolean))];
      return { sides, blobs: blobsOf(top, ids) };
    }
    function blobsOf(top, ids) {
      if (!ids.length) return empty;
      const checked = output(run(top, ['cat-file', '--batch-check'], { input: ids.join('\n') + '\n', max: 64 << 20 }));
      const wanted = [];
      let total = 0;
      for (const line of checked.toString('utf8').split('\n')) {
        const [id, type, size] = line.split(' ');
        if (type !== 'blob' || Number(size) > limits.file || Number(size) > budget) continue;
        wanted.push(id);
        budget -= Number(size);
        total += Number(size);
      }
      if (!wanted.length) return empty;
      return output(run(top, ['cat-file', '--batch'], { input: wanted.join('\n') + '\n', max: total + 128 * wanted.length }));
    }
    function worktreeListing(areas, reviewed, spec, extra) {
      const area = areaOf(areas, reviewed);
      if (!area) fail('refused');
      const repo = repository(reviewed);
      if (!repo) return { ok: true, kind: 'worktree', notice: { text: 'not in a git repository' }, ...extra };
      const own = repository(areas[0].lex);
      const label = own && own.gitDir !== repo.gitDir ? { name: path.basename(repo.top), branch: branchOf(repo.top) } : null;
      const top = real(repo.top) || repo.top;
      const specs = pathspecs(spec.paths, reviewed, area, top);
      if (typeof specs === 'string') return { ok: true, kind: 'worktree', notice: { text: specs }, label, ...extra };
      const revisions = ['HEAD', ...(spec.ref ? [spec.ref] : []), ...(spec.base.kind === 'commit' ? [spec.base.revision] : [])];
      watch = { dir: reviewed, revisions, refs: spec.base.kind === 'mergeBase', index: true, worktrees: !!spec.ref, status: specs };
      const common = { ok: true, kind: 'worktree', top: repo.top, label, branch: branchOf(repo.top), defaultBranch: defaultBranch(repo.top), ...extra };
      const absOf = p => path.join(repo.top, p);
      for (let attempt = 0; ; attempt++) {
        budget = limits.total;
        room = limits.reply;
        watch.files = [];
        const before = observed(watch, areas);
        baseline = sha256(before.join('\0'));
        const base = resolveBase(repo.top, spec.base);
        if (!base.sha) return { ...common, base, notice: { text: base.label } };
        let head = base.sha;
        if (spec.base.kind !== 'head') { try { head = verify(repo.top, 'HEAD'); } catch { head = null; } }
        const raw = capture(repo.top, ['--literal-pathspecs', 'diff', '--raw', '-z', '-M', '--no-color', '--no-ext-diff', '--no-textconv', base.sha, '--', ...specs], 64 << 20);
        if (!raw.out) return { ...common, base, head, notice: { text: failure(raw) } };
        const others = capture(repo.top, ['--literal-pathspecs', 'ls-files', '-z', '--others', '--exclude-standard', '--', ...specs], 64 << 20);
        if (!others.out) return { ...common, base, head, notice: { text: failure(others) } };
        const entries = parseRaw(raw.out);
        const listed = new Set(entries.map(e => e.path));
        for (const p of others.out.toString('utf8').split('\0')) if (p && !listed.has(p)) entries.push({ path: p, status: 'added' });
        entries.sort(byPath);
        const selected = entries.slice(0, limits.maxFiles);
        const listing = { ...common, base, head, raw: b64(raw.out), others: b64(others.out), selected: selected.map(e => e.path), omitted: entries.length - selected.length,
          boardPaths: boardPaths(repo.top, selected, areas[0]) };
        if (!selected.length) return listing;
        watch.files = selected.map(e => absOf(e.path));
        baseline = sha256([...before, ...stamps(watch.files, areas)].join('\0'));
        const reads = readPaths(selected.map(e => absOf(e.path)), areas, 'bytes', true);
        const refused = new Set(selected.filter((e, i) => reads[i].kind === 'refused' || reads[i].kind === 'unreadable'
          || (e.oldPath && !areaOf(areas, absOf(e.oldPath)))).map(e => e.path));
        const kept = selected.filter(e => !refused.has(e.path));
        const renamed = kept.filter(e => e.status === 'renamed' && e.oldPath);
        const captured = patches(repo.top, base.sha, kept.filter(e => !renamed.includes(e)).map(e => e.path));
        const renames = byName();
        for (const e of renamed) {
          const old = capture(repo.top, ['cat-file', 'blob', '--end-of-options', base.sha + ':' + e.oldPath], limits.file);
          const patch = capture(repo.top, [...limits.renameRecords, base.sha, '--', e.oldPath, e.path], 3 * limits.file);
          renames[e.path] = { old: b64(old.out), patch: b64(patch.out) };
        }
        const paths = kept.map(e => e.path);
        const diff = against => paths.length ? output(capture(repo.top, [...limits.changeRecords, ...against, '--', ...paths], 64 << 20)) : empty;
        const unstaged = diff([]), staged = head ? diff(['--cached']) : empty, againstHead = head ? diff([head]) : empty;
        const sides = sidesOf(repo.top, head, paths);
        const checked = selected.flatMap((e, i) => refused.has(e.path) || reads[i].kind === 'tooLarge' ? [] : [i]);
        const again = readPaths(checked.map(i => absOf(selected[i].path)), areas, 'digest');
        const moved = new Set(checked.filter((i, j) => !same(reads[i], again[j])).map(i => selected[i].path));
        if (moved.size && attempt < 2) continue;
        const files = byName();
        selected.forEach((e, i) => {
          const r = refused.has(e.path) ? { kind: reads[i].kind === 'unreadable' ? 'unreadable' : 'refused' } : moved.has(e.path) ? { kind: 'unstable' } : reads[i];
          files[e.path] = { kind: r.kind, data: b64(r.data), exec: r.exec ?? null, sha: r.digest ?? null };
        });
        return {
          ...listing, files, tree: b64(captured.tree), status: b64(captured.status), patch: b64(captured.patch), patchTooLarge: captured.tooLarge, renames,
          unstaged: b64(unstaged), staged: b64(staged), againstHead: b64(againstHead), sides: sides.sides, blobs: b64(sides.blobs)
        };
      }
    }
    function commitsListing(areas, headRevision, headName, spec, gone, extra) {
      const common = { ok: true, kind: 'commits', branch: headName, ...extra };
      let reviewed = areas[0].lex;
      if (spec.root) {
        const p = path.resolve(reviewed, spec.root);
        if (!areaOf(areas, p)) return { ...common, notice: { text: spec.root + " is not a worktree of this board's repository" } };
        reviewed = p;
      }
      const repo = repository(reviewed);
      if (!repo) return { ...common, notice: { text: 'not in a git repository' } };
      const top = repo.top;
      const specs = pathspecs(spec.paths, reviewed, areaOf(areas, reviewed) || areas[0], real(top) || top);
      if (typeof specs === 'string') return { ...common, notice: { text: specs } };
      const revisions = [spec.ref || headRevision, ...(spec.base.kind === 'commit' || (spec.base.kind === 'head' && spec.head) ? [spec.baseProp] : [])];
      watch = { dir: reviewed, revisions, refs: spec.base.kind === 'mergeBase' || !!gone, worktrees: !!spec.ref };
      baseline = observe(watch, areas);
      const refusal = (notice, label = spec.baseProp) => ({ ...common, notice, baseLabel: label });
      let headSha;
      try { headSha = verify(top, headRevision); } catch (e) { return refusal({ text: failure(e.r) }); }
      if (!headSha) return refusal({ missing: headName, remotes: remotes(top) });
      let label = spec.baseProp, tip;
      if (spec.base.kind === 'mergeBase') {
        let branch = null;
        try { branch = defaultRef(top); } catch {}
        if (!branch) return refusal({ text: 'no default branch' });
        label = 'merge-base with ' + shortName(branch);
        try { tip = verify(top, branch); } catch (e) { return refusal({ text: failure(e.r) }, label); }
        if (!tip) return refusal({ text: 'no default branch' }, label);
      } else if (spec.base.kind === 'head' && !spec.head) {
        tip = headSha;
      } else {
        try { tip = verify(top, spec.baseProp); } catch (e) { return refusal({ text: failure(e.r) }); }
        if (!tip) return refusal({ missing: spec.baseProp, remotes: remotes(top) });
      }
      const mergeBase = t => {
        const r = run(top, ['merge-base', t, headSha], { allowed: [0, 1] });
        if (r.failed) throw new GitFailed(r);
        return r.out.toString('utf8').trim();
      };
      let base;
      try {
        base = mergeBase(tip);
        if (gone?.merged && base === headSha && gone.merged !== headSha) {
          let parent = null;
          try { parent = verify(top, gone.merged + '^1'); } catch {}
          if (parent) {
            tip = parent;
            base = mergeBase(parent);
          }
        }
      } catch (e) {
        if (e instanceof GitFailed) return refusal({ text: failure(e.r) }, label);
        throw e;
      }
      if (!base) return refusal({ unrelated: true }, label);
      const listing = { ...common, top, head: headSha, baseLabel: label, baseTip: tip, baseSha: base, gone };
      const raw = capture(top, ['--literal-pathspecs', 'diff', '--raw', '-z', '-M', '--no-abbrev', '--no-color', '--no-ext-diff', '--no-textconv', base, headSha, '--', ...specs], 64 << 20);
      if (!raw.out) return { ...listing, notice: { text: failure(raw) } };
      const entries = parseRaw(raw.out).sort(byPath);
      const selected = entries.slice(0, limits.maxFiles);
      const ids = [...new Set(selected.flatMap(e => [[e.oldBlob, e.oldMode], [e.newBlob, e.newMode]]).filter(([id, mode]) => id && mode !== '160000').map(([id]) => id))].sort();
      const samePath = selected.filter(e => e.status === 'modified' && e.oldBlob !== e.newBlob).map(e => e.path);
      const changes = samePath.length ? output(capture(top, [...limits.changeRecords, base, headSha, '--', ...samePath], 64 << 20)) : empty;
      const renamePatches = byName();
      for (const e of selected) {
        if (e.status !== 'renamed' || !e.oldBlob || !e.newBlob || e.oldBlob === e.newBlob) continue;
        const r = capture(top, [...limits.changeRecords, e.oldBlob, e.newBlob], 3 * limits.file);
        if (r.out) renamePatches[e.path] = b64(r.out);
      }
      return { ...listing, raw: b64(raw.out), selected: selected.map(e => e.path), omitted: entries.length - selected.length, boardPaths: boardPaths(top, selected, areas[0]),
        blobs: b64(blobsOf(top, ids)), changes: b64(changes), renamePatches };
    }
    function changes() {
      const areas = areasOf(req.boardRoot);
      const board = areas[0].lex;
      const spec = req.spec;
      if (spec.ref) {
        const resolve = () => resolveSource({ kind: 'ref', root: board, ref: spec.ref, sha: spec.refSha });
        const refWatch = { dir: board, revisions: [spec.ref], refs: true, worktrees: true };
        let source;
        try { source = resolve(); }
        catch (e) {
          if (e.code !== 'ref') throw e;
          watch = refWatch;
          baseline = observe(watch, areas);
          if (!settled(resolve, e)) baseline = unsettled;
          if (e.message === 'not in a git repository') return { ok: true, kind: 'notice', notice: { text: e.message }, branch: spec.ref };
          return { ok: true, kind: 'notice', notice: { missing: spec.ref, remotes: remotes(board) }, branch: spec.ref };
        }
        const ref = { state: source.state, sha: source.sha, merge: source.merge };
        try {
          if (source.state === 'live') {
            const own = repository(board), live = repository(source.root);
            return worktreeListing(areasOf(req.boardRoot), own && live && own.gitDir === live.gitDir ? board : source.root, spec, { ref });
          }
          const gone = source.state === 'merged' ? { merged: source.merge } : source.state === 'missing' ? {} : null;
          return commitsListing(areas, source.sha, spec.ref, spec, gone, { ref });
        } finally {
          if (!settled(resolve, source)) {
            watch ??= refWatch;
            baseline = unsettled;
          }
        }
      }
      if (spec.head) return commitsListing(areas, spec.head, spec.head, spec, null, {});
      if (!spec.root) return worktreeListing(areas, board, spec, {});
      const reviewed = path.resolve(board, spec.root);
      if (!areaOf(areas, reviewed)) return { ok: true, kind: 'notice', notice: { text: spec.root + " is not a worktree of this board's repository" } };
      return worktreeListing(areas, reviewed, spec, {});
    }
    function unquote(text) {
      const chars = [...text], bytes = [];
      for (let i = 1; i < chars.length; i++) {
        const c = chars[i];
        if (c === '"') return { value: Buffer.from(bytes).toString('utf8'), end: chars.slice(0, i + 1).join('').length };
        if (c !== '\\') { bytes.push(...Buffer.from(c, 'utf8')); continue; }
        const e = chars[++i];
        if (/[0-7]/.test(e)) { bytes.push(parseInt(chars.slice(i, i + 3).join(''), 8) & 255); i += 2; continue; }
        bytes.push({ a: 7, b: 8, t: 9, n: 10, v: 11, f: 12, r: 13 }[e] ?? e.charCodeAt(0));
      }
      return null;
    }
    function patchPaths(patch) {
      const names = new Set();
      let header = false;
      for (const line of patch.split('\n')) {
        if (line.startsWith('diff --git ')) {
          header = true;
          const rest = line.slice(11);
          let name;
          if (rest.startsWith('"')) name = unquote(rest)?.value;
          else {
            const half = (rest.length - 5) / 2;
            name = 'a/' + rest.slice(2, 2 + half);
            if (rest !== name + ' b/' + name.slice(2)) fail('refused');
          }
          if (!name?.startsWith('a/')) fail('refused');
          names.add(name.slice(2));
        } else if (line.startsWith('@@')) {
          header = false;
        } else if (header) {
          if (line.startsWith('rename ') || line.startsWith('copy ')) fail('refused');
          if (line.startsWith('--- ') || line.startsWith('+++ ')) {
            const rest = line.slice(4);
            if (rest === '/dev/null') continue;
            const name = rest.startsWith('"') ? unquote(rest)?.value : rest;
            if (!name || !(name.startsWith('a/') || name.startsWith('b/'))) fail('refused');
            names.add(name.slice(2));
          }
        }
      }
      return [...names];
    }
    function apply() {
      const areas = areasOf(req.boardRoot);
      const boardTop = text(areas[0].lex, ['rev-parse', '--show-toplevel']);
      const top = typeof req.toplevel === 'string' ? real(req.toplevel) : null;
      if (!boardTop || !top || !worktreeEntries(boardTop).some(e => real(e) === top)) fail('refused');
      const named = patchPaths(String(req.patch));
      const expected = new Map((Array.isArray(req.expect) ? req.expect : []).map(e => [String(e.path), e]));
      if (!named.length || named.some(p => !expected.has(p))) fail('refused');
      const files = named.map(p => {
        const parts = p.split('/');
        if (p.startsWith('/') || p.includes('\0') || parts.includes('..') || parts.includes('.git') || parts.includes('')) fail('refused');
        const area = areaOf(areas, path.join(top, p));
        if (!area) fail('refused');
        return { path: p, area };
      });
      const heads = byName(), indexed = byName();
      for (const record of output(run(top, ['--literal-pathspecs', 'ls-tree', '-z', '--full-tree', 'HEAD', '--', ...named], { max: 64 << 20 })).toString('utf8').split('\0')) {
        const tab = record.indexOf('\t');
        if (tab < 0) continue;
        const [mode, , id] = record.slice(0, tab).split(' ');
        heads[record.slice(tab + 1)] = { mode, id };
      }
      for (const record of output(run(top, ['--literal-pathspecs', 'ls-files', '-s', '-z', '--', ...named], { max: 64 << 20 })).toString('utf8').split('\0')) {
        const tab = record.indexOf('\t');
        if (tab < 0 || record.slice(tab + 1) in indexed) continue;
        const [mode, id] = record.slice(0, tab).split(' ');
        indexed[record.slice(tab + 1)] = { mode, id };
      }
      const sameSide = (side, expected) => side == null ? expected == null : expected != null && side.mode === expected.mode && side.id === expected.id;
      const reads = readFiles(files.map(f => ({ path: path.join(top, f.path), roots: [f.area.real], bytes: true, digest: true, limit: limits.file, metadataLimit: false })));
      files.forEach((f, i) => {
        const read = reads[i], e = expected.get(f.path);
        if (read.code === 'refused') fail('refused');
        if (!read.ok && read.code !== 'not_found') fail('stale', { path: f.path });
        const worktree = read.ok ? { mode: read.exec ? '100755' : '100644', id: read.sha256 } : null;
        if (!sameSide(heads[f.path], e.head) || !sameSide(indexed[f.path], e.index) || !sameSide(worktree, e.worktree)) fail('stale', { path: f.path });
      });
      const r = run(top, ['apply', '--whitespace=nowarn', ...(req.target === 'index' ? ['--cached'] : []), ...(req.reverse ? ['-R'] : []), '-'], { input: Buffer.from(String(req.patch), 'utf8') });
      if (r.failed) fail('apply', { message: r.err });
      if (r.tooLarge) fail('apply', { message: 'git apply printed too much' });
      return { ok: true };
    }
    function placeFiles() {
      const areas = areasOf(req.boardRoot);
      const configs = Array.isArray(req.configs) ? req.configs : [];
      const places = (Array.isArray(req.files) ? req.files : []).map(p => {
        if (typeof p !== 'string' || !path.isAbsolute(p) || p.includes('\0')) return { refused: true };
        const area = areaOf(areas, p);
        if (!area) return { refused: true };
        const file = resolved(path.resolve(p));
        const placed = { file, own: area === areas[0], checkout: area.real };
        const config = configs.find(c => c.extensions.includes(path.extname(file).slice(1).toLowerCase()));
        if (!config) return placed;
        for (let dir = path.dirname(file); inside(area.real, dir); dir = path.dirname(dir)) {
          if (config.markers.some(m => fs.existsSync(path.join(dir, m)))) return { ...placed, language: config.language, project: dir };
          if (dir === area.real) break;
        }
        return { ...placed, language: config.language, project: area.real };
      });
      return { ok: true, root: areas[0].real, places };
    }
    function readDocuments() {
      const areasByRoot = new Map();
      const areasFor = root => {
        if (!areasByRoot.has(root)) areasByRoot.set(root, areasOf(root));
        return areasByRoot.get(root);
      };
      const asked = Array.isArray(req.documents) ? req.documents : [];
      const requests = [], slots = [];
      const documents = asked.map((d, i) => {
        const named = typeof d?.path === 'string' && path.isAbsolute(d.path) && !d.path.includes('\0') && typeof d.boardRoot === 'string';
        const area = named && areaOf(areasFor(d.boardRoot), d.path);
        if (!area) return { kind: 'refused' };
        requests.push({ path: resolved(path.resolve(d.path)), roots: [area.real], bytes: true, stamp: d.stamp, limit: limits.file, metadataLimit: false });
        slots.push(i);
        return null;
      });
      readFiles(requests, limits.total).forEach((r, j) => {
        const i = slots[j];
        if (r.ok) documents[i] = r.stamp === asked[i].stamp ? { kind: 'unchanged' } : { kind: 'text', stamp: r.stamp, data: r.data };
        else if (r.code === 'unavailable') fail('unavailable', { message: r.message });
        else documents[i] = { kind: { not_found: 'missing', too_large: 'tooLarge' }[r.code] || r.code };
      });
      return { ok: true, documents };
    }
    function scopeOf(areas) {
      const scope = typeof req.scope === 'string' && path.isAbsolute(req.scope) && !req.scope.includes('\0') ? path.resolve(req.scope) : null;
      if (!scope || !areaOf(areas, scope)) fail('refused');
      return scope;
    }
    function listFiles() {
      const scope = scopeOf(areasOf(req.boardRoot));
      const r = run(scope, ['ls-files', '--cached', '--others', '--exclude-standard', '--deduplicate', '-z'], { max: 64 << 20 });
      if (r.failed) fail('unavailable', { message: r.err || 'git ls-files failed' });
      if (r.tooLarge) fail('too_large', { limit: 64 << 20 });
      return { ok: true, paths: r.out.toString('utf8').split('\0').filter(Boolean).slice(0, req.limit) };
    }
    function grepFiles() {
      const scope = scopeOf(areasOf(req.boardRoot));
      if (typeof req.pattern !== 'string' || !req.pattern || req.pattern.includes('\0')) fail('refused');
      const declared = req.mode === 'declared';
      const args = declared ? ['grep', '-l', '-I', '-E', '-e', req.pattern] : ['grep', '-n', '-I', '-w', '-F', '-e', req.pattern];
      const r = run(scope, args, { max: \#(NoteSource.maxOutput), allowed: [0, 1] });
      if (r.failed) fail('unavailable', { message: r.err || 'git grep failed' });
      if (r.tooLarge) fail('too_large', { limit: \#(NoteSource.maxOutput) });
      const lines = r.out.toString('utf8').split('\n').filter(Boolean);
      if (declared) return { ok: true, paths: lines.slice(0, req.limit) };
      const looks = new RegExp('(^|[^\\p{L}\\p{M}\\p{Nd}\\p{Pc}.$])' + req.pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*[(<=:]', 'u');
      const order = [], seen = new Set(), named = new Set();
      for (const line of lines) {
        const first = line.indexOf(':'), second = first < 0 ? -1 : line.indexOf(':', first + 1);
        if (second < 0) continue;
        const file = line.slice(0, first);
        if (!seen.has(file)) { seen.add(file); order.push(file); }
        if (looks.test(line.slice(second + 1))) named.add(file);
      }
      return { ok: true, paths: [...order.filter(f => named.has(f)), ...order.filter(f => !named.has(f))].slice(0, req.limit) };
    }
    function loginValues(values) {
      const marker = '__CANVAS_VALUE__', end = '__CANVAS_END__';
      const script = values.map(v => "printf '\\n" + marker + "%s" + end + "' \"" + v + "\"").join('; ');
      return new Promise(resolve => {
        let output = '', settled = false, exited = false, closed = false, child = null, timer = null;
        const finish = kill => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          if (kill && child?.pid) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }
          child?.stdout?.destroy();
          child?.unref();
          resolve(output.split('\n' + marker).slice(1).map(answer => {
            const at = answer.indexOf(end);
            return at < 0 ? '' : answer.slice(0, at).trim();
          }));
        };
        timer = setTimeout(() => { output = ''; finish(true); }, 10000);
        try {
          child = cp.spawn(process.env.SHELL || '/bin/sh', ['-lc', script], { detached: true, stdio: ['ignore', 'pipe', 'ignore'] });
        } catch {
          return finish(false);
        }
        child.stdout.setEncoding('utf8');
        child.stdout.on('data', chunk => { output += chunk; });
        child.stdout.on('close', () => { closed = true; if (exited) finish(false); });
        child.on('error', () => { output = ''; finish(true); });
        child.on('exit', () => {
          exited = true;
          if (closed) finish(false);
          else setTimeout(() => finish(true), 100);
        });
      });
    }
    function findServer() {
      const executable = p => {
        if (typeof p !== 'string' || !p.startsWith('/')) return null;
        try { fs.accessSync(p, fs.constants.X_OK); return fs.statSync(p).isDirectory() ? null : p; } catch { return null; }
      };
      if (typeof req.command !== 'string' || !req.command || !Array.isArray(req.probes) || !Array.isArray(req.directories)) fail('refused');
      if (req.command.startsWith('/')) return { ok: true, path: executable(req.command), searchPath: process.env.PATH || null };
      const home = process.env.HOME || '';
      const probes = req.probes.map(String);
      return loginValues([...probes, '$PATH']).then(answers => {
        const answer = i => answers[i] || '';
        const directories = req.directories.map(d => (String(d).startsWith('~/') ? home + String(d).slice(1) : String(d)) + '/' + req.command);
        const candidates = [answer(0), answer(1), ...directories, ...probes.slice(2).map((_, i) => answer(i + 2))];
        return { ok: true, path: candidates.map(executable).find(Boolean) || null, searchPath: answer(probes.length) || process.env.PATH || null };
      });
    }
    function reapServer() {
      const pid = req.pid;
      if (!Number.isInteger(pid) || pid <= 1 || typeof req.binary !== 'string' || !req.binary.startsWith('/')) fail('refused');
      const runs = () => {
        const r = cp.spawnSync('ps', ['-ww', '-o', 'args=', '-p', String(pid)], { encoding: 'utf8', timeout: 5000 });
        return r.status === 0 && (' ' + r.stdout.trim() + ' ').includes(' ' + req.binary + ' ');
      };
      for (const signal of ['SIGTERM', 'SIGKILL']) {
        if (!runs()) return { ok: true, alive: false };
        try { process.kill(pid, signal); } catch {}
        for (let i = 0; i < 10 && runs(); i++) cp.spawnSync('sleep', ['0.1']);
      }
      return { ok: true, alive: runs() };
    }
    const operations = {
      code, changes, apply, stamp: () => ({ ok: true, digest: observe(req.watch, areasOf(req.boardRoot)) }),
      place: placeFiles, documents: readDocuments, list: listFiles, grep: grepFiles, server: findServer, reap: reapServer
    };
    (async () => {
      let reply;
      try {
        if (!operations[req.op]) fail('unavailable', { message: 'unknown host git operation ' + req.op });
        reply = await operations[req.op]();
      } catch (e) {
        const failed = !(e instanceof Error) && !(e instanceof GitFailed) && typeof e?.code === 'string';
        const message = e instanceof GitFailed ? failure(e.r) : typeof e?.message === 'string' ? e.message : failed ? undefined : String(e);
        reply = failed ? { ok: false, code: e.code, message, path: e.path, limit: e.limit } : { ok: false, code: 'unavailable', message };
      }
      reply.watch = watch;
      reply.baseline = baseline;
      let json = JSON.stringify(reply);
      if (json.length > limits.reply) json = JSON.stringify({ ok: false, code: 'too_large', ...oversized, watch, baseline });
      process.stdout.write(json);
    })();
    """#)
}
