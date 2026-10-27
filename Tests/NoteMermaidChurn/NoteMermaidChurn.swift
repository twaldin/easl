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
        try require(!text.string.contains("flowchart"), "\(fixture.name) edit \(edit): diagram source replaced an image")
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
        let request = TileRenderRequest(size: tile.bounds.size, scale: 2, full: false,
                                        appearance: NSAppearance(named: .aqua)!)
        let rendered = await tile.render(request)
        guard let pixels = rendered.image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let actual = tile.bitmapImageRepForCachingDisplay(in: tile.bounds) else {
            throw Failure(description: "live/export diagram comparison has no bitmap")
        }
        tile.cacheDisplay(in: tile.bounds, to: actual)
        let expected = NSBitmapImageRep(cgImage: pixels)
        try require(actual.pixelsWide == expected.pixelsWide && actual.pixelsHigh == expected.pixelsHigh,
                    "live note and scale-2 export have different raster bounds")
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
        emit(["event": "live-export-pixels", "matchedDiagramPixels": witnesses, "scale": 2])
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
        }
        emit(["event": "source-swaps", "edits": 3, "imageCounts": [1, 1, 1], "rasterMatches": 3])
    }

    private static func churn(_ fixture: Fixture, board: Board, directory: URL, profile: Bool) async throws -> Bool {
        let object = board.create(type: .note, props: .object(["markdown": .string(fixture.markdown(edit: -1))]),
                                  frame: Frame(x: 0, y: 0, w: Double(width), h: 640))
        let tile = NoteTile(object: object, board: board)
        let window = NSWindow(contentRect: tile.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView!.addSubview(tile)
        window.orderFrontRegardless()
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
        emit(["event": "churn", "fixture": fixture.name, "edits": editCount,
              "expectedImagesPerEdit": fixture.sources.count, "immediateImageCounts": immediateCounts,
              "settledImageCounts": settledCounts, "immediateImagesTotal": immediateCounts.reduce(0, +),
              "settledImagesTotal": settledCounts.reduce(0, +), "finalImages": try check(tile, fixture: fixture, edit: editCount - 1),
              "maxGapMs": heartbeat.maximumMilliseconds, "limitMs": gapLimitMilliseconds,
              "heartbeatSamples": heartbeat.samples, "withinLimit": passed, "assertsTiming": !profile])
        try await verifyLiveDiagramPixels(tile)
        try snapshot(tile, name: fixture.name + "-after", directory: directory)
        if fixture.sources.count == 1 { try await sourceSwaps(tile, board: board, directory: directory) }
        return passed
    }

    static func main() async throws {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"], CommandLine.arguments.count >= 2 else {
            throw Failure(description: "run with isolated EASL_HOME and an artifact directory")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        let profile = CommandLine.arguments.contains("--profile")
        var timingPassed = true
        for fixture in fixtures {
            let passed = try await churn(fixture, board: board, directory: directory, profile: profile)
            timingPassed = timingPassed && passed
        }
        try require(profile || timingPassed, "main-queue heartbeat exceeded 50ms; see churn records")
        emit(["event": "result", "status": profile ? "profile-only" : "passed", "churnEdits": 50,
              "immediateImagesTotal": 275, "settledImagesTotal": 275, "sourceSwapEdits": 3])
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
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            Darwin.exit(1)
        }
    }
    app.run()
    return 0
}
