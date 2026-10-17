import Foundation

/// What a changes tile reviews (`ChangesProps`): the worktree (`root`: another worktree of the
/// board's repository, absolute or board-relative; none: the board root), the diff base (default
/// `HEAD`: the uncommitted work, what an agent just did; `merge-base`; or a commit) and the files
/// or directories it is limited to (relative to `root` or absolute; none: all of `root`).
///
/// `head` (any commit or ref: a branch, `origin/x`, a fetched `pull/N/head`) compares two commits
/// instead of a worktree: the files as `head` has them against its merge-base with `base`
/// (`git diff base...head`, a pull request's view), read from git objects, no checkout, nothing
/// to stage or discard. `ref` (a branch) is the worktree that has it checked out when one of the
/// board's repository does, else `head: ref`. With either, `base` defaults to `merge-base` (the
/// default branch).
public struct ChangesSpec: Equatable, Sendable {
    public var root: String?
    public var baseProp: String
    public var paths: [String]
    public var head: String?
    public var ref: String?
    /// The commit `ref` named when the tile last read it (`props.refSha`, written by the tile):
    /// what it reads once the branch is gone.
    public var refSha: String?

    public init(_ props: JSONValue) {
        func nonEmpty(_ key: String) -> String? { props[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        root = nonEmpty("root")
        head = nonEmpty("head")
        ref = nonEmpty("ref")
        refSha = nonEmpty("refSha")
        baseProp = nonEmpty("base") ?? (head != nil || ref != nil ? "merge-base" : "HEAD")
        paths = props["paths"]?.array?.compactMap(\.string).filter { !$0.isEmpty } ?? []
    }

    public var base: DiffBase { DiffBase(prop: baseProp) }

    /// The directory reviewed: `root` resolved against the board root; for `ref`, the worktree
    /// of the board's repository that has the branch checked out; else the board root.
    public func directory(boardRoot: URL) -> URL {
        if let ref, root == nil {
            guard let own = GitWorktree.containing(boardRoot.path), let found = GitRefs.liveWorktree(ref, in: own), found.gitDir != own.gitDir else { return boardRoot }
            return URL(fileURLWithPath: found.toplevel)
        }
        guard let root else { return boardRoot }
        return (root.hasPrefix("/") ? URL(fileURLWithPath: root) : boardRoot.appendingPathComponent(root)).standardizedFileURL
    }

    /// How titles and the activity log name the tile: `changes vs HEAD`, `changes fm/x vs merge-base`.
    public var name: String {
        "changes \((head ?? ref).map { "\($0) " } ?? "")vs \(baseProp)"
    }
}

/// A base a changes tile compares with, as its header's picker and Review Changes offer them:
/// the uncommitted work (`HEAD`), everything the branch changed (the merge-base with the default
/// branch, the PR view), or another commit or ref typed in.
public enum ChangesBaseChoice: Equatable, Sendable {
    case uncommitted
    case branch
    case other(String)

    public init(prop: String) {
        switch prop {
        case "HEAD", "head": self = .uncommitted
        case "merge-base": self = .branch
        default: self = .other(prop)
        }
    }

    /// A commit or ref typed into the picker (whitespace trimmed); nil when nothing was typed.
    public init?(typed text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.init(prop: trimmed)
    }

    /// `props.base` for it.
    public var prop: String {
        switch self {
        case .uncommitted: "HEAD"
        case .branch: "merge-base"
        case .other(let revision): revision
        }
    }

    /// How the pickers (changes and code tiles) and Review Changes name it: `Uncommitted
    /// changes`, `Branch vs origin/main` (`defaultBranch`: `GitWorktree.defaultBranch`), `vs v1.2`
    /// (a full SHA shortened).
    public func title(defaultBranch: String?) -> String {
        switch self {
        case .uncommitted: "Uncommitted changes"
        case .branch: "Branch vs \(defaultBranch ?? "default branch")"
        case .other(let revision): "vs \(revision.count == 40 && revision.allSatisfy(\.isHexDigit) ? String(revision.prefix(7)) : revision)"
        }
    }

    /// The picker's choices with `current` checked: the two standing ones, and the one typed in
    /// when that is current.
    public static func choices(current: ChangesBaseChoice) -> [ChangesBaseChoice] {
        [.uncommitted, .branch] + (current == .uncommitted || current == .branch ? [] : [current])
    }
}

/// One row of a unified diff: an unchanged line around or between changes, a removed base line,
/// or an added working-tree line, with its line numbers (1-based) on the sides it is on.
public struct ChangeLine: Equatable, Sendable {
    public enum Kind: Sendable { case context, removed, added }

    public var kind: Kind
    public var old: Int?
    public var new: Int?

    public init(kind: Kind, old: Int?, new: Int?) {
        self.kind = kind
        self.old = old
        self.new = new
    }
}

/// Whether the index holds a hunk: `unstaged` (the working tree differs from the index there
/// and the index is as HEAD there), `partial` (the index holds some of it: staged, then edited
/// again), `staged` (the index has it), or `committed` (HEAD already has it: a base older than
/// HEAD).
public enum HunkStatus: String, Sendable, Equatable {
    case unstaged, partial, staged, committed

    /// Staging it would change the index.
    public var stageable: Bool { self == .unstaged || self == .partial }
    /// The index holds some of it that HEAD doesn't: unstaging would change the index.
    public var unstageable: Bool { self == .staged || self == .partial }
    /// Some of it isn't committed yet: Discard has something of the user's own work to put back.
    /// A committed hunk (a branch's commits, reviewed against its merge-base) never is: a review
    /// must never rewrite the commits it reads.
    public var discardable: Bool { self != .committed }
}

/// One hunk as `git diff -U3` groups it: changes at most 2 × 3 unchanged lines apart, with 3
/// lines of context around them.
public struct ChangeHunk: Equatable, Sendable {
    public var mappings: [LineRangeMapping]
    public var lines: [ChangeLine]
    public var status: HunkStatus
    /// Stable across reloads while the hunk's lines stay the same (line numbers aside): a hash
    /// of its path and its lines' kinds and text (`ChangeSet.load` sets it).
    public var id = ""
    /// The span the lines cover on each side, as a patch header counts it: a zero count starts
    /// at the line before.
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int

    public init(mappings: [LineRangeMapping], old: SideText, new: SideText, status: HunkStatus = .unstaged, context: Int = 3) {
        self.mappings = mappings
        self.status = status
        let lines = Self.lines(old: old, new: new, mappings: mappings, context: context)
        self.lines = lines
        let olds = lines.compactMap(\.old), news = lines.compactMap(\.new)
        oldCount = olds.count
        newCount = news.count
        oldStart = olds.first ?? max(0, (mappings.first?.original.lowerBound ?? 1) - 1)
        newStart = news.first ?? max(0, (mappings.first?.modified.lowerBound ?? 1) - 1)
    }

    public var header: String {
        func span(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
        return "@@ -\(span(oldStart, oldCount)) +\(span(newStart, newCount)) @@"
    }

    /// How the tile names it: `Lines 15–46` (its working-tree lines), or `Removed lines 3–9`
    /// when it has none (a deleted file).
    public var label: String {
        func span(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start)–\(start + count - 1)" }
        if newCount > 0 { return "\(newCount == 1 ? "Line" : "Lines") \(span(newStart, newCount))" }
        return "Removed \(oldCount == 1 ? "line" : "lines") \(span(oldStart, oldCount))"
    }

    /// The hunk as unified-diff lines (` `, `-`, `+` and the text, no line breaks) between
    /// `old` and `new`, the first `limit`.
    public func unified(old: SideText, new: SideText, limit: Int = .max) -> [String] {
        lines.prefix(limit).map { line in
            switch line.kind {
            case .context: " " + Self.text(new, line.new)
            case .removed: "-" + Self.text(old, line.old)
            case .added: "+" + Self.text(new, line.new)
            }
        }
    }

    static func text(_ side: SideText, _ line: Int?) -> String {
        guard let line, line >= 1, line <= side.lineCount else { return "" }
        return side.line(line)
    }

    /// `id` for a hunk of `path`: FNV-1a over the path and the unified lines.
    static func identity(path: String, unified: [String]) -> String {
        var hash = StableHash()
        hash.add(path)
        for line in unified {
            hash.add("\n")
            hash.add(line)
        }
        return "h" + hash.hex
    }

    /// `rows` (indices into `lines`) with the other half of every replaced line in them: within
    /// one change the n-th removed and n-th added line are a pair (an edited line), and picking
    /// either picks the edit. Lines without a partner (a pure addition or deletion, the surplus
    /// of a longer side) stay as they are.
    public func pairedRows(_ rows: Set<Int>) -> Set<Int> {
        var result = rows
        var index = 0
        while index < lines.count {
            guard lines[index].kind != .context else {
                index += 1
                continue
            }
            var removed: [Int] = [], added: [Int] = []
            while index < lines.count, lines[index].kind == .removed {
                removed.append(index)
                index += 1
            }
            while index < lines.count, lines[index].kind == .added {
                added.append(index)
                index += 1
            }
            for pair in 0..<min(removed.count, added.count) where rows.contains(removed[pair]) || rows.contains(added[pair]) {
                result.insert(removed[pair])
                result.insert(added[pair])
            }
        }
        return result
    }

    public var added: Int { mappings.reduce(0) { $0 + $1.modified.count } }
    public var removed: Int { mappings.reduce(0) { $0 + $1.original.count } }

    /// What a mention of the whole hunk names: its working-tree lines, or its base lines when it
    /// only removes.
    public var mentionLines: (side: DiffSide, lines: LineRange) { DiffHunk(mappings: mappings).mentionLines }

    /// Working-tree lines the hunk's changes span (an empty range for a pure deletion sits
    /// before the line after it).
    public var modified: Range<Int> { mappings.first!.modified.lowerBound..<mappings.last!.modified.upperBound }

    /// The unified-diff rows of `mappings` (one hunk's changes) between `old` and `new`, with up
    /// to `context` unchanged lines before, between, and after them.
    public static func lines(old: SideText, new: SideText, mappings: [LineRangeMapping], context: Int = 3) -> [ChangeLine] {
        guard let first = mappings.first else { return [] }
        var lines: [ChangeLine] = []
        let lead = max(0, min(context, first.original.lowerBound - 1, first.modified.lowerBound - 1))
        var oldLine = first.original.lowerBound - lead, newLine = first.modified.lowerBound - lead
        for mapping in mappings {
            while newLine < mapping.modified.lowerBound, oldLine < mapping.original.lowerBound {
                lines.append(ChangeLine(kind: .context, old: oldLine, new: newLine))
                oldLine += 1
                newLine += 1
            }
            for line in mapping.original { lines.append(ChangeLine(kind: .removed, old: line, new: nil)) }
            for line in mapping.modified { lines.append(ChangeLine(kind: .added, old: nil, new: line)) }
            oldLine = mapping.original.upperBound
            newLine = mapping.modified.upperBound
        }
        let trail = max(0, min(context, old.lineCount - oldLine + 1, new.lineCount - newLine + 1))
        for _ in 0..<trail {
            lines.append(ChangeLine(kind: .context, old: oldLine, new: newLine))
            oldLine += 1
            newLine += 1
        }
        return lines
    }

    /// Whether two line ranges of the same side meet: overlapping, or an empty range (a
    /// deletion's position) at or touching the other.
    static func touches(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        if a.isEmpty, b.isEmpty { return a.lowerBound == b.lowerBound }
        if a.isEmpty { return b.lowerBound <= a.lowerBound && a.lowerBound <= b.upperBound }
        if b.isEmpty { return a.lowerBound <= b.lowerBound && b.lowerBound <= a.upperBound }
        return a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }

    /// The index's view of a hunk from the working-tree side (every range in working-tree
    /// lines): where the index differs from the working tree over any of its changes
    /// (`unstaged` = index → working tree changes; an untracked file is all unstaged) it is
    /// `partial` when the index also differs from HEAD there (`staged` = HEAD → index changes, in
    /// index lines: staged, then edited again), else `unstaged`; where the index matches the
    /// working tree, `staged` when HEAD differs there too (`head` = HEAD → working tree changes;
    /// nil when the base is HEAD, whose hunks HEAD always lacks), else `committed`.
    public static func status(of mappings: [LineRangeMapping], tracked: Bool, unstaged: [LineRangeMapping], staged: [LineRangeMapping] = [],
                              head: [LineRangeMapping]?) -> HunkStatus {
        guard tracked else { return .unstaged }
        let ranges = mappings.map(\.modified)
        if unstaged.contains(where: { change in ranges.contains { touches($0, change.modified) } }) {
            return staged.contains { touches(indexSpan(of: ranges, unstaged: unstaged), $0.modified) } ? .partial : .unstaged
        }
        guard let head else { return .staged }
        return head.contains(where: { change in ranges.contains { touches($0, change.modified) } }) ? .staged : .committed
    }

    /// The index lines a span of working-tree lines (`ranges`, in order) covers, given the
    /// index → working tree changes (`unstaged`): lines past earlier unstaged changes shift by
    /// what those changes added; a boundary inside one widens to its index lines.
    public static func indexSpan(of ranges: [Range<Int>], unstaged: [LineRangeMapping]) -> Range<Int> {
        guard let first = ranges.first, let last = ranges.last else { return 0..<0 }
        func indexLine(_ line: Int, upper: Bool) -> Int {
            var shift = 0
            for change in unstaged {
                let span = change.modified
                if span.isEmpty {
                    // Index lines the working tree dropped: inside the span when they sit at its start.
                    if span.lowerBound < line || (span.lowerBound == line && upper) {
                        shift += change.original.count
                        continue
                    }
                    if span.lowerBound == line { return change.original.lowerBound }
                    break
                }
                if span.upperBound <= line {
                    shift += change.original.count - span.count
                    continue
                }
                if span.lowerBound < line { return upper ? change.original.upperBound : change.original.lowerBound }
                break
            }
            return line + shift
        }
        let start = indexLine(first.lowerBound, upper: false)
        return start..<max(start, indexLine(last.upperBound, upper: true))
    }
}

/// FNV-1a, 64 bits: a hash that is the same in every process (Swift's `Hasher` is seeded per
/// launch), for ids and fingerprints stored in props.
struct StableHash {
    private var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func add(_ text: String) {
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value &*= 0x0000_0100_0000_01b3
        }
    }

    var hex: String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}

public enum ChangeStatus: String, Sendable, Equatable {
    case added, modified, deleted, renamed
}

/// One changed file: both sides' text (the base version, the working tree), the hunks between
/// them, and its highlighting once `ChangeSet.highlight` ran.
public struct ChangedFile: Sendable {
    /// Relative to the repository's top level (what git names it).
    public var path: String
    /// A renamed file's name in the base.
    public var oldPath: String?
    /// `path` as the board names it: relative to the board root when under it, else absolute.
    public var boardPath: String
    public var oldBoardPath: String?
    public var status: ChangeStatus
    public var old: SideText
    public var new: SideText
    /// Git file modes (`100644`, `100755`); nil where the side has no file.
    public var oldMode: String?
    public var newMode: String?
    /// In the index (false for untracked files).
    public var tracked: Bool
    public var hunks: [ChangeHunk]
    /// Why there are no hunks to show (binary, too large, a submodule, only the mode changed).
    public var notice: String?
    /// The two sides' blob ids when the diff compares commits (`ChangesSpec.head`): nil where
    /// that side has no file. Nil for a worktree's diff.
    public var blobs: Blobs?
    public struct Blobs: Equatable, Sendable {
        public var old: String?
        public var new: String?
    }
    public var oldSyntax = SyntaxLines.empty
    public var newSyntax = SyntaxLines.empty
    public var oldSymbols: [SyntaxSymbol] = []
    public var newSymbols: [SyntaxSymbol] = []

    public var added: Int { hunks.reduce(0) { $0 + $1.added } }
    public var removed: Int { hunks.reduce(0) { $0 + $1.removed } }

    /// A hunk's changes a patch can carry: all of them for a created or deleted file (one hunk).
    public var mappings: [LineRangeMapping] { hunks.flatMap(\.mappings) }

    /// Read from git objects (two commits compared): nothing of it is the reviewer's to stage,
    /// unstage, or discard.
    public var readOnly: Bool { blobs != nil }

    /// What the file header's buttons offer (a binary, oversized, or mode-only file has no lines
    /// to patch): Stage while some of it isn't staged, Unstage once all of that is (Stage's
    /// place), Discard while some of it isn't committed (`HunkStatus.discardable`); none when
    /// `readOnly`.
    public var stageable: Bool { !readOnly && notice == nil && (hunks.isEmpty || hunks.contains { $0.status.stageable }) }
    public var unstageable: Bool { !readOnly && notice == nil && !stageable && hunks.contains { $0.status.unstageable } }
    public var discardable: Bool { !readOnly && notice == nil && (hunks.isEmpty || hunks.contains { $0.status.discardable }) }

    /// What `props.viewed` records for the file: its diff as the user saw it (hunk ids,
    /// status, notice), so an entry stops counting once the diff changes. Between commits, the
    /// two sides' blob ids: the same while neither side's file changes, wherever the head moves.
    public var fingerprint: String {
        var hash = StableHash()
        hash.add(boardPath + "\u{0}" + status.rawValue + "\u{0}" + (notice ?? ""))
        if let blobs {
            hash.add("\u{0}" + (oldBoardPath ?? "") + "\u{0}" + (blobs.old ?? "-") + "\u{0}" + (blobs.new ?? "-"))
        } else {
            for hunk in hunks { hash.add("\u{0}" + hunk.id) }
        }
        return hash.hex
    }

    /// Marked Viewed in `viewed` (`props.viewed`: board path → fingerprint) for this very diff.
    public func isViewed(in viewed: JSONValue?) -> Bool {
        viewed?[boardPath]?.string == fingerprint
    }

    /// The innermost declaration around lines of one side (`innermost(around:)`).
    public func symbol(lines: LineRange, side: DiffSide) -> String? {
        (side == .old ? oldSymbols : newSymbols).innermost(around: lines)
    }
}

/// What a changes tile shows: every file that differs between the base and the working tree
/// (untracked files as added) under its paths, with hunks and their index status; or, comparing
/// two commits (`ChangesSpec.head`), every file that differs between them. Loaded by `load`,
/// all git through `GitDiffEngine` and `GitRunner`, off the main thread.
public struct ChangeSet: Sendable {
    public var repository: URL?
    /// Full SHA of the base; nil when there is none (see `notice`).
    public var base: String?
    /// How the base was chosen (`HEAD`, `merge-base with main`, the commit as written).
    public var baseLabel: String
    public var files: [ChangedFile]
    /// Why nothing can be listed (not a repository, no commits, a path outside it).
    public var notice: String?
    /// Changed files past `maxFiles`, not loaded.
    public var omitted: Int
    /// Another worktree of the board's repository (`props.root`), named for the header: its
    /// directory (`PathLabel`) and branch, e.g. `wt-omp (feature)`. Nil for the board's own.
    public var worktree: String?
    /// Full SHA of the reviewed worktree's HEAD, or of the head commit compared; nil without commits.
    public var head: String?
    /// The branch checked out in the reviewed worktree (nil when detached), or the head as written.
    public var branch: String?
    /// Set when two commits are compared (`ChangesSpec.head`, or a `ref` no worktree has checked
    /// out): `base` is then the merge-base of `head` with the commit the base names.
    public var commits: Commits?
    public struct Commits: Equatable, Sendable {
        /// Full SHA of the commit the base names (`origin/main`'s tip), whose merge-base with
        /// the head is the diff's base.
        public var baseTip: String
        /// A `ref` that no longer resolves, read at the last commit the tile saw.
        public var gone: Gone?
    }

    public enum Gone: Equatable, Sendable {
        /// The default branch has it: brought in by this commit (the merge, or the head itself
        /// when fast-forwarded).
        case merged(String)
        /// Deleted without the default branch having it.
        case deleted

        /// How the header says it, as code tiles do (`RefSource.label`): `merged in 1a2b3c4`, `branch gone`.
        public var label: String {
            switch self {
            case .merged(let commit): "merged in \(commit.prefix(7))"
            case .deleted: "branch gone"
            }
        }
    }

    /// The commit a `ref` tile read (`GitRefs.Resolution.sha`), which the tile keeps in
    /// `props.refSha`; nil for other tiles.
    public var refSha: String?

    public init(repository: URL? = nil, base: String? = nil, baseLabel: String = "", files: [ChangedFile] = [], notice: String? = nil, omitted: Int = 0, worktree: String? = nil,
                head: String? = nil, branch: String? = nil, commits: Commits? = nil) {
        self.repository = repository
        self.base = base
        self.baseLabel = baseLabel
        self.files = files
        self.notice = notice
        self.omitted = omitted
        self.worktree = worktree
        self.head = head
        self.branch = branch
        self.commits = commits
    }

    /// Two commits compared, read from git objects: nothing to stage, unstage, or discard.
    public var comparesCommits: Bool { commits != nil }

    /// The base is another commit than HEAD (the branch's merge-base, a commit typed in), so the
    /// hunks include committed work: Discard only puts back what isn't committed
    /// (`ReviewPatch.discardUncommitted`).
    public var includesCommits: Bool { base != nil && base != head }

    /// Some file has something to stage, unstage, or discard: false for a review of commits
    /// only, where the tile is for reading (its header offers no staging).
    public var actionable: Bool { files.contains { $0.stageable || $0.unstageable || $0.discardable } }

    /// Files a tile loads at most; the rest are counted in `omitted`.
    public static let maxFiles = 300
    /// Sides longer than this aren't highlighted.
    static let maxHighlightLines = 20_000

    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }

    /// The header's lead, which names plainly what is compared with what (a click on it picks
    /// the base): `Uncommitted changes` against HEAD (another worktree's name first:
    /// `wt-omp (feature) · Uncommitted changes`), else `pr-1041 vs origin/main` (the branch, or
    /// `HEAD` when detached, against the base's name), with the two commits' short SHAs when
    /// comparing commits (`pr-1041 vs origin/main · 1a2b3c4..5d6e7f8`); or why nothing is listed.
    public var lead: String {
        let place = worktree.map { "\($0) · " } ?? ""
        if let notice { return place + notice }
        if let commits, let base, let head {
            let gone = commits.gone.map { " (\($0.label))" } ?? ""
            return "\(branch ?? "HEAD")\(gone) vs \(baseName) · \(base.prefix(7))..\(head.prefix(7))"
        }
        if base == nil || !includesCommits { return place + (files.isEmpty ? "No uncommitted changes" : "Uncommitted changes") }
        return "\(branch ?? "HEAD") vs \(baseName)"
    }

    /// The base as the header names it: `origin/main` for the merge-base with it, else the
    /// commit or ref as written (a full SHA shortened).
    public var baseName: String {
        if let branch = GitDiffEngine.ResolvedBase.mergeBaseBranch(baseLabel) { return branch }
        if baseLabel.count == 40, baseLabel.allSatisfy(\.isHexDigit) { return String(baseLabel.prefix(7)) }
        return baseLabel
    }

    /// What the header says after the lead: `6 files · +62 −0`, `no changes`, or nothing.
    public var counts: String {
        guard notice == nil, base != nil else { return "" }
        guard !files.isEmpty else { return includesCommits || comparesCommits ? "no changes" : "" }
        let count = files.count + omitted
        return "\(count) file\(count == 1 ? "" : "s") · +\(added) −\(removed)"
    }

    /// The header's summary: `Uncommitted changes · 3 files · +40 −12`,
    /// `pr-1041 vs origin/main · 6 files · +62 −0`.
    public var summary: String { counts.isEmpty ? lead : "\(lead) · \(counts)" }

    /// The summary's tooltip: what the base is exactly.
    public var baseDescription: String? {
        guard let base else { return nil }
        if let commits, let head {
            return "\(branch ?? head.prefix(7).description) at \(head.prefix(7)) against its merge-base \(base.prefix(7)) with \(baseName) (at \(commits.baseTip.prefix(7))): "
                + "read from git objects, nothing to stage or discard"
        }
        guard includesCommits else { return "Against HEAD \(base.prefix(7)): the work not committed yet, staged or not" }
        return "Against \(baseLabel) \(base.prefix(7)): the commits since it and the work not committed yet (Discard only puts back uncommitted work)"
    }

    // MARK: Loading

    /// The changes between `spec`'s base and the working tree of the repository containing
    /// `root` (the board root), or of `spec.root` when that is another worktree of it (anything
    /// else is refused), limited to `spec.paths` (else that directory). With `spec.head`, two
    /// commits compared instead (`loadCommits`). `spec.ref` is resolved by `GitRefs`: the
    /// worktree that has it checked out, else the commit it names (or, gone, the last one the
    /// tile saw, `spec.refSha`) against the base; `refSha` says which commit that was.
    /// `highlight` also parses both sides with tree-sitter (tiles; measuring and `object.get`
    /// don't need it).
    public static func load(root: URL, spec: ChangesSpec, highlight: Bool = true, engine: GitDiffEngine = .shared) async -> ChangeSet {
        if spec.head != nil, spec.ref != nil { return ChangeSet(notice: "give head or ref, not both") }
        if spec.ref != nil, spec.root != nil { return ChangeSet(notice: "give ref or root, not both") }
        if let head = spec.head { return await loadCommits(root: root, spec: spec, head: head, headName: head, highlight: highlight) }
        guard let ref = spec.ref else {
            let reviewed = spec.directory(boardRoot: root)
            if let prop = spec.root, !GitWorktree.sameRepository(reviewed.path, root.path) {
                return ChangeSet(notice: "\(prop) is not a worktree of this board's repository")
            }
            return await loadWorktree(root: root, reviewed: reviewed, spec: spec, highlight: highlight, engine: engine)
        }
        let resolution: GitRefs.Resolution
        do {
            resolution = try await GitRefs.resolve(repo: root, ref: ref, lastKnownSha: spec.refSha)
        } catch GitRefs.Failure.unknownRef(_) {
            return ChangeSet(notice: await missing(ref, in: GitDiffEngine.existingAncestor(of: root)), branch: ref)
        } catch GitRefs.Failure.notRevision(_) {
            return ChangeSet(notice: "not a ref: \(ref)", branch: ref)
        } catch {
            return ChangeSet(notice: "not in a git repository", branch: ref)
        }
        var set: ChangeSet
        switch resolution.state {
        case .live:
            // The board's own checkout reviews the board root (which may be a directory inside it).
            let own = GitWorktree.containing(root.path)?.gitDir
            let reviewed = resolution.worktree.flatMap { GitWorktree.containing($0.path)?.gitDir == own ? nil : $0 } ?? root
            set = await loadWorktree(root: root, reviewed: reviewed, spec: spec, highlight: highlight, engine: engine)
        case .objects:
            set = await loadCommits(root: root, spec: spec, head: resolution.sha, headName: ref, highlight: highlight)
        case .merged(let merge):
            set = await loadCommits(root: root, spec: spec, head: resolution.sha, headName: ref, gone: .merged(merge), highlight: highlight)
        case .missing:
            set = await loadCommits(root: root, spec: spec, head: resolution.sha, headName: ref, gone: .deleted, highlight: highlight)
        }
        set.refSha = resolution.sha
        return set
    }

    /// A worktree's changes: `reviewed` (the board root, or another worktree of its repository).
    private static func loadWorktree(root: URL, reviewed: URL, spec: ChangesSpec, highlight: Bool, engine: GitDiffEngine) async -> ChangeSet {
        var worktree: String?
        if let own = GitWorktree.containing(root.path), let other = GitWorktree.containing(reviewed.path), own.gitDir != other.gitDir {
            worktree = PathLabel.short(reviewed.path) == reviewed.path ? other.name : PathLabel.short(reviewed.path)
            if let branch = other.branch { worktree! += " (\(branch))" }
        }
        // Held while loading: the engine finds the repository and resolves the base once for
        // this listing and all its files.
        let probe = GitDiffEngine.existingAncestor(of: reviewed).appendingPathComponent(".canvas-changes")
        guard let held = await engine.retain(containing: probe) else {
            return ChangeSet(notice: "not in a git repository", worktree: worktree)
        }
        defer { Task { await engine.release(held) } }
        let toplevel = URL(fileURLWithPath: held)
        let specs: [String]
        do {
            specs = try pathspecs(spec.paths, root: reviewed, toplevel: toplevel)
        } catch {
            return ChangeSet(repository: toplevel, notice: error.message, worktree: worktree)
        }
        let branch = GitWorktree.containing(toplevel.path)?.branch
        let resolved = await engine.resolvedBase(for: probe, base: spec.base) ?? GitDiffEngine.ResolvedBase(sha: nil, label: "not in a git repository")
        guard let sha = resolved.sha else { return ChangeSet(repository: toplevel, baseLabel: resolved.label, notice: resolved.label, worktree: worktree, branch: branch) }
        let headSHA = spec.base == .head ? sha : await engine.resolvedBase(for: probe, base: .head)?.sha

        var entries: [Entry] = []
        if let raw = try? await GitRunner.shared.run(["--literal-pathspecs", "diff", "--raw", "-z", "-M", "--no-color", "--no-ext-diff", "--no-textconv", sha, "--"] + specs, in: toplevel) {
            entries = parseRaw(raw)
        }
        let listed = Set(entries.map(\.path))
        if let others = try? await GitRunner.shared.run(["--literal-pathspecs", "ls-files", "-z", "--others", "--exclude-standard", "--"] + specs, in: toplevel) {
            for record in others.split(separator: 0) {
                let path = String(decoding: record, as: UTF8.self)
                guard !listed.contains(path) else { continue }
                entries.append(Entry(status: .added, path: path, oldPath: nil, oldMode: nil, newMode: nil, tracked: false))
            }
        }
        entries.sort { $0.path < $1.path }
        let omitted = max(0, entries.count - maxFiles)
        let selected = Array(entries.prefix(maxFiles))
        guard !selected.isEmpty else { return ChangeSet(repository: toplevel, base: sha, baseLabel: resolved.label, worktree: worktree, head: headSHA, branch: branch) }

        // Index → working tree, HEAD → index, and HEAD → working tree for a base older than
        // HEAD: which hunks the index already holds, or part of.
        let paths = selected.map(\.path)
        let unstaged = await workingTreeChanges(against: nil, paths: paths, in: toplevel)
        let staged = headSHA == nil ? [:] : await workingTreeChanges(against: nil, cached: true, paths: paths, in: toplevel)
        var head: [String: [LineRangeMapping]]?
        if let headSHA, headSHA != sha { head = await workingTreeChanges(against: headSHA, paths: paths, in: toplevel) }
        let headChanges = head

        let files = await withTaskGroup(of: (Int, ChangedFile?).self) { group in
            for (index, entry) in selected.enumerated() {
                group.addTask {
                    let file = await Self.file(entry, base: sha, diffBase: spec.base, root: root, toplevel: toplevel, engine: engine,
                                               unstaged: unstaged[entry.path] ?? [], staged: staged[entry.path] ?? [], head: headChanges.map { $0[entry.path] ?? [] })
                    return (index, file)
                }
            }
            var found: [(Int, ChangedFile)] = []
            for await (index, file) in group { if let file { found.append((index, file)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let set = ChangeSet(repository: toplevel, base: sha, baseLabel: resolved.label, files: files, omitted: omitted, worktree: worktree, head: headSHA, branch: branch)
        return highlight ? await offPool { set.highlighted() } : set
    }

    /// Both sides of every file parsed with tree-sitter (highlighting and enclosing symbols).
    func highlighted() -> ChangeSet {
        var set = self
        for index in set.files.indices {
            let file = set.files[index]
            guard let language = SyntaxLanguage(path: file.path) else { continue }
            if file.new.lineCount > 0, file.new.lineCount <= Self.maxHighlightLines {
                let analysis = Syntax.analyze(file.new.text, language: language)
                set.files[index].newSyntax = SyntaxLines(analysis.spans, text: file.new)
                set.files[index].newSymbols = analysis.symbols
            }
            if file.old.lineCount > 0, file.old.lineCount <= Self.maxHighlightLines {
                let analysis = Syntax.analyze(file.old.text, language: SyntaxLanguage(path: file.oldPath ?? file.path) ?? language)
                set.files[index].oldSyntax = SyntaxLines(analysis.spans, text: file.old)
                set.files[index].oldSymbols = analysis.symbols
            }
        }
        return set
    }

    struct Entry: Equatable, Sendable {
        var status: ChangeStatus
        var path: String
        var oldPath: String?
        var oldMode: String?
        var newMode: String?
        var tracked: Bool
        /// The sides' object ids as `--raw` printed them (full with `--no-abbrev`); nil where the
        /// side has no file, or for the working tree (git prints zeros there).
        var oldBlob: String? = nil
        var newBlob: String? = nil
    }

    /// `git diff --raw -z` records: `:<old mode> <new mode> <old sha> <new sha> <status>\0<path>\0`,
    /// a rename or copy with its source path first. Unmerged and unknown entries are skipped.
    static func parseRaw(_ data: Data) -> [Entry] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var entries: [Entry] = []
        var index = 0
        while index < fields.count {
            let meta = fields[index]
            index += 1
            guard meta.hasPrefix(":") else { continue }
            let parts = meta.dropFirst().split(separator: " ")
            guard parts.count >= 5, let letter = parts[4].first else { continue }
            let oldMode = parts[0] == "000000" ? nil : String(parts[0])
            let newMode = parts[1] == "000000" ? nil : String(parts[1])
            func blob(_ id: Substring) -> String? { id.allSatisfy { $0 == "0" } ? nil : String(id) }
            let oldBlob = blob(parts[2]), newBlob = blob(parts[3])
            let twoPaths = letter == "R" || letter == "C"
            guard index + (twoPaths ? 1 : 0) < fields.count else { break }
            let first = fields[index]
            let second = twoPaths ? fields[index + 1] : nil
            index += twoPaths ? 2 : 1
            switch letter {
            case "A": entries.append(Entry(status: .added, path: first, oldPath: nil, oldMode: nil, newMode: newMode, tracked: true, newBlob: newBlob))
            case "D": entries.append(Entry(status: .deleted, path: first, oldPath: nil, oldMode: oldMode, newMode: nil, tracked: true, oldBlob: oldBlob))
            case "M", "T": entries.append(Entry(status: .modified, path: first, oldPath: nil, oldMode: oldMode, newMode: newMode, tracked: true, oldBlob: oldBlob, newBlob: newBlob))
            case "R": entries.append(Entry(status: .renamed, path: second ?? first, oldPath: first, oldMode: oldMode, newMode: newMode, tracked: true, oldBlob: oldBlob, newBlob: newBlob))
            case "C": entries.append(Entry(status: .added, path: second ?? first, oldPath: nil, oldMode: nil, newMode: newMode, tracked: true, newBlob: newBlob))
            default: continue
            }
        }
        return entries
    }

    /// Repository-relative pathspecs for `paths` (board-relative or absolute; none: the board
    /// root). Anything outside the repository is refused: a changes tile never reaches past it.
    static func pathspecs(_ paths: [String], root: URL, toplevel: URL) throws(ChangesFailure) -> [String] {
        let top = GitDiffEngine.realPath(toplevel).path
        func spec(_ path: String) throws(ChangesFailure) -> String {
            let absolute = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            let real = GitDiffEngine.realPath(absolute.standardizedFileURL).path
            if real == top { return "." }
            guard real.hasPrefix(top + "/") else { throw ChangesFailure("\(path) is outside the repository \(top)") }
            return String(real.dropFirst(top.count + 1))
        }
        return paths.isEmpty ? [try spec(root.path)] : try paths.map(spec)
    }

    /// `-U0` changes per path between the index (`against` nil) or a commit and the working
    /// tree, in working-tree lines; `cached`: between HEAD and the index, in index lines.
    static func workingTreeChanges(against commit: String?, cached: Bool = false, paths: [String], in toplevel: URL) async -> [String: [LineRangeMapping]] {
        let args = GitDiffEngine.changeRecords + (cached ? ["--cached"] : []) + (commit.map { [$0] } ?? []) + ["--"] + paths
        guard let output = try? await GitRunner.shared.run(args, in: toplevel, maxOutput: 64 << 20) else { return [:] }
        return await offPool {
            GitDiffEngine.split(output).mapValues { UnifiedDiff.parse($0).mappings }
        }
    }

    private static func file(_ entry: Entry, base sha: String, diffBase: DiffBase, root: URL, toplevel: URL, engine: GitDiffEngine,
                             unstaged: [LineRangeMapping], staged: [LineRangeMapping], head: [LineRangeMapping]?) async -> ChangedFile? {
        let url = toplevel.appendingPathComponent(entry.path)
        let diff: FileDiff
        if entry.status == .renamed, let oldPath = entry.oldPath {
            diff = await renamed(from: oldPath, to: entry.path, base: sha, in: toplevel, engine: engine)
        } else {
            diff = await engine.diff(file: url, base: diffBase, held: toplevel.path)
        }
        return changed(entry, diff: diff, workingMode: Self.mode(of: url), unstaged: unstaged, staged: staged, head: head) {
            Board.relativePath(toplevel.appendingPathComponent($0).path, root: root)
        }
    }

    static func changed(_ entry: Entry, diff: FileDiff, workingMode: @autoclosure () -> String?, unstaged: [LineRangeMapping], staged: [LineRangeMapping],
                        head: [LineRangeMapping]?, boardPath: (String) -> String) -> ChangedFile? {
        var notice: String?
        var status = entry.status
        switch diff.state {
        case .modified: break
        case .added: status = .added
        case .deleted: status = .deleted
        case .unchanged: notice = entry.status == .renamed ? nil : "mode changed"
        case .binary: notice = "binary file"
        case .tooLarge, .diffTooLarge: notice = "too large to show"
        case .submodule: notice = "submodule"
        case .unstable: notice = "kept changing while diffing; waiting for the next write"
        case .missing, .ignored: return nil
        case .notRepository, .noBase, .pinned, .pinUnavailable, .unreadable: notice = diff.baseLabel ?? "not comparable"
        }
        let newMode = entry.newMode ?? (status == .deleted ? nil : workingMode())
        var ids: Set<String> = []
        let hunks: [ChangeHunk] = notice == nil ? diff.hunks.map { hunk -> ChangeHunk in
            var change = ChangeHunk(mappings: hunk.mappings, old: diff.old, new: diff.new,
                                    status: ChangeHunk.status(of: hunk.mappings, tracked: entry.tracked, unstaged: unstaged, staged: staged, head: head))
            let id = ChangeHunk.identity(path: entry.path, unified: change.unified(old: diff.old, new: diff.new))
            // Two identical hunks in one file: the later ones numbered.
            var unique = id, count = 1
            while ids.contains(unique) {
                count += 1
                unique = "\(id)-\(count)"
            }
            ids.insert(unique)
            change.id = unique
            return change
        } : []
        return ChangedFile(path: entry.path, oldPath: entry.oldPath, boardPath: boardPath(entry.path), oldBoardPath: entry.oldPath.map(boardPath),
                           status: status, old: diff.old, new: diff.new, oldMode: status == .added ? nil : entry.oldMode ?? "100644", newMode: newMode,
                           tracked: entry.tracked, hunks: hunks, notice: notice)
    }

    static let renameRecords = ["--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "-M", "--diff-algorithm=histogram",
                                "-U0", "--inter-hunk-context=0"]

    /// A file renamed since the base: `oldPath`'s base text against the working tree's `path`.
    private static func renamed(from oldPath: String, to path: String, base sha: String, in toplevel: URL, engine: GitDiffEngine) async -> FileDiff {
        let url = toplevel.appendingPathComponent(path)
        guard let old = await engine.text(of: toplevel.appendingPathComponent(oldPath), at: sha),
              let data = await offPool({ try? Data(contentsOf: url) }) else {
            return await renamedDiff(old: nil, data: nil, patch: nil, base: sha, toplevel: toplevel.path)
        }
        let patch = try? await GitRunner.shared.run(renameRecords + [sha, "--", oldPath, path], in: toplevel, maxOutput: 3 * GitDiffEngine.maxFileSize)
        return await renamedDiff(old: old, data: data, patch: patch, base: sha, toplevel: toplevel.path)
    }

    static func renamedDiff(old: SideText?, data: Data?, patch: Data?, base sha: String, toplevel: String?) async -> FileDiff {
        guard let old, let data else { return FileDiff(state: .missing, base: sha, baseLabel: nil, old: SideText(""), new: SideText(""), hunks: []) }
        let new = await offPool { SideText(String(decoding: data, as: UTF8.self)) }
        guard let patch else { return FileDiff(state: .tooLarge, base: sha, baseLabel: nil, old: old, new: new, hunks: []) }
        let parsed = await offPool { UnifiedDiff.parse(patch) }
        if parsed.binary { return FileDiff(state: .binary, base: sha, baseLabel: nil, old: old, new: new, hunks: []) }
        let state: FileDiff.State = parsed.mappings.isEmpty ? .unchanged : .modified
        return FileDiff(state: state, base: sha, baseLabel: nil, old: old, new: new, hunks: UnifiedDiff.hunks(parsed.mappings), repository: toplevel)
    }

    /// The git mode of a working-tree file: executable or not.
    static func mode(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        return permissions & 0o111 != 0 ? "100755" : "100644"
    }

    // MARK: Summary

    /// What `object.get` adds for a changes tile: the files and their hunks, board-relative,
    /// with each file's Viewed mark from `viewed` (`props.viewed`); comparing commits, the head
    /// commit, the base's tip, and `readOnly`.
    public func json(viewed: JSONValue? = nil) -> JSONValue {
        var result: [String: JSONValue] = [
            "base": base.map(JSONValue.string) ?? .null,
            "baseLabel": .string(baseLabel),
            "added": .number(Double(added)),
            "removed": .number(Double(removed)),
            "files": .array(files.map { $0.json(viewed: viewed) }),
        ]
        if let repository { result["repository"] = .string(repository.path) }
        if let notice { result["notice"] = .string(notice) }
        if omitted > 0 { result["omitted"] = .number(Double(omitted)) }
        if let commits {
            result["head"] = head.map(JSONValue.string) ?? .null
            result["headLabel"] = branch.map(JSONValue.string) ?? .null
            result["baseTip"] = .string(commits.baseTip)
            result["readOnly"] = .bool(true)
            if let gone = commits.gone { result["refState"] = .string(gone.label) }
        }
        if let refSha { result["refSha"] = .string(refSha) }
        return .object(result)
    }

    /// Unified lines `object.get` gives per hunk at most; `truncated` says there were more.
    public static let maxJSONLines = 200
}

extension ChangedFile {
    public func json(viewed: JSONValue? = nil) -> JSONValue {
        var result: [String: JSONValue] = [
            "path": .string(boardPath),
            "status": .string(status.rawValue),
            "added": .number(Double(added)),
            "removed": .number(Double(removed)),
            "hunks": .array(hunks.map { hunk in
                var entry: [String: JSONValue] = [
                    "id": .string(hunk.id),
                    "header": .string(hunk.header),
                    "old": .object(["start": .number(Double(hunk.oldStart)), "count": .number(Double(hunk.oldCount))]),
                    "new": .object(["start": .number(Double(hunk.newStart)), "count": .number(Double(hunk.newCount))]),
                    "added": .number(Double(hunk.added)),
                    "removed": .number(Double(hunk.removed)),
                    "status": .string(hunk.status.rawValue),
                    "lines": .array(hunk.unified(old: old, new: new, limit: ChangeSet.maxJSONLines).map(JSONValue.string)),
                ]
                if hunk.lines.count > ChangeSet.maxJSONLines { entry["truncated"] = .bool(true) }
                return .object(entry)
            }),
        ]
        if let oldBoardPath { result["oldPath"] = .string(oldBoardPath) }
        if let notice { result["notice"] = .string(notice) }
        if isViewed(in: viewed) { result["viewed"] = .bool(true) }
        return .object(result)
    }
}

public struct ChangesFailure: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }

    /// Discard asked of committed work: a review never rewrites the commits it reads.
    public static let committed = ChangesFailure("committed: Discard only puts back work not committed yet")
    /// Stage, Unstage, or Discard asked of two commits compared: nothing there is a worktree's.
    public static let readOnly = ChangesFailure("read-only: this tile compares two commits; there is nothing to stage, unstage, or discard")
}
