import CoreGraphics

/// Geometry of a code tile in points, shared by the renderer (which must obey it) and layout
/// (`object.measure`, `size: "fit"`). Rows are a fixed height; text is the system monospaced
/// font at `fontSize`, so every column (after expanding tabs to `tabWidth` columns) is
/// `charAdvance` wide. Lines wider than the text column soft-wrap onto continuation rows
/// (`wrap(_:columns:)`); nothing scrolls sideways.
///
/// The object's frame, top to bottom: the tile title bar, the code header, the optional caption
/// strip, the follow history strip (follow tiles only), then `verticalPadding`, the rows, and
/// `verticalPadding` again. Left to right: the gutter (line numbers and change signs), the
/// text, `trailingPadding`.
public enum CodeMetrics {
    public static let fontSize: CGFloat = 12
    /// Advance of every glyph of `NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)`.
    public static let charAdvance: CGFloat = 7.41796875
    public static let rowHeight: CGFloat = 16
    /// Baseline from the top of a row.
    public static let baseline: CGFloat = 12
    public static let tabWidth = 4

    /// The tile chrome's title bar (every tile type), at the top of the frame.
    public static let titleHeight = CGFloat(RenderMath.tileTitleHeight)
    /// Code header: diff base, change navigation, status and warnings.
    public static let headerHeight: CGFloat = 26
    /// The one-line `caption` strip under the header (truncated, never wraps).
    public static let captionHeight: CGFloat = 20
    /// Caption text's inset from the tile's left and right edges.
    public static let captionInset: CGFloat = 8
    /// Recent-locations strip under the header of follow tiles.
    public static let historyHeight: CGFloat = 22
    /// Above the first row and below the last.
    public static let verticalPadding: CGFloat = 4

    /// Line numbers get at least this many digits, so tiles over files of up to 9,999 lines
    /// share one gutter width.
    public static let minLineNumberDigits = 4
    /// Left of the line numbers.
    public static let gutterLeading: CGFloat = 4
    /// Between the line numbers and the change-sign column.
    public static let signGap: CGFloat = 5
    /// The change-sign column (added/modified bars, deleted wedges).
    public static let signWidth: CGFloat = 4
    /// Between the sign column and the text.
    public static let textGap: CGFloat = 7
    public static let trailingPadding: CGFloat = 12
    /// Narrowest frame the header controls fit in.
    public static let minWidth: CGFloat = 280
    /// Text columns a code tile is widened to hold when nobody names its width.
    public static let autoColumns = 200
    /// Widest frame `size: "fit"` and `object.measure` give a code tile when the caller names no
    /// width, and the widest a new tile without a frame gets (`autoWidth`): `autoColumns` columns
    /// beside a 4-digit gutter, so lines past the usual formatter limits (80–120) stay unwrapped
    /// too, while one minified or generated line can't stretch a tile across a whole board.
    public static let defaultFitWidth = (gutterWidth(lineCount: 1) + CGFloat(autoColumns) * charAdvance + trailingPadding).rounded(.up)
    /// Continuation rows start this many columns right of their line's indentation.
    public static let wrapIndent = 2

    public static func lineNumberDigits(lineCount: Int) -> Int {
        max(minLineNumberDigits, String(max(1, lineCount)).count)
    }

    /// Width of everything left of the text for a file of `lineCount` lines.
    public static func gutterWidth(lineCount: Int) -> CGFloat {
        (gutterLeading + CGFloat(lineNumberDigits(lineCount: lineCount)) * charAdvance + signGap + signWidth + textGap).rounded(.up)
    }

    /// Text columns a code tile `width` points wide shows (its rows wrap there), for a file of
    /// `lineCount` lines; at least 1.
    public static func textColumns(width: CGFloat, lineCount: Int) -> Int {
        // A frame sized for N columns (`size`, rounded up) must show N despite float error.
        max(1, Int(((width - gutterWidth(lineCount: lineCount) - trailingPadding) / charAdvance + 0.001).rounded(.down)))
    }

    /// Height above the first row's padding, inside the object's frame.
    public static func chromeHeight(caption: Bool, history: Bool = false) -> CGFloat {
        titleHeight + headerHeight + (caption ? captionHeight : 0) + (history ? historyHeight : 0)
    }

    /// Full object frame that shows `lines` rows of at most `longestLine` columns (tabs
    /// expanded) without scrolling, for files of up to 9,999 lines.
    public static func size(lines: Int, longestLine: Int, caption: Bool) -> CGSize {
        var size = content(rows: lines, longestLine: longestLine, gutterWidth: gutterWidth(lineCount: 1), headerHeight: chromeHeight(caption: caption) - titleHeight)
        size.height += titleHeight
        return size
    }

    /// A code tile's content (its body, below the title bar) showing `rows` rows of at most
    /// `longestLine` columns beside a `gutterWidth` gutter, under header strips `headerHeight`
    /// tall: what `view.render` reports as its `contentSize`.
    public static func content(rows: Int, longestLine: Int, gutterWidth: CGFloat, headerHeight: CGFloat) -> CGSize {
        let width = gutterWidth + CGFloat(max(0, longestLine)) * charAdvance + trailingPadding
        let height = headerHeight + 2 * verticalPadding + CGFloat(max(1, rows)) * rowHeight
        return CGSize(width: max(minWidth, width.rounded(.up)), height: height.rounded(.up))
    }

    /// Frame width of a new code tile without a frame (opened by a click or created without one)
    /// over a file of `lineCount` lines whose longest is `longestLine` columns: `defaultWidth`,
    /// widened so that line doesn't wrap, up to `defaultFitWidth`. Never narrower than the default.
    public static func autoWidth(longestLine: Int, lineCount: Int, defaultWidth: CGFloat) -> CGFloat {
        let needed = (gutterWidth(lineCount: lineCount) + CGFloat(longestLine) * charAdvance + trailingPadding).rounded(.up)
        return max(defaultWidth, min(needed, defaultFitWidth))
    }

    /// The columns of `text`'s longest line (tabs expanded, carriage returns not counted) and
    /// its number of lines, a final newline ending the last line rather than starting another.
    public static func longestLine(in text: String) -> (columns: Int, lines: Int) {
        var longest = 0, column = 0, lines = 0, open = false
        for unit in text.utf16 {
            switch unit {
            case 0x0A:
                longest = max(longest, column)
                column = 0
                lines += 1
                open = false
            case 0x0D: continue
            case 0x09:
                column += tabWidth - column % tabWidth
                open = true
            default:
                column += columns(of: unit)
                open = true
            }
        }
        return (max(longest, column), lines + (open ? 1 : 0))
    }

    /// Columns one UTF-16 unit other than a tab takes. East Asian wide and fullwidth characters
    /// take 2 (the font fallback draws them about 1.6 columns wide, so a row never overflows);
    /// a surrogate pair (emoji and other astral characters) takes 2, all on its high half.
    public static func columns(of unit: UInt16) -> Int {
        switch unit {
        case 0xD800...0xDBFF: 2
        case 0xDC00...0xDFFF: 0
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6: 2
        default: 1
        }
    }

    /// Columns a line occupies with tabs expanded to the next multiple of `tabWidth`.
    public static func columns(_ line: some StringProtocol) -> Int {
        columns(units: line.utf16)
    }

    public static func columns(units: some Sequence<UInt16>) -> Int {
        var column = 0
        for unit in units {
            column += unit == 0x09 ? tabWidth - column % tabWidth : columns(of: unit)
        }
        return column
    }

    /// How a line soft-wraps at `columns` text columns: the UTF-16 offsets (within the line)
    /// where its continuation rows start, and the columns those rows are indented by (the line's
    /// own indentation plus `wrapIndent`, at most half the row). No breaks when the line fits.
    /// Breaks fall between characters, never inside a surrogate pair; every row holds at least
    /// one. Tabs expand against the unwrapped line's columns, so a wrapped line draws the same
    /// spaces it would unwrapped.
    public static func wrap(_ units: some Sequence<UInt16>, columns: Int) -> (breaks: [Int], indent: Int) {
        var breaks: [Int] = []
        var indent = 0
        var limit = max(1, columns)
        var virtual = 0, used = 0, leading = 0
        var inLeading = true
        var offset = 0, rowStart = 0
        for unit in units {
            let width = unit == 0x09 ? tabWidth - virtual % tabWidth : self.columns(of: unit)
            if inLeading {
                if unit == 0x20 || unit == 0x09 { leading += width } else { inLeading = false }
            }
            if width > 0, used + width > limit, offset > rowStart {
                if breaks.isEmpty {
                    indent = min(leading + wrapIndent, max(1, columns) / 2)
                    limit = max(1, columns - indent)
                }
                breaks.append(offset)
                rowStart = offset
                used = 0
            }
            used += width
            virtual += width
            offset += 1
        }
        return (breaks, indent)
    }

    // MARK: Scroll rule and line anchors

    /// Rows of context shown above a range when the viewport has room for them and the range.
    public static let rangeContext = 3

    /// Scroll offset (points from the top of the rows, before `verticalPadding`) that shows the
    /// range starting at visual row `row` and `count` rows long in a rows viewport `viewport`
    /// points tall: the range's first row near the top with up to `rangeContext` rows of context
    /// above it, fewer when the viewport can't show that context and all `count` rows too (a
    /// tile sized to fit its range shows exactly the range). Clamped to the content when
    /// `totalRows` is known.
    public static func scrollOffset(toRow row: Int, count: Int, viewport: CGFloat, totalRows: Int?) -> CGFloat {
        let visible = Int(((viewport - verticalPadding) / rowHeight).rounded(.down))
        let context = max(0, min(rangeContext, visible - count))
        var offset = CGFloat(max(0, row - context)) * rowHeight
        if let totalRows {
            let content = 2 * verticalPadding + CGFloat(max(1, totalRows)) * rowHeight
            offset = min(offset, max(0, content - viewport))
        }
        return max(0, offset)
    }

    /// Visual rows a rows viewport `viewport` points tall shows when scrolled by `scroll`: rows
    /// never draw into the `verticalPadding` bands, and a sliver under a point doesn't count.
    /// Clamped to `totalRows`.
    public static func visibleRows(scroll: CGFloat, viewport: CGFloat, totalRows: Int) -> Range<Int> {
        let top = scroll, bottom = scroll + viewport - 2 * verticalPadding
        let first = max(0, Int(((top + 1) / rowHeight).rounded(.down)))
        let end = min(totalRows, Int(((bottom - 1) / rowHeight).rounded(.up)))
        return first..<max(first, end)
    }

    /// Whether a code tile tints its range (visual rows `range`): only while it shows rows
    /// outside it. When the range fills everything visible (a tile fitted to its range, a
    /// whole-file range) the tint would mark every row and say nothing.
    public static func tintsRange(_ range: Range<Int>, scroll: CGFloat, viewport: CGFloat, totalRows: Int) -> Bool {
        let visible = visibleRows(scroll: scroll, viewport: viewport, totalRows: totalRows)
        return !visible.isEmpty && (visible.lowerBound < range.lowerBound || visible.upperBound > range.upperBound)
    }

    /// Where an arrow bound to `line` attaches on a code tile, in points from the top of its
    /// frame: the middle of the line's first visual row (`rows`, or one row per line), with the
    /// rows scrolled by `scroll` below `rowsTop`, clamped into the rows viewport
    /// (`rowsTop`…`frameHeight`), so a line scrolled out of view pins the end to the top or
    /// bottom edge of the code.
    public static func lineY(line: Int, rows: CodeRows?, scroll: CGFloat, rowsTop: CGFloat, frameHeight: CGFloat) -> CGFloat {
        let row = rows?.index(ofLine: line) ?? max(0, line - 1)
        let y = rowsTop + verticalPadding + CGFloat(row) * rowHeight - scroll + rowHeight / 2
        return min(max(y, rowsTop), max(rowsTop, frameHeight))
    }

    /// `lineY` for a code tile at `frame` with `props` as it shows them freshly aimed: scrolled to
    /// `props.range` by `scrollOffset`, its body zoomed by `props.zoom` under a 1× title bar.
    /// Canvas y. `rows` (wrapped at the tile's natural width) nil: one row per line, content
    /// length unknown. Live tiles use their real scroll instead (the user may have scrolled).
    public static func lineY(line: Int, frame: Frame, props: JSONValue, rows: CodeRows?) -> CGFloat {
        let zoom = ObjectZoom.of(props), natural = ObjectZoom.natural(frame, zoom: zoom)
        let y = naturalLineY(line: line, frameHeight: CGFloat(natural.h), props: props, rows: rows)
        return CGFloat(frame.y) + titleHeight + CGFloat(zoom) * (y - titleHeight)
    }

    /// `lineY` in the tile's own points from the top of its frame, for a natural frame
    /// `frameHeight` tall, freshly aimed.
    public static func naturalLineY(line: Int, frameHeight: CGFloat, props: JSONValue, rows: CodeRows?) -> CGFloat {
        let caption = props["caption"]?.string.map { !$0.isEmpty } ?? false
        let history = props["followOf"]?.string != nil && !(props["history"]?.array?.isEmpty ?? true)
        let rowsTop = chromeHeight(caption: caption, history: history)
        let viewport = max(0, frameHeight - rowsTop)
        var scroll: CGFloat = 0
        if let start = props["range"]?["start"]?.int {
            let end = max(start, props["range"]?["end"]?.int ?? start)
            // All rows of the range, wrapped lines' continuations included.
            let first = rows?.index(ofLine: start) ?? max(0, start - 1)
            let stop = rows?.rows(ofLine: end).upperBound ?? end
            scroll = scrollOffset(toRow: first, count: stop - first, viewport: viewport, totalRows: rows?.count)
        }
        return lineY(line: line, rows: rows, scroll: scroll, rowsTop: rowsTop, frameHeight: frameHeight)
    }
}
