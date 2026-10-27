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

    private static func raster(_ outcomes: [Int: NoteMermaid.Outcome], width: CGFloat, name: String) throws -> NSImage {
        guard case .image(let image)? = outcomes[1] else {
            if case .fallback(let reason)? = outcomes[1] {
                throw Failure(message: "\(name) fell back: \(reason)")
            }
            throw Failure(message: "\(name) did not return an image")
        }
        try require(image.size.width >= 1 && image.size.width <= width && image.size.height >= 1, "\(name) has invalid logical dimensions: \(image.size)")
        guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure(message: "\(name) has no raster")
        }
        let pixelWidth = pixels.width, pixelHeight = pixels.height
        try require(pixelWidth > 0 && pixelHeight > 0 && pixelWidth <= 8192 && pixelHeight <= 8192 && pixelWidth * pixelHeight <= 4_194_304, "\(name) exceeds the device-pixel cap: \(pixelWidth)x\(pixelHeight)")
        try require(CGFloat(pixelWidth) <= image.size.width * 2 && CGFloat(pixelHeight) <= image.size.height * 2, "\(name) exceeds 2x density")
        try require(abs(CGFloat(pixelHeight) - CGFloat(pixelWidth) * image.size.height / image.size.width) < 2, "\(name) distorted the bitmap aspect ratio")
        if image.size.width * image.size.height * 4 <= 4_194_304 && image.size.width * 2 <= 8192 && image.size.height * 2 <= 8192 {
            try require(CGFloat(pixelWidth) == image.size.width * 2 && CGFloat(pixelHeight) == image.size.height * 2, "\(name) must render at 2x when it fits")
        }
        print("RASTER \(name): logical=\(image.size) pixels=\(pixelWidth)x\(pixelHeight)")
        return image
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
            let image = try raster(result, width: width, name: "LR \(appearance)")
            try require(image.size.width > image.size.height, "declared LR flowchart must stay horizontal, got \(image.size)")
            let text = NoteRenderer(excerpts: [:], source: source, width: width, diagrams: result).render(document, placeholder: "")
            try require(attachments(text).count == 1 && !text.string.contains("flowchart"), "completed fence must be an image, not its source")
            let fallback = NoteRenderer(excerpts: [:], source: source, width: width).render(document, placeholder: "")
            try require(attachments(fallback).isEmpty && fallback.string.contains("flowchart LR"), "synchronous cache miss must preserve source")
        }
        let narrow = await NoteMermaid.resolve(document, width: width, appearance: .light)
        let narrowImage = try raster(narrow, width: width, name: "small at 480pt")
        let wide = await NoteMermaid.resolve(document, width: 1400, appearance: .light)
        let wideImage = try raster(wide, width: 1400, name: "small at 1400pt")
        try require(wideImage.size.width < 480 && abs(wideImage.size.width - narrowImage.size.width) <= 1 && abs(wideImage.size.height - narrowImage.size.height) <= 1, "small diagram must retain its natural dimensions at wide note widths: \(narrowImage.size) versus \(wideImage.size)")
        let gantt = "gantt\ntitle Forty tasks\ndateFormat YYYY-MM-DD\nsection Work\n" + (0..<40).map {
            "Task \($0 + 1) : t\($0), 2026-10-\(String(format: "%02d", $0 % 25 + 1)), 2d"
        }.joined(separator: "\n")
        let ordinary = [
            (name: "sequence at 1400pt", source: "sequenceDiagram\nparticipant Client\nparticipant Server\nClient->>Server: Request\nalt Cached\nServer-->>Client: Hit\nelse Uncached\nServer-->>Client: Result\nend"),
            (name: "TD at 1400pt", source: "flowchart TD\nsubgraph Work\nA[Start] --> B[Build]\nend\nB --> C[Ship]"),
            (name: "gantt40 at 1400pt", source: gantt)
        ]
        for fixture in ordinary {
            let source = "```mermaid\n\(fixture.source)\n```"
            let document = NoteMarkdown.parse(source)
            let outcomes = await NoteMermaid.resolve(document, width: 1400, appearance: .light)
            _ = try raster(outcomes, width: 1400, name: fixture.name)
            let rendered = NoteRenderer(excerpts: [:], source: source, width: 1400, diagrams: outcomes).render(document, placeholder: "")
            try require(attachments(rendered).count == 1 && !rendered.string.contains(fixture.source), "\(fixture.name) must display its image instead of source")
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
        let retinaRequest = TileRenderRequest(size: request.size, scale: 2, full: true, appearance: NSAppearance(named: .aqua)!)
        let retinaExport = await tile.render(retinaRequest)
        try require(retinaExport.state == .rendered && retinaExport.image != nil && retinaExport.contentSize == export.contentSize, "2x export must preserve logical note geometry")
        let changedSource = "Changed prose\n\n```mermaid\nflowchart TD\nDifferent --> Diagram\n```"
        let changed = try board.update(object.id, props: .object(["markdown": .string(changedSource)]))
        tile.update(changed)
        let pending = textViews(tile).first { !$0.isEditable }!.attributedString()
        try require(pending.string.contains("Changed prose") && pending.string.contains("Different --> Diagram") && attachments(pending).isEmpty, "a changed fence must show current source, not the previous diagram")
        try await wait { textViews(tile).contains { !$0.isEditable && $0.string.contains("Changed prose") && attachments($0.attributedString()).count == 1 } }
        let malformed = NoteMarkdown.parse("```mermaid\nflowchart LR\nA[unfinished\n```")
        let rejected = await NoteMermaid.resolve(malformed, width: width, appearance: .light)
        guard case .fallback? = rejected[1] else { throw Failure(message: "malformed diagram must fall back") }
        let fallback = NoteRenderer(excerpts: [:], width: width, diagrams: rejected).render(malformed, placeholder: "")
        try require(fallback.string.contains("A[unfinished") && attachments(fallback).isEmpty, "malformed source was lost")
        print("PASS native note Mermaid: light/dark 2x rasters, natural-size small diagrams, wide sequence/TD/gantt40, physical pixel/byte caps, source fallback, live tile, 1x/2x exports and intrinsic dimensions")
    }
}
