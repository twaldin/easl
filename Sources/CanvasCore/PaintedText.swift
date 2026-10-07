import AppKit

/// Text a view paints itself, with what selecting it and clicking its links need (a question
/// tile's text, `QuestionPainter`). With nothing selected it is drawn by string drawing, as the
/// rest of such a page is, so the view shows the same pixels as a render of it. It is also laid
/// out by TextKit 1 the way string drawing lays it out (a layout manager, no line fragment
/// padding, the font's leading), which maps a point to the nearest caret and a range to the rects
/// it covers, in the view's own coordinates (the same at any zoom). Carets go by insertion points,
/// as a text view's do, so one can sit inside a ligature ("fi"); a selection is highlighted as
/// TextKit lays out its glyphs, in whichever direction each run goes, so what is highlighted is
/// exactly what is copied, in right-to-left and mixed text too.
@MainActor
public final class PaintedText {
    /// A web link in the text and where it is drawn: a rect per line it runs over, each as wide
    /// as its text there.
    public struct Link {
        public let match: WebLink.Match
        public let areas: [CGRect]
    }

    public let rect: CGRect
    public let string: String
    public private(set) var links: [Link] = []
    private let text: NSAttributedString
    private let storage: NSTextStorage
    private let layout = NSLayoutManager()
    private let container: NSTextContainer

    /// `text` wrapped to `rect`'s width from its origin, with `links` (`WebLink.matches` of it).
    public init(_ text: NSAttributedString, links: [WebLink.Match], in rect: CGRect) {
        self.text = text
        self.rect = rect
        string = text.string
        storage = NSTextStorage(attributedString: text)
        container = NSTextContainer(size: CGSize(width: max(1, rect.width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.usesFontLeading = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        // Laid out before anything asks: asked first, the range of "i" in a line-initial "fi"
        // came back as its own glyph, which layout then made part of the ligature.
        layout.ensureLayout(for: container)
        self.links = links.map { Link(match: $0, areas: rects(for: $0.range, selected: false)) }
    }

    /// Draws the text in the current (flipped) context. `selection`: highlighted as a text view
    /// highlights it, its text in the selected text color (by TextKit, whose layout the highlight
    /// comes from: a ligature cut by the selection stays one glyph).
    public func draw(selected selection: NSRange? = nil) {
        guard let selection, selection.length > 0, NSMaxRange(selection) <= storage.length else {
            return text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        NSColor.selectedTextBackgroundColor.setFill()
        for area in rects(for: selection) { area.fill(using: .sourceOver) }
        layout.addTemporaryAttribute(.foregroundColor, value: NSColor.selectedTextColor, forCharacterRange: selection)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: rect.origin)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
    }

    /// The rects `range` covers. `selected`: as a text view highlights a selection, line by line,
    /// a span per visual run (a run of right-to-left text in a left-to-right line is one of its
    /// own), and a line the range runs on past reaches the right edge. Otherwise a link's areas:
    /// on each line it spans, from the caret where it starts there to the one where it ends.
    public func rects(for range: NSRange, selected: Bool = true) -> [CGRect] {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return [] }
        return selected ? highlight(range) : areas(range)
    }

    private func highlight(_ range: NSRange) -> [CGRect] {
        var whole = NSRange()
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: &whole)
        // A line at a time: over several lines TextKit joins the whole lines into one rect, which
        // a trim on the first or last line would cut across them all.
        var rects: [CGRect] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, line, _ in
            let slice = NSIntersectionRange(line, glyphs)
            guard slice.length > 0 else { return }
            self.layout.enumerateEnclosingRects(forGlyphRange: slice, withinSelectedGlyphRange: glyphs, in: self.container) { found, _ in rects.append(found) }
        }
        // A ligature the range starts or ends inside is one glyph, all of it in those rects: give
        // back the part of it outside the range, on its line only.
        if whole.location < range.location { rects = trim(rects, from: whole.location, to: range.location) }
        if NSMaxRange(whole) > NSMaxRange(range) { rects = trim(rects, from: NSMaxRange(range), to: NSMaxRange(whole)) }
        return rects.map { $0.offsetBy(dx: rect.minX, dy: rect.minY) }
    }

    /// `rects` (one line each) less the span between the carets at `start` and `end` (part of one
    /// ligature, on one line), cut from the edge of that line's rect it lies at, whichever side.
    private func trim(_ rects: [CGRect], from start: Int, to end: Int) -> [CGRect] {
        let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
        let carets = carets(onLineAt: start)
        func x(_ offset: Int) -> CGFloat { line.minX + (carets.last { $0.offset <= offset }?.x ?? 0) }
        let low = min(x(start), x(end)), high = max(x(start), x(end))
        return rects.map { rect in
            guard rect.minY < line.maxY, rect.maxY > line.minY else { return rect }
            if abs(rect.minX - low) < 0.5, high < rect.maxX { return CGRect(x: high, y: rect.minY, width: rect.maxX - high, height: rect.height) }
            if abs(rect.maxX - high) < 0.5, low > rect.minX { return CGRect(x: rect.minX, y: rect.minY, width: low - rect.minX, height: rect.height) }
            return rect
        }
    }

    private func areas(_ range: NSRange) -> [CGRect] {
        var rects: [CGRect] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { fragment, _, _, glyphs, _ in
            let line = self.layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let start = max(range.location, line.location), end = min(NSMaxRange(range), NSMaxRange(line))
            guard end > start else { return }
            let carets = self.carets(onLineAt: line.location)
            func x(_ offset: Int) -> CGFloat { carets.last { $0.offset <= offset }?.x ?? 0 }
            let left = min(x(start), x(end)), right = max(x(start), x(end))
            rects.append(CGRect(x: self.rect.minX + fragment.minX + left, y: self.rect.minY + fragment.minY, width: right - left, height: fragment.height))
        }
        return rects
    }

    /// The caret (UTF-16 offset) nearest `point`: the insertion point before or after the one
    /// under it, whichever is nearer, never inside a composed character (an emoji, a letter and
    /// its accent); above the text its start, below it its end.
    public func offset(at point: CGPoint) -> Int {
        guard storage.length > 0, point.y >= rect.minY else { return 0 }
        guard point.y < rect.maxY else { return storage.length }
        var fraction: CGFloat = 0
        let index = layout.characterIndex(for: CGPoint(x: point.x - rect.minX, y: point.y - rect.minY), in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < storage.length else { return storage.length }
        return fraction > 0.5 ? NSMaxRange((string as NSString).rangeOfComposedCharacterSequence(at: index)) : index
    }

    /// The link drawn under `point`.
    public func link(at point: CGPoint) -> WebLink.Match? {
        links.first { $0.areas.contains { $0.contains(point) } }?.match
    }

    /// The insertion points of the line holding character `index`, with their x from the line's start.
    private func carets(onLineAt index: Int) -> [(offset: Int, x: CGFloat)] {
        let count = layout.getLineFragmentInsertionPoints(forCharacterAt: index, alternatePositions: false, inDisplayOrder: false, positions: nil, characterIndexes: nil)
        var positions = [CGFloat](repeating: 0, count: count), offsets = [Int](repeating: 0, count: count)
        _ = layout.getLineFragmentInsertionPoints(forCharacterAt: index, alternatePositions: false, inDisplayOrder: false, positions: &positions, characterIndexes: &offsets)
        return zip(offsets, positions).map { ($0, $1) }
    }
}
