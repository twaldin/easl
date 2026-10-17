import Foundation

/// One side of a diff: the full text and where each line starts (UTF-16 offsets), so lines and
/// syntax spans can be sliced without copying the text per line.
public struct SideText: Sendable, Equatable {
    public let text: String
    /// UTF-16 offset of each line's first character; `lineStarts.count` is the line count.
    public let lineStarts: [Int]
    /// UTF-16 offset where each line's content ends, before `\n` or `\r\n`.
    public let lineEnds: [Int]
    public let utf16Count: Int

    public init(_ text: String) {
        self.text = text
        var starts: [Int] = []
        var ends: [Int] = []
        var offset = 0
        var previous: UInt16 = 0
        for unit in text.utf16 {
            if starts.count == ends.count { starts.append(offset) }
            if unit == 0x0A { ends.append(previous == 0x0D ? offset - 1 : offset) }
            previous = unit
            offset += 1
        }
        if starts.count > ends.count { ends.append(offset) }
        lineStarts = starts
        lineEnds = ends
        utf16Count = offset
    }

    public var lineCount: Int { lineStarts.count }

    /// UTF-16 range of a 1-based line, without its line break.
    public func range(ofLine line: Int) -> NSRange {
        NSRange(location: lineStarts[line - 1], length: lineEnds[line - 1] - lineStarts[line - 1])
    }

    public func line(_ line: Int) -> String {
        (text as NSString).substring(with: range(ofLine: line))
    }

    /// 1-based line containing a UTF-16 offset.
    public func line(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }
}

/// VS Code-style change: 1-based, end-exclusive line ranges on each side. An empty range sits
/// before the line where the other side's lines were inserted or removed.
public struct LineRangeMapping: Equatable, Sendable {
    public var original: Range<Int>
    public var modified: Range<Int>

    public init(original: Range<Int>, modified: Range<Int>) {
        self.original = original
        self.modified = modified
    }

    /// Every line of `text` added (a file created), or removed (`removed`: a file deleted).
    public static func whole(_ text: SideText, removed: Bool = false) -> [LineRangeMapping] {
        guard text.lineCount > 0 else { return [] }
        let lines = 1..<text.lineCount + 1
        return [removed ? LineRangeMapping(original: lines, modified: 1..<1) : LineRangeMapping(original: 1..<1, modified: lines)]
    }
}

/// Changes close enough that `git diff -U3` would print them as one hunk.
public struct DiffHunk: Equatable, Sendable {
    public var mappings: [LineRangeMapping]

    public var original: Range<Int> { mappings.first!.original.lowerBound..<mappings.last!.original.upperBound }
    public var modified: Range<Int> { mappings.first!.modified.lowerBound..<mappings.last!.modified.upperBound }

    /// Whether every change in the hunk only removes lines (its new-side span, if any, is
    /// unchanged lines between deletions).
    public var removesOnly: Bool { mappings.allSatisfy(\.modified.isEmpty) }

    /// Lines a mention of the whole hunk refers to: the new side, or the old side when the hunk
    /// only removes lines.
    public var mentionLines: (side: DiffSide, lines: LineRange) {
        if removesOnly {
            return (.old, LineRange(start: original.lowerBound, end: max(original.lowerBound, original.upperBound - 1)))
        }
        return (.new, LineRange(start: modified.lowerBound, end: modified.upperBound - 1))
    }

    public var header: String {
        func span(_ range: Range<Int>) -> String {
            range.count == 1 ? "\(range.lowerBound)" : "\(range.isEmpty ? range.lowerBound - 1 : range.lowerBound),\(range.count)"
        }
        return "@@ -\(span(original)) +\(span(modified)) @@"
    }
}

public enum DiffSide: String, Sendable, Codable {
    case old, new
}

/// What the tile shows for a file: its diff against a resolved base, or why there is none.
public struct FileDiff: Sendable, Equatable {
    public enum State: Equatable, Sendable {
        /// Differs from the base (including files deleted from the working tree).
        case modified
        case unchanged
        /// New since the base, untracked (`untracked`) or not: every line is added.
        case added
        /// Not in the base and ignored by git (a dependency under `node_modules`, a build
        /// output): no work of the branch's, so `new` holds it as plain source, no signs.
        case ignored
        case deleted
        case binary
        /// Neither on disk nor in the base.
        case missing
        /// Outside any git repository; `new` holds the file as source.
        case notRepository
        /// No commit to compare with (unborn HEAD, no default branch, unknown commit); `new`
        /// holds the file as source and `baseLabel` says why.
        case noBase
        /// The file on disk exceeds `GitDiffEngine.maxFileSize`: nothing to show.
        case tooLarge
        /// The base version or the patch exceeds the limits; `new` holds the file as source.
        case diffTooLarge
        /// A gitlink (submodule) in the base or on disk: not a text file.
        case submodule
        /// The file kept changing while it was being diffed; the next write reloads it.
        case unstable
        /// The file as of a commit (a tile's `pinnedCommit`): `new` holds it, `base` is the
        /// commit's full SHA, `baseLabel` the revision as written. No diff.
        case pinned
        /// A pinned commit that can't be shown: `baseLabel` says why (unknown commit, the file
        /// isn't in it, outside git, binary or too large).
        case pinUnavailable
        /// A remote board's host refused the path (outside the board, an escaping symlink) or
        /// couldn't read it: `baseLabel` says why. Nothing of the file is shown.
        case unreadable
    }

    public var state: State
    /// Full SHA of the commit diffed against; nil when there is no base.
    public var base: String?
    /// How the base was chosen, e.g. `merge-base with origin/main`.
    public var baseLabel: String?
    public var old: SideText
    public var new: SideText
    public var hunks: [DiffHunk]
    /// Top-level directory of the repository the file belongs to.
    public var repository: String?
    /// An `added` file git doesn't track yet (not in the index either).
    public var untracked = false

    public init(state: State, base: String?, baseLabel: String?, old: SideText, new: SideText, hunks: [DiffHunk], repository: String? = nil) {
        self.repository = repository
        self.state = state
        self.base = base
        self.baseLabel = baseLabel
        self.old = old
        self.new = new
        self.hunks = hunks
    }

    public var mappings: [LineRangeMapping] { hunks.flatMap(\.mappings) }
    public var addedCount: Int { mappings.reduce(0) { $0 + $1.modified.count } }
    public var removedCount: Int { mappings.reduce(0) { $0 + $1.original.count } }
}

/// Parses `git diff -U0 --inter-hunk-context=0` output for one file. Lines are split on LF
/// bytes, not Characters: a CRLF pair is one Character, and its CR belongs to the source line.
public enum UnifiedDiff {
    public struct Parsed: Equatable, Sendable {
        public var mappings: [LineRangeMapping] = []
        /// Removed lines keyed by old line number (with any CR), the only old-side text the
        /// patch carries.
        public var removed: [Int: String] = [:]
        /// `\ No newline at end of file` followed a removed line: the base's last line has none.
        public var oldMissingFinalNewline = false
        public var binary = false
        /// The entry is a gitlink (mode 160000) on either side.
        public var gitlink = false
    }

    public static func parse(_ patch: Data) -> Parsed {
        var parsed = Parsed()
        var oldLine = 0
        var lastWasRemoval = false
        patch.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != 0x0A { end += 1 }
                let line = UnsafeBufferPointer(rebasing: bytes[start..<end])
                start = end + 1
                guard let first = line.first else { continue }
                switch first {
                case UInt8(ascii: "@"):
                    lastWasRemoval = false
                    guard let mapping = mapping(fromHeader: Substring(decoding: line, as: UTF8.self)) else { continue }
                    parsed.mappings.append(mapping)
                    oldLine = mapping.original.lowerBound
                case UInt8(ascii: "-") where !parsed.mappings.isEmpty:
                    // Inside hunks every `-` line is a removal, even one whose text starts with `--`.
                    parsed.removed[oldLine] = String(decoding: UnsafeBufferPointer(rebasing: line.dropFirst()), as: UTF8.self)
                    oldLine += 1
                    lastWasRemoval = true
                case UInt8(ascii: "+") where !parsed.mappings.isEmpty:
                    lastWasRemoval = false
                case UInt8(ascii: "\\"):
                    if lastWasRemoval { parsed.oldMissingFinalNewline = true }
                default:
                    guard parsed.mappings.isEmpty else { continue }
                    let text = String(decoding: line, as: UTF8.self)
                    if text.hasPrefix("Binary files ") || text == "GIT binary patch" { parsed.binary = true }
                    if text.hasSuffix(" 160000") && (text.hasPrefix("index ") || text.contains(" mode 160000")) { parsed.gitlink = true }
                }
            }
        }
        return parsed
    }

    /// `@@ -a[,b] +c[,d] @@`: a zero count means the range is empty and sits after line a/c.
    static func mapping(fromHeader header: Substring) -> LineRangeMapping? {
        let fields = header.split(separator: " ")
        guard fields.count >= 3, fields[0] == "@@", fields[1].hasPrefix("-"), fields[2].hasPrefix("+"),
              let original = range(fields[1].dropFirst()), let modified = range(fields[2].dropFirst()) else { return nil }
        return LineRangeMapping(original: original, modified: modified)
    }

    private static func range(_ field: Substring) -> Range<Int>? {
        let parts = field.split(separator: ",")
        guard let first = parts.first, let start = Int(first) else { return nil }
        let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        let lower = count == 0 ? start + 1 : start
        return lower..<(lower + count)
    }

    /// git merges changes into one hunk when at most 2 × 3 context lines separate them.
    public static func hunks(_ mappings: [LineRangeMapping], context: Int = 3) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        for mapping in mappings {
            if let last = hunks.last?.mappings.last, mapping.modified.lowerBound - last.modified.upperBound <= 2 * context {
                hunks[hunks.count - 1].mappings.append(mapping)
            } else {
                hunks.append(DiffHunk(mappings: [mapping]))
            }
        }
        return hunks
    }

    /// The base version of the file: the new lines with each change's removed lines put back.
    /// Unchanged runs are copied as whole spans with their own line endings. Returns nil when the
    /// patch doesn't describe `new` (e.g. the file changed after it was read).
    public static func reconstructOld(new: SideText, parsed: Parsed) -> SideText? {
        let source = new.text as NSString
        let out = NSMutableString(capacity: new.utf16Count)
        var next = 1
        var nextOld = 1
        for mapping in parsed.mappings {
            let unchanged = mapping.modified.lowerBound - next
            guard unchanged >= 0, mapping.original.lowerBound - nextOld == unchanged,
                  mapping.modified.upperBound - 1 <= new.lineCount else { return nil }
            if unchanged > 0 {
                let start = new.lineStarts[next - 1]
                // A deletion at the end of the file sits after the last line.
                let end = mapping.modified.lowerBound <= new.lineCount ? new.lineStarts[mapping.modified.lowerBound - 1] : new.utf16Count
                out.append(source.substring(with: NSRange(location: start, length: end - start)))
                if end == new.utf16Count, !out.hasSuffix("\n") { out.append("\n") }
            }
            for old in mapping.original {
                guard let line = parsed.removed[old] else { return nil }
                out.append(line)
                out.append("\n")
            }
            next = mapping.modified.upperBound
            nextOld = mapping.original.upperBound
        }
        guard next <= new.lineCount + 1 else { return nil }
        if next <= new.lineCount {
            let start = new.lineStarts[next - 1]
            out.append(source.substring(with: NSRange(location: start, length: new.utf16Count - start)))
        } else if parsed.oldMissingFinalNewline, out.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return SideText(out as String)
    }
}
