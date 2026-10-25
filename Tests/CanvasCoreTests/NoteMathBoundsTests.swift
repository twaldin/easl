import AppKit
import Foundation
import Testing
@testable import CanvasCore

@MainActor
struct NoteMathBoundsTests {
    private func hostileFormulas() -> [String] {
        let depth = 1000
        return [
            String(repeating: #"\frac{1}{"#, count: depth) + "1" + String(repeating: "}", count: depth),
            String(repeating: "{", count: depth) + "x" + String(repeating: "}", count: depth),
            String(repeating: #"\sqrt{"#, count: depth) + "x" + String(repeating: "}", count: depth),
            String(repeating: #"\sqrt "#, count: depth) + "x",
            String(repeating: #"\sqrt["#, count: depth) + "2" + String(repeating: "]{x}", count: depth),
            String(repeating: #"\left("#, count: depth) + "x" + String(repeating: #"\right)"#, count: depth),
            String(repeating: #"\begin{matrix}"#, count: depth) + "x" + String(repeating: #"\end{matrix}"#, count: depth),
            String(repeating: "x_{", count: depth) + "x" + String(repeating: "}", count: depth),
            String(repeating: "x^{", count: depth) + "x" + String(repeating: "}", count: depth),
            String(repeating: #"x\over "#, count: depth) + "x",
            String(repeating: #"\hat "#, count: depth) + "x",
            String(repeating: #"\mathbf "#, count: depth) + "x",
            String(repeating: "x", count: 1_000_000),
        ]
    }

    @Test func hostileFormulasNeverEnterNativeTypesetting() {
        Run6Trace.event("body.enter", "selector=NoteMathBoundsTests/hostileFormulasNeverEnterNativeTypesetting")
        defer { Run6Trace.event("body.exit", "selector=NoteMathBoundsTests/hostileFormulasNeverEnterNativeTypesetting") }
        for latex in hostileFormulas() {
            #expect(NoteMath.attachment(latex: latex, fontSize: 13, display: true) == nil)
            #expect(NoteMath.attachment(latex: latex, fontSize: 13, display: false) == nil)
        }
    }

    @Test func rejectedFormulasKeepTheirLiteralSourceInMonospace() throws {
        Run6Trace.event("body.enter", "selector=NoteMathBoundsTests/rejectedFormulasKeepTheirLiteralSourceInMonospace")
        defer { Run6Trace.event("body.exit", "selector=NoteMathBoundsTests/rejectedFormulasKeepTheirLiteralSourceInMonospace") }
        for latex in hostileFormulas() {
            let markdown = "$$\n" + latex + "\n$$"
            let text = NoteRenderer(excerpts: [:], source: markdown, width: 400).render(NoteMarkdown.parse(markdown), placeholder: "")
            #expect(text.string.trimmingCharacters(in: .whitespacesAndNewlines) == markdown)
            var attachmentCount = 0
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if value != nil { attachmentCount += 1 }
            }
            #expect(attachmentCount == 0)
            let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
        }
    }

    @Test func sizeFitMeasuresTheRejectedFormulaAsSource() async throws {
        Run6Trace.event("body.enter", "selector=NoteMathBoundsTests/sizeFitMeasuresTheRejectedFormulaAsSource")
        defer { Run6Trace.event("body.exit", "selector=NoteMathBoundsTests/sizeFitMeasuresTheRejectedFormulaAsSource") }
        let latex = String(repeating: #"\frac{1}{"#, count: 1000) + "1" + String(repeating: "}", count: 1000)
        let markdown = "$$\n" + latex + "\n$$"
        let text = NoteRenderer(excerpts: [:], source: markdown, width: 384).render(NoteMarkdown.parse(markdown), placeholder: "")
        let measured = try await ObjectMeasure.size(type: .note, props: .object(["markdown": .string(markdown)]), width: 400, root: URL(fileURLWithPath: "/tmp"))
        let expectedHeight = (CodeMetrics.titleHeight + 2 * ObjectMeasure.noteInset.height + ObjectMeasure.noteTextHeight(text, width: 384)).rounded(.up)
        #expect(measured == CGSize(width: 400, height: expectedHeight))
    }

    @Test func smallFormulasAndEscapedSymbolsStillTypeset() {
        Run6Trace.event("body.enter", "selector=NoteMathBoundsTests/smallFormulasAndEscapedSymbolsStillTypeset")
        defer { Run6Trace.event("body.exit", "selector=NoteMathBoundsTests/smallFormulasAndEscapedSymbolsStillTypeset") }
        for latex in [#"\frac{a}{b}"#, #"\sqrt[3]{x^2}"#, #"\left(\frac{a}{b}\right)"#, #"\begin{matrix}a&b\\c&d\end{matrix}"#, #"\{x\}"#] {
            #expect(NoteMath.attachment(latex: latex, fontSize: 13, display: true) != nil)
        }
    }
    @Test func byteAndRecursionBoundariesPreserveAcceptedMath() {
        Run6Trace.event("body.enter", "selector=NoteMathBoundsTests/byteAndRecursionBoundariesPreserveAcceptedMath")
        defer { Run6Trace.event("body.exit", "selector=NoteMathBoundsTests/byteAndRecursionBoundariesPreserveAcceptedMath") }
        #expect(NoteMath.attachment(latex: String(repeating: "x", count: 2048), fontSize: 13, display: true) != nil)
        #expect(NoteMath.attachment(latex: String(repeating: "x", count: 2049), fontSize: 13, display: true) == nil)
        let accepted = String(repeating: "{", count: 16) + "x" + String(repeating: "}", count: 16)
        let rejected = String(repeating: "{", count: 17) + "x" + String(repeating: "}", count: 17)
        #expect(NoteMath.attachment(latex: accepted, fontSize: 13, display: true) != nil)
        #expect(NoteMath.attachment(latex: rejected, fontSize: 13, display: true) == nil)
        #expect(NoteMath.attachment(latex: String(repeating: #"\sqrt "#, count: 16) + "x", fontSize: 13, display: true) != nil)
        #expect(NoteMath.attachment(latex: String(repeating: #"\sqrt "#, count: 17) + "x", fontSize: 13, display: true) == nil)
    }

    @Test func prefixedTextColorsRenderWithoutTrapping() throws {
        Run6Trace.event("body.enter", "selector=NoteMathBoundsTests/prefixedTextColorsRenderWithoutTrapping")
        defer { Run6Trace.event("body.exit", "selector=NoteMathBoundsTests/prefixedTextColorsRenderWithoutTrapping") }
        if try runIsolatedTestIfParallelNow("NoteMathBoundsTests/prefixedTextColorsRenderWithoutTrapping") { return }
        let inputs = [
            #"$x\textcolor{red}{\frac12}$"#,
            #"$a=\textcolor{#f00}{\sqrt{2}}$"#,
            #"$x\textcolor{red}{}$"#,
            #"$$\frac{a}{b}=\textcolor{red}{\frac{c}{d}}$$"#,
        ]
        for markdown in inputs {
            let text = NoteRenderer(excerpts: [:], source: markdown, width: 400)
                .render(NoteMarkdown.parse(markdown), placeholder: "")
            var attachmentCount = 0
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if value != nil { attachmentCount += 1 }
            }
            #expect(attachmentCount == 1, "\(markdown)")
            #expect(!text.string.contains("textcolor"), "\(markdown)")
        }
    }

    @Test func prefixedColorAccentAndScriptFuzzRunsInChild() throws {
        Run6Trace.event("body.enter", "selector=NoteMathBoundsTests/prefixedColorAccentAndScriptFuzzRunsInChild")
        defer { Run6Trace.event("body.exit", "selector=NoteMathBoundsTests/prefixedColorAccentAndScriptFuzzRunsInChild") }
        if try runIsolatedTestIfParallelNow("NoteMathBoundsTests/prefixedColorAccentAndScriptFuzzRunsInChild") { return }
        let arguments = [
            "", "x", #"\frac12"#, #"\sqrt{2}"#, #"\left(x\right)"#,
            #"\sum_{i=1}^{n}i"#, #"\begin{matrix}a&b\\c&d\end{matrix}"#,
        ]
        let wrappers: [(String) -> String] = [
            { #"x\textcolor{FF0000}{"# + $0 + "}" },
            { #"x\color{FF0000}{"# + $0 + "}" },
            { #"x\colorbox{FF0000}{"# + $0 + "}" },
            { #"x\hat{"# + $0 + "}" },
            { #"x\widehat{"# + $0 + "}" },
            { #"x\vec{"# + $0 + "}" },
            { "x_{" + $0 + "}" },
            { "x^{" + $0 + "}" },
        ]
        for argument in arguments {
            for wrap in wrappers {
                var latex = argument
                for depth in 1...5 {
                    latex = wrap(latex)
                    for display in [false, true] {
                        #expect(NoteMath.attachment(latex: latex, fontSize: 13, display: display) != nil,
                                "depth \(depth): \(latex)")
                    }
                }
            }
        }
    }

    @Test func malformedRadicalDegreesUseLiteralFallbackInChild() throws {
        Run6Trace.event("body.enter", "selector=NoteMathBoundsTests/malformedRadicalDegreesUseLiteralFallbackInChild")
        defer { Run6Trace.event("body.exit", "selector=NoteMathBoundsTests/malformedRadicalDegreesUseLiteralFallbackInChild") }
        if try runIsolatedTestIfParallelNow("NoteMathBoundsTests/malformedRadicalDegreesUseLiteralFallbackInChild") { return }
        for latex in [#"\sqrt[}]{x}"#, #"\sqrt[2}]{x}"#, #"\sqrt[{x}}]{x}"#, #"x\sqrt[\frac1}]{x}"#] {
            for display in [false, true] {
                #expect(NoteMath.attachment(latex: latex, fontSize: 13, display: display) == nil)
            }
            let markdown = "$$\n" + latex + "\n$$"
            let text = NoteRenderer(excerpts: [:], source: markdown, width: 400)
                .render(NoteMarkdown.parse(markdown), placeholder: "")
            #expect(text.string.trimmingCharacters(in: .whitespacesAndNewlines) == markdown)
        }
    }

    @Test func wideMathDoesNotSpendItsDepthAllowance() throws {
        Run6Trace.event("body.enter", "selector=NoteMathBoundsTests/wideMathDoesNotSpendItsDepthAllowance")
        defer { Run6Trace.event("body.exit", "selector=NoteMathBoundsTests/wideMathDoesNotSpendItsDepthAllowance") }
        if try runIsolatedTestIfParallelNow("NoteMathBoundsTests/wideMathDoesNotSpendItsDepthAllowance") { return }
        let row = Array(repeating: "x", count: 4).joined(separator: "&")
        let matrix = #"\begin{matrix}"# + Array(repeating: row, count: 4).joined(separator: "\\\\") + #"\end{matrix}"#
        for latex in [
            #"\frac{1}{\sigma\sqrt{2\pi}} e^{-\frac{1}{2}\left(\frac{x-\mu}{\sigma}\right)^2}"#,
            matrix,
            String(repeating: #"\frac{a}{b}+"#, count: 24) + "1",
        ] {
            #expect(NoteMath.attachment(latex: latex, fontSize: 13, display: true) != nil, "\(latex)")
        }
    }

    @Test func allRecursiveConstructsHaveBoundedDepthInChild() throws {
        Run6Trace.event("body.enter", "selector=NoteMathBoundsTests/allRecursiveConstructsHaveBoundedDepthInChild")
        defer { Run6Trace.event("body.exit", "selector=NoteMathBoundsTests/allRecursiveConstructsHaveBoundedDepthInChild") }
        if try runIsolatedTestIfParallelNow("NoteMathBoundsTests/allRecursiveConstructsHaveBoundedDepthInChild") { return }
        let recursive: [(Int) -> String] = [
            { String(repeating: #"\frac1"#, count: $0) + "1" },
            { String(repeating: #"\binom1"#, count: $0) + "1" },
            { String(repeating: #"\sqrt "#, count: $0) + "x" },
            { String(repeating: #"\hat "#, count: $0) + "x" },
            { String(repeating: #"\mathbf "#, count: $0) + "x" },
            { String(repeating: #"\overline "#, count: $0) + "x" },
            { String(repeating: #"\underline "#, count: $0) + "x" },
            { String(repeating: #"x\atop "#, count: $0) + "x" },
            { String(repeating: #"x\choose "#, count: $0) + "x" },
            { String(repeating: #"x\over "#, count: $0) + "x" },
            { String(repeating: #"x\brack "#, count: $0) + "x" },
            { String(repeating: #"x\brace "#, count: $0) + "x" },
            { String(repeating: #"\color{FF0000}"#, count: $0) + "x" },
            { String(repeating: #"\textcolor{FF0000}"#, count: $0) + "x" },
            { String(repeating: #"\colorbox{FF0000}"#, count: $0) + "x" },
            { String(repeating: #"\left("#, count: $0) + "x" + String(repeating: #"\right)"#, count: $0) },
            { String(repeating: #"\sqrt["#, count: $0) + "2" + String(repeating: "]{x}", count: $0) },
            { String(repeating: "x^{", count: $0) + "x" + String(repeating: "}", count: $0) },
            { String(repeating: "x_{", count: $0) + "x" + String(repeating: "}", count: $0) },
            { String(repeating: #"\begin{matrix}"#, count: $0) + "x" + String(repeating: #"\end{matrix}"#, count: $0) },
        ]
        for formula in recursive {
            for display in [false, true] {
                #expect(NoteMath.attachment(latex: formula(17), fontSize: 13, display: display) == nil)
            }
        }
    }

    @Test func colorRewriteMatchesWholeCommandsOnlyInChild() throws {
        Run6Trace.event("body.enter", "selector=NoteMathBoundsTests/colorRewriteMatchesWholeCommandsOnlyInChild")
        defer { Run6Trace.event("body.exit", "selector=NoteMathBoundsTests/colorRewriteMatchesWholeCommandsOnlyInChild") }
        if try runIsolatedTestIfParallelNow("NoteMathBoundsTests/colorRewriteMatchesWholeCommandsOnlyInChild") { return }
        #expect(NoteMath.attachment(latex: #"x\textcolorful{red}{x}"#, fontSize: 13, display: true) == nil)
        #expect(NoteMath.attachment(latex: #"x\textcoloré{red}{x}"#, fontSize: 13, display: true) == nil)
        #expect(NoteMath.attachment(latex: #"\backslash textcolor"#, fontSize: 13, display: true) != nil)
    }

    @Test func workBoundaryIsIndependentOfDepthInChild() throws {
        Run6Trace.event("body.enter", "selector=NoteMathBoundsTests/workBoundaryIsIndependentOfDepthInChild")
        defer { Run6Trace.event("body.exit", "selector=NoteMathBoundsTests/workBoundaryIsIndependentOfDepthInChild") }
        if try runIsolatedTestIfParallelNow("NoteMathBoundsTests/workBoundaryIsIndependentOfDepthInChild") { return }
        #expect(NoteMath.attachment(latex: String(repeating: #"\,x"#, count: 256), fontSize: 13, display: true) != nil)
        #expect(NoteMath.attachment(latex: String(repeating: #"\,x"#, count: 257), fontSize: 13, display: true) == nil)
    }

    @Test func repeatedDeepRadicalsAndAccentsUseTheSourceFallbackInChild() throws {
        Run6Trace.event("body.enter", "selector=NoteMathBoundsTests/repeatedDeepRadicalsAndAccentsUseTheSourceFallbackInChild")
        defer { Run6Trace.event("body.exit", "selector=NoteMathBoundsTests/repeatedDeepRadicalsAndAccentsUseTheSourceFallbackInChild") }
        if try runIsolatedTestIfParallelNow("NoteMathBoundsTests/repeatedDeepRadicalsAndAccentsUseTheSourceFallbackInChild") { return }
        for command in [#"\sqrt "#, #"\hat "#] {
            let chain = String(repeating: command, count: 16) + "x"
            let latex = chain + "+" + chain
            #expect(NoteMath.attachment(latex: latex, fontSize: 13, display: true) == nil)
            let markdown = "$$\n" + latex + "\n$$"
            let text = NoteRenderer(excerpts: [:], source: markdown, width: 400)
                .render(NoteMarkdown.parse(markdown), placeholder: "")
            #expect(text.string.trimmingCharacters(in: .whitespacesAndNewlines) == markdown)
        }
    }
}
