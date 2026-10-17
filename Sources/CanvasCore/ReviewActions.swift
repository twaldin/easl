import Foundation

/// A changes tile's Revert and Stage (docs/contracts.md, Changes tiles): one unified patch
/// applied with `git apply` to the working tree or the index. Applying the same patch the other
/// way round is the undo, so every action is exactly reversible while the lines it touched are
/// as it left them; a patch that no longer applies is refused, never forced.
public struct ReviewPatch: Equatable, Sendable {
    public enum Target: String, Sendable { case worktree, index }

    /// Where git applies it: a repository's top level on this Mac, or on a remote board's host
    /// (`HostGit.apply`), whose path is never a directory here. The patch names paths relative to it.
    public enum Checkout: Equatable, Sendable {
        case local(URL)
        case host(String)
    }

    public var checkout: Checkout
    public var text: String
    public var target: Target
    /// Applied reversed (`git apply -R`): a revert applies the base → working tree patch reversed.
    public var reverse: Bool

    public init(checkout: Checkout, text: String, target: Target, reverse: Bool) {
        self.checkout = checkout
        self.text = text
        self.target = target
        self.reverse = reverse
    }

    public init(repository: URL, text: String, target: Target, reverse: Bool) {
        self.init(checkout: .local(repository), text: text, target: target, reverse: reverse)
    }

    /// The same change undone.
    public var inverse: ReviewPatch {
        var patch = self
        patch.reverse.toggle()
        return patch
    }

    public var arguments: [String] {
        ["apply", "--whitespace=nowarn"] + (target == .index ? ["--cached"] : []) + (reverse ? ["-R"] : []) + ["-"]
    }

    /// Changed lines a patch keeps when only part of a hunk is picked: removed lines by their
    /// old-side number, added lines by their new-side number.
    public struct LinePick: Equatable, Sendable {
        public var removed: Set<Int>
        public var added: Set<Int>

        public init(removed: Set<Int>, added: Set<Int>) {
            self.removed = removed
            self.added = added
        }
    }

    /// A unified patch turning `old` into `new` over `mappings` for `path` (repository-relative),
    /// with `context` lines around each hunk. `old` nil creates the file, `new` nil deletes it;
    /// modes only appear in those headers. Lines keep their own endings (CRLF too), and a last
    /// line without one gets git's `\ No newline at end of file`.
    ///
    /// `pick`: only those changed lines. Within each change (its removed lines, then its added
    /// ones) the n-th removed and n-th added line are a pair and stay together, so picking one
    /// replacement of several keeps the others in place. Applied forward (`reverse` false: the
    /// target holds `old`), an unpicked removed line becomes context and an unpicked added line
    /// is dropped; applied reversed (the target holds `new`), an unpicked added line becomes
    /// context and an unpicked removed line is dropped. Either way unpicked lines stay as the
    /// target has them, as `git add -p` edits a hunk. Headers are recounted; a hunk left with no
    /// change is dropped, and a patch left with none is empty.
    public static func text(path: String, old: SideText?, new: SideText?, oldMode: String? = nil, newMode: String? = nil,
                            mappings: [LineRangeMapping], context: Int = 3, pick: LinePick? = nil, reverse: Bool = false) -> String {
        let a = quoted("a/" + path), b = quoted("b/" + path)
        var out = "diff --git \(a) \(b)\n"
        if old == nil, pick == nil || !reverse {
            out += "new file mode \(newMode ?? "100644")\n--- /dev/null\n+++ \(b)\n"
        } else if new == nil, pick == nil || reverse {
            out += "deleted file mode \(oldMode ?? "100644")\n--- \(a)\n+++ /dev/null\n"
        } else {
            out += "--- \(a)\n+++ \(b)\n"
        }
        let oldText = old ?? SideText(""), newText = new ?? SideText("")
        guard let pick else {
            for hunk in UnifiedDiff.hunks(mappings, context: context) {
                let change = ChangeHunk(mappings: hunk.mappings, old: oldText, new: newText, context: context)
                out += change.header + "\n"
                for line in change.lines {
                    switch line.kind {
                    case .context: out += " " + raw(newText, line.new!)
                    case .removed: out += "-" + raw(oldText, line.old!)
                    case .added: out += "+" + raw(newText, line.new!)
                    }
                }
            }
            return out
        }
        // What applying the earlier hunks adds to the side the target doesn't hold.
        var delta = 0
        var any = false
        for hunk in UnifiedDiff.hunks(mappings, context: context) {
            let change = ChangeHunk(mappings: hunk.mappings, old: oldText, new: newText, context: context)
            var body = ""
            var kept = (context: 0, removed: 0, added: 0)
            let lines = change.lines
            var index = 0
            while index < lines.count {
                if lines[index].kind == .context {
                    body += " " + raw(newText, lines[index].new!)
                    kept.context += 1
                    index += 1
                    continue
                }
                var removed: [Int] = [], added: [Int] = []
                while index < lines.count, lines[index].kind == .removed {
                    removed.append(lines[index].old!)
                    index += 1
                }
                while index < lines.count, lines[index].kind == .added {
                    added.append(lines[index].new!)
                    index += 1
                }
                for pair in 0..<max(removed.count, added.count) {
                    if pair < removed.count {
                        if pick.removed.contains(removed[pair]) {
                            body += "-" + raw(oldText, removed[pair])
                            kept.removed += 1
                        } else if !reverse {
                            body += " " + raw(oldText, removed[pair])
                            kept.context += 1
                        }
                    }
                    if pair < added.count {
                        if pick.added.contains(added[pair]) {
                            body += "+" + raw(newText, added[pair])
                            kept.added += 1
                        } else if reverse {
                            body += " " + raw(newText, added[pair])
                            kept.context += 1
                        }
                    }
                }
            }
            guard kept.removed + kept.added > 0 else { continue }
            any = true
            let oldCount = kept.context + kept.removed, newCount = kept.context + kept.added
            let oldStart: Int, newStart: Int
            if reverse {
                newStart = change.newStart
                let first = (change.newCount == 0 ? change.newStart + 1 : change.newStart) - delta
                oldStart = oldCount == 0 ? first - 1 : first
            } else {
                oldStart = change.oldStart
                let first = (change.oldCount == 0 ? change.oldStart + 1 : change.oldStart) + delta
                newStart = newCount == 0 ? first - 1 : first
            }
            delta += kept.added - kept.removed
            func span(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
            out += "@@ -\(span(oldStart, oldCount)) +\(span(newStart, newCount)) @@\n" + body
        }
        return any ? out : ""
    }

    /// A line with its own line break, or with git's no-newline marker when it has none.
    static func raw(_ text: SideText, _ line: Int) -> String {
        let start = text.lineStarts[line - 1]
        let end = line < text.lineCount ? text.lineStarts[line] : text.utf16Count
        let slice = (text.text as NSString).substring(with: NSRange(location: start, length: end - start))
        // By UTF-16 unit: "\r\n" is one Character, which never `hasSuffix("\n")`.
        return slice.utf16.last == 0x0A ? slice : slice + "\n\\ No newline at end of file\n"
    }

    /// A patch header path, C-quoted as git writes names with quotes, backslashes, or control
    /// characters.
    static func quoted(_ path: String) -> String {
        guard path.unicodeScalars.contains(where: { $0 == "\"" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }) else { return path }
        var out = "\""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\%03o", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: Actions

    /// Revert: the hunks' changes discarded from the working tree (the base's lines put back),
    /// as the base → working tree patch of `file` applied reversed. All hunks of a created or
    /// deleted file are the file (deleted again, or brought back). A renamed file keeps its name.
    /// `lines`: only those rows (indices into the one hunk's `lines`) of the hunk.
    public static func revert(_ hunks: [ChangeHunk], of file: ChangedFile, in repository: URL, lines: Set<Int>? = nil) throws -> ReviewPatch {
        try revert(hunks, of: file, checkout: .local(repository), lines: lines)
    }

    /// `revert` of a remote board's file, applied on its host in `toplevel`.
    public static func revert(_ hunks: [ChangeHunk], of file: ChangedFile, onHost toplevel: String, lines: Set<Int>? = nil) throws -> ReviewPatch {
        try revert(hunks, of: file, checkout: .host(toplevel), lines: lines)
    }

    private static func revert(_ hunks: [ChangeHunk], of file: ChangedFile, checkout: Checkout, lines: Set<Int>?) throws -> ReviewPatch {
        if file.readOnly { throw ChangesFailure.readOnly }
        try checkPath(file.path)
        guard hunks.isEmpty || hunks.contains(where: \.status.discardable) else { throw ChangesFailure.committed }
        let mappings = file.status == .added || file.status == .deleted ? file.mappings : hunks.flatMap(\.mappings)
        guard !mappings.isEmpty || file.status == .added || file.status == .deleted else { throw ChangesFailure("nothing to revert in \(file.boardPath)") }
        let pick = try lines.map { try Self.pick($0, of: hunks) }
        let text = text(path: file.path, old: file.status == .added ? nil : file.old, new: file.status == .deleted ? nil : file.new,
                        oldMode: file.oldMode, newMode: file.newMode, mappings: mappings, pick: pick, reverse: true)
        guard !text.isEmpty else { throw ChangesFailure("no changed line selected") }
        return ReviewPatch(checkout: checkout, text: text, target: .worktree, reverse: true)
    }

    /// The changed lines among `rows` (indices into the one hunk's `lines`), by side.
    static func pick(_ rows: Set<Int>, of hunks: [ChangeHunk]) throws -> LinePick {
        guard hunks.count == 1, let hunk = hunks.first else { throw ChangesFailure("lines are picked within one hunk") }
        var pick = LinePick(removed: [], added: [])
        for index in rows where hunk.lines.indices.contains(index) {
            let line = hunk.lines[index]
            switch line.kind {
            case .removed: pick.removed.insert(line.old!)
            case .added: pick.added.insert(line.new!)
            case .context: break
            }
        }
        guard !pick.removed.isEmpty || !pick.added.isEmpty else { throw ChangesFailure("no changed line selected") }
        return pick
    }

    /// Stage: the index takes the working tree's lines where `file` changes over `hunks` (nil:
    /// the whole file), whatever base the tile compares with. Built from the index and the
    /// working tree as they are now: an untracked file is added whole, a deleted one removed.
    /// `lines`: only those rows (indices into the one hunk's `lines`): added lines by their
    /// working-tree line, removed ones by the index line with the same text in the change there.
    public static func stage(_ hunks: [ChangeHunk]?, of file: ChangedFile, in repository: URL, lines: Set<Int>? = nil) async throws -> ReviewPatch {
        try await stage(hunks, of: file, reading: reads(file, in: repository), checkout: .local(repository), lines: lines)
    }

    /// `stage` of a remote board's file from the sides its listing read (`sides`), applied on its
    /// host in `toplevel` only while those sides are still what the host has (`HostGit.apply`).
    public static func stage(_ hunks: [ChangeHunk]?, of file: ChangedFile, sides: ReviewSides, onHost toplevel: String, lines: Set<Int>? = nil) async throws -> ReviewPatch {
        try await stage(hunks, of: file, reading: reads(sides), checkout: .host(toplevel), lines: lines)
    }

    private static func stage(_ hunks: [ChangeHunk]?, of file: ChangedFile, reading: Reads, checkout: Checkout, lines: Set<Int>?) async throws -> ReviewPatch {
        if file.readOnly { throw ChangesFailure.readOnly }
        let text = try await towardWorkingTree(hunks, of: file, from: .index, reading: reading, lines: lines, reverse: false)
        guard !text.isEmpty else { throw ChangesFailure("already staged") }
        return ReviewPatch(checkout: checkout, text: text, target: .index, reverse: false)
    }

    /// Discard against a base older than HEAD (`ChangeSet.includesCommits`): only the work not
    /// committed yet goes, the working tree put back to HEAD where `file` changes over `hunks`
    /// (nil: the whole file), so a review never rewrites the commits it reads. Built like Stage,
    /// from HEAD and the working tree as they are now (an untracked file is deleted, a file
    /// deleted since HEAD comes back), and refused when the working tree is no longer what the
    /// tile shows or nothing of it is uncommitted. `lines`: only those rows of the one hunk.
    public static func discardUncommitted(_ hunks: [ChangeHunk]?, of file: ChangedFile, in repository: URL, lines: Set<Int>? = nil) async throws -> ReviewPatch {
        try await discardUncommitted(hunks, of: file, reading: reads(file, in: repository), checkout: .local(repository), lines: lines)
    }

    /// `discardUncommitted` of a remote board's file from the sides its listing read, applied on
    /// its host in `toplevel` only while they are still what the host has.
    public static func discardUncommitted(_ hunks: [ChangeHunk]?, of file: ChangedFile, sides: ReviewSides, onHost toplevel: String, lines: Set<Int>? = nil) async throws -> ReviewPatch {
        try await discardUncommitted(hunks, of: file, reading: reads(sides), checkout: .host(toplevel), lines: lines)
    }

    private static func discardUncommitted(_ hunks: [ChangeHunk]?, of file: ChangedFile, reading: Reads, checkout: Checkout, lines: Set<Int>?) async throws -> ReviewPatch {
        if file.readOnly { throw ChangesFailure.readOnly }
        if let hunks, !hunks.contains(where: \.status.discardable) { throw ChangesFailure.committed }
        let text = try await towardWorkingTree(hunks, of: file, from: .head, reading: reading, lines: lines, reverse: true, expected: file.status == .deleted ? nil : file.new)
        guard !text.isEmpty else { throw ChangesFailure("nothing uncommitted to discard in \(file.boardPath)") }
        return ReviewPatch(checkout: checkout, text: text, target: .worktree, reverse: true)
    }

    /// Unstage: the index goes back to HEAD where it holds `file`'s changes over `hunks` (nil:
    /// the whole file), as `git restore --staged -p` would, leaving the working tree alone: the
    /// HEAD → index patch of those changes applied reversed to the index (a file new in the index
    /// leaves it, a deletion staged is taken back). `lines`: only those rows of the one hunk, by
    /// their text in the staged change. Refused when nothing there is staged.
    public static func unstage(_ hunks: [ChangeHunk]?, of file: ChangedFile, in repository: URL, lines: Set<Int>? = nil) async throws -> ReviewPatch {
        try await unstage(hunks, of: file, reading: reads(file, in: repository), checkout: .local(repository), lines: lines)
    }

    /// `unstage` of a remote board's file from the sides its listing read, applied on its host in
    /// `toplevel` only while they are still what the host has.
    public static func unstage(_ hunks: [ChangeHunk]?, of file: ChangedFile, sides: ReviewSides, onHost toplevel: String, lines: Set<Int>? = nil) async throws -> ReviewPatch {
        try await unstage(hunks, of: file, reading: reads(sides), checkout: .host(toplevel), lines: lines)
    }

    private static func unstage(_ hunks: [ChangeHunk]?, of file: ChangedFile, reading: Reads, checkout: Checkout, lines: Set<Int>?) async throws -> ReviewPatch {
        if file.readOnly { throw ChangesFailure.readOnly }
        try checkPath(file.path)
        let picked = try lines.map { try Self.pick($0, of: hunks ?? []) }
        let head = try await reading.blob(.head)
        let index = try await reading.blob(.index)
        let text: String
        switch (head, index) {
        case (nil, nil):
            throw ChangesFailure("not staged")
        case (nil, let index?):
            text = Self.text(path: file.path, old: nil, new: index.text, newMode: index.mode, mappings: LineRangeMapping.whole(index.text),
                             pick: picked.map { LinePick(removed: [], added: matching(texts($0.added, of: file.new), among: Array(1..<index.text.lineCount + 1), in: index.text)) }, reverse: true)
        case (let head?, nil):
            text = Self.text(path: file.path, old: head.text, new: nil, oldMode: head.mode, mappings: LineRangeMapping.whole(head.text, removed: true),
                             pick: picked.map { LinePick(removed: matching(texts($0.removed, of: file.old), among: Array(1..<head.text.lineCount + 1), in: head.text), added: []) }, reverse: true)
        case (let head?, let index?):
            let staged = try await reading.changes(.head, .index)
            guard await offPool({ UnifiedDiff.reconstructOld(new: index.text, parsed: staged) }) == head.text else {
                throw ChangesFailure("\(file.boardPath) changed while unstaging; try again")
            }
            var selected = staged.mappings
            if let hunks {
                let unstaged = try await reading.changes(.index, .workingTree).mappings
                let span = ChangeHunk.indexSpan(of: hunks.flatMap { $0.mappings.map(\.modified) }, unstaged: unstaged)
                selected = selected.filter { ChangeHunk.touches(span, $0.modified) }
            }
            guard !selected.isEmpty else { throw ChangesFailure("not staged") }
            let pick = picked.map { picked in
                LinePick(removed: matching(texts(picked.removed, of: file.old), among: selected.flatMap { Array($0.original) }, in: head.text),
                         added: matching(texts(picked.added, of: file.new), among: selected.flatMap { Array($0.modified) }, in: index.text))
            }
            text = Self.text(path: file.path, old: head.text, new: index.text, mappings: selected, pick: pick, reverse: true)
        }
        guard !text.isEmpty else { throw ChangesFailure(lines == nil ? "not staged" : "none of the selected lines is staged") }
        return ReviewPatch(checkout: checkout, text: text, target: .index, reverse: true)
    }

    /// Where a file's text is read from.
    enum Side {
        case head, index, workingTree
    }

    struct Reads: Sendable {
        var blob: @Sendable (Side) async throws -> (text: SideText, mode: String)?
        var worktree: @Sendable () async -> SideText?
        var workingMode: @Sendable () -> String?
        var changes: @Sendable (Side, Side) async throws -> UnifiedDiff.Parsed
    }

    private static func reads(_ file: ChangedFile, in repository: URL) -> Reads {
        let url = repository.appendingPathComponent(file.path)
        return Reads(blob: { try await blob(file, at: $0, in: repository) },
                     worktree: { await offPool { (try? Data(contentsOf: url)).map { SideText(String(decoding: $0, as: UTF8.self)) } } },
                     workingMode: { ChangeSet.mode(of: url) },
                     changes: { try await changes(of: file, between: $0, and: $1, in: repository) })
    }

    private static func reads(_ sides: ReviewSides) -> Reads {
        Reads(blob: { side in
            switch side {
            case .head: return sides.head.map { (text: $0.text, mode: $0.mode) }
            case .index: return sides.index.map { (text: $0.text, mode: $0.mode) }
            case .workingTree: return nil
            }
        }, worktree: { sides.worktree?.text }, workingMode: { sides.worktree?.mode }, changes: { from, to in
            switch (from, to) {
            case (.head, .index): return sides.staged
            case (.head, _): return sides.againstHead
            default: return sides.unstaged
            }
        })
    }

    /// `file`'s text and git mode in HEAD or the index; nil where it has none (or there are no
    /// commits).
    private static func blob(_ file: ChangedFile, at side: Side, in repository: URL) async throws -> (text: SideText, mode: String)? {
        let listing: Data?
        switch side {
        case .head: listing = try? await GitRunner.shared.run(["--literal-pathspecs", "ls-tree", "-z", "HEAD", "--", file.path], in: repository)
        case .index: listing = try? await GitRunner.shared.run(["--literal-pathspecs", "ls-files", "-s", "-z", "--", file.path], in: repository)
        case .workingTree: return nil
        }
        guard let record = listing?.split(separator: 0).first, let mode = String(decoding: record, as: UTF8.self).split(separator: " ").first.map(String.init) else { return nil }
        guard let data = try? await GitRunner.shared.run(["cat-file", "blob", (side == .head ? "HEAD:" : ":") + file.path], in: repository, maxOutput: GitDiffEngine.maxFileSize) else {
            throw ChangesFailure("can't read \(file.boardPath) from \(side == .head ? "HEAD" : "the index")")
        }
        return (await offPool { SideText(String(decoding: data, as: UTF8.self)) }, mode)
    }

    /// `git diff -U0` of `file` from one side to another (HEAD → index, index or HEAD → working tree).
    private static func changes(of file: ChangedFile, between from: Side, and to: Side, in repository: URL) async throws -> UnifiedDiff.Parsed {
        let sides: [String] = switch (from, to) {
        case (.head, .index): ["--cached"]
        case (.head, _): ["HEAD"]
        default: []
        }
        let args = GitDiffEngine.changeRecords + sides + ["--", file.path]
        let patch = try await GitRunner.shared.run(args, in: repository, maxOutput: 3 * GitDiffEngine.maxFileSize)
        return await offPool { UnifiedDiff.parse(patch) }
    }

    /// The text of `lines` (in order) of `side`, where it has them.
    static func texts(_ lines: Set<Int>, of side: SideText) -> [String] {
        lines.sorted().filter { $0 >= 1 && $0 <= side.lineCount }.map(side.line)
    }

    /// Lines of `side` among `candidates` holding `texts`, in order, each line used once: where a
    /// picked line of the tile's diff sits in another version of the file.
    static func matching(_ texts: [String], among candidates: [Int], in side: SideText) -> Set<Int> {
        var found: Set<Int> = []
        for text in texts {
            if let match = candidates.first(where: { !found.contains($0) && $0 >= 1 && $0 <= side.lineCount && side.line($0) == text }) { found.insert(match) }
        }
        return found
    }

    /// The patch from `from`'s text of `file` (the index, or HEAD) to the working tree over the
    /// changes touching `hunks`' working-tree lines (nil: all of them), read now and checked
    /// against both texts (and against `expected`, the working tree the tile showed, when given),
    /// with only `lines` of the one hunk when picked (removed lines found by their text in the
    /// change there). `reverse`: how it will be applied (a discard), which decides what unpicked
    /// lines become.
    private static func towardWorkingTree(_ hunks: [ChangeHunk]?, of file: ChangedFile, from side: Side, reading: Reads, lines: Set<Int>?, reverse: Bool,
                                          expected: SideText? = nil) async throws -> String {
        try checkPath(file.path)
        let picked = try lines.map { try Self.pick($0, of: hunks ?? []) }
        let old = try await reading.blob(side)
        let worktree = await reading.worktree()
        if let expected, worktree != expected { throw ChangesFailure("\(file.boardPath) changed since the tile read it; try again") }
        if old == nil, side == .head, file.status == .renamed { throw ChangesFailure("\(file.boardPath) was renamed since HEAD; discard it against HEAD (Uncommitted changes)") }
        switch (old, worktree) {
        case (nil, nil):
            throw ChangesFailure("\(file.boardPath) is neither in \(side == .head ? "HEAD" : "the index") nor on disk")
        case (nil, let worktree?):
            return Self.text(path: file.path, old: nil, new: worktree, newMode: reading.workingMode(), mappings: LineRangeMapping.whole(worktree),
                             pick: picked.map { LinePick(removed: [], added: $0.added) }, reverse: reverse)
        case (let old?, nil):
            return Self.text(path: file.path, old: old.text, new: nil, oldMode: old.mode, mappings: LineRangeMapping.whole(old.text, removed: true),
                             pick: picked.map { LinePick(removed: matching(texts($0.removed, of: file.old), among: Array(1..<old.text.lineCount + 1), in: old.text), added: []) }, reverse: reverse)
        case (let old?, let worktree?):
            let parsed = try await reading.changes(side, .workingTree)
            // git read the file after we did: a patch that doesn't describe our text is stale.
            guard await offPool({ UnifiedDiff.reconstructOld(new: worktree, parsed: parsed) }) == old.text else {
                throw ChangesFailure("\(file.boardPath) changed meanwhile; try again")
            }
            let ranges = hunks?.flatMap { $0.mappings.map(\.modified) }
            let selected = ranges.map { ranges in parsed.mappings.filter { change in ranges.contains { ChangeHunk.touches($0, change.modified) } } } ?? parsed.mappings
            guard !selected.isEmpty else { return "" }
            var pick: LinePick?
            if let picked, let hunk = hunks?.first {
                var removed: Set<Int> = []
                for mapping in hunk.mappings {
                    let base = mapping.original.filter(picked.removed.contains)
                    guard !base.isEmpty else { continue }
                    let candidates = selected.filter { ChangeHunk.touches($0.modified, mapping.modified) }.flatMap { Array($0.original) }
                    removed.formUnion(matching(texts(Set(base), of: file.old), among: candidates, in: old.text))
                }
                pick = LinePick(removed: removed, added: picked.added)
            }
            return Self.text(path: file.path, old: old.text, new: worktree, mappings: selected, pick: pick, reverse: reverse)
        }
    }

    /// Patch lines a `props.reviewed` entry carries at most; `truncated` says there were more.
    public static let maxEntryLines = 200

    /// The `props.reviewed` entry for an applied action on `file` (`hunk` nil: all of it;
    /// `lines`: rows of the hunk picked): what, where (`hunk`: the hunk's stable id, `label`),
    /// how much, and the patch it applied (`patch`, as `git apply` took it; a revert's is the
    /// base → working tree diff applied reversed), capped.
    public static func entry(_ action: String, file: ChangedFile, hunk: ChangeHunk?, lines: Set<Int>?, patch: ReviewPatch) -> JSONValue {
        var entry: [String: JSONValue] = ["action": .string(action), "path": .string(file.boardPath),
                                          "scope": .string(hunk == nil ? "file" : lines == nil ? "hunk" : "lines"), "status": .string(file.status.rawValue)]
        if let hunk {
            entry["hunk"] = .string(hunk.id)
            entry["header"] = .string(hunk.header)
            entry["label"] = .string(hunk.label)
            let rows = lines.map { picked in hunk.lines.indices.filter(picked.contains).map { hunk.lines[$0] } } ?? hunk.lines
            entry["added"] = .number(Double(rows.filter { $0.kind == .added }.count))
            entry["removed"] = .number(Double(rows.filter { $0.kind == .removed }.count))
        } else {
            entry["added"] = .number(Double(file.added))
            entry["removed"] = .number(Double(file.removed))
        }
        let patchLines = patch.text.split(separator: "\n", omittingEmptySubsequences: false)
        let body = patchLines.last == "" ? patchLines.dropLast() : patchLines[...]
        entry["patch"] = .string(body.prefix(maxEntryLines).joined(separator: "\n") + "\n")
        if body.count > maxEntryLines { entry["truncated"] = .bool(true) }
        if patch.reverse { entry["applied"] = .string("reversed") }
        return .object(entry)
    }

    /// How undo names a `props.reviewed` entry: `Stage of src/a.rs` (the file), `Discard of
    /// src/a.rs, lines 15–46` (a hunk), `Unstage of 2 lines of src/a.rs` (picked lines).
    public static func name(of entry: JSONValue) -> String {
        let action: String
        switch entry["action"]?.string {
        case "stage": action = "Stage"
        case "unstage": action = "Unstage"
        case "revert": action = "Discard"
        case let other?: action = other.capitalized
        case nil: action = "Change"
        }
        return "\(action) of \(subject(of: entry))"
    }

    /// What a Discard just did, said where the user looks once it is done (nothing on the board
    /// shows files changing), in undo's words: `Discarded src/a.rs, lines 15–46 from your files
    /// · ⌘Z undoes`.
    public static func discardNotice(of entry: JSONValue) -> String {
        "Discarded \(subject(of: entry)) from your files · ⌘Z undoes"
    }

    /// A Discard on a remote board's host, which no ⌘Z here takes back: `Discarded src/a.rs,
    /// lines 15–46 on deckbox`. The patch stays in the tile's `props.reviewed`.
    public static func discardNotice(of entry: JSONValue, host: String) -> String {
        "Discarded \(subject(of: entry)) on \(host)"
    }

    /// What an entry acted on: `src/a.rs`, `src/a.rs, lines 15–46`, `2 lines of src/a.rs`.
    private static func subject(of entry: JSONValue) -> String {
        let path = entry["path"]?.string ?? "a file"
        switch entry["scope"]?.string {
        case "hunk":
            guard let label = entry["label"]?.string else { return path }
            return "\(path), \(label.prefix(1).lowercased() + label.dropFirst())"
        case "lines":
            let count = Int((entry["added"]?.number ?? 0) + (entry["removed"]?.number ?? 0))
            return "\(count) line\(count == 1 ? "" : "s") of \(path)"
        default:
            return path
        }
    }

    /// Patches only ever name files inside their repository.
    static func checkPath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(".."), !parts.contains(".git") else {
            throw ChangesFailure("refusing to patch \(path): outside the repository")
        }
    }
}

/// What a remote board's changes listing read of one file for Stage, Unstage, and Discard
/// (`HostGit.changes`): its HEAD and index blobs and its working-tree bytes, each with the id
/// its host compares again before applying a patch built from them (`HostGit.apply`), and the
/// `-U0` diffs between them. Nothing is read again here.
public struct ReviewSides: Sendable, Equatable {
    public struct Side: Sendable, Equatable {
        public var text: SideText
        public var mode: String
        /// The blob's object id; for the working tree, the SHA-256 of its bytes.
        public var id: String
    }

    public var head: Side?
    public var index: Side?
    public var worktree: Side?
    /// Index → working tree.
    public var unstaged: UnifiedDiff.Parsed
    /// HEAD → index.
    public var staged: UnifiedDiff.Parsed
    /// HEAD → working tree.
    public var againstHead: UnifiedDiff.Parsed
}

extension Notification.Name {
    /// Posted (object: the repository's top-level path) after a changes tile's patch applied,
    /// its undo and redo included: tiles showing that repository reload.
    public static let reviewPatchApplied = Notification.Name("canvas.reviewPatchApplied")
    /// Posted (object: the changes tile's id, userInfo `message`) when undoing or redoing a
    /// tile's action couldn't apply.
    public static let reviewPatchFailed = Notification.Name("canvas.reviewPatchFailed")
}

/// Applies review patches one at a time, in the order asked (an undo right after its action
/// waits for it), through `GitRunner`.
@MainActor
public final class ReviewGit {
    public static let shared = ReviewGit()

    private var tail: Task<Void, Never>?

    public init() {}

    /// Queues `patch` behind everything asked before it (at once, so an undo asked right after
    /// its action runs after it); the task answers why it didn't apply (the lines changed
    /// since, the index is locked), nil when it did.
    @discardableResult
    public func enqueue(_ patch: ReviewPatch) -> Task<ChangesFailure?, Never> {
        let previous = tail
        let work = Task<ChangesFailure?, Never> {
            await previous?.value
            guard case .local(let repository) = patch.checkout else { return ChangesFailure("this patch applies on its host, not on this Mac") }
            let failure: ChangesFailure?
            do {
                _ = try await GitRunner.shared.run(patch.arguments, in: repository, input: Data(patch.text.utf8))
                failure = nil
            } catch GitError.failed(_, let stderr) {
                failure = ChangesFailure(Self.reason(stderr))
            } catch {
                failure = ChangesFailure("git apply failed: \(error)")
            }
            if failure == nil { NotificationCenter.default.post(name: .reviewPatchApplied, object: repository.path) }
            return failure
        }
        tail = Task { _ = await work.value }
        return work
    }

    /// `enqueue`, throwing its refusal.
    public func apply(_ patch: ReviewPatch) async throws {
        if let failure = await enqueue(patch).value { throw failure }
    }

    /// Waits until every patch asked for so far has applied or failed.
    public func settled() async {
        await tail?.value
    }

    /// git's complaint, said for the user.
    nonisolated static func reason(_ stderr: String) -> String {
        if stderr.contains("index.lock") { return "the index is locked by another git process; try again" }
        if stderr.contains("patch does not apply") || stderr.contains("does not match index") || stderr.contains("already exists") || stderr.contains("does not exist") {
            return "no longer applies: the lines changed since"
        }
        return stderr.split(separator: "\n").first.map(String.init) ?? "git apply failed"
    }
}

extension Board {
    /// A changes tile fitted to its diff (`size: "fit"`) grown toward `size` to show it again once
    /// hunks were added (`ChangesTile`), into free space only (`grownFrame`: never over a
    /// neighbour, such as the terminal an agent types in below it; what doesn't fit scrolls). The
    /// app's own write-back, credited to the system, and not an undo step, so ⌘Z keeps undoing
    /// what someone did.
    public func growFitted(_ id: ObjectID, toward size: CGSize) {
        guard !history.isOpen, let frame = try? grownFrame(id, toward: size), frame != objects[id]?.frame else { return }
        history.replaying = true
        defer { history.replaying = false }
        _ = try? update(id, frame: frame, actor: .system)
    }

    /// Log entries a changes tile keeps in `props.reviewed`, newest last.
    public static let reviewedLimit = 100

    /// A review action the tile already applied (`patch`), recorded as one undo step with an
    /// entry in the tile's `props.reviewed`: ⌘Z applies the patch the other way round (a revert
    /// comes back, a stage leaves the index) and drops the entry; redo applies it again. When
    /// the lines moved on meanwhile, the undo is refused and `.reviewPatchFailed` says so. A
    /// patch applied on a remote board's host only logs the entry: no ⌘Z here reaches the host.
    public func recordReview(tile: ObjectID, entry: JSONValue, patch: ReviewPatch, git: ReviewGit = .shared) throws {
        let object = try object(tile)
        var reviewed = object.props["reviewed"]?.array ?? []
        reviewed.append(entry)
        if reviewed.count > Self.reviewedLimit { reviewed.removeFirst(reviewed.count - Self.reviewedLimit) }
        guard case .local = patch.checkout else {
            _ = try update(tile, props: .object(["reviewed": .array(reviewed)]))
            return
        }
        let what = [entry["action"]?.string, entry["path"]?.string, entry["header"]?.string].compactMap { $0 }.joined(separator: " ")
        transaction {
            _ = try? update(tile, props: .object(["reviewed": .array(reviewed)]))
            history.record(.effect(UndoEffect(name: ReviewPatch.name(of: entry), undo: { Self.replay(patch.inverse, "undo", what, tile: tile, git: git) },
                                              redo: { Self.replay(patch, "redo", what, tile: tile, git: git) })))
        }
    }

    /// Undo or redo of a recorded review action: the patch applied in the background, a refusal
    /// reported to the tile.
    private static func replay(_ patch: ReviewPatch, _ verb: String, _ what: String, tile: ObjectID, git: ReviewGit) {
        let work = git.enqueue(patch)
        Task { @MainActor in
            guard let failure = await work.value else { return }
            NotificationCenter.default.post(name: .reviewPatchFailed, object: tile, userInfo: ["message": "Couldn't \(verb) \(what): \(failure.message)"])
        }
    }
}
