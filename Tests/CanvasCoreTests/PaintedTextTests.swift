import AppKit
import Testing
import CanvasCore

/// A question tile's text, laid out for selecting and clicking: carets go by insertion points (into
/// a ligature, never into an emoji), and a link's areas and a selection's highlight come from the
/// same carets.
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

    @Test func aCaretNeverSplitsAnEmojiAndStopsAtTheTextsEnds() throws {
        let text = painted("a😀b")
        let before = try caret(1, in: text), after = try caret(3, in: text)
        #expect(text.offset(at: CGPoint(x: before + (after - before) * 0.75, y: text.rect.midY)) == 3, "past its middle: after it, never offset 2")
        #expect(text.offset(at: CGPoint(x: before + (after - before) * 0.25, y: text.rect.midY)) == 1)
        #expect(text.offset(at: CGPoint(x: text.rect.maxX, y: text.rect.minY - 1)) == 0)
        #expect(text.offset(at: CGPoint(x: text.rect.minX, y: text.rect.maxY + 1)) == 4)
    }

    /// A link that wraps takes clicks on each line it runs over, only where its text is; selecting
    /// the same characters highlights from the same start and runs to the edge on all but its
    /// last line, as a text view does.
    @Test func aWrappedLinkIsClickableOnEachLineItRunsOver() throws {
        let text = painted("see https://example.com/a/very/long/path/that/wraps/over/lines here", width: 150)
        let link = try #require(text.links.first)
        #expect(link.areas.count >= 2)
        for area in link.areas {
            #expect(text.rect.insetBy(dx: -0.01, dy: -0.01).contains(area))
            #expect(text.link(at: CGPoint(x: area.midX, y: area.midY)) == link.match)
        }
        let selection = text.rects(for: link.match.range)
        #expect(selection.count == link.areas.count)
        let firstHighlight = try #require(selection.first)
        #expect(abs(firstHighlight.minX - link.areas[0].minX) < 0.01)
        for (highlight, area) in zip(selection.dropLast(), link.areas.dropLast()) {
            #expect(abs(highlight.maxX - text.rect.maxX) < 0.01)
            #expect(area.maxX <= text.rect.maxX + 0.01)
        }
        let lastHighlight = try #require(selection.last), lastArea = try #require(link.areas.last)
        #expect(abs(lastHighlight.maxX - lastArea.maxX) < 0.01)
        let here = try #require(text.rects(for: (text.string as NSString).range(of: "here")).first)
        #expect(text.link(at: CGPoint(x: here.midX, y: here.midY)) == nil, "the word after it")
    }
}
