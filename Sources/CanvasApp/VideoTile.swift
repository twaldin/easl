import AppKit
@preconcurrency import AVFoundation
import AVKit
import CanvasCore
import CoreImage
import UniformTypeIdentifiers

@MainActor
final class VideoTile: NSView, TileContent {
    private static let snapshotContext = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    private var object: CanvasObject
    private let board: Board
    private let files: HostFiles?
    private let player = AVPlayer()
    private let playerView = VideoPlayerView()
    private var source: HostVideoAsset?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var videoTransform: CGAffineTransform?
    private var statusObservation: NSKeyValueObservation?
    private var displayObservation: NSKeyValueObservation?
    private var endedObserver: NSObjectProtocol?
    private var playTask: Task<Void, Never>?
    private var posterTask: Task<Void, Never>?
    private var thumbnails: [UUID: (source: HostVideoAsset, generator: AVAssetImageGenerator)] = [:]
    private var posterView: NSImageView?
    private var snapshotCover: NSImageView?
    private var lastSnapshot: NSImage?
    private var failureLabel: NSTextField?
    private var posterFailed = false
    private var readyWaiters: [@MainActor () -> Void] = []
    private var live = true
    private var hostBoardClosed = false
    private var playbackGeneration = 0
    private var position: Double
    private var pendingSeek = true
    private var shouldPlay: Bool

    init(object: CanvasObject, board: Board, files: HostFiles? = nil) {
        self.object = object
        self.board = board
        self.files = files
        position = object.props["startTime"]?.number ?? 0
        shouldPlay = object.props["autoplay"] == .bool(true)
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        player.allowsExternalPlayback = false
        playerView.frame = bounds
        playerView.autoresizingMask = [.width, .height]
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.player = player
        addSubview(playerView)
        displayObservation = playerView.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.live, !self.hostBoardClosed, self.frameReady else { return }
                self.posterView?.isHidden = true
                self.reveal()
            }
        }
        start()
    }

    required init?(coder: NSCoder) { fatalError("unused") }
    nonisolated override var isFlipped: Bool { true }

    deinit {
        playTask?.cancel()
        posterTask?.cancel()
        MainActor.assumeIsolated {
            source?.cancel()
            if let endedObserver { NotificationCenter.default.removeObserver(endedObserver) }
        }
    }

    private func request(_ path: String) -> HostFileRequest {
        HostFileRequest(source: .directory(board.root.path), policy: .boardAsset(path), bytes: false)
    }

    private func start() {
        guard !hostBoardClosed else { return }
        failureLabel?.removeFromSuperview()
        failureLabel = nil
        posterFailed = false
        let source = HostVideoAsset(request: request(object.props["path"]?.string ?? ""), files: files)
        self.source = source
        let item = AVPlayerItem(asset: source.asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        videoOutput = output
        videoTransform = nil
        item.preferredForwardBufferDuration = 2
        player.isMuted = object.props["muted"] == .bool(true)
        player.replaceCurrentItem(with: item)
        pendingSeek = true
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, !self.hostBoardClosed, self.player.currentItem === item else { return }
                if item.status == .readyToPlay { self.seek() }
                if item.status == .failed {
                    self.showFailure(self.source?.failure ?? item.error?.localizedDescription ?? "video could not load")
                }
            }
        }
        endedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.live, !self.hostBoardClosed, self.player.currentItem === item,
                      self.object.props["loop"] == .bool(true) else { return }
                self.position = 0
                self.pendingSeek = true
                self.shouldPlay = true
                self.seek()
            }
        }
        loadPoster()
    }

    private func seek() {
        guard pendingSeek, !hostBoardClosed, let item = player.currentItem, item.status == .readyToPlay else { return }
        pendingSeek = false
        playbackGeneration += 1
        let generation = playbackGeneration
        playTask?.cancel()
        item.cancelPendingSeeks()
        let time = CMTime(seconds: max(0, position), preferredTimescale: 600)
        playTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.playbackGeneration == generation {
                    self.playTask = nil
                    if self.live, !self.hostBoardClosed, self.frameReady {
                        self.posterView?.isHidden = true
                        self.reveal()
                    }
                }
            }
            do {
                if self.videoTransform == nil {
                    let tracks = try await item.asset.loadTracks(withMediaType: .video)
                    let transform: CGAffineTransform
                    if let track = tracks.first { transform = try await track.load(.preferredTransform) }
                    else { transform = .identity }
                    guard !Task.isCancelled, !self.hostBoardClosed, self.player.currentItem === item,
                          self.playbackGeneration == generation else { return }
                    self.videoTransform = transform
                }
                let finished = await self.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                guard finished, !Task.isCancelled, self.live, !self.hostBoardClosed,
                      self.player.currentItem === item, self.playbackGeneration == generation else { return }
                if self.shouldPlay { self.player.play() }
                else { self.player.pause() }
            } catch {
                guard !Task.isCancelled, !self.hostBoardClosed, self.player.currentItem === item,
                      self.playbackGeneration == generation else { return }
                self.showFailure(HostVideoAsset.message(error))
            }
        }
    }

    private func stop() {
        playbackGeneration += 1
        playTask?.cancel()
        playTask = nil
        posterTask?.cancel()
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        statusObservation = nil
        if let endedObserver { NotificationCenter.default.removeObserver(endedObserver) }
        endedObserver = nil
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        videoTransform = nil
        source?.cancel()
        source = nil
    }

    private func loadPoster() {
        posterTask?.cancel()
        posterView?.removeFromSuperview()
        posterView = nil
        if posterFailed {
            failureLabel?.removeFromSuperview()
            failureLabel = nil
            posterFailed = false
        }
        guard let path = object.props["poster"]?.string, !path.isEmpty else { return }
        var request = request(path)
        request.bytes = true
        let files = files
        posterTask = Task { @MainActor [weak self] in
            do {
                let file = try await HostVideoAsset.read(request, files: files)
                guard !Task.isCancelled, let self else { return }
                guard let image = NSImage(data: file.data) else { throw HostFileError.unreadable }
                self.posterView = self.overlay(image)
                self.posterView?.isHidden = self.playerView.isReadyForDisplay
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.showFailure(HostVideoAsset.message(error), poster: true)
            }
        }
    }

    private func overlay(_ image: NSImage) -> NSImageView? {
        guard let parent = playerView.contentOverlayView else { return nil }
        let view = NSImageView(frame: parent.bounds)
        view.autoresizingMask = [.width, .height]
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = image
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        parent.addSubview(view)
        return view
    }

    private func showFailure(_ message: String, poster: Bool = false) {
        if poster, failureLabel != nil, !posterFailed { return }
        posterFailed = poster
        failureLabel?.removeFromSuperview()
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .systemRed
        label.frame = CGRect(x: 12, y: 12, width: max(0, bounds.width - 24), height: 42)
        label.autoresizingMask = [.width]
        addSubview(label)
        failureLabel = label
        if !poster { reveal() }
    }

    private func reveal() {
        let ready = readyWaiters
        readyWaiters.removeAll()
        for callback in ready { callback() }
    }

    private var currentPosition: Double {
        if pendingSeek || playTask != nil { return position }
        let time = player.currentTime().seconds
        return player.currentItem != nil && time.isFinite ? time : position
    }

    private var frameReady: Bool {
        !pendingSeek && playTask == nil && playerView.isReadyForDisplay
    }

    private func captureFrame(pixels: CGSize) -> NSImage? {
        guard !pendingSeek, playTask == nil, let output = videoOutput, let transform = videoTransform,
              let item = player.currentItem else { return nil }
        var time = player.currentTime()
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0, time.seconds >= duration {
            time = CMTime(seconds: max(0, duration - 1 / 600.0), preferredTimescale: 600)
        }
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return nil }
        let imageTransform = CGAffineTransform(a: transform.a, b: -transform.b, c: -transform.c, d: transform.d, tx: transform.tx, ty: transform.ty)
        var image = CIImage(cvPixelBuffer: buffer).transformed(by: imageTransform)
        let extent = image.extent
        let scale = min(1, min(4096, max(1, pixels.width)) / extent.width, min(4096, max(1, pixels.height)) / extent.height)
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let frame = Self.snapshotContext.createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: frame, size: CGSize(width: frame.width, height: frame.height))
    }

    func setHostBoardClosed(_ closed: Bool) {
        guard hostBoardClosed != closed else { return }
        if closed {
            let scale = window?.backingScaleFactor ?? 2
            if let frame = captureFrame(pixels: CGSize(width: bounds.width * scale, height: bounds.height * scale)) { lastSnapshot = frame }
            position = currentPosition
            if player.currentItem?.status == .readyToPlay { shouldPlay = player.rate != 0 }
            playbackGeneration += 1
            playTask?.cancel()
            playTask = nil
            posterTask?.cancel()
            player.pause()
            source?.cancel()
            cancelThumbnails()
        }
        hostBoardClosed = closed
    }

    private func cancelThumbnails() {
        for job in thumbnails.values {
            job.generator.cancelAllCGImageGeneration()
            job.source.cancel()
        }
    }

    private func thumbnail(at time: Double, pixels: CGSize) async throws -> NSImage {
        try Task.checkCancellation()
        guard !hostBoardClosed else { throw CancellationError() }
        let source = HostVideoAsset(request: request(object.props["path"]?.string ?? ""), files: files)
        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: min(4096, max(1, pixels.width)), height: min(4096, max(1, pixels.height)))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let id = UUID()
        thumbnails[id] = (source, generator)
        defer {
            thumbnails[id] = nil
            source.cancel()
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let duration = try await source.asset.load(.duration).seconds
            try Task.checkCancellation()
            let end = duration.isFinite && duration > 0 ? max(0, duration - 1 / 600.0) : time
            let frame = try await generator.image(at: CMTime(seconds: min(max(0, time), end), preferredTimescale: 600))
            try Task.checkCancellation()
            guard !hostBoardClosed else { throw CancellationError() }
            return NSImage(cgImage: frame.image, size: CGSize(width: frame.image.width, height: frame.image.height))
        } onCancel: {
            generator.cancelAllCGImageGeneration()
            Task { @MainActor in source.cancel() }
        }
    }

    func setLive(_ live: Bool) {
        guard !live || !hostBoardClosed else { return }
        guard live != self.live else { return }
        self.live = live
        if live {
            start()
        } else {
            position = currentPosition
            if !hostBoardClosed, player.currentItem?.status == .readyToPlay { shouldPlay = player.rate != 0 }
            readyWaiters.removeAll()
            stop()
        }
    }

    func update(_ object: CanvasObject) {
        let previous = self.object
        self.object = object
        if previous.props["path"] != object.props["path"] {
            stop()
            position = object.props["startTime"]?.number ?? 0
            shouldPlay = object.props["autoplay"] == .bool(true)
            lastSnapshot = nil
            if live { start() }
            return
        }
        if previous.props["startTime"] != object.props["startTime"] {
            position = object.props["startTime"]?.number ?? 0
            pendingSeek = true
            if player.currentItem?.status == .readyToPlay { shouldPlay = player.rate != 0 }
        }
        if previous.props["autoplay"] != object.props["autoplay"] {
            shouldPlay = object.props["autoplay"] == .bool(true)
            if live, !pendingSeek, playTask == nil, !hostBoardClosed {
                if shouldPlay { player.play() } else { player.pause() }
            }
        }
        if previous.props["muted"] != object.props["muted"] { player.isMuted = object.props["muted"] == .bool(true) }
        if live {
            seek()
            if previous.props["poster"] != object.props["poster"] { loadPoster() }
        }
    }

    func render(_ request: TileRenderRequest) async -> TileRender {
        do {
            let frame: NSImage
            if hostBoardClosed {
                guard let cached = lastSnapshot else { return .placeholder(request, "host closed this board before a video frame was cached") }
                frame = cached
            } else {
                frame = try await thumbnail(at: object.props["startTime"]?.number ?? 0,
                                            pixels: CGSize(width: request.size.width * request.scale, height: request.size.height * request.scale))
            }
            let image = request.image { bounds in
                NSColor.black.setFill()
                bounds.fill()
                let scale = min(bounds.width / frame.size.width, bounds.height / frame.size.height)
                let size = CGSize(width: frame.size.width * scale, height: frame.size.height * scale)
                frame.drawUpright(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
            }
            return TileRender(image: image, contentSize: request.size, state: image == nil ? .failed : .rendered, reason: image == nil ? "bitmap allocation failed" : nil)
        } catch is CancellationError {
            return .placeholder(request, "cancelled")
        } catch {
            return TileRender(image: nil, contentSize: request.size, state: .failed, reason: HostVideoAsset.message(error))
        }
    }

    func cardSnapshot() async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let pixels = CGSize(width: bounds.width * TileFrameView.cardPixelsPerPoint, height: bounds.height * TileFrameView.cardPixelsPerPoint)
        if let frame = captureFrame(pixels: pixels) {
            lastSnapshot = frame
            return frame
        }
        if hostBoardClosed { return lastSnapshot }
        let frame = try? await thumbnail(at: currentPosition, pixels: pixels)
        guard !Task.isCancelled else { return nil }
        if let frame { lastSnapshot = frame }
        return frame
    }

    func whenLiveReady(_ ready: @escaping @MainActor () -> Void) {
        guard live, !hostBoardClosed else { return }
        if frameReady || (failureLabel != nil && !posterFailed) { ready() }
        else { readyWaiters.append(ready) }
    }

    func prepareSnapshot() async {
        guard !Task.isCancelled else { return }
        let scale = window?.backingScaleFactor ?? 2
        let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if let frame = captureFrame(pixels: pixels) { lastSnapshot = frame }
        else if !hostBoardClosed, let frame = try? await thumbnail(at: currentPosition, pixels: pixels) {
            guard !Task.isCancelled, !hostBoardClosed else { return }
            lastSnapshot = frame
        }
    }

    func showSnapshot(_ show: Bool) {
        snapshotCover?.removeFromSuperview()
        snapshotCover = nil
        if show, let lastSnapshot { snapshotCover = overlay(lastSnapshot) }
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? { .object(object.id) }
    func outline(for target: MentionTarget) -> NSRect? { bounds }
    var takesKeyboardFocus: Bool { true }
    var surfaceLuminance: Double? { 0 }
    func enterKeyboard() -> Bool { window?.makeFirstResponder(playerView) ?? false }
}

@MainActor
private final class VideoPlayerView: AVPlayerView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class HostVideoAsset: NSObject, AVAssetResourceLoaderDelegate {
    let asset: AVURLAsset
    private let request: HostFileRequest
    private let files: HostFiles?
    private var metadataTask: Task<HostFile, Error>?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var blocks: [HostFile] = []
    private var nextBlock = 0
    private var cancelled = false
    private(set) var failure: String?

    init(request: HostFileRequest, files: HostFiles?) {
        self.request = request
        self.files = files
        var url = URLComponents()
        url.scheme = HtmlKit.scheme
        url.host = "video"
        url.path = "/" + UUID().uuidString
        asset = AVURLAsset(url: url.url!, options: [AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)])
        super.init()
        blocks.reserveCapacity(4)
        asset.resourceLoader.setDelegate(self, queue: .main)
    }

    static func read(_ request: HostFileRequest, files: HostFiles?) async throws -> HostFile {
        if let files { return try await files.read(request) }
        return try await HostFiles.readLocal(request)
    }

    static func message(_ error: Error) -> String {
        if let error = error as? HostFileError { return HostGit.refusal(error) }
        return error.localizedDescription
    }

    private func metadata() async throws -> HostFile {
        if let metadataTask { return try await metadataTask.value }
        let request = request
        let files = files
        let task = Task { try await Self.read(request, files: files) }
        metadataTask = task
        return try await task.value
    }

    private func block(at offset: Int64, metadata: HostFile) async throws -> HostFile {
        if let block = blocks.first(where: { offset >= $0.offset && offset < $0.offset + Int64($0.data.count) }) { return block }
        let start = offset - offset % Int64(HostFileRange.maxLength)
        let length = Int(min(Int64(HostFileRange.maxLength), metadata.size - start))
        var request = request
        request.bytes = true
        request.range = HostFileRange(offset: start, length: length)
        let file = try await Self.read(request, files: files)
        guard file.version == metadata.version, file.size == metadata.size,
              file.offset == start, file.data.count == length else { throw URLError(.resourceUnavailable) }
        if blocks.count < 4 { blocks.append(file) }
        else {
            blocks[nextBlock] = file
            nextBlock = (nextBlock + 1) % 4
        }
        return file
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        MainActor.assumeIsolated {
            guard !cancelled, loadingRequest.request.url == asset.url else { return false }
            let key = ObjectIdentifier(loadingRequest)
            tasks[key] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.tasks[key] = nil }
                do {
                    let metadata = try await self.metadata()
                    try Task.checkCancellation()
                    if let info = loadingRequest.contentInformationRequest {
                        info.contentType = UTType(mimeType: metadata.mimeType)?.identifier
                        info.contentLength = metadata.size
                        info.isByteRangeAccessSupported = true
                    }
                    if let data = loadingRequest.dataRequest {
                        guard data.requestedOffset >= 0 else { throw URLError(.badServerResponse) }
                        let end: Int64
                        if data.requestsAllDataToEndOfResource {
                            end = metadata.size
                        } else {
                            let sum = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
                            guard data.requestedLength >= 0, !sum.overflow else { throw URLError(.badServerResponse) }
                            end = min(metadata.size, sum.partialValue)
                        }
                        var offset = max(data.requestedOffset, data.currentOffset)
                        while offset < end {
                            try Task.checkCancellation()
                            let block = try await self.block(at: offset, metadata: metadata)
                            guard !loadingRequest.isCancelled else { throw CancellationError() }
                            let start = Int(offset - block.offset)
                            let count = Int(min(end - offset, Int64(block.data.count - start)))
                            guard count > 0 else { throw URLError(.resourceUnavailable) }
                            data.respond(with: block.data[start..<(start + count)])
                            offset += Int64(count)
                        }
                    }
                    try Task.checkCancellation()
                    if !loadingRequest.isCancelled { loadingRequest.finishLoading() }
                } catch {
                    if !(error is CancellationError) { self.failure = Self.message(error) }
                    if !loadingRequest.isCancelled { loadingRequest.finishLoading(with: error) }
                }
            }
            return true
        }
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        MainActor.assumeIsolated { tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel() }
    }

    func cancel() {
        cancelled = true
        asset.cancelLoading()
        metadataTask?.cancel()
        for task in tasks.values { task.cancel() }
        blocks.removeAll()
    }
}
