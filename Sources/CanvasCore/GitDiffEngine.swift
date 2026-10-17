import CryptoKit
import Foundation

/// What a code tile diffs against (`CodeProps.diffBase`).
public enum DiffBase: Hashable, Sendable {
    /// Merge-base of HEAD with the default branch (origin/HEAD, else main, else master).
    case mergeBase
    case head
    case commit(String)

    public init(prop: String?) {
        switch prop {
        case nil, "merge-base": self = .mergeBase
        case "head", "HEAD": self = .head
        case let other?: self = .commit(other)
        }
    }

    /// How mention context names the base: `merge-base`, `HEAD`, or `commit`.
    public var name: String {
        switch self {
        case .mergeBase: "merge-base"
        case .head: "HEAD"
        case .commit: "commit"
        }
    }
}

extension Notification.Name {
    /// Posted (object: the repository's top-level path) when a resolved diff base moved, e.g.
    /// after a commit, checkout, rebase, or fetch, or when the index changed whether a new file
    /// is tracked (`git add`). Live code tiles reload on it.
    public static let gitDiffBaseChanged = Notification.Name("canvas.gitDiffBaseChanged")
    /// Posted (object: the top-level path of a repository a live tile holds) when HEAD, a ref, or
    /// a worktree of the repository moved, whether or not any diff base did: branch-anchored
    /// tiles re-resolve their ref on it (a worktree gone, a branch merged or deleted).
    public static let gitRefsMoved = Notification.Name("canvas.gitRefsMoved")
}

/// Git diffs for code tiles (docs/design.md, Code/diff and Performance):
///  - repositories that live tiles hold (`retain`) keep their resolved diff bases and a debounced
///    FSEvents stream on the git directory that re-resolves them when HEAD or refs move, and
///    retires cached diffs of new files when the index moves; with no holder the record and its
///    stream are dropped
///  - requests for the same repository and base that arrive together share one `git ls-tree`
///    and one `git diff`
///  - results are cached by (base SHA, content hash), so an unchanged file never runs git; a new
///    file's entry also holds the index it was read against, as git status told it apart
///  - the file is read once, diffed, and read again: a patch that doesn't describe the captured
///    text is retried, never reconstructed
///  - all git goes through `GitRunner.shared` (at most two processes app-wide)
public actor GitDiffEngine {
    public static let shared = GitDiffEngine()

    /// Files larger than this on either side render as a notice instead of a diff.
    public static let maxFileSize = 4 << 20

    /// A base commit and how it was chosen (`merge-base with main`), or no commit and why not
    /// (`no commits yet`, `no default branch`, `git failed: …` when git itself couldn't answer).
    public struct ResolvedBase: Equatable, Sendable {
        public var sha: String?
        public var label: String

        static let mergeBasePrefix = "merge-base with "

        /// The branch a merge-base label was taken with: `origin/main` for `merge-base with
        /// origin/main`; nil for any other label.
        public static func mergeBaseBranch(_ label: String) -> String? {
            label.hasPrefix(mergeBasePrefix) ? String(label.dropFirst(mergeBasePrefix.count)) : nil
        }
    }

    private final class Repository {
        let toplevel: URL
        /// The worktree's own git directory, whose `index` says what is tracked.
        let gitDir: String
        let watchedDirectories: [String]
        var bases: [DiffBase: ResolvedBase] = [:]
        var watcher: FileEventStream?
        var holders = 0

        init(toplevel: URL, gitDir: String, commonDir: String) {
            self.toplevel = toplevel
            self.gitDir = gitDir
            self.watchedDirectories = Array(Set([gitDir, commonDir]))
        }
    }

    private struct CacheKey: Hashable {
        var toplevel: String
        var path: String
        var base: String
        var content: Data
    }

    /// A cached diff, and for a file the base lacks (added, or ignored) the index it was read
    /// against: whether git tracks the file isn't in the key, so a changed index retires it.
    private struct Cached {
        var diff: FileDiff
        var index: String?
    }

    private struct BatchKey: Hashable {
        var toplevel: String
        var base: String
    }

    /// What `git ls-tree -l` says the base has at a path.
    enum BaseEntry: Equatable, Sendable {
        case absent
        case blob(size: Int)
        case gitlink
        case other
    }

    struct PatchResult: Sendable {
        var patch = Data()
        var entry = BaseEntry.absent
        var tooLarge = false
        /// `git status --porcelain` code of a path the base lacks: `??` untracked, `!!` ignored.
        var status: String?
    }

    private struct Request {
        var path: String
        var continuation: CheckedContinuation<PatchResult, Never>
    }

    private let watchesRepositories: Bool
    /// Held repositories by top-level path, and which directories lie in them.
    private var repositories: [String: Repository] = [:]
    private var repositoryOfDirectory: [String: String] = [:]
    private var cache: [CacheKey: Cached] = [:]
    private var cacheOrder: [CacheKey] = []
    private let cacheLimit = 64
    private var batches: [BatchKey: [Request]] = [:]

    public init(watchesRepositories: Bool = true) {
        self.watchesRepositories = watchesRepositories
    }

    /// Number of `git diff` batches run so far; lets tests observe cache hits.
    public private(set) var diffRuns = 0

    /// Repositories with a live FSEvents stream.
    var watchedRepositoryCount: Int { repositories.values.filter { $0.watcher != nil }.count }

    // MARK: Holding repositories

    /// A live tile showing `file` holds its repository: bases stay resolved and are re-resolved
    /// (with `.gitDiffBaseChanged`) when HEAD or refs move. Returns the top-level path to pass
    /// to `release`, or nil outside git.
    public func retain(containing file: URL) async -> String? {
        guard let repository = await repository(containing: file) else { return nil }
        let key = repository.toplevel.path
        let held = repositories[key] ?? repository
        repositories[key] = held
        repositoryOfDirectory[Self.existingAncestor(of: file.deletingLastPathComponent()).path] = key
        held.holders += 1
        if watchesRepositories, held.watcher == nil { watch(held) }
        return key
    }

    /// Drop one hold; the last one stops the stream and forgets the repository's bases.
    public func release(_ toplevel: String) {
        guard let repository = repositories[toplevel] else { return }
        repository.holders -= 1
        guard repository.holders <= 0 else { return }
        repository.watcher = nil
        repositories.removeValue(forKey: toplevel)
        repositoryOfDirectory = repositoryOfDirectory.filter { $0.value != toplevel }
    }

    // MARK: Diff

    /// `held`: the top level of a repository the caller holds and knows `file` lies in (a changes
    /// tile's files, as git listed them), so no git runs to find it.
    public func diff(file: URL, base: DiffBase, held: String? = nil) async -> FileDiff {
        for _ in 0..<3 {
            if let diff = await attempt(file: file, base: base, held: held) { return diff }
        }
        return FileDiff(state: .unstable, base: nil, baseLabel: nil, old: SideText(""), new: SideText(""), hunks: [])
    }

    /// One read–diff–verify pass; nil when the file changed underneath it.
    private func attempt(file: URL, base: DiffBase, held: String?) async -> FileDiff? {
        let content = await offPool { Self.read(file) }
        if content.tooLarge { return FileDiff(state: .tooLarge, base: nil, baseLabel: nil, old: SideText(""), new: SideText(""), hunks: []) }
        let data = content.data
        let new = await offPool { SideText(data.map { String(decoding: $0, as: UTF8.self) } ?? "") }
        var found = held.flatMap { repositories[$0] }
        if found == nil { found = await repository(containing: file) }
        guard let repository = found else {
            let state: FileDiff.State = content.isDirectory ? .missing : data == nil ? .missing : .notRepository
            return FileDiff(state: state, base: nil, baseLabel: nil, old: SideText(""), new: new, hunks: [])
        }
        let toplevel = repository.toplevel.path
        func result(_ state: FileDiff.State, base: String?, label: String?, old: SideText = SideText(""), new: SideText = SideText(""), hunks: [DiffHunk] = []) -> FileDiff {
            FileDiff(state: state, base: base, baseLabel: label, old: old, new: new, hunks: hunks, repository: toplevel)
        }
        if content.isDirectory {
            let isSubmodule = FileManager.default.fileExists(atPath: file.appendingPathComponent(".git").path)
            return result(isSubmodule ? .submodule : .missing, base: nil, label: nil)
        }
        let resolved = await resolve(base, in: repository)
        guard let sha = resolved.sha else { return Self.sourceOnly(data: data, new: new, label: resolved.label, toplevel: toplevel) }
        let path = Self.relative(Self.realPath(file), to: repository.toplevel)
        let hash = await offPool { data.map { Data(SHA256.hash(data: $0)) } ?? Data() }
        let key = CacheKey(toplevel: toplevel, path: path, base: sha, content: hash)
        // Keyed by commit: another base that resolved to the same commit (HEAD is the merge-base)
        // shares the diff but names its own base.
        if let cached = cache[key], cached.index == nil || cached.index == Self.indexStamp(repository.gitDir) {
            var diff = cached.diff
            diff.baseLabel = resolved.label
            return diff
        }
        // Taken before git status runs: an index written meanwhile retires the entry next time.
        let index = Self.indexStamp(repository.gitDir)
        let patch = await patch(path, in: repository, base: sha)
        guard let diff = await Self.diff(data: data, new: new, base: sha, label: resolved.label, patch: patch, toplevel: toplevel) else { return nil }
        if diff.state == .missing { return diff }
        // git read the file some time after we did; only a file still identical afterwards
        // proves the patch describes the text we captured.
        guard await offPool({ Self.read(file).data }) == data else { return nil }
        store(Cached(diff: diff, index: diff.state == .added || diff.state == .ignored ? index : nil), for: key)
        return diff
    }

    static func sourceOnly(data: Data?, new: SideText, label: String, toplevel: String?) -> FileDiff {
        func result(_ state: FileDiff.State, new: SideText = SideText("")) -> FileDiff {
            FileDiff(state: state, base: nil, baseLabel: label, old: SideText(""), new: new, hunks: [], repository: toplevel)
        }
        if data == nil { return result(.missing) }
        if data.map(looksBinary) ?? false { return result(.binary) }
        return result(.noBase, new: new)
    }

    static func diff(data: Data?, new: SideText, base sha: String, label: String, patch: PatchResult, toplevel: String?) async -> FileDiff? {
        func result(_ state: FileDiff.State, old: SideText = SideText(""), new: SideText = SideText(""), hunks: [DiffHunk] = []) -> FileDiff {
            FileDiff(state: state, base: sha, baseLabel: label, old: old, new: new, hunks: hunks, repository: toplevel)
        }
        let patchData = patch.patch
        let parsed = await offPool { UnifiedDiff.parse(patchData) }
        if patch.entry == .gitlink || parsed.gitlink { return result(.submodule) }
        // A deleted file's only text is the oversized base; otherwise show the file as source.
        if patch.tooLarge { return result(data == nil ? .tooLarge : .diffTooLarge, new: data == nil ? SideText("") : new) }
        if parsed.binary || (data.map(looksBinary) ?? false) { return result(.binary) }
        if data == nil {
            guard patch.entry != .absent else { return result(.missing) }
            // Deleted from the working tree: the patch removes every base line.
            guard let old = await offPool({ UnifiedDiff.reconstructOld(new: new, parsed: parsed) }) else { return nil }
            return result(.deleted, old: old, new: new, hunks: UnifiedDiff.hunks(parsed.mappings))
        }
        if patch.entry == .absent {
            // New since the base: an agent's new file, tracked yet or not, is work of the branch;
            // a file git ignores (a node_modules frame) isn't, and shows as plain source.
            if patch.status == "!!" { return result(.ignored, new: new) }
            var added = result(.added, new: new, hunks: LineRangeMapping.whole(new).map { DiffHunk(mappings: [$0]) })
            added.untracked = patch.status == "??"
            return added
        }
        // Mode-only changes and identical content alike: nothing to show line by line.
        if parsed.mappings.isEmpty { return result(.unchanged, old: new, new: new) }
        guard let old = await offPool({ UnifiedDiff.reconstructOld(new: new, parsed: parsed) }) else { return nil }
        return result(.modified, old: old, new: new, hunks: UnifiedDiff.hunks(parsed.mappings))
    }

    /// `file` as of `revision` for a code tile pinned to it (`pinnedCommit`): the whole text at
    /// that commit, no diff (`.pinned`), or `.pinUnavailable` with the reason in `baseLabel`.
    /// The working tree plays no part, so the tile doesn't change when the file does.
    public func pinned(file: URL, revision: String) async -> FileDiff {
        func unavailable(_ reason: String, repository: String? = nil) -> FileDiff {
            FileDiff(state: .pinUnavailable, base: nil, baseLabel: reason, old: SideText(""), new: SideText(""), hunks: [], repository: repository)
        }
        guard NoteSource.isRevision(revision) else { return unavailable("not a revision: \(revision)") }
        guard let repository = await repository(containing: file) else { return unavailable("not in a git repository") }
        let toplevel = repository.toplevel
        let resolved = await Self.resolve(.commit(revision), in: toplevel)
        guard let sha = resolved.sha else { return unavailable(resolved.label, repository: toplevel.path) }
        let path = Self.relative(Self.realPath(file), to: toplevel)
        guard let data = try? await GitRunner.shared.run(["cat-file", "blob", "--end-of-options", "\(sha):\(path)"], in: toplevel, maxOutput: Self.maxFileSize) else {
            return unavailable("not in \(sha.prefix(7))", repository: toplevel.path)
        }
        if Self.looksBinary(data) { return unavailable("binary at \(sha.prefix(7))", repository: toplevel.path) }
        let text = await offPool { SideText(String(decoding: data, as: UTF8.self)) }
        return FileDiff(state: .pinned, base: sha, baseLabel: revision, old: SideText(""), new: text, hunks: [], repository: toplevel.path)
    }

    /// The base `file` diffs against, resolved afresh (a changes listing must match the
    /// repository as it is now, whatever its watcher has seen yet) and, when it names a commit,
    /// recorded for the diffs that follow; tiles showing a held repository hear of it when it moved.
    public func resolvedBase(for file: URL, base: DiffBase) async -> ResolvedBase? {
        guard let repository = await repository(containing: file) else { return nil }
        let resolved = await Self.resolve(base, in: repository.toplevel)
        guard resolved.sha != nil else { return resolved }
        let previous = repository.bases.updateValue(resolved, forKey: base)
        if let previous, previous != resolved, repositories[repository.toplevel.path] === repository {
            NotificationCenter.default.post(name: .gitDiffBaseChanged, object: repository.toplevel.path)
        }
        return resolved
    }

    /// `file` as of `commit` (`git cat-file blob`), for excerpts of old-side and pinned lines.
    /// Nil outside git, when the commit lacks the file, or when it is too large.
    public func text(of file: URL, at commit: String) async -> SideText? {
        guard let repository = await repository(containing: file) else { return nil }
        let path = Self.relative(Self.realPath(file), to: repository.toplevel)
        guard let data = try? await GitRunner.shared.run(["cat-file", "blob", "--end-of-options", "\(commit):\(path)"], in: repository.toplevel, maxOutput: Self.maxFileSize) else { return nil }
        return await offPool { SideText(String(decoding: data, as: UTF8.self)) }
    }

    private func store(_ entry: Cached, for key: CacheKey) {
        if cache.updateValue(entry, forKey: key) == nil {
            cacheOrder.append(key)
            if cacheOrder.count > cacheLimit { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        }
    }

    /// When the index at `gitDir` was last written, and its size; nil without one.
    private static func indexStamp(_ gitDir: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: gitDir + "/index"),
              let date = attributes[.modificationDate] as? Date else { return nil }
        return "\(date.timeIntervalSinceReferenceDate) \(attributes[.size] as? Int ?? 0)"
    }

    private static func read(_ file: URL) -> (data: Data?, tooLarge: Bool, isDirectory: Bool) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return (nil, false, false) }
        if attributes[.type] as? FileAttributeType == .typeDirectory { return (nil, false, true) }
        if let size = attributes[.size] as? Int, size > maxFileSize { return (nil, true, false) }
        return (try? Data(contentsOf: file), false, false)
    }

    /// git's own heuristic: a NUL byte in the first 8000 bytes.
    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }

    // MARK: Batched git

    private func patch(_ path: String, in repository: Repository, base: String) async -> PatchResult {
        let toplevel = repository.toplevel
        let key = BatchKey(toplevel: toplevel.path, base: base)
        return await withCheckedContinuation { continuation in
            let first = batches[key] == nil
            batches[key, default: []].append(Request(path: path, continuation: continuation))
            // Requests arriving within a short window (tiles going live together) join the same
            // git invocations.
            if first {
                Task {
                    try? await Task.sleep(for: .milliseconds(20))
                    await self.flush(key, toplevel: toplevel)
                }
            }
        }
    }

    private func flush(_ key: BatchKey, toplevel: URL) async {
        guard let requests = batches.removeValue(forKey: key) else { return }
        let paths = Array(Set(requests.map(\.path))).sorted()
        // What the base has at each path, and how big: gitlinks and oversized blobs never reach
        // `git diff`, whose output would otherwise hold the whole removed file.
        var entries: [String: BaseEntry] = [:]
        if let listing = try? await GitRunner.shared.run(["--literal-pathspecs", "ls-tree", "-l", "-z", "--full-tree", key.base, "--"] + paths, in: toplevel) {
            entries = Self.parseTree(listing)
        }
        let diffPaths = paths.filter { Self.diffs(entries[$0] ?? .absent) }
        let absentPaths = paths.filter { entries[$0] == nil }
        // Whether the files the base lacks are tracked yet, untracked, or ignored: one status.
        var codes: [String: String] = [:]
        if !absentPaths.isEmpty,
           let listing = try? await GitRunner.shared.run(["--literal-pathspecs", "status", "--porcelain=v1", "-z", "--ignored=matching", "--untracked-files=all", "--"] + absentPaths, in: toplevel) {
            codes = Self.parseStatus(listing)
        }
        var sections: [String: Data] = [:]
        var tooLarge = false
        if !diffPaths.isEmpty {
            diffRuns += 1
            let args = Self.changeRecords + [key.base, "--"] + diffPaths
            do {
                let output = try await GitRunner.shared.run(args, in: toplevel, maxOutput: diffPaths.count * 3 * Self.maxFileSize)
                sections = await offPool { Self.split(output) }
            } catch GitError.outputTooLarge {
                tooLarge = true
            } catch {}
        }
        let results = Self.patchResults(paths, entries: entries, codes: codes, sections: sections, diffTooLarge: tooLarge)
        for request in requests {
            request.continuation.resume(returning: results[request.path] ?? PatchResult())
        }
    }

    static func diffs(_ entry: BaseEntry) -> Bool {
        switch entry {
        case .gitlink: false
        case .blob(let size): size <= maxFileSize
        case .absent, .other: true
        }
    }

    static func patchResults(_ paths: [String], entries: [String: BaseEntry], codes: [String: String], sections: [String: Data], diffTooLarge: Bool) -> [String: PatchResult] {
        var results: [String: PatchResult] = [:]
        for path in paths {
            let entry = entries[path] ?? .absent
            var result = PatchResult(entry: entry)
            if case .blob(let size) = entry, size > maxFileSize { result.tooLarge = true }
            if diffs(entry) {
                // An ignored directory is listed as itself (`node_modules/`), not file by file.
                if entry == .absent { result.status = codes[path] ?? codes.first { $0.key.hasSuffix("/") && path.hasPrefix($0.key) }?.value }
                if diffTooLarge { result.tooLarge = true } else { result.patch = sections[path] ?? Data() }
            }
            results[path] = result
        }
        return results
    }

    /// `git diff` giving pure change records: -U0 with zero inter-hunk context whatever the
    /// user's diff config says (hunks are regrouped locally), no renames, byte-exact paths.
    static let changeRecords = ["--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--diff-algorithm=histogram",
                                "-U0", "--inter-hunk-context=0", "--src-prefix=a/", "--dst-prefix=b/"]

    /// `git ls-tree -l -z` records: `<mode> <type> <object> <size>\t<path>\0`.
    static func parseTree(_ listing: Data) -> [String: BaseEntry] {
        var entries: [String: BaseEntry] = [:]
        for record in listing.split(separator: 0) {
            guard let tab = record.firstIndex(of: 0x09) else { continue }
            let meta = String(decoding: record[record.startIndex..<tab], as: UTF8.self).split(separator: " ", omittingEmptySubsequences: true)
            let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
            guard meta.count >= 4 else { continue }
            switch meta[1] {
            case "blob": entries[path] = .blob(size: Int(meta[3]) ?? 0)
            case "commit": entries[path] = .gitlink
            default: entries[path] = .other
            }
        }
        return entries
    }

    /// `git status --porcelain=v1 -z` records: `XY <path>\0`, a rename or copy with its source
    /// path in the next record. Paths to their two-letter code.
    static func parseStatus(_ listing: Data) -> [String: String] {
        var codes: [String: String] = [:]
        var records = listing.split(separator: 0)[...]
        while let record = records.popFirst() {
            guard record.count > 3 else { continue }
            let code = String(decoding: record.prefix(2), as: UTF8.self)
            codes[String(decoding: record.dropFirst(3), as: UTF8.self)] = code
            if code.first == "R" || code.first == "C" { _ = records.popFirst() }
        }
        return codes
    }

    /// Per-file sections of a multi-file patch keyed by path, split on LF bytes and with git's
    /// C-quoted names (`"a/tab\there"`) decoded.
    static func split(_ patch: Data) -> [String: Data] {
        var sections: [String: Data] = [:]
        var current: (path: String, start: Int)?
        let bytes = [UInt8](patch)
        let marker = Array("diff --git ".utf8)
        var lineStart = 0
        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            if bytes[lineStart..<lineEnd].starts(with: marker) {
                if let current { sections[current.path] = Data(bytes[current.start..<lineStart]) }
                current = headerPath(bytes[(lineStart + marker.count)..<lineEnd]).map { ($0, lineStart) }
            }
            lineStart = lineEnd + 1
        }
        if let current { sections[current.path] = Data(bytes[current.start...]) }
        return sections
    }

    /// The path in `a/<path> b/<path>` (no renames, so both sides name the same file).
    static func headerPath(_ rest: ArraySlice<UInt8>) -> String? {
        if rest.first == UInt8(ascii: "\"") {
            guard let quoted = unquote(rest), quoted.starts(with: Array("a/".utf8)) else { return nil }
            return String(decoding: quoted.dropFirst(2), as: UTF8.self)
        }
        let length = (rest.count - 5) / 2
        guard length > 0, rest.count == 2 * length + 5 else { return nil }
        let path = rest.dropFirst(2).prefix(length)
        guard rest.starts(with: Array("a/".utf8)), Array(rest.suffix(length + 3)) == Array(" b/".utf8) + Array(path) else { return nil }
        return String(decoding: path, as: UTF8.self)
    }

    /// Decodes the leading C-style quoted string git writes for unusual file names.
    static func unquote(_ text: ArraySlice<UInt8>) -> [UInt8]? {
        var out: [UInt8] = []
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let byte = text[index]
            if byte == UInt8(ascii: "\"") { return out }
            guard byte == UInt8(ascii: "\\") else {
                out.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < text.endIndex else { return nil }
            let escaped = text[index]
            switch escaped {
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                guard index + 2 < text.endIndex else { return nil }
                let digits = text[index...(index + 2)].map { Int($0) - 48 }
                guard digits.allSatisfy({ (0...7).contains($0) }) else { return nil }
                out.append(UInt8(truncatingIfNeeded: digits[0] * 64 + digits[1] * 8 + digits[2]))
                index += 3
                continue
            case UInt8(ascii: "a"): out.append(0x07)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "v"): out.append(0x0B)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "r"): out.append(0x0D)
            default: out.append(escaped)
            }
            index += 1
        }
        return nil
    }

    // MARK: Repositories and bases

    /// The held record for the repository containing `file`, or a transient one (bases resolved
    /// afresh each time) when no live tile holds it.
    private func repository(containing file: URL) async -> Repository? {
        let directory = Self.existingAncestor(of: file.deletingLastPathComponent())
        if let known = repositoryOfDirectory[directory.path], let repository = repositories[known] { return repository }
        guard let output = try? await GitRunner.shared.run(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"], in: directory) else { return nil }
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
        guard lines.count == 3 else { return nil }
        if let held = repositories[lines[0]] {
            repositoryOfDirectory[directory.path] = lines[0]
            return held
        }
        return Repository(toplevel: URL(fileURLWithPath: lines[0]), gitDir: lines[1], commonDir: lines[2])
    }

    /// The repository's resolved base, reused only when it names a commit: an answer without one
    /// (no commits yet, or git cancelled or failing mid-question) is asked again on the next
    /// load, so it never outlives what caused it. It is still recorded, so a HEAD or ref change
    /// re-resolves it and tiles showing it reload (`refresh`).
    private func resolve(_ base: DiffBase, in repository: Repository) async -> ResolvedBase {
        if let known = repository.bases[base], known.sha != nil { return known }
        let resolved = await Self.resolve(base, in: repository.toplevel)
        repository.bases[base] = resolved
        return resolved
    }

    /// Git's answer for `base`; a git that couldn't answer (cancelled, timed out, failed) is
    /// `git failed: <why>`, never mistaken for a missing commit.
    static func resolve(_ base: DiffBase, in toplevel: URL) async -> ResolvedBase {
        do {
            return try await lookUp(base, in: toplevel)
        } catch {
            return ResolvedBase(sha: nil, label: "git failed: \(describe(error))")
        }
    }

    private static func lookUp(_ base: DiffBase, in toplevel: URL) async throws -> ResolvedBase {
        /// The commit `revision` names; nil when there is none (git exits 1: unborn HEAD, unknown name).
        func verify(_ revision: String) async throws -> String? {
            let data: Data
            do {
                data = try await GitRunner.shared.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(revision)^{commit}"], in: toplevel)
            } catch GitError.failed(status: 1, _) {
                return nil
            }
            let sha = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return sha.isEmpty ? nil : sha
        }
        switch base {
        case .head:
            let sha = try await verify("HEAD")
            return ResolvedBase(sha: sha, label: sha == nil ? "no commits yet" : "HEAD")
        case .commit(let revision):
            let sha = try await verify(revision)
            return ResolvedBase(sha: sha, label: sha == nil ? "unknown commit \(revision)" : revision)
        case .mergeBase:
            // HEAD is only checked when git can't answer otherwise: without commits there is no
            // merge-base, and that is what the tile says, not which branch is missing.
            guard let branch = try await defaultBranch(in: toplevel) else {
                return ResolvedBase(sha: nil, label: try await verify("HEAD") == nil ? "no commits yet" : "no default branch")
            }
            let shortName = branch.replacingOccurrences(of: "refs/remotes/", with: "").replacingOccurrences(of: "refs/heads/", with: "")
            let data: Data
            do {
                // Exit 1: the histories share no commit.
                data = try await GitRunner.shared.run(["merge-base", branch, "HEAD"], in: toplevel, allowedStatus: [0, 1])
            } catch GitError.failed(let status, let stderr) {
                guard try await verify("HEAD") == nil else { throw GitError.failed(status: status, stderr: stderr) }
                return ResolvedBase(sha: nil, label: "no commits yet")
            }
            let sha = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return sha.isEmpty ? ResolvedBase(sha: nil, label: "no merge-base with \(shortName)") : ResolvedBase(sha: sha, label: ResolvedBase.mergeBasePrefix + shortName)
        }
    }

    /// Why git couldn't answer, in a few words for a header.
    private static func describe(_ error: Error) -> String {
        switch error {
        case is CancellationError: "cancelled"
        case GitError.timedOut: "timed out"
        case GitError.outputTooLarge: "too much output"
        case GitError.launch(let reason): reason
        case GitError.failed(let status, let stderr): stderr.split(separator: "\n").first.map(String.init) ?? "exit \(status)"
        default: "\(error)"
        }
    }

    /// origin/HEAD's target when the clone has one, else local main, else master.
    static func defaultBranch(in toplevel: URL) async throws -> String? {
        let data = try await GitRunner.shared.run(["for-each-ref", "--format=%(refname)%09%(symref)", "refs/remotes/origin/HEAD", "refs/heads/main", "refs/heads/master"], in: toplevel)
        var refs: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            refs[String(fields[0])] = fields.count > 1 ? String(fields[1]) : ""
        }
        if let target = refs["refs/remotes/origin/HEAD"], !target.isEmpty { return target }
        if refs["refs/heads/main"] != nil { return "refs/heads/main" }
        if refs["refs/heads/master"] != nil { return "refs/heads/master" }
        return nil
    }

    private func watch(_ repository: Repository) {
        let toplevel = repository.toplevel.path
        repository.watcher = FileEventStream(paths: repository.watchedDirectories, latency: 0.4) { [weak self] paths in
            let bases = paths.contains(where: Self.movesBase), index = paths.contains(where: Self.isIndex)
            if bases { NotificationCenter.default.post(name: .gitRefsMoved, object: toplevel) }
            guard let self, bases || index else { return }
            Task { await self.refresh(toplevel, bases: bases, index: index) }
        }
    }

    /// HEAD, branch refs, and packed-refs decide every base; index, objects, and logs never do.
    nonisolated public static func movesBase(_ path: String) -> Bool {
        if path.hasSuffix(".lock") || path.contains("/logs/") || path.contains("/objects/") { return false }
        let name = (path as NSString).lastPathComponent
        return name == "HEAD" || name == "packed-refs" || path.contains("/refs/")
    }

    /// The index: what git tracks, so whether a file the base lacks is untracked (`git add`).
    nonisolated static func isIndex(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == "index" && !path.contains("/objects/") && !path.contains("/refs/")
    }

    /// After a git write: re-resolve the bases tiles are using (`bases`) and retire cached diffs
    /// read against another index (`index`); announce the repository when either changed what
    /// its tiles show.
    func refresh(_ toplevel: String, bases: Bool, index: Bool) async {
        guard let repository = repositories[toplevel] else { return }
        var changed = false
        if index {
            let now = Self.indexStamp(repository.gitDir)
            let stale = Set(cache.filter { $0.key.toplevel == toplevel && $0.value.index != nil && $0.value.index != now }.keys)
            for key in stale { cache.removeValue(forKey: key) }
            cacheOrder.removeAll { stale.contains($0) }
            changed = !stale.isEmpty
        }
        if bases {
            let previous = repository.bases
            for base in previous.keys {
                let resolved = await Self.resolve(base, in: repository.toplevel)
                if resolved != previous[base] { changed = true }
                repository.bases[base] = resolved
            }
        }
        if changed {
            NotificationCenter.default.post(name: .gitDiffBaseChanged, object: toplevel)
        }
    }

    // MARK: Paths

    /// Symlink-free absolute path, also for files that no longer exist (deleted in the tree).
    static func realPath(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        var existing = standardized
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        // realpath(3), not resolvingSymlinksInPath, which maps /private/var back to /var while git
        // reports the /private form.
        guard let real = realpath(existing.path, nil) else { return standardized }
        defer { free(real) }
        var resolved = URL(fileURLWithPath: String(cString: real))
        for component in missing { resolved.appendPathComponent(component) }
        return resolved
    }

    static func existingAncestor(of directory: URL) -> URL {
        var current = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        while !(FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory) && isDirectory.boolValue), current.path != "/" {
            current.deleteLastPathComponent()
        }
        return current
    }

    static func relative(_ file: URL, to toplevel: URL) -> String {
        let root = toplevel.path.hasSuffix("/") ? toplevel.path : toplevel.path + "/"
        return file.path.hasPrefix(root) ? String(file.path.dropFirst(root.count)) : file.path
    }
}
