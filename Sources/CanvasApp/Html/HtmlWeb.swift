import AppKit
import CanvasCore
import CryptoKit
import WebKit

/// Compiled local allowlists and the fixed remote connection-hint guard, shared by HTML tiles.
@MainActor
enum HtmlRuleLists {
    private static var compiled: [String: WKContentRuleList] = [:]

    static func list(allowing hosts: [String]) async throws -> WKContentRuleList {
        try await compile(HtmlKit.networkRules(allow: hosts))
    }

    static func remote() async throws -> WKContentRuleList {
        try await compile(HtmlKit.remoteNetworkRules)
    }

    private static func compile(_ json: String) async throws -> WKContentRuleList {
        let identifier = "canvas-html-" + SHA256.hash(data: Data(json.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        if let list = compiled[identifier] { return list }
        guard let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else {
            throw HtmlError.malformed("content rule list \(identifier) did not compile")
        }
        compiled[identifier] = list
        return list
    }
}

@MainActor
final class HtmlSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var tile: HtmlTile? {
        didSet {
            if oldValue !== tile {
                for read in reads.values { read.cancel() }
                reads.removeAll()
                mediaBlocks.removeAll()
                hostURLs = HostURLMap(allow: [])
            }
        }
    }
    private static let kitRoot = AppPaths.asset("kit")
    private let priority: HostReadPriority
    private static var kitCache: [String: Data] = [:]
    private static let textLimit = 4 * 1024 * 1024
    private var reads: [ObjectIdentifier: Task<Void, Never>] = [:]
    private struct MediaBlock {
        var path: String
        var request: HostFileRequest
        var file: HostFile
    }
    private var mediaBlocks: [MediaBlock] = []
    var hostNetworkEnabled = true
    private var hostURLs = HostURLMap(allow: [])
    private var httpActive = 0
    private var httpWaiters: [CheckedContinuation<Void, Never>] = []

    @MainActor
    private final class HTTPTransfer {
        let task: any WKURLSchemeTask
        let url: URL
        let method: String
        var response: HostHTTPHead?
        var text = Data()
        var rewrite = false

        init(task: any WKURLSchemeTask, url: URL, method: String) {
            self.task = task
            self.url = url
            self.method = method
        }
    }

    func networkURL(_ original: URL, from host: String) -> URL? {
        guard hostNetworkEnabled, tile?.isRemote == true,
              host == HtmlKit.host || hostURLs.contains(host: host) else { return nil }
        return hostURLs.proxyURL(for: original)
    }

    private func rememberMedia(_ file: HostFile, request: HostFileRequest, path: String) {
        mediaBlocks.removeAll { $0.path == path && $0.file.offset == file.offset }
        if mediaBlocks.count == 4 { mediaBlocks.removeFirst() }
        var metadata = request
        metadata.bytes = false
        metadata.range = nil
        mediaBlocks.append(MediaBlock(path: path, request: metadata, file: file))
    }

    init(tile: HtmlTile?, priority: HostReadPriority = .visible) {
        self.tile = tile
        self.priority = priority
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let tile, !tile.hostBoardClosed else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        guard !tile.isRemote || tile.files != nil else {
            return task.didFailWithError(URLError(.cannotConnectToHost))
        }
        if url.host != HtmlKit.host {
            guard hostNetworkEnabled, let original = hostURLs.originalURL(for: url), let files = tile.files?.prioritized(priority) else {
                return task.didFailWithError(URLError(.noPermissionsToReadFile))
            }
            return serveHTTP(task, url: url, original: original, files: files, allow: tile.allowNetwork)
        }
        if url.path == HtmlKit.pageURL(tile: tile.objectID).path {
            for read in reads.values { read.cancel() }
            reads.removeAll()
            mediaBlocks.removeAll()
            if webView === tile.webView { tile.resetAssetWatches() }
            hostURLs = HostURLMap(allow: tile.allowNetwork)
            let html = tile.isRemote && hostNetworkEnabled && !tile.allowNetwork.isEmpty
                ? HtmlHostRuntime.script + hostURLs.rewriteHTML(in: tile.html) : tile.html
            let document = HtmlKit.document(html: html, policy: tile.contentSecurityPolicy)
            respond(task, url: url, data: Data(document.utf8), type: "text/html", cache: "no-store")
            return
        }
        if let kitRoot = Self.kitRoot, let file = HtmlKit.kitFile(requestPath: url.path, kitRoot: kitRoot),
           let data = Self.kitCache[file.path] ?? (try? Data(contentsOf: file, options: .alwaysMapped)) {
            Self.kitCache[file.path] = data
            respond(task, url: url, data: data, type: HtmlKit.mimeType(file), cache: "max-age=31536000, immutable")
            return
        }
        let method = task.request.httpMethod ?? "GET"
        guard method == "GET" || method == "HEAD" else {
            return respond(task, url: url, data: Data(), type: "text/plain", cache: "no-store", status: 405)
        }
        let key = ObjectIdentifier(task)
        let files = tile.files?.prioritized(priority)
        let source = tile.isRemote ? tile.hostImageSource : .directory(tile.boardRoot.path)
        let assetPath = url.path.hasPrefix(tile.boardRoot.path + "/") ? url.path : String(url.path.drop(while: { $0 == "/" }))
        let assetKey = url.path
        var request = HostFileRequest(source: source, policy: .boardAsset(assetPath), bytes: false)
        let live = webView === tile.webView
        reads[key] = Task { @MainActor [weak self, weak tile] in
            guard let self, let tile else { return }
            var began = false
            var assetFailure: HostFileError?
            var observed = false
            do {
                let metadata: HostFile
                if let cached = self.mediaBlocks.first(where: { $0.path == assetKey }) {
                    var file = cached.file
                    file.data = Data()
                    file.offset = 0
                    metadata = file
                    request = cached.request
                } else {
                    do {
                        let asset = try await Self.readBoardAsset(request, absolutePath: url.path, files: files)
                        metadata = asset.file
                        request = asset.request
                    } catch {
                        assetFailure = error as? HostFileError ?? .unavailable(String(describing: error))
                        switch error {
                        case HostFileError.refused, HostFileError.notFound: break
                        default: throw error
                        }
                        guard let fallback = LocalImage.hostPageFile(requestPath: url.path, source: source,
                                                                   temps: files?.temps ?? FollowFilter.tempDirectories) else { throw error }
                        var imageRequest = fallback
                        imageRequest.bytes = false
                        metadata = try await Self.read(imageRequest, files: files)
                        request = imageRequest
                    }
                }
                guard self.reads[key] != nil, !Task.isCancelled else { return }
                observed = true
                if live { tile.observeAsset(assetKey, request: request, baseline: .version(metadata.version)) }
                let selection: MediaByteRange
                do {
                    selection = try MediaByteRange(header: task.request.value(forHTTPHeaderField: "Range"), size: metadata.size)
                } catch {
                    self.head(task, url: url, type: metadata.mimeType, status: 416,
                              headers: ["Content-Range": "bytes */\(metadata.size)", "Content-Length": "0", "Accept-Ranges": "bytes"])
                    task.didFinish()
                    self.reads.removeValue(forKey: key)
                    return
                }
                let rewrite = tile.isRemote && self.hostNetworkEnabled && !tile.allowNetwork.isEmpty &&
                    method != "HEAD" && !selection.partial && ["text/html", "text/css"].contains(metadata.mimeType)
                guard !rewrite || metadata.size <= Int64(Self.textLimit) else { throw URLError(.dataLengthExceedsMaximum) }
                var text = Data()
                if rewrite {
                    text.reserveCapacity(Int(metadata.size))
                } else {
                    self.head(task, url: url, type: metadata.mimeType, status: selection.partial ? 206 : 200,
                              headers: selection.headers(size: metadata.size))
                    began = true
                }
                let media = metadata.mimeType.hasPrefix("video/") || metadata.mimeType.hasPrefix("audio/")
                let rangeFiles = media && self.priority == .visible ? files?.prioritized(.interactive) : files
                if method != "HEAD" {
                    var offset = selection.bytes.lowerBound
                    request.bytes = true
                    while offset < selection.bytes.upperBound {
                        try Task.checkCancellation()
                        let chunk: HostFile
                        if media, let cached = self.mediaBlocks.first(where: {
                            $0.path == assetKey && $0.file.version == metadata.version &&
                                offset >= $0.file.offset && offset < $0.file.offset + Int64($0.file.data.count)
                        }) {
                            chunk = cached.file
                        } else {
                            let start = media ? offset - offset % Int64(HostFileRange.maxLength) : offset
                            let length = Int(min(Int64(HostFileRange.maxLength), (media ? metadata.size : selection.bytes.upperBound) - start))
                            request.range = HostFileRange(offset: start, length: length)
                            chunk = try await Self.read(request, files: rangeFiles)
                            guard self.reads[key] != nil, !Task.isCancelled else { return }
                            guard chunk.version == metadata.version, chunk.size == metadata.size,
                                  chunk.offset == start, chunk.data.count == length else { throw URLError(.resourceUnavailable) }
                            if media { self.rememberMedia(chunk, request: request, path: assetKey) }
                        }
                        let start = Int(offset - chunk.offset)
                        let count = Int(min(selection.bytes.upperBound - offset, Int64(chunk.data.count - start)))
                        guard count > 0 else { throw URLError(.resourceUnavailable) }
                        if rewrite { text.append(chunk.data[start..<(start + count)]) }
                        else { task.didReceive(chunk.data[start..<(start + count)]) }
                        offset += Int64(count)
                    }
                }
                if rewrite {
                    let transformed = try self.transformedText(text, type: metadata.mimeType, base: url)
                    self.head(task, url: url, type: metadata.mimeType, status: 200,
                              headers: ["Content-Length": String(transformed.count)])
                    began = true
                    if !transformed.isEmpty { task.didReceive(transformed) }
                }
                guard self.reads.removeValue(forKey: key) != nil, !Task.isCancelled else { return }
                tile.hostImageFinished(url, error: nil, in: webView)
                task.didFinish()
            } catch {
                guard self.reads.removeValue(forKey: key) != nil, !Task.isCancelled else { return }
                tile.hostImageFinished(url, error: error, in: webView)
                if live, !observed {
                    tile.observeAsset(assetKey, request: request,
                                      baseline: .failure(assetFailure ?? (error as? HostFileError) ?? .unavailable(String(describing: error))))
                }
                if began {
                    task.didFailWithError(error)
                } else {
                    let failure = error as? HostFileError ?? .unavailable(String(describing: error))
                    if case .unavailable = failure {
                        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                                                     userInfo: [NSLocalizedDescriptionKey: HostGit.refusal(failure)]))
                    } else {
                        self.respond(task, url: url, data: Data("not found".utf8), type: "text/plain", cache: "no-store", status: 404)
                    }
                }
            }
        }
    }

    private static func read(_ request: HostFileRequest, files: HostFiles?) async throws -> HostFile {
        if let files { return try await files.read(request) }
        return try await HostFiles.readLocal(request)
    }

    private static func readBoardAsset(_ request: HostFileRequest, absolutePath: String, files: HostFiles?) async throws -> (request: HostFileRequest, file: HostFile) {
        do {
            return (request, try await read(request, files: files))
        } catch let primaryFailure {
            switch primaryFailure {
            case HostFileError.refused, HostFileError.notFound:
                guard request.policy != .boardAsset(absolutePath) else { throw primaryFailure }
                var absolute = request
                absolute.policy = .boardAsset(absolutePath)
                do { return (absolute, try await read(absolute, files: files)) }
                catch { throw primaryFailure }
            default:
                throw primaryFailure
            }
        }
    }

    private func acquireHTTP() async {
        if httpActive < 2 { httpActive += 1; return }
        await withCheckedContinuation { httpWaiters.append($0) }
    }

    private func releaseHTTP() {
        if httpWaiters.isEmpty { httpActive -= 1 }
        else { httpWaiters.removeFirst().resume() }
    }

    private func serveHTTP(_ task: any WKURLSchemeTask, url: URL, original: URL, files: HostFiles, allow: [String]) {
        let method = task.request.httpMethod ?? "GET"
        guard method == "GET" || method == "HEAD" else {
            return respond(task, url: url, data: Data(), type: "text/plain", cache: "no-store", status: 405)
        }
        let key = ObjectIdentifier(task)
        let transfer = HTTPTransfer(task: task, url: url, method: method)
        let request = HostHTTPRequest(url: original, method: method, range: task.request.value(forHTTPHeaderField: "Range"))
        reads[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.acquireHTTP()
            defer { self.releaseHTTP() }
            guard self.reads[key] != nil, !Task.isCancelled else { return }
            do {
                try await files.http(request, allow: allow) { [weak self] event in
                    guard let self else { throw CancellationError() }
                    try await self.receiveHTTP(event, transfer: transfer, key: key)
                }
                guard self.reads[key] != nil, !Task.isCancelled else { return }
                guard let response = transfer.response else { throw URLError(.badServerResponse) }
                if transfer.rewrite {
                    let type = response.headers.first { $0.key.lowercased() == "content-type" }?.value ?? "text/plain"
                    guard let base = self.hostURLs.proxyURL(for: response.url) else { throw URLError(.noPermissionsToReadFile) }
                    let data = try self.transformedText(transfer.text, type: type, base: base)
                    var headers = response.headers.filter {
                        !["content-length", "content-type", "access-control-allow-origin", "etag", "content-md5", "digest", "content-digest"].contains($0.key.lowercased())
                    }
                    headers["Content-Length"] = String(data.count)
                    headers["Access-Control-Allow-Origin"] = "*"
                    self.head(task, url: url, type: type, status: response.status, headers: headers)
                    if !data.isEmpty { task.didReceive(data) }
                }
                guard self.reads.removeValue(forKey: key) != nil, !Task.isCancelled else { return }
                task.didFinish()
            } catch {
                guard self.reads.removeValue(forKey: key) != nil, !Task.isCancelled else { return }
                task.didFailWithError(error)
            }
        }
    }

    private func receiveHTTP(_ event: HostHTTPEvent, transfer: HTTPTransfer, key: ObjectIdentifier) throws {
        guard reads[key] != nil, !Task.isCancelled else { throw CancellationError() }
        switch event {
        case .response(let response):
            transfer.response = response
            let type = response.headers.first { $0.key.lowercased() == "content-type" }?.value ?? "application/octet-stream"
            let mime = type.lowercased().split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            transfer.rewrite = transfer.method != "HEAD" && response.status >= 200 &&
                ![204, 205, 206, 304].contains(response.status) && ["text/html", "text/css"].contains(mime)
            if !transfer.rewrite {
                var headers = response.headers.filter { $0.key.lowercased() != "access-control-allow-origin" }
                headers["Access-Control-Allow-Origin"] = "*"
                head(transfer.task, url: transfer.url, type: type, status: response.status, headers: headers)
            }
        case .bytes(let data):
            guard transfer.response != nil else { throw URLError(.badServerResponse) }
            if transfer.rewrite {
                guard transfer.text.count + data.count <= Self.textLimit else { throw URLError(.dataLengthExceedsMaximum) }
                transfer.text.append(data)
            } else if !data.isEmpty {
                transfer.task.didReceive(data)
            }
        }
    }

    private func transformedText(_ data: Data, type: String, base: URL) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        if type.lowercased().hasPrefix("text/html") {
            return Data(HtmlHostRuntime.document(hostURLs.rewriteHTML(in: text), base: base).utf8)
        }
        return Data(hostURLs.rewriteCSS(in: text).utf8)
    }

    func cancelHostReads() {
        for task in reads.values { task.cancel() }
        reads.removeAll()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        reads.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    private func head(_ task: any WKURLSchemeTask, url: URL, type: String, status: Int, headers: [String: String]) {
        let upstreamPolicy = headers.first { $0.key.lowercased() == "content-security-policy" }?.value
        var headers = headers.filter { !["content-type", "cache-control", "content-security-policy"].contains($0.key.lowercased()) }
        headers["Content-Type"] = type
        headers["Cache-Control"] = "no-store"
        if let policy = tile?.contentSecurityPolicy {
            headers["Content-Security-Policy"] = [upstreamPolicy, policy].compactMap { $0 }.joined(separator: ", ")
        }
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, type: String, cache: String, status: Int = 200) {
        guard let tile, !tile.hostBoardClosed else { return task.didFailWithError(URLError(.cancelled)) }
        var headers = ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": cache]
        if let policy = tile.contentSecurityPolicy { headers["Content-Security-Policy"] = policy }
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        if !data.isEmpty { task.didReceive(data) }
        task.didFinish()
    }
}

@MainActor
final class HtmlChannelHandler: NSObject, WKScriptMessageHandlerWithReply {
    /// As `HtmlSchemeHandler.tile`.
    weak var tile: HtmlTile?
    private let priority: HostReadPriority

    init(tile: HtmlTile?, priority: HostReadPriority = .visible) {
        self.tile = tile
        self.priority = priority
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let origin = message.frameInfo.securityOrigin
        guard let tile, origin.protocol == HtmlKit.scheme, origin.host.isEmpty || origin.host == HtmlKit.host,
              let source = message.webView, source === tile.webView || source === tile.renderWebView else { return (nil, "not allowed") }
        guard let body = message.body as? [String: Any] else { return (nil, HtmlError.malformed("message must be an object").description) }
        if body["type"] as? String == "network.url" {
            guard body.count == 2, let value = body["url"] as? String, value.utf8.count <= 8192,
                  let original = URL(string: value),
                  let handler = source.configuration.urlSchemeHandler(forURLScheme: HtmlKit.scheme) as? HtmlSchemeHandler,
                  let proxy = handler.networkURL(original, from: origin.host) else { return (nil, "not allowed") }
            return (["url": proxy.absoluteString], nil)
        }
        // Consume before any await. The work queue can sit behind other page work, and a second
        // send must not see the same arm.
        var mayStartTurn = false
        if body["type"] as? String == "send" {
            switch tile.beginPageSend(from: source, frame: message.frameInfo, at: ProcessInfo.processInfo.systemUptime) {
            case .failure(let reason):
                return (nil, reason)
            case .success(let authorized):
                mayStartTurn = authorized
            }
        } else {
            guard message.frameInfo.isMainFrame else { return (nil, "not allowed") }
        }
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return (nil, HtmlError.malformed("message must be an object").description) }
        do {
            let parsed = try HtmlMessage.parse(data)
            let reply = try await tile.handle(parsed, rendering: source === tile.renderWebView, priority: priority, mayStartTurn: mayStartTurn)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply), options: .fragmentsAllowed)
            return (object, nil)
        } catch let error as HtmlError {
            return (nil, error.description)
        } catch let error as BoardError {
            return (nil, "\(error)")
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}

/// An HTML tile's page takes the keyboard only when the user asks for it: Return on the tile
/// (`HtmlTile.enterKeyboard`) or a click in one of its text fields. Until then the page can't
/// take it, so an explainer never pulls the keyboard from the prompt target terminal the user is
/// typing in.
final class HtmlWebView: WKWebView {
    static let nativeMouseDown = Notification.Name("HtmlWebView.nativeMouseDown")
    private static let clickWorld = WKContentWorld.world(name: "canvas-html-keyboard")
    private static let clickGrantLifetime: TimeInterval = 0.3
    /// One monitor for every HTML web view. `mouseDown` on this class misses WebKit's descendant
    /// views, so a click in the page would never arm a permit.
    private static var sendMonitor: Any?

    /// The live tile's page. An offscreen render leaves this false and cannot arm a permit.
    var acceptsSendGestures = false
    private var sendPermit = HtmlGesturePermit(url: "")

    private enum KeyboardAuthorization {
        case denied
        case pending(KeyboardClick)
        case granted
    }

    @MainActor
    private final class KeyboardClick: NSObject {
        weak var window: NSWindow?
        weak var responder: NSResponder?
        let time: TimeInterval
        let wasKey: Bool
        let appWasActive: Bool
        private let invalidated: @MainActor () -> Void
        private var responderObservation: NSKeyValueObservation?

        init(window: NSWindow, invalidated: @escaping @MainActor () -> Void) {
            self.window = window
            responder = window.firstResponder
            time = ProcessInfo.processInfo.systemUptime
            wasKey = window.isKeyWindow
            appWasActive = NSApp.isActive
            self.invalidated = invalidated
            super.init()
        }

        func observe() {
            guard let window else { return }
            responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
                MainActor.assumeIsolated {
                    guard let self, window.firstResponder !== self.responder else { return }
                    self.invalidate()
                }
            }
            let center = NotificationCenter.default
            for name in [HtmlWebView.nativeMouseDown, NSWindow.didResignKeyNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
                center.addObserver(self, selector: #selector(invalidate), name: name, object: window)
            }
            for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
                center.addObserver(self, selector: #selector(invalidate), name: name, object: NSApp)
            }
        }

        @objc private func invalidate() { invalidated() }

        func stopObserving() {
            responderObservation = nil
            NotificationCenter.default.removeObserver(self)
        }
    }

    private var keyboardAuthorization: KeyboardAuthorization = .denied {
        didSet {
            if case let .pending(click) = oldValue { click.stopObserving() }
        }
    }
    /// Esc in the page: the canvas takes the keyboard back (`CanvasView.leaveTile`). Set for the
    /// tile's live page; an offscreen render's page has none and never has the keyboard anyway.
    var onEscape: (@MainActor () -> Void)?

    override init(frame: NSRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        Self.suppressPageFocusChanges(in: self)
        Self.installSendMonitor()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// Best effort: suppress WebKit's page-initiated focus changes in addition to the native
    /// keyboard permission gate. Explicit user grants still use `makeFirstResponder`.
    private static func suppressPageFocusChanges(in web: WKWebView) {
        let selector = NSSelectorFromString("_setShouldSuppressFirstResponderChanges:")
        guard web.responds(to: selector) else { return }
        typealias SetSuppressed = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(web.method(for: selector), to: SetSuppressed.self)(web, selector, true)
    }

    override var acceptsFirstResponder: Bool {
        if case .granted = keyboardAuthorization { return true }
        return false
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard acceptsFirstResponder else { return false }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { keyboardAuthorization = .denied }
        return resigned
    }

    /// The user asked for the page's keyboard (Return on the selected tile, or a click in a text
    /// field). False when the page has no view in the window to take it.
    @discardableResult
    func takeKeyboard() -> Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        keyboardAuthorization = .granted
        guard window?.makeFirstResponder(self) == true else {
            keyboardAuthorization = .denied
            return false
        }
        return true
    }

    func resetKeyboardAuthorization() {
        keyboardAuthorization = .denied
        revokeSendPermit()
        guard let window, ownsKeyboard(in: window) else { return }
        onEscape?()
        if ownsKeyboard(in: window) { window.makeFirstResponder(nil) }
    }

    private func ownsKeyboard(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            keyboardAuthorization = .denied
            revokeSendPermit()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func bindSendDocument(_ url: String) {
        sendPermit.noteURL(url)
    }

    func revokeSendPermit() {
        sendPermit.reset()
    }

    /// False when the page is parked, hidden, or not the live tile. A hidden page can still queue
    /// inert data; it cannot spend a permit.
    func consumeSendPermit(at time: TimeInterval) -> Bool {
        guard acceptsSendGestures, isLiveVisible else {
            revokeSendPermit()
            return false
        }
        return sendPermit.consume(at: time)
    }

    private var isLiveVisible: Bool {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return false }
        return true
    }

    private static func installSendMonitor() {
        guard sendMonitor == nil else { return }
        sendMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated { observeSendGesture(event) }
            return event
        }
    }

    /// Left mouse down only. Mouse up is the same click, not a second gesture. Key repeats do
    /// not extend the window after the first key down.
    private static func observeSendGesture(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard let web = webView(hitBy: event), web.acceptsSendGestures, web.isLiveVisible else { return }
            web.sendPermit.arm(at: event.timestamp)
        case .keyDown:
            guard !event.isARepeat, let window = event.window, window.isKeyWindow,
                  let web = webView(owningKeyboardIn: window), web.acceptsSendGestures, web.isLiveVisible else { return }
            web.sendPermit.arm(at: event.timestamp)
        default:
            break
        }
    }

    private static func webView(hitBy event: NSEvent) -> HtmlWebView? {
        guard let content = event.window?.contentView else { return nil }
        let point = content.convert(event.locationInWindow, from: nil)
        guard let hit = content.hitTest(point), let web = ancestorWebView(of: hit) else { return nil }
        guard web.bounds.contains(web.convert(event.locationInWindow, from: nil)) else { return nil }
        return web
    }

    private static func webView(owningKeyboardIn window: NSWindow) -> HtmlWebView? {
        guard let responder = window.firstResponder as? NSView, let web = ancestorWebView(of: responder), web.ownsKeyboard(in: window) else { return nil }
        return web
    }

    private static func ancestorWebView(of view: NSView) -> HtmlWebView? {
        var current: NSView? = view
        while let view = current {
            if let web = view as? HtmlWebView { return web }
            current = view.superview
        }
        return nil
    }

    private func cancelKeyboardClick() {
        if case .pending = keyboardAuthorization { keyboardAuthorization = .denied }
    }

    private var lastClick: (time: TimeInterval, flags: NSEvent.ModifierFlags)?

    /// The modifiers of the last click on the page when it was within `seconds` (a link the page
    /// follows just after one is the user's: the web view tells a script's navigation from a click
    /// only by its type, and `a.click()` looks like one).
    func recentClick(within seconds: TimeInterval = 2) -> NSEvent.ModifierFlags? {
        guard let lastClick, ProcessInfo.processInfo.systemUptime - lastClick.time <= seconds else { return nil }
        return lastClick.flags
    }

    override func mouseDown(with event: NSEvent) {
        lastClick = (ProcessInfo.processInfo.systemUptime, event.modifierFlags)
        let hadKeyboard = window?.firstResponder === self
        let point = convert(event.locationInWindow, from: nil)
        let zoom = pageZoom * magnification
        let x = (point.x - bounds.minX) / zoom
        let y = (isFlipped ? point.y - bounds.minY : bounds.maxY - point.y) / zoom
        cancelKeyboardClick()
        super.mouseDown(with: event)
        guard !hadKeyboard, let window else { return }
        let click = KeyboardClick(window: window) { [weak self] in self?.cancelKeyboardClick() }
        guard !click.appWasActive || click.wasKey else { return }
        keyboardAuthorization = .pending(click)
        click.observe()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clickGrantLifetime) { [weak self, weak click] in
            guard let self, let click, case let .pending(latest) = self.keyboardAuthorization, latest === click else { return }
            self.cancelKeyboardClick()
        }
        // First mouse can arrive without activating the app. A later focus, key-window or
        // application transition cancels even if the original state is restored.
        PageScript.call("""
        const el = Object.getOwnPropertyDescriptor(Document.prototype, 'activeElement').get.call(document);
        if (!(el instanceof HTMLElement)) return false;
        const tag = Object.getOwnPropertyDescriptor(Element.prototype, 'tagName').get.call(el);
        const editable = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'isContentEditable').get.call(el);
        if (!(tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || editable === true)) return false;
        const hit = Document.prototype.elementFromPoint.call(document, x, y);
        return hit !== null && Node.prototype.contains.call(el, hit) === true;
        """, ["x": x, "y": y], in: Self.clickWorld, on: self) { [weak self, weak click] value, error in
            guard let self, let click, case let .pending(latest) = self.keyboardAuthorization, latest === click else { return }
            self.keyboardAuthorization = .denied
            guard error == nil, (value as? Bool) == true,
                  ProcessInfo.processInfo.systemUptime - click.time <= Self.clickGrantLifetime,
                  let window = click.window, self.window === window,
                  window.firstResponder === click.responder, window.isKeyWindow == click.wasKey,
                  NSApp.isActive == click.appWasActive else { return }
            _ = self.takeKeyboard()
        }
    }

    /// Esc the page didn't use (a dialog closes, a game pauses on its own) arrives here as
    /// WebKit's saved Esc command; no `super` (the canvas must not see it). It hands the keyboard
    /// back like any tile's Esc. Every other key the page didn't use stays in the page: the
    /// canvas's tools, Delete and Return don't act while a field is being typed in.
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func mouseUp(with event: NSEvent) {
        lastClick = (ProcessInfo.processInfo.systemUptime, event.modifierFlags)
        super.mouseUp(with: event)
    }

    /// WebKit's context menu leads with Mention: the element under the right-click.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        CanvasView.insertMention(into: menu, in: self, for: event)
    }
}
