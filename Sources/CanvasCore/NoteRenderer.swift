import AppKit
import Markdown

/// Markdown → attributed text for the note display (TextKit 2). Prose is styled as authored;
/// anchored fences render what `NoteSource` resolved from disk, keyed by their info string.
@MainActor
public final class NoteRenderer {
    public static let bodyFont = NSFont.systemFont(ofSize: 13)
    public static let codeFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    public static let captionFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    /// Rows past this in one excerpt are summarized; a whole-file excerpt stays cheap to lay out.
    static let maxRows = 400

    private let excerpts: [String: NoteExcerpt]
    /// Anchored fences show their body as written instead of waiting for an excerpt: a remote
    /// board's note, whose files are its host's (docs/design.md "Client mode").
    private let asWritten: Bool
    /// Images by markdown destination (`NoteImages.load`); an image missing here shows as its alt text.
    private let images: [String: NSImage]
    /// Where lines end: the text container's width less its line fragment padding. Tables fit
    /// their columns into it.
    private let lineWidth: CGFloat
    private let out = NSMutableAttributedString()
    /// Whether the text depends on the width it was rendered at (a table's cells wrap to it).
    public private(set) var fitsWidth = false
    /// Points of width the text container lacks to show every table cell whole: 0 unless a table
    /// has more columns than the note has room for even with its words broken, when its rows
    /// run past the edge and are cut with "…" (`layout.check` reports it as `truncated`).
    public private(set) var tableShortfall: CGFloat = 0

    /// `width`: the text container's width, the note's width less `ObjectMeasure.noteInset` on
    /// each side, as the display, renders, and `ObjectMeasure` lay it out.
    public init(excerpts: [String: NoteExcerpt], images: [String: NSImage] = [:], width: CGFloat, asWritten: Bool = false) {
        self.excerpts = excerpts
        self.images = images
        self.asWritten = asWritten
        lineWidth = max(1, width - 2 * ObjectMeasure.noteLineFragmentPadding)
    }

    /// Nesting state for block rendering.
    private struct Context {
        var indent: CGFloat = 0
        var quoted = false
        /// List marker for the next paragraph (the first one of a list item).
        var marker: String?
        var markerWidth: CGFloat = 0
    }

    public func render(_ document: Document, placeholder: String) -> NSAttributedString {
        if document.childCount == 0 {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            out.append(NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: style,
            ]))
            return out
        }
        var context = Context()
        blocks(document, &context)
        // Every block ends its paragraph; the last one needs no empty paragraph after it.
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    // MARK: Blocks

    private func blocks(_ container: Markup, _ context: inout Context) {
        for child in container.children { block(child, &context) }
    }

    private func block(_ markup: Markup, _ context: inout Context) {
        let line = markup.range?.lowerBound.line
        switch markup {
        case let heading as Heading:
            let sizes: [CGFloat] = [20, 17, 15, 13]
            let size = sizes[min(sizes.count, max(1, heading.level)) - 1]
            let font = NSFont.systemFont(ofSize: size, weight: heading.level <= 2 ? .bold : .semibold)
            paragraph(heading, font: font, context: &context, line: line, spacingBefore: heading.level <= 2 ? 6 : 3)
        case let paragraph as Paragraph:
            self.paragraph(paragraph, font: Self.bodyFont, context: &context, line: line)
        case let quote as BlockQuote:
            var inner = context
            inner.indent += 14
            inner.quoted = true
            blocks(quote, &inner)
            context.marker = inner.marker
        case let list as UnorderedList:
            listItems(Array(list.listItems), ordered: nil, &context)
        case let list as OrderedList:
            listItems(Array(list.listItems), ordered: Int(list.startIndex), &context)
        case let code as CodeBlock:
            fence(code, context: context, line: line ?? 1)
        case let table as Table:
            self.table(table, context: context, line: line)
        case is ThematicBreak:
            append(" \n", [.font: Self.bodyFont, .paragraphStyle: style(context, spacing: 8), .noteBlock: NoteBlock.rule.rawValue])
        case let html as HTMLBlock:
            code(html.rawHTML, context: context, line: line)
        default:
            if markup.childCount > 0 {
                blocks(markup, &context)
            } else {
                append(markup.format() + "\n", [.font: Self.bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style(context, spacing: 6)])
            }
        }
    }

    private func listItems(_ items: [ListItem], ordered start: Int?, _ context: inout Context) {
        for (index, item) in items.enumerated() {
            var inner = context
            let number = start.map { "\($0 + index)." }
            let checkbox = item.checkbox.map { $0 == .checked ? "☑" : "☐" }
            inner.marker = [number ?? (checkbox == nil ? "•" : nil), checkbox].compactMap { $0 }.joined(separator: " ")
            inner.markerWidth = start == nil ? (checkbox == nil ? 14 : 20) : 22
            inner.indent += inner.markerWidth + 4
            blocks(item, &inner)
        }
    }

    private func style(_ context: Context, spacing: CGFloat, before: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = context.indent
        style.headIndent = context.indent
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = before
        style.lineHeightMultiple = 1.05
        return style
    }

    private func paragraph(_ markup: Markup, font: NSFont, context: inout Context, line: Int?, spacingBefore: CGFloat = 0) {
        let style = style(context, spacing: 6, before: spacingBefore)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: context.quoted ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: style,
        ]
        if let line { attributes[.noteMarkdownLine] = line }
        if context.quoted { attributes[.noteBlock] = NoteBlock.quote.rawValue }
        let start = out.length
        if let marker = context.marker {
            // Hanging marker: the marker sits in the indent, wrapped lines align with the text.
            style.firstLineHeadIndent = context.indent - context.markerWidth - 4
            style.tabStops = [NSTextTab(textAlignment: .left, location: context.indent)]
            append(marker + "\t", attributes.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 })
            context.marker = nil
        }
        prose(markup, attributes, into: out)
        append("\n", attributes)
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
    }

    // MARK: Inlines

    /// A paragraph's, heading's or table cell's inlines with their `path:line` references
    /// linked, found in the text as it reads: markdown splits `src/_compat.py:3` into several
    /// text runs, and a reference may be prose, inline code, or both.
    private func prose(_ markup: Markup, _ attributes: [NSAttributedString.Key: Any], into target: NSMutableAttributedString) {
        let start = target.length
        inlines(markup, attributes, into: target)
        let range = NSRange(location: start, length: target.length - start)
        linkReferences(in: (target.string as NSString).substring(with: range), at: start, of: target)
    }

    private func inlines(_ markup: Markup, _ attributes: [NSAttributedString.Key: Any], into target: NSMutableAttributedString) {
        for child in markup.children { inline(child, attributes, into: target) }
    }

    private func inline(_ markup: Markup, _ attributes: [NSAttributedString.Key: Any], into target: NSMutableAttributedString) {
        var attributes = attributes
        let font = attributes[.font] as? NSFont ?? Self.bodyFont
        switch markup {
        case let text as Markdown.Text:
            target.append(NSAttributedString(string: text.string, attributes: attributes))
        case is Emphasis:
            attributes[.font] = Self.font(font, adding: .italic)
            inlines(markup, attributes, into: target)
        case is Strong:
            attributes[.font] = Self.font(font, adding: .bold)
            inlines(markup, attributes, into: target)
        case is Strikethrough:
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            inlines(markup, attributes, into: target)
        case let code as InlineCode:
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
            attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.25)
            target.append(NSAttributedString(string: code.code, attributes: attributes))
        case let link as Markdown.Link:
            if let destination = link.destination, let parsed = NoteLink(encoded: destination) {
                attributes[.noteLink] = parsed.encoded
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            inlines(markup, attributes, into: target)
        case let image as Markdown.Image:
            if let source = image.source, let picture = images[source] {
                let attachment = NoteImageAttachment()
                attachment.image = picture
                attachment.allowsTextAttachmentView = false
                attributes[.attachment] = attachment
                target.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
            } else {
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
                target.append(NSAttributedString(string: "[image: \(image.plainText)]", attributes: attributes))
            }
        case let html as InlineHTML:
            target.append(NSAttributedString(string: html.rawHTML, attributes: attributes))
        case is SoftBreak:
            target.append(NSAttributedString(string: " ", attributes: attributes))
        case is LineBreak:
            target.append(NSAttributedString(string: "\u{2028}", attributes: attributes))
        case let symbol as SymbolLink:
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
            target.append(NSAttributedString(string: symbol.destination ?? "", attributes: attributes))
        default:
            if markup.childCount > 0 {
                inlines(markup, attributes, into: target)
            } else {
                target.append(NSAttributedString(string: markup.format(), attributes: attributes))
            }
        }
    }

    public static func font(_ font: NSFont, adding trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait)), size: font.pointSize) ?? font
    }

    /// `path:line` references in authored text open a code tile. Text that is already a
    /// markdown link's keeps its destination.
    private func linkReferences(in text: String, at offset: Int, of target: NSMutableAttributedString) {
        for reference in NoteReferences.find(in: text) {
            let range = NSRange(location: offset + reference.range.location, length: reference.range.length)
            var linked = false
            target.enumerateAttribute(.noteLink, in: range) { value, _, stop in
                if value != nil {
                    linked = true
                    stop.pointee = true
                }
            }
            guard !linked else { continue }
            target.addAttributes([
                .noteLink: NoteLink.code(path: reference.path, lines: reference.lines).encoded,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: range)
        }
    }

    // MARK: Tables

    /// Room between table columns.
    static let columnGap: CGFloat = 18
    /// Narrowest a column is squeezed to (unless its content is narrower) before the table no
    /// longer fits and is cut: below its longest word or link a column breaks inside words.
    static let minColumnWidth: CGFloat = 36

    /// A table as tab-aligned rows, one paragraph per row, each cell wrapped to its column
    /// (`columnWidths`): a cell's lines stack in its column, separated by line separators, so a
    /// row stays one block (its band, its markdown line, its mention) however many lines it takes.
    private func table(_ table: Table, context: Context, line: Int?) {
        let header = Array(table.head.cells)
        let rows = [header] + table.body.rows.map { Array($0.cells) }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        let bold = Self.font(Self.bodyFont, adding: .bold)
        let rendered = rows.enumerated().map { index, cells in
            cells.map { cell -> NSAttributedString in
                let text = NSMutableAttributedString()
                prose(cell, [.font: index == 0 ? bold : Self.bodyFont, .foregroundColor: NSColor.labelColor], into: text)
                return text
            }
        }
        let left = context.indent + 4
        // A point of slack: TextKit must never find the last column a hair too wide and wrap it.
        let layout = Self.columnWidths(rendered, columns: columns, available: lineWidth - left - CGFloat(columns - 1) * Self.columnGap - 1)
        fitsWidth = true
        tableShortfall = max(tableShortfall, layout.shortfall)
        var stops: [NSTextTab] = []
        var x = left
        for width in layout.widths.dropLast() {
            x += width + Self.columnGap
            stops.append(NSTextTab(textAlignment: .left, location: x))
        }
        for (index, cells) in rendered.enumerated() {
            let style = style(context, spacing: index == rendered.count - 1 ? 8 : 2)
            style.firstLineHeadIndent = left
            style.headIndent = left
            style.tabStops = stops
            // A table too wide for the note even with its words broken keeps a line per row, cut
            // with "…" at the note's edge.
            let cut = layout.shortfall > 0
            style.lineBreakMode = cut ? .byTruncatingTail : .byWordWrapping
            let wrapped = cells.enumerated().map { column, cell in cut ? [cell] : Self.wrap(cell, width: layout.widths[column]) }
            let start = out.length
            for row in 0..<(wrapped.map(\.count).max() ?? 1) {
                if row > 0 { append("\u{2028}", [.font: Self.bodyFont]) }
                let last = wrapped.lastIndex { row < $0.count } ?? 0
                for column in 0...last where column < wrapped.count {
                    if column > 0 { append("\t", [.font: Self.bodyFont]) }
                    if row < wrapped[column].count { out.append(wrapped[column][row]) }
                }
            }
            append("\n", [.font: Self.bodyFont])
            var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: style]
            if index == 0 { attributes[.noteBlock] = NoteBlock.tableHeader.rawValue }
            // Body rows follow the delimiter row.
            if let line { attributes[.noteMarkdownLine] = line + index + (index > 0 ? 1 : 0) }
            out.addAttributes(attributes, range: NSRange(location: start, length: out.length - start))
        }
    }

    /// Column widths for `rows` of cells in `available` points (the gaps already taken out), as a
    /// browser lays out an automatic table: every column as wide as its widest cell when they all
    /// fit; else each keeps its longest unbreakable run (a word, or a whole link or code span, so a
    /// `path:line` stays on one line) and the room left goes to the columns with the most text
    /// to wrap; else the widest runs break inside, down to `minColumnWidth`; past that it is cut
    /// (columns as wide as their widest cell, rows unwrapped) and `shortfall` says how much more
    /// room would let it wrap instead.
    static func columnWidths(_ rows: [[NSAttributedString]], columns: Int, available: CGFloat) -> (widths: [CGFloat], shortfall: CGFloat) {
        var natural = [CGFloat](repeating: 0, count: columns)
        var unbreakable = [CGFloat](repeating: 0, count: columns)
        for cells in rows {
            for (column, cell) in cells.enumerated() {
                natural[column] = max(natural[column], measure(cell))
                for run in runs(of: cell) { unbreakable[column] = max(unbreakable[column], measure(cell.attributedSubstring(from: run))) }
            }
        }
        let least = natural.map { min($0, minColumnWidth) }
        let minimum = zip(unbreakable, least).map { max($0, $1) }
        /// `from` widths, each grown toward its `to` by a share of `room` proportional to its gap.
        func grow(_ from: [CGFloat], toward to: [CGFloat], room: CGFloat) -> [CGFloat] {
            let gaps = zip(to, from).map { $0 - $1 }
            let total = gaps.reduce(0, +)
            guard total > 0 else { return from }
            return zip(from, gaps).map { ($0 + $1 * room / total).rounded(.down) }
        }
        let sum = { (widths: [CGFloat]) in widths.reduce(0, +) }
        if sum(natural) <= available { return (natural, 0) }
        if sum(minimum) <= available { return (grow(minimum, toward: natural, room: available - sum(minimum)), 0) }
        if sum(least) <= available {
            // The widest runs break first: each column keeps its longest run up to a cap as high
            // as the room allows, so a long citation breaks before a timestamp does.
            let capped = { (cap: CGFloat) in zip(least, minimum).map { max($0, min($1, cap)) } }
            var low: CGFloat = 0
            var high = minimum.max() ?? 0
            for _ in 0..<24 {
                let cap = (low + high) / 2
                if sum(capped(cap)) <= available { low = cap } else { high = cap }
            }
            return (capped(low).map { $0.rounded(.down) }, 0)
        }
        return (natural, (sum(least) - available).rounded(.up))
    }

    /// Width `text` draws at on one line.
    private static func measure(_ text: NSAttributedString) -> CGFloat {
        ceil(text.size().width)
    }

    /// The runs of a cell a line may not break inside, in order: words between spaces, where a
    /// link or a code span counts as one word with the text touching it (`(a/b.py:3),`).
    static func runs(of cell: NSAttributedString) -> [NSRange] {
        let text = cell.string as NSString
        var protected = IndexSet()
        cell.enumerateAttributes(in: NSRange(location: 0, length: cell.length)) { attributes, range, _ in
            if attributes[.noteLink] != nil || attributes[.backgroundColor] != nil { protected.insert(integersIn: range.location..<NSMaxRange(range)) }
        }
        var runs: [NSRange] = []
        var start: Int?
        for index in 0..<text.length {
            let breaks = !protected.contains(index) && CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(text.character(at: index)) ?? "x")
            if breaks {
                if let open = start { runs.append(NSRange(location: open, length: index - open)) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let open = start { runs.append(NSRange(location: open, length: text.length - open)) }
        return runs
    }

    /// `cell` in lines at most `width` wide: whole runs (`runs(of:)`) while they fit, a run wider
    /// than the column broken after its last `/`, `.`, `-`, `_`, `:` or `,` that fits, else
    /// between characters. Every line keeps its text's attributes: a wrapped link links on both.
    static func wrap(_ cell: NSAttributedString, width: CGFloat) -> [NSAttributedString] {
        let text = cell.string as NSString
        var lines: [NSAttributedString] = []
        var line: NSRange?
        for run in runs(of: cell) {
            if let open = line {
                let joined = NSRange(location: open.location, length: NSMaxRange(run) - open.location)
                if measure(cell.attributedSubstring(from: joined)) <= width {
                    line = joined
                    continue
                }
                lines.append(cell.attributedSubstring(from: open))
            }
            var rest = run
            while measure(cell.attributedSubstring(from: rest)) > width {
                let cut = breakOffset(in: rest, of: cell, text: text, width: width)
                lines.append(cell.attributedSubstring(from: NSRange(location: rest.location, length: cut)))
                rest = NSRange(location: rest.location + cut, length: rest.length - cut)
            }
            line = rest
        }
        if let line { lines.append(cell.attributedSubstring(from: line)) }
        return lines.isEmpty ? [NSAttributedString()] : lines
    }

    /// Length of the longest start of `range` that fits `width` (at least one character), cut
    /// back to just after a path or word separator when one lies in its latter two thirds.
    private static func breakOffset(in range: NSRange, of cell: NSAttributedString, text: NSString, width: CGFloat) -> Int {
        var ends: [Int] = []
        var index = range.location
        while index < NSMaxRange(range) {
            index = NSMaxRange(text.rangeOfComposedCharacterSequence(at: index))
            ends.append(index - range.location)
        }
        var low = 0
        var high = ends.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if measure(cell.attributedSubstring(from: NSRange(location: range.location, length: ends[middle]))) <= width { low = middle } else { high = middle - 1 }
        }
        let fits = ends[low]
        let separators = CharacterSet(charactersIn: "/.-_:,\\")
        for length in stride(from: fits, to: fits / 3, by: -1) where length < range.length {
            if let scalar = Unicode.Scalar(text.character(at: range.location + length - 1)), separators.contains(scalar) { return length }
        }
        return fits
    }

    // MARK: Fences

    private func fence(_ block: CodeBlock, context: Context, line: Int) {
        let key = (block.language ?? "").trimmingCharacters(in: .whitespaces)
        let fence = NoteFence(info: key)
        let body = NoteSource.lines(of: block.code)
        switch fence.mode {
        case .free:
            rows(body.map { ($0, nil, NoteBlock.authored, nil) }, context: context, markdownLine: line + 1, numberWidth: 0, referenceLinks: true)
        case .excerpt, .propose:
            anchored(fence, excerpt: excerpts[key], body: body, context: context, line: line)
        }
    }

    private func anchored(_ fence: NoteFence, excerpt: NoteExcerpt?, body: [String], context: Context, line: Int) {
        let proposing = fence.mode == .propose
        guard let excerpt else {
            caption(fence, excerpt: nil, context: context, line: line)
            let shown: [(text: String, number: Int?, block: NoteBlock, row: NoteCodeRow?)] = asWritten
                ? body.map { ($0, nil, proposing ? .authored : .excerpt, nil) } : [("loading…", nil, .excerpt, nil)]
            rows(shown, context: context, markdownLine: line, numberWidth: 0, referenceLinks: false)
            return
        }
        caption(fence, excerpt: excerpt, context: context, line: line)
        guard let range = excerpt.range else {
            // Stale: what the excerpt last showed (or, for a proposal or a never-resolved excerpt,
            // the fence body), marked so nobody mistakes it for the file's current text.
            let fallback = proposing || excerpt.lines.isEmpty ? body : excerpt.lines
            rows(fallback.map { ($0, nil, proposing ? .authored : .excerpt, nil) }, context: context, markdownLine: line, numberWidth: 0, referenceLinks: false, dimmed: !proposing)
            return
        }
        let symbol = fence.symbol
        let width = String(range.end).count
        func row(_ number: Int) -> NoteCodeRow { NoteCodeRow(path: excerpt.path, line: number, symbol: symbol, commit: fence.commit) }
        if proposing, let diff = excerpt.diff {
            let lines = zip(diff, excerpt.proposalLines).map { entry, source -> (String, Int?, NoteBlock, NoteCodeRow?) in
                switch entry {
                case .same(_, _, let text): ("  " + text, source, .excerpt, row(source))
                case .removed(_, let text): ("- " + text, source, .removed, row(source))
                case .added(_, let text): ("+ " + text, nil, .added, row(source))
                }
            }
            rows(lines, context: context, markdownLine: line, numberWidth: width, referenceLinks: false)
        } else {
            let lines = excerpt.lines.enumerated().map { offset, text in (text, range.start + offset, NoteBlock.excerpt, Optional(row(range.start + offset))) }
            rows(lines, context: context, markdownLine: line, numberWidth: width, referenceLinks: false)
        }
    }

    /// `src/app.ts:10-40 · symbol X · @1a2b3c4 · was L8-38`, the path opening a code tile; a
    /// lost anchor says so in the caption, an applied proposal quietly too.
    private func caption(_ fence: NoteFence, excerpt: NoteExcerpt?, context: Context, line: Int) {
        let style = style(context, spacing: 0, before: 2)
        style.firstLineHeadIndent = context.indent + NoteBlockFragment.inset + 4
        style.lineBreakMode = .byTruncatingMiddle
        let base: [NSAttributedString.Key: Any] = [
            .font: Self.captionFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
            .noteBlock: NoteBlock.caption.rawValue, .noteMarkdownLine: line,
        ]
        let start = out.length
        if fence.mode == .propose { append("Proposed change · ", base.merging([.foregroundColor: NSColor.labelColor]) { $1 }) }
        let path = excerpt?.path ?? fence.path ?? ""
        let range = excerpt?.range ?? fence.lines
        let location = path + (range.map { $0.start == $0.end ? ":\($0.start)" : ":\($0.start)-\($0.end)" } ?? "")
        if !path.isEmpty {
            append(location, base.merging([.noteLink: NoteLink.code(path: path, lines: range).encoded, .foregroundColor: NSColor.linkColor]) { $1 })
        }
        var details: [String] = []
        if let symbol = fence.symbol { details.append("symbol \(symbol)") }
        if let commit = fence.commit { details.append("@\(commit)") }
        if case .relocated(let from)? = excerpt?.status { details.append(from.start == from.end ? "was L\(from.start)" : "was L\(from.start)-\(from.end)") }
        if excerpt?.applied == true { details.append("✓ applied") }
        if !details.isEmpty { append(" · " + details.joined(separator: " · "), base) }
        if case .stale(let reason)? = excerpt?.status {
            append("  ⚠ stale: \(reason)", base.merging([.foregroundColor: NSColor.systemOrange, .font: NSFont.systemFont(ofSize: 10.5, weight: .bold)]) { $1 })
        }
        append("\n", base)
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
    }

    /// One paragraph per code row, so each row can carry its own band and source line.
    private func rows(_ rows: [(text: String, number: Int?, block: NoteBlock, row: NoteCodeRow?)], context: Context, markdownLine: Int, numberWidth: Int, referenceLinks: Bool, dimmed: Bool = false) {
        let shown = rows.prefix(Self.maxRows)
        for (index, row) in shown.enumerated() {
            let last = index == shown.count - 1 && rows.count <= Self.maxRows
            let style = style(context, spacing: last ? 8 : 0, before: index == 0 && numberWidth == 0 && row.block == .authored ? 2 : 0)
            style.firstLineHeadIndent = context.indent + NoteBlockFragment.inset + 4
            style.headIndent = style.firstLineHeadIndent
            style.lineBreakMode = .byTruncatingTail
            style.lineHeightMultiple = 1
            var attributes: [NSAttributedString.Key: Any] = [
                .font: Self.codeFont,
                .foregroundColor: dimmed ? NSColor.tertiaryLabelColor : NSColor.labelColor,
                .paragraphStyle: style,
                .noteBlock: row.block.rawValue,
                .noteMarkdownLine: markdownLine + (referenceLinks ? index : 0),
            ]
            if let codeRow = row.row { attributes[.noteCodeRow] = codeRow }
            if numberWidth > 0 {
                let number = row.number.map(String.init) ?? ""
                append(String(repeating: " ", count: max(0, numberWidth - number.count)) + number + "  ", attributes.merging([.foregroundColor: NSColor.tertiaryLabelColor]) { $1 })
            }
            let text = row.text.replacingOccurrences(of: "\t", with: "    ")
            let textStart = out.length
            append(text, attributes)
            if referenceLinks { linkReferences(in: text, at: textStart, of: out) }
            append("\n", attributes)
        }
        if rows.count > Self.maxRows {
            append("… \(rows.count - Self.maxRows) more lines\n", [.font: Self.captionFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style(context, spacing: 8)])
        }
    }

    private func code(_ text: String, context: Context, line: Int?) {
        rows(NoteSource.lines(of: text).map { ($0, nil, NoteBlock.authored, nil) }, context: context, markdownLine: line ?? 1, numberWidth: 0, referenceLinks: false)
    }

    private func append(_ string: String, _ attributes: [NSAttributedString.Key: Any]) {
        out.append(NSAttributedString(string: string, attributes: attributes))
    }
}

/// A note's `![alt](path)` picture: its natural size, scaled down to the line's width (never up),
/// drawn by the text layout itself (no attachment view), so on-screen notes, renders, and
/// `ObjectMeasure` all lay it out the same way.
final class NoteImageAttachment: NSTextAttachment {
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
                                   proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return .zero }
        let width = min(size.width, max(1, proposedLineFragment.width - position.x - 4))
        return CGRect(x: 0, y: 0, width: width, height: (size.height * width / size.width).rounded())
    }
}

/// The images a note's markdown shows: board-relative paths, and absolute paths (or `file://`
/// URLs) inside the board root or the temp directory (`LocalImage.sandboxed`), read off the main
/// thread. Keyed by the markdown destination as written.
@MainActor
public enum NoteImages {
    public static func sources(in document: Document) -> [String] {
        var out: [String] = []
        func walk(_ markup: Markup) {
            if let image = markup as? Markdown.Image, let source = image.source, !source.isEmpty, !out.contains(source) { out.append(source) }
            for child in markup.children { walk(child) }
        }
        walk(document)
        return out
    }

    /// The files `sources` name, where a note may show them.
    public static func files(_ sources: [String], root: URL) -> [String: URL] {
        var files: [String: URL] = [:]
        for source in sources { files[source] = LocalImage.sandboxed(source, root: root) }
        return files
    }

    public static func load(_ sources: [String], root: URL) async -> [String: NSImage] {
        var images: [String: NSImage] = [:]
        for (source, file) in files(sources, root: root) {
            guard let read = await LocalImage.read(file), let image = NSImage(data: read.data) else { continue }
            image.size = read.size
            images[source] = image
        }
        return images
    }
}
