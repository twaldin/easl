import AppKit
import CanvasCore
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Browser tiles another Mac's viewer streams (`surface.*`, docs/design.md "Client mode"). The
/// viewer shows this Mac's own page as images it holds in memory and drives it with native
/// input, so the page keeps this Mac's profile and logins and the viewer runs no WebKit. A
/// stream belongs to the connection that opened it: no other connection can see or drive it,
/// and it ends when that connection closes (`sweep`). Ending one never releases the page; the
/// tile's driven-page policy (`BrowserTile.markDriven`) takes it from there.
@MainActor
final class BrowserSurfaceHost: NSObject {
    static let sweepInterval: TimeInterval = 1
    /// How long after a viewer's press a menu opening on this Mac counts as the page's answer to it.
    static let menuWindow: TimeInterval = 2

    private let registry: BoardRegistry
    private let tile: (Board, ObjectID) -> BrowserTile?
    private var streams: [String: SurfaceStream] = [:]
    private var surfaces: [ObjectIdentifier: BrowserSurface] = [:]
    private var sweeper: Timer?

    init(registry: BoardRegistry, tile: @escaping (Board, ObjectID) -> BrowserTile?) {
        self.registry = registry
        self.tile = tile
        super.init()
    }

    func handle(_ request: SurfaceRequest, from connection: SocketServer.Connection) async throws -> JSONValue {
        switch request {
        case .stream(let id, let scale, let format):
            return try await open(id, scale: scale, format: format, on: connection)
        case .ack(let stream, let frame):
            try owned(stream, by: connection).ack(frame)
            return .object([:])
        case .input(let stream, let events):
            return try await owned(stream, by: connection).input(events)
        case .answer(let id, let dialog, let answer):
            let stream = try owned(id, by: connection)
            try await stream.surface.answer(dialog, answer, from: stream)
            return .object([:])
        case .stop(let stream):
            close(try owned(stream, by: connection), reason: nil)
            return .object(["stopped": .bool(true)])
        }
    }

    private func open(_ id: ObjectID, scale: Double, format: SurfaceFormat, on connection: SocketServer.Connection) async throws -> JSONValue {
        guard let board = registry.board(containing: id), let tile = self.tile(board, id) else {
            throw ApiRouter.Failure("unavailable", "browser tile \(id) is not open in a window")
        }
        await tile.markDriven()
        guard connection.isOpen, board.objects[id] != nil, tile.window != nil else {
            throw ApiRouter.Failure("unavailable", "browser tile \(id) closed while its stream opened")
        }
        guard let webView = tile.webView, webView.bounds.width >= 1, webView.bounds.height >= 1 else {
            throw ApiRouter.Failure("unavailable", "browser tile \(id) has no page area to stream")
        }
        let size = webView.bounds.size
        let surface = surface(for: tile)
        let stream = SurfaceStream(id: IDs.make("str"), connection: connection, board: board.id, surface: surface,
                                   scale: min(scale, BrowserSurface.fittedScale(for: size)), format: format)
        streams[stream.id] = stream
        surface.add(stream)
        watch()
        NSLog("easl: browser %@ streams as %@ (%@, %.2f px/pt)", id, stream.id, format.rawValue, stream.scale)
        return .object(["stream": .string(stream.id), "size": SurfaceEvent.size(size), "scale": .number(stream.scale)])
    }

    private func surface(for tile: BrowserTile) -> BrowserSurface {
        let key = ObjectIdentifier(tile)
        if let surface = surfaces[key], surface.tile === tile { return surface }
        // A tile freed before the sweep noticed left its surface under the address a new tile has now.
        if let stale = surfaces[key] { stale.streams.forEach { close($0, reason: "tile closed") } }
        let surface = BrowserSurface(tile: tile, registry: registry) { [weak self] stream, reason in self?.close(stream, reason: reason) }
        surfaces[key] = surface
        return surface
    }

    private func owned(_ id: String, by connection: SocketServer.Connection) throws -> SurfaceStream {
        guard let stream = streams[id], stream.connection === connection else {
            throw ApiRouter.Failure("not_found", "stream \(id) is not open on this connection")
        }
        return stream
    }

    /// Ends `stream`; `reason` tells a viewer still connected why this Mac ended it.
    private func close(_ stream: SurfaceStream, reason: String?) {
        guard streams.removeValue(forKey: stream.id) != nil else { return }
        if let reason { stream.push("surface.notice", SurfaceEvent.notice(stream: stream.id, kind: .closed, reason: reason)) }
        let surface = stream.surface
        surface.remove(stream)
        if surface.streams.isEmpty {
            if surfaces[surface.key] === surface { surfaces[surface.key] = nil }
            surface.detach()
        }
        if streams.isEmpty { unwatch() }
        NSLog("easl: browser stream %@ ended%@", stream.id, reason.map { ": \($0)" } ?? "")
    }

    /// Closed connections and closed tiles, looked for while any stream is open: a stalled
    /// viewer sends nothing that would tell.
    private func sweep() {
        for stream in Array(streams.values) {
            if !stream.connection.isOpen {
                close(stream, reason: nil)
            } else if let reason = stream.surface.ended() {
                close(stream, reason: reason)
            }
        }
    }

    private func watch() {
        if sweeper == nil {
            let timer = Timer(timeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sweep() }
            }
            RunLoop.main.add(timer, forMode: .common)
            sweeper = timer
            NotificationCenter.default.addObserver(self, selector: #selector(menuBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        }
    }

    private func unwatch() {
        sweeper?.invalidate()
        sweeper = nil
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    /// A menu opening on this Mac just after a viewer's press is the page's (its context menu, a
    /// select in a frame the relay doesn't reach): nobody here sees it, and its tracking would
    /// hold the event queue every viewer's input waits in. It closes, and the viewers hear why.
    @objc private func menuBegan(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let pressed = surfaces.values.compactMap { surface in surface.remoteDownAt.map { (surface: surface, at: $0) } }.max { $0.at < $1.at }
        guard let pressed, now - pressed.at < Self.menuWindow else { return }
        // This Mac's user opened it: the menu bar, or a click of theirs after the viewer's.
        if let current = NSApp.currentEvent, !SurfaceEventQueue.isSynthesized(current), current.timestamp > pressed.at,
           [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown].contains(current.type) { return }
        menu.cancelTracking()
        pressed.surface.remoteDownAt = nil
        pressed.surface.refuse("menu")
    }
}

/// One browser tile's streams: one capture serves them all, the page's dialogs go to the viewer
/// driving it, and viewers' input reaches the page in order.
@MainActor
final class BrowserSurface {
    /// About 30 frames a second at most.
    static let frameInterval: TimeInterval = 1.0 / 30
    /// An unchanged page is looked at again less and less often, down to once a second.
    static let idleInterval: TimeInterval = 1
    /// Longest wait for input a viewer sent before it acknowledged the last frame to reach the page.
    static let inputSettle: TimeInterval = 0.25
    /// Longest wait for the page to present before a snapshot; past it the frame credits no new input.
    static let presentationWait: TimeInterval = 0.25
    /// Longest wait for WebKit to hand the page the mouse or key events it queued.
    static let processingWait: TimeInterval = 2
    /// Longest a copy waits for the page's selection.
    static let selectionWait: TimeInterval = 2
    /// Image pixels per frame at most: a larger page streams at a lower scale.
    static let pixelBudget = Double(SurfaceEvent.Frame.maxPixels)
    /// Encoded bytes per frame at most, well under a connection's outbox limit
    /// (`SocketServer.Connection.maxPending`) once base64 adds a third.
    static let frameBytes = 16 << 20
    nonisolated static let jpegQuality = 0.8
    private static let noRange = NSRange(location: NSNotFound, length: 0)
    /// `NSEvent.Phase` raw values → CGScrollPhase, and → CGMomentumScrollPhase.
    private static let scrollPhases: [UInt: Int64] = [1: 1, 2: 2, 4: 2, 8: 4, 16: 8, 32: 128]
    private static let momentumPhases: [UInt: Int64] = [1: 1, 2: 2, 4: 2, 8: 3, 16: 3]
    private static var reportedMissingFence = false

    let key: ObjectIdentifier
    private(set) weak var tile: BrowserTile?
    let registry: BoardRegistry
    private let end: (SurfaceStream, String) -> Void
    private(set) var streams: [SurfaceStream] = []
    private var dialogs: [String: (stream: SurfaceStream, dialog: PageDialog)] = [:]
    private var capturing = false
    private var lastCapture: TimeInterval = 0
    private var interval = BrowserSurface.frameInterval
    private var pacing: (token: Int, continuation: CheckedContinuation<Void, Never>)?
    private var pacingToken = 0
    private var download: (name: String, state: String)?
    /// When a viewer last pressed the button or a key on the page (system uptime), until this
    /// Mac's own user does (`BrowserWebView.onUserInput`).
    var remoteDownAt: TimeInterval?

    init(tile: BrowserTile, registry: BoardRegistry, end: @escaping (SurfaceStream, String) -> Void) {
        key = ObjectIdentifier(tile)
        self.tile = tile
        self.registry = registry
        self.end = end
        tile.surface = self
        if let webView = tile.webView { prepare(webView) }
    }

    /// Image pixels per point that keep a page of `size` within `pixelBudget`.
    static func fittedScale(for size: CGSize) -> Double {
        (pixelBudget / Double(size.width * size.height)).squareRoot()
    }

    func add(_ stream: SurfaceStream) {
        streams.append(stream)
    }

    /// `stream` is over: its dialogs get a dismissed dialog's answer, and the button and keys it
    /// held are released, so the page isn't left mid-drag.
    func remove(_ stream: SurfaceStream) {
        stream.closed = true
        streams.removeAll { $0 === stream }
        for (id, pending) in dialogs where pending.stream === stream {
            dialogs[id] = nil
            pending.dialog.dismiss()
        }
        guard stream.holdsInput else { return }
        Task { _ = try? await SurfaceEventQueue.run { [weak self] in self?.release(stream) ?? false } }
    }

    /// The last stream ended: the page is the tile's own again.
    func detach() {
        guard let tile, tile.surface === self else { return }
        tile.surface = nil
        guard let webView = tile.webView else { return }
        webView.allowsBackForwardNavigationGestures = true
        webView.configuration.preferences.isElementFullscreenEnabled = true
        tile.endSurfaceDrive()
        Self.setSelectRelay(false, in: webView)
    }

    /// A new document starts without the select relay.
    func pageReady() {
        if let webView = tile?.webView { prepare(webView) }
    }

    /// A swipe would track this Mac's own input stream, which a viewer's scrolls never reach, and
    /// a select's menu would open here where nobody sees it.
    private func prepare(_ webView: WKWebView) {
        webView.allowsBackForwardNavigationGestures = false
        webView.configuration.preferences.isElementFullscreenEnabled = false
        tile?.beginSurfaceDrive()
        Self.setSelectRelay(true, in: webView)
    }

    /// Why the streams should end, once the tile, its board or its window is gone.
    func ended() -> String? {
        guard let tile else { return "tile closed" }
        guard registry.boards[tile.board.id] === tile.board else { return "board closed" }
        guard tile.board.objects[tile.objectID] != nil else { return "tile closed" }
        return tile.window == nil ? "window closed" : nil
    }

    // MARK: Frames

    /// Captures while any stream may have its next frame, one capture at a time.
    func pump() {
        guard !capturing, streams.contains(where: { $0.next != nil }) else { return }
        capturing = true
        Task {
            await self.capture()
            self.capturing = false
            self.pump()
        }
    }

    /// New input: the next frame comes at full rate.
    func inputArrived() {
        interval = Self.frameInterval
        wake()
    }

    private func capture() async {
        var wait = lastCapture + interval - ProcessInfo.processInfo.systemUptime
        while wait > 0 {
            await pause(wait)
            wait = lastCapture + interval - ProcessInfo.processInfo.systemUptime
        }
        guard let tile, streams.contains(where: { $0.next != nil }) else { return }
        lastCapture = ProcessInfo.processInfo.systemUptime
        await tile.markDriven()
        var targets = streams.filter { $0.next != nil }
        for stream in targets where stream.pending { await stream.settle(within: Self.inputSettle) }
        targets.removeAll { $0.closed || $0.next == nil }
        guard let webView = tile.webView, let window = webView.window, webView.bounds.width >= 1, webView.bounds.height >= 1, !targets.isEmpty else { return idle() }
        // Copied before the presentation wait: input WebKit takes during it may miss this image.
        let fences = targets.map(\.delivered)
        let presented = await Self.presented(webView)
        let size = webView.bounds.size
        let fitted = Self.fittedScale(for: size)
        let scale = min(targets.lazy.map(\.scale).max() ?? 1, fitted)
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        configuration.snapshotWidth = NSNumber(value: Double(size.width * scale / window.backingScaleFactor))
        let started = ProcessInfo.processInfo.systemUptime
        guard tile.webView === webView, let image = try? await webView.takeSnapshot(configuration: configuration),
              let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return idle() }
        let back = webView.canGoBack, forward = webView.canGoForward, loading = webView.isLoading
        var images: [Variant: (data: Data, width: Int, height: Int)] = [:]
        for variant in Set(targets.lazy.map { Variant(scale: min($0.scale, fitted), format: $0.format) }) {
            let (width, height) = SurfaceEvent.Frame.fittedPixels(width: pixels.width, height: pixels.height, ratio: variant.scale / scale)
            let format = variant.format
            if let data = await offPool({ Self.encode(pixels, width: width, height: height, format: format) }) {
                images[variant] = (data, width, height)
            }
        }
        Metrics.shared.record("surface.capture", ms: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        var sent = false
        for (stream, fence) in zip(targets, fences) {
            let variant = Variant(scale: min(stream.scale, fitted), format: stream.format)
            guard !stream.closed, let seq = stream.next, let image = images[variant] else { continue }
            guard image.data.count <= Self.frameBytes else {
                end(stream, "frame too large")
                continue
            }
            // Without WebKit's own presentation callback nothing newer is known to be on screen.
            let input = presented ? fence : stream.fence
            let frame = SurfaceEvent.Frame(stream: stream.id, seq: seq, input: input, size: size, scale: variant.scale, format: stream.format,
                                           data: image.data, width: image.width, height: image.height, back: back, forward: forward, loading: loading)
            if stream.send(frame) { sent = true }
        }
        interval = sent ? Self.frameInterval : min(interval * 2, Self.idleInterval)
    }

    private func idle() {
        interval = min(interval * 2, Self.idleInterval)
    }

    private struct Variant: Hashable {
        let scale: Double
        let format: SurfaceFormat
    }

    private func pause(_ seconds: TimeInterval) async {
        pacingToken += 1
        let token = pacingToken
        await withCheckedContinuation { continuation in
            pacing = (token, continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                MainActor.assumeIsolated { self?.wake(token) }
            }
        }
    }

    private func wake(_ token: Int? = nil) {
        guard let pacing, token == nil || token == pacing.token else { return }
        self.pacing = nil
        pacing.continuation.resume()
    }

    /// Whether WebKit presented the page's next frame within `presentationWait`: its own
    /// callback, never the timeout or `WebStage`'s fallback delay.
    private static func presented(_ webView: WKWebView) async -> Bool {
        guard webView.responds(to: NSSelectorFromString("_doAfterNextPresentationUpdate:")) else { return false }
        return await bounded(presentationWait) { (done: @escaping @MainActor (Bool) -> Void) in
            WebStage.afterNextPresentationUpdate(webView) { done(true) }
        } ?? false
    }

    nonisolated static func encode(_ image: CGImage, width: Int, height: Int, format: SurfaceFormat) -> Data? {
        var source = image
        if image.width != width || image.height != height {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            source = scaled
        }
        let output = NSMutableData()
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: jpegQuality] : [:]
        CGImageDestinationAddImage(destination, source, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    // MARK: Input

    /// Delivers a batch in order from this app's event queue. A copy reads the page's
    /// selection where it stands in the batch; the text of the last one, nil when it couldn't be read.
    func deliver(_ events: ArraySlice<SurfaceInputEvent>, for stream: SurfaceStream) async -> String? {
        guard let tile else { return nil }
        await tile.markDriven()
        var text: String?
        var start = events.startIndex
        while start < events.endIndex {
            let last = events[start...].firstIndex(where: \.readsSelection) ?? events.endIndex - 1
            let nativeEnd = events[last].readsSelection ? last : last + 1
            let natives = events[start..<nativeEnd]
            if let lastNative = natives.last,
               await native(for: stream, mouse: natives.contains(where: \.queuedAsMouse), key: natives.contains(where: \.queuedAsKey), { surface, tile, webView in
                   for event in natives { surface.perform(event.action, by: stream, tile: tile, on: webView) }
               }) {
                stream.markDelivered(lastNative.seq)
            }
            if case .command(let command) = events[last].action, command.readsSelection {
                guard !stream.closed, !stream.mousePending, !stream.keyPending, let webView = self.tile?.webView else { return nil }
                text = await Self.selection(in: webView)
                stream.markDelivered(events[last].seq)
            }
            start = last + 1
        }
        return text
    }

    /// Runs `body` from this app's event queue against the tile's page as it is then, and waits
    /// for WebKit to confirm all mouse and key events still pending on this stream. A missing
    /// callback leaves that class pending; a later key cannot credit an unconfirmed mouse.
    private func native(for stream: SurfaceStream, mouse: Bool, key: Bool,
                        _ body: @escaping @MainActor (BrowserSurface, BrowserTile, WKWebView) -> Void) async -> Bool {
        let page = try? await SurfaceEventQueue.run { [weak self] () -> WKWebView? in
            guard let self, !stream.closed, let tile = self.tile, let webView = tile.webView else { return nil }
            body(self, tile, webView)
            return webView
        }
        guard let page else { return false }
        stream.mousePending = stream.mousePending || mouse
        stream.keyPending = stream.keyPending || key
        if stream.mousePending, await Self.processed("_doAfterProcessingAllPendingMouseEvents:", by: page) == true { stream.mousePending = false }
        if stream.keyPending, await Self.processed("_doAfterProcessingAllPendingKeyEvents:", by: page) == true { stream.keyPending = false }
        return !stream.closed && !stream.mousePending && !stream.keyPending
    }

    /// WebKit SPI (`WKWebViewPrivateForTesting`) that calls back once the page has every queued
    /// mouse or key event: true then, false past `processingWait`, nil without the SPI.
    private static func processed(_ name: String, by webView: WKWebView) async -> Bool? {
        let selector = NSSelectorFromString(name)
        guard webView.responds(to: selector) else {
            if !reportedMissingFence {
                reportedMissingFence = true
                NSLog("easl: this WebKit lacks %@; browser stream input fences cannot advance", name)
                Metrics.shared.gauge("surface.fence.unavailable", 1)
            }
            return nil
        }
        typealias Method = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        let method = unsafeBitCast(webView.method(for: selector), to: Method.self)
        return await bounded(processingWait) { (done: @escaping @MainActor (Bool) -> Void) in
            method(webView, selector) { DispatchQueue.main.async { MainActor.assumeIsolated { done(true) } } }
        } ?? false
    }

    fileprivate func perform(_ action: SurfaceAction, by stream: SurfaceStream, tile: BrowserTile, on webView: WKWebView) {
        switch action {
        case .mouse(let mouse):
            let point = Self.point(mouse.x, mouse.y, in: webView)
            let target = (mouse.phase == .up || mouse.phase == .drag)
                ? stream.mouseTarget ?? Self.responder(at: point, in: webView)
                : Self.responder(at: point, in: webView)
            switch mouse.phase {
            case .down:
                stream.heldButton = point
                stream.mouseTarget = target
                remoteDownAt = ProcessInfo.processInfo.systemUptime
            case .up:
                stream.heldButton = nil
                stream.mouseTarget = nil
            case .drag, .move:
                break
            }
            Self.mouse(mouse.phase, at: point, clicks: mouse.clicks, mods: mouse.mods, on: webView, target: target)
        case .scroll(let scroll):
            Self.scroll(scroll, on: webView)
        case .key(let key):
            if key.down {
                stream.heldKeys[key.code] = (key.chars, key.plain)
                remoteDownAt = ProcessInfo.processInfo.systemUptime
            } else {
                stream.heldKeys[key.code] = nil
            }
            Self.key(down: key.down, code: key.code, chars: key.chars, plain: key.plain, isRepeat: key.isRepeat, mods: key.mods, on: webView)
        case .text(let text):
            typing(on: webView) { $0.insertText(text, replacementRange: Self.noRange) }
        case .compose(let text, let start, let length):
            let count = (text as NSString).length, location = min(start, count)
            typing(on: webView) { $0.setMarkedText(text, selectedRange: NSRange(location: location, length: min(length, count - location)), replacementRange: Self.noRange) }
        case .unmark:
            typing(on: webView) { $0.unmarkText() }
        case .focus(true):
            webView.window?.makeFirstResponder(webView)
        case .focus(false):
            release(stream)
            if let window = webView.window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: webView) {
                window.makeFirstResponder(nil)
            }
        case .command(let command):
            switch command {
            case .copy:
                // Read where they stand in the batch (`deliver`), never through this Mac's pasteboard.
                break
            case .paste(let text):
                typing(on: webView) { $0.insertText(text, replacementRange: Self.noRange) }
            case .selectAll:
                // The web view's own Select All; past it the responder chain is the canvas's.
                let selectAll = NSSelectorFromString("selectAll:")
                if webView.responds(to: selectAll) { _ = webView.perform(selectAll, with: nil) }
            case .back:
                tile.credit.user()
                if webView.canGoBack { tile.track(webView.goBack()) }
            case .forward:
                tile.credit.user()
                if webView.canGoForward { tile.track(webView.goForward()) }
            case .reload:
                tile.credit.user()
                tile.reload()
            case .stop:
                webView.stopLoading()
            }
        case .navigate(let url):
            tile.credit.user()
            tile.load(url.absoluteString)
        }
    }

    /// Committed and marked text as an input method hands it over, outside any key event.
    private func typing(on webView: WKWebView, _ body: (NSTextInputClient) -> Void) {
        guard let client = webView as? NSTextInputClient else { return refuse("text input") }
        body(client)
    }

    /// Lets go of the button and keys `stream` holds down.
    @discardableResult
    private func release(_ stream: SurfaceStream) -> Bool {
        defer {
            stream.heldButton = nil
            stream.mouseTarget = nil
            stream.heldKeys = [:]
        }
        guard let webView = tile?.webView else { return false }
        if let point = stream.heldButton {
            Self.mouse(.up, at: point, clicks: 1, mods: 0, on: webView, target: stream.mouseTarget ?? Self.responder(at: point, in: webView))
        }
        for (code, key) in stream.heldKeys {
            Self.key(down: false, code: code, chars: key.chars, plain: key.plain, isRepeat: false, mods: 0, on: webView)
        }
        return true
    }

    /// Web view points from the viewer's top-left ones.
    private static func point(_ x: Double, _ y: Double, in webView: WKWebView) -> NSPoint {
        NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
    }

    /// The view WebKit itself takes the event in at `point`: the web view or one of its own
    /// subviews, never a window's hit test (a staged page's window is 1 pt and click-through).
    private static func responder(at point: NSPoint, in webView: WKWebView) -> NSView {
        guard let container = webView.superview, let hit = webView.hitTest(webView.convert(point, to: container)), hit.isDescendant(of: webView) else { return webView }
        return hit
    }

    private static func mouse(_ phase: SurfaceMouse.Phase, at point: NSPoint, clicks: Int, mods: UInt, on webView: WKWebView, target: NSView) {
        guard let window = webView.window else { return }
        let type: NSEvent.EventType = switch phase {
        case .down: .leftMouseDown
        case .up: .leftMouseUp
        case .drag: .leftMouseDragged
        case .move: .mouseMoved
        }
        guard let event = NSEvent.mouseEvent(with: type, location: webView.convert(point, to: nil), modifierFlags: NSEvent.ModifierFlags(rawValue: mods),
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: phase == .move ? 0 : clicks, pressure: phase == .down || phase == .drag ? 1 : 0) else { return }
        SurfaceEventQueue.adopt(event)
        switch phase {
        case .down: target.mouseDown(with: event)
        case .up: target.mouseUp(with: event)
        case .drag: target.mouseDragged(with: event)
        case .move: target.mouseMoved(with: event)
        }
    }

    private static func key(down: Bool, code: UInt16, chars: String, plain: String, isRepeat: Bool, mods: UInt, on webView: WKWebView) {
        guard let window = webView.window,
              let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: mods),
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                           characters: chars, charactersIgnoringModifiers: plain, isARepeat: isRepeat, keyCode: code) else { return }
        SurfaceEventQueue.adopt(event)
        if down { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
    }

    private static func scroll(_ scroll: SurfaceScroll, on webView: WKWebView) {
        func wheel(_ delta: Double) -> Int32 { Int32(max(-100_000, min(100_000, delta)).rounded()) }
        guard webView.window != nil,
              let cg = CGEvent(scrollWheelEvent2Source: nil, units: scroll.precise ? .pixel : .line, wheelCount: 2,
                               wheel1: wheel(scroll.dy), wheel2: wheel(scroll.dx), wheel3: 0) else { return }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: scroll.precise ? 1 : 0)
        if let phase = scrollPhases[scroll.phase], let field = CGEventField(rawValue: 99) { cg.setIntegerValueField(field, value: phase) }
        if let phase = momentumPhases[scroll.momentum], let field = CGEventField(rawValue: 123) { cg.setIntegerValueField(field, value: phase) }
        cg.flags = CGEventFlags(rawValue: UInt64(scroll.mods))
        // The event has no window, and WebKit reads its location as its view's window's
        // coordinates: the window-local point goes where that reading gives it back unchanged.
        let local = Self.point(scroll.x, scroll.y, in: webView)
        let inWindow = webView.convert(local, to: nil)
        cg.location = CGPoint(x: inWindow.x, y: (NSScreen.screens.first?.frame.height ?? 0) - inWindow.y)
        guard let event = NSEvent(cgEvent: cg) else { return }
        SurfaceEventQueue.adopt(event)
        responder(at: local, in: webView).scrollWheel(with: event)
    }

    /// The page's selected text, read in the helper's world (`selectedText`): never through this
    /// Mac's pasteboard, which Universal Clipboard may carry to other devices.
    private static func selection(in webView: WKWebView) async -> String? {
        let read = await bounded(selectionWait) { (done: @escaping @MainActor (String?) -> Void) in
            Task { @MainActor in
                let value = try? await webView.callAsyncJavaScript(BrowserScripts.ensure + "return window.__canvasCmux.selectedText()", arguments: [:],
                                                                   in: nil, contentWorld: BrowserScripts.world)
                done(value as? String)
            }
        }
        return read ?? nil
    }

    private static func setSelectRelay(_ on: Bool, in webView: WKWebView) {
        Task {
            _ = try? await webView.callAsyncJavaScript(BrowserScripts.ensure + "return window.__canvasCmux.setSelectRelay(on)", arguments: ["on": on],
                                                       in: nil, contentWorld: BrowserScripts.world)
        }
    }

    // MARK: Dialogs and notices

    /// What the page asked, held until its viewer answers (`surface.answer`) or its stream ends.
    enum PageDialog {
        case alert(@MainActor @Sendable () -> Void)
        case confirm(@MainActor @Sendable (Bool) -> Void)
        case prompt(defaultText: String?, @MainActor @Sendable (String?) -> Void)
        case login(@MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
        /// The select the page helper relayed (`chooseSelect`), with its choice count.
        case select(token: Int, choices: Int)

        var kind: SurfaceEvent.DialogKind {
            switch self {
            case .alert: .alert
            case .confirm: .confirm
            case .prompt: .prompt
            case .login: .login
            case .select: .select
            }
        }

        /// The answer a dismissed dialog gives.
        @MainActor func dismiss() {
            switch self {
            case .alert(let done): done()
            case .confirm(let done): done(false)
            case .prompt(_, let done): done(nil)
            case .login(let done): done(.cancelAuthenticationChallenge, nil)
            case .select: break
            }
        }
    }

    /// Hands the dialog to the latest driving viewer. With no listener, dismiss it here rather
    /// than asking this Mac's user to answer a request from a remote page.
    func relay(_ dialog: PageDialog, origin: String, message: String? = nil, text: String? = nil, choices: [String]? = nil, selected: Int? = nil) {
        let listening = streams.filter { !$0.closed && $0.connection.isOpen && $0.hears("surface.dialog") }
        guard let stream = listening.reversed().max(by: { $0.lastInput < $1.lastInput }) else {
            dialog.dismiss()
            refuse(dialog.kind.rawValue)
            return
        }
        let id = IDs.make("dlg")
        dialogs[id] = (stream, dialog)
        stream.push("surface.dialog", SurfaceEvent.dialog(stream: stream.id, dialog: id, kind: dialog.kind, origin: origin, message: message,
                                                          text: text, choices: choices, selected: selected))
    }

    func answer(_ id: String, _ answer: SurfaceAnswer, from stream: SurfaceStream) async throws {
        guard let pending = dialogs[id], pending.stream === stream else {
            throw ApiRouter.Failure("not_found", "dialog \(id) is not open on stream \(stream.id)")
        }
        try Self.check(answer, for: pending.dialog)
        dialogs[id] = nil
        switch pending.dialog {
        case .alert(let done):
            done()
        case .confirm(let done):
            done(answer.accept)
        case .prompt(let defaultText, let done):
            done(answer.accept ? (answer.text ?? defaultText ?? "") : nil)
        case .login(let done):
            guard answer.accept else { return done(.cancelAuthenticationChallenge, nil) }
            done(.useCredential, URLCredential(user: answer.user ?? "", password: answer.password ?? "", persistence: .forSession))
        case .select(let token, _):
            guard answer.accept, let choice = answer.choice else { return }
            guard let webView = tile?.webView, await Self.choose(token, choice, in: webView) else {
                throw ApiRouter.Failure("invalid_params", "choice \(choice) can't be chosen: it is disabled, or the select changed or went away")
            }
        }
    }

    private static func check(_ answer: SurfaceAnswer, for dialog: PageDialog) throws {
        let kind = dialog.kind
        if answer.text != nil, kind != .prompt { throw ApiRouter.Failure("invalid_params", "text answers a prompt only") }
        if answer.user != nil || answer.password != nil, kind != .login { throw ApiRouter.Failure("invalid_params", "user and password answer a login only") }
        if answer.choice != nil, kind != .select { throw ApiRouter.Failure("invalid_params", "choice answers a select only") }
        if case .select(_, let count) = dialog, answer.accept, (answer.choice ?? count) >= count {
            throw ApiRouter.Failure("invalid_params", "accepting this select takes a choice below \(count)")
        }
    }

    private static func choose(_ token: Int, _ index: Int, in webView: WKWebView) async -> Bool {
        await bounded(selectionWait) { (done: @escaping @MainActor (Bool) -> Void) in
            Task { @MainActor in
                let chosen = try? await webView.callAsyncJavaScript(BrowserScripts.ensure + "return window.__canvasCmux.chooseSelect(token, index)",
                                                                    arguments: ["token": token, "index": index], in: nil, contentWorld: BrowserScripts.world)
                done((chosen as? Bool) == true)
            }
        } ?? false
    }

    /// The page helper kept a select's menu from opening here (`relaySelect`).
    func selectRequested(_ body: Any, origin: String) {
        guard let message = body as? [String: Any], let token = (message["token"] as? NSNumber)?.intValue,
              let choices = message["choices"] as? [String], !choices.isEmpty else { return }
        let selected = (message["selected"] as? NSNumber)?.intValue
        relay(.select(token: token, choices: choices.count), origin: origin, choices: choices, selected: selected.flatMap { (0..<choices.count).contains($0) ? $0 : nil })
    }

    /// Something the page asked that this Mac won't do for a viewer (a file to upload, a
    /// certificate, the camera, a menu): refused, and the viewers told.
    func refuse(_ reason: String) {
        NSLog("easl: browser %@ refused %@ while streamed", tile?.objectID ?? "?", reason)
        notify(.refused, reason: reason)
    }

    /// The page's download as it starts, finishes or fails; the file stays on this Mac.
    func downloadChanged(_ status: BrowserDownloads.Status) {
        var state = "running", reason = "saved on the host Mac"
        switch status.state {
        case .running: break
        case .finished: state = "finished"
        case .failed(let why): (state, reason) = ("failed", why)
        }
        guard download?.name != status.name || download?.state != state else { return }
        download = (status.name, state)
        notify(.download, reason: reason, name: status.name, state: state)
    }

    private func notify(_ kind: SurfaceEvent.NoticeKind, reason: String? = nil, name: String? = nil, state: String? = nil) {
        for stream in streams {
            stream.push("surface.notice", SurfaceEvent.notice(stream: stream.id, kind: kind, reason: reason, name: name, state: state))
        }
    }

    /// `start`'s answer, or nil once `limit` passes first.
    static func bounded<T: Sendable>(_ limit: TimeInterval, _ start: (@escaping @MainActor (T) -> Void) -> Void) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let finish: @MainActor (T?) -> Void = { value in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: value)
            }
            start { finish($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { MainActor.assumeIsolated { finish(nil) } }
        }
    }
}

@MainActor
private final class Once {
    var done = false
}

/// One viewer's stream of a browser tile, owned by the connection that opened it.
@MainActor
final class SurfaceStream {
    enum Credit {
        /// Frame `seq` was sent (0: the stream just opened) and isn't acknowledged yet.
        case outstanding(Int)
        /// The viewer acknowledged the last frame: frame `next` may go.
        case granted(next: Int)
    }

    /// Input batches a stream may have waiting before more is refused.
    static let maxQueued = 32

    let id: String
    let connection: SocketServer.Connection
    let board: BoardID
    let surface: BrowserSurface
    let scale: Double
    let format: SurfaceFormat
    private(set) var credit = Credit.outstanding(0)
    /// The highest seq accepted into the queue.
    private(set) var accepted = 0
    /// The highest seq WebKit handed the page (`BrowserSurface.native`).
    private(set) var delivered = 0
    var mousePending = false
    var keyPending = false
    /// The last frame's delivered input and full page state.
    private(set) var fence = 0
    private var lastSent: SurfaceEvent.Frame?
    /// When it last accepted input (system uptime): the page's dialogs go to the latest.
    private(set) var lastInput: TimeInterval = 0
    var closed = false
    /// Where the viewer's button is down, in web view points, and the keys it holds.
    var heldButton: NSPoint?
    weak var mouseTarget: NSView?
    var heldKeys: [UInt16: (chars: String, plain: String)] = [:]
    private var pipeline: Task<Void, Never>?
    private var queued = 0

    init(id: String, connection: SocketServer.Connection, board: BoardID, surface: BrowserSurface, scale: Double, format: SurfaceFormat) {
        self.id = id
        self.connection = connection
        self.board = board
        self.surface = surface
        self.scale = scale
        self.format = format
    }

    /// The seq the next frame takes, while one may go.
    var next: Int? {
        if case .granted(let next) = credit { return next }
        return nil
    }

    var holdsInput: Bool { heldButton != nil || !heldKeys.isEmpty }

    func markDelivered(_ seq: Int) {
        guard !mousePending, !keyPending else { return }
        delivered = max(delivered, seq)
    }

    /// Input accepted that hasn't reached the page yet.
    var pending: Bool { queued > 0 }

    /// The outstanding frame acknowledged grants exactly one more; an older ack changes nothing.
    func ack(_ frame: Int) throws {
        switch credit {
        case .outstanding(let sent):
            guard frame <= sent else { throw ApiRouter.Failure("invalid_params", "frame \(frame) wasn't sent; the latest is \(sent)") }
            guard frame == sent else { return }
            credit = .granted(next: sent + 1)
            surface.pump()
        case .granted(let next):
            guard frame < next else { throw ApiRouter.Failure("invalid_params", "frame \(frame) wasn't sent; the latest is \(next - 1)") }
        }
    }

    /// Queues the batch's new events (seq past `accepted`; the rest were accepted before) and
    /// answers once they are queued, not delivered: frames report delivery (`fence`). A copy
    /// waits up to `BrowserSurface.selectionWait` for the selected text.
    func input(_ events: [SurfaceInputEvent]) async throws -> JSONValue {
        let fresh = events.drop(while: { $0.seq <= accepted })
        guard let last = fresh.last else { return .object(["accepted": .number(0)]) }
        guard surface.tile != nil else { throw ApiRouter.Failure("unavailable", "the streamed tile closed") }
        guard queued < Self.maxQueued else {
            throw ApiRouter.Failure("unavailable", "this Mac hasn't delivered the stream's last \(queued) batches yet (a menu or drag here holds its event queue); nothing in this batch was accepted")
        }
        accepted = last.seq
        lastInput = ProcessInfo.processInfo.systemUptime
        let batch = enqueue(fresh)
        surface.inputArrived()
        var result: [String: JSONValue] = ["accepted": .number(Double(fresh.count))]
        if fresh.contains(where: \.readsSelection) {
            let read = await BrowserSurface.bounded(BrowserSurface.selectionWait) { (done: @escaping @MainActor (String?) -> Void) in
                Task { done(await batch.value) }
            }
            guard let read, let text = read else {
                throw ApiRouter.Failure("unavailable", "the page's selection couldn't be read within \(Int(BrowserSurface.selectionWait)) s; the batch's input was accepted")
            }
            result["text"] = .string(text)
        }
        return .object(result)
    }

    /// Batches reach the page one after another, each once the one before is through.
    private func enqueue(_ events: ArraySlice<SurfaceInputEvent>) -> Task<String?, Never> {
        let previous = pipeline
        queued += 1
        let batch = Task { () -> String? in
            await previous?.value
            defer { self.queued -= 1 }
            guard !self.closed else { return nil }
            return await self.surface.deliver(events, for: self)
        }
        pipeline = Task { _ = await batch.value }
        return batch
    }

    /// Until the accepted input has reached the page, or `limit` passes.
    func settle(within limit: TimeInterval) async {
        guard let pipeline else { return }
        _ = await BrowserSurface.bounded(limit) { (done: @escaping @MainActor (Bool) -> Void) in
            Task {
                await pipeline.value
                done(true)
            }
        }
    }

    func send(_ frame: SurfaceEvent.Frame) -> Bool {
        if let last = lastSent,
           frame.input == last.input, frame.size == last.size, frame.scale == last.scale,
           frame.width == last.width, frame.height == last.height, frame.format == last.format,
           frame.back == last.back, frame.forward == last.forward, frame.loading == last.loading,
           frame.data == last.data { return false }
        credit = .outstanding(frame.seq)
        fence = frame.input
        lastSent = frame
        Metrics.shared.record("surface.frame", bytes: frame.data.count)
        let connection = connection, board = board
        // Base64 and JSON of a whole page image take milliseconds: off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let line = try? JSONEncoder().encode(SurfaceEvent.envelope("surface.frame", board: board, frame.json)) else { return }
            if connection.send(encoded: line) {
                Metrics.shared.record("surface.frameWire", bytes: line.count + 1)
            }
        }
        return true
    }

    /// Whether the connection subscribed to `event` on the stream's board.
    func hears(_ event: String) -> Bool {
        surface.registry.subscribes(connection, to: event, on: board)
    }

    /// A dialog or notice, to this stream's own connection only, once it subscribed to it.
    func push(_ event: String, _ data: JSONValue) {
        guard !closed, hears(event) else { return }
        connection.send(SurfaceEvent.envelope(event, board: board, data))
    }
}

/// Streamed input's place in this app's own event queue. A batch waits behind the events already
/// queued (a real click, a key) and runs when AppKit dispatches its marker
/// (`CanvasApplication.sendEvent`), never through a window's hit test or the system's event
/// stream. The events it synthesizes are remembered weakly: WebKit hands a key its page didn't
/// handle back to the app, and that key must reach nothing on this Mac.
@MainActor
enum SurfaceEventQueue {
    private static let subtype: Int16 = 0x5346
    private static let marker = 0x5355_5246
    private static var pending: [Int: () -> Void] = [:]
    private static var next = 0
    private static let synthesized = NSHashTable<NSEvent>(options: [.weakMemory, .objectPointerPersonality])

    /// Runs `body` once the app's event queue reaches the point this call put it at.
    static func run<T: Sendable>(_ body: @escaping @MainActor () -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            next &+= 1
            let ticket = next
            guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: 0, context: nil, subtype: subtype, data1: marker, data2: ticket) else {
                continuation.resume(throwing: ApiRouter.Failure("unavailable", "cannot queue native browser input"))
                return
            }
            pending[ticket] = { continuation.resume(returning: body()) }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Whether `event` is the queue's: its marker (what waits runs now) or an event it
    /// synthesized, which WebKit hands back when the page didn't handle it.
    static func consumes(_ event: NSEvent) -> Bool {
        if event.type == .applicationDefined, event.subtype.rawValue == subtype, event.data1 == marker {
            pending.removeValue(forKey: event.data2)?()
            return true
        }
        return synthesized.contains(event)
    }

    static func adopt(_ event: NSEvent) {
        synthesized.add(event)
    }

    static func isSynthesized(_ event: NSEvent) -> Bool {
        synthesized.contains(event)
    }
}
