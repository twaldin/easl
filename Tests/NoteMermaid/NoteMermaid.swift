import AppKit
import WebKit

@testable import CanvasApp
@testable import CanvasCore

@MainActor
private final class HeldMermaidRenderer: NoteMermaidBackend {
    private var pending: [NoteMermaid.Key: @MainActor (NoteMermaid.Outcome) -> Void] = [:]
    private(set) var starts = 0

    func start(_ key: NoteMermaid.Key, completion: @escaping @MainActor (NoteMermaid.Outcome) -> Void) -> (@MainActor () -> Void) {
        starts += 1
        pending[key] = completion
        return { [weak self] in self?.pending.removeValue(forKey: key) }
    }

    func finish(with image: NSImage) {
        let completions = Array(pending.values)
        pending.removeAll()
        for completion in completions { completion(.image(image)) }
    }
}

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
    private static func pendingResizeRoundTrip() async throws {
        let previous = NoteMermaid.backend
        let renderer = HeldMermaidRenderer()
        NoteMermaid.backend = renderer
        defer { NoteMermaid.backend = previous }
        let board = Board(id: "mermaid-resize", root: URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASL_HOME"]!))
        let source = "```mermaid\nflowchart LR\nPending --> Ready\n```"
        let object = board.create(type: .note, props: .object(["markdown": .string(source)]), frame: Frame(x: 0, y: 0, w: 496, h: 240))
        let tile = NoteTile(object: object, board: board)
        let window = NSWindow(contentRect: tile.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView!.addSubview(tile)
        window.orderFrontRegardless()
        defer { tile.setLive(false); tile.removeFromSuperview(); window.close() }
        try await wait { renderer.starts == 1 }
        tile.setFrameSize(NSSize(width: 536, height: 240))
        try await wait { renderer.starts == 2 }
        tile.setFrameSize(NSSize(width: 496, height: 240))
        try await Task.sleep(for: .milliseconds(200))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 40,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.bitmapData!.initialize(repeating: 128, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        bitmap.size = NSSize(width: 40, height: 20)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        renderer.finish(with: image)
        try await wait {
            textViews(tile).contains { text in
                !text.isEditable && attachments(text.attributedString()).count == 1 && !text.string.contains("Pending")
            }
        }
        print("PASS pending Mermaid width round-trip replaces source with completed output")
    }

    private static func kitDiagramSize(_ source: String, width: CGFloat) async throws -> CGSize {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASL_HOME"]!)
        let board = Board(id: "mermaid-kit-parity", root: root)
        let html = "<style>body{padding:0}.mermaid{margin:0}</style><pre class=\"mermaid\">\(source)</pre>"
        let object = board.create(type: .html, props: .object(["html": .string(html)]),
                                  frame: Frame(x: 0, y: 0, w: Double(width), h: 1200))
        let tile = HtmlTile(object: object, board: board)
        let window = NSWindow(contentRect: tile.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView!.addSubview(tile)
        window.orderFrontRegardless()
        defer { tile.setLive(false); tile.removeFromSuperview(); window.close() }
        var ready = false
        tile.whenLiveReady { ready = true }
        try await wait { ready }
        guard let web = tile.webView,
              let dimensions = try await web.evaluateJavaScript("const box = document.querySelector('.mermaid svg').getBoundingClientRect(); ({width: box.width, height: box.height})") as? [String: Double],
              let width = dimensions["width"], let height = dimensions["height"] else {
            throw Failure(message: "HTML kit did not produce a Mermaid diagram")
        }
        return CGSize(width: width, height: height)
    }

    static func main() async throws {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        try await pendingResizeRoundTrip()
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
        let canonicalGantt = try await kitDiagramSize(gantt, width: 1392)
        let noteGantt = try raster(await NoteMermaid.resolve(NoteMarkdown.parse("```mermaid\n\(gantt)\n```"), width: 1400, appearance: .light), width: 1400, name: "gantt kit parity")
        try require(abs(noteGantt.size.width - canonicalGantt.width) <= 1 && abs(noteGantt.size.height - canonicalGantt.height) <= 1,
                    "note gantt must use the HTML kit's container geometry: \(noteGantt.size) versus \(canonicalGantt)")
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
