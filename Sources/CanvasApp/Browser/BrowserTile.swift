import AppKit
import CanvasCore
import WebKit

/// A web page on the canvas. Every browser tile shares one website data store (`BrowserProfile`),
/// so they are one browser profile (cookies, logins) with separate screens. (Since macOS 12 WebKit
/// ignores process pools and all web views share one, so there is no pool to configure.)
///
/// The web view is created the first time the tile is live and stays in the tile, hidden while
/// nobody can see it there (the tile isn't live, or its window is minimized, covered, in a
/// background tab or on another Space), so WebKit treats the page as hidden: no
/// requestAnimationFrame or CSS animation, and timers throttled further the longer it stays
/// hidden (`hiddenPageDOMTimerThrottlingAutoIncreases`; `placePage`). A hidden page still commits
/// a frame for every DOM change, and each commit spins WebKit's display link in the app for a
/// moment (a page with a 1 s clock: ~15 wakeups/s), so after `releaseDelay` not live, and not
/// driven, it is released entirely and later rebuilt from `props.url`. The cmux subset
/// (BrowserAutomation.swift) can wake it without making it live; while an agent drives the page
/// it stays visible to WebKit (see `markDriven`).
@MainActor
final class BrowserTile: NSView, TileContent {
    static let chromeHeight: CGFloat = 32
    /// Cap on the cached page image (zoomed-out cards, `view.snapshot` covers), in pixels.
    static let snapshotPixelBudget: CGFloat = 1_500_000
    static let releaseDelay: TimeInterval = 120
    /// Minimum spacing between background snapshot refreshes of a busy page.
    static let refreshInterval: TimeInterval = 1
    /// How long a page counts as agent-driven after the last cmux command.
    static let drivenIdle: TimeInterval = 60
    /// Longest a command waits for a page it just made visible to present a frame.
    static let revealWait: TimeInterval = 0.5
    /// How long a released web view outlives its release (see `release`).
    static let closeDelay: TimeInterval = 2

    let objectID: ObjectID
    let board: Board
    private(set) var object: CanvasObject
    private(set) var webView: WKWebView?
    /// The loaded page's background luminance (`PageSurface`), kept while the page is detached.
    private(set) var surfaceLuminance: Double?
    private let chrome = BrowserChrome()
    /// The page area under the address bar, holding the web view: WebKit docks the Web Inspector
    /// inside the web view's superview (at its bottom, laid out from its bounds), so there it
    /// shares the page's room and never covers the address bar.
    private let pageHost = NSView()
    /// Covers the web view while `view.snapshot` renders (WebKit draws outside `cacheDisplay`).
    private let cover = NSImageView()
    private var cachedImage: NSImage?
    private var isLive = true
    private var releaseTimer: Timer?
    /// Set while an agent drives the page; fires `drivenIdle` after the last command.
    private var drivenTimer: Timer?
    private var observations: [NSKeyValueObservation] = []
    private var refreshScheduled = false
    /// Whether the current document reports activity (`setPageActivity`); each starts without.
    private var pageActivity = false
    private var lastRefresh = Date.distantPast
    private var readyWaiters: [@MainActor () -> Void] = []

    /// Navigations this tile started that haven't finished or failed (for load-state waits).
    var pendingNavigations: [WKNavigation] = []
    /// Navigations (ours or the page's) whose new document hasn't replaced the current one yet;
    /// until then the current document's ready state says nothing about the destination.
    var uncommittedNavigations: [WKNavigation] = []
    /// Automation waits parked until the page changes (navigation, DOM activity) or time runs out.
    private var changeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Who the page's URL changes and the tiles it opens are credited to.
    var credit = NavigationCredit()
    /// A tile the user opened from this page (their click on a `_blank` link or `window.open`
    /// button): the canvas shows and selects it.
    var onOpenedTile: ((ObjectID) -> Void)?
    /// Latest Hyper-hover answer, and the point whose answer is still wanted.
    private var hover: (point: CGPoint, element: WebMentions.Element)?
    private var hoverWanted: CGPoint?
    private var hoverInFlight = false
    /// The page's error count as it last reported it (`PageCapture`), and its own document's
    /// HTTP error status: the chrome's badge counts both.
    fileprivate var pageErrors = 0
    fileprivate var documentStatus = DocumentFailureTracker<ObjectIdentifier>()
    fileprivate var documentFailure: PageLogEntry? { documentStatus.current }
    /// The badge's list of the page's errors, while open.
    fileprivate var problemsList: PageProblemsView?
    /// The log of the page easl last released (`PageReport.previous`), read from it as it went
    /// (`previousRead` while that read runs), and the documents committed since the release: the
    /// page loaded again is the first; the one after it drops the old log.
    fileprivate var previousLoad: PageReport.Released?
    fileprivate var previousRead: Task<Void, Never>?
    fileprivate var commitsSinceRelease = 0
    /// A `file:line` in the error list opened code (`board.openForNavigation`); `existing` when
    /// a tile already showed it.
    var onOpenedCode: ((ObjectID, _ existing: Bool) -> Void)?
    /// The page that didn't load, shown in place of a blank page (`BrowserLoadFailure`), its
    /// address's failed loads in a row since the last fresh round of retries, and the pending
    /// automatic retry or watch.
    private(set) var loadFailure: BrowserLoadFailure?
    private let failureView = BrowserFailureView()
    private var failedInRow = 0
    private var retryTask: Task<Void, Never>?
    /// The canvas's browser tile view for an object: the tile made for a page's popup builds its
    /// web view from the configuration WebKit passes (`adoptPopup`), so the popup keeps its
    /// `window.opener`.
    var browserTile: ((ObjectID) -> BrowserTile?)?
    /// The tile whose page opened this one as a popup the user asked for: shown again when the
    /// popup's page closes it while the popup has the user's attention (`hasAttention`: the
    /// canvas's answer, selected or holding the keyboard).
    private var popupOpener: ObjectID?
    var hasAttention: ((ObjectID) -> Bool)?
    /// The profile the web view was built with (`BrowserProfile`); a changed `props.profile`
    /// rebuilds it.
    private var webViewProfile: String?
    /// The find bar (⌘F, Edit ▸ Find in Page…), and who had the keyboard before it.
    private var findBar: CodeFindBar?
    private weak var findPreviousResponder: NSResponder?
    /// The files behind a local page, while `props.reloadOnChange` is on (`LocalPageWatch`).
    private var pageWatch: (directory: URL, watch: LocalPageWatch)?
    /// A counted file change arrived while the page loaded: it reloads once that load ends.
    private var reloadPending = false

    init(object: CanvasObject, board: Board) {
        objectID = object.id
        self.board = board
        self.object = object
        zoom = CGFloat(object.zoom)
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        chrome.autoresizingMask = []
        chrome.onBack = { [weak self] in
            self?.credit.user()
            self?.webView?.goBack()
        }
        chrome.onForward = { [weak self] in
            self?.credit.user()
            self?.webView?.goForward()
        }
        chrome.onSubmit = { [weak self] text in
            self?.credit.user()
            self?.submitAddress(text)
        }
        chrome.onEscape = { [weak self] in self?.leave() }
        chrome.onProblems = { [weak self] in self?.toggleProblems() }
        chrome.onDownload = { [weak self] in self?.revealDownload() }
        chrome.onExtensions = { [weak self] anchor in
            guard let self else { return }
            BrowserExtensions.buttonClicked(self, anchor: anchor)
        }
        chrome.onReload = { [weak self] in
            guard let self else { return }
            self.credit.user()
            if self.loadFailure == nil, let webView = self.webView, webView.isLoading { return webView.stopLoading() }
            self.reload()
        }
        chrome.setAddress(object.props["url"]?.string ?? "")
        addSubview(chrome)
        addSubview(pageHost)
        cover.imageScaling = .scaleAxesIndependently
        cover.autoresizingMask = [.width, .height]
        cover.isHidden = true
        failureView.isHidden = true
        failureView.onRetry = { [weak self] in
            self?.credit.user()
            self?.retryFailedLoad(restart: true)
        }
        addSubview(failureView)
        addSubview(cover)
        layoutParts()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    /// The tile's content zoom (`props.zoom`): the page draws at it, like a browser's page zoom,
    /// while the address bar stays its size on the canvas (it takes `chromeHeight / zoom` of the
    /// view's points, drawn at `zoom` times by the tile, and its bounds undo the zoom).
    private var zoom: CGFloat

    /// The address bar's height in this view's points.
    private var chromeExtent: CGFloat { Self.chromeHeight / zoom }

    private var pageFrame: NSRect {
        NSRect(x: 0, y: chromeExtent, width: bounds.width, height: max(0, bounds.height - chromeExtent))
    }

    /// The web view's frame in `pageHost`: the page area, its size rounded up to whole device pixels at the
    /// tile's on-screen scale (the sliver past the tile is clipped). WebKit sizes the page's
    /// viewport from the view's size in device pixels, rounded to whole pixels, then scaled
    /// back and cut to whole CSS pixels: at 90% zoom a 648 pt tile is 1166.4 px, rounded to
    /// 1166, which comes back as 647.8, and `innerWidth` was 647. Rounded up first it is the
    /// tile's body width (and `innerHeight` its body height); when rounding up would pass the
    /// next whole point (on-screen scale below 1 px/pt) the size stays as it is.
    private var webViewFrame: NSRect {
        let page = pageFrame
        let unit = convert(NSSize(width: 1, height: 1), to: nil)
        let backing = window?.backingScaleFactor ?? 2
        func snapped(_ length: CGFloat, _ pixelsPerPoint: CGFloat) -> CGFloat {
            guard pixelsPerPoint > 0 else { return length }
            let up = (length * pixelsPerPoint - 0.001).rounded(.up) / pixelsPerPoint
            return up.rounded(.down) == length.rounded(.down) ? up : length
        }
        return NSRect(x: 0, y: 0, width: snapped(page.width, abs(unit.width) * backing),
                      height: snapped(page.height, abs(unit.height) * backing))
    }

    /// The canvas zoom settled at a new value: the web view's device-pixel size changed.
    func zoomChanged() {
        if let webView, webView.superview === pageHost { webView.frame = webViewFrame }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutParts()
    }

    /// A detached web view still gets the tile's size, so pages lay out as they will be seen.
    private func layoutParts() {
        chrome.frame = NSRect(x: 0, y: 0, width: bounds.width, height: chromeExtent)
        let chromeBounds = NSSize(width: bounds.width * zoom, height: Self.chromeHeight)
        if chrome.bounds.size != chromeBounds {
            chrome.setBoundsSize(chromeBounds)
            // Its buttons and field lay out from its bounds, which a frame change alone leaves scaled.
            chrome.resizeSubviews(withOldSize: chrome.frame.size)
        }
        cover.frame = pageFrame
        failureView.frame = pageFrame
        pageHost.frame = pageFrame
        webView?.frame = webViewFrame
        placeProblems()
        placeFindBar()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            // Closed or its canvas went away: nothing will show or drive this page again.
            BrowserExtensions.closed(self)
            release()
            return
        }
        BrowserExtensions.opened(self)
        // A driven page moves to the stage while its window is off screen (minimized, a
        // background tab, the app hidden) and back when it returns.
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            center.addObserver(self, selector: #selector(windowVisibilityChanged), name: name, object: window)
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.addObserver(self, selector: #selector(windowVisibilityChanged), name: name, object: NSApp)
        }
        // A closed tab or window keeps its views (opening the folder again shows them), so the
        // page goes with the close and comes back from `props.url` when the window does.
        center.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)
        // The frame view starts out live and only reports changes, and the canvas decides
        // liveness on the next main-queue pass; look after that pass so offscreen tiles never load.
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isLive, self.window != nil else { return }
                    self.attach()
                }
            }
        }
    }

    // MARK: Web view lifecycle

    @discardableResult
    func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let view = makeWebView()
        load(object.props["url"]?.string ?? "about:blank")
        return view
    }

    /// The tile's web view: a fresh one in the tile's profile, or for a popup (`adoptPopup`) one
    /// from the configuration WebKit passed, which carries the opener (`window.opener`), its
    /// profile's store and settings. The popup gets a user content controller of its own: the
    /// one it inherits answers to the opener's tile (its page log, its activity). Either way the
    /// page runs the user's Safari extensions (`BrowserExtensions`).
    private func makeWebView(popup: WKWebViewConfiguration? = nil) -> WKWebView {
        let configuration = popup ?? WKWebViewConfiguration()
        // A popup's tile names its opener's profile (`openPopup`), whose store it carries.
        webViewProfile = BrowserProfile.name(in: object.props)
        if popup == nil {
            configuration.websiteDataStore = BrowserProfile.store(named: webViewProfile)
        } else {
            configuration.userContentController = WKUserContentController()
        }
        BrowserExtensions.attach(to: configuration)
        configuration.applicationNameForUserAgent = BrowserProfile.applicationName
        // The page's context menu offers Inspect Element (Web Inspector), as in Safari with
        // its Develop menu on.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.preferences.setValue(true, forKey: "hiddenPageDOMTimerThrottlingAutoIncreases")
        // A video's or game's fullscreen button: WebKit's own fullscreen window, Esc leaves it.
        configuration.preferences.isElementFullscreenEnabled = true
        WebMentions.install(on: configuration)
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: BrowserScripts.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: BrowserScripts.world))
        controller.add(PageMessages { [weak self] message in
            guard let kind = message.body as? String else { return }
            self?.pageMessage(kind)
        }, contentWorld: BrowserScripts.world, name: BrowserScripts.messageName)
        // The page's console, errors and requests from its first line on (`PageLog`).
        controller.addUserScript(WKUserScript(source: PageCapture.source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.add(PageMessages { [weak self] message in
            // The page's world can post anything here: only a plausible error count counts.
            guard let self, message.frameInfo.isMainFrame, let count = (message.body as? NSNumber)?.doubleValue,
                  count.isFinite, count >= 0, count < 1e9 else { return }
            self.pageErrors = Int(count)
            self.problemsChanged()
        }, contentWorld: .page, name: PageCapture.messageName)
        let view = BrowserWebView(frame: webViewFrame, configuration: configuration)
        view.onUserInput = { [weak self] in
            guard let self else { return }
            self.credit.user()
            self.closeProblems()
            BrowserExtensions.activated(self)
        }
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = true
        webView = view
        observations = [
            view.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.commitTitle(view.title)
                    BrowserExtensions.changed(self, .title)
                }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Same-document navigations (pushState, back/forward between its entries)
                    // never "finish"; commit them here, or when the load they ran in ends.
                    if !view.isLoading { self.commitURL() }
                    self.signalChange()
                    BrowserExtensions.changed(self, .url)
                }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.chrome.isLoading = view.isLoading
                    if !view.isLoading { self.commitURL() }
                    if !view.isLoading, self.reloadPending { self.filesChanged() }
                    self.signalChange()
                    BrowserExtensions.changed(self, .loading)
                }
            },
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.chrome.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.chrome.canGoForward = view.canGoForward }
            },
        ]
        if !isLive { scheduleRelease() }
        // A page back after a release: the chrome says it reloaded.
        if previousLoad != nil { problemsChanged() }
        updatePageWatch()
        return view
    }

    /// A page's popup lands in this new tile: its web view is built from `configuration` and
    /// returned to WebKit, which loads the popup into it. Nil when the tile has a page already.
    /// When its page closes it (`webViewDidClose`), a popup the user opened shows `opener` again.
    func adoptPopup(_ configuration: WKWebViewConfiguration, opener: ObjectID, returnsToOpener: Bool) -> WKWebView? {
        guard webView == nil else { return nil }
        popupOpener = returnsToOpener ? opener : nil
        return makeWebView(popup: configuration)
    }

    /// Shows the web view in the tile, creating it on first use.
    private func attach() {
        ensureWebView()
        placePage()
        scheduleSnapshotRefresh()
    }

    /// Where the web view belongs: in the stage while an agent drives it and the tile can't show
    /// it; otherwise in the tile, hidden unless someone can see it there (`pageOnScreen`) or an
    /// agent drives it, until it is released. WebKit renders a hidden view's page no more: in a
    /// minimized window (or out of every window after the stage) a clock on the page had it
    /// commit a frame, and start a display link, every second. Only a page on screen reports
    /// activity (`setPageActivity`).
    private func placePage() {
        guard let webView else { return }
        let shown = isLive && window?.isVisible == true
        if drivenTimer != nil, !shown {
            releaseTimer?.invalidate()
            releaseTimer = nil
            webView.isHidden = false
            if !WebStage.isParked(webView) { WebStage.park(webView, frame: webViewFrame) }
        } else {
            if webView.superview !== pageHost {
                webView.frame = webViewFrame
                pageHost.addSubview(webView)
            }
            webView.isHidden = visibility == .hidden
            if isLive {
                releaseTimer?.invalidate()
                releaseTimer = nil
            } else if releaseTimer == nil, drivenTimer == nil {
                scheduleRelease()
            }
        }
        setPageActivity(pageOnScreen)
    }

    /// The page is in its live tile, in a window on screen and not covered: someone can see it.
    private var pageOnScreen: Bool {
        guard isLive, let webView, webView.superview === pageHost, let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    @objc private func windowVisibilityChanged() {
        // A board window closed and opened again: its tiles are tabs again (`BrowserExtensions`).
        if window?.isVisible == true { BrowserExtensions.opened(self) }
        // The board's window opened again after a close (`windowWillClose`): the page comes back.
        if webView == nil, isLive, window?.isVisible == true { return attach() }
        placePage()
        // `occlusionState` lags the miniaturize notifications: look again on the next turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.placePage()
                self.scheduleSnapshotRefresh()
                self.failedPageShown(self.pageOnScreen)
            }
        }
    }

    @objc private func windowWillClose() {
        release()
    }

    /// Page-activity reporting (DOM observer, messages, and the snapshot refreshes they cause)
    /// runs only while the page is on screen: in a minimized or covered window a clock on the
    /// page otherwise had WebKit render a snapshot every second.
    private func setPageActivity(_ on: Bool) {
        guard let webView, on != pageActivity else { return }
        pageActivity = on
        Task { _ = try? await webView.callAsyncJavaScript(BrowserScripts.ensure + "return window.__canvasCmux.setActivity(on)", arguments: ["on": on], in: nil, contentWorld: BrowserScripts.world) }
    }

    /// Drops the web view (its page, history, and web content process share) but keeps the image
    /// and the page's log (`previousLoad`, read from the page as it goes), so what it logged
    /// stays readable through `object.get` and the error list after the page is gone.
    private func release() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        drivenTimer?.invalidate()
        drivenTimer = nil
        // A failed page stays failed until the web view comes back and tries again.
        retryTask?.cancel()
        retryTask = nil
        guard let webView else { return }
        let failure = documentFailure
        let releasedAt = Date()
        commitsSinceRelease = 0
        previousRead = Task { [weak self] in
            let log = await Self.pageLog(of: webView, failure: failure)
            guard let self else { return }
            self.previousRead = nil
            // A page that logged nothing readable (a failed load) leaves the log before it.
            if let log, self.commitsSinceRelease <= 1 { self.previousLoad = PageReport.Released(log: log, at: releasedAt) }
            self.problemsChanged()
        }
        pageErrors = 0
        documentStatus.reset()
        pageActivity = false
        observations = []
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        // Closed in the same breath as the stop, a page WebKit treated as visible (the stage) with
        // a navigation in flight leaves a dangling display-link client in WebKit (macOS 26), which
        // crashes the app while its window is minimized; letting the stop settle first doesn't.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDelay) { _ = webView }
        self.webView = nil
        pageWatch = nil
        reloadPending = false
        closeFind()
        pendingNavigations = []
        uncommittedNavigations = []
        hover = nil
        signalChange()
    }

    private func scheduleRelease() {
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: Self.releaseDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.releaseTimer = nil
                guard !self.isLive, self.drivenTimer == nil else { return }
                self.release()
            }
        }
    }

    // MARK: Agent-driven pages

    /// Keeps the page visible to WebKit while an agent drives it, so requestAnimationFrame, timers
    /// and IntersectionObserver run as they would for a user: window occlusion detection is off
    /// (another Space or a covered window hides the page too), and while the tile can't show the
    /// page (offscreen, its window minimized or in a background tab, the app hidden) the web view
    /// waits in `WebStage`. `drivenIdle` after the last command the normal hide/release policy
    /// resumes. A page this made visible gets up to `revealWait` to present a frame first, so
    /// the command that follows already sees `visibilityState` "visible".
    func markDriven() async {
        let webView = ensureWebView()
        let wasVisible = pageOnScreen
        let starting = drivenTimer == nil
        drivenTimer?.invalidate()
        drivenTimer = Timer.scheduledTimer(withTimeInterval: Self.drivenIdle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endDriven() }
        }
        placePage()
        guard starting else { return }
        WebStage.setOcclusionDetection(false, on: webView)
        if window?.occlusionState.contains(.visible) == false { refreshOcclusion(webView) }
        if !wasVisible { await presented(webView, within: Self.revealWait) }
    }

    /// Until the page's next frame is on screen, or `limit` passes.
    private func presented(_ webView: WKWebView, within limit: TimeInterval) async {
        @MainActor final class Once { var done = false }
        let once = Once()
        await withCheckedContinuation { continuation in
            let finish: @MainActor () -> Void = {
                guard !once.done else { return }
                once.done = true
                continuation.resume()
            }
            WebStage.afterNextPresentationUpdate(webView, finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { MainActor.assumeIsolated { finish() } }
        }
    }

    private func endDriven() {
        drivenTimer = nil
        guard let webView else { return }
        WebStage.setOcclusionDetection(true, on: webView)
        // Back from the stage into its tile, or hidden there when nobody can see it.
        let inTile = webView.superview === pageHost
        placePage()
        if inTile { refreshOcclusion(webView) }
    }

    /// WebKit re-reads occlusion only on the next window change; re-parenting in the tile forces it.
    private func refreshOcclusion(_ webView: WKWebView) {
        guard webView.superview === pageHost else { return }
        webView.removeFromSuperview()
        pageHost.addSubview(webView)
    }

    func load(_ address: String) {
        let webView = webView ?? makeWebView()
        guard let url = BrowserURL.normalize(address) else { return }
        let navigation = url.isFileURL
            ? webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            : webView.load(URLRequest(url: url))
        track(navigation)
    }

    func track(_ navigation: WKNavigation?) {
        guard let navigation else { return }
        pendingNavigations.append(navigation)
        uncommittedNavigations.append(navigation)
    }

    private func submitAddress(_ text: String) {
        guard let url = BrowserURL.normalize(text) else { return NSSound.beep() }
        load(url.absoluteString)
        window?.makeFirstResponder(webView)
    }

    /// The page's committed URL into the address bar and `props.url`, credited per `credit`.
    private func commitURL() {
        guard let url = webView?.url?.absoluteString else { return }
        if !chrome.isEditing { chrome.setAddress(url) }
        guard url != object.props["url"]?.string else { return }
        let props = JSONValue.object(["url": .string(url)])
        switch credit.actor() {
        case .agent(let tile): _ = try? board.update(objectID, props: props, caller: tile)
        case let actor: _ = try? board.update(objectID, props: props, actor: actor)
        }
    }

    /// The page named itself: bookkeeping (`props.pageTitle`), not anyone's edit, so the tile's
    /// `rev` stays and an agent's own `title` keeps its place.
    private func commitTitle(_ title: String?) {
        guard let title, !title.isEmpty, title != object.props["pageTitle"]?.string else { return }
        try? board.writeBookkeeping(objectID, props: .object(["pageTitle": .string(title)]))
    }

    // MARK: Pages that don't load

    /// A main-frame load failed: the page area says so ("Can't reach localhost:5391 ·
    /// Connection refused", a Retry button) instead of staying blank, the old page's title
    /// goes (the title bar falls back to the address), and a local address tries again by
    /// itself (`BrowserLoadFailure.retryDelays`), then, while the tile is on screen, loads when
    /// its server answers (`watchInterval`). Quiet: no alert, no marker.
    private func loadFailed(_ error: Error, webView: WKWebView) {
        let error = error as NSError
        let failing = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url ?? object.props["url"]?.string.flatMap(BrowserURL.normalize)
        guard let url = failing else { return }
        let count = loadFailure?.url == url ? failedInRow + 1 : 1
        guard let failure = BrowserLoadFailure(url: url, domain: error.domain, code: error.code, description: error.localizedDescription, attempt: count) else { return }
        failedInRow = count
        loadFailure = failure
        failureView.show(failure)
        failureView.isHidden = false
        if !chrome.isEditing { chrome.setAddress(url.absoluteString) }
        if object.props["pageTitle"] != nil { try? board.writeBookkeeping(objectID, props: .object(["pageTitle": .null])) }
        NSLog("easl: browser %@ %@", objectID, failure.summary)
        retryTask?.cancel()
        retryTask = nil
        if let delay = failure.retryDelay {
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.retryFailedLoad(restart: false)
            }
        } else if failure.watches, pageOnScreen {
            retryTask = Task { [weak self] in
                guard await Self.waitForServer(at: url) else { return }
                self?.retryFailedLoad(restart: true)
            }
        }
    }

    /// True once something answers at `url` (any HTTP response to a HEAD request, asked every
    /// `BrowserLoadFailure.watchInterval`); false when cancelled first. Loads no page.
    private nonisolated static func waitForServer(at url: URL) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 2)
        request.httpMethod = "HEAD"
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(BrowserLoadFailure.watchInterval))
            guard !Task.isCancelled else { return false }
            if (try? await URLSession.shared.data(for: request)) != nil { return true }
        }
        return false
    }

    /// Loads the failed address again; the failure stays up until the page commits, so a
    /// retry that fails again never flashes a blank page. `restart` (Retry, Reload, the page
    /// coming back into view) begins a fresh round of automatic retries.
    private func retryFailedLoad(restart: Bool) {
        guard let failure = loadFailure else { return }
        if restart { failedInRow = 0 }
        retryTask?.cancel()
        retryTask = nil
        failureView.showRetrying()
        load(failure.url.absoluteString)
    }

    /// Reload, `browser.reload` and `object.reload`: the page loads again; one that failed to
    /// load asks its address again, from a fresh round of retries.
    func reload() {
        if loadFailure != nil { return retryFailedLoad(restart: true) }
        track(ensureWebView().reload())
    }

    /// A failed page watches for its server only while someone can see it; back in view (its
    /// tile, its window) after its retries ran out or its watch stopped, it tries again at once.
    private func failedPageShown(_ shown: Bool) {
        guard loadFailure != nil else { return }
        if shown {
            if retryTask == nil, webView?.isLoading != true { retryFailedLoad(restart: true) }
        } else if loadFailure?.watches == true {
            retryTask?.cancel()
            retryTask = nil
        }
    }

    /// The page committed (or another address was asked for): the failure is over.
    private func clearLoadFailure() {
        retryTask?.cancel()
        retryTask = nil
        guard loadFailure != nil else { return }
        loadFailure = nil
        failureView.isHidden = true
    }

    /// A link opened beside this one (⌘-click, `target=_blank`), credited like a navigation, in
    /// this tile's profile: a tile on the board already showing that address in the same profile
    /// is reused (`Board.openLink`; a second click while the first tile appears gets it too).
    /// One the user opened (`onOpenedTile`) is shown and selected, since it may be out of view.
    private func openTile(_ url: URL) {
        let actor = credit.actor()
        let caller: ObjectID? = if case .agent(let tile) = actor { tile } else { nil }
        let opened = board.openLink(url, near: objectID, caller: caller, props: profileProps)
        if opened.existing { NSLog("easl: browser %@ link %@ reuses %@", objectID, url.absoluteString, opened.object.id) }
        if actor == .user { onOpenedTile?(opened.object.id) }
    }

    /// `props.profile` for the tiles this page opens: they share its cookies and logins.
    private var profileProps: [String: JSONValue] {
        webViewProfile.map { ["profile": .string($0)] } ?? [:]
    }

    /// A page's `window.open` (a sign-in popup, a share dialog): a new tile beside this one
    /// whose web view WebKit opens the popup in, so the popup's `window.opener` is this page and
    /// its `postMessage` reaches it; the popup's `window.close()` closes the tile
    /// (`webViewDidClose`). Nil (the popup loads as a plain tile, without an opener) when the
    /// canvas has no tile view for it.
    private func openPopup(_ url: URL?, configuration: WKWebViewConfiguration) -> WKWebView? {
        let actor = credit.actor()
        let size = Board.defaultSize(.browser)
        let caller: ObjectID? = if case .agent(let tile) = actor { tile } else { nil }
        let address = url.map(\.absoluteString).flatMap { $0.isEmpty ? nil : $0 } ?? "about:blank"
        let opened = board.create(type: .browser, props: .object(["url": .string(address)].merging(profileProps) { $1 }),
                                  frame: board.place(width: size.w, height: size.h, near: objectID), caller: caller)
        NSLog("easl: browser %@ opened popup %@ (%@)", objectID, opened.id, address)
        if actor == .user { onOpenedTile?(opened.id) }
        return browserTile?(opened.id)?.adoptPopup(configuration, opener: objectID, returnsToOpener: actor == .user)
    }

    /// Puts keyboard focus in the address field (a new, empty tile the user made; ⌘L).
    func focusAddress() {
        chrome.focusAddress()
    }

    /// The installed extensions changed (loaded, removed, an action's icon): the address bar's
    /// button follows.
    func extensionsChanged() {
        chrome.setExtensions(BrowserExtensions.button(for: self))
    }

    /// Where an extension's popup hangs: its button, or the address bar while that's hidden.
    var extensionsAnchor: NSView { chrome.extensions.isHidden ? chrome : chrome.extensions }

    /// Return on the selected tile: the page takes the keyboard (the address field while there
    /// is no page); ⌘L goes to the address field, ⌘Esc (Leave Tile) back to the canvas. Esc is
    /// the page's (games, dialogs and menus close or pause on it), as it is a terminal program's.
    func enterKeyboard() -> Bool {
        guard let webView, webView.url != nil, webView.url?.absoluteString != "about:blank" else {
            focusAddress()
            return true
        }
        return window?.makeFirstResponder(webView) == true
    }

    private func leave() {
        (enclosingScrollView as? CanvasView)?.leaveTile(objectID)
    }

    /// A key the page didn't handle comes back up the responder chain, whose next stops past the
    /// tile are the canvas's: it stays here, so while the page has the keyboard no key (Esc,
    /// Delete, Return, a tool's letter) acts on the canvas. ⌘Esc leaves (`leaveTile`), taken by
    /// the window before the page sees it.
    override func keyDown(with event: NSEvent) {}

    /// The page's unhandled Esc also comes back as `cancelOperation`: it stays here too, not
    /// clearing the canvas's selection.
    override func cancelOperation(_ sender: Any?) {}

    // MARK: Change signals (automation waits, snapshot freshness)

    /// Resumes every parked wait; each re-checks its own condition.
    func signalChange() {
        let waiters = changeWaiters.values
        changeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Parks until the page changes or `deadline` passes.
    func nextChange(before deadline: Date) async {
        let id = UUID()
        await withCheckedContinuation { continuation in
            changeWaiters[id] = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) { [weak self] in
                MainActor.assumeIsolated { self?.changeWaiters.removeValue(forKey: id)?.resume() }
            }
        }
    }

    fileprivate func pageMessage(_ kind: String) {
        signalChange()
        // Each new document starts with activity reporting off.
        if kind == "ready" {
            pageActivity = false
            setPageActivity(pageOnScreen)
        }
        if kind != "ready" { scheduleSnapshotRefresh() }
    }

    /// Keeps `cachedImage` close to what's on screen, at most once per `refreshInterval`.
    func scheduleSnapshotRefresh() {
        guard !refreshScheduled, pageOnScreen else { return }
        refreshScheduled = true
        let delay = max(0.25, Self.refreshInterval - Date().timeIntervalSince(lastRefresh))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.refreshSnapshot() }
        }
    }

    private func refreshSnapshot() {
        refreshScheduled = false
        guard pageOnScreen, let webView, webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        lastRefresh = Date()
        let size = webView.bounds.size
        let scale = window?.backingScaleFactor ?? 2
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(min(size.width, (Self.snapshotPixelBudget * size.width / size.height).squareRoot() / scale)))
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self, let image else { return }
                self.cachedImage = image
            }
        }
    }

    // MARK: Mentions

    /// A point in this view → CSS pixels in the page's viewport; nil over the chrome.
    private func pagePoint(_ point: NSPoint) -> CGPoint? {
        guard let webView, webView.superview === pageHost else { return nil }
        var local = webView.convert(point, from: self)
        guard webView.bounds.contains(local) else { return nil }
        if !webView.isFlipped { local.y = webView.bounds.height - local.y }
        let zoom = webView.pageZoom * webView.magnification
        return CGPoint(x: local.x / zoom, y: local.y / zoom)
    }

    private func viewRect(_ pageRect: CGRect) -> NSRect? {
        guard let webView, webView.superview === pageHost else { return nil }
        let zoom = webView.pageZoom * webView.magnification
        var rect = NSRect(x: pageRect.minX * zoom, y: pageRect.minY * zoom, width: pageRect.width * zoom, height: pageRect.height * zoom)
        if !webView.isFlipped { rect.origin.y = webView.bounds.height - rect.maxY }
        return convert(rect.intersection(webView.bounds), from: webView)
    }

    private func mention(_ element: WebMentions.Element) -> MentionTarget {
        let url = webView?.url?.absoluteString ?? object.props["url"]?.string ?? ""
        return .dom(object: objectID, url: url, selector: element.selector, text: element.text.isEmpty ? nil : element.text, point: element.point)
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        if let problem = problemMention(at: point) { return problem }
        guard let page = pagePoint(point) else { return nil }
        if hover?.point != page { requestHover(at: page) }
        guard let hover, hover.element.rect.contains(page) else { return nil }
        return mention(hover.element)
    }

    /// One element lookup in flight at a time; while it runs only the latest point is kept.
    private func requestHover(at point: CGPoint) {
        hoverWanted = point
        guard !hoverInFlight else { return }
        hoverInFlight = true
        Task { [weak self] in
            while let self, let point = self.hoverWanted, let webView = self.webView {
                self.hoverWanted = nil
                let element = await WebMentions.element(at: point, in: webView)
                let changed = element != self.hover?.element
                self.hover = element.map { (point, $0) }
                if changed { NotificationCenter.default.post(name: .tileMentionHoverChanged, object: self) }
            }
            self?.hoverInFlight = false
        }
    }

    func resolveMention(at point: NSPoint) async -> MentionTarget? {
        if let problem = problemMention(at: point) { return problem }
        guard let page = pagePoint(point), let webView,
              let element = await WebMentions.element(at: page, in: webView, pixel: true) else { return nil }
        return mention(element)
    }

    /// Edit › Mention: the page's text selection (the element holding it, with the selected
    /// text); nil without one: the whole tile.
    func keyboardMention(hasKeyboard: Bool) async -> MentionTarget? {
        guard let webView, let element = await WebMentions.selection(in: webView) else { return nil }
        return mention(element)
    }

    func pageElements(in rect: NSRect) async -> PageElements? {
        guard let webView, webView.superview === pageHost else { return nil }
        var local = webView.convert(rect, from: self).intersection(webView.bounds)
        guard !local.isNull, local.width > 0, local.height > 0 else { return nil }
        if !webView.isFlipped { local.origin.y = webView.bounds.height - local.maxY }
        let zoom = webView.pageZoom * webView.magnification
        let page = CGRect(x: local.minX / zoom, y: local.minY / zoom, width: local.width / zoom, height: local.height / zoom)
        guard let found = await WebMentions.elements(in: page, in: webView) else { return nil }
        let url = webView.url?.absoluteString ?? object.props["url"]?.string ?? ""
        return PageElements(url: url, elements: found.elements.map { .init(selector: $0.selector, text: $0.text) }, more: found.more)
    }

    var headerHeight: CGFloat { chromeExtent }

    func outline(for target: MentionTarget) -> NSRect? {
        if case .console(_, _, let entry) = target { return problemOutline(entry) }
        guard case .dom(_, _, let selector, _, _) = target, let hover, hover.element.selector == selector else { return nil }
        return viewRect(hover.element.rect)
    }

    // MARK: TileContent

    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        if live {
            attach()
        } else {
            readyWaiters.removeAll()
            placePage()
        }
        failedPageShown(pageOnScreen)
    }

    func whenLiveReady(_ ready: @escaping @MainActor () -> Void) {
        readyWaiters.append(ready)
        checkReady()
    }

    /// Ready once the attached page has loaded and that frame is on screen.
    private func checkReady() {
        guard !readyWaiters.isEmpty, isLive, let webView, webView.superview === pageHost, !webView.isLoading else { return }
        WebStage.afterNextPresentationUpdate(webView) { [weak self] in
            guard let self else { return }
            let waiters = self.readyWaiters
            self.readyWaiters.removeAll()
            for ready in waiters { ready() }
        }
    }

    /// The address bar and the page. Rendering counts as driving the page (`markDriven`): one
    /// that isn't loaded, or that its tile can't show now (offscreen, its window minimized or in
    /// a background tab), loads in the stage and is waited for until the render's deadline.
    func render(_ request: TileRenderRequest) async -> TileRender {
        await markDriven()
        // A page that failed is asked again (its server may be up by now) before it's drawn.
        if webView?.isLoading != true { retryFailedLoad(restart: true) }
        if let webView { await settle(webView) }
        return await capture(request)
    }

    /// The zoomed-out card shows the page as it is; only an agent's render loads one.
    func cardSnapshot(_ deliver: @escaping @MainActor (NSImage?) -> Void) {
        let request = TileRenderRequest(size: bounds.size, scale: TileFrameView.cardPixelsPerPoint, full: false,
                                        appearance: window?.effectiveAppearance ?? NSApp.effectiveAppearance)
        Task { @MainActor in
            await MainTurns.next()
            let render = await self.capture(request)
            deliver(render.state == .rendered ? render.image : nil)
        }
    }

    /// Until the page has loaded and that frame is presented, or the render is cancelled.
    private func settle(_ webView: WKWebView) async {
        while self.webView === webView, webView.isLoading || !pendingNavigations.isEmpty {
            guard !Task.isCancelled else { return }
            await nextChange(before: Date().addingTimeInterval(0.25))
        }
        guard !Task.isCancelled, self.webView === webView else { return }
        await presented(webView, within: 1)
    }

    /// The address bar and the page as loaded now; a page not loaded yet shows its last capture,
    /// and one that failed to load shows what the tile shows (`loadFailure`), with the reason.
    private func capture(_ request: TileRenderRequest) async -> TileRender {
        let bar = request.image(of: chrome)
        if let loadFailure {
            if failureView.frame.size != pageFrame.size { failureView.frame = pageFrame }
            let failed = request.image(of: failureView)
            let image = request.image { bounds in
                NSColor.textBackgroundColor.setFill()
                bounds.fill()
                bar?.drawUpright(in: NSRect(x: 0, y: 0, width: bounds.width, height: chromeExtent))
                failed?.drawUpright(in: NSRect(x: 0, y: chromeExtent, width: bounds.width, height: max(0, bounds.height - chromeExtent)))
            }
            return TileRender(image: image, contentSize: request.size, state: .rendered, reason: loadFailure.summary)
        }
        var page: NSImage?
        var reason: String?
        // A page hidden in its tile (not live) draws nothing new: its last capture stands in.
        if let webView, webView.window != nil, !webView.isHiddenOrHasHiddenAncestor, !webView.isLoading, webView.bounds.width > 0, webView.bounds.height > 0 {
            page = try? await webView.takeSnapshot(configuration: WKSnapshotConfiguration())
            if page == nil { reason = "the page did not produce a snapshot" }
        } else {
            reason = webView?.isLoading == true ? "the page is still loading" : "the page isn't loaded"
            if cachedImage != nil { reason! += "; showing its last capture" }
        }
        let shown = page ?? cachedImage
        let image = request.image { bounds in
            NSColor.textBackgroundColor.setFill()
            bounds.fill()
            bar?.drawUpright(in: NSRect(x: 0, y: 0, width: bounds.width, height: chromeExtent))
            shown?.drawUpright(in: NSRect(x: 0, y: chromeExtent, width: bounds.width, height: max(0, bounds.height - chromeExtent)))
        }
        return TileRender(image: image, contentSize: request.size, state: page == nil ? .placeholder : .rendered, reason: page == nil ? reason : nil)
    }

    func showSnapshot(_ show: Bool) {
        // A failed page's state is drawn by AppKit, which `cacheDisplay` captures as it is.
        let covering = show && loadFailure == nil && webView?.superview === pageHost && cachedImage != nil
        cover.image = covering ? cachedImage : nil
        cover.isHidden = !covering
    }

    var takesKeyboardFocus: Bool { true }

    /// Someone else changed `props.url` (an agent's object.update): go there, credited to them.
    /// Another `profile` builds the page again in that profile's store (from `props.url`).
    func update(_ object: CanvasObject) {
        let previous = self.object.props["url"]?.string
        self.object = object
        if CGFloat(object.zoom) != zoom {
            zoom = CGFloat(object.zoom)
            layoutParts()
        }
        if webView != nil, BrowserProfile.name(in: object.props) != webViewProfile {
            NSLog("easl: browser %@ now in profile %@", objectID, BrowserProfile.name(in: object.props) ?? "default")
            release()
            if isLive, window != nil { attach() }
            return
        }
        updatePageWatch()
        guard let url = object.props["url"]?.string, url != previous else { return }
        // A released page reloads from props.url when it comes back.
        guard let webView else { return chrome.setAddress(url) }
        guard url != webView.url?.absoluteString else { return }
        if case .agent(let tile) = object.updatedBy { credit.agent(tile) } else { credit.user() }
        load(url)
    }

    // MARK: Reload when files change

    /// Whether the page is one `props.reloadOnChange` can apply to (`LocalPage`).
    var servedLocally: Bool {
        pageURL.flatMap(URL.init(string:)).map(LocalPage.isLocal) ?? false
    }

    /// Watches the files behind the page while it has a web view and `props.reloadOnChange` is
    /// on; any change reloads it. A page that leaves for another address follows the address.
    private func updatePageWatch() {
        let wanted = webView != nil && object.props["reloadOnChange"]?.bool == true
            ? pageURL.flatMap(URL.init(string:)).flatMap { LocalPage.directory(for: $0, boardRoot: board.root) } : nil
        guard wanted != pageWatch?.directory else { return }
        pageWatch = nil
        reloadPending = false
        guard let wanted else { return }
        guard let watch = LocalPageWatch(directory: wanted, onChange: { [weak self] in self?.filesChanged() }) else { return }
        pageWatch = (wanted, watch)
        NSLog("easl: browser %@ reloads when files in %@ change", objectID, wanted.path)
    }

    /// A counted change reloads the page; one that arrives while the page loads (a reload still
    /// fetching, an agent's second save) waits, and the page reloads once more when that load ends.
    private func filesChanged() {
        guard let webView, pageWatch != nil else { return }
        guard !webView.isLoading else { return reloadPending = true }
        reloadPending = false
        NSLog("easl: browser %@ reloading: files changed", objectID)
        credit.user()
        track(webView.reload())
    }

    // MARK: Print, find

    var canPrint: Bool { webView?.url != nil && window != nil }

    /// File ▸ Print Page…: the page through the print panel, as a sheet on the board window.
    func printPage() {
        guard let webView, let window else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        // WKWebView's operation view starts with an empty frame and prints blank pages.
        operation.view?.frame = webView.bounds
        operation.jobTitle = webView.title ?? pageURL ?? "Page"
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Edit ▸ Find in Page… (⌘F): a find bar at the top right of the page, with the selection or
    /// the last query; Return / ⇧Return go to the next or previous match (WebKit selects it and
    /// scrolls it into view), Esc closes it and gives the keyboard back.
    func showFind() {
        let bar = findBar ?? makeFindBar()
        if !bar.holdsKeyboard { findPreviousResponder = window?.firstResponder }
        bar.isHidden = false
        placeFindBar()
        window?.makeFirstResponder(bar.field)
        bar.field.selectText(nil)
        if !bar.field.stringValue.isEmpty { find(backward: false) }
    }

    private func makeFindBar() -> CodeFindBar {
        let bar = CodeFindBar(frame: NSRect(origin: .zero, size: CodeFindBar.size))
        bar.onChange = { [weak self] in self?.find(backward: false) }
        bar.onStep = { [weak self] backward in self?.find(backward: backward) }
        bar.onClose = { [weak self] in self?.closeFind() }
        addSubview(bar, positioned: .above, relativeTo: cover)
        findBar = bar
        return bar
    }

    private func placeFindBar() {
        guard let findBar else { return }
        let size = CodeFindBar.size
        findBar.frame = NSRect(x: max(0, bounds.width - size.width - 8), y: chromeExtent + 4, width: min(size.width, bounds.width), height: size.height)
    }

    private func find(backward: Bool) {
        guard let findBar, let webView else { return }
        let query = findBar.field.stringValue
        guard !query.isEmpty else { return findBar.show(status: "") }
        let configuration = WKFindConfiguration()
        configuration.backwards = backward
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(query, configuration: configuration) { [weak findBar] result in
            MainActor.assumeIsolated {
                guard let findBar, findBar.field.stringValue == query else { return }
                findBar.show(status: result.matchFound ? "" : "No results")
            }
        }
    }

    private func closeFind() {
        guard let findBar, !findBar.isHidden else { return }
        let hadKeyboard = findBar.holdsKeyboard
        findBar.isHidden = true
        if hadKeyboard, let window { CanvasView.returnKeyboard(to: findPreviousResponder, in: window) }
    }

    // MARK: Downloads

    /// The address bar's download pill (`BrowserDownloads`).
    func showDownload(_ status: BrowserDownloads.Status) {
        chrome.download = status
    }

    /// The pill clicked: a finished download shown in Finder; a failed one's pill goes.
    private func revealDownload() {
        guard let status = chrome.download else { return }
        switch status.state {
        case .finished: if let file = status.file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        case .failed: chrome.download = nil
        case .running: break
        }
    }

    /// File > New Browser Tile: asks for an address and hands it to `open` (which places the
    /// tile in view). A sheet, not an app-modal alert, so the sockets keep answering agents
    /// while the user types.
    static func promptForNew(in window: NSWindow, open: @escaping @MainActor (URL) -> Void) {
        let alert = NSAlert()
        alert.messageText = "New Browser Tile"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "localhost:3000 or https://…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let url = text.isEmpty ? URL(string: "about:blank") : BrowserURL.normalize(text) else { return NSSound.beep() }
            open(url)
        }
    }
}

extension BrowserTile: WKNavigationDelegate, WKUIDelegate {
    /// Schemes a page loads itself; anything else is another app's link (`openInOtherApp`).
    static let pageSchemes: Set<String> = ["http", "https", "about", "file", "data", "blob", "javascript", "webkit-extension", "safari-web-extension"]

    /// ⌥-click on a web link: the default browser (Safari, Chrome), as everywhere on the board.
    /// ⌘-click: a tile beside this one. A link marked `download`: a download. Another app's
    /// link (`zoommtg:`): that app, after asking.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        let scheme = url.scheme?.lowercased() ?? ""
        let web = scheme == "http" || scheme == "https"
        if navigationAction.navigationType == .linkActivated, web, navigationAction.modifierFlags.contains(.option) {
            ExternalOpen.open(url, because: "browser \(objectID) link (⌥-click)")
            return decisionHandler(.cancel)
        }
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command) {
            openTile(url)
            return decisionHandler(.cancel)
        }
        if !scheme.isEmpty, !Self.pageSchemes.contains(scheme) {
            // A subframe's (a tracking iframe's) never leaves the page.
            if navigationAction.targetFrame?.isMainFrame != false { openInOtherApp(url, from: navigationAction.sourceFrame) }
            if NSWorkspace.shared.urlForApplication(toOpen: url) != nil { return decisionHandler(.cancel) }
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    /// The page's own document with an HTTP error status is its first problem (`PageLog`), once
    /// its navigation commits (`DocumentFailureTracker`). A response the page can't show (a zip,
    /// a dmg) or one the server sends as an attachment downloads (`BrowserDownloads`).
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let attachment = disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment")
        if !navigationResponse.canShowMIMEType || attachment { return decisionHandler(.download) }
        if navigationResponse.isForMainFrame {
            let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 0
            documentStatus.responded(url: navigationResponse.response.url?.absoluteString ?? "", status: status)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        BrowserDownloads.shared.start(download, from: self)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        BrowserDownloads.shared.start(download, from: self)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if !uncommittedNavigations.contains(where: { $0 === navigation }) { uncommittedNavigations.append(navigation) }
        documentStatus.started()
        signalChange()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        uncommittedNavigations.removeAll { $0 === navigation }
        clearLoadFailure()
        commitURL()
        // The committed document's own HTTP error, or none; a page back from the back/forward
        // cache has no response of its own and takes its history entry's (Back from a 404: none).
        documentStatus.committed(into: webView.backForwardList.currentItem.map(ObjectIdentifier.init))
        // The page loaded again after a release is the first document since; the next one
        // (a navigation, a reload) leaves the released page's log behind.
        commitsSinceRelease += 1
        if commitsSinceRelease > 1 { previousLoad = nil }
        problemsChanged()
        signalChange()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished(navigation)
        commitURL()
        scheduleSnapshotRefresh()
        checkReady()
        probeSurface(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finished(navigation)
        checkReady()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finished(navigation)
        checkReady()
        if !chrome.isEditing, let url = webView.url?.absoluteString { chrome.setAddress(url) }
        loadFailed(error, webView: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pendingNavigations = []
        uncommittedNavigations = []
        track(webView.reload())
        signalChange()
    }

    /// A link with `target=_blank` opens a tile beside this one, as a ⌘-click does (no opener,
    /// as Safari gives such links); ⌥-click on one goes to the default browser. A script's
    /// `window.open` (a sign-in popup) gets a real web view in a new tile (`openPopup`), so the
    /// popup can talk back to this page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        if navigationAction.navigationType == .linkActivated, let url {
            let scheme = url.scheme?.lowercased()
            if navigationAction.modifierFlags.contains(.option), scheme == "http" || scheme == "https" {
                ExternalOpen.open(url, because: "browser \(objectID) link (⌥-click)")
            } else {
                openTile(url)
            }
            return nil
        }
        return openPopup(url, configuration: configuration)
    }

    /// The page closed its own window (`window.close()` in a popup it was opened as): its tile
    /// goes. Its opener is shown and selected again only while the popup still had the user's
    /// attention (selected or holding the keyboard); otherwise nothing else moves.
    func webViewDidClose(_ webView: WKWebView) {
        guard webView === self.webView, board.objects[objectID] != nil else { return }
        NSLog("easl: browser %@ closed by its page", objectID)
        let attended = hasAttention?(objectID) == true
        let caller: ObjectID? = if case .agent(let tile) = credit.actor() { tile } else { nil }
        try? board.delete(objectID, caller: caller)
        if attended, let popupOpener, board.objects[popupOpener] != nil { onOpenedTile?(popupOpener) }
    }

    private func finished(_ navigation: WKNavigation?) {
        pendingNavigations.removeAll { $0 === navigation }
        uncommittedNavigations.removeAll { $0 === navigation }
        signalChange()
    }
}

/// The first click into a page acts (follows the link, presses the button) even while the
/// window isn't key, as the canvas's own gestures do; WebKit alone only activates the window.
/// Clicks and key presses are the user acting on the page (`NavigationCredit`).
final class BrowserWebView: WKWebView {
    var onUserInput: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// WebKit's context menu leads with Mention: the element under the right-click.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        CanvasView.insertMention(into: menu, in: self, for: event)
    }

    override func mouseDown(with event: NSEvent) {
        onUserInput?()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onUserInput?()
        super.keyDown(with: event)
    }
}

/// A script message handler for the tile's page. WebKit retains handlers strongly, so the tile's
/// closures hold it weakly to keep the web view from owning its tile.
@MainActor
private final class PageMessages: NSObject, WKScriptMessageHandler {
    private let receive: @MainActor (WKScriptMessage) -> Void

    init(_ receive: @escaping @MainActor (WKScriptMessage) -> Void) {
        self.receive = receive
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(message)
    }
}

/// Back, forward, reload, and the address field.
@MainActor
private final class BrowserChrome: NSView, NSTextFieldDelegate {
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onSubmit: ((String) -> Void)?
    /// Esc in the address field: its text goes back to the page's address, the canvas takes the keyboard.
    var onEscape: (() -> Void)?
    /// The address the field shows while nobody types in it.
    private var shownAddress = ""
    private let back = BrowserChrome.button("chevron.left", "Back")
    private let forward = BrowserChrome.button("chevron.right", "Forward")
    private let reload = BrowserChrome.button("arrow.clockwise", "Reload")
    private let address = NSTextField()
    /// "2 errors", only while the page has any; clicking it lists them (`onProblems`).
    private let problems = NSButton(title: "", target: nil, action: nil)
    /// "Reloaded", quietly, while the tile keeps the log of the page easl released (the page
    /// loaded again, or "Released" while it hasn't); clicking it lists that page's errors too.
    private let releaseNote = NSButton(title: "", target: nil, action: nil)
    var onProblems: (() -> Void)?
    /// The page's latest download: "↓ build.zip 42%", "↓ build.zip" once done (clicking shows
    /// it in Finder), "Download failed" in red.
    private let downloadNote = NSButton(title: "", target: nil, action: nil)
    var onDownload: (() -> Void)?
    /// The installed browser extensions' button, at the bar's trailing end while any run
    /// (`BrowserExtensions`); clicked, it hands itself over as the anchor for a popup or menu.
    let extensions = BrowserChrome.button("puzzlepiece.extension", "Extensions")
    var onExtensions: ((NSView) -> Void)?
    private(set) var isEditing = false

    var download: BrowserDownloads.Status? {
        didSet {
            guard download != oldValue else { return }
            downloadNote.isHidden = download == nil
            if let download {
                let text: String
                var color = NSColor.secondaryLabelColor
                switch download.state {
                case .running(let fraction): text = "↓ \(download.name)" + (fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? "…")
                case .finished: text = "↓ \(download.name)"
                case .failed: (text, color) = ("Download failed: \(download.name)", .systemRed)
                }
                downloadNote.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color])
                downloadNote.toolTip = switch download.state {
                case .finished: "Downloaded to \(download.file?.path ?? "Downloads"). Click to show it in Finder."
                case .running: "Downloading to \(download.file?.deletingLastPathComponent().path ?? "Downloads")"
                case .failed(let reason): reason
                }
                downloadNote.setAccessibilityLabel(text)
            }
            resizeSubviews(withOldSize: bounds.size)
        }
    }

    var errorCount = 0 {
        didSet {
            guard errorCount != oldValue else { return }
            problems.isHidden = errorCount == 0
            let title = errorCount == 1 ? "1 error" : "\(errorCount) errors"
            problems.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.systemRed])
            problems.setAccessibilityLabel("\(title) on this page")
            resizeSubviews(withOldSize: bounds.size)
        }
    }

    /// The page easl released, while the tile keeps its log: whether the page loaded again
    /// since, the errors it had logged, and when it went.
    struct Released: Equatable {
        var reloaded: Bool
        var errors: Int
        var at: Date
    }

    var released: Released? {
        didSet {
            guard released != oldValue else { return }
            releaseNote.isHidden = released == nil
            if let released {
                let word = released.reloaded ? "Reloaded" : "Released"
                let before = released.errors == 0 ? "" : released.errors == 1 ? " · 1 error before" : " · \(released.errors) errors before"
                releaseNote.attributedTitle = NSAttributedString(string: word + before, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
                let time = DateFormatter.localizedString(from: released.at, dateStyle: .none, timeStyle: .short)
                let again = released.reloaded ? ", and loaded it again when it came back" : "; it loads again when the tile comes back into view"
                releaseNote.toolTip = "easl released this page at \(time), \(Int(BrowserTile.releaseDelay / 60)) minutes after it left the view, to save energy\(again). Click for what it logged before."
                releaseNote.setAccessibilityLabel("Page \(word.lowercased()) after being released\(before)")
            }
            resizeSubviews(withOldSize: bounds.size)
        }
    }

    var canGoBack = false { didSet { back.isEnabled = canGoBack } }
    var canGoForward = false { didSet { forward.isEnabled = canGoForward } }
    var isLoading = false {
        didSet { reload.image = NSImage(systemSymbolName: isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: "Reload") }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        back.target = self
        back.action = #selector(backClicked)
        forward.target = self
        forward.action = #selector(forwardClicked)
        reload.target = self
        reload.action = #selector(reloadClicked)
        back.isEnabled = false
        forward.isEnabled = false
        address.bezelStyle = .roundedBezel
        address.font = .systemFont(ofSize: 12)
        address.lineBreakMode = .byTruncatingTail
        address.cell?.isScrollable = true
        address.cell?.wraps = false
        address.placeholderString = "Address"
        address.delegate = self
        address.target = self
        address.action = #selector(addressSubmitted)
        problems.isBordered = false
        problems.wantsLayer = true
        problems.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12).cgColor
        problems.layer?.cornerRadius = 9
        problems.toolTip = "Console errors and failed requests since the page loaded"
        problems.target = self
        problems.action = #selector(problemsClicked)
        problems.isHidden = true
        releaseNote.isBordered = false
        releaseNote.wantsLayer = true
        releaseNote.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.1).cgColor
        releaseNote.layer?.cornerRadius = 9
        releaseNote.target = self
        releaseNote.action = #selector(problemsClicked)
        releaseNote.isHidden = true
        downloadNote.isBordered = false
        downloadNote.wantsLayer = true
        downloadNote.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.1).cgColor
        downloadNote.layer?.cornerRadius = 9
        downloadNote.lineBreakMode = .byTruncatingMiddle
        downloadNote.target = self
        downloadNote.action = #selector(downloadClicked)
        downloadNote.isHidden = true
        extensions.target = self
        extensions.action = #selector(extensionsClicked)
        extensions.imageScaling = .scaleProportionallyDown
        extensions.isHidden = true
        [back, forward, reload, address, downloadNote, releaseNote, problems, extensions].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let side: CGFloat = 24
        let y = (bounds.height - side) / 2
        back.frame = NSRect(x: 6, y: y, width: side, height: side)
        forward.frame = NSRect(x: 32, y: y, width: side, height: side)
        reload.frame = NSRect(x: 58, y: y, width: side, height: side)
        var trailing: CGFloat = 8
        if !extensions.isHidden {
            extensions.frame = NSRect(x: bounds.width - 6 - side, y: y, width: side, height: side)
            trailing += side + 2
        }
        for pill in [problems, releaseNote, downloadNote] where !pill.isHidden {
            let width = min(ceil(pill.attributedTitle.size().width) + 14, 220)
            pill.frame = NSRect(x: bounds.width - trailing + 2 - width, y: (bounds.height - 18) / 2, width: width, height: 18)
            trailing += width + 4
        }
        address.frame = NSRect(x: 88, y: (bounds.height - 22) / 2, width: max(0, bounds.width - 88 - trailing), height: 22)
    }

    /// The badge's frame in the chrome, for anchoring its list.
    var problemsFrame: NSRect { problems.frame }

    func setAddress(_ text: String) {
        shownAddress = text == "about:blank" ? "" : text
        address.stringValue = shownAddress
    }

    func focusAddress() {
        window?.makeFirstResponder(address)
    }

    private static func button(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.toolTip = label
        return button
    }

    @objc private func backClicked() { onBack?() }
    @objc private func forwardClicked() { onForward?() }
    @objc private func reloadClicked() { onReload?() }
    @objc private func problemsClicked() { onProblems?() }
    @objc private func downloadClicked() { onDownload?() }
    @objc private func extensionsClicked() { onExtensions?(extensions) }

    /// The extensions' button (`BrowserExtensions.button`): nil hides it.
    func setExtensions(_ shown: (image: NSImage, label: String)?) {
        extensions.image = shown?.image
        extensions.toolTip = shown?.label
        extensions.setAccessibilityLabel(shown?.label)
        guard extensions.isHidden != (shown == nil) else { return }
        extensions.isHidden = shown == nil
        resizeSubviews(withOldSize: bounds.size)
    }

    @objc private func addressSubmitted() {
        isEditing = false
        onSubmit?(address.stringValue)
    }

    func controlTextDidBeginEditing(_ obj: Notification) { isEditing = true }
    func controlTextDidEndEditing(_ obj: Notification) { isEditing = false }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        address.stringValue = shownAddress
        isEditing = false
        onEscape?()
        return true
    }
}

extension BrowserTile {
    /// Reads the loaded page's background (a transparent page is WebKit's white, or its dark
    /// default for a page that asks for dark colors) for drawings over the tile.
    fileprivate func probeSurface(_ webView: WKWebView) {
        Task { @MainActor [weak self] in
            guard let probe = await PageSurface.probe(webView), let self else { return }
            let luminance = probe.luminance ?? (probe.darkDefault ? 0.01 : 1)
            guard luminance != self.surfaceLuminance else { return }
            self.surfaceLuminance = luminance
            NotificationCenter.default.post(name: .tileSurfaceChanged, object: self)
        }
    }
}

// MARK: Page problems (console errors, failed requests)

extension BrowserTile {
    /// The badge shows the count, the quiet "Reloaded" pill the released page's log, and an
    /// open list refreshes.
    fileprivate func problemsChanged() {
        let count = pageErrors + (documentFailure == nil ? 0 : 1)
        chrome.errorCount = count
        chrome.released = previousLoad.map { .init(reloaded: webView != nil, errors: $0.log.errors, at: $0.at) }
        if count == 0, previousLoad == nil { return closeProblems() }
        if problemsList != nil { refreshProblems() }
    }

    /// What the page reported since it loaded; nil without a page that runs `PageCapture`.
    func readPageLog() async -> PageLog? {
        guard let webView else { return nil }
        return await Self.pageLog(of: webView, failure: documentFailure)
    }

    /// `webView`'s page log, its own document's HTTP error (`failure`) first.
    fileprivate static func pageLog(of webView: WKWebView, failure: PageLogEntry?) async -> PageLog? {
        guard let text = try? await webView.callAsyncJavaScript(PageCapture.readScript, arguments: [:], in: nil, contentWorld: .page) as? String,
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), var log = PageLog(json: json) else { return nil }
        if let failure { log.add(documentFailure: failure) }
        return log
    }

    /// `object.get`'s `page`: how WebKit runs the page now, its log, and the released page's.
    func pageReport() async -> PageReport {
        await previousRead?.value
        let log = await readPageLog()
        return PageReport(visibility: visibility, log: log, previous: previousLoad)
    }

    /// On screen; kept visible to WebKit for an agent though nobody sees it (the stage, a
    /// minimized or covered window); hidden in its tile; or no page at all.
    var visibility: PageReport.Visibility {
        guard webView != nil else { return .released }
        if pageOnScreen { return .visible }
        return drivenTimer != nil ? .driven : .hidden
    }

    fileprivate func toggleProblems() {
        if problemsList != nil { return closeProblems() }
        let list = PageProblemsView()
        list.onClose = { [weak self] in self?.closeProblems() }
        list.onResize = { [weak self] in self?.placeProblems() }
        list.resolve = { [weak self] text in self?.sourceFile(text) }
        list.onOpenSource = { [weak self] file, line in self?.openSource(file, line: line) }
        problemsList = list
        addSubview(list, positioned: .above, relativeTo: cover)
        placeProblems()
        refreshProblems()
        // Sources name files by their served path: a file listed since the board opened (a
        // new module) links once the root's list is fresh.
        BoardFiles.of(board.root).refresh { [weak self] _ in
            if self?.problemsList === list { self?.refreshProblems() }
        }
    }

    func closeProblems() {
        problemsList?.removeFromSuperview()
        problemsList = nil
    }

    private func refreshProblems() {
        Task { @MainActor [weak self] in
            await self?.previousRead?.value
            let log = await self?.readPageLog()
            guard let self, let list = self.problemsList else { return }
            list.show(log?.problems ?? self.documentFailure.map { [$0] } ?? [], previous: self.previousLoad, reloaded: self.webView != nil)
            self.placeProblems()
        }
    }

    /// The repo file and line a page `source` or stack frame names (`PageSource`), found like a
    /// terminal's ⌘-click reference: served path against the board root, then by trailing path
    /// among the root's files.
    fileprivate func sourceFile(_ text: String) -> (file: String, line: Int)? {
        guard let location = PageSource.location(text),
              let file = PageSource.file(for: location.url, root: board.root.path, listed: BoardFiles.of(board.root).current()) else { return nil }
        return (file, location.line)
    }

    /// A `file:line` in the error list: the code at that line, as a note's code link opens it.
    fileprivate func openSource(_ file: String, line: Int) {
        let opened = board.openForNavigation(CodeAim(path: board.boardPath(file, linkRoot: board.root), range: LineRange(start: line, end: line)), from: objectID)
        NSLog("easl: browser %@ opened %@:%d as %@", objectID, file, line, opened.id)
        onOpenedCode?(opened.id, opened.existing)
    }

    /// Under the badge, at the page's right edge, as tall as its rows up to most of the page.
    fileprivate func placeProblems() {
        guard let list = problemsList else { return }
        let width = min(PageProblemsView.preferredWidth, bounds.width - 12)
        let height = min(list.fittingHeight(width: width), max(80, (bounds.height - chromeExtent) * 0.7))
        list.frame = NSRect(x: bounds.width - width - 6, y: chromeExtent + 2, width: width, height: height)
    }

    /// A Hyper-click on a row of the list: that entry, as a `console` mention.
    fileprivate func problemMention(at point: NSPoint) -> MentionTarget? {
        guard let list = problemsList, let entry = list.entry(at: list.convert(point, from: self)) else { return nil }
        let url = webView?.url?.absoluteString ?? object.props["url"]?.string ?? ""
        return .console(object: objectID, url: url, entry: entry)
    }

    fileprivate func problemOutline(_ entry: PageLogEntry) -> NSRect? {
        guard let list = problemsList, let rect = list.rowRect(of: entry) else { return nil }
        return convert(rect, from: list)
    }

    /// Safari's Web Inspector for the page, docked in the page area under the address bar
    /// (`pageHost`). `_inspector` is WKWebView's own inspector handle (`isInspectable` makes it
    /// available); nil when the page isn't loaded or WebKit has no such handle.
    private var inspector: NSObject? {
        guard let webView, webView.url != nil, webView.responds(to: NSSelectorFromString("_inspector")) else { return nil }
        return webView.value(forKey: "_inspector") as? NSObject
    }

    /// Whether the page's Web Inspector is open (View ▸ Hide Web Inspector then).
    var inspectorVisible: Bool {
        guard let inspector, inspector.responds(to: NSSelectorFromString("isVisible")) else { return false }
        return (inspector.value(forKey: "isVisible") as? Bool) == true
    }

    /// Opens the Web Inspector (the object menu's Inspect Element; the page's own Inspect Element
    /// opens it too). False without an inspector.
    @discardableResult
    func showInspector() -> Bool {
        guard let inspector, inspector.responds(to: NSSelectorFromString("show")) else { return false }
        inspector.perform(NSSelectorFromString("show"))
        return true
    }

    /// ⌥⌘I, View ▸ Show/Hide Web Inspector: closes an open inspector, else opens it.
    func toggleInspector() {
        guard inspectorVisible else {
            showInspector()
            return
        }
        guard let inspector, inspector.responds(to: NSSelectorFromString("close")) else { return }
        inspector.perform(NSSelectorFromString("close"))
    }

    var canShowInspector: Bool { webView?.url != nil }

    /// Snapshot to Image: the page as it shows now (without the address bar), at the screen's
    /// pixels; a page released from its web view gives its last capture. Nil with neither.
    func pageImage() async -> NSImage? {
        if let webView, webView.window != nil, webView.url != nil, webView.bounds.width > 0, webView.bounds.height > 0,
           let page = try? await webView.takeSnapshot(configuration: WKSnapshotConfiguration()) {
            return page
        }
        return cachedImage
    }

    /// The address the page shows (a released page's `props.url`).
    var pageURL: String? { webView?.url?.absoluteString ?? object.props["url"]?.string }

    /// The page's address as another browser opens it (Open in Browser): a web or file URL; nil
    /// for an empty tile.
    var webAddress: URL? {
        guard let text = pageURL, let url = URL(string: text), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

/// What a browser tile's page area shows when its page didn't load (`BrowserLoadFailure`):
/// "Can't reach localhost:5391", the reason and the automatic retry under it, and Retry. Quiet,
/// like the blank page it replaces: no icon, no alert colour.
@MainActor
private final class BrowserFailureView: NSView {
    var onRetry: (() -> Void)?
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let retry = NSButton(title: "Retry", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        headline.font = .systemFont(ofSize: 15, weight: .semibold)
        headline.textColor = .labelColor
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        for label in [headline, detail] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        retry.bezelStyle = .rounded
        retry.controlSize = .small
        retry.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        retry.target = self
        retry.action = #selector(retryClicked)
        addSubview(retry)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    /// Drawn, not a layer colour, so renders and cards (`cacheDisplay`) show it too.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }

    func show(_ failure: BrowserLoadFailure) {
        headline.stringValue = failure.headline
        detail.stringValue = failure.detail
        toolTip = failure.url.absoluteString
        needsLayout = true
        resizeSubviews(withOldSize: bounds.size)
    }

    func showRetrying() {
        detail.stringValue = "Trying again…"
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        retry.sizeToFit()
        let width = max(0, bounds.width - 32)
        let block: CGFloat = 20 + 6 + 16 + 12 + retry.frame.height
        let top = max(12, (bounds.height - block) / 2 - 12)
        headline.frame = NSRect(x: 16, y: top, width: width, height: 20)
        detail.frame = NSRect(x: 16, y: top + 26, width: width, height: 16)
        retry.frame.origin = NSPoint(x: ((bounds.width - retry.frame.width) / 2).rounded(), y: top + 54)
    }

    @objc private func retryClicked() { onRetry?() }
}
