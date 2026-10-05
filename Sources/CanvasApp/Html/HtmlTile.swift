import AppKit
import CanvasCore
import WebKit

/// Agent- or user-authored HTML in a sandboxed web view (docs/design.md, HTML): a throwaway data
/// store, http(s)/ws blocked except `props.allowNetwork` hosts, and no native bridge beyond the
/// validated `canvas` channel. The web view exists only while the tile is live, and for
/// `parkDelay` after it leaves the view (hidden, so panning or zooming back shows the page without
/// loading it again); then it is released and the tile shows its last snapshot.
@MainActor
final class HtmlTile: NSView, TileContent {
    private(set) var object: CanvasObject
    private let board: Board
    private(set) var webView: WKWebView?
    /// `html.webviews` while `webView` exists; released with it, or with the tile when the tile
    /// goes without a `detach` (deleted from the board).
    private var webViewCount: GaugeHold?
    private var live = true
    private var building = false
    private var loadFailure: NSTextField?
    /// Last rendered image: zoomed-out cards and `view.snapshot` covers.
    private var lastSnapshot: NSImage?
    private var snapshotCover: NSImageView?
    private var snapshotTask: Task<Void, Never>?
    /// The live page has settled (the kit's `view.rendered`) and that frame is on screen.
    private var pageShown = false
    private var readyWaiters: [@MainActor () -> Void] = []
    /// Page scroll reported by the kit, restored after re-renders and re-attachment.
    private var scrollY: Double = 0
    /// The page's own background luminance (`PageSurface`); nil while it leaves it transparent
    /// (the tile's own background shows through).
    private(set) var surfaceLuminance: Double?
    private var hovered: WebMentions.Element?
    private var hoverInFlight = false
    private var queuedHover: NSPoint?
    /// Bounds the native work a page can have outstanding; cancelled when the web view goes away.
    private let work = HtmlWorkQueue()
    /// A code tile the user opened from this page (`<canvas-link>`, `<canvas-code>`), or one
    /// that already showed the lines (`existing`); the canvas shows it.
    var onOpenedCode: ((ObjectID, _ existing: Bool) -> Void)?
    /// A web link the user clicked on the page opened or found this browser tile; the canvas
    /// shows it.
    var onOpenedLink: ((ObjectID) -> Void)?

    /// `live: false` builds no web view (a page measured offscreen, `measure`).
    init(object: CanvasObject, board: Board, live: Bool = true) {
        self.object = object
        self.board = board
        self.live = live
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        build()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    var objectID: ObjectID { object.id }
    /// Where the page's relative `<img src>` paths resolve: the tile's link root (a scratch tile
    /// being measured runs on a board rooted there already).
    var boardRoot: URL { board.objects[object.id] != nil ? board.linkRoot(of: object) : board.root }
    var html: String { object.props["html"]?.string ?? "" }
    private var allowNetwork: [String] { object.props["allowNetwork"]?.array?.compactMap(\.string) ?? [] }
    private var pageURL: URL { HtmlKit.pageURL(tile: object.id) }

    // MARK: Web view lifecycle

    /// The rule list compiles asynchronously; the page never loads without it (fail closed), and
    /// never with a list compiled for an allowlist that has since changed.
    private func build() {
        guard live, webView == nil, !building else { return }
        building = true
        let hosts = allowNetwork
        Task { @MainActor [weak self] in
            let rules: WKContentRuleList?
            var failure: Error?
            do {
                rules = try await HtmlRuleLists.list(allowing: hosts)
            } catch {
                rules = nil
                failure = error
            }
            guard let self else { return }
            self.building = false
            guard hosts == self.allowNetwork else { return self.build() }
            guard let rules else { return self.showFailure("Network rules failed to compile: \(failure.map(String.init(describing:)) ?? "")") }
            guard self.live, self.webView == nil else { return }
            self.attach(rules: rules)
        }
    }

    /// The sandbox every page of this tile runs in: its own data store, the network rules, the
    /// kit scheme, and the validated `canvas` channel.
    private func configuration(rules: WKContentRuleList) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        configuration.setURLSchemeHandler(HtmlSchemeHandler(tile: self), forURLScheme: HtmlKit.scheme)
        configuration.userContentController.addScriptMessageHandler(HtmlChannelHandler(tile: self), contentWorld: .page, name: "canvas")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        return configuration
    }

    private func attach(rules: WKContentRuleList) {
        Metrics.shared.record("html.load")
        webViewCount = GaugeHold("html.webviews")
        let configuration = configuration(rules: rules)
        WebMentions.install(on: configuration)

        let web = HtmlWebView(frame: bounds, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.uiDelegate = self
        web.underPageBackgroundColor = .textBackgroundColor
        addSubview(web, positioned: .below, relativeTo: nil)
        webView = web
        pageShown = false
        loadFailure?.removeFromSuperview()
        loadFailure = nil
        web.load(URLRequest(url: pageURL))
    }

    private func detach() {
        unpark()
        snapshotTask?.cancel()
        snapshotTask = nil
        pageShown = false
        readyWaiters.removeAll()
        work.cancelAll()
        guard let web = webView else { return }
        webViewCount = nil
        web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.removeFromSuperview()
        webView = nil
        hovered = nil
    }

    // MARK: Parked pages

    /// How long a page that left the view stays loaded (hidden) before it is released.
    static let parkDelay: TimeInterval = 30
    /// Pages kept loaded out of view at once; parking another releases the longest parked.
    static let maxParked = 12
    private static var parked: [WeakTile] = []
    private var parkTimer: Timer?

    private struct WeakTile {
        weak var tile: HtmlTile?
    }

    /// The page left the view: hide it and keep it for `parkDelay`.
    private func park() {
        guard let web = webView else { return }
        web.isHidden = true
        readyWaiters.removeAll()
        Self.parked.removeAll { $0.tile == nil || $0.tile === self }
        Self.parked.append(WeakTile(tile: self))
        while Self.parked.count > Self.maxParked { Self.parked.removeFirst().tile?.detach() }
        parkTimer?.invalidate()
        parkTimer = Timer.scheduledTimer(withTimeInterval: Self.parkDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.live else { return }
                self.detach()
            }
        }
    }

    private func unpark() {
        parkTimer?.invalidate()
        parkTimer = nil
        Self.parked.removeAll { $0.tile == nil || $0.tile === self }
    }

    private func showFailure(_ message: String) {
        loadFailure?.removeFromSuperview()
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .systemRed
        label.frame = bounds.insetBy(dx: 12, dy: 12)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
        loadFailure = label
        showPage()
    }

    // MARK: Channel

    /// `rendering`: from the offscreen page `render(_:)` loads, which may read (excerpts, state)
    /// but never act for the user.
    func handle(_ message: HtmlMessage, rendering: Bool) async throws -> JSONValue {
        if rendering {
            switch message {
            case .rendered:
                offscreenSettled = true
                return .object([:])
            case .getState(let key):
                // The page being rendered or measured is this object's (which may not be on the board yet).
                return HtmlChannel.state(object.props, key: key)
            case .openCode, .setState:
                throw HtmlError.malformed("not available while the page renders offscreen")
            default:
                break
            }
        } else if case .rendered(let y) = message {
            if let y { scrollY = y }
            pageSettled()
        }
        let result = try await work.perform { [object, board] in try await HtmlChannel.handle(message, tile: object.id, board: board) }
        if case .openCode = message, let opened = result["tile"]?.string { onOpenedCode?(opened, result["existing"] == .bool(true)) }
        return result
    }

    // MARK: Snapshots

    /// The live page settled: its first settled frame on screen makes it ready (`whenLiveReady`),
    /// and the snapshot is refreshed.
    private func pageSettled() {
        if !pageShown, let web = webView {
            WebStage.afterNextPresentationUpdate(web) { [weak self] in
                guard let self, self.webView === web else { return }
                self.showPage()
            }
        }
        scheduleSnapshot()
    }

    private func showPage() {
        pageShown = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for ready in waiters { ready() }
    }

    /// WebKit draws outside AppKit, so `cacheDisplay` can't capture it; keep an image of the
    /// settled page instead. Width is capped so large tiles don't hold huge bitmaps.
    private func scheduleSnapshot() {
        snapshotTask?.cancel()
        snapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            // A parked (hidden) page draws nothing worth keeping: the card keeps its last image.
            guard !Task.isCancelled, let self, self.live, let web = self.webView, !web.bounds.isEmpty else { return }
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = NSNumber(value: min(web.bounds.width, 1200))
            if let image = try? await web.takeSnapshot(configuration: configuration), !Task.isCancelled {
                self.lastSnapshot = image
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if live, webView != nil { scheduleSnapshot() }
    }

    // MARK: TileContent

    func setLive(_ live: Bool) {
        guard live != self.live else { return }
        self.live = live
        if live, let web = webView {
            // Back before its release: the page is still loaded. It may have re-rendered while
            // hidden (a `state` change), which parked pages don't capture: refresh the snapshot
            // once the page is on screen again.
            unpark()
            web.isHidden = false
            Metrics.shared.record("html.reuse")
            WebStage.afterNextPresentationUpdate(web) { [weak self] in
                guard let self, self.live, self.webView === web else { return }
                self.scheduleSnapshot()
            }
        } else if live {
            build()
        } else if pageShown, loadFailure == nil {
            park()
        } else {
            detach()
        }
    }

    func whenLiveReady(_ ready: @escaping @MainActor () -> Void) {
        guard live else { return }
        if pageShown { ready() } else { readyWaiters.append(ready) }
    }

    /// Card image: the live page's last capture, else an offscreen render.
    func cardSnapshot(_ deliver: @escaping @MainActor (NSImage?) -> Void) {
        if let lastSnapshot { return deliver(lastSnapshot) }
        let request = TileRenderRequest(size: bounds.size, scale: TileFrameView.cardPixelsPerPoint, full: false,
                                        appearance: window?.effectiveAppearance ?? NSApp.effectiveAppearance)
        Task { @MainActor in
            // Cards requested together (a batch of new tiles) render one per main turn.
            await MainTurns.next()
            let render = await self.render(request)
            deliver(render.state == .rendered ? render.image : nil)
        }
    }

    // MARK: Offscreen render

    /// The page `render(_:)` or `measure` loaded; the channel accepts its messages (read-only).
    private(set) var renderWebView: WKWebView?
    /// The offscreen page reported `view.rendered` since this was last reset.
    private var offscreenSettled = false
    private var renderBusy = false

    /// Loads the page in a separate web view parked in the stage (never the user's live page,
    /// whose size and scroll must not change), waits for the kit's `view.rendered` (Mermaid,
    /// `<canvas-code>` excerpts settled), measures it, and snapshots it: the tile's window at
    /// its scroll position, or with `full` the whole page height.
    func render(_ request: TileRenderRequest) async -> TileRender {
        guard let window else { return .placeholder(request, "the tile has no window") }
        guard await beginOffscreen() else { return .placeholder(request, "timed out waiting for another render of this tile") }
        let started = Metrics.now()
        defer {
            endOffscreen()
            Metrics.shared.record("html.render", ms: (Metrics.now() - started) * 1000)
        }
        let content: CGSize
        switch await loadOffscreen(size: request.size, appearance: request.appearance) {
        case .success(let extent): content = CGSize(width: max(request.size.width, extent.width), height: extent.height)
        case .failure(.rules(let reason)): return TileRender(image: nil, contentSize: request.size, state: .failed, reason: reason)
        case .failure(.unsettled(let reason)): return .placeholder(request, reason)
        }
        guard let web = renderWebView else { return .placeholder(request, "timed out") }
        if request.full, content.height > request.size.height + 1 {
            offscreenSettled = false
            let size = CGSize(width: request.size.width, height: min(content.height, RenderMath.maxContentExtent))
            WebStage.park(web, frame: NSRect(origin: .zero, size: size))
            _ = await Self.wait(until: { [unowned self] in offscreenSettled }, limit: .seconds(2))
        } else if !request.full, scrollY > 0 {
            offscreenSettled = false
            _ = try? await web.callAsyncJavaScript("window.canvasKit?.restoreScroll(y)", arguments: ["y": scrollY], contentWorld: .page)
            _ = await Self.wait(until: { [unowned self] in offscreenSettled }, limit: .seconds(1))
        }
        guard !Task.isCancelled else { return .placeholder(request, "timed out") }
        let shot = WKSnapshotConfiguration()
        shot.snapshotWidth = NSNumber(value: Double(web.bounds.width * request.scale / max(window.backingScaleFactor, 1)))
        guard let page = try? await web.takeSnapshot(configuration: shot) else {
            return TileRender(image: nil, contentSize: content, state: .failed, reason: "WebKit produced no snapshot")
        }
        let image = request.image(size: web.bounds.size) { bounds in page.drawUpright(in: bounds) }
        return TileRender(image: image, contentSize: content, state: image == nil ? .failed : .rendered)
    }

    /// Pages measured at once (`measure`); more wait their turn.
    private static var measuring = 0
    private static let maxMeasuring = 3
    /// How long a measured page gets to report `view.rendered`.
    static let measureLimit: Duration = .seconds(10)

    /// The document extent (scroll width and height, in points) of an HTML tile's page with
    /// `props` laid out `width` points wide: `object.measure`, `size: "fit"`, and `layout.check`
    /// (`ObjectMeasure.html`). The page loads offscreen exactly as `render(_:)` loads it, in a
    /// throwaway tile (the object may not exist yet) whose `<canvas-code>` excerpts read `root`.
    /// It is laid out 1 pt tall, so the document height is the content's, not the viewport's.
    /// A page loads in ~350 ms, so the same props at the same width reuse their extent for
    /// `measureReuse` (an agent's `layout.check` loop re-checks unchanged pages).
    static func measure(props: JSONValue, width: CGFloat, root: URL) async throws -> CGSize {
        let key = measureKey(props: props, width: width, root: root)
        if let key, let known = measured[key], ContinuousClock.now - known.at < measureReuse {
            Metrics.shared.record("html.measure.cached")
            return known.size
        }
        let queued = Metrics.now()
        while measuring >= maxMeasuring {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(30))
        }
        let started = Metrics.now()
        if started - queued > 0.001 { Metrics.shared.record("html.measure.wait", ms: (started - queued) * 1000) }
        measuring += 1
        defer {
            measuring -= 1
            Metrics.shared.record("html.measure", ms: (Metrics.now() - started) * 1000)
        }
        let object = CanvasObject(id: IDs.make("obj"), type: .html, frame: Frame(x: 0, y: 0, w: Double(width), h: RenderMath.tileTitleHeight + 1),
                                  z: 0, createdBy: .user, createdAt: Date(), props: props)
        let tile = HtmlTile(object: object, board: Board(id: IDs.make("brd"), root: root), live: false)
        guard await tile.beginOffscreen() else { throw ObjectMeasure.Failure.unavailable("the page is busy") }
        defer { tile.endOffscreen() }
        switch await tile.loadOffscreen(size: CGSize(width: width, height: 1), appearance: NSApp.effectiveAppearance, limit: measureLimit) {
        case .success(let extent):
            if let key {
                if measured.count >= 64 { measured = measured.filter { ContinuousClock.now - $0.value.at < measureReuse } }
                measured[key] = (extent, ContinuousClock.now)
            }
            return extent
        case .failure(.rules(let reason)), .failure(.unsettled(let reason)): throw ObjectMeasure.Failure.unavailable("cannot measure the page: \(reason)")
        }
    }

    /// How long a measured extent stands for the same page: long enough for a check loop, short
    /// enough that a `<canvas-code>` file edited meanwhile is measured again soon.
    static let measureReuse: Duration = .seconds(30)
    private static var measured: [String: (size: CGSize, at: ContinuousClock.Instant)] = [:]

    private static func measureKey(props: JSONValue, width: CGFloat, root: URL) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let json = try? encoder.encode(props) else { return nil }
        return "\(width)|\(root.path)|\(String(decoding: json, as: UTF8.self))"
    }

    /// Loads the page offscreen exactly as `render(_:)` does (never the user's live page) and runs
    /// `body` on it once it settled; nil and the reason when it didn't (or `body` threw).
    func withOffscreenPage<T>(size: CGSize, appearance: NSAppearance, _ body: (WKWebView) async throws -> T) async -> (T?, String?) {
        guard await beginOffscreen() else { return (nil, "another render of this tile is still running") }
        defer { endOffscreen() }
        switch await loadOffscreen(size: size, appearance: appearance) {
        case .success: break
        case .failure(.rules(let reason)), .failure(.unsettled(let reason)): return (nil, reason)
        }
        guard let web = renderWebView else { return (nil, "the page went away") }
        do {
            return (try await body(web), nil)
        } catch {
            return (nil, "\(error.localizedDescription)")
        }
    }

    private enum OffscreenFailure: Error {
        case rules(String)
        case unsettled(String)
    }

    /// Waits for this tile's previous offscreen page to finish; false when cancelled meanwhile.
    private func beginOffscreen() async -> Bool {
        while renderBusy {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        renderBusy = true
        return true
    }

    private func endOffscreen() {
        renderBusy = false
        renderWebView?.stopLoading()
        renderWebView?.configuration.userContentController.removeAllScriptMessageHandlers()
        renderWebView?.removeFromSuperview()
        renderWebView = nil
    }

    /// Loads the page into `renderWebView`, `size` points, parked in the stage, and waits for the
    /// kit's `view.rendered`; then the document's scroll width and height.
    private func loadOffscreen(size: CGSize, appearance: NSAppearance, limit: Duration = .seconds(60)) async -> Result<CGSize, OffscreenFailure> {
        let rules: WKContentRuleList
        do {
            rules = try await HtmlRuleLists.list(allowing: allowNetwork)
        } catch {
            return .failure(.rules("network rules failed to compile: \(error)"))
        }
        let web = HtmlWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration(rules: rules))
        web.navigationDelegate = self
        web.uiDelegate = self
        web.appearance = appearance
        web.underPageBackgroundColor = .textBackgroundColor
        WebStage.setOcclusionDetection(false, on: web)
        WebStage.park(web, frame: NSRect(origin: .zero, size: size))
        renderWebView = web
        offscreenSettled = false
        web.load(URLRequest(url: pageURL))
        guard await Self.wait(until: { [unowned self] in offscreenSettled }, limit: limit) else { return .failure(.unsettled("the page did not finish rendering")) }
        let measure = "[Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0), Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)]"
        let extent = (try? await web.evaluateJavaScript(measure)) as? [Double] ?? []
        return .success(CGSize(width: extent.first ?? size.width, height: extent.count > 1 ? extent[1] : size.height))
    }

    /// Polls `condition` until it holds, the task is cancelled (the render deadline), or `limit` passes.
    private static func wait(until condition: () -> Bool, limit: Duration = .seconds(60)) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return true
    }

    func showSnapshot(_ show: Bool) {
        snapshotCover?.removeFromSuperview()
        snapshotCover = nil
        guard show, live, webView != nil, let lastSnapshot else { return }
        let cover = NSImageView(frame: bounds)
        cover.image = lastSnapshot
        cover.imageScaling = .scaleAxesIndependently
        addSubview(cover)
        snapshotCover = cover
    }

    func update(_ object: CanvasObject) {
        let previous = self.object
        self.object = object
        guard let web = webView else { return }
        let networkChanged = (object.props["allowNetwork"] ?? .array([])) != (previous.props["allowNetwork"] ?? .array([]))
        if !live, networkChanged || object.props["html"] != previous.props["html"] {
            // A parked page would load again unseen: release it; the card shows the change.
            detach()
        } else if networkChanged {
            detach()
            build()
        } else if object.props["html"] != previous.props["html"] {
            Metrics.shared.record("html.reload")
            work.cancelAll()
            web.load(URLRequest(url: pageURL))
        } else if object.props["state"] != previous.props["state"] {
            let state = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(object.props["state"] ?? .object([:])))) ?? [String: Any]()
            Task { _ = try? await web.callAsyncJavaScript("window.canvasKit?.receiveState(state)", arguments: ["state": state], contentWorld: .page) }
        }
    }

    /// Element-level: the DOM element under the pointer, from the tile's canvas-kit page.
    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard webView != nil else { return nil }
        requestHover(at: point)
        return hovered.map(domTarget)
    }

    func resolveMention(at point: NSPoint) async -> MentionTarget? {
        guard let web = webView, let element = await WebMentions.element(at: point, in: web, pixel: true) else { return nil }
        var shown = element
        shown.point = nil
        hovered = shown
        return domTarget(element)
    }

    /// Edit › Mention: the page's text selection; nil without one: the whole tile.
    func keyboardMention(hasKeyboard: Bool) async -> MentionTarget? {
        guard let web = webView, let element = await WebMentions.selection(in: web) else { return nil }
        return domTarget(element)
    }

    func pageElements(in rect: NSRect) async -> PageElements? {
        let region = rect.intersection(bounds)
        guard let web = webView, !region.isNull, region.width > 0, region.height > 0,
              let found = await WebMentions.elements(in: region, in: web) else { return nil }
        return PageElements(url: pageURL.absoluteString, elements: found.elements.map { .init(selector: $0.selector, text: $0.text) }, more: found.more)
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .dom(_, _, let selector, _, _) = target, let hovered, hovered.selector == selector else { return bounds }
        return hovered.rect.intersection(bounds)
    }

    var takesKeyboardFocus: Bool { false }

    private func domTarget(_ element: WebMentions.Element) -> MentionTarget {
        .dom(object: object.id, url: pageURL.absoluteString, selector: element.selector, text: element.text.isEmpty ? nil : element.text, point: element.point)
    }

    /// One element lookup in flight at a time; the latest pointer position wins.
    private func requestHover(at point: NSPoint) {
        guard !hoverInFlight else {
            queuedHover = point
            return
        }
        guard let web = webView else { return }
        hoverInFlight = true
        Task { @MainActor [weak self] in
            let element = await WebMentions.element(at: point, in: web)
            guard let self else { return }
            self.hoverInFlight = false
            if element != self.hovered {
                self.hovered = element
                NotificationCenter.default.post(name: .tileMentionHoverChanged, object: self)
            }
            if let next = self.queuedHover {
                self.queuedHover = nil
                self.requestHover(at: next)
            }
        }
    }
}

extension HtmlTile: WKNavigationDelegate, WKUIDelegate {
    /// The page may load only its own document and kit; links never navigate the tile away. A
    /// web link the user just clicked goes to a browser tile beside this one instead
    /// (`followed`): a link activated in the page's main frame, or a new window (`target=_blank`,
    /// or a `window.open` the page calls while handling a click: with
    /// `javaScriptCanOpenWindowsAutomatically` off, WebKit blocks one from a timer before asking).
    /// Every other navigation off the page (a timer setting `location.href`, an iframe's `src`)
    /// is cancelled.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let isMain = action.targetFrame?.isMainFrame ?? true
        let userLink = action.targetFrame == nil || (action.navigationType == .linkActivated && isMain)
        if userLink, followed(action, in: webView) { return .cancel }
        if isMain { return url.scheme == HtmlKit.scheme && url.host == HtmlKit.host && url.path == pageURL.path ? .allow : .cancel }
        return ["about", "data", "blob", HtmlKit.scheme].contains(url.scheme ?? "") ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        probeSurface(webView)
        guard scrollY > 0 else { return }
        let y = scrollY
        Task { _ = try? await webView.callAsyncJavaScript("window.canvasKit?.restoreScroll(y)", arguments: ["y": y], contentWorld: .page) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.load(URLRequest(url: pageURL))
    }

    /// A new window the policy above let through (it opened as a link already when it could):
    /// never a web view of its own.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    /// Opens the http(s) link of `action` when the user clicked the page just now (a script
    /// navigating or opening windows by itself is not a click): in a browser tile beside this
    /// one (`Board.openLink`, a tile already showing it is reused), or in the default browser
    /// with ⌥ held.
    private func followed(_ action: WKNavigationAction, in webView: WKWebView) -> Bool {
        guard let url = action.request.url, WebLink.isWeb(url), let click = (webView as? HtmlWebView)?.recentClick() else { return false }
        if click.union(action.modifierFlags).contains(.option) {
            ExternalOpen.open(url, because: "html \(object.id) link (⌥-click)")
        } else {
            let opened = board.openLink(url, near: object.id, caller: nil)
            NSLog("easl: html %@ link %@ → %@ %@", object.id, url.absoluteString, opened.existing ? "existing browser tile" : "new browser tile", opened.object.id)
            onOpenedLink?(opened.object.id)
        }
        return true
    }
}

extension HtmlTile {
    /// Reads the page's background for drawings over the tile.
    fileprivate func probeSurface(_ webView: WKWebView) {
        Task { @MainActor [weak self] in
            guard let probe = await PageSurface.probe(webView), let self, probe.luminance != self.surfaceLuminance else { return }
            self.surfaceLuminance = probe.luminance
            NotificationCenter.default.post(name: .tileSurfaceChanged, object: self)
        }
    }
}
