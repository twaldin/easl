import AppKit
import Testing
@testable import CanvasCore

/// Math in note tiles: `$…$` and `$$…$$` typeset with SwiftMath, and what stays literal.
@MainActor
struct NoteMathTests {
    func render(_ markdown: String, width: CGFloat = 400) -> NSAttributedString {
        NoteRenderer(excerpts: [:], source: markdown, width: width).render(NoteMarkdown.parse(markdown), placeholder: "")
    }

    /// The rendered math pictures in `text`, in order.
    func math(_ text: NSAttributedString) -> [NSTextAttachment] {
        var found: [NSTextAttachment] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { found.append(attachment) }
        }
        return found
    }

    @Test func inlineMathTypesetsAsMath() {
        let text = render(#"The identity $e^{i\pi} + 1 = 0$ holds."#)
        let pictures = math(text)
        #expect(pictures.count == 1)
        #expect(!text.string.contains("e^{i"))
        #expect(text.string.contains("The identity "))
        #expect(text.string.contains(" holds."))
        #expect((pictures.first?.image?.size.height ?? 0) > 0)
    }

    @Test func currencyAndEscapedDollarsStayProse() {
        let text = render(#"Costs $5 and $10; a literal \$ and $x$ after it."#)
        #expect(math(text).count == 1)
        #expect(text.string.contains("$5 and $10"))
        #expect(text.string.contains(#"a literal $ and "#))
    }

    @Test func displayMathStandsOnItsOwnCenteredLine() {
        let text = render(#"""
        Before.

        $$
        \sum_{i=1}^{n} i = \frac{n(n+1)}{2}
        $$

        After.
        """#)
        let pictures = math(text)
        #expect(pictures.count == 1)
        #expect(!text.string.contains("sum_"))
        let mark = "\u{FFFC}"
        #expect(text.string.split(separator: "\n").contains { String($0) == mark })
        let style = text.attribute(.paragraphStyle, at: (text.string as NSString).range(of: mark).location, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.alignment == .center)
    }

    @Test func blockquoteDisplayMathDoesNotTypesetContainerMarkers() throws {
        let latex = #"\frac{x}{y} > \sqrt{2}"#
        let expected = try #require(math(render("$$\n" + latex + "\n$$")).first)
        for prefix in ["> ", "> > "] {
            let markdown = prefix + "$$\n" + prefix + latex + "\n" + prefix + "$$"
            let text = render(markdown)
            let actual = try #require(math(text).first)
            #expect(actual.bounds == expected.bounds)
            #expect(!text.string.contains(">"))
            let mark = (text.string as NSString).range(of: "\u{FFFC}")
            let style = try #require(text.attribute(.paragraphStyle, at: mark.location, effectiveRange: nil) as? NSParagraphStyle)
            #expect(style.alignment == .center)
            #expect(style.headIndent > 0)
        }
    }

    @Test func blockquoteDisplayFallbackRetainsFormulaWithoutQuoteMarkers() {
        let formula = #"\notarealcommand{x > y}"#
        let text = render("> $$\n> " + formula + "\n> $$")
        #expect(math(text).isEmpty)
        #expect(text.string == "$$\n" + formula + "\n$$")
    }

    @Test func codeSpansAndFencesAreNeverMath() {
        let text = render(#"""
        Use `$x^2$` and `$$y$$`.

        ```
        $$z$$
        ```
        """#)
        #expect(math(text).isEmpty)
        #expect(text.string.contains("$x^2$"))
        #expect(text.string.contains("$$y$$"))
        #expect(text.string.contains("$$z$$"))
    }

    @Test func unparsableLatexKeepsItsSourceInMonospace() {
        let markdown = #"Broken $\notarealcommand{x}$ here."#
        let text = render(markdown)
        #expect(math(text).isEmpty)
        let range = (text.string as NSString).range(of: #"$\notarealcommand{x}$"#)
        #expect(range.location != NSNotFound)
        guard range.location != NSNotFound else { return }
        let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    @Test func measuredNoteFitsTheMathItDraws() {
        let markdown = #"""
        $$
        \frac{a}{b}
        $$
        """#
        let plain = ObjectMeasure.note(NoteMarkdown.parse("a"), markdown: "a", width: 400, excerpts: [:], images: [:])
        let measured = ObjectMeasure.note(NoteMarkdown.parse(markdown), markdown: markdown, width: 400, excerpts: [:], images: [:])
        #expect(measured.size.height > plain.size.height)
    }

    @Test func ampersandHeavyProsePreservesEveryCharacter() throws {
        let raw = String(repeating: "&", count: 128)
        let input = CountingNoteMathCharacters(Array(raw))
        let text = try #require(NoteMath.text(raw: input, decoded: raw))
        #expect(String(text.characters) == raw)
        #expect(text.source.joined() == raw)
        #expect(text.escapedDollar.allSatisfy { !$0 })
        #expect(input.visits <= 34 * input.count)
    }

    @Test func boundedEntitiesKeepTheirDecodedTextAndMathSource() throws {
        let raw = #"&amp; &lt; &gt; &quot; &apos; &#36;x&#x24; \$"#
        let text = try #require(NoteMath.text(raw: raw, decoded: "& < > \" ' $x$ $"))
        #expect(String(text.characters) == "& < > \" ' $x$ $")
        #expect(text.source.joined() == raw)
        let spans = NoteMath.spans(in: text)
        #expect(spans.map(\.latex) == ["x"])
        let longest = "&#" + String(repeating: "0", count: 28) + "36;"
        let boundary = try #require(NoteMath.text(raw: longest, decoded: "$"))
        #expect(boundary.characters == ["$"])
        #expect(boundary.source == [longest])
        let tooLong = "&#" + String(repeating: "0", count: 29) + "36;"
        #expect(NoteMath.text(raw: tooLong, decoded: "$") == nil)
    }
}

private final class CountingNoteMathCharacters: RandomAccessCollection {
    private let characters: [Character]
    private(set) var visits = 0

    init(_ characters: [Character]) {
        self.characters = characters
    }

    var startIndex: Int { characters.startIndex }
    var endIndex: Int { characters.endIndex }

    subscript(index: Int) -> Character {
        visits += 1
        return characters[index]
    }

    func index(after index: Int) -> Int { index + 1 }
    func index(before index: Int) -> Int { index - 1 }
    func index(_ index: Int, offsetBy distance: Int) -> Int { index + distance }
    func distance(from start: Int, to end: Int) -> Int { end - start }
}
