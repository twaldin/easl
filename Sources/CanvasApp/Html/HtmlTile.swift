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
    let files: HostFiles?
    /// Remote documents and every scheme response share this in-memory policy.
    private(set) var contentSecurityPolicy: String?
    private(set) var webView: WKWebView?
    /// `html.webviews` while `webView` exists; released with it, or with the tile when the tile
    /// goes without a `detach` (deleted from the board).
    private var webViewCount: GaugeHold?
    private var live = true
    private var building = false
    private var loadFailure: NSTextField?
    private var hostImageFailure: NSTextField?
    private var hostImageFailures: [URL: String] = [:]
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
    private struct AssetDependency: Equatable {
        var request: HostFileRequest
        var baseline: HostFileObservation
    }
    private var assets: [String: AssetDependency] = [:]
    private var assetWatch: HostFileWatch?
    private var assetReload: DispatchWorkItem?

    private func suspendAssetWatch() {
        assetWatch?.cancel()
        assetWatch = nil
        assetReload?.cancel()
        assetReload = nil
    }

    func resetAssetWatches() {
        suspendAssetWatch()
        assets.removeAll()
    }

    func observeAsset(_ path: String, request: HostFileRequest, baseline: HostFileObservation) {
        guard live else { return }
        var metadata = request
        metadata.bytes = false
        metadata.range = nil
        let dependency = AssetDependency(request: metadata, baseline: baseline)
        guard assets[path] != dependency else { return }
        assets[path] = dependency
        resumeAssetWatch()
    }

    private func resumeAssetWatch() {
        suspendAssetWatch()
        guard live, window != nil, !assets.isEmpty else { return }
        let dependencies = assets.sorted { $0.key < $1.key }.map(\.value)
        let requests = dependencies.map(\.request)
        let files = files
        assetWatch = HostFileWatch(baseline: dependencies.map(\.baseline), probe: {
            do {
                if let files { return try await files.observe(requests) }
                return try await HostFiles.observeLocal(requests)
            } catch {
                return nil
            }
        }, changed: { [weak self] _ in
            guard let self, self.live, self.window != nil else { return }
            self.assetReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.live, self.window != nil, let web = self.webView else { return }
                    self.loadPage(in: web)
                }
            }
            self.assetReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        })
    }
    /// A code tile the user opened from this page (`<canvas-link>`, `<canvas-code>`), or one
    /// that already showed the lines (`existing`); the canvas shows it.
    var onOpenedCode: ((ObjectID, _ existing: Bool) -> Void)?
    /// A web link the user clicked on the page opened or found this browser tile; the canvas
    /// shows it.
    var onOpenedLink: ((ObjectID) -> Void)?

    /// `live: false` builds no web view (a page measured offscreen, `measure`).
    init(object: CanvasObject, board: Board, live: Bool = true, files: HostFiles? = nil) {
        self.object = object
        self.board = board
        self.live = live
        self.files = files
        contentSecurityPolicy = board.isRemote
            ? HtmlKit.contentSecurityPolicy(allow: object.props["allowNetwork"]?.array?.compactMap(\.string) ?? [])
            : nil
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
    var allowNetwork: [String] { object.props["allowNetwork"]?.array?.compactMap(\.string) ?? [] }
    var hostImageSource: HostFileRequest.Source { board.hostSource(props: object.props, objects: false) }
    var isRemote: Bool { board.isRemote }
    private var pageURL: URL { HtmlKit.pageURL(tile: object.id) }

    // MARK: Web view lifecycle

    /// The rule list compiles asynchronously; the page never loads without it (fail closed), and
    /// never with a list compiled for an allowlist that has since changed.
    private func build() {
        guard live, webView == nil, !building else { return }
        building = true
        let hosts = allowNetwork
        let remote = board.isRemote
        Task { @MainActor [weak self] in
            let rules: WKContentRuleList?
            var failure: Error?
            do {
                if remote {
                    rules = try await HtmlRuleLists.remote()
                } else {
                    rules = try await HtmlRuleLists.list(allowing: hosts)
                }
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
    private func configuration(rules: WKContentRuleList?) -> WKWebViewConfiguration {
        Self.configuration(rules: rules, scheme: HtmlSchemeHandler(tile: self), channel: HtmlChannelHandler(tile: self))
    }

    static func configuration(rules: WKContentRuleList?, scheme: HtmlSchemeHandler, channel: HtmlChannelHandler) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        if scheme.tile?.isRemote == true {
            scheme.hostNetworkEnabled = Self.disableDirectTransports(configuration.preferences)
        }
        if let rules { configuration.userContentController.add(rules) }
        configuration.setURLSchemeHandler(scheme, forURLScheme: HtmlKit.scheme)
        configuration.userContentController.addScriptMessageHandler(channel, contentWorld: .page, name: "canvas")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        return configuration
    }

    private static func disableDirectTransports(_ preferences: WKPreferences) -> Bool {
        let featuresSelector = NSSelectorFromString("_features")
        let setter = NSSelectorFromString("_setEnabled:forFeature:")
        guard WKPreferences.responds(to: featuresSelector), preferences.responds(to: setter),
              let features = (WKPreferences.self as AnyObject).perform(featuresSelector)?.takeUnretainedValue() as? [NSObject] else { return false }
        let required = ["WebTransportEnabled", "PeerConnectionEnabled"]
        let selected = features.filter {
            $0.responds(to: NSSelectorFromString("key")) && required.contains($0.value(forKey: "key") as? String ?? "")
        }
        guard required.allSatisfy({ key in selected.contains { $0.value(forKey: "key") as? String == key } }) else { return false }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let setEnabled = unsafeBitCast(preferences.method(for: setter), to: SetEnabled.self)
        for feature in selected { setEnabled(preferences, setter, false, feature) }
        return true
    }

    private func attach(rules: WKContentRuleList?) {
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
        loadPage(in: web)
    }

    private func detach() {
        unpark()
        resetAssetWatches()
        snapshotTask?.cancel()
        snapshotTask = nil
        pageShown = false
        readyWaiters.removeAll()
        work.cancelAll()
        guard let web = webView else { return }
        webViewCount = nil
        (web.configuration.urlSchemeHandler(forURLScheme: HtmlKit.scheme) as? HtmlSchemeHandler)?.tile = nil
        web.stopLoading()
        (web.configuration.urlSchemeHandler(forURLScheme: HtmlKit.scheme) as? HtmlSchemeHandler)?.cancelHostReads()
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

    private func loadPage(in web: WKWebView) {
        (web.configuration.urlSchemeHandler(forURLScheme: HtmlKit.scheme) as? HtmlSchemeHandler)?.cancelHostReads()
        hostImageFailures.removeAll()
        hostImageFailure?.removeFromSuperview()
        hostImageFailure = nil
        loadFailure?.removeFromSuperview()
        loadFailure = nil
        web.load(URLRequest(url: pageURL))
    }

    private func showFailure(_ message: String) {
        loadFailure?.removeFromSuperview()
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .systemRed
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.frame = bounds.insetBy(dx: 12, dy: 12)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
        loadFailure = label
        showPage()
    }

    func hostImageFinished(_ url: URL, error: Error?, in web: WKWebView) {
        guard web === webView else { return }
        if let error {
            let failure = error as? HostFileError ?? .unavailable(String(describing: error))
            hostImageFailures[url] = "\(HostGit.refusal(failure)) (\(url.lastPathComponent))"
        } else {
            hostImageFailures.removeValue(forKey: url)
        }
        hostImageFailure?.removeFromSuperview()
        hostImageFailure = nil
        guard let reason = hostImageFailures.first?.value else { return }
        let message = "Host image: \(reason)"
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .systemRed
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = message
        label.frame = NSRect(x: 8, y: max(8, bounds.height - 56), width: max(0, bounds.width - 16), height: min(48, max(0, bounds.height - 16)))
        label.autoresizingMask = [.width, .minYMargin]
        addSubview(label)
        hostImageFailure = label
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
        let result = try await work.perform { [object, board, files] in try await HtmlChannel.handle(message, tile: object.id, board: board, files: files) }
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
        if !live {
            suspendAssetWatch()
            webView?.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        }
        if live, let web = webView {
            // Back before its release: the page is still loaded. It may have re-rendered while
            // hidden (a `state` change), which parked pages don't capture: refresh the snapshot
            // once the page is on screen again.
            unpark()
            web.setAllMediaPlaybackSuspended(false, completionHandler: nil)
            web.isHidden = false
            Metrics.shared.record("html.reuse")
            resumeAssetWatch()
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            suspendAssetWatch()
        } else if live {
            resumeAssetWatch()
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
            // Cards requested together (a batch of new tiles) render one per wake of the main thread.
            await MainTurns.next()
            let render = await self.render(request)
            deliver(render.state == .rendered ? render.image : nil)
        }
    }

    // MARK: Offscreen render

    /// The page `render(_:)` or `measure` loaded; the channel accepts its messages (read-only).
    private(set) var renderWebView: WKWebView?
    /// The pooled page `renderWebView` is while it measures (`HtmlMeasurePool`).
    private var measurePage: HtmlMeasurePage?
    /// The offscreen page reported `view.rendered` since this was last reset.
    private var offscreenSettled = false
    private var renderBusy = false

    /// Loads the page in a separate web view parked in the stage (never the user's live page,
    /// whose size and scroll must not change), waits for the kit's `view.rendered` (Mermaid,
    /// `<canvas-code>` excerpts settled), measures it, and snapshots it: the tile's window at
    /// its scroll position, or with `full` the whole page height.
    func render(_ request: TileRenderRequest) async -> TileRender {
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
        // WebKit snapshots at the backing scale of the window the page is parked in, the stage's.
        let shot = WKSnapshotConfiguration()
        shot.snapshotWidth = NSNumber(value: Double(web.bounds.width * request.scale / max(web.window?.backingScaleFactor ?? 1, 1)))
        guard let page = try? await web.takeSnapshot(configuration: shot) else {
            return TileRender(image: nil, contentSize: content, state: .failed, reason: "WebKit produced no snapshot")
        }
        let image = request.image(size: web.bounds.size) { bounds in page.drawUpright(in: bounds) }
        return TileRender(image: image, contentSize: content, state: image == nil ? .failed : .rendered)
    }

    /// Pages measured at once (`measure`); more wait their turn.
    private static var measuring = 0
    static let maxMeasuring = 3
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
        let extent = try await measure(measuredPage(props, width: width), on: Board(id: IDs.make("brd"), root: root), files: nil)
        if let key {
            if measured.count >= 64 { measured = measured.filter { ContinuousClock.now - $0.value.at < measureReuse } }
            measured[key] = (extent, ContinuousClock.now)
        }
        return extent
    }

    /// The same for a page on remote board `board`, as its viewer measures it for the board's
    /// easld: on a scratch board of its own (`Board.measuring`), its `<canvas-code>` excerpts and
    /// images read on the host through `files` under the page's own root, ref and refSha, never
    /// from this Mac's disk. Its page is never a pooled one (`loadOffscreen`), and its extent is
    /// never reused: `measured` is keyed by path, and a path names another file on another host.
    static func measure(props: JSONValue, width: CGFloat, remote board: Board, files: HostFiles) async throws -> CGSize {
        let page = measuredPage(props, width: width)
        return try await measure(page, on: .measuring(page, on: board), files: files)
    }

    /// The throwaway object a page is measured in: `width` wide, its body 1 pt tall.
    private static func measuredPage(_ props: JSONValue, width: CGFloat) -> CanvasObject {
        CanvasObject(id: IDs.make("obj"), type: .html, frame: Frame(x: 0, y: 0, w: Double(width), h: RenderMath.tileTitleHeight + 1),
                     z: 0, createdBy: .user, createdAt: Date(), props: props)
    }

    private static func measure(_ page: CanvasObject, on board: Board, files: HostFiles?) async throws -> CGSize {
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
        let tile = HtmlTile(object: page, board: board, live: false, files: files)
        guard await tile.beginOffscreen() else { throw ObjectMeasure.Failure.unavailable("the page is busy") }
        var measuredFine = false
        // A page that failed or was cancelled may be stuck (a script that never yields): it is
        // discarded, never emptied for reuse (`HtmlMeasurePool`).
        defer { tile.endOffscreen(keepPage: measuredFine && !Task.isCancelled) }
        switch await tile.loadOffscreen(size: CGSize(width: page.frame.w, height: 1), appearance: NSApp.effectiveAppearance, limit: measureLimit, pooled: true) {
        case .success(let extent):
            measuredFine = true
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

    /// `keepPage`: a pooled measure page goes back to the pool (it measured fine); otherwise it
    /// is discarded.
    private func endOffscreen(keepPage: Bool = false) {
        renderBusy = false
        if let page = measurePage {
            measurePage = nil
            renderWebView = nil
            if keepPage { HtmlMeasurePool.give(page) } else { HtmlMeasurePool.discard(page) }
            return
        }
        (renderWebView?.configuration.urlSchemeHandler(forURLScheme: HtmlKit.scheme) as? HtmlSchemeHandler)?.tile = nil
        renderWebView?.stopLoading()
        renderWebView?.configuration.userContentController.removeAllScriptMessageHandlers()
        renderWebView?.removeFromSuperview()
        renderWebView = nil
    }

    /// Loads the page into `renderWebView`, `size` points, parked in the stage, and waits for the
    /// kit's `view.rendered`; then the document's scroll width and height. `pooled` (a measure)
    /// borrows a web view from `HtmlMeasurePool` instead of making one.
    private func loadOffscreen(size: CGSize, appearance: NSAppearance, limit: Duration = .seconds(60), pooled: Bool = false) async -> Result<CGSize, OffscreenFailure> {
        let rules: WKContentRuleList
        do {
            if board.isRemote {
                rules = try await HtmlRuleLists.remote()
            } else {
                rules = try await HtmlRuleLists.list(allowing: allowNetwork)
            }
        } catch {
            return .failure(.rules("network rules failed to compile: \(error)"))
        }
        let web: HtmlWebView
        if pooled, !board.isRemote {
            let page = HtmlMeasurePool.take(for: self, rules: rules)
            measurePage = page
            web = page.web
        } else {
            web = HtmlWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration(rules: rules))
            WebStage.setOcclusionDetection(false, on: web)
        }
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        web.appearance = appearance
        web.underPageBackgroundColor = .textBackgroundColor
        WebStage.park(web, frame: NSRect(origin: .zero, size: size))
        renderWebView = web
        offscreenSettled = false
        web.load(URLRequest(url: pageURL))
        guard await Self.wait(until: { [unowned self] in offscreenSettled }, limit: limit) else { return .failure(.unsettled("the page did not finish rendering")) }
        let measure = "[Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0), Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)]"
        do {
            guard let extent = try await web.evaluateJavaScript(measure) as? [Double],
                  extent.count == 2, extent.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                return .failure(.unsettled("cannot read the page's dimensions"))
            }
            return .success(CGSize(width: extent[0], height: extent[1]))
        } catch {
            return .failure(.unsettled("cannot read the page's dimensions"))
        }
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
        let networkChanged = (object.props["allowNetwork"] ?? .array([])) != (previous.props["allowNetwork"] ?? .array([]))
        let pageChanged = ["html", "root", "ref"].contains { object.props[$0] != previous.props[$0] }
        self.object = object
        if networkChanged, board.isRemote {
            contentSecurityPolicy = HtmlKit.contentSecurityPolicy(allow: allowNetwork)
        }
        guard let web = webView else { return }
        if !live, networkChanged || pageChanged {
            // A parked page would load again unseen: release it; the card shows the change.
            detach()
        } else if networkChanged {
            detach()
            build()
        } else if pageChanged {
            Metrics.shared.record("html.reload")
            work.cancelAll()
            loadPage(in: web)
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
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let isMain = action.targetFrame?.isMainFrame ?? true
        let userLink = action.targetFrame == nil || (action.navigationType == .linkActivated && isMain)
        if userLink, followed(action, in: webView) { return .cancel }
        if isMain { return url.scheme == HtmlKit.scheme && url.host == HtmlKit.host && url.path == pageURL.path ? .allow : .cancel }
        let schemes = board.isRemote ? ["about", HtmlKit.scheme] : ["about", "data", "blob", HtmlKit.scheme]
        return schemes.contains(url.scheme ?? "") ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        probeSurface(webView)
        guard scrollY > 0 else { return }
        let y = scrollY
        Task { _ = try? await webView.callAsyncJavaScript("window.canvasKit?.restoreScroll(y)", arguments: ["y": y], contentWorld: .page) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView {
            loadPage(in: webView)
        } else {
            (webView.configuration.urlSchemeHandler(forURLScheme: HtmlKit.scheme) as? HtmlSchemeHandler)?.cancelHostReads()
            webView.load(URLRequest(url: pageURL))
        }
    }

    /// A new window the policy above let through (it opened as a link already when it could):
    /// never a web view of its own.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    private func followed(_ action: WKNavigationAction, in webView: WKWebView) -> Bool {
        guard !board.isRemote, let url = action.request.url, WebLink.isWeb(url),
              let click = (webView as? HtmlWebView)?.recentClick() else { return false }
        if click.union(action.modifierFlags).contains(.option) {
            ExternalOpen.open(url, because: "html \(object.id) link (⌥-click)", naming: true)
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
