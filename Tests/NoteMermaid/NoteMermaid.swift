import AppKit
import WebKit

@testable import CanvasApp
@testable import CanvasCore

@main
@MainActor
private enum NoteMermaidRegression {
    private struct Failure: Error { let message: String }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
    }

    private static func attachments(_ text: NSAttributedString) -> [NSTextAttachment] {
        var result: [NSTextAttachment] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { result.append(attachment) }
        }
        return result
    }

    private static func textViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    private static func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(message: "note display did not finish its diagram")
    }

    static func main() async throws {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        NoteMermaid.backend = NoteMermaidWeb()
        defer { NoteMermaid.backend = nil }
        let source = "```mermaid\nflowchart LR\nsubgraph Work\ndirection LR\nA[Start] --> B[Finish]\nend\n```"
        let document = NoteMarkdown.parse(source)
        let width: CGFloat = 480
        for appearance in [NoteMermaid.Appearance.light, .dark] {
            let result = await NoteMermaid.resolve(document, width: width, appearance: appearance)
            guard case .image(let image)? = result[1] else { throw Failure(message: "ordinary flowchart did not render for \(appearance)") }
            let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            try require(pixels != nil && image.size.width <= width && image.size.width > image.size.height, "declared LR flowchart must stay horizontal within the note width, got \(image.size)")
            let text = NoteRenderer(excerpts: [:], source: source, width: width, diagrams: result).render(document, placeholder: "")
            try require(attachments(text).count == 1 && !text.string.contains("flowchart"), "completed fence must be an image, not its source")
            let fallback = NoteRenderer(excerpts: [:], source: source, width: width).render(document, placeholder: "")
            try require(attachments(fallback).isEmpty && fallback.string.contains("flowchart LR"), "synchronous cache miss must preserve source")
        }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASL_HOME"]!).appendingPathComponent("board")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = Board(id: "mermaid-native", root: root)
        let object = board.create(type: .note, props: .object(["markdown": .string(source)]), frame: Frame(x: 0, y: 0, w: 496, h: 400))
        let tile = NoteTile(object: object, board: board)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 496, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView!.addSubview(tile)
        window.orderFrontRegardless()
        defer { tile.setLive(false); window.close() }
        try await wait { textViews(tile).contains { !$0.isEditable && attachments($0.attributedString()).count == 1 } }
        let request = TileRenderRequest(size: CGSize(width: 496, height: 400), scale: 1, full: true, appearance: NSAppearance(named: .aqua)!)
        let export = await tile.render(request)
        let measured = await ObjectMeasure.note(object.props, width: 496, root: root)
        try require(export.state == .rendered && export.image != nil, "note export did not complete")
        try require(abs(export.contentSize.height + CodeMetrics.titleHeight - measured.size.height) <= 1, "export and intrinsic measurement disagree: \(export.contentSize) versus \(measured.size)")
        let malformed = NoteMarkdown.parse("```mermaid\nflowchart LR\nA[unfinished\n```")
        let rejected = await NoteMermaid.resolve(malformed, width: width, appearance: .light)
        guard case .fallback? = rejected[1] else { throw Failure(message: "malformed diagram must fall back") }
        let fallback = NoteRenderer(excerpts: [:], width: width, diagrams: rejected).render(malformed, placeholder: "")
        try require(fallback.string.contains("A[unfinished") && attachments(fallback).isEmpty, "malformed source was lost")
        print("PASS native note Mermaid: light/dark diagrams, source fallback, live tile, completed export and intrinsic dimensions")
    }
}
