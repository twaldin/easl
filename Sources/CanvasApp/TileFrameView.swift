import AppKit
import CanvasCore

/// Shared chrome around every tile: title bar (drag moves the selection), lifecycle badge, content
/// zoom control, close button, resize grip, and the zoomed-out card (tinted by agent lifecycle).
/// Selection rings are drawn by the canvas overlay.
@MainActor
final class TileFrameView: NSView {
    static let titleHeight = CGFloat(RenderMath.tileTitleHeight)

    let objectID: ObjectID
    let content: any TileContent
    /// Holds the content at the tile's `zoom`: its frame is the body, its bounds the body divided
    /// by the zoom, so the content lays out, hit-tests, and converts coordinates in its own points
    /// and draws magnified in place, while the title bar stays at 1×.
    private let zoomView = ContentZoomView()
    private let zoomControl = TileZoomControl()
    private let titleBar = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    /// The agent terminal that made the object (`AuthorMark`), small and muted at the right.
    private let authorLabel = NSTextField(labelWithString: "")
    /// A terminal's last command when it failed or ran long (`exit 1 · 42 s`), right-aligned.
    private let statusLabel = NSTextField(labelWithString: "")
    private let badge = NSView()
    private let closeButton = TileCloseButton()
    private let card = CardImageView()
    private var cardTitle = NSTextField(labelWithString: "")
    private let cardTint = CardTint()
    private(set) var isLive = true
    /// Stacking order among tiles (the object's `z`).
    private(set) var z: Double = 0
    private var lifecycleState: String?

    /// Called with the new canvas-space frame when a resize ends.
    var onFrameCommit: ((NSRect) -> Void)?
    /// The title bar's − / % / + asked for this content zoom.
    var onZoom: ((Double) -> Void)?
    /// Live resize, so the canvas can keep rings and groups around the tile.
    var onResizing: (() -> Void)?
    var onClose: (() -> Void)?
    /// Title-bar drags move the whole selection; the canvas runs the gesture.
    var onMoveBegan: ((NSEvent) -> Void)?
    var onMoveDragged: ((NSEvent) -> Void)?
    var onMoveEnded: ((NSEvent) -> Void)?
    var onTitleDoubleClick: (() -> Void)?
    var onMenu: ((NSEvent) -> NSMenu?)?

    private var resizeStart: (mouse: NSPoint, frame: NSRect, proportional: Bool)?
    /// The object's `props.zoom` (`ObjectZoom`): how big the content draws inside the body. The
    /// frame is the tile's size and never follows it.
    private(set) var zoom: CGFloat = 1
    /// Whether the tile is selected (the zoom control's − and + show while it is, or hovered).
    var isSelected = false {
        didSet { if isSelected != oldValue { updateZoomControl() } }
    }
    private var hovered = false
    private var moving = false

    /// What the tile is, for accessibility ("terminal", "code", …).
    private let roleDescription: String
    /// Whether the tile's content zooms (`ObjectZoom.applies`): not an image's.
    private let zoomable: Bool

    init(object: CanvasObject, content: any TileContent, frame: NSRect) {
        objectID = object.id
        self.content = content
        zoom = CGFloat(object.zoom)
        zoomable = ObjectZoom.applies(to: object.type)
        roleDescription = object.type == .html ? "HTML" : object.type.rawValue
        super.init(frame: frame)
        closeButton.tile = self
        card.tile = self
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        titleBar.wantsLayer = true
        // The group's label says the title (with state, range, caption); the label itself would
        // say it again, and is empty while the window isn't visible (`syncTitle`).
        titleLabel.setAccessibilityElement(false)
        titleLabel.font = ChromeText.font(Self.titleFont)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        applyLayerColors()
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.title = "✕"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        authorLabel.font = ChromeText.font(Self.authorFont)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.alignment = .right
        authorLabel.isHidden = true
        titleBar.addSubview(badge)
        titleBar.addSubview(titleLabel)
        titleBar.addSubview(authorLabel)
        statusLabel.font = ChromeText.font(Self.statusFont)
        statusLabel.alignment = .right
        statusLabel.isHidden = true
        titleBar.addSubview(statusLabel)
        titleBar.addSubview(closeButton)
        closeBaseFont = closeButton.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        closeButton.font = ChromeText.font(closeBaseFont)
        zoomControl.applyScale()
        NotificationCenter.default.addObserver(self, selector: #selector(chromeTextChanged), name: ChromeText.didChange, object: nil)
        zoomControl.onStep = { [weak self] bigger in self?.stepZoom(bigger: bigger) }
        zoomControl.onReset = { [weak self] in self?.onZoom?(1) }
        titleBar.addSubview(zoomControl)
        addSubview(titleBar)
        zoomView.addSubview(content)
        addSubview(zoomView)
        card.imageScaling = .scaleProportionallyUpOrDown
        card.isHidden = true
        cardTitle.font = .systemFont(ofSize: 28, weight: .semibold)
        cardTitle.alignment = .center
        cardTitle.isHidden = true
        cardTitle.setAccessibilityElement(false)
        addSubview(card)
        addSubview(cardTitle)
        cardTint.isHidden = true
        addSubview(cardTint)
        update(object)
        layoutParts()
        updateZoomControl()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Each tile is one accessibility group (VoiceOver, Full Keyboard Access) named by its title,
    // what an agent's terminal is doing, a code tile's lines and caption, and who made it; its
    // text (`TileContent.accessibleText`) is a text area inside while it is live.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityRoleDescription() -> String? { roleDescription }
    override func accessibilityLabel() -> String? {
        ([title, accessibilityDetail] + [author.map { "created by \($0)" }]).compactMap { $0 }.joined(separator: ", ")
    }
    override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren() ?? []
        guard isLive, !zoomedOut, let text = content.accessibleText else { return children }
        return children + [text]
    }

    /// What the label says after the title (`accessibilityDetail(for:)`).
    private var accessibilityDetail: String?

    /// An agent terminal's lifecycle ("done", "blocked: approve Bash?"), a code tile's lines and
    /// caption ("lines 1321–1331, Step 1/4 · …"), an image's caption, a question's status
    /// ("open", "answered"); nil for anything else.
    static func accessibilityDetail(for object: CanvasObject) -> String? {
        let props = object.props
        func nonEmpty(_ value: JSONValue?) -> String? { value?.string.flatMap { $0.isEmpty ? nil : $0 } }
        switch object.type {
        case .terminal:
            guard let state = props["lifecycle"]?["state"]?.string, CanvasBasics.lifecycle(state) != nil else { return nil }
            return state == "blocked" ? nonEmpty(props["lifecycle"]?["message"]).map { "blocked: \($0)" } ?? state : state
        case .code:
            var parts: [String] = []
            if let start = props["range"]?["start"]?.int {
                let end = props["range"]?["end"]?.int ?? start
                parts.append(end > start ? "lines \(start)–\(end)" : "line \(start)")
            }
            if let caption = nonEmpty(props["caption"]) { parts.append(CodeCaption.plain(caption)) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .image: return nonEmpty(props["caption"])
        case .question: return QuestionSpec.status(of: props).rawValue
        default: return nil
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerColors()
    }

    /// Layer colors resolve once, so again when the appearance changes (dark, light, Increase
    /// Contrast). Under Increase Contrast the border is thicker and the lifecycle dot ringed.
    private func applyLayerColors() {
        let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderWidth = increased ? 2 : 1
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            titleBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            badge.layer?.backgroundColor = Self.badgeColor(lifecycleState).cgColor
            badge.layer?.borderWidth = increased && lifecycleState != nil ? 1 : 0
            badge.layer?.borderColor = NSColor.labelColor.cgColor
        }
    }

    /// Layout happens in `layoutParts`.
    override func resizeSubviews(withOldSize oldSize: NSSize) {}

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutParts()
    }

    /// Moves the tile and zooms its content in one step, so the content never lays out at a size
    /// in between.
    func place(_ rect: NSRect, zoom: CGFloat) {
        let rezoomed = zoom != self.zoom
        self.zoom = zoom
        if frame != rect { frame = rect }
        if rezoomed {
            applyZoom()
            updateZoomControl()
        }
    }

    /// The content at `zoom` in the body: laid out at the body divided by the zoom.
    private func applyZoom() {
        let body = zoomView.frame.size
        let natural = NSSize(width: body.width / zoom, height: body.height / zoom)
        if abs(zoomView.bounds.width - natural.width) > 0.001 || abs(zoomView.bounds.height - natural.height) > 0.001 { zoomView.setBoundsSize(natural) }
        if content.frame.size != zoomView.bounds.size || content.frame.origin != .zero { content.frame = NSRect(origin: .zero, size: zoomView.bounds.size) }
    }

    private func layoutParts() {
        let width = bounds.width
        titleBar.frame = NSRect(x: 0, y: 0, width: width, height: Self.titleHeight)
        badge.frame = NSRect(x: 10, y: (Self.titleHeight - 10) / 2, width: 10, height: 10)
        closeButton.frame = TileTitleBar.closeFrame(width: width)
        layoutTitle()
        let body = NSRect(x: 0, y: Self.titleHeight, width: width, height: max(0, bounds.height - Self.titleHeight))
        // The zoom view keeps its bounds' scale as its frame changes (AppKit), so the content
        // sees one resize, to its natural size.
        if zoomView.frame != body { zoomView.frame = body }
        applyZoom()
        card.frame = body
        cardTitle.frame = body.insetBy(dx: 12, dy: body.height / 3)
        cardTint.frame = bounds
    }

    func update(_ object: CanvasObject) {
        if title.isEmpty || object.type != .terminal { setTitle(Self.title(for: object, branch: branch)) }
        // A file outside the board root shows a short label, an image its file name; the
        // tooltip has the path.
        switch object.type {
        case .code: titleLabel.toolTip = object.props["path"]?.string.flatMap { PathLabel.short($0) == $0 ? nil : $0 }
        case .image: titleLabel.toolTip = object.props["path"]?.string.flatMap { ($0 as NSString).lastPathComponent == $0 ? nil : $0 }
        default: titleLabel.toolTip = nil
        }
        z = object.z
        accessibilityDetail = Self.accessibilityDetail(for: object)
        let state = object.type == .terminal ? object.props["lifecycle"]?["state"]?.string : nil
        badge.isHidden = object.type != .terminal
        if state != lifecycleState {
            lifecycleState = state
            applyLayerColors()
            // What the dot means, in the words of Help › easl Basics.
            badge.toolTip = CanvasBasics.lifecycle(state)
            updateTint()
        }
        content.update(object)
    }

    /// The title (terminals report theirs). The labels show it only while the window is visible:
    /// a working agent retitles its terminal ~12 times a second (omp's spinner), and every label
    /// change costs a layout, text drawing, and a commit to the window server, minimized or not.
    private(set) var title = ""
    private var occlusionObserver: NSObjectProtocol?

    func setTitle(_ title: String) {
        guard title != self.title else { return }
        self.title = title
        if window?.occlusionState.contains(.visible) == true { syncTitle() }
    }

    /// A terminal's last-command status (`TerminalCommand.status`), nil to hide it: quiet
    /// secondary text, red only for a failure; `detail` is its tooltip.
    func setStatus(_ status: String?, failed: Bool, detail: String?) {
        statusLabel.stringValue = status ?? ""
        statusLabel.textColor = failed ? .systemRed : .secondaryLabelColor
        statusLabel.toolTip = detail
        statusLabel.isHidden = status == nil
        layoutTitle()
    }

    /// Puts the title into the labels (also for `view.snapshot` of a window nobody sees).
    func syncTitle() {
        guard titleLabel.stringValue != title else { return }
        titleLabel.stringValue = title
        cardTitle.stringValue = title
        if author != nil { layoutTitle() }
    }

    // MARK: Author mark

    /// The title bar's text at 100% (`ChromeText` scales it; `view.render` draws these as they are).
    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let authorFont = NSFont.systemFont(ofSize: 11)
    static let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var closeBaseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    /// Chrome text changed size (`ChromeText.didChange`): the title bar's text and the width it
    /// takes. The bar itself stays `titleHeight` tall: that is the board's geometry.
    @objc private func chromeTextChanged() {
        titleLabel.font = ChromeText.font(Self.titleFont)
        authorLabel.font = ChromeText.font(Self.authorFont)
        statusLabel.font = ChromeText.font(Self.statusFont)
        closeButton.font = ChromeText.font(closeBaseFont)
        zoomControl.applyScale()
        updateZoomControl()
    }

    /// A line of title bar text `height` points tall at 100%, as a frame centred in the bar at
    /// `scale`.
    private static func line(_ height: CGFloat, scale: Double) -> (y: CGFloat, height: CGFloat) {
        let scaled = (height * CGFloat(scale)).rounded()
        return (((titleHeight - scaled) / 2).rounded(), scaled)
    }

    /// The name of the agent terminal that made the object (`AuthorMark`), nil for none.
    private(set) var author: String?

    func setAuthor(_ author: String?) {
        guard author != self.author else { return }
        self.author = author
        authorLabel.stringValue = author.map(AuthorMark.label) ?? ""
        authorLabel.toolTip = author.map(AuthorMark.toolTip)
        layoutTitle()
    }

    private func layoutTitle() {
        // The content zoom control sits before the close button; a terminal's command status
        // (never on a tile with an author mark) before that.
        let width = bounds.width
        let zoomWidth = zoomControl.isHidden ? 0 : zoomControl.fittedWidth
        zoomControl.frame = TileTitleBar.zoomControlFrame(width: width, controlWidth: zoomWidth) ?? .zero
        let trailing = zoomWidth > 0 ? zoomWidth + 4 : 0
        let status = statusLabel.isHidden ? 0 : min(statusLabel.fittingSize.width, max(0, width / 3))
        let line = Self.line(15, scale: ChromeText.scale)
        statusLabel.frame = NSRect(x: width - 32 - trailing - status, y: line.y, width: status, height: line.height)
        let frames = Self.titleFrames(width: width - (status > 0 ? status + 8 : 0) - trailing, title: titleLabel.stringValue, author: author, scale: ChromeText.scale)
        titleLabel.frame = frames.title
        authorLabel.isHidden = frames.author == nil
        if let rect = frames.author { authorLabel.frame = rect }
    }

    // MARK: Content zoom

    /// − and +: the next of `ObjectZoom.levels` that way.
    private func stepZoom(bigger: Bool) {
        guard let next = ObjectZoom.step(from: Double(zoom), bigger: bigger) else { return }
        onZoom?(next)
    }

    /// The percentage shows whenever the content isn't at 100%, − and + while the tile is
    /// hovered or selected: an untouched tile's title bar stays as it was.
    private func updateZoomControl() {
        let zoom = Double(self.zoom)
        let expanded = zoomable && (hovered || isSelected)
        zoomControl.show(zoom: zoom, expanded: expanded, canZoomOut: ObjectZoom.step(from: zoom, bigger: false) != nil,
                         canZoomIn: ObjectZoom.step(from: zoom, bigger: true) != nil)
        zoomControl.isHidden = !zoomable || (!expanded && abs(zoom - 1) < 0.001)
        layoutTitle()
    }

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateZoomControl()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateZoomControl()
    }

    static let zoomLabelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// Where the title bar shows the content zoom percentage while − and + are hidden, here and
    /// in `view.render`: just before the close button; nil at 100%. `scale`: the chrome text
    /// scale (`view.render` draws at 1, the same for every client).
    static func zoomLabelFrame(width: CGFloat, zoom: Double, scale: Double = ChromeText.scale) -> NSRect? {
        guard abs(zoom - 1) >= 0.001 else { return nil }
        let percent = TileZoomControl.percentWidth(scale: scale)
        return NSRect(x: width - 30 - percent, y: 4, width: percent, height: 18)
    }

    /// Where a title bar `width` wide draws the title and the author mark (nil: none), here and
    /// in `view.render`: the mark right-aligned before the close button, truncated before the
    /// title and dropped in a narrow bar (`AuthorMark.width`). The text is `scale` times its
    /// size; the bar's height and its left and right margins are fixed.
    static func titleFrames(width: CGFloat, title: String, author: String?, scale: Double = ChromeText.scale) -> (title: NSRect, author: NSRect?) {
        let space = max(0, width - 60)
        let titleLine = line(16, scale: scale), markLine = line(15, scale: scale)
        let whole = NSRect(x: 26, y: titleLine.y, width: space, height: titleLine.height)
        guard let author else { return (whole, nil) }
        // A label's cell pads its text 2 pt on either side.
        func measure(_ text: String, _ font: NSFont) -> CGFloat { ((text as NSString).size(withAttributes: [.font: font]).width + 5).rounded(.up) }
        let shown = AuthorMark.width(natural: measure(AuthorMark.label(author), ChromeText.font(authorFont, scale: scale)),
                                     title: measure(title, ChromeText.font(titleFont, scale: scale)), space: space)
        guard shown > 0 else { return (whole, nil) }
        let mark = NSRect(x: whole.maxX - shown, y: markLine.y, width: shown, height: markLine.height)
        return (NSRect(x: whole.minX, y: whole.minY, width: max(0, space - shown - AuthorMark.gap), height: whole.height), mark)
    }

    // MARK: Title

    /// A board-root changes tile's branch, which its title names (`title(for:branch:)`).
    func setBranch(_ branch: String?, of object: CanvasObject) {
        guard branch != self.branch else { return }
        self.branch = branch
        setTitle(Self.title(for: object, branch: branch))
    }

    private var branch: String?

    /// The title from the object's props; `branch` is the branch checked out in the board root,
    /// which a changes tile of the whole board root names (`Changes: main`).
    static func title(for object: CanvasObject, branch: String? = nil) -> String {
        let props = object.props
        switch object.type {
        case .terminal: return props["title"]?.string ?? props["agent"]?["kind"]?.string ?? "Terminal"
        case .code:
            let path = props["path"].flatMap(\.string).map(PathLabel.short) ?? "code"
            return props["followOf"] != nil ? "↳ \(path)" : path
        case .note: return props["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "Note"
        case .browser: return [props["title"], props["pageTitle"], props["url"]].lazy.compactMap { $0?.string }.first { !$0.isEmpty } ?? "Browser"
        case .html: return props["title"]?.string ?? "HTML"
        // The file name wherever the file is (`ImageProps.title`); the path is the tooltip's.
        case .image: return props["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? props["path"].flatMap(\.string).map { ($0 as NSString).lastPathComponent } ?? "Image"
        case .diagram: return DiagramSpec.title(props)
        // Who asks; a terminal asking is named in the body (its header's name).
        case .question:
            let asker = QuestionSpec(props).asker
            return asker?.name.map { name in "Question from \(asker?.host.map { "\(name)@\($0)" } ?? name)" } ?? "Question"
        case .changes:
            let spec = ChangesSpec(props)
            if let title = props["title"]?.string { return title }
            let parts = ((spec.head ?? spec.ref).map { [$0] } ?? []) + (spec.root.map { [($0 as NSString).lastPathComponent] } ?? []) + spec.paths.map(PathLabel.short)
            return parts.isEmpty ? branch.map { "Changes: \($0)" } ?? "Changes" : "Changes: \(parts.joined(separator: ", "))"
        default: return object.type.rawValue.capitalized
        }
    }

    static func badgeColor(_ state: String?) -> NSColor {
        switch state {
        case "working": .systemBlue
        case "blocked": .systemOrange
        case "done": .systemGreen
        case "idle": .systemGray
        default: .clear
        }
    }

    /// Cards show below `CanvasView.liveThreshold` zoom, so ~0.6 pixels per point is all they need
    /// (a full 2× capture would be ~11× the memory, held for every card on the board).
    static let cardPixelsPerPoint: CGFloat = 0.6

    /// Zoomed-out or offscreen: freeze to a card and let the content release its resources. The
    /// live content stays up until its card has arrived, so a swap never shows a blank or
    /// title-only tile; going live, the card stays until the content is ready (`revealWhenReady`).
    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        cardRequest += 1
        if live {
            showContent(true)
            revealWhenReady()
        } else {
            requestCard()
        }
        updateTint()
    }

    /// Longest a card covers content that never reports ready (a page whose script fails).
    static let revealLimit: TimeInterval = 2

    /// The card stays over the live content, which renders under it, until the content reports
    /// its live view drawn (a web page attaches, loads, lays out, and paints): the swap never
    /// shows a blank, half-loaded, or differently laid-out tile.
    private func revealWhenReady() {
        guard !card.isHidden || !cardTitle.isHidden else { return }
        let request = cardRequest
        let asked = DevPerf.mark()
        let reveal: @MainActor () -> Void = { [weak self] in
            guard let self, self.isLive, self.cardRequest == request else { return }
            if !self.card.isHidden || !self.cardTitle.isHidden { DevPerf.record("live.reveal.\(type(of: self.content))", since: asked) }
            self.card.image = nil
            self.card.isHidden = true
            self.cardTitle.isHidden = true
        }
        content.whenLiveReady(reveal)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealLimit) { reveal() }
    }

    /// A new tile where it wouldn't be live (zoomed out or offscreen) starts as its card, the
    /// title until the card is drawn: its content never shows, so it never loads or lays out
    /// its live view (a batch of dozens of tiles would otherwise build every one live and only
    /// then swap it for its card). Called before the tile joins the canvas; the card is
    /// requested once it is in the window (web content renders in it).
    func startAsCard() {
        guard isLive else { return }
        isLive = false
        cardRequest += 1
        cardTitle.isHidden = false
        showContent(false)
        startCardDue = true
        updateTint()
    }

    private var startCardDue = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        occlusionObserver.map(NotificationCenter.default.removeObserver)
        occlusionObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window?.occlusionState.contains(.visible) == true else { return }
                    self.syncTitle()
                }
            }
        }
        guard let window else { return }
        if window.occlusionState.contains(.visible) { syncTitle() }
        guard startCardDue else { return }
        startCardDue = false
        if !isLive { requestCard() }
    }

    private func requestCard() {
        let request = cardRequest
        let asked = DevPerf.mark()
        let kind = String(describing: type(of: content))
        let started = Metrics.now()
        DevPerf.time("card.call.\(type(of: content))") {
            Metrics.shared.span("card", "card.call.\(kind)", detail: objectID) {
                content.cardSnapshot { [weak self] image in
                    guard let self, !self.isLive, self.cardRequest == request else { return }
                    DevPerf.record("card.latency.\(type(of: self.content))", since: asked)
                    Metrics.shared.record("card.latency.\(kind)", ms: (Metrics.now() - started) * 1000)
                    DevPerf.time("card.install.\(type(of: self.content))") {
                        self.card.image = image.map { self.cardImage($0) }
                        self.card.isHidden = self.card.image == nil
                        self.cardTitle.isHidden = self.card.image != nil
                        self.showContent(false)
                    }
                }
            }
        }
        // A card that never comes (a page that won't load) mustn't keep the content's
        // resources: after a second the tile goes to its title card.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.isLive, self.cardRequest == request, self.contentLive else { return }
            self.cardTitle.isHidden = false
            self.showContent(false)
        }
    }

    /// A card shows the content as it was when the tile went offscreen or zoomed out, and code
    /// and changes tiles watch nothing meanwhile: `view.snapshot` redraws their cards from the
    /// model first (`cardSnapshot` reloads a model that isn't current), so it shows what the
    /// tile holds now.
    func refreshCard() async {
        guard !isLive, !contentLive else { return }
        let request = cardRequest
        let image = await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            content.cardSnapshot { continuation.resume(returning: $0) }
        }
        guard !isLive, cardRequest == request, let image else { return }
        card.image = cardImage(image)
        card.isHidden = false
        cardTitle.isHidden = true
    }

    /// Below the readable zoom: the tile is one handle (click selects, drag moves) and shows its
    /// agent's lifecycle wash, whether it shows a card or lives zoomed out.
    var zoomedOut = false {
        didSet { if zoomedOut != oldValue { updateTint() } }
    }

    private var cardRequest = 0
    private var contentLive = true
    /// Whether this tile's live content counts in `app.metrics` (`live.<Kind>`): while it is on a
    /// board.
    private var countedLive = false

    private func showContent(_ live: Bool) {
        guard live != contentLive else { return }
        contentLive = live
        content.isHidden = !live
        let kind = String(describing: type(of: content))
        if countedLive { Metrics.shared.adjust("live.\(kind)", by: live ? 1 : -1) }
        DevPerf.time("content.\(live ? "live" : "unlive").\(type(of: content))") {
            Metrics.shared.span("card", "flip.\(live ? "live" : "card").\(kind)", detail: objectID) { content.setLive(live) }
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        let onBoard = superview != nil
        guard onBoard != countedLive else { return }
        countedLive = onBoard
        if contentLive { Metrics.shared.adjust("live.\(type(of: content))", by: onBoard ? 1 : -1) }
    }

    /// The card at the body's size and card resolution (content renders at that resolution
    /// already; web snapshots arrive larger and are scaled down so every card costs the same).
    private func cardImage(_ image: NSImage) -> NSImage {
        let size = card.frame.size
        let width = max(1, Int(size.width * Self.cardPixelsPerPoint)), height = max(1, Int(size.height * Self.cardPixelsPerPoint))
        if let rep = image.representations.first, rep.pixelsWide <= width + 1, rep.pixelsHigh <= height + 1 { return image }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        // The context's units are the rep's pixels (its size when the context was made); the rep
        // gets its point size only afterwards.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = size
        let card = NSImage(size: size)
        card.addRepresentation(rep)
        return card
    }

    /// Zoomed-out cards carry the agent's lifecycle color so a board of agents reads at a glance.
    private func updateTint() {
        let color = Self.badgeColor(lifecycleState)
        cardTint.color = color
        cardTint.isHidden = (isLive && !zoomedOut) || color == .clear
    }

    @objc private func closeClicked() {
        onClose?()
    }

    // MARK: Move / resize

    /// The bottom-right corner: drag resizes, ⌥-drag resizes keeping the tile's proportions;
    /// neither changes the content's zoom. 16 points in (at least the handle's half on screen),
    /// and past the corner as far as the handle the canvas draws for a selected tile
    /// (`TileHandles`) reaches, selected or not, inside a group or not: a drag starting just
    /// outside the corner still resizes.
    private var resizeGrip: NSRect {
        let perScreenPoint = convert(NSSize(width: 1, height: 1), from: nil).width
        let reach = TileHandles.reach * perScreenPoint
        let inside = min(max(16, reach), bounds.width / 2, bounds.height / 2)
        return NSRect(x: bounds.width - inside, y: bounds.height - inside, width: inside + reach, height: inside + reach)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if resizeGrip.contains(local) { return self }
        // A zoomed-out card is one handle: click selects, drag moves, double-click focuses.
        if !isLive || zoomedOut, bounds.contains(local) { return self }
        // So is the title bar, but for its buttons (`TileTitleBar`): a press on the title, the
        // dot, a status or the gaps between them selects the tile and turns the keyboard to it,
        // the first click into an inactive window included (the bar's own view takes no first
        // click, so a press on it was lost and typing stayed in the tile that had the keyboard).
        if TileTitleBar.part(at: local, width: bounds.width, zoomControlWidth: zoomControl.isHidden ? 0 : zoomControl.frame.width) == .handle { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if resizeGrip.contains(convert(event.locationInWindow, from: nil)) {
            resizeStart = (event.locationInWindow, frame, event.modifierFlags.contains(.option))
        } else if event.clickCount == 2 {
            onTitleDoubleClick?()
        } else {
            moving = true
            onMoveBegan?(event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if moving { return onMoveDragged?(event) ?? () }
        guard let start = resizeStart, let superview else { return }
        let perPoint = superview.convert(NSSize(width: 1, height: 1), from: nil).width
        let dx = (event.locationInWindow.x - start.mouse.x) * perPoint
        let dy = (start.mouse.y - event.locationInWindow.y) * perPoint
        let w = start.frame.width, h = start.frame.height
        let minimum = NSSize(width: 160, height: 80 + Self.titleHeight)
        if start.proportional {
            // The drag projected on the diagonal: the tile keeps its proportions.
            let ratio = max(((w + dx) * w + (h + dy) * h) / max(w * w + h * h, 1), minimum.width / max(w, 1), minimum.height / max(h, 1))
            setFrameSize(NSSize(width: w * ratio, height: h * ratio))
        } else {
            setFrameSize(NSSize(width: max(minimum.width, w + dx), height: max(minimum.height, h + dy)))
        }
        onResizing?()
    }

    override func mouseUp(with event: NSEvent) {
        if moving {
            moving = false
            onMoveEnded?(event)
        } else if let start = resizeStart, start.frame != frame {
            onFrameCommit?(frame)
        }
        resizeStart = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu?(event) }

    override func resetCursorRects() {
        addCursorRect(resizeGrip, cursor: .crosshair)
        addCursorRect(titleBar.frame, cursor: .openHand)
    }
}

/// A zoomed-out or offscreen tile's card image, named for accessibility like the live tile
/// (its title, state, lines and caption), not an unlabelled image.
private final class CardImageView: NSImageView {
    weak var tile: TileFrameView?

    override func accessibilityLabel() -> String? { tile?.accessibilityLabel() }
}

/// The tile's body at its content zoom (`TileFrameView.zoomView`): a frame the body's size and
/// bounds the body divided by the zoom, holding the content at its bounds. It never resizes the
/// content itself; the tile sets the content's frame once per change.
private final class ContentZoomView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizesSubviews = false
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }
}

/// The title bar's content zoom control, `−  150%  +`: − and + step through `ObjectZoom.levels`,
/// a click on the percentage goes back to 100%. The percentage shows whenever the content isn't
/// at 100%; − and + only while the tile is hovered or selected (`TileFrameView.updateZoomControl`).
/// Object › Content Zoom and its keys (⌃⌘= ⌃⌘- ⌃⌘0) do the same.
private final class TileZoomControl: NSView {
    var onStep: ((Bool) -> Void)?
    var onReset: (() -> Void)?
    private let minus = NSButton()
    private let percent = NSButton()
    private let plus = NSButton()
    private var expanded = false
    /// Wide enough for a − or + at the chrome text scale.
    static var buttonWidth: CGFloat { ChromeText.scaled(18) }
    private static var percentWidths: [Double: CGFloat] = [:]
    /// Room for the widest percentage ("100%", "800%") and the label's padding, at `scale`.
    static func percentWidth(scale: Double) -> CGFloat {
        if let known = percentWidths[scale] { return known }
        let width = (("800%" as NSString).size(withAttributes: [.font: ChromeText.font(TileFrameView.zoomLabelFont, scale: scale)]).width + 10).rounded(.up)
        percentWidths[scale] = width
        return width
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (button, symbol, label, tip) in [(minus, "minus", "Zoom content out", "Zoom Content Out (⌃⌘-)"), (plus, "plus", "Zoom content in", "Zoom Content In (⌃⌘=)")] {
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.setAccessibilityLabel(label)
            button.toolTip = tip
            button.target = self
            button.action = #selector(step(_:))
            addSubview(button)
        }
        percent.isBordered = false
        percent.target = self
        percent.action = #selector(reset)
        percent.toolTip = "Content zoom: click for 100% (⌃⌘0)"
        addSubview(percent)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    /// The control's width as it shows now: the percentage, and − and + beside it when expanded.
    var fittedWidth: CGFloat { Self.percentWidth(scale: ChromeText.scale) + (expanded ? 2 * Self.buttonWidth : 0) }

    /// The symbols and the percentage at the chrome text scale (the percentage when `show` runs).
    func applyScale() {
        for (button, symbol, label) in [(minus, "minus", "Zoom content out"), (plus, "plus", "Zoom content in")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: ChromeText.size(10), weight: .semibold))
        }
        needsLayout = true
    }

    func show(zoom: Double, expanded: Bool, canZoomOut: Bool, canZoomIn: Bool) {
        self.expanded = expanded
        let text = ObjectZoom.percent(zoom)
        percent.attributedTitle = NSAttributedString(string: text, attributes: [.font: ChromeText.font(TileFrameView.zoomLabelFont), .foregroundColor: NSColor.secondaryLabelColor])
        percent.setAccessibilityLabel("Content zoom \(text), reset to 100%")
        minus.isHidden = !expanded
        plus.isHidden = !expanded
        minus.isEnabled = canZoomOut
        plus.isEnabled = canZoomIn
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height, button = Self.buttonWidth, percentWidth = Self.percentWidth(scale: ChromeText.scale)
        if expanded {
            minus.frame = NSRect(x: 0, y: 0, width: button, height: h)
            percent.frame = NSRect(x: button, y: 0, width: percentWidth, height: h)
            plus.frame = NSRect(x: button + percentWidth, y: 0, width: button, height: h)
        } else {
            percent.frame = bounds
        }
    }

    @objc private func step(_ sender: NSButton) { onStep?(sender === plus) }
    @objc private func reset() { onReset?() }
}

/// A tile's close button, named for accessibility after the tile it closes ("Close notes.md").
private final class TileCloseButton: NSButton {
    weak var tile: TileFrameView?

    override func accessibilityLabel() -> String? { "Close \(tile?.title ?? "tile")" }
    override func accessibilityTitle() -> String? { accessibilityLabel() }
}

/// Lifecycle wash over a zoomed-out card, drawn (not a layer color) so snapshots include it.
private final class CardTint: NSView {
    var color: NSColor = .clear { didSet { if color != oldValue { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("draw.CardTint", since: perfStart) }
        color.withAlphaComponent(0.3).setFill()
        bounds.fill()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 8, dy: 8))
        border.lineWidth = 16
        color.setStroke()
        border.stroke()
    }
}
