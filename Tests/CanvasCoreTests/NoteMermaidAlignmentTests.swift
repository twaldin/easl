import AppKit
import Testing
@testable import CanvasCore

@MainActor
struct NoteMermaidAlignmentTests {
    @Test func narrowDiagramsAreCentredWithinTheirNoteContainer() throws {
        let source = "```mermaid\nflowchart LR\nA --> B\n```"
        let image = NSImage(size: NSSize(width: 120, height: 60))
        let text = NoteRenderer(excerpts: [:], source: source, width: 400, diagrams: [1: .image(image)])
            .render(NoteMarkdown.parse(source), placeholder: "")
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: 0))
        container.lineFragmentPadding = ObjectMeasure.noteLineFragmentPadding
        layout.textContainer = container
        content.attributedString = text
        layout.ensureLayout(for: layout.documentRange)
        var diagramBounds: CGRect?
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let line = fragment.textLineFragments.first {
                diagramBounds = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: 0)
            }
            return true
        }
        let bounds = try #require(diagramBounds)
        #expect(abs(bounds.midX - 200) <= 1)
        #expect(abs(bounds.width - 120) <= 1)
    }
}
