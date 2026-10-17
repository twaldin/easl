import Foundation

/// What an anchored fence shows: the resolved range of a real file (or, when stale, the text it
/// last showed). Built off the main actor by `NoteSource.excerpt`.
public struct NoteExcerpt: Equatable, Sendable {
    /// The file the fence points at, as written or as found by a workspace symbol search.
    public var path: String
    public var range: LineRange?
    /// The range's lines; for a stale anchor, the captured text it used to show (possibly empty).
    public var lines: [String]
    public var status: NoteAnchor.Status
    /// For a proposal: the range (old) against the fence body (new), computed here, off the main
    /// actor, because a whole-file proposal can be large.
    public var diff: [NoteDiff.Line]?
    /// Lines in the file, so a proposal row appended past its range knows whether a real line
    /// follows it.
    public var fileLineCount = 0
    /// Nothing to read: the file doesn't exist (on disk, or at the pinned commit), or the
    /// pinned commit doesn't. A stale anchor on a file that is there is not missing.
    public var missing = false
    /// A proposal whose text the file already reads (`NoteAnchor.applied`): `range` is where,
    /// `lines` the file's, and there is no diff.
    public var applied = false
    /// Not read: the file lies outside the board's areas (`BoardAreas`), for metadata the app
    /// writes or reports itself. Stale with `NoteSource.refusal`.
    public var refused = false

    public init(path: String, range: LineRange?, lines: [String], status: NoteAnchor.Status, diff: [NoteDiff.Line]? = nil,
                fileLineCount: Int = 0, missing: Bool = false, applied: Bool = false) {
        self.path = path
        self.range = range
        self.lines = lines
        self.status = status
        self.diff = diff
        self.fileLineCount = fileLineCount
        self.missing = missing
        self.applied = applied
    }

    public var isStale: Bool {
        if case .stale = status { true } else { false }
    }

    /// What `object.get` reports for the fence (schema `AnchorStatus`).
    public enum State: String, Sendable {
        case live, relocated, stale, applied, missing
    }

    public var state: State {
        if missing { return .missing }
        if applied { return .applied }
        switch status {
        case .exact: return .live
        case .relocated: return .relocated
        case .stale: return .stale
        }
    }

    /// `state`, the range it resolved to, the range as written when it moved, and why it is stale.
    public var statusJSON: [String: JSONValue] {
        var out: [String: JSONValue] = ["state": .string(state.rawValue)]
        if let range { out["range"] = range.json }
        switch status {
        case .relocated(let from): out["written"] = from.json
        case .stale(let reason): out["reason"] = .string(reason)
        case .exact: break
        }
        return out
    }

    /// For each `diff` row, the real source line it mentions: its own line for kept and removed
    /// rows; for an added row the line it would be inserted before, or, appended at the end of
    /// the file where there is none, the last line (which it follows).
    public var proposalLines: [Int] {
        guard let diff, let range else { return [] }
        var next = range.start
        return diff.map { entry in
            switch entry {
            case .same(let old, _, _), .removed(let old, _):
                next = range.start + old + 1
                return range.start + old
            case .added:
                return next <= fileLineCount ? next : max(1, fileLineCount)
            }
        }
    }
}

public enum NoteSource {
    /// Resolve a fence against disk (or `git show` for a pinned commit). `captured` is the text the
    /// range showed when first resolved; it re-finds the range when lines move and stands in when
    /// the anchor is lost. `body` is the fence's own text (see `NoteAnchor.resolve`). With `areas`,
    /// for metadata the app writes or reports itself, `root` and the file must lie inside them
    /// (`BoardAreas`), else the fence is `refused`.
    @concurrent
    public static func excerpt(for fence: NoteFence, root: URL, captured: [String]?, body: [String] = [], within areas: BoardAreas? = nil) async -> NoteExcerpt {
        if let areas, !areas.permits(root: root) { return refused(fence.path ?? "") }
        var path = fence.path
        if path == nil, let symbol = fence.symbol {
            path = await locate(symbol: symbol, root: root)
        }
        guard let path else {
            return NoteExcerpt(path: "", range: nil, lines: captured ?? [], status: .stale("symbol \(fence.symbol ?? "") not found in the workspace"))
        }
        let text: String
        func failed(_ reason: String, missing: Bool) -> NoteExcerpt {
            NoteExcerpt(path: path, range: nil, lines: captured ?? [], status: .stale(reason), missing: missing)
        }
        do {
            if let areas {
                text = try await areas.read(path, commit: fence.commit, root: root)
            } else {
                text = try await read(path, commit: fence.commit, root: root)
            }
        } catch NoteSourceError.refused {
            return refused(path)
        } catch NoteSourceError.invalidRevision(let commit) {
            return failed("\"\(commit)\" is not a commit", missing: false)
        } catch NoteSourceError.unknownCommit(let commit) {
            return failed("unknown commit \(commit)", missing: true)
        } catch NoteSourceError.notAtCommit(let commit) {
            return failed("\(path) does not exist at \(commit)", missing: true)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return failed("no file \(path)", missing: true)
        } catch {
            let place = fence.commit.map { "\(path) at \($0)" } ?? path
            return failed("cannot read \(place)", missing: false)
        }
        return interpret(text, for: fence, path: path, captured: captured, body: body)
    }

    public static func interpret(_ text: String, for fence: NoteFence, path: String, captured: [String]? = nil, body: [String] = []) -> NoteExcerpt {
        let source = lines(of: text)
        let resolution = NoteAnchor.resolve(fence, in: source, captured: captured, body: body)
        let shown = resolution.range.map { Array(source[($0.start - 1)..<$0.end]) }
        if fence.mode == .propose {
            // Already applied: a body starting anywhere it would overlap the resolved range, or,
            // with the anchor lost (the proposal rewrote its first line), anywhere in the file.
            let starts = resolution.range.map { ($0.start - max(1, body.count))...($0.end - 1) }
            let near = (resolution.range?.start ?? fence.lines?.start ?? 1) - 1
            if let at = NoteAnchor.applied(body, original: captured ?? shown ?? [], in: source, starts: starts, near: near) {
                let status: NoteAnchor.Status = at == resolution.range ? resolution.status : fence.lines.map { $0 == at ? .exact : .relocated(from: $0) } ?? .exact
                return NoteExcerpt(path: path, range: at, lines: Array(source[(at.start - 1)..<at.end]), status: status, fileLineCount: source.count, applied: true)
            }
        }
        guard let range = resolution.range, let shown else {
            return NoteExcerpt(path: path, range: nil, lines: captured ?? [], status: resolution.status, fileLineCount: source.count)
        }
        let diff = fence.mode == .propose ? NoteDiff.lines(shown, body) : nil
        return NoteExcerpt(path: path, range: range, lines: shown, status: resolution.status, diff: diff, fileLineCount: source.count)
    }

    /// A note's anchored fences resolved in turn (`excerpt`, inside `areas` when given), by key,
    /// each with the text it `captured` (by key); fewer when the task is cancelled on the way.
    public static func excerpts(for fences: [NoteMarkdown.AnchoredFence], root: URL, captured: [String: [String]] = [:], within areas: BoardAreas? = nil) async -> [String: NoteExcerpt] {
        var results: [String: NoteExcerpt] = [:]
        for fence in fences {
            results[fence.key] = await excerpt(for: fence.fence, root: root, captured: captured[fence.key], body: fence.body, within: areas)
            if Task.isCancelled { break }
        }
        return results
    }

    /// The reason a fence outside the board's areas is stale, as the API reports it.
    public static let refusal = "path refused"

    /// A fence whose file the board's areas don't permit: nothing read, nothing shown.
    static func refused(_ path: String) -> NoteExcerpt {
        var excerpt = NoteExcerpt(path: path, range: nil, lines: [], status: .stale(refusal))
        excerpt.refused = true
        return excerpt
    }

    /// File text; a pinned commit reads through `git show` (see `showCommand`).
    static func read(_ path: String, commit: String?, root: URL) async throws -> String {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        guard let commit else { return try await offPool { Result { try String(contentsOf: url, encoding: .utf8) } }.get() }
        let command = try showCommand(path, commit: commit, root: root)
        return try await show(command.arguments, commit: commit, in: command.directory)
    }

    /// A pinned file's text from `git show`. A failed show tells a commit that lacks the file
    /// from one that doesn't exist.
    static func show(_ arguments: [String], commit: String, in directory: URL) async throws -> String {
        let data: Data
        do {
            data = try await GitRunner.shared.run(arguments, in: directory, maxOutput: maxOutput, timeout: timeout)
        } catch GitError.failed {
            throw await missing(commit, in: directory)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }

    /// Why git found no file at `commit`: the commit doesn't exist, or it lacks the file.
    static func missing(_ commit: String, in directory: URL) async -> NoteSourceError {
        let exists = try? await GitRunner.shared.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(commit)^{commit}"], in: directory, timeout: timeout)
        return exists == nil ? .unknownCommit(commit) : .notAtCommit(commit)
    }

    /// `git show --end-of-options <commit>:./<path>` and where to run it. A path under the board
    /// root runs in the root, relative to it (the root may be a subdirectory of the repository).
    /// A file elsewhere, typically in another worktree of the repository, runs in its own
    /// worktree with the path relative to that: every worktree shares the object database, but
    /// only its own top level makes the path mean something. The revision comes from markdown
    /// anyone can write, so it may not look like an option or carry its own `:path`.
    static func showCommand(_ path: String, commit: String, root: URL) throws -> (arguments: [String], directory: URL) {
        guard isRevision(commit) else { throw NoteSourceError.invalidRevision(commit) }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let rootPath = root.standardizedFileURL.path
        let absolute = url.standardizedFileURL.path
        if absolute.hasPrefix(rootPath + "/") {
            return (["show", "--end-of-options", "\(commit):./\(absolute.dropFirst(rootPath.count + 1))"], root)
        }
        guard let worktree = GitWorktree.containing(absolute), let relative = worktree.relativePath(of: absolute) else {
            throw NoteSourceError.notAtCommit(commit)
        }
        return (["show", "--end-of-options", "\(commit):./\(relative)"], URL(fileURLWithPath: worktree.toplevel))
    }

    static func isRevision(_ text: String) -> Bool {
        guard let first = text.first, first != "-" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || "._~^/-".contains($0) }
    }

    static func symbolPattern(_ symbol: String) -> String? {
        guard let name = symbol.split(separator: ".").last.map(String.init), !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) else { return nil }
        return "(^|[^[:alnum:]_.$])(\(DeclarationKeywords.alternation(DeclarationKeywords.kinds.keys)))[[:space:]]+([(][^)]*[)][[:space:]]*)?\(name.replacingOccurrences(of: "$", with: "\\$"))([^[:alnum:]_$]|$)"
    }

    /// First tracked file that declares `symbol` (its last dotted component), found by `git grep`
    /// with the strongest declaration keywords.
    static func locate(symbol: String, root: URL) async -> String? {
        guard let pattern = symbolPattern(symbol) else { return nil }
        guard let data = try? await GitRunner.shared.run(["grep", "-l", "-I", "-E", "-e", pattern], in: root, allowedStatus: [0, 1], maxOutput: maxOutput, timeout: timeout),
              let output = String(data: data, encoding: .utf8) else { return nil }
        let candidates = output.split(separator: "\n").map(String.init)
        return await offPool {
            candidates.first { candidate in
                guard let text = try? String(contentsOf: root.appendingPathComponent(candidate), encoding: .utf8) else { return false }
                return NoteAnchor.symbolRange(symbol, in: lines(of: text)) != nil
            }
        }
    }

    /// Git for a fence is bounded: a pinned file larger than this is not an excerpt, and a stuck
    /// git can't hold one of the app's two git slots.
    static let maxOutput = 32 << 20
    static let timeout: TimeInterval = 20

    /// Lines without the empty string after a trailing newline.
    public static func lines(of text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }
}

public enum NoteSourceError: Error, Equatable {
    /// A pinned fence's `commit=` doesn't look like a revision (e.g. it looks like an option).
    case invalidRevision(String)
    /// The pinned commit doesn't exist in the file's repository.
    case unknownCommit(String)
    /// The commit exists but has no file at the path (or the path is in no repository).
    case notAtCommit(String)
    /// Outside the board's areas, or a symlink in the commit's tree (`BoardAreas.read`).
    case refused
}
