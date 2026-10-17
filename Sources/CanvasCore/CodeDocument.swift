import Foundation

/// A gutter sign for one change against the tile's diff base, as in nvim's gitsigns: a green bar
/// on added lines, a blue bar on modified lines, a red wedge between lines where lines were
/// deleted.
public struct GitSign: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case added, modified, deleted
    }

    public var kind: Kind
    /// Displayed lines the bar marks (1-based, end-exclusive). A deletion marks none: its wedge
    /// sits on the top edge of line `lines.lowerBound`, which is `lineCount + 1` (below the last
    /// line) for deletions at the end of the file.
    public var lines: Range<Int>
    /// Base lines the change replaced or removed; empty for additions.
    public var old: Range<Int>

    public init(kind: Kind, lines: Range<Int>, old: Range<Int>) {
        self.kind = kind
        self.lines = lines
        self.old = old
    }

    /// Whether clicking the sign can show base lines.
    public var peekable: Bool { !old.isEmpty }

    /// One sign per change record of the diff.
    public static func signs(_ mappings: [LineRangeMapping]) -> [GitSign] {
        mappings.map { mapping in
            let kind: Kind = mapping.original.isEmpty ? .added : mapping.modified.isEmpty ? .deleted : .modified
            return GitSign(kind: kind, lines: mapping.modified, old: mapping.original)
        }
    }
}

/// A side's text with each line's width in columns, measured once per load so rows can rewrap
/// at any width without rescanning the lines that fit.
public struct WrapText: Sendable, Equatable {
    public let text: SideText
    /// Columns of each line (`CodeMetrics.columns`: tabs expanded, wide characters 2).
    public let columns: [Int32]
    /// Widest line in columns.
    public let longest: Int

    public init(_ text: SideText) {
        self.text = text
        let utf16 = text.text.utf16
        var columns: [Int32] = []
        columns.reserveCapacity(text.lineCount)
        var cursor = utf16.startIndex, at = 0
        for line in 0..<text.lineCount {
            let start = utf16.index(cursor, offsetBy: text.lineStarts[line] - at)
            let end = utf16.index(start, offsetBy: text.lineEnds[line] - text.lineStarts[line])
            columns.append(Int32(CodeMetrics.columns(units: utf16[start..<end])))
            cursor = end
            at = text.lineEnds[line]
        }
        self.columns = columns
        longest = Int(columns.max() ?? 0)
    }

    /// UTF-16 units of a 1-based line, without its break.
    public func units(ofLine line: Int) -> Substring.UTF16View {
        let range = text.range(ofLine: line)
        let start = String.Index(utf16Offset: range.location, in: text.text)
        let end = String.Index(utf16Offset: range.location + range.length, in: text.text)
        return text.text[start..<end].utf16
    }
}

/// The rows a code tile shows. Entries are the logical rows: every line of the displayed text,
/// plus, for each peeked sign, the base lines it replaced or removed, inline above the lines that
/// replaced them (or at the deletion's wedge). Visual rows are what's drawn: an entry wider than
/// `columns` soft-wraps onto continuation rows (`CodeMetrics.wrap`). Row indices are visual
/// unless named entries. Peeks and wrapped lines are few, so both mappings are computed rather
/// than stored per row.
public struct CodeRows: Equatable, Sendable {
    public enum Row: Hashable, Sendable {
        /// A 1-based line of the displayed text.
        case line(Int)
        /// A 1-based base line shown by peeking sign `sign`.
        case peek(old: Int, sign: Int)
    }

    /// One visual row: all or part of an entry's line.
    public struct Segment: Equatable, Sendable {
        public var entry: Int
        public var row: Row
        /// 0 for the line's first row, then its continuation rows.
        public var part: Int
        /// UTF-16 offset in the line where the row's text starts.
        public var start: Int
        /// Where it ends: the next row's `start`, or nil for the line's last row.
        public var end: Int?
        /// Columns the text is indented by (continuation rows).
        public var indent: Int

        public var isContinuation: Bool { part > 0 }
    }

    struct Peek: Equatable, Sendable {
        var sign: Int
        /// The displayed line the peek rows sit above.
        var at: Int
        var old: Range<Int>
    }

    struct Wrapped: Equatable, Sendable {
        var entry: Int
        var breaks: [Int]
        var indent: Int
        /// Continuation rows of the wrapped entries before this one.
        var before: Int
    }

    public let lineCount: Int
    let peeks: [Peek]
    /// Text columns the rows wrap at; nil when they don't wrap.
    public let columns: Int?
    /// Entries that wrap, ascending.
    let wrapped: [Wrapped]

    /// Rows without wrapping: one per entry.
    public init(lineCount: Int, signs: [GitSign] = [], peeked: Set<Int> = []) {
        self.lineCount = lineCount
        peeks = Self.peeks(lineCount: lineCount, signs: signs, peeked: peeked)
        columns = nil
        wrapped = []
    }

    /// Rows of `text` (and peeked lines of `old`) wrapped at `columns` text columns.
    public init(text: WrapText, old: WrapText? = nil, signs: [GitSign] = [], peeked: Set<Int> = [], columns: Int?) {
        let lineCount = text.text.lineCount
        let peeks = Self.peeks(lineCount: lineCount, signs: signs, peeked: peeked)
        self.lineCount = lineCount
        self.peeks = peeks
        self.columns = columns
        guard let columns else {
            wrapped = []
            return
        }
        var found: [Wrapped] = []
        if text.longest > columns {
            for line in 1...lineCount where Int(text.columns[line - 1]) > columns {
                let wrap = CodeMetrics.wrap(text.units(ofLine: line), columns: columns)
                guard !wrap.breaks.isEmpty else { continue }
                found.append(Wrapped(entry: Self.entry(ofLine: line, lineCount: lineCount, peeks: peeks), breaks: wrap.breaks, indent: wrap.indent, before: 0))
            }
        }
        if let old, old.longest > columns {
            var inserted = 0
            for peek in peeks {
                for line in peek.old where line <= old.text.lineCount && Int(old.columns[line - 1]) > columns {
                    let wrap = CodeMetrics.wrap(old.units(ofLine: line), columns: columns)
                    guard !wrap.breaks.isEmpty else { continue }
                    let entry = peek.at - 1 + inserted + (line - peek.old.lowerBound)
                    found.append(Wrapped(entry: entry, breaks: wrap.breaks, indent: wrap.indent, before: 0))
                }
                inserted += peek.old.count
            }
        }
        found.sort { $0.entry < $1.entry }
        var before = 0
        for index in found.indices {
            found[index].before = before
            before += found[index].breaks.count
        }
        wrapped = found
    }

    private static func peeks(lineCount: Int, signs: [GitSign], peeked: Set<Int>) -> [Peek] {
        peeked.sorted().compactMap { index in
            guard signs.indices.contains(index), signs[index].peekable else { return nil }
            return Peek(sign: index, at: min(signs[index].lines.lowerBound, lineCount + 1), old: signs[index].old)
        }.sorted { ($0.at, $0.sign) < ($1.at, $1.sign) }
    }

    private static func entry(ofLine line: Int, lineCount: Int, peeks: [Peek]) -> Int {
        let line = min(max(1, line), max(1, lineCount))
        return line - 1 + peeks.reduce(0) { $0 + ($1.at <= line ? $1.old.count : 0) }
    }

    // MARK: Entries

    public var entryCount: Int { lineCount + peeks.reduce(0) { $0 + $1.old.count } }

    /// What an entry shows.
    public func entryRow(_ index: Int) -> Row? {
        guard index >= 0 else { return nil }
        var inserted = 0
        for peek in peeks {
            let start = peek.at - 1 + inserted
            if index < start { break }
            if index < start + peek.old.count { return .peek(old: peek.old.lowerBound + index - start, sign: peek.sign) }
            inserted += peek.old.count
        }
        let line = index - inserted + 1
        return line <= lineCount ? .line(line) : nil
    }

    /// Entry of a displayed line (clamped to the text).
    public func entry(ofLine line: Int) -> Int {
        Self.entry(ofLine: line, lineCount: lineCount, peeks: peeks)
    }

    /// Entry of a base line shown by a peek.
    public func entry(ofPeek sign: Int, old line: Int) -> Int? {
        var inserted = 0
        for peek in peeks {
            if peek.sign == sign {
                guard peek.old.contains(line) else { return nil }
                return peek.at - 1 + inserted + (line - peek.old.lowerBound)
            }
            inserted += peek.old.count
        }
        return nil
    }

    /// Wrapped entries before `entry` (an insertion point into `wrapped`).
    private func wrappedBefore(_ entry: Int) -> Int {
        var low = 0, high = wrapped.count
        while low < high {
            let mid = (low + high) / 2
            if wrapped[mid].entry < entry { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Visual rows of an entry: its first row and its continuations.
    public func rows(ofEntry entry: Int) -> Range<Int> {
        let index = wrappedBefore(entry)
        let first = entry + (index > 0 ? wrapped[index - 1].before + wrapped[index - 1].breaks.count : 0)
        let continuations = index < wrapped.count && wrapped[index].entry == entry ? wrapped[index].breaks.count : 0
        return first..<(first + 1 + continuations)
    }

    // MARK: Visual rows

    public var count: Int { entryCount + (wrapped.last.map { $0.before + $0.breaks.count } ?? 0) }

    /// What a visual row draws.
    public func segment(_ index: Int) -> Segment? {
        guard index >= 0, index < count else { return nil }
        // The last wrapped entry starting at or above the row.
        var low = 0, high = wrapped.count
        while low < high {
            let mid = (low + high) / 2
            if wrapped[mid].entry + wrapped[mid].before <= index { low = mid + 1 } else { high = mid }
        }
        var entry = index, part = 0
        var wrap: Wrapped?
        if low > 0 {
            let above = wrapped[low - 1]
            let first = above.entry + above.before
            if index <= first + above.breaks.count {
                entry = above.entry
                part = index - first
                wrap = above
            } else {
                entry = index - above.before - above.breaks.count
            }
        }
        guard let row = entryRow(entry) else { return nil }
        let start = part == 0 ? 0 : wrap?.breaks[part - 1] ?? 0
        let end = wrap.flatMap { part < $0.breaks.count ? $0.breaks[part] : nil }
        return Segment(entry: entry, row: row, part: part, start: start, end: end, indent: part == 0 ? 0 : wrap?.indent ?? 0)
    }

    /// The entry a visual row belongs to (continuations included).
    public func row(_ index: Int) -> Row? {
        segment(index)?.row
    }

    /// First visual row of a displayed line (clamped to the text).
    public func index(ofLine line: Int) -> Int {
        rows(ofEntry: entry(ofLine: line)).lowerBound
    }

    /// All visual rows of a displayed line (clamped to the text).
    public func rows(ofLine line: Int) -> Range<Int> {
        rows(ofEntry: entry(ofLine: line))
    }

    /// First visual row of a base line shown by a peek.
    public func index(ofPeek sign: Int, old line: Int) -> Int? {
        entry(ofPeek: sign, old: line).map { rows(ofEntry: $0).lowerBound }
    }

    /// Visual row whose top edge is the top edge of `line`; `lineCount + 1` gives the edge below
    /// the last line (where deletion wedges sit).
    public func edgeRow(ofLine line: Int) -> Int {
        line <= lineCount ? index(ofLine: line) : rows(ofLine: lineCount).upperBound
    }

    public var peekedSigns: Set<Int> { Set(peeks.map(\.sign)) }
}

extension CodeRows {
    /// The rows a code tile `width` points wide shows for a file's `text` without its diff (no
    /// peeks): the model's view of a tile it hasn't loaded, for line anchors.
    public init(file text: String, width: CGFloat) {
        let side = SideText(text)
        self.init(text: WrapText(side), columns: CodeMetrics.textColumns(width: width, lineCount: side.lineCount))
    }

    /// A place in the text: an entry and a UTF-16 offset into its line. Rewrapping doesn't move
    /// it, so selections survive resizes.
    public struct Position: Comparable, Sendable {
        public var entry: Int
        public var offset: Int

        public init(entry: Int, offset: Int) {
            self.entry = entry
            self.offset = offset
        }

        public static func < (lhs: Position, rhs: Position) -> Bool {
            (lhs.entry, lhs.offset) < (rhs.entry, rhs.offset)
        }
    }
}

/// A visual row's text as drawn: its slice of the line, with tabs expanded to the stops of the
/// whole line, and the mapping between line offsets and offsets in the drawn string.
public struct CodeRowText: Sendable, Equatable {
    /// The drawn string.
    public let display: String
    /// UTF-16 offsets of the line the row covers.
    public let start: Int
    public let end: Int
    /// Display offset of each line offset `start...end`, relative to the row; nil without tabs.
    let map: [Int]?

    /// `slice` is the row's part of the line, starting at line offset `start` and at column
    /// `startColumn` of the unwrapped line.
    public init(line slice: String, start: Int, startColumn: Int) {
        self.start = start
        let units = Array(slice.utf16)
        end = start + units.count
        guard units.contains(0x09) else {
            display = slice
            map = nil
            return
        }
        var out: [UInt16] = []
        var map: [Int] = []
        map.reserveCapacity(units.count + 1)
        var column = startColumn
        for unit in units {
            map.append(out.count)
            if unit == 0x09 {
                let width = CodeMetrics.tabWidth - column % CodeMetrics.tabWidth
                out.append(contentsOf: repeatElement(0x20, count: width))
                column += width
            } else {
                out.append(unit)
                column += CodeMetrics.columns(of: unit)
            }
        }
        map.append(out.count)
        display = String(utf16CodeUnits: out, count: out.count)
        self.map = map
    }

    /// Offset in `display` of a line offset (clamped to the row).
    public func display(ofOffset offset: Int) -> Int {
        let local = min(max(offset, start), end) - start
        return map?[local] ?? local
    }

    /// Line offset of an offset in `display` (a tab's spaces map to the tab).
    public func offset(ofDisplay index: Int) -> Int {
        guard let map else { return start + min(max(0, index), end - start) }
        return start + (map.lastIndex { $0 <= index } ?? 0)
    }
}

/// Highlight runs grouped by line: what the renderer needs for one row, without the whole-file
/// span list or an attributed string. Overlapping spans are flattened (the last applied wins).
public struct SyntaxLines: Sendable, Equatable {
    /// UTF-16 offsets within the line.
    public struct Run: Sendable, Equatable {
        public var start: Int32
        public var end: Int32
        public var style: SyntaxStyle
    }

    private let runs: [Run]
    /// Index into `runs` of each line's first run; one more entry than lines.
    private let firsts: [Int32]

    public static let empty = SyntaxLines(runs: [], firsts: [0])

    private init(runs: [Run], firsts: [Int32]) {
        self.runs = runs
        self.firsts = firsts
    }

    public init(_ spans: [SyntaxSpan], text: SideText) {
        guard !spans.isEmpty, text.utf16Count > 0 else {
            self = .empty
            return
        }
        let styles = SyntaxStyle.allCases
        let none = UInt8.max
        var paint = [UInt8](repeating: none, count: text.utf16Count)
        for span in spans {
            let start = max(0, span.range.location), end = min(text.utf16Count, span.range.location + span.range.length)
            guard start < end, let code = styles.firstIndex(of: span.style) else { continue }
            for offset in start..<end { paint[offset] = UInt8(code) }
        }
        var runs: [Run] = []
        var firsts: [Int32] = []
        firsts.reserveCapacity(text.lineCount + 1)
        for line in 0..<text.lineCount {
            firsts.append(Int32(runs.count))
            let base = text.lineStarts[line]
            var offset = base
            let end = text.lineEnds[line]
            while offset < end {
                let code = paint[offset]
                var stop = offset + 1
                while stop < end, paint[stop] == code { stop += 1 }
                if code != none {
                    runs.append(Run(start: Int32(offset - base), end: Int32(stop - base), style: styles[Int(code)]))
                }
                offset = stop
            }
        }
        firsts.append(Int32(runs.count))
        self.runs = runs
        self.firsts = firsts
    }

    /// Runs of a 1-based line, in order.
    public func runs(line: Int) -> ArraySlice<Run> {
        guard line >= 1, line < firsts.count else { return [] }
        return runs[Int(firsts[line - 1])..<Int(firsts[line])]
    }
}

/// Everything a code tile draws for one load of its file: the text (the working tree, or the
/// base version of a deleted file), gitsigns against the diff base, per-line highlighting for
/// both sides, and the header's status and warning. Built off the main thread.
public struct CodeDocument: Sendable {
    public let path: String
    /// The file the rows were read from, as mentions and the editor name it: `path`, or for a
    /// tile anchored to a branch that is live in another worktree, the file in that worktree.
    public let readPath: String
    public let diff: FileDiff
    /// Which side of the diff the rows show: the base version only for deleted files.
    public let side: DiffSide
    public let signs: [GitSign]
    public let syntax: SyntaxLines
    /// The base side, for peek rows.
    public let oldSyntax: SyntaxLines
    public let symbols: [SyntaxSymbol]
    public let oldSymbols: [SyntaxSymbol]
    /// The displayed text measured for wrapping.
    public let wrapText: WrapText
    /// The base side measured for wrapping peek rows (modified files only).
    public let oldWrapText: WrapText?
    /// Shown instead of rows when there is no text (binary, missing, too large…).
    public let notice: String?
    /// Why the tile shows plain source or a read-only base version.
    public let warning: String?
    /// The header's status: the counts, and the base's commit unless the header's picker
    /// already names it (a commit typed as its sha).
    public let status: String
    /// What the diff is against, exactly, for the header's tooltips: `against merge-base with
    /// origin/main b57db4f`. Nil without a base.
    public let baseDescription: String?

    public var text: SideText { side == .old ? diff.old : diff.new }

    /// `readPath` defaults to `path`; `ref` is a branch-anchored tile's state (`RefSource.label`),
    /// which leads the status.
    public init(path: String, diff: FileDiff, readPath: String? = nil, ref: String? = nil) {
        self.path = path
        self.readPath = readPath ?? path
        self.diff = diff
        side = diff.state == .deleted ? .old : .new
        let showsSigns = diff.state == .modified || diff.state == .added
        signs = showsSigns ? GitSign.signs(diff.mappings) : []
        let text = side == .old ? diff.old : diff.new
        let language = SyntaxLanguage(path: path)
        let analysis = language.map { Syntax.analyze(text.text, language: $0) } ?? .empty
        syntax = SyntaxLines(analysis.spans, text: text)
        symbols = analysis.symbols
        if diff.state == .modified, let language {
            let old = Syntax.analyze(diff.old.text, language: language)
            oldSyntax = SyntaxLines(old.spans, text: diff.old)
            oldSymbols = old.symbols
        } else {
            oldSyntax = .empty
            oldSymbols = side == .old ? symbols : []
        }
        wrapText = WrapText(text)
        // Only modified files have signs that peek base lines.
        oldWrapText = diff.state == .modified ? WrapText(diff.old) : nil
        // The header's picker names the base in words (`Branch vs origin/main`, `vs v1.2`), so
        // the status adds only its commit, and not even that when the picker shows it.
        let base = diff.base.map { sha in diff.baseLabel.map { !$0.isEmpty && sha.hasPrefix($0) } == true ? "" : " · \(sha.prefix(7))" } ?? ""
        baseDescription = diff.state == .pinned ? nil : diff.base.map { "against \(diff.baseLabel ?? "base") \($0.prefix(7))" }
        var notice: String?
        var warning: String?
        let status: String
        switch diff.state {
        case .modified: status = "+\(diff.addedCount) −\(diff.removedCount)\(base)"
        case .unchanged: status = "no changes\(base)"
        case .added: status = "\(diff.untracked ? "new file, not tracked by git yet" : "new file") · +\(diff.addedCount)\(base)"
        case .ignored: status = "ignored by git"
        case .deleted:
            status = "−\(diff.removedCount)\(base)"
            warning = "deleted — base version, read-only"
        case .noBase:
            status = ""
            warning = "\(diff.baseLabel ?? "no base") — showing source"
        case .diffTooLarge:
            status = base.isEmpty ? "" : String(base.dropFirst(3))
            warning = "diff too large — showing source"
        case .notRepository: status = "not in a git repository"
        case .binary:
            status = String(base.dropFirst(3))
            notice = "binary file"
        case .missing:
            status = ""
            notice = "file not found: \(path)"
        case .tooLarge:
            status = ""
            notice = "file too large to show (over \(GitDiffEngine.maxFileSize >> 20) MiB)"
        case .submodule:
            status = ""
            notice = "submodule (not a text file)"
        case .unstable:
            status = ""
            notice = "file kept changing while diffing; waiting for the next write"
        case .pinned:
            let sha = String(diff.base?.prefix(7) ?? "")
            let revision = diff.baseLabel.flatMap { sha.hasPrefix($0) || $0.hasPrefix(sha) ? nil : $0 }
            status = "pinned at \(sha)" + (revision.map { " (\($0))" } ?? "") + " · read-only"
        case .pinUnavailable:
            status = "pinned"
            notice = "\(path): \(diff.baseLabel ?? "pinned commit unavailable")"
        case .unreadable:
            status = ""
            notice = "\(path): \(diff.baseLabel ?? "unreadable on the host")"
        }
        self.notice = notice
        self.warning = warning
        // A ref's objects read like a pinned commit, but the header names the ref's state.
        self.status = switch (ref, diff.state) {
        case (nil, _): status
        case (let ref?, .pinned): "\(ref) · read-only"
        case (let ref?, _): status.isEmpty || diff.state == .pinUnavailable ? ref : "\(ref) · \(status)"
        }
    }

    /// Displayed line range a line range of the object's `range` covers, clamped to the text.
    public func lines(for range: LineRange) -> ClosedRange<Int>? {
        guard text.lineCount > 0 else { return nil }
        let start = min(max(1, range.start), text.lineCount)
        return start...min(max(start, range.end), text.lineCount)
    }

    /// Lines of the longer side: the gutter's line numbers fit either.
    public var gutterLineCount: Int { max(text.lineCount, diff.old.lineCount) }

    /// The rows a tile `width` points wide shows with `peeked` signs open; nil `width` doesn't
    /// wrap.
    public func rows(peeked: Set<Int>, width: CGFloat?) -> CodeRows {
        CodeRows(text: wrapText, old: oldWrapText, signs: signs, peeked: peeked,
                 columns: width.map { CodeMetrics.textColumns(width: $0, lineCount: gutterLineCount) })
    }

    /// The side, line, and highlighting an entry shows.
    public func source(of row: CodeRows.Row) -> (text: SideText, line: Int, syntax: SyntaxLines) {
        switch row {
        case .line(let line): (text, line, syntax)
        case .peek(let old, _): (diff.old, old, oldSyntax)
        }
    }

    /// The whole line an entry shows, without its break.
    public func text(of row: CodeRows.Row) -> String {
        let source = source(of: row)
        guard source.line >= 1, source.line <= source.text.lineCount else { return "" }
        return source.text.line(source.line)
    }

    /// What a visual row draws: its slice of the line, tabs expanded.
    public func rowText(_ segment: CodeRows.Segment) -> CodeRowText {
        let source = source(of: segment.row)
        guard source.line >= 1, source.line <= source.text.lineCount else { return CodeRowText(line: "", start: 0, startColumn: 0) }
        let range = source.text.range(ofLine: source.line)
        let whole = source.text.text as NSString
        let end = min(segment.end ?? range.length, range.length), start = min(segment.start, end)
        let slice = whole.substring(with: NSRange(location: range.location + start, length: end - start))
        // Tab stops count from the start of the line, not the row.
        let column = start > 0 && slice.utf16.contains(0x09) ? CodeMetrics.columns(whole.substring(with: NSRange(location: range.location, length: start))) : 0
        return CodeRowText(line: slice, start: start, startColumn: column)
    }

    /// The text between two positions: logical lines joined by newlines, however they wrap.
    public func text(rows: CodeRows, from: CodeRows.Position, to: CodeRows.Position) -> String {
        guard from < to else { return "" }
        var pieces: [String] = []
        for entry in from.entry...to.entry {
            guard let row = rows.entryRow(entry) else { continue }
            let line = text(of: row) as NSString
            let start = entry == from.entry ? min(from.offset, line.length) : 0
            let end = entry == to.entry ? min(to.offset, line.length) : line.length
            pieces.append(line.substring(with: NSRange(location: start, length: max(0, end - start))))
        }
        return pieces.joined(separator: "\n")
    }

    /// Width of everything left of the text, for this file and its base.
    public var gutterWidth: CGFloat {
        CodeMetrics.gutterWidth(lineCount: gutterLineCount)
    }

    /// A code tile's content (body coordinates) showing this document at `range` in a tile
    /// `width` wide: the header strips (`headerHeight`) over the range's visual `rows` (built at
    /// that width, so wrapped lines count every row) and its longest line, or every row and the
    /// file's longest line without a range; never wider than the tile, since rows wrap there.
    /// What `size: "fit"` makes the body show, and what `view.render` reports as the tile's
    /// `contentSize`.
    public func content(range: LineRange?, rows: CodeRows, width: CGFloat, headerHeight: CGFloat) -> CGSize {
        var size: CGSize
        if let range, let lines = lines(for: range) {
            let first = rows.index(ofLine: lines.lowerBound)
            let longest = lines.map { Int(wrapText.columns[$0 - 1]) }.max() ?? 0
            size = CodeMetrics.content(rows: rows.rows(ofLine: lines.upperBound).upperBound - first, longestLine: longest, gutterWidth: gutterWidth, headerHeight: headerHeight)
        } else {
            size = CodeMetrics.content(rows: rows.count, longestLine: wrapText.longest, gutterWidth: gutterWidth, headerHeight: headerHeight)
        }
        size.width = min(size.width, width)
        return size
    }

    /// The commit mentions of this tile's lines name: the diff base while the tile shows changes
    /// against it, the base a deleted file's rows come from, or the pinned commit.
    public var mentionCommit: String? {
        signs.isEmpty && side == .new && !isPinned ? nil : diff.base
    }

    /// The file as of a pinned commit (`pinnedCommit`): read-only, never the working tree.
    public var isPinned: Bool { diff.state == .pinned }

    /// The innermost declaration holding all of `lines` on one side (`innermost(around:)`).
    public func enclosingSymbol(lines: LineRange, side: DiffSide) -> String? {
        (side == self.side ? symbols : oldSymbols).innermost(around: lines)
    }

    /// The sign whose bar covers `line`, or whose wedge sits on its top edge.
    public func sign(at line: Int) -> Int? {
        signs.firstIndex { $0.lines.contains(line) } ?? signs.firstIndex { $0.kind == .deleted && $0.lines.lowerBound == line }
    }

    /// First displayed line of the change after (or before) `line`, wrapping around; for
    /// header ↑/↓.
    public func changeLine(after line: Int, forward: Bool) -> Int? {
        let starts = signs.map { min($0.lines.lowerBound, max(1, text.lineCount)) }
        guard !starts.isEmpty else { return nil }
        return forward ? starts.first { $0 > line } ?? starts.first : starts.last { $0 < line } ?? starts.last
    }
}

/// Which lines of a file one write changed, from the text before and after it.
public enum CodeEdits {
    /// Beyond this many differing lines the whole differing span counts as changed.
    static let diffLimit = 4000

    /// Lines of `new` that an edit inserted or replaced (1-based, end-exclusive, ascending) and
    /// the first line it touched (a pure deletion touches the line after it). Nil when the
    /// texts have the same lines.
    public static func changes(from old: SideText, to new: SideText) -> (lines: [Range<Int>], first: Int)? {
        let before = (0..<old.lineCount).map { old.line($0 + 1) }
        let after = (0..<new.lineCount).map { new.line($0 + 1) }
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        guard prefix < before.count || prefix < after.count else { return nil }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix, before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let removed = before[prefix..<(before.count - suffix)]
        let added = after[prefix..<(after.count - suffix)]
        let first = min(prefix + 1, max(1, new.lineCount))
        guard !added.isEmpty else { return ([], first) }
        guard removed.count + added.count <= diffLimit, !removed.isEmpty else {
            return ([(prefix + 1)..<(prefix + added.count + 1)], first)
        }
        var inserted: [Int] = []
        for change in added.difference(from: removed) {
            if case .insert(let offset, _, _) = change { inserted.append(offset) }
        }
        var lines: [Range<Int>] = []
        for offset in inserted.sorted() {
            let line = prefix + offset + 1
            if let last = lines.last, last.upperBound == line {
                lines[lines.count - 1] = last.lowerBound..<(line + 1)
            } else {
                lines.append(line..<(line + 1))
            }
        }
        return (lines, first)
    }
}
