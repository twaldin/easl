import AppKit
import WebKit
import Darwin

@testable import CanvasApp
@testable import CanvasCore

@MainActor
private final class Heartbeat {
    private var timer: DispatchSourceTimer?
    private var last = ProcessInfo.processInfo.systemUptime
    private(set) var maximumMilliseconds = 0.0
    private(set) var samples = 0

    func start() {
        last = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(100))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sample() }
        }
        self.timer = timer
        timer.resume()
    }

    func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        maximumMilliseconds = max(maximumMilliseconds, (now - last) * 1000)
        last = now
        samples += 1
    }

    func stop() {
        sample()
        timer?.cancel()
        timer = nil
    }
}

@MainActor
private final class RecoveryBackend: NoteMermaidPreparingBackend {
    private let renderer = NoteMermaidWeb()
    private(set) var preparationMilliseconds: [Double] = []
    private(set) var readyUptime = 0.0

    func start(_ key: NoteMermaid.Key, ready: @escaping @MainActor () -> Void,
               failed: @escaping @MainActor (String) -> Void,
               completion: @escaping @MainActor (NoteMermaid.Outcome) -> Void) -> (@MainActor () -> Void) {
        let began = ProcessInfo.processInfo.systemUptime
        return renderer.start(key, ready: { [weak self] in
            let now = ProcessInfo.processInfo.systemUptime
            self?.preparationMilliseconds.append((now - began) * 1000)
            self?.readyUptime = now
            ready()
        }, failed: failed, completion: completion)
    }
}

@MainActor
private enum NoteMermaidChurn {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private struct Fixture {
        let name: String
        let sources: [String]

        func markdown(edit: Int) -> String {
            sources.enumerated().map { index, source in
                let prose = Array(repeating: "Prose edit \(edit), fence \(index + 1).", count: edit % 3 + 2).joined(separator: "\n\n")
                return "\(prose)\n\n```mermaid\n\(source)\n```\n\nAfter edit \(edit)."
            }.joined(separator: "\n\n")
        }
    }

    private struct ChurnResult {
        let edits: Int
        let immediateImages: Int
        let settledImages: Int
        let withinLimit: Bool
    }

    private struct Candidate {
        let fixture: Fixture
        let pixelsWide: Int
        let pixelsHigh: Int
        var area: Int { pixelsWide * pixelsHigh }
    }

    private static var stageSeconds = 0.0
    private static var geometryChecks = 0
    private static var lifecycleChecks = 0
    private static var swapCounts: [Int] = []

    private static func stage(_ name: String, tile: NoteTile, directory: URL) async throws {
        try snapshot(tile, name: name, directory: directory)
        guard let window = tile.window else { throw Failure(description: "stage has no native window") }
        let receipt: [String: Any] = ["event": "stage", "name": name, "pid": getpid(),
                                      "windowNumber": window.windowNumber, "pauseSeconds": stageSeconds,
                                      "windowFrame": NSStringFromRect(window.frame),
                                      "backingScale": window.backingScaleFactor]
        emit(receipt)
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("stage.json"))
        if stageSeconds > 0 { try await Task.sleep(for: .seconds(stageSeconds)) }
    }

    private static func makeWindow(_ tile: NoteTile) -> NSWindow {
        let window = NSWindow(contentRect: tile.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView!.addSubview(tile)
        window.orderFrontRegardless()
        return window
    }

    private static func layerRaster(_ layer: CALayer) -> CGImage? {
        guard let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return (contents as! CGImage)
    }

    private static func imageLayers(_ text: NSTextView) -> [CALayer] {
        (text.layer?.sublayers ?? []).filter { layerRaster($0) != nil }
    }

    private static func rectValues(_ rect: CGRect) -> [Double] {
        [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
    }

    @discardableResult
    private static func geometry(_ tile: NoteTile, state: String, zoom: CGFloat) throws -> [CGRect] {
        tile.layoutSubtreeIfNeeded()
        tile.displayIfNeeded()
        let text = try display(tile)
        guard let layout = text.textLayoutManager, let content = layout.textContentManager else {
            throw Failure(description: "\(state): missing TextKit 2 layout")
        }
        layout.ensureLayout(for: layout.documentRange)
        var expected: [CGRect] = []
        var rasters: [Data] = []
        let storage = text.attributedString()
        var geometryError: Error?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            do {
                guard let image = attachment.image,
                      let location = content.location(content.documentRange.location, offsetBy: range.location),
                      let fragment = layout.textLayoutFragment(for: location) else {
                    throw Failure(description: "\(state): attachment has no image or laid-out fragment")
                }
                let rect = fragment.frameForTextAttachment(at: location)
                    .offsetBy(dx: fragment.layoutFragmentFrame.minX + text.textContainerOrigin.x,
                              dy: fragment.layoutFragmentFrame.minY + text.textContainerOrigin.y)
                try require(!rect.isEmpty, "\(state): TextKit returned an empty attachment frame")
                expected.append(rect)
                rasters.append(try rasterData(image))
            } catch { geometryError = error }
        }
        if let geometryError { throw geometryError }
        let layers = imageLayers(text)
        try require(layers.count == expected.count, "\(state): \(layers.count) visible image layers for \(expected.count) attachments")
        let scale = tile.window?.backingScaleFactor ?? 1
        for (index, layer) in layers.enumerated() {
            let frame = expected[index]
            try require(zip(rectValues(layer.frame), rectValues(frame)).allSatisfy { abs($0 - $1) < 0.001 },
                        "\(state): layer \(index) \(layer.frame) differs from TextKit \(frame)")
            try require(layer.superlayer === text.layer && !layer.isHidden && layer.opacity == 1,
                        "\(state): diagram layer is detached or hidden")
            try require(layer.contentsScale == scale, "\(state): diagram layer uses the wrong backing scale")
            guard let pixels = layerRaster(layer),
                  let png = NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:]) else {
                throw Failure(description: "\(state): layer has no raster contents")
            }
            try require(png == rasters[index], "\(state): layer \(index) shows a stale or different image")
            let actualInWindow = text.convert(layer.frame, to: nil)
            let expectedInWindow = text.convert(frame, to: nil)
            try require(zip(rectValues(actualInWindow), rectValues(expectedInWindow)).allSatisfy { abs($0 - $1) < 0.001 },
                        "\(state): scaled/scrolled window frame differs from TextKit")
            try require(abs(expectedInWindow.width - frame.width * zoom) < 0.1 &&
                        abs(expectedInWindow.height - frame.height * zoom) < 0.1,
                        "\(state): canvas-like view transform did not apply the requested zoom")
            emit(["event": "geometry", "state": state, "attachment": index, "zoom": zoom,
                  "actual": rectValues(layer.frame), "textKit": rectValues(frame),
                  "windowFrame": rectValues(actualInWindow), "backingScale": scale,
                  "scrollOrigin": rectValues(text.enclosingScrollView?.contentView.bounds ?? .zero)])
            geometryChecks += 1
        }
        return layers.map { text.convert($0.frame, to: nil) }
    }

    private static let width: CGFloat = 1416
    private static let editCount = 25
    private static let gapLimitMilliseconds = 50.0

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    private static func emit(_ record: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func textViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    private static func display(_ tile: NoteTile) throws -> NSTextView {
        guard let text = textViews(tile).first(where: { !$0.isEditable }) else {
            throw Failure(description: "note has no rendered text view")
        }
        return text
    }

    private static func attachments(_ text: NSAttributedString) -> [NSTextAttachment] {
        var result: [NSTextAttachment] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { result.append(attachment) }
        }
        return result
    }

    private static func wait(_ description: String, until condition: @MainActor () throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: "timed out: \(description)")
    }

    private static func warm(_ backend: NoteMermaidWeb) async throws {
        var outcome: NoteMermaid.Outcome?
        let abort = backend.start(NoteMermaid.Key(source: "flowchart LR\nWarm --> Ready\n", width: 480, appearance: .light)) {
            outcome = $0
        }
        defer { abort() }
        try await wait("untimed real WebKit warmup") { outcome != nil }
        guard case .image(let image)? = outcome, image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else {
            if case .fallback(let reason)? = outcome { throw Failure(description: "WebKit warmup fell back: \(reason)") }
            throw Failure(description: "WebKit warmup did not produce a raster")
        }
        emit(["event": "warmup", "state": "image", "timed": false])
    }

    private static func check(_ tile: NoteTile, fixture: Fixture, edit: Int) throws -> Int {
        let text = try display(tile)
        let images = attachments(text.attributedString())
        try require(images.count == fixture.sources.count,
                    "\(fixture.name) edit \(edit): expected \(fixture.sources.count) attachments, got \(images.count)")
        try require(images.allSatisfy { $0.image != nil }, "\(fixture.name) edit \(edit): attachment lost its image")
        try require(text.string.contains("Prose edit \(edit), fence 1.") && text.string.contains("After edit \(edit)."),
                    "\(fixture.name) edit \(edit): displayed prose is stale")
        let layers = imageLayers(text)
        try require(layers.count == images.count && layers.allSatisfy { !$0.frame.isEmpty && !$0.isHidden && $0.opacity == 1 },
                    "\(fixture.name) edit \(edit): a displayed diagram layer is missing or empty")
        return images.count
    }

    private static func snapshot(_ tile: NoteTile, name: String, directory: URL) throws {
        tile.layoutSubtreeIfNeeded()
        tile.displayIfNeeded()
        guard let bitmap = tile.bitmapImageRepForCachingDisplay(in: tile.bounds) else {
            throw Failure(description: "could not capture native note window for \(name)")
        }
        tile.cacheDisplay(in: tile.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(description: "could not encode native note window for \(name)")
        }
        let url = directory.appendingPathComponent(name + ".png")
        try png.write(to: url)
        emit(["event": "artifact", "path": url.path])
    }

    private static func rasterData(_ image: NSImage) throws -> Data {
        guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:]) else {
            throw Failure(description: "displayed Mermaid image has no raster")
        }
        return png
    }

    private static func verifyLiveDiagramPixels(_ tile: NoteTile) async throws {
        tile.layoutSubtreeIfNeeded()
        tile.displayIfNeeded()
        guard let actual = tile.bitmapImageRepForCachingDisplay(in: tile.bounds) else {
            throw Failure(description: "live diagram comparison has no capture bitmap")
        }
        tile.cacheDisplay(in: tile.bounds, to: actual)
        let scale = CGFloat(actual.pixelsWide) / tile.bounds.width
        try require(abs(CGFloat(actual.pixelsHigh) / tile.bounds.height - scale) < 0.001,
                    "native capture has inconsistent horizontal and vertical scale")
        let request = TileRenderRequest(size: tile.bounds.size, scale: scale, full: false,
                                        appearance: NSAppearance(named: .aqua)!)
        let rendered = await tile.render(request)
        guard let pixels = rendered.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure(description: "independent note export has no bitmap")
        }
        let expected = NSBitmapImageRep(cgImage: pixels)
        try require(actual.pixelsWide == expected.pixelsWide && actual.pixelsHigh == expected.pixelsHigh,
                    "live note and independent export have different raster bounds at capture scale \(scale)")
        func color(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
            bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        }
        func close(_ left: NSColor, _ right: NSColor, tolerance: CGFloat) -> Bool {
            abs(left.redComponent - right.redComponent) <= tolerance &&
                abs(left.greenComponent - right.greenComponent) <= tolerance &&
                abs(left.blueComponent - right.blueComponent) <= tolerance &&
                abs(left.alphaComponent - right.alphaComponent) <= tolerance
        }
        var witnesses = 0
        for y in stride(from: 8, to: expected.pixelsHigh - 8, by: 32) {
            for x in stride(from: 8, to: expected.pixelsWide - 8, by: 32) {
                let reference = color(expected, x, y)
                guard reference.alphaComponent > 0.99,
                      [(-4, 0), (4, 0), (0, -4), (0, 4)].allSatisfy({
                          close(reference, color(expected, x + $0.0, y + $0.1), tolerance: 0.02)
                      }) else { continue }
                try require(close(reference, color(actual, x, y), tolerance: 0.13),
                            "live note lost or misplaced a diagram at raster pixel \(x),\(y)")
                witnesses += 1
            }
        }
        try require(witnesses >= 16, "fixture did not expose enough opaque diagram pixels to compare")
        emit(["event": "live-export-pixels", "matchedDiagramPixels": witnesses, "scale": scale,
              "pixelsWide": actual.pixelsWide, "pixelsHigh": actual.pixelsHigh,
              "windowBackingScale": tile.window?.backingScaleFactor ?? 1])
    }

    private static func sourceSwaps(_ tile: NoteTile, board: Board, directory: URL) async throws {
        let sources = ["flowchart LR\nA[Short] --> B[Wide]", "flowchart TD\nA[Tall] --> B[Second] --> C[Third] --> D[Fourth] --> E[Last]"]
        let diagramWidth = (tile.bounds.width - 2 * ObjectMeasure.noteInset.width).rounded(.down)
        var expected: [Data] = []
        for source in sources {
            let outcomes = await NoteMermaid.resolve(NoteMarkdown.parse("```mermaid\n\(source)\n```"),
                                                     width: diagramWidth, appearance: .light)
            guard case .image(let image)? = outcomes[1] else {
                throw Failure(description: "source-swap warmup did not produce its real diagram")
            }
            expected.append(try rasterData(image))
        }
        try require(expected[0] != expected[1], "source-swap fixtures must display different diagrams")
        for (step, index) in [0, 1, 0].enumerated() {
            let marker = "Source swap \(step)"
            let markdown = "\(marker)\n\n```mermaid\n\(sources[index])\n```"
            tile.update(try board.update(tile.object.id, props: .object(["markdown": .string(markdown)])))
            try await wait("source swap \(step)") {
                let text = try display(tile)
                return text.string.contains(marker) && attachments(text.attributedString()).count == 1
            }
            let image = try display(tile).attributedString()
            guard let raster = attachments(image).first?.image else {
                throw Failure(description: "source swap \(step) has no displayed image")
            }
            let actual = try rasterData(raster)
            try require(actual == expected[index], "source swap \(step) displayed a stale cached diagram")
            try await verifyLiveDiagramPixels(tile)
            try snapshot(tile, name: "source-swap-\(step)", directory: directory)
            swapCounts.append(attachments(image).count)
        }
        emit(["event": "source-swaps", "edits": swapCounts.count,
              "imageCounts": swapCounts, "rasterMatches": swapCounts.count])
    }

    private static func churn(_ fixture: Fixture, board: Board, directory: URL, profile: Bool) async throws -> ChurnResult {
        let object = board.create(type: .note, props: .object(["markdown": .string(fixture.markdown(edit: -1))]),
                                  frame: Frame(x: 0, y: 0, w: Double(width), h: 640))
        let tile = NoteTile(object: object, board: board)
        let window = makeWindow(tile)
        defer { tile.setLive(false); tile.removeFromSuperview(); window.close() }
        try await wait("\(fixture.name) initial real diagrams") {
            attachments(try display(tile).attributedString()).count == fixture.sources.count
        }
        let initialImages = attachments(try display(tile).attributedString())
        for attachment in initialImages {
            guard let image = attachment.image else { throw Failure(description: "initial attachment has no image") }
            _ = try rasterData(image)
        }
        _ = try check(tile, fixture: fixture, edit: -1)
        try snapshot(tile, name: fixture.name + "-before", directory: directory)
        try await Task.sleep(for: .milliseconds(200))
        emit(["event": "churn-ready", "fixture": fixture.name, "pid": getpid(), "images": initialImages.count, "profile": profile])
        if profile { try await Task.sleep(for: .seconds(3)) }

        let heartbeat = Heartbeat()
        heartbeat.start()
        var immediateCounts: [Int] = []
        var settledCounts: [Int] = []
        do {
            try await Task.sleep(for: .milliseconds(20))
            for edit in 0..<editCount {
                heartbeat.sample()
                tile.update(try board.update(object.id, props: .object(["markdown": .string(fixture.markdown(edit: edit))])))
                heartbeat.sample()
                immediateCounts.append(try check(tile, fixture: fixture, edit: edit))
                try await Task.sleep(for: .milliseconds(20))
                heartbeat.sample()
                settledCounts.append(try check(tile, fixture: fixture, edit: edit))
            }
            try await Task.sleep(for: .milliseconds(200))
            _ = try check(tile, fixture: fixture, edit: editCount - 1)
            heartbeat.stop()
        } catch {
            heartbeat.stop()
            emit(["event": "churn-failure", "fixture": fixture.name, "completedEdits": immediateCounts.count,
                  "immediateImageCounts": immediateCounts, "settledImageCounts": settledCounts,
                  "maxGapMs": heartbeat.maximumMilliseconds, "error": String(describing: error)])
            throw error
        }
        let passed = heartbeat.maximumMilliseconds <= gapLimitMilliseconds
        emit(["event": "churn", "fixture": fixture.name, "edits": immediateCounts.count,
              "expectedImagesPerEdit": fixture.sources.count, "immediateImageCounts": immediateCounts,
              "settledImageCounts": settledCounts, "immediateImagesTotal": immediateCounts.reduce(0, +),
              "settledImagesTotal": settledCounts.reduce(0, +), "finalImages": try check(tile, fixture: fixture, edit: editCount - 1),
              "maxGapMs": heartbeat.maximumMilliseconds, "limitMs": gapLimitMilliseconds,
              "heartbeatSamples": heartbeat.samples, "withinLimit": passed, "assertsTiming": !profile])
        try await verifyLiveDiagramPixels(tile)
        try geometry(tile, state: "churn-final-\(fixture.name)", zoom: 1)
        try snapshot(tile, name: fixture.name + "-after", directory: directory)
        if fixture.name == "flowchart-120" { try await sourceSwaps(tile, board: board, directory: directory) }
        return ChurnResult(edits: immediateCounts.count, immediateImages: immediateCounts.reduce(0, +),
                           settledImages: settledCounts.reduce(0, +), withinLimit: passed)
    }

    private static func lifecycle(board: Board, directory: URL) async throws {
        let source = "flowchart TD\nA[First] --> B[Second] --> C[Third] --> D[Fourth] --> E[Last]"
        let fixture = Fixture(name: "duplicate-lifecycle", sources: [source, source])
        let initial = "Geometry heading\n\n" + fixture.markdown(edit: 0)
        let object = board.create(type: .note, props: .object(["markdown": .string(initial)]),
                                  frame: Frame(x: 0, y: 0, w: 760, h: 420))
        let tile = NoteTile(object: object, board: board)
        let host = NSView(frame: tile.bounds)
        host.autoresizesSubviews = false
        host.addSubview(tile)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView!.addSubview(host)
        window.orderFrontRegardless()
        defer { tile.setLive(false); tile.removeFromSuperview(); window.close() }

        func loaded(_ count: Int) throws -> Bool {
            let text = try display(tile)
            let found = attachments(text.attributedString())
            return found.count == count && found.allSatisfy { $0.image != nil }
        }
        func record(_ state: String, expected: Int) throws {
            let text = try display(tile)
            let count = attachments(text.attributedString()).count
            let layers = imageLayers(text).count
            try require(count == expected && layers == expected,
                        "\(state): expected \(expected) images and layers, got \(count)/\(layers)")
            lifecycleChecks += 1
            emit(["event": "lifecycle", "state": state, "attachments": count, "imageLayers": layers])
        }
        try await wait("duplicate fences in real NoteTile") { try loaded(fixture.sources.count) }
        let text = try display(tile)
        let initialRasters = try attachments(text.attributedString()).map { try rasterData($0.image!) }
        try require(initialRasters.count == fixture.sources.count && Set(initialRasters).count == 1,
                    "duplicate fences did not display the same raster twice")
        try record("duplicate-fences", expected: fixture.sources.count)
        for zoom in [CGFloat(0.65), CGFloat(1.35)] {
            host.frame = NSRect(x: 12, y: 12, width: tile.bounds.width * zoom, height: tile.bounds.height * zoom)
            host.bounds = tile.bounds
            try await Task.sleep(for: .milliseconds(80))
            try geometry(tile, state: "zoom-\(zoom)", zoom: zoom)
            try await stage("native-geometry-\(zoom)", tile: tile, directory: directory)
        }
        let zoom: CGFloat = 1.35
        guard let scroll = text.enclosingScrollView else { throw Failure(description: "native note has no internal scroll view") }
        let beforeScroll = try geometry(tile, state: "before-scroll", zoom: zoom)
        let start = scroll.contentView.bounds.origin
        let offset = min(CGFloat(90), text.bounds.height - scroll.contentView.bounds.height)
        try require(offset > 20, "duplicate-fence fixture is not tall enough to exercise internal scrolling")
        scroll.contentView.scroll(to: CGPoint(x: start.x, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(80))
        let scrolled = try geometry(tile, state: "internal-scroll", zoom: zoom)
        let delta = scroll.contentView.bounds.minY - start.y
        try require(delta > 20 && abs(abs(scrolled[0].minY - beforeScroll[0].minY) - delta * zoom) < 0.1,
                    "native internal scrolling did not move diagram window geometry by the scaled clip offset")
        try record("internal-scroll", expected: fixture.sources.count)
        try await stage("native-internal-scroll", tile: tile, directory: directory)

        let oldY = imageLayers(text)[0].frame.minY
        let edited = Array(repeating: "Inserted paragraph above both diagrams.", count: 5).joined(separator: "\n\n") + "\n\n" + initial
        tile.update(try board.update(object.id, props: .object(["markdown": .string(edited)])))
        try await wait("edited prose above duplicate diagrams") { try loaded(fixture.sources.count) }
        try geometry(tile, state: "edit-above", zoom: zoom)
        try require(imageLayers(text)[0].frame.minY > oldY + 30, "editing above the diagram did not move its attachment")
        let editedRasters = try attachments(text.attributedString()).map { try rasterData($0.image!) }
        try require(editedRasters == initialRasters, "editing prose replaced a duplicate diagram with a different image")
        try record("edit-above", expected: fixture.sources.count)
        try await stage("native-edit-above", tile: tile, directory: directory)

        let reused = imageLayers(text)
        let foreign = CALayer()
        reused.forEach { foreign.addSublayer($0) }
        text.needsLayout = true
        text.layoutSubtreeIfNeeded()
        try geometry(tile, state: "reattached-layer", zoom: zoom)
        try require(zip(imageLayers(text), reused).allSatisfy { $0 === $1 },
                    "native relayout discarded instead of reattaching the retained image layers")
        try record("reattached-layer", expected: fixture.sources.count)

        tile.setFrameSize(NSSize(width: 620, height: 360))
        host.setFrameSize(NSSize(width: tile.bounds.width * zoom, height: tile.bounds.height * zoom))
        host.bounds = tile.bounds
        let resizedWidth = (tile.bounds.width - 2 * ObjectMeasure.noteInset.width).rounded(.down)
        let resized = await NoteMermaid.resolve(NoteMarkdown.parse("```mermaid\n\(source)\n```"),
                                                 width: resizedWidth, appearance: .light)
        guard case .image(let resizedImage)? = resized[1] else { throw Failure(description: "resized diagram did not render") }
        let resizedRaster = try rasterData(resizedImage)
        try await wait("resize publishes both diagram rasters") {
            guard try loaded(fixture.sources.count) else { return false }
            return try attachments(text.attributedString()).allSatisfy { try rasterData($0.image!) == resizedRaster }
        }
        try geometry(tile, state: "resize", zoom: zoom)
        try record("resize", expected: fixture.sources.count)
        try await stage("native-resize", tile: tile, directory: directory)

        tile.setHostBoardClosed(true)
        try require(text.isSelectable && !text.isEditable && !tile.isEditing,
                    "closed-board note did not enter its supported selectable read-only state")
        let all = text.string as NSString
        let attachmentRange = all.range(of: "\u{FFFC}")
        try require(attachmentRange.location != NSNotFound && attachmentRange.location > 0,
                    "read-only note has no diagram to select across")
        let selectionStart = max(0, attachmentRange.location - 20)
        let selection = NSRange(location: selectionStart,
                                length: min(all.length, attachmentRange.location + 30) - selectionStart)
        try require(window.makeFirstResponder(text), "read-only note could not take selection focus")
        text.setSelectedRange(selection)
        text.scrollRangeToVisible(selection)
        try require(text.selectedRange() == selection && NSLocationInRange(attachmentRange.location, selection),
                    "read-only selection did not span the displayed diagram")
        text.copy(nil)
        try require(NSPasteboard.general.string(forType: .string) == all.substring(with: selection),
                    "read-only selection across diagram did not copy the displayed range")
        try geometry(tile, state: "read-only-selection", zoom: zoom)
        try record("read-only-selection", expected: fixture.sources.count)
        try await stage("native-read-only-selection", tile: tile, directory: directory)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        tile.setHostBoardClosed(false)

        let removedLayers = imageLayers(text)
        tile.setLive(false)
        try require(text.enclosingScrollView?.superview == nil && text.string.isEmpty,
                    "parked note retained a displayed text hierarchy")
        try require(imageLayers(text).isEmpty && removedLayers.allSatisfy { $0.superlayer == nil },
                    "parked note retained visible diagram layers")
        lifecycleChecks += 1
        emit(["event": "lifecycle", "state": "parked", "attachments": attachments(text.attributedString()).count,
              "imageLayers": imageLayers(text).count])
        tile.setLive(true)
        try await wait("unpark restores duplicate diagrams") { try loaded(fixture.sources.count) }
        try geometry(tile, state: "unparked", zoom: zoom)
        try record("unparked", expected: fixture.sources.count)
        try await stage("native-unparked", tile: tile, directory: directory)

        let single = "One fence remains.\n\n```mermaid\n\(source)\n```\n\nAfter diagram."
        let duplicateLayers = imageLayers(text)
        tile.update(try board.update(object.id, props: .object(["markdown": .string(single)])))
        try await wait("delete one duplicate fence") { try loaded(1) }
        try geometry(tile, state: "delete-one-fence", zoom: zoom)
        try record("delete-one-fence", expected: 1)
        try require(duplicateLayers.dropFirst().allSatisfy { $0.superlayer == nil },
                    "deleted duplicate fence left its image layer attached")
        let finalLayers = imageLayers(text)
        tile.update(try board.update(object.id, props: .object(["markdown": .string("No diagrams remain.")])))
        try await wait("delete final fence") { try loaded(0) }
        try record("delete-all-fences", expected: 0)
        try require(finalLayers.allSatisfy { $0.superlayer == nil }, "deleted final fence left an image layer attached")
        try await stage("native-deleted-fences", tile: tile, directory: directory)
    }

    private static func candidate(_ fixture: Fixture, board: Board, directory: URL, profile: Bool) async throws -> Candidate? {
        let diagramWidth = (width - 2 * ObjectMeasure.noteInset.width).rounded(.down)
        let outcomes = await NoteMermaid.resolve(NoteMarkdown.parse("```mermaid\n\(fixture.sources[0])\n```"),
                                                 width: diagramWidth, appearance: .light)
        guard case .image(let image)? = outcomes[1],
              let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            let reason: String
            if case .fallback(let failure)? = outcomes[1] { reason = String(describing: failure) }
            else { reason = "no raster outcome" }
            emit(["event": "candidate", "fixture": fixture.name, "rendered": false, "fallback": reason])
            return nil
        }
        let observed = Candidate(fixture: fixture, pixelsWide: pixels.width, pixelsHigh: pixels.height)
        let heartbeat = Heartbeat()
        heartbeat.start()
        defer { heartbeat.stop() }
        let object = board.create(type: .note, props: .object(["markdown": .string(fixture.markdown(edit: -1))]),
                                  frame: Frame(x: 0, y: 0, w: Double(width), h: 640))
        let tile = NoteTile(object: object, board: board)
        let window = makeWindow(tile)
        defer { tile.setLive(false); tile.removeFromSuperview(); window.close() }
        try await wait("\(fixture.name) candidate visible as native image") {
            let text = try display(tile)
            return attachments(text.attributedString()).count == fixture.sources.count &&
                imageLayers(text).count == fixture.sources.count
        }
        _ = try check(tile, fixture: fixture, edit: -1)
        tile.layoutSubtreeIfNeeded()
        tile.displayIfNeeded()
        heartbeat.stop()
        let idle = Heartbeat()
        let idleStarted = ProcessInfo.processInfo.systemUptime
        idle.start()
        do {
            try await Task.sleep(for: .milliseconds(500))
            idle.stop()
        } catch {
            idle.stop()
            throw error
        }
        let idleMilliseconds = (ProcessInfo.processInfo.systemUptime - idleStarted) * 1000
        try geometry(tile, state: "candidate-\(fixture.name)", zoom: 1)
        emit(["event": "candidate", "fixture": fixture.name, "rendered": true,
              "pixelsWide": observed.pixelsWide, "pixelsHigh": observed.pixelsHigh, "pixelArea": observed.area,
              "publicationMaxGapMs": heartbeat.maximumMilliseconds, "publicationHeartbeatSamples": heartbeat.samples,
              "displayMaxGapMs": idle.maximumMilliseconds, "displayHeartbeatSamples": idle.samples,
              "idleDisplayMilliseconds": idleMilliseconds, "measurement": "idle-display-without-edits",
              "withinLimit": max(heartbeat.maximumMilliseconds, idle.maximumMilliseconds) <= gapLimitMilliseconds,
              "assertsTiming": !profile])
        try await stage("candidate-\(fixture.name)", tile: tile, directory: directory)
        try require(profile || max(heartbeat.maximumMilliseconds, idle.maximumMilliseconds) <= gapLimitMilliseconds,
                    "\(fixture.name) displayed image exceeded the 50ms main-thread gap limit")
        return observed
    }

    private static func timeoutRecovery(profile: Bool) async throws {
        let previous = NoteMermaid.backend
        let backend = RecoveryBackend()
        NoteMermaid.backend = backend
        defer { NoteMermaid.backend = previous }
        let first = await NoteMermaid.resolve(NoteMarkdown.parse("```mermaid\nflowchart LR\nFresh --> Ready\n```"),
                                             width: 1400, appearance: .light)
        guard case .image? = first[1], let cold = backend.preparationMilliseconds.first else {
            throw Failure(description: "fresh renderer did not produce the recovery control image")
        }
        let hostile = "---\nconfig:\n  radar:\n    width: 4000\n    height: 4000\n---\nradar-beta\nshowLegend false\naxis a,b,c,d\ncurve "
            + (0..<3300).map { "c\($0){9,9,9,9}" }.joined(separator: ",")
        for trial in 0..<3 {
            let stopped = await NoteMermaid.resolve(NoteMarkdown.parse("```mermaid\n\(hostile)\n%% recovery \(trial)\n```"),
                                                   width: 1400, appearance: .light)
            let active = ProcessInfo.processInfo.systemUptime - backend.readyUptime
            let timedOut: Bool
            switch stopped[1] {
            case .image?: timedOut = false
            case .fallback?:
                try require(active >= 1.9, "recovery workload fell back without exercising the warm deadline")
                timedOut = true
            case nil: throw Failure(description: "recovery workload produced no outcome")
            }
            try require(profile || active < 2.25, "warm renderer exceeded its two-second deadline")
            let next = await NoteMermaid.resolve(NoteMarkdown.parse("```mermaid\nflowchart LR\nRecovered\(trial) --> Ready\n```"),
                                                width: 1400, appearance: .light)
            guard case .image? = next[1], let preparation = backend.preparationMilliseconds.last else {
                throw Failure(description: "ordinary diagram did not recover after a renderer timeout")
            }
            emit(["event": "timeout-recovery", "trial": trial, "freshPreparationMs": cold,
                  "recoveryPreparationMs": preparation, "excessMs": preparation - cold,
                  "maximumExcessMs": 750, "timedOut": timedOut, "activeMs": active * 1000, "assertsTiming": !profile])
            try require(profile || preparation <= cold + 750,
                        "a timed-out diagram delayed the next ordinary diagram beyond cold preparation")
        }
    }

    static func main() async throws {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"], CommandLine.arguments.count >= 2 else {
            throw Failure(description: "run with isolated EASL_HOME and an artifact directory")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var supplied: [Fixture] = []
        var profile = false
        var recoveryOnly = false
        var argument = 2
        while argument < CommandLine.arguments.count {
            let option = CommandLine.arguments[argument]
            if option == "--profile" {
                profile = true
            } else if option == "--recovery-only" {
                recoveryOnly = true
            } else if option == "--stage-seconds" {
                argument += 1
                guard argument < CommandLine.arguments.count,
                      let seconds = Double(CommandLine.arguments[argument]), seconds.isFinite, seconds >= 0 else {
                    throw Failure(description: "--stage-seconds requires a nonnegative finite duration")
                }
                stageSeconds = seconds
            } else if option == "--fixture" {
                argument += 1
                guard argument < CommandLine.arguments.count else { throw Failure(description: "--fixture requires NAME=PATH") }
                let parts = CommandLine.arguments[argument].split(separator: "=", maxSplits: 1).map(String.init)
                try require(parts.count == 2 && !parts[0].isEmpty, "--fixture requires NAME=PATH")
                try require(parts[0].allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" },
                            "fixture names may contain letters, numbers, hyphens and underscores")
                let source = try String(contentsOfFile: parts[1], encoding: .utf8)
                try require(!source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            "fixture \(parts[0]) is empty")
                try require(!supplied.contains { $0.name == parts[0] }, "duplicate fixture name \(parts[0])")
                supplied.append(Fixture(name: parts[0], sources: [source]))
                emit(["event": "fixture-input", "fixture": parts[0], "path": parts[1], "sourceBytes": source.utf8.count])
            } else {
                throw Failure(description: "unknown native option \(option)")
            }
            argument += 1
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if recoveryOnly {
            try await timeoutRecovery(profile: profile)
            emit(["event": "result", "status": "passed", "proof": "timeout-recovery"])
            return
        }
        let root = URL(fileURLWithPath: home).appendingPathComponent("churn-board", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = Board(id: "mermaid-churn", root: root)
        var backend: NoteMermaidWeb? = NoteMermaidWeb()
        NoteMermaid.backend = backend
        defer {
            NoteMermaid.backend = nil
            backend = nil
            emit(["event": "native-cleanup", "pid": getpid(), "backendDetached": true,
                  "visibleWindowsRemaining": NSApp.windows.filter { $0.isVisible }.count])
        }
        emit(["event": "identity", "pid": getpid(), "system": ProcessInfo.processInfo.operatingSystemVersionString,
              "cores": ProcessInfo.processInfo.processorCount, "artifacts": directory.path])
        try await warm(backend!)
        let large = "flowchart TD\n" + (1..<120).map { node in
            "N\((node - 1) / 2)[Node \((node - 1) / 2)] --> N\(node)[Node \(node)]"
        }.joined(separator: "\n")
        let fixtures = [Fixture(name: "flowchart-120", sources: [large]),
                        Fixture(name: "ten-fences", sources: (0..<10).map { "flowchart LR\nA\($0)[Start \($0)] --> B\($0)[Finish \($0)]" })]
        var results: [ChurnResult] = []
        for fixture in fixtures {
            results.append(try await churn(fixture, board: board, directory: directory, profile: profile))
        }
        var candidates: [Candidate] = []
        for fixture in [fixtures[0]] + supplied {
            if let rendered = try await candidate(fixture, board: board, directory: directory, profile: profile) { candidates.append(rendered) }
        }
        guard let largest = candidates.max(by: { $0.area < $1.area }) else {
            throw Failure(description: "no actual rendered candidate image is available for largest-image churn")
        }
        emit(["event": "largest-rendered", "fixture": largest.fixture.name,
              "pixelArea": largest.area, "pixelsWide": largest.pixelsWide, "pixelsHigh": largest.pixelsHigh,
              "renderedCandidateCount": candidates.count, "suppliedCandidateCount": supplied.count])
        if largest.fixture.name != fixtures[0].name {
            let largestFixture = Fixture(name: "largest-rendered-\(largest.fixture.name)", sources: largest.fixture.sources)
            results.append(try await churn(largestFixture, board: board, directory: directory, profile: profile))
        }
        try await lifecycle(board: board, directory: directory)
        try await timeoutRecovery(profile: profile)
        try require(profile || results.allSatisfy(\.withinLimit), "main-queue heartbeat exceeded 50ms; see churn records")
        emit(["event": "result", "status": profile ? "profile-only" : "passed",
              "churnEdits": results.reduce(0) { $0 + $1.edits },
              "immediateImagesTotal": results.reduce(0) { $0 + $1.immediateImages },
              "settledImagesTotal": results.reduce(0) { $0 + $1.settledImages },
              "sourceSwapEdits": swapCounts.count, "geometryChecks": geometryChecks, "lifecycleChecks": lifecycleChecks,
              "renderedCandidates": candidates.count, "fallbackCandidates": supplied.count + 1 - candidates.count])
    }
}

@MainActor
@_cdecl("NoteMermaidChurnMain")
func noteMermaidChurnMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    let app = NSApplication.shared
    Task { @MainActor in
        do {
            try await NoteMermaidChurn.main()
            app.terminate(nil)
        } catch {
            let failure: [String: Any] = ["event": "failure", "pid": getpid(), "error": String(describing: error)]
            if let data = try? JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys]) {
                FileHandle.standardError.write(data)
                FileHandle.standardError.write(Data("\n".utf8))
            }
            Darwin.exit(1)
        }
    }
    app.run()
    return 0
}
