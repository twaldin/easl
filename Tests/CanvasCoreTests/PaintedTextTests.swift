import AppKit
import Testing
import CanvasCore

/// A question tile's text, laid out for selecting and clicking: carets go by insertion points (into
/// a ligature, never into an emoji), a selection is highlighted run by run in whichever direction
/// each goes (cut to the caret inside a ligature), and a link's areas end where its text does.
@MainActor
struct PaintedTextTests {
    func painted(_ string: String, font: NSFont = .systemFont(ofSize: 15, weight: .semibold), width: CGFloat = 432) -> PaintedText {
        let text = NSAttributedString(string: string, attributes: [.font: font])
        let height = ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        return PaintedText(text, links: WebLink.matches(in: string), in: CGRect(x: 14, y: 33, width: width, height: height))
    }

    /// Where the caret after the first `count` characters is (on the first line).
    func caret(_ count: Int, in text: PaintedText) throws -> CGFloat {
        try #require(text.rects(for: NSRange(location: 0, length: count)).first).maxX
    }

    /// Hoefler Text draws "ffi" in "office" as one glyph. Glyph hit-testing put every point in it
    /// at its start (offset 1); insertion points reach each letter, and the highlight ends at the
    /// same caret the press found, so what shows selected is what ⌘C copies.
    @Test func aCaretLandsInsideALigature() throws {
        let font = try #require(NSFont(name: "Hoefler Text", size: 30))
        let text = painted("office", font: font, width: 400)
        let carets = try (0...6).map { $0 == 0 ? text.rect.minX : try caret($0, in: text) }
        #expect(zip(carets, carets.dropFirst()).allSatisfy { $0 < $1 }, "a caret between each two letters, in the ligature too")
        for offset in 1...5 {
            #expect(text.offset(at: CGPoint(x: carets[offset] + 0.3, y: text.rect.midY)) == offset)
        }
        let selected = TextPress.range(from: 0, to: text.offset(at: CGPoint(x: carets[2] + 0.3, y: text.rect.midY)), in: text.string)
        #expect((text.string as NSString).substring(with: selected) == "of")
        let highlight = try #require(text.rects(for: selected).first)
        #expect(abs(highlight.maxX - carets[2]) < 0.01)
    }

    /// "file" starts with the "fi" ligature, and with three or four lines of it, lines start with
    /// one. A selection from inside the first one to the end leaves out only that "f"; every later
    /// line stays highlighted all across, its first "f" too (one rect for all the whole lines,
    /// trimmed for the first line's ligature, lost them).
    @Test func aSelectionFromInsideALineInitialLigatureKeepsTheLaterLines() throws {
        let font = try #require(NSFont(name: "Hoefler Text", size: 30))
        let text = painted("file file file file file file file", font: font, width: 130)
        let length = (text.string as NSString).length
        let spans = text.rects(for: NSRange(location: 1, length: length - 1))
        let first = try #require(text.rects(for: NSRange(location: 0, length: 1)).first)
        let last = try #require(text.rects(for: NSRange(location: length - 1, length: 1)).first)
        #expect(last.minY >= first.maxY + first.height, "at least three lines")
        for index in 0..<length {
            let letter = try #require(text.rects(for: NSRange(location: index, length: 1)).first)
            let shown = spans.contains { $0.insetBy(dx: -0.01, dy: -0.01).contains(CGPoint(x: letter.midX, y: letter.midY)) }
            #expect(shown == (index > 0), "character \(index)")
        }
    }

    @Test func aCaretNeverSplitsAnEmojiAndStopsAtTheTextsEnds() throws {
        let text = painted("a😀b")
        let before = try caret(1, in: text), after = try caret(3, in: text)
        #expect(text.offset(at: CGPoint(x: before + (after - before) * 0.75, y: text.rect.midY)) == 3, "past its middle: after it, never offset 2")
        #expect(text.offset(at: CGPoint(x: before + (after - before) * 0.25, y: text.rect.midY)) == 1)
        #expect(text.offset(at: CGPoint(x: text.rect.maxX, y: text.rect.minY - 1)) == 0)
        #expect(text.offset(at: CGPoint(x: text.rect.minX, y: text.rect.maxY + 1)) == 4)
    }

    /// A right-to-left word starts at the right: selected whole (a drag from one end to the
    /// other), it is highlighted across all of it, never as a zero-width span.
    @Test func aRightToLeftWordIsHighlightedWhole() throws {
        let word = "שלום"
        let text = painted(word)
        let whole = NSRange(location: 0, length: (word as NSString).length)
        let spans = text.rects(for: whole)
        #expect(spans.count == 1)
        let highlight = try #require(spans.first)
        let width = NSAttributedString(string: word, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]).size().width
        #expect(abs(highlight.width - width) < 0.5, "as wide as the word")
        let from = text.offset(at: CGPoint(x: highlight.maxX - 0.5, y: highlight.midY))
        let to = text.offset(at: CGPoint(x: highlight.minX + 0.5, y: highlight.midY))
        #expect(TextPress.range(from: from, to: to, in: text.string) == whole, "a drag across it selects all of it")
        for index in 0..<whole.length {
            let letter = try #require(text.rects(for: NSRange(location: index, length: 1)).first)
            #expect(highlight.insetBy(dx: -0.01, dy: -0.01).contains(letter))
        }
    }

    /// A right-to-left word in left-to-right text: a selection from before it into its first
    /// letters (which sit at its right) is two spans on the line, and the letters it leaves out,
    /// between them, stay unhighlighted.
    @Test func aSelectionAcrossDirectionsHighlightsEachRun() throws {
        let text = painted("abc שלום def")
        let spans = text.rects(for: NSRange(location: 1, length: 5))
        #expect(spans.count == 2)
        func highlighted(_ index: Int) throws -> Bool {
            let letter = try #require(text.rects(for: NSRange(location: index, length: 1)).first)
            return spans.contains { $0.insetBy(dx: -0.01, dy: -0.01).contains(CGPoint(x: letter.midX, y: letter.midY)) }
        }
        for index in 1...5 {
            let shown = try highlighted(index)
            #expect(shown, "character \(index) is selected")
        }
        for index in [0, 6, 7, 8, 9] {
            let shown = try highlighted(index)
            #expect(!shown, "character \(index) is not")
        }
    }

    /// A link that wraps takes clicks on each line it runs over, only where its text is; selecting
    /// the same characters highlights all of those areas, from the same start to the same end, and
    /// runs to the edge on all but its last line, as a text view does.
    @Test func aWrappedLinkIsClickableOnEachLineItRunsOver() throws {
        let text = painted("see https://example.com/a/very/long/path/that/wraps/over/lines here", width: 150)
        let link = try #require(text.links.first)
        #expect(link.areas.count >= 2)
        let selection = text.rects(for: link.match.range)
        for area in link.areas {
            #expect(text.rect.insetBy(dx: -0.01, dy: -0.01).contains(area))
            #expect(area.maxX <= text.rect.maxX + 0.01)
            #expect(text.link(at: CGPoint(x: area.midX, y: area.midY)) == link.match)
            #expect(selection.contains { $0.insetBy(dx: -0.01, dy: -0.01).contains(area) }, "highlighted where it takes clicks")
        }
        let firstHighlight = try #require(selection.first), firstArea = try #require(link.areas.first)
        #expect(abs(firstHighlight.minX - firstArea.minX) < 0.01 && abs(firstHighlight.minY - firstArea.minY) < 0.01)
        for highlight in selection.dropLast() {
            #expect(abs(highlight.maxX - text.rect.maxX) < 0.01)
        }
        let lastHighlight = try #require(selection.last), lastArea = try #require(link.areas.last)
        #expect(abs(lastHighlight.maxX - lastArea.maxX) < 0.01 && abs(lastHighlight.maxY - lastArea.maxY) < 0.01)
        let here = try #require(text.rects(for: (text.string as NSString).range(of: "here")).first)
        #expect(text.link(at: CGPoint(x: here.midX, y: here.midY)) == nil, "the word after it")
    }
}
