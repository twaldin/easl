import AppKit
import CanvasCore
import ImageIO
import UniformTypeIdentifiers

/// An image file on the canvas (`type: image`, `props.path`): a chart an agent saved, a
/// screenshot, an SVG, a PDF's first page. The picture keeps its aspect ratio inside the body,
/// above an optional one-line `caption`, and reloads whenever the file changes on disk (agents
/// re-save charts in place). A Hyper-click on the picture mentions that pixel of the image.
@MainActor
final class ImageTile: NSView, TileContent {
    /// File events arrive in bursts (write, rename, touch); reload once they settle.
    static let debounce: TimeInterval = 0.2

    private enum FileSource {
        case local(root: URL)
        case host(HostFiles, root: String)
    }
    private enum Resolution {
        case preview(Int)
        case original

        func covers(_ other: Resolution) -> Bool {
            switch (self, other) {
            case (.original, _): true
            case (.preview(let have), .preview(let need)): have >= need
            case (.preview, .original): false
            }
        }
    }

    private var object: CanvasObject
    private let source: FileSource
    private var live = true
    /// The loaded picture and its natural size (pixels for bitmaps, points for SVG and PDF).
    private var picture: (image: NSImage, size: CGSize, path: String)?
    private final class Animation {
        let frames: GIFFrames
        var index = 0
        var cycle = 0
        var image: NSImage
        var delay: TimeInterval

        var isComplete: Bool {
            guard let totalPlays = frames.totalPlays else { return false }
            return cycle == totalPlays - 1 && index == frames.count - 1
        }

        init(frames: GIFFrames, image: NSImage, delay: TimeInterval) {
            self.frames = frames
            self.image = image
            self.delay = delay
        }
    }
    private var animation: Animation?
    private var animationTimer: Timer?
    private var animationTask: Task<Void, Never>?
    /// The picture's mean relative luminance, nil when it is mostly transparent (the tile's
    /// background shows): what drawings in the default ink over it contrast with.
    private(set) var surfaceLuminance: Double?
    /// Why there is no picture: the file is missing or unreadable.
    private var failure: String?
    private var loaded = false
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var resolution: Resolution?
    private var loadingResolution: Resolution?
    private var events: FileEvents?
    private var hostWatch: HostFileWatch?
    private var pendingReload: DispatchWorkItem?
    private var pendingResolutionUpgrade: DispatchWorkItem?
    /// Reload after a period without a watcher, including a detached window.
    private var stale = false

    init(object: CanvasObject, board: Board, files: HostFiles? = nil) {
        self.object = object
        if let files {
            source = .host(files, root: board.root.path)
        } else {
            source = .local(root: board.root)
        }
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        if case .local = source { reload() }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        loadTask?.cancel()
        animationTask?.cancel()
        MainActor.assumeIsolated { animationTimer?.invalidate() }
    }

    nonisolated override var isFlipped: Bool { true }

    private var path: String { object.props["path"]?.string ?? "" }
    private var caption: String? { object.props["caption"]?.string.flatMap { $0.isEmpty ? nil : $0 } }

    // MARK: Loading

    private func requestedResolution(scale: CGFloat? = nil) -> Resolution {
        guard case .host = source else { return .original }
        let pixels: CGFloat
        if let scale {
            pixels = max(bounds.width, bounds.height) * scale
        } else if let window {
            let displayed = convert(bounds, to: nil).size
            pixels = max(displayed.width, displayed.height) * window.backingScaleFactor
        } else {
            pixels = max(bounds.width, bounds.height) * TileFrameView.cardPixelsPerPoint
        }
        guard pixels.isFinite, pixels <= 2048 else { return .original }
        var limit = 64
        while CGFloat(limit) < pixels { limit *= 2 }
        return .preview(limit)
    }

    /// Reads the file off the main thread; the newest read wins.
    private func reload(priority: HostReadPriority? = nil, resolution requested: Resolution? = nil) {
        stopAnimation()
        loadTask?.cancel()
        hostWatch?.cancel()
        hostWatch = nil
        pendingReload?.cancel()
        pendingReload = nil
        pendingResolutionUpgrade?.cancel()
        pendingResolutionUpgrade = nil
        loadGeneration += 1
        stale = false
        let generation = loadGeneration
        let source = source
        let path = path
        let priority = priority ?? (live && window != nil ? .visible : .background)
        let requested = requested ?? requestedResolution()
        loadingResolution = requested
        let id = object.id
        loadTask = Task { [weak self] in
            var read: (data: Data, size: CGSize)?
            var previewImage: CGImage?
            var readResolution: Resolution = .original
            var failure: String?
            var readFailure: HostFileError?
            var baseline: HostFileObservation?
            if path.isEmpty {
                failure = "no image path"
            } else {
                switch source {
                case .local(let root):
                    let file = LocalImage.tileFile(path, root: root)
                    read = await LocalImage.read(file)
                    if read == nil {
                        failure = FileManager.default.fileExists(atPath: file.path) ? "not a readable image: \(path)" : "image not found: \(path)"
                    }
                case .host(let files, let root):
                    do {
                        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                        let raster = ext == "png" || ext == "jpg" || ext == "jpeg"
                        var preview: HostImagePreview?
                        if case .preview(let pixels) = requested, raster {
                            do {
                                preview = try await files.imagePreview(object: id, maxPixels: pixels, priority: priority)
                            } catch is CancellationError {
                                return
                            } catch {
                                try Task.checkCancellation()
                                if let failure = error as? EaslConnection.Failure,
                                   !failure.isHostResponse || failure.code == "unavailable" || failure.code == "timeout" {
                                    throw failure
                                }
                                let metadata = HostFileRequest(source: .directory(root), policy: .boardImage(path), bytes: false)
                                do {
                                    baseline = .version(try await files.read(metadata, priority: priority).version)
                                } catch is CancellationError {
                                    return
                                } catch {
                                    baseline = .failure(error as? HostFileError ?? .unavailable(String(describing: error)))
                                }
                                throw error
                            }
                        }
                        if let preview, case .preview(let pixels) = requested {
                            read = (preview.data, CGSize(width: CGFloat(preview.naturalWidth), height: CGFloat(preview.naturalHeight)))
                            previewImage = preview.image
                            readResolution = .preview(pixels)
                            baseline = .version(preview.version)
                        } else {
                            let file = try await files.read(HostFileRequest(source: .directory(root), policy: .boardImage(path)), priority: priority)
                            baseline = .version(file.version)
                            if let size = await offPool({ LocalImage.naturalSize(of: file.data) }) {
                                read = (file.data, size)
                            } else {
                                failure = "not a readable image on host: \(path)"
                            }
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        let error = error as? HostFileError ?? .unavailable(String(describing: error))
                        readFailure = error
                        baseline = baseline ?? .failure(error)
                        failure = Self.hostFailure(error, path: path)
                    }
                }
            }
            guard !Task.isCancelled, self?.loadGeneration == generation, self?.path == path else { return }
            var image: NSImage?
            var animation: Animation?
            if let read {
                if let previewImage {
                    image = NSImage(cgImage: previewImage, size: read.size)
                } else if let frames = GIFFrames(data: read.data), let first = await frames.frame(0) {
                    let firstImage = NSImage(cgImage: first.image, size: read.size)
                    image = firstImage
                    animation = Animation(frames: frames, image: firstImage, delay: first.delay)
                } else {
                    image = NSImage(data: read.data)
                }
            }
            guard let self, !Task.isCancelled, self.loadGeneration == generation, self.path == path else { return }
            self.loaded = true
            self.loadingResolution = nil
            if let read, let image {
                image.size = read.size
                self.picture = (image, read.size, path)
                self.resolution = readResolution
                self.animation = animation
                self.failure = nil
            } else {
                let unavailable = if case .unavailable? = readFailure { true } else { false }
                if !unavailable || self.picture?.path != path {
                    self.picture = nil
                    self.resolution = nil
                    self.animation = nil
                }
                self.failure = failure ?? "not a readable image: \(path)"
            }
            let luminance = self.picture.flatMap { Self.meanLuminance($0.image) }
            if luminance != self.surfaceLuminance {
                self.surfaceLuminance = luminance
                NotificationCenter.default.post(name: .tileSurfaceChanged, object: self)
            }
            self.needsDisplay = true
            self.startAnimation()
            self.watch(baseline: baseline)
        }
        watch()
    }

    private static func hostFailure(_ error: HostFileError, path: String) -> String {
        switch error {
        case .refused: "image path refused by host: \(path)"
        case .notFound: "image not found on host: \(path)"
        case .tooLarge(let limit): "image too large on host (limit \(limit) bytes): \(path)"
        case .unreadable: "not a readable image on host: \(path)"
        case .ref(let message): "host image source unavailable: \(message)"
        case .unavailable(let message): "host image unavailable: \(message)"
        }
    }

    private func startAnimation() {
        guard live, window != nil, picture?.path == path, let animation, !animation.isComplete,
              animationTimer == nil, animationTask == nil else { return }
        let timer = Timer(timeInterval: animation.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.animationTimer = nil
                self.advanceAnimation()
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceAnimation() {
        guard live, window != nil, let animation, !animation.isComplete else { return }
        let generation = loadGeneration
        let next = (animation.index + 1) % animation.frames.count
        animationTask = Task { [weak self] in
            let frame = await animation.frames.frame(next)
            guard let self, !Task.isCancelled, self.loadGeneration == generation,
                  self.animation === animation, self.live, self.window != nil else { return }
            self.animationTask = nil
            guard let frame else { return }
            if next == 0, animation.frames.totalPlays != nil {
                animation.cycle += 1
            }
            animation.index = next
            animation.image = NSImage(cgImage: frame.image, size: self.picture?.size ?? .zero)
            animation.delay = frame.delay
            self.needsDisplay = true
            self.startAnimation()
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationTask?.cancel()
        animationTask = nil
    }

    /// Mean relative luminance of an image drawn into 8×8 pixels; nil when most of it is
    /// transparent.
    private static func meanLuminance(_ image: NSImage) -> Double? {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            red += Double(pixels[index]); green += Double(pixels[index + 1]); blue += Double(pixels[index + 2]); alpha += Double(pixels[index + 3])
        }
        guard alpha / Double(side * side * 255) >= 0.5 else { return nil }
        // Premultiplied: divide by the coverage for the opaque parts' color.
        return InkContrast.luminance(red: red / alpha, green: green / alpha, blue: blue / alpha)
    }

    /// Local file events and host metadata polling exist only while live in a window.
    private func watch(baseline: HostFileObservation? = nil) {
        guard live, window != nil, !path.isEmpty else {
            stopWatching()
            return
        }
        let path = path
        switch source {
        case .local(let root):
            let target = FileEvents.canonical(LocalImage.tileFile(path, root: root).path)
            let directory = FileEvents.watchableDirectory(for: target)
            guard events?.directories != [directory] else { return }
            events = FileEvents(directories: [directory]) { [weak self] paths in
                guard let self, self.live, self.window != nil, self.path == path, paths.contains(target) else { return }
                self.scheduleReload()
            }
        case .host(let files, let root):
            guard let baseline else { return }
            hostWatch?.cancel()
            let generation = loadGeneration
            let request = HostFileRequest(source: .directory(root), policy: .boardImage(path))
            hostWatch = HostFileWatch(files: files, request: request, baseline: baseline) { [weak self] _ in
                guard let self, self.live, self.window != nil, self.path == path, self.loadGeneration == generation else { return }
                self.reload()
            }
        }
    }

    private func stopWatching() {
        events = nil
        hostWatch?.cancel()
        hostWatch = nil
        pendingReload?.cancel()
        pendingReload = nil
        pendingResolutionUpgrade?.cancel()
        pendingResolutionUpgrade = nil
    }

    private func suspend() {
        stopWatching()
        stopAnimation()
        loadTask?.cancel()
        loadTask = nil
        loadingResolution = nil
        loadGeneration += 1
        stale = true
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let generation = loadGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.live, self.window != nil, self.loadGeneration == generation else { return }
                self.reload()
            }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            suspend()
        } else if live {
            reload()
        }
    }

    // MARK: Geometry and drawing

    /// The body minus the caption strip.
    private func pictureArea(_ size: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - (caption == nil ? 0 : LocalImage.captionHeight)))
    }

    /// Where the picture draws: aspect-fit and centered in the picture area, never scaled up past
    /// its natural size.
    private func pictureRect(_ size: CGSize) -> CGRect? {
        guard let natural = picture?.size, natural.width > 0, natural.height > 0 else { return nil }
        let area = pictureArea(size)
        let scale = min(area.width / natural.width, area.height / natural.height, 1)
        let drawn = CGSize(width: natural.width * scale, height: natural.height * scale)
        return CGRect(x: area.midX - drawn.width / 2, y: area.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        paint(in: bounds, animated: live && window != nil)
    }

    /// Picture, caption, or the reason there is none; `bounds` is the body (top-left origin).
    private func paint(in bounds: CGRect, animated: Bool = false) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        if let picture, let rect = pictureRect(bounds.size) {
            let image = animated ? animation?.image ?? picture.image : picture.image
            image.drawUpright(in: rect)
        }
        if loaded, let failure {
            let text = NSAttributedString(string: failure, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: picture == nil ? NSColor.secondaryLabelColor : NSColor.systemOrange])
            if picture != nil {
                let area = CGRect(x: 8, y: 8, width: max(0, bounds.width - 16), height: 40)
                NSColor.textBackgroundColor.withAlphaComponent(0.9).setFill()
                area.fill()
                text.draw(with: area.insetBy(dx: 6, dy: 4), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            } else {
                let size = text.size()
                text.draw(at: CGPoint(x: max(8, (bounds.width - size.width) / 2), y: max(8, (pictureArea(bounds.size).height - size.height) / 2)))
            }
        }
        guard let caption else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let strip = CGRect(x: 10, y: bounds.height - LocalImage.captionHeight + 4, width: max(0, bounds.width - 20), height: LocalImage.captionHeight - 8)
        NSAttributedString(string: caption, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
            .draw(with: strip, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: TileContent
    func alignToPixels() {
        pendingResolutionUpgrade?.cancel()
        pendingResolutionUpgrade = nil
        guard live, window != nil, loaded, !stale, picture?.path == path else { return }
        let requested = requestedResolution()
        guard resolution?.covers(requested) != true, loadingResolution?.covers(requested) != true else { return }
        let generation = loadGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.live, self.window != nil, self.loadGeneration == generation else { return }
                let requested = self.requestedResolution()
                guard self.resolution?.covers(requested) != true, self.loadingResolution?.covers(requested) != true else { return }
                self.reload(resolution: requested)
            }
        }
        pendingResolutionUpgrade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }


    func setLive(_ live: Bool) {
        guard live != self.live else { return }
        self.live = live
        if live {
            reload()
        } else {
            suspend()
        }
    }

    func render(_ request: TileRenderRequest) async -> TileRender {
        let requested = requestedResolution(scale: request.scale)
        if !loaded || stale || (picture != nil && resolution?.covers(requested) != true) {
            if loadingResolution?.covers(requested) != true { reload(priority: request.priority, resolution: requested) }
            await loadTask?.value
        }
        guard loaded, !stale else { return .placeholder(request, "image read was cancelled") }
        if picture != nil, resolution?.covers(requested) != true {
            return TileRender(image: nil, contentSize: request.size, state: .failed, reason: failure ?? "image resolution unavailable")
        }
        let image = request.image { bounds in paint(in: bounds) }
        guard let image else { return TileRender(image: nil, contentSize: request.size, state: .failed, reason: "bitmap allocation failed") }
        return TileRender(image: image, contentSize: request.size, state: .rendered)
    }

    /// A pixel of the picture (in the image's own pixels from its top-left), else the tile.
    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard let natural = picture?.size, let rect = pictureRect(bounds.size), rect.contains(point) else { return .object(object.id) }
        let x = Int(((point.x - rect.minX) / rect.width * natural.width).rounded(.down))
        let y = Int(((point.y - rect.minY) / rect.height * natural.height).rounded(.down))
        return .image(object: object.id, path: path, x: min(max(0, x), Int(natural.width) - 1), y: min(max(0, y), Int(natural.height) - 1))
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .image = target, let rect = pictureRect(bounds.size) else { return bounds }
        return rect
    }

    var takesKeyboardFocus: Bool { false }

    func update(_ object: CanvasObject) {
        let previous = self.object
        self.object = object
        if previous.props["path"] != object.props["path"] {
            stopWatching()
            if case .host = source, !live || window == nil {
                suspend()
            } else {
                reload()
            }
        } else if previous.props["caption"] != object.props["caption"] {
            needsDisplay = true
        }
    }
}

private actor GIFFrames {
    private let source: CGImageSource
    nonisolated let count: Int
    nonisolated let totalPlays: Int?

    struct Frame: Sendable {
        let image: CGImage
        let delay: TimeInterval
    }

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier,
              CGImageSourceGetCount(source) > 1 else { return nil }
        self.source = source
        count = CGImageSourceGetCount(source)
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        if let repetitions = gif?[kCGImagePropertyGIFLoopCount] as? Int {
            // The extension counts repetitions after the initial play; zero means forever.
            totalPlays = repetitions == 0 ? nil : repetitions + 1
        } else {
            totalPlays = 1
        }
    }

    func frame(_ index: Int) -> Frame? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { return nil }
        defer { CGImageSourceRemoveCacheAtIndex(source, index) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return Frame(image: image, delay: delay.isFinite && delay >= 0.011 ? delay : 0.1)
    }
}
