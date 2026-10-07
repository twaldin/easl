import AppKit

/// Text a view paints itself, with what selecting it and clicking its links need (a question
/// tile's text, `QuestionPainter`). With nothing selected it is drawn by string drawing, as the
/// rest of such a page is, so the view shows the same pixels as a render of it. It is also laid
/// out by TextKit 1 the way string drawing lays it out (a layout manager, no line fragment
/// padding, the font's leading), which maps a point to the nearest caret and a range to the rects
/// it covers, in the view's own coordinates (the same at any zoom). Both go by insertion points,
/// as a text view does, so a caret can sit inside a ligature ("fi"), and what is highlighted is
/// exactly what is copied.
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

    /// The rects `range` covers, one per line it spans, from caret to caret. `selected`: as a
    /// text view highlights a selection, a line the range runs on past reaches the right edge.
    public func rects(for range: NSRange, selected: Bool = true) -> [CGRect] {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return [] }
        var rects: [CGRect] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { fragment, _, _, glyphs, _ in
            let line = self.layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let start = max(range.location, line.location), end = min(NSMaxRange(range), NSMaxRange(line))
            guard end > start else { return }
            let carets = self.carets(onLineAt: line.location)
            func x(_ offset: Int) -> CGFloat { carets.last { $0.offset <= offset }?.x ?? 0 }
            let left = range.location < line.location ? 0 : x(start)
            let right = selected && NSMaxRange(range) > NSMaxRange(line) ? fragment.width : x(end)
            rects.append(CGRect(x: self.rect.minX + fragment.minX + left, y: self.rect.minY + fragment.minY, width: max(0, right - left), height: fragment.height))
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
