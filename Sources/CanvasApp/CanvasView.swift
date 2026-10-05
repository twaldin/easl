import AppKit
import CanvasCore

/// Flipped, very large document; canvas coordinates are offset so (0,0) sits in the middle.
/// Mouse input that reaches it landed on empty canvas (marquee, context menu); it also takes
/// keyboard focus for Esc/⌫/⌘A when no terminal holds it.
final class CanvasDocumentView: NSView {
    static let extent: CGFloat = 200_000
    static let origin = NSPoint(x: extent / 2, y: extent / 2)

    weak var canvas: CanvasView?

    // nonisolated: AppKit asks on every coordinate transform, and the @objc thunk of a main-actor
    // override otherwise pays a runtime executor check each time.
    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Canvas gestures work on the first click into an inactive window, like any canvas app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The canvas background at `scale` screen points (or render pixels, with `pixelsPerPoint` 1)
    /// per document unit, for offscreen renders; on screen, `CanvasGrid` draws the same grid
    /// behind the document (which draws nothing itself). One tiled image (RenderMath.gridLevel):
    /// a rect fill per dot left ~100k display-list entries at 10% zoom, and one path of all dots
    /// made Core Animation union every rect on each frame of a pan.
    static func drawBackground(in dirtyRect: NSRect, pointsPerUnit scale: CGFloat, pixelsPerPoint backing: CGFloat) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let (spacing, fade) = RenderMath.gridLevel(scale: Double(scale))
        let period = CGFloat(spacing)
        guard let tile = gridTile(pixels: gridPixels(period * scale * backing), dot: 2 * backing, color: dotColor.cgColor, fade: CGFloat(fade)) else { return }
        context.saveGState()
        context.clip(to: dirtyRect)
        context.draw(tile, in: CGRect(x: -period / 2, y: -period / 2, width: period, height: period), byTiling: true)
        context.restoreGState()
    }

    static var dotColor: NSColor { NSColor.tertiaryLabelColor.withAlphaComponent(0.35) }

    /// An even pixel count, so the tile's center and edge midpoints fall on pixel boundaries.
    static func gridPixels(_ exact: CGFloat) -> Int { max(2, 2 * Int((exact / 2).rounded())) }

    private static var gridTileCache: (key: String, image: CGImage)?

    /// One grid period: the coarse dot in the center, the finer level's three midpoint dots (at
    /// opacity `fade`) on the edges and corners, split across them so tiling reassembles them.
    /// Symmetric, so flipped and unflipped contexts draw the same lattice.
    static func gridTile(pixels: Int, dot: CGFloat, color: CGColor, fade: CGFloat) -> CGImage? {
        let fade = (fade * 32).rounded() / 32
        let key = "\(pixels) \(dot) \(fade) \(color.components ?? [])"
        if let cached = gridTileCache, cached.key == key { return cached.image }
        guard let bitmap = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = CGFloat(pixels), half = size / 2
        func mark(_ x: CGFloat, _ y: CGFloat) { bitmap.fill(CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)) }
        bitmap.setFillColor(color)
        mark(half, half)
        if fade > 0, let faded = color.copy(alpha: color.alpha * fade) {
            bitmap.setFillColor(faded)
            for (x, y) in [(0, half), (half, 0), (0, 0)] as [(CGFloat, CGFloat)] {
                for dx in [0, size] where x == 0 || dx == 0 {
                    for dy in [0, size] where y == 0 || dy == 0 { mark(x + dx, y + dy) }
                }
            }
        }
        guard let image = bitmap.makeImage() else { return nil }
        gridTileCache = (key, image)
        return image
    }

    override func mouseDown(with event: NSEvent) { canvas?.emptyMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { canvas?.emptyMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { canvas?.emptyMouseUp(event) }
    override func menu(for event: NSEvent) -> NSMenu? { canvas?.emptyCanvasMenu(at: convert(event.locationInWindow, from: nil)) }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let plain = modifiers.isEmpty
        // Return hands the keyboard to the one selected tile (Esc in it hands it back).
        if plain, KeyboardFocus.entersSelection(keyCode: event.keyCode), canvas?.enterSelection() == true { return }
        // Tab (⇧Tab) goes to an open panel's buttons, else nowhere: it never types into a tile.
        if event.keyCode == 48, plain || modifiers == .shift {
            _ = canvas?.onTab?(modifiers == .shift)
            return
        }
        switch event.keyCode {
        case 53: cancelOperation(nil)
        case 51, 117: deleteBackward(nil)
        default:
            // A selected changes tile's keys say to press Return first (they act once it has the keyboard).
            if canvas?.selectedChangesTile?.keyWhileSelected(event) == true { return }
            // A ⌃-chord that is a ⌘ shortcut on a Mac says so (`noticeMacKey`).
            if canvas?.noticeMacKey(for: event) == true { return }
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { canvas?.escape() }
    override func deleteBackward(_ sender: Any?) { canvas?.deleteSelection() }
    override func deleteForward(_ sender: Any?) { canvas?.deleteSelection() }
    override func selectAll(_ sender: Any?) { canvas?.selectAll() }
}

/// The pan/zoom scene for one board: tiles are real NSViews positioned by object frames; groups
/// are regions behind them; drawings (installed by the drawing layer) and the overlay sit above.
/// Zoom is capped at 100%; below `liveThreshold` tiles become cards and release resources.
/// The viewport only moves on user input, never in response to agents.
@MainActor
final class CanvasView: NSScrollView {
    static let liveThreshold = CGFloat(RenderMath.liveThreshold)
    /// Live tiles turn to cards only below this share of their live zoom, and offscreen only past
    /// `cardMargin`: a zoom or pan resting near an edge must not flip tiles back and forth.
    static let cardHysteresis: CGFloat = 0.9
    static let liveMargin: CGFloat = 300
    static let cardMargin: CGFloat = 600
    static let lassoDefaultsKey = "canvas.lassoSelection"

    /// Marquee drags draw a freehand lasso instead of a box (View menu, persisted).
    static var lassoSelection: Bool {
        get { UserDefaults.standard.bool(forKey: lassoDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: lassoDefaultsKey) }
    }

    let board: Board
    let document = CanvasDocumentView(frame: NSRect(x: 0, y: 0, width: CanvasDocumentView.extent, height: CanvasDocumentView.extent))
    let overlay = SceneOverlay(frame: NSRect(x: 0, y: 0, width: CanvasDocumentView.extent, height: CanvasDocumentView.extent))
    private let attention = AttentionLayer()
    private let edges = AttentionEdgeView()
    /// Selected tiles' resize handles, above the markers.
    private let handles = TileHandles()
    private let grid = CanvasGrid()
    private(set) var tiles: [ObjectID: TileFrameView] = [:]
    private(set) var groups: [ObjectID: GroupView] = [:]
    /// Each terminal's name as the author marks of its agent's objects show it (`AuthorMarks`).
    var authorNames: [ObjectID: String] = [:]
    private var markers: [ObjectID: AttentionMarker] = [:]
    /// Terminals whose agent is blocked (waiting on the user), each with a ring and a bubble of
    /// its lifecycle message while on screen and an edge pill while offscreen, like a marker's
    /// but in the blocked style (`AttentionStyle`).
    private var blocked: [ObjectID: AttentionMarker] = [:]
    private(set) var selection: Set<ObjectID> = []
    /// The group being worked in: zoomed to, everything else dimmed.
    private(set) var enteredGroup: ObjectID?
    /// Read by drawing-layer extensions (e.g. hiding handles while rendering an object image).
    private(set) var shapeLayer: NSView?

    private var livenessScheduled = false
    private var geometryDirty = false
    private var magnifying = false
    private var move: MoveGesture?
    private var marquee: MarqueeGesture?
    /// A press on a drawn object is tracked here (the event never reaches a view).
    private var shapePress = false
    private var mouseMonitor: Any?
    /// Terminals seen since their agent last started working (mirrors Board's seen set).
    private var seenLocally: Set<ObjectID> = []
    /// Who the activity log credits for viewport moves: the user, except while the app moves it.
    private var viewportMover: ActivityActor = .user
    private var activitySettle: DispatchWorkItem?
    /// This client's record of where the view was left (`SavedViewport`), not the board's.
    private var viewportRecorder: SavedViewport.Recorder
    /// Whether the opening view is in place: nothing is saved before it, or a board closed in its
    /// first turn would record the unplaced view over the real one.
    private var viewPlaced = false
    private var viewportSave: DispatchWorkItem?
    /// The saved view this board opened with, held until the user first moves the view: the
    /// window can still change size after the board opens (a tab joining the group, the saved
    /// frame, a hidden tab shown), and the view shows that centre through it, not the corner
    /// AppKit keeps fixed.
    private var openedAtSavedView: SavedViewport?
    private var restoringView = false
    private var restoredView = (origin: CGPoint.zero, zoom: CGFloat(1))
    private lazy var seen = SeenTracker { [weak self] id in self?.didSee(id) }

    /// Where the tray drains and Superwhisper pastes (`PromptTarget`; the window controller
    /// settles it).
    var promptTarget: ObjectID? { didSet { onPromptTargetChange?() } }
    var onPromptTargetChange: (() -> Void)?
    /// The prompt target, or the terminal holding the keyboard, retitled itself (an agent's OSC
    /// title); the tray names them by that.
    var onPromptTargetTitle: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    /// Tab (true: ⇧Tab) with the canvas holding the keyboard: an open panel (Get Started) takes
    /// it at its first (last) button; false when none is open.
    var onTab: ((Bool) -> Bool)?
    /// Whether a panel is open over the board that Esc on the canvas closes once nothing else
    /// is left to leave (Get Started), and closing it.
    var panelOpen: (() -> Bool)?
    var closePanel: (() -> Void)?

    // MARK: Drawn objects (installed by the drawing layer)

    /// The shape or arrow drawn at a document point. Only strokes, text, and fills hit, so an
    /// empty shape interior never blocks the tiles beneath; drawn objects sit above tiles.
    var shapeHitTest: ((NSPoint) -> ObjectID?)?
    /// Document-space outline of a drawn object at its committed position.
    var shapeOutline: ((ObjectID) -> NSRect?)?
    /// True where the drawing layer handles the mouse itself (active tool, shape handles);
    /// scene selection, marquee, and moves stand down there.
    var drawingOwnsPoint: (NSPoint) -> Bool = { _ in false }
    /// Extra props to merge into a drawn object's move (e.g. translated free arrow endpoints).
    var moveProps: ((CanvasObject, _ dx: Double, _ dy: Double) -> JSONValue?)?
    /// Live offset (document points) of drawn objects being dragged; `.zero` right before commit.
    var onSelectionDrag: ((Set<ObjectID>, NSSize) -> Void)?

    private struct MoveGesture {
        var start: NSPoint
        /// Pressed object that was already part of a multi-selection: a click without a drag
        /// narrows the selection to it.
        var collapseTo: ObjectID?
        var tileOrigins: [ObjectID: NSPoint]
        var drawn: [ObjectID: NSRect]
        var delta = NSSize.zero
    }

    private struct MarqueeGesture {
        var start: NSPoint
        var points: [NSPoint]
        var base: Set<ObjectID>
        var lasso: Bool
    }

    init(board: Board) {
        self.board = board
        viewportRecorder = SavedViewport.Recorder(store: SavedViewport.Store(url: AppPaths.viewport(of: board.id)))
        super.init(frame: .zero)
        documentView = document
        document.canvas = self
        document.addSubview(overlay)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.1
        maxMagnification = 1.0
        drawsBackground = false
        addSubview(grid, positioned: .below, relativeTo: contentView)
        addSubview(attention)
        addSubview(edges)
        addSubview(handles)
        edges.onReveal = { [weak self] id in self?.jumpToAttention(id) }
        contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        // A window resize changes what's visible without moving the bounds origin.
        contentView.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.frameDidChangeNotification, object: contentView)
        center.addObserver(self, selector: #selector(magnifyStarted), name: NSScrollView.willStartLiveMagnifyNotification, object: self)
        center.addObserver(self, selector: #selector(magnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
        center.addObserver(self, selector: #selector(boundsChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(boundsChanged), name: NSApplication.didResignActiveNotification, object: nil)
        // Placement aims at what the user can see: the viewport clear of the toolbar and tray.
        board.viewport = { [weak self] in self?.clearViewport }
        // A mention of a shape drawn on a page lists the elements under it.
        board.pageElements = { [weak self] id, rect in await self?.pageElements(id, canvasRect: rect) }
        // Mentions name a terminal as its header does, one of a whole terminal carries its screen,
        // and one of a command's block says which `agent.read` block it is.
        board.terminalLabel = { [weak self] id in (self?.tiles[id]?.content as? TerminalTile)?.label }
        board.terminalScreen = { [weak self] id in (self?.tiles[id]?.content as? TerminalTile)?.shownText() }
        board.terminalBlockIndex = { [weak self] id, command in (self?.tiles[id]?.content as? TerminalTile)?.blockIndex(of: command) }
        for object in board.snapshot.objects { add(object) }
        // Markers the user hadn't seen when the board was last open.
        for marker in board.attention.values { showMarker(marker.object, message: marker.message) }
        restack()
        refreshGroups()
        DispatchQueue.main.async { [weak self] in self?.placeOpeningView() }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func tile() {
        super.tile()
        attention.frame = bounds
        edges.frame = bounds
        handles.frame = bounds
        grid.frame = bounds
        updateGrid()
    }

    private func updateGrid() {
        grid.update(origin: grid.convert(NSPoint.zero, from: document), scale: magnification)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            // Not `self?.handleMouse(event) ?? event`: that turns "consumed" (nil) back into the event.
            guard let self else { return event }
            return self.handleMouse(event)
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(boundsChanged), name: NSWindow.didResignKeyNotification, object: window)
        window.initialFirstResponder = document
    }

    // MARK: Coordinates

    /// Document rect of an object's frame: a tile's whole drawn box (title bar included), a
    /// drawn object's box.
    static func docRect(_ frame: Frame) -> NSRect {
        NSRect(x: frame.x + CanvasDocumentView.origin.x, y: frame.y + CanvasDocumentView.origin.y, width: frame.w, height: frame.h)
    }

    static func canvasFrame(_ rect: NSRect) -> Frame {
        Frame(x: rect.minX - CanvasDocumentView.origin.x, y: rect.minY - CanvasDocumentView.origin.y, w: rect.width, h: rect.height)
    }

    /// Where an object is on screen right now, in document coordinates, including an in-flight drag.
    func docFrame(_ id: ObjectID) -> NSRect? {
        if let tile = tiles[id] { return tile.frame }
        if let group = groups[id] { return group.isHidden ? nil : group.region }
        if let start = move?.drawn[id], let delta = move?.delta { return start.offsetBy(dx: delta.width, dy: delta.height) }
        guard let object = board.objects[id] else { return nil }
        return shapeOutline?(id) ?? Self.docRect(object.frame)
    }

    private func docPoint(_ event: NSEvent) -> NSPoint {
        document.convert(event.locationInWindow, from: nil)
    }

    // MARK: Reconciliation

    func apply(_ event: BoardEvent) {
        switch event {
        case .objectCreated(let object):
            add(object)
            restack()
            scheduleGeometry()
        case .objectUpdated(let object):
            if object.type == .group {
                groups[object.id]?.update(object)
            } else if let tile = tiles[object.id] {
                // The user's own resize already laid the content out at this size; any other
                // (an agent's update or fit, undo) re-aims a code tile at its range.
                let body = tile.content.frame.size
                // Readable is the board's magnification times the content's zoom.
                if tile.zoom != CGFloat(object.zoom) { scheduleLiveness() }
                tile.place(Self.docRect(object.frame), zoom: CGFloat(object.zoom))
                let restacks = tile.z != object.z
                tile.update(object)
                if tile.content.frame.size != body, let code = tile.content as? CodeTile { code.resizedElsewhere() }
                if restacks { restack() }
                if object.type == .terminal {
                    lifecycleChanged(object)
                    syncAuthors(of: object.id)
                }
            } else {
                add(object)
            }
            scheduleGeometry()
        case .objectDeleted(let id):
            tiles.removeValue(forKey: id)?.removeFromSuperview()
            groups.removeValue(forKey: id)?.removeFromSuperview()
            if enteredGroup == id { exitGroup() }
            hideMarker(id)
            if let view = blocked.removeValue(forKey: id) {
                view.removeFromSuperview()
                layoutPills()
            }
            seenLocally.remove(id)
            if selection.contains(id) { setSelection(selection.subtracting([id])) }
            syncAuthors(of: id)
            scheduleGeometry()
        case .attentionChanged(let id, let marker):
            if let marker { showMarker(id, message: marker.message) } else { hideMarker(id) }
        default: break
        }
    }

    private func add(_ object: CanvasObject) {
        if object.type == .group { return addGroup(object) }
        guard tiles[object.id] == nil, TileFactory.hasTile(object.type) else { return }
        let id = object.id
        let content = TileFactory.make(object, board: board)
        if chromeHidden { (content as? CodeTile)?.setPresenting(true) }
        if let terminal = content as? TerminalTile {
            terminal.onTitle = { [weak self] title in
                self?.tiles[id]?.setTitle(title)
                // The tray names the target and, when typing goes elsewhere, the terminal typing goes to.
                if self?.promptTarget == id || self?.focusedTerminal == id { self?.onPromptTargetTitle?() }
                // The foreground program changed, maybe: it names the terminal's objects.
                self?.syncAuthors(of: id)
            }
            terminal.onStatus = { [weak self] status, failed, detail in self?.tiles[id]?.setStatus(status, failed: failed, detail: detail) }
            // A ⌘-clicked reference: user navigation. A tile already showing it anywhere on the
            // board is gone to (`goToShown`); the re-aimed preview is selected (keyboard focus
            // stays in the terminal). A preview or new tile pans the view only when it is mostly
            // out of view, never so far that the reference goes.
            terminal.onOpenedCode = { [weak self] opened, source in
                guard let self else { return }
                let from = self.viewport
                if opened.existing {
                    self.goToShown(opened.id)
                } else {
                    if !opened.created { self.setSelection([opened.id]) }
                    self.reveal(opened.id, openedFrom: source.isNull ? .null : self.document.convert(source, from: nil))
                }
                self.recordNavigation(from: from, reaim: opened.reaim, landing: self.board.objects[opened.id].flatMap(CodeAim.init))
            }
            terminal.onOpenedLink = { [weak self] opened in self?.showOpenedLink(opened, openedFrom: id) }
        }
        // A page's or note's code link (an HTML tile's, a browser page's error list, a note's):
        // the tile already showing the lines is gone to, anything else is shown with the least pan.
        let showCode = { [weak self] (opened: ObjectID, existing: Bool) -> Void in self?.showOpenedCode(opened, existing: existing) }
        (content as? HtmlTile)?.onOpenedCode = showCode
        (content as? NoteTile)?.onOpenedCode = showCode
        (content as? BrowserTile)?.onOpenedCode = showCode
        (content as? DiagramTile)?.onOpenedCode = showCode
        // A web link a note or HTML tile opened (`Board.openLink`): shown like a terminal's.
        (content as? HtmlTile)?.onOpenedLink = { [weak self] opened in self?.showOpenedLink(opened, openedFrom: id) }
        (content as? NoteTile)?.onOpenedLink = { [weak self] opened in self?.showOpenedLink(opened, openedFrom: id) }
        // A node the user opened: the pan that shows what it added (never for an agent's expand).
        (content as? DiagramTile)?.onExpanded = { [weak self] tile, added, clicked in self?.revealExpansion(tile: tile, added: added, clicked: clicked) }
        // A clicked line: user navigation. The changes tile keeps the selection and the keyboard
        // (j/k go on through the hunks; a selected code tile would take the keyboard from it);
        // the least pan that shows the code tile keeps the diff in view too.
        (content as? ChangesTile)?.onOpenedCode = { [weak self] opened, _ in
            self?.reveal(opened, keeping: id)
        }
        (content as? ChangesTile)?.onBranch = { [weak self] branch in
            guard let self, let object = self.board.objects[id] else { return }
            self.tiles[id]?.setBranch(branch, of: object)
        }
        (content as? BrowserTile)?.onOpenedTile = { [weak self] opened in
            self?.reveal(opened)
            self?.setSelection([opened])
        }
        let tile = TileFrameView(object: object, content: content, frame: Self.docRect(object.frame))
        tile.onFrameCommit = { [weak self] rect in
            _ = try? self?.board.update(id, frame: Self.canvasFrame(rect))
        }
        tile.onZoom = { [weak self] zoom in
            guard let self, let object = self.board.objects[id] else { return }
            self.setZoom(zoom, of: [object])
        }
        tile.onResizing = { [weak self] in self?.objectsMoved() }
        tile.onClose = { [weak self] in self?.delete([id]) }
        tile.onMoveBegan = { [weak self] event in self?.beginMove(event, pressing: id) }
        tile.onMoveDragged = { [weak self] event in self?.dragMove(event) }
        tile.onMoveEnded = { [weak self] event in self?.endMove(event) }
        tile.onTitleDoubleClick = { [weak self] in self?.focus(tile: id) }
        tile.onMenu = { [weak self, weak tile] event in
            // A right-click on the tile's body mentions what is under it; on its title bar, the tile.
            let point = tile.map { $0.content.convert(event.locationInWindow, from: nil) }
            return self?.objectMenu(for: id, at: point.flatMap { point in tile?.content.bounds.contains(point) == true ? point : nil })
        }
        // Created where it wouldn't be live (a batch building a board zoomed out or offscreen),
        // a code, note, or HTML tile starts as its card rather than building its live view for
        // the liveness pass to swap out. Terminals and browsers start live: they run a session
        // or a page an agent may be driving.
        if object.type != .terminal, object.type != .browser, !magnifying, !shouldBeLive(tile, scale: magnification) { tile.startAsCard() }
        document.addSubview(tile, positioned: .below, relativeTo: shapeLayer ?? overlay)
        tiles[id] = tile
        tile.zoomedOut = RenderMath.isZoomedOut(magnification: magnification, zoom: tile.zoom)
        if object.type == .terminal { lifecycleChanged(object) }
        if object.type == .terminal { syncAuthors(of: id) } else { tile.setAuthor(authorName(of: object)) }
        scheduleLiveness()
    }

    private func addGroup(_ object: CanvasObject) {
        guard groups[object.id] == nil, let view = GroupView(object: object) else { return }
        let id = object.id
        view.onPress = { [weak self] event in self?.beginMove(event, pressing: id) }
        view.onDrag = { [weak self] event in self?.dragMove(event) }
        view.onRelease = { [weak self] event in self?.endMove(event) }
        view.onEnter = { [weak self] in self?.enter(group: id) }
        view.onMenu = { [weak self] in self?.groupMenu(for: id) }
        document.addSubview(view, positioned: .below, relativeTo: nil)
        groups[id] = view
        view.author = authorName(of: object)
    }

    /// Orders document subviews: group regions, tiles by `z`, the drawing layer, then the
    /// overlay. Reorders in place so tiles never leave the window.
    private func restack() {
        document.sortSubviews({ a, b, _ in
            MainActor.assumeIsolated {
                let lhs = CanvasView.stackRank(a), rhs = CanvasView.stackRank(b)
                return lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
            }
        }, context: nil)
    }

    private static func stackRank(_ view: NSView) -> (Int, Double) {
        switch view {
        case is GroupView: (0, 0)
        case let tile as TileFrameView: (1, tile.z)
        case is SceneOverlay: (4, 0)
        default: (2, 0)
        }
    }

    /// The drawing layer sits above tiles and below the overlay.
    func installShapeLayer(_ view: NSView) {
        shapeLayer = view
        document.addSubview(view, positioned: .below, relativeTo: overlay)
        restack()
    }

    /// Board changes re-lay out what's drawn around objects on the next turn, after every other
    /// consumer of the event (the drawing layer's outlines) has caught up, then re-run culling,
    /// edge pills, and seen eligibility, since an object may have moved into or out of view.
    private func scheduleGeometry() {
        geometryDirty = true
        scheduleLiveness()
    }

    /// Geometry changed (moves, resizes, deletes, drags): everything drawn around objects follows.
    private func objectsMoved() {
        refreshRings()
        refreshGroups()
        layoutPills()
        refreshFocusHoles()
    }

    // MARK: Selection

    func select(_ id: ObjectID, extend: Bool) {
        if extend {
            setSelection(selection.symmetricDifference([id]))
        } else {
            setSelection([id])
            (tiles[id]?.content as? TerminalTile)?.focus()
        }
    }

    func setSelection(_ ids: Set<ObjectID>) {
        guard ids != selection else { return }
        let added = ids.subtracting(selection)
        let removed = selection.subtracting(ids)
        selection = ids
        for (id, group) in groups { group.isSelected = !chromeHidden && ids.contains(id) }
        for id in added.union(removed) { tiles[id]?.isSelected = !chromeHidden && ids.contains(id) }
        board.activity.selectionChanged(Array(ids), actor: .user, rev: board.revision)
        scheduleActivitySettle()
        refreshRings()
        // Selecting a marked object is the user acknowledging it.
        for id in added where markers[id] != nil { board.clearAttention(id) }
        // The keyboard never stays behind in a tile the selection left (`KeyboardFocus`).
        hand(KeyboardFocus.afterSelectionChange(ids, holder: keyboardHolder))
        onSelectionChange?()
    }

    /// The tile holding the keyboard, for `KeyboardFocus`.
    private var keyboardHolder: KeyboardFocus.Holder? {
        focusedTile.map { KeyboardFocus.Holder($0, isTerminal: tiles[$0]?.content is TerminalTile) }
    }

    /// Moves the keyboard as `KeyboardFocus` decided.
    private func hand(_ handoff: KeyboardFocus.Handoff) {
        switch handoff {
        case .stay: break
        case .canvas: window?.makeFirstResponder(document)
        case .terminal(let id): (tiles[id]?.content as? TerminalTile)?.focus()
        }
    }

    func selectAll() {
        let scope = enteredGroup.flatMap { groups[$0]?.members }.map(Set.init)
        setSelection(Set(selectableRects().map(\.id).filter { scope?.contains($0) ?? true }))
    }

    private func refreshRings() {
        overlay.rings = chromeHidden ? [] : selection.sorted().compactMap { id in
            guard groups[id] == nil, let rect = docFrame(id) else { return nil }
            return SceneOverlay.Ring(rect: rect, dashed: tiles[id] == nil)
        }
        placeHandles()
    }

    /// Selected tiles' resize handles, where their corners are on screen now.
    private func placeHandles() {
        let visible = documentVisibleRect
        handles.corners = chromeHidden ? [] : selection.sorted().compactMap { tiles[$0] }.filter { $0.frame.intersects(visible) }
            .map { handles.convert(NSPoint(x: $0.frame.maxX, y: $0.frame.maxY), from: document) }
    }

    /// A press on an object's handle (title bar, drawn stroke, group label): a plain press on an
    /// unselected object selects just it; on a selected one it keeps the selection for dragging.
    /// A plain press on a tile's title bar also turns the keyboard to that tile (a terminal) or
    /// the canvas, away from whatever had it (`KeyboardFocus.afterTitleBarPress`).
    private func press(_ id: ObjectID, extend: Bool) -> ObjectID? {
        if extend {
            setSelection(selection.symmetricDifference([id]))
            return nil
        }
        let holder = keyboardHolder
        defer {
            if let tile = tiles[id] {
                lastClickedTile = id
                hand(KeyboardFocus.afterTitleBarPress(on: id, isTerminal: tile.content is TerminalTile, holder: holder))
            }
        }
        if selection.contains(id) { return selection.count > 1 ? id : nil }
        select(id, extend: false)
        return nil
    }

    /// The tile the user last clicked (its body or title bar): Code ▸ commands fall back to it
    /// (`KeyboardFocus.codeTarget`).
    private var lastClickedTile: ObjectID?

    /// Selection with groups expanded to their members: what a move or new group acts on.
    private func expandedSelection() -> [ObjectID] {
        var ids: Set<ObjectID> = []
        for id in selection {
            if let group = groups[id] {
                ids.formUnion(group.members.filter { board.objects[$0] != nil && groups[$0] == nil })
            } else if board.objects[id] != nil {
                ids.insert(id)
            }
        }
        return ids.sorted()
    }

    private func selectableRects() -> [(id: ObjectID, rect: NSRect)] {
        board.objects.values.compactMap { object in
            guard object.type != .group else { return nil }
            // Drawn objects: rendered bounds (an arrow reroutes with its tiles without a frame write).
            return (object.id, tiles[object.id]?.frame ?? shapeOutline?(object.id) ?? Self.docRect(object.frame))
        }
    }

    /// Tiles and drawn objects wholly inside a document rect, with the groups it encloses and
    /// the arrows between what it selects (`SelectionScope.marquee`).
    func objects(inDocRect rect: NSRect) -> [ObjectID] {
        marqueeSelection { rect.contains($0) }
    }

    /// Tiles and drawn objects wholly inside a lasso drawn in document coordinates, with the
    /// groups it encloses and the arrows between what it selects.
    func objects(inLasso points: [NSPoint]) -> [ObjectID] {
        let lasso = Lasso(points: points.map { (Double($0.x), Double($0.y)) })
        return marqueeSelection { lasso.contains(Frame(x: $0.minX, y: $0.minY, w: $0.width, h: $0.height)) }
    }

    private func marqueeSelection(encloses: (NSRect) -> Bool) -> [ObjectID] {
        let enclosed = Set(selectableRects().filter { encloses($0.rect) }.map(\.id))
        let scopeGroups = groups.values.map { SelectionScope.Group(id: $0.objectID, members: $0.members, enclosed: !$0.isHidden && !$0.region.isEmpty && encloses($0.region)) }
        let arrows = board.objects.values.compactMap { object in
            ArrowSpec(object.props).flatMap { object.type == .arrow ? SelectionScope.Arrow(id: object.id, from: $0.from.objectID, to: $0.to.objectID) : nil }
        }
        return SelectionScope.marquee(enclosed: enclosed, groups: scopeGroups, arrows: arrows).sorted()
    }

    // MARK: Mouse

    /// Clicks that land on tiles or drawings, seen before any view: tile bodies select their tile
    /// and still receive the click (a terminal keeps focusing); drawn objects are selected and
    /// dragged here because they have no view of their own.
    private func handleMouse(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, !HyperMonitor.isHyper(event.modifierFlags) else { return event }
        switch event.type {
        case .leftMouseDown:
            guard let hit = hitView(event), hit.isDescendant(of: document) else { return event }
            let point = docPoint(event)
            if drawingOwnsPoint(point) { return event }
            if let shape = shapeHitTest?(point) {
                if event.clickCount >= 2 { return event }
                shapePress = true
                beginMove(event, pressing: shape)
                return nil
            }
            var view: NSView? = hit
            while let current = view, !(current is TileFrameView) { view = current.superview }
            if let tile = view as? TileFrameView, tile.isLive, hit.isDescendant(of: tile.content) {
                // ⇧-click inside a tile is the tile's own (extending a text or line selection):
                // it selects just that tile, as a plain click does; title bars ⇧-click to add.
                lastClickedTile = tile.objectID
                select(tile.objectID, extend: false)
            } else if let tile = view as? TileFrameView, hit !== tile, !event.modifierFlags.contains(.shift) {
                // A title-bar button (close, content zoom; the rest of the bar is the tile's own
                // handle, `TileTitleBar`): the user turned to the tile, as a press on its bar does.
                _ = press(tile.objectID, extend: false)
            }
            return event
        case .leftMouseDragged where shapePress:
            dragMove(event)
            return nil
        case .leftMouseUp where shapePress:
            shapePress = false
            endMove(event)
            return nil
        default:
            return event
        }
    }

    private func hitView(_ event: NSEvent) -> NSView? {
        guard let content = window?.contentView, let frame = content.superview else { return nil }
        return content.hitTest(frame.convert(event.locationInWindow, from: nil))
    }

    private var terminalHasFocus: Bool {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if current is TerminalTile { return true }
            view = current.superview
        }
        return false
    }

    func emptyMouseDown(_ event: NSEvent) {
        // Keyboard focus stays in the prompt terminal while the mouse selects; otherwise the
        // canvas takes it so Esc, Delete, and ⌘A act on the selection.
        if !terminalHasFocus { window?.makeFirstResponder(document) }
        let extend = event.modifierFlags.contains(.shift)
        if !extend { setSelection([]) }
        let point = docPoint(event)
        marquee = MarqueeGesture(start: point, points: [point], base: selection, lasso: Self.lassoSelection)
    }

    func emptyMouseDragged(_ event: NSEvent) {
        guard var gesture = marquee else { return }
        let point = docPoint(event)
        if gesture.lasso {
            if let last = gesture.points.last, hypot(point.x - last.x, point.y - last.y) * magnification < 3 { return }
            gesture.points.append(point)
            let path = NSBezierPath()
            path.move(to: gesture.points[0])
            gesture.points.dropFirst().forEach(path.line(to:))
            path.close()
            path.lineWidth = 1 / max(magnification, 0.05)
            overlay.marquee = path
        } else {
            gesture.points = [gesture.start, point]
            let rect = HyperMonitor.rect(gesture.start, point)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1 / max(magnification, 0.05)
            overlay.marquee = path
            // Box containment is cheap enough to show live.
            setSelection(gesture.base.union(objects(inDocRect: rect)))
        }
        marquee = gesture
    }

    func emptyMouseUp(_ event: NSEvent) {
        guard let gesture = marquee else { return }
        marquee = nil
        overlay.marquee = nil
        if gesture.lasso, gesture.points.count >= 3 {
            setSelection(gesture.base.union(objects(inLasso: gesture.points)))
        }
    }

    private func beginMove(_ event: NSEvent, pressing id: ObjectID) {
        let collapse = press(id, extend: event.modifierFlags.contains(.shift))
        var origins: [ObjectID: NSPoint] = [:]
        var drawn: [ObjectID: NSRect] = [:]
        for id in expandedSelection() {
            if let tile = tiles[id] {
                origins[id] = tile.frame.origin
            } else if let rect = docFrame(id) {
                drawn[id] = rect
            }
        }
        move = MoveGesture(start: docPoint(event), collapseTo: collapse, tileOrigins: origins, drawn: drawn)
    }

    private func dragMove(_ event: NSEvent) {
        guard var gesture = move else { return }
        let point = docPoint(event)
        gesture.delta = NSSize(width: point.x - gesture.start.x, height: point.y - gesture.start.y)
        move = gesture
        for (id, origin) in gesture.tileOrigins {
            tiles[id]?.setFrameOrigin(NSPoint(x: origin.x + gesture.delta.width, y: origin.y + gesture.delta.height))
        }
        if !gesture.drawn.isEmpty { onSelectionDrag?(Set(gesture.drawn.keys), gesture.delta) }
        objectsMoved()
    }

    /// One board update per moved object, as one undo step; groups re-bound themselves.
    private func endMove(_ event: NSEvent) {
        guard let gesture = move else { return }
        move = nil
        guard gesture.delta != .zero else {
            if let id = gesture.collapseTo { setSelection([id]) }
            return
        }
        if !gesture.drawn.isEmpty { onSelectionDrag?(Set(gesture.drawn.keys), .zero) }
        let dx = Double(gesture.delta.width), dy = Double(gesture.delta.height)
        let moved = Set(gesture.tileOrigins.keys).union(gesture.drawn.keys)
        board.transaction {
            for id in moved.sorted() {
                guard let object = board.objects[id] else { continue }
                var frame = object.frame
                frame.x += dx
                frame.y += dy
                _ = try? board.update(id, frame: frame, props: tiles[id] == nil ? moveProps?(object, dx, dy) : nil)
            }
        }
    }

    // MARK: Groups

    /// Group regions follow their members live (mid-drag too), the same way the board fits
    /// their frames on commit; nested groups count with their committed frames.
    private func refreshGroups() {
        for group in groups.values {
            let rects = group.members.compactMap { id -> NSRect? in
                guard board.objects[id]?.type != .arrow else { return nil }
                if groups[id] != nil { return board.objects[id].map { Self.docRect($0.frame) } }
                return docFrame(id)
            }
            if let region = group.spec.frame(around: rects) {
                group.show(region: region)
                group.isHidden = false
            } else {
                group.isHidden = true
            }
        }
    }

    func groupSelection() {
        let members = expandedSelection()
        guard members.count >= 2, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Group \(members.count) objects"
        alert.informativeText = "Name the group (optional)."
        alert.addButton(withTitle: "Group")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Group"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.createGroup(members, name: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func createGroup(_ members: [ObjectID], name: String) {
        guard members.count >= 2 else { return }
        var props: [String: JSONValue] = ["members": .array(members.map(JSONValue.string))]
        if !name.isEmpty { props["title"] = .string(name) }
        let group = board.create(type: .group, props: .object(props))
        setSelection([group.id])
    }

    /// Deletes the selected groups, and groups containing selected objects; members stay.
    func ungroupSelection() {
        let ids = groups.values.filter { selection.contains($0.objectID) || !selection.isDisjoint(with: $0.members) }
        guard !ids.isEmpty else { return }
        let members = Set(ids.flatMap(\.members))
        board.transaction {
            for group in ids { try? board.delete(group.objectID) }
        }
        setSelection(members.filter { board.objects[$0] != nil })
    }

    func enter(group id: ObjectID) {
        guard let view = groups[id], !view.isHidden else { return }
        enteredGroup = id
        setSelection([])
        fit(view.frame)
        refreshFocusHoles()
    }

    func exitGroup() {
        enteredGroup = nil
        overlay.focusHoles = nil
    }

    private func refreshFocusHoles() {
        guard let id = enteredGroup, let view = groups[id] else { return }
        let holes = view.isHidden ? [] : [view.frame]
        if overlay.focusHoles != holes { overlay.focusHoles = holes }
    }

    // MARK: Commands

    func escape() {
        switch KeyboardFocus.escape(chromeHidden: chromeHidden, inGroup: enteredGroup != nil, hasSelection: !selection.isEmpty, panelOpen: panelOpen?() ?? false) {
        case .showChrome: chromeHidden = false
        case .exitGroup: exitGroup()
        case .deselect: setSelection([])
        case .closePanel: closePanel?()
        case .none: break
        }
    }

    func deleteSelection() {
        delete(Array(selection))
    }

    /// Deletes objects as one undo step. Closing a terminal ends its zmx session (the board
    /// reports it ended; see AppDelegate), so ask first, in a sheet: an app-modal alert would
    /// stall every socket request until answered. `selectingNext`: ⌘W keeps going, the nearest
    /// remaining tile takes the selection (and a terminal the keyboard), so the next ⌘W closes
    /// that rather than the window.
    func delete(_ ids: [ObjectID], selectingNext: Bool = false) {
        guard !ids.isEmpty else { return }
        let terminals = ids.filter { tiles[$0]?.content is TerminalTile }
        guard !terminals.isEmpty else { return remove(ids, selectingNext: selectingNext) }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = terminals.count == 1 ? "Close this terminal?" : "Close \(terminals.count) terminals?"
        // What ends, by name: the foreground program and what it or the shell started.
        alert.informativeText = SessionProcesses.closingText(terminals.map { (tiles[$0]?.content as? TerminalTile)?.sessionProcesses() })
        // Return and Esc cancel: closing ends running work, so it takes a click or ⌘⌫, which
        // the button names (a sheet's buttons show no key equivalent themselves).
        alert.addButton(withTitle: "Cancel")
        let close = alert.addButton(withTitle: "Close  ⌘⌫")
        close.setAccessibilityLabel("Close")
        close.setAccessibilityHelp("Command-Delete closes")
        close.keyEquivalent = "\u{8}"
        close.keyEquivalentModifierMask = .command
        close.hasDestructiveAction = true
        let previous = window.firstResponder
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertSecondButtonReturn else {
                // Cancelled: the keyboard goes back to whoever had it (the terminal asked about).
                if let window = self.window { Self.returnKeyboard(to: previous, in: window) }
                return
            }
            // The board may have changed while the sheet was up.
            self.remove(ids.filter { self.board.objects[$0] != nil }, selectingNext: selectingNext)
        }
    }

    /// Deletes objects as one undo step without asking (the close sheet, or the board's own
    /// close sheet in `CanvasWindowController`, has).
    func remove(_ ids: [ObjectID], selectingNext: Bool = false) {
        let closed = ids.compactMap { tiles[$0]?.frame }
        board.transaction {
            for id in ids.sorted() { try? board.delete(id) }
        }
        if selectingNext, let first = closed.first {
            let area = closed.dropFirst().reduce(first) { $0.union($1) }
            let candidates = tiles.values.filter { !$0.isHidden }.sorted { $0.objectID < $1.objectID }
            if let index = Layout.nearest(to: area, among: candidates.map(\.frame)) {
                let next = candidates[index].objectID
                reveal(next)
                setSelection([next])
                return takeKeyboard(next)
            }
        }
        // A closed tile that had the keyboard leaves it with the window: the canvas takes it,
        // so Esc, Delete, ⌘W and the arrows keep working.
        if let window, window.firstResponder === window { window.makeFirstResponder(document) }
    }

    /// ⌘W: closes the selected objects, else the focused terminal (terminals ask first, in the
    /// close sheet), and selects the nearest tile left. False with neither, so the window's own
    /// close (tab or window) runs.
    func closeSelectionOrFocused() -> Bool {
        if !selection.isEmpty {
            delete(Array(selection), selectingNext: true)
            return true
        }
        guard let id = focusedTerminal else { return false }
        delete([id], selectingNext: true)
        return true
    }

    func bringToFront() {
        let ids = expandedSelection().sorted { (board.objects[$0]?.z ?? 0) < (board.objects[$1]?.z ?? 0) }
        var top = board.objects.values.map(\.z).max() ?? 0
        board.transaction {
            for id in ids {
                top += 1
                _ = try? board.update(id, z: top)
            }
        }
    }

    func sendToBack() {
        let ids = expandedSelection().sorted { (board.objects[$0]?.z ?? 0) > (board.objects[$1]?.z ?? 0) }
        var bottom = board.objects.values.map(\.z).min() ?? 0
        board.transaction {
            for id in ids {
                bottom -= 1
                _ = try? board.update(id, z: bottom)
            }
        }
    }

    /// A new terminal with keyboard focus: at a document point (`createHere`), else placed and
    /// revealed like any new object the user asks for (`openForUser`).
    func createTerminal(at point: NSPoint? = nil) {
        let props: JSONValue = .object(["cwd": .string(board.workingRoot.path), "command": .array([])])
        guard let point else { return openForUser(.terminal, props: props) }
        takeKeyboard(createHere(.terminal, props: props, at: point).id)
    }

    /// A new terminal in `terminal`'s directory beside it (a Ghostty new window, tab or split
    /// binding pressed in it), placed, revealed, and focused like any object the user asks for.
    func createTerminal(beside terminal: ObjectID) {
        let cwd = board.objects[terminal]?.props["cwd"]?.string ?? board.workingRoot.path
        openForUser(.terminal, props: .object(["cwd": .string(cwd), "command": .array([])]), near: terminal)
    }

    /// New Terminal/Note/Browser Here: the object's top-left at a document point, moved to the
    /// nearest free spot on whole points, wholly in view clear of the toolbar and tray when there's
    /// room (`Board.place`); when there isn't, the canvas pans the least that shows it. `size`:
    /// other than the type's default.
    private func createHere(_ type: ObjectType, props: JSONValue, at point: NSPoint, size: (w: Double, h: Double)? = nil) -> CanvasObject {
        let size = size ?? Board.defaultSize(type)
        let object = board.create(type: type, props: props, frame: board.place(Frame(x: point.x - CanvasDocumentView.origin.x, y: point.y - CanvasDocumentView.origin.y, w: size.w, h: size.h)))
        reveal(object.id)
        return object
    }

    /// A new object the user asked for without saying where (File › Open File, New Note, New
    /// Browser Tile, ⌘T, Edit Here's terminal `near` its code tile): the free spot nearest the
    /// viewport center or that tile, in view when there's room (`Board.place`), then `showNew`.
    func openForUser(_ type: ObjectType, props: JSONValue, near anchor: ObjectID? = nil) {
        let size = Board.defaultSize(type)
        showNew(board.create(type: type, props: props, frame: board.place(width: size.w, height: size.h, near: anchor)))
    }

    /// An object the user just made or opened: revealed with the least pan, selected, and given
    /// the keyboard; an empty note starts editing (as Return would), so what they type right
    /// away goes into it, and Esc then leaves it selected with the canvas holding the keyboard.
    func showNew(_ object: CanvasObject) {
        reveal(object.id)
        setSelection([object.id])
        if object.type == .note, object.props["markdown"]?.string?.isEmpty != false, enterSelection() { return }
        takeKeyboard(object.id)
    }

    /// Keyboard focus for a tile the keyboard just went to: a terminal takes it itself (on the
    /// next turn, once a new one's surface exists); anything else leaves it with the canvas, so
    /// Esc, Delete, ⌘W, ⌘G and the arrows act on the selection, and Return enters it.
    func takeKeyboard(_ id: ObjectID) {
        guard board.objects[id]?.type == .terminal else {
            window?.makeFirstResponder(document)
            return
        }
        DispatchQueue.main.async { [weak self] in
            (self?.tiles[id]?.content as? TerminalTile)?.focus()
        }
    }

    /// Tiles Return hands the keyboard to (an HTML tile's page never takes it: `HtmlWebView`).
    private static let enterable: Set<ObjectType> = [.terminal, .code, .changes, .note, .browser]

    /// Return with one tile selected and the canvas holding the keyboard: the tile
    /// takes it (`TileContent.enterKeyboard`), revealed first with the least pan (an agent's
    /// terminal with its follow tile, `landing`); a zoomed-out one comes up at 100%
    /// so its live view can. False when nothing is selected that types (the key stays the
    /// canvas's).
    func enterSelection() -> Bool {
        guard selection.count == 1, let id = selection.first, let tile = tiles[id], let type = board.objects[id]?.type, Self.enterable.contains(type) else { return false }
        if !tile.isLive, let rect = docFrame(id) {
            apply(Layout.center(rect, in: clearArea, zoom: 1, padding: Self.jumpPadding))
        } else if let rect = landing(id, padding: Self.jumpPadding / magnification) {
            reveal(rect: rect)
        }
        // On the next turn: a tile just made live builds its view in the liveness pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selection == [id], let content = self.tiles[id]?.content else { return }
            _ = content.enterKeyboard()
        }
        return true
    }

    /// Esc in a tile that has the keyboard (or Leave Tile, ⌘Esc): the canvas takes it back, the
    /// tile stays selected.
    func leaveTile(_ id: ObjectID) {
        if board.objects[id] != nil { setSelection([id]) }
        window?.makeFirstResponder(document)
    }

    /// Where the keyboard goes back to when something that borrowed it (Go to, a code tile's
    /// Outline, References or find bar, the close sheet) closes: a terminal through its own focus
    /// path, another view still shown in the window as it is, else the canvas.
    static func returnKeyboard(to previous: NSResponder?, in window: NSWindow) {
        var view = previous as? NSView
        while let current = view {
            if let terminal = current as? TerminalTile, terminal.window === window { return terminal.focus() }
            view = current.superview
        }
        if let previous = previous as? NSView, previous.window === window, !previous.isHiddenOrHasHiddenAncestor {
            window.makeFirstResponder(previous)
        } else {
            window.makeFirstResponder(window.initialFirstResponder)
        }
    }

    /// The tile holding keyboard focus (a terminal, a code tile's rows, a page, a note being
    /// edited, a code tile's find field).
    var focusedTile: ObjectID? {
        var responder = window?.firstResponder as? NSView
        while let view = responder {
            if let tile = view as? TileFrameView { return tile.objectID }
            responder = view.superview
        }
        return nil
    }

    /// The terminal holding keyboard focus.
    var focusedTerminal: ObjectID? {
        focusedTile.flatMap { tiles[$0]?.content is TerminalTile ? $0 : nil }
    }

    /// ⌥⌘-moves so far, so the opposite arrow goes back (`TileWalk`).
    private var walk = TileWalk()

    /// Navigate Back/Forward, Go to's Recent section, and how deep in a navigation the view is
    /// (`CanvasView+Navigation`).
    var navigation = NavigationHistory()
    var recentLocations = RecentLocations()
    var navigationDepth = 0

    /// ⌥⌘-arrow, stepping through the board like slides: from the focused tile, else the selected
    /// object, ⌥⌘→ follows its outgoing `next_step` arrow and ⌥⌘← its incoming one
    /// (`StepOrder`; at the end of a sequence a notice says "Last step" or "First step"). ⌥⌘→
    /// from a group holding a walkthrough, or with nothing selected, starts the walkthrough
    /// (nearest the view) at its first stop (`StepOrder.start`). Else the nearest tile that way
    /// from the focused tile, else the selection, else the viewport center (`Layout.neighbor`),
    /// or the tile the previous move came from when this is its opposite arrow (`TileWalk`).
    /// The stop shows whole: centered when it isn't in view with a margin, fitted when it's
    /// larger than the view (`Layout.present`); a walkthrough's stop is fitted from a view zoomed
    /// out below readable (`Layout.presentStop`). Selected, given the keyboard, and one step of
    /// Navigate Back (which selects the stop it came from again).
    func moveToNeighbor(_ heading: Layout.Heading) {
        let sources = focusedTile.map { [$0] } ?? selection.sorted()
        var target: ObjectID?
        if sources.count <= 1, heading == .right || heading == .left {
            if let source = sources.first {
                switch StepOrder.step(from: source, forward: heading == .right, in: board.objects) {
                case .to(let next): target = next
                case .end: return showNotice(heading == .right ? "Last step" : "First step")
                case .none: break
                }
            }
            if target == nil, heading == .right {
                let center = CGPoint(x: clearViewport.rect.midX, y: clearViewport.rect.midY)
                target = StepOrder.start(from: sources.first, center: center, in: board.objects)
            }
        }
        let stop = target != nil
        if target == nil {
            let tileSources = sources.filter { tiles[$0] != nil }
            let frames = tileSources.compactMap { tiles[$0]?.frame }
            let from = frames.dropFirst().reduce(frames.first) { union, frame in union?.union(frame) }
                ?? NSRect(x: documentVisibleRect.midX, y: documentVisibleRect.midY, width: 0, height: 0)
            let candidates = tiles.values.filter { !tileSources.contains($0.objectID) && !$0.isHidden }.sorted { $0.objectID < $1.objectID }
            target = walk.step(from: tileSources.count == 1 ? tileSources[0] : nil, frame: from, toward: heading,
                               among: candidates.map { ($0.objectID, $0.frame) })
        }
        guard let id = target, docFrame(id) != nil else { return }
        let before = viewport, selectedBefore = sources.count == 1 ? sources[0] : nil
        present(id, stop: stop)
        setSelection([id])
        if tiles[id] != nil { takeKeyboard(id) }
        guard navigationDepth == 0 else { return }
        navigation.record(NavigationHistory.Entry(from: before, to: viewport, reaim: nil, selectedBefore: selectedBefore, selectedAfter: id))
    }

    /// ⌘F: the find bar of the focused code tile, else of the one selected code tile. False
    /// when neither (the focused terminal or page keeps ⌘F).
    func findInCodeTile() -> Bool {
        let code: CodeTile?
        if let focused = focusedTile, tiles[focused]?.content is CodeTile {
            code = tiles[focused]?.content as? CodeTile
        } else if selection.count == 1, let id = selection.first {
            code = tiles[id]?.content as? CodeTile
        } else {
            code = nil
        }
        guard let code, tiles[code.object.id]?.isLive == true else { return false }
        code.showFind()
        return true
    }

    /// An empty note at a document point (`createHere`), editing (`showNew`).
    func createNote(at point: NSPoint) {
        showNew(createHere(.note, props: .object(["markdown": .string("")]), at: point))
    }

    /// An empty browser tile at a document point (`createHere`), with the address field focused
    /// for the user to type where to go.
    func createBrowser(at point: NSPoint) {
        let browser = createHere(.browser, props: .object(["url": .string("about:blank")]), at: point)
        setSelection([browser.id])
        DispatchQueue.main.async { [weak self] in
            (self?.tiles[browser.id]?.content as? BrowserTile)?.focusAddress()
        }
    }

    /// Review Changes: a changes tile for the uncommitted work (`base`: or everything the branch
    /// changed) of the board root, or of another worktree of its repository (`root`), at a
    /// document point (`createHere`), selected with the canvas holding the keyboard, so Return
    /// gives it the keys. It lists first: with nothing to review the tile is a compact "No changes"
    /// (it grows when changes appear, `ChangesMetrics.grown`), not a full-size empty one. With
    /// one already on the board for that directory and base (`Board.changesTile`), Review
    /// Changes goes to it instead.
    func createChanges(at point: NSPoint, root: String? = nil, base: ChangesBaseChoice = .uncommitted) {
        if let existing = board.changesTile(root: root, base: base.prop) { return go(to: existing) }
        var props: [String: JSONValue] = ["base": .string(base.prop)]
        if let root { props["root"] = .string(root) }
        let spec = ChangesSpec(.object(props)), boardRoot = board.root
        Task { [weak self] in
            let set = await ChangeSet.load(root: boardRoot, spec: spec, highlight: false)
            guard let self else { return }
            if let existing = self.board.changesTile(root: root, base: base.prop) { return self.go(to: existing) }
            let full = Board.defaultSize(.changes)
            let compact = set.files.isEmpty ? ChangesMetrics.fit(set, maxWidth: full.w) : nil
            // The pan that shows the new tile is a place ⌘[ comes back from.
            self.navigating {
                self.showNew(self.createHere(.changes, props: .object(props), at: point, size: compact.map { (Double($0.width), Double($0.height)) }))
                return nil
            }
        }
    }

    /// Review Changes in the empty canvas's menu: per worktree of the board's repository (the
    /// board's own first, by branch when there are several), its uncommitted changes and
    /// everything its branch changed against the default branch (the merge-base: a PR's view).
    private func reviewChangesItem(at point: NSPoint) -> NSMenuItem {
        let own = GitWorktree.containing(board.root.path)
        let worktrees = own.map { own in [own] + own.siblings.filter { $0.gitDir != own.gitDir } } ?? []
        let submenu = NSMenu()
        for worktree in worktrees {
            let isOwn = worktree.gitDir == own?.gitDir
            if worktrees.count > 1 {
                submenu.addItem(MenuAction.item("\(worktree.branch ?? "detached") — \(worktree.name)\(isOwn ? " (this board)" : "")", enabled: false) {})
            }
            let defaultBranch = worktree.defaultBranch
            for base in [ChangesBaseChoice.uncommitted, .branch] {
                let item = MenuAction.item(base.title(defaultBranch: defaultBranch), enabled: base == .uncommitted || defaultBranch != nil) { [weak self] in
                    self?.createChanges(at: point, root: isOwn ? nil : worktree.toplevel, base: base)
                }
                item.indentationLevel = worktrees.count > 1 ? 1 : 0
                submenu.addItem(item)
            }
        }
        if worktrees.isEmpty {
            submenu.addItem(MenuAction.item(ChangesBaseChoice.uncommitted.title(defaultBranch: nil)) { [weak self] in self?.createChanges(at: point) })
        }
        let item = NSMenuItem(title: "Review Changes", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// The one selected tile when it is a changes tile.
    var selectedChangesTile: ChangesTile? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return tiles[id]?.content as? ChangesTile
    }

    // MARK: Menu bar (the context menus' actions, for the keyboard and accessibility)

    /// The code tile Code ▸ Go to Definition, Find References and Outline act on: the focused
    /// one, else the one selected tile, else the one last clicked (`KeyboardFocus.codeTarget`).
    var keyboardCodeTile: CodeTile? {
        let id = KeyboardFocus.codeTarget(focused: focusedTile, selection: selection, lastClicked: lastClickedTile) { self.tiles[$0]?.content is CodeTile }
        return id.flatMap { tiles[$0]?.content as? CodeTile }
    }

    /// The terminal Object ▸ Follow Files toggles and whose checkout Review Changes and Review
    /// Branch review: the focused one, else the one selected tile.
    var followTerminal: ObjectID? {
        if let focused = focusedTerminal { return focused }
        guard selection.count == 1, let id = selection.first, board.objects[id]?.type == .terminal else { return nil }
        return id
    }

    /// Whether `followTerminal`'s agent reports bring up its follow tile (the default).
    func follows(_ terminal: ObjectID) -> Bool { board.objects[terminal]?.props["follow"]?.bool != false }

    /// Follow Files on or off: off removes the follow tile; on, the agent's next file report
    /// brings it back.
    func toggleFollow() {
        guard let id = followTerminal else { return }
        try? board.setFollowing(id, !follows(id))
    }

    /// What Object ▸ Content Zoom acts on (like ⌘W): the selected tiles whose content zooms and
    /// text shapes, else the tile holding the keyboard.
    private var zoomTargets: [CanvasObject] {
        let selected = selection.compactMap { board.objects[$0] }.filter(Self.zooms)
        return selected.isEmpty ? focusedTile.flatMap { board.objects[$0] }.flatMap { Self.zooms($0) ? [$0] : nil } ?? [] : selected
    }

    /// Whether Content Zoom acts on `object`: a tile whose content zooms (`ObjectZoom.applies`),
    /// or a text shape, whose content is its text (`props.textSize`; its box follows the text).
    private static func zooms(_ object: CanvasObject) -> Bool {
        ObjectZoom.applies(to: object.type) || (object.type == .shape && ShapeSpec(object.props)?.kind == .text)
    }

    /// A tile's content zoom, a text shape's text size.
    private static func contentZoom(of object: CanvasObject) -> Double {
        object.type == .shape ? ShapeSpec.textSize(of: object.props) : object.zoom
    }

    /// The content zooms of `zoomTargets`; nil when there is none.
    var zoomTargetLevels: Set<Double>? {
        let levels = Set(zoomTargets.map(Self.contentZoom))
        return levels.isEmpty ? nil : levels
    }

    /// The one selected group, for Enter Group.
    var selectedGroup: ObjectID? {
        guard selection.count == 1, let id = selection.first, groups[id] != nil else { return nil }
        return id
    }

    /// File ▸ Review Changes (uncommitted work) and Review Branch (everything the branch changed
    /// against the default branch): a changes tile in view for the checkout `followTerminal`
    /// works in, else the board's working worktree, else the board root (`Board.reviewRoot`).
    /// Review Branch with nothing to go by on the default branch, which it would review against
    /// itself, offers the repository's worktrees instead (`Board.branchReviewChoices`).
    func reviewChanges(base: ChangesBaseChoice = .uncommitted) {
        let size = Board.defaultSize(.changes), visible = documentVisibleRect
        let point = NSPoint(x: visible.midX - size.w / 2, y: visible.midY - size.h / 2)
        let root = board.reviewRoot(terminal: followTerminal)
        let choices = base == .branch && root == nil ? board.branchReviewChoices : []
        guard !choices.isEmpty, let documentView else { return createChanges(at: point, root: root, base: base) }
        let menu = NSMenu()
        menu.addItem(MenuAction.item("Review Branch of", enabled: false) {})
        for worktree in choices {
            let item = MenuAction.item("\(worktree.branch ?? "detached") — \(worktree.name)") { [weak self] in
                self?.createChanges(at: point, root: worktree.toplevel, base: .branch)
            }
            item.indentationLevel = 1
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: visible.midX, y: visible.midY), in: documentView)
    }

    /// ⌘L: the address field of the focused browser tile, else of the one selected browser tile
    /// (selected too). False when neither (a terminal or anything else keeps ⌘L).
    func focusBrowserAddress() -> Bool {
        let id = focusedTile ?? (selection.count == 1 ? selection.first : nil)
        guard let id, let browser = tiles[id]?.content as? BrowserTile else { return false }
        setSelection([id])
        reveal(id)
        browser.focusAddress()
        return true
    }

    // MARK: Context menus

    func objectMenu(for id: ObjectID, at point: NSPoint? = nil) -> NSMenu {
        if !selection.contains(id) { select(id, extend: false) }
        let count = selection.count
        let menu = NSMenu()
        if focusedTile == id {
            // How to get out of a terminal or page, whose Esc belongs to its program (View ▸ Leave Tile).
            let leave = MenuAction.item("Leave Tile") { [weak self] in self?.leaveTile(id) }
            leave.keyEquivalent = "\u{1b}"
            leave.keyEquivalentModifierMask = .command
            menu.addItem(leave)
            menu.addItem(.separator())
        }
        if count == 1 {
            menu.addItem(mentionItem(for: id, at: point))
            menu.addItem(.separator())
        }
        menu.addItem(MenuAction.item(count > 1 ? "Close \(count) Objects" : "Close") { [weak self] in self?.deleteSelection() })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Bring to Front") { [weak self] in self?.bringToFront() })
        menu.addItem(MenuAction.item("Send to Back") { [weak self] in self?.sendToBack() })
        menu.addItem(.separator())
        if let zoom = contentZoomMenu() { menu.addItem(zoom) }
        menu.addItem(MenuAction.item("Group Selection", enabled: expandedSelection().count >= 2) { [weak self] in self?.groupSelection() })
        if count == 1, let terminal = board.objects[id], terminal.type == .terminal {
            // Off removes the follow tile; on, the agent's next file report brings it back.
            let following = terminal.props["follow"]?.bool != false
            let item = MenuAction.item("Follow Files") { [weak self] in try? self?.board.setFollowing(id, !following) }
            item.state = following ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Copy as Image") { [weak self] in self?.copySelectionAsImage() })
        menu.addItem(MenuAction.item("Save as PNG…") { [weak self] in self?.saveSelectionAsPNG() })
        if count == 1, board.objects[id]?.type == .html {
            menu.addItem(MenuAction.item("Save as HTML…") { [weak self] in self?.saveHTML(id) })
            menu.addItem(MenuAction.item("Open in Browser") { [weak self] in self?.openHTMLInBrowser(id) })
        }
        if count == 1, board.objects[id]?.type == .note {
            menu.addItem(MenuAction.item("Copy as Markdown") { [weak self] in self?.copyNoteMarkdown(id) })
            menu.addItem(MenuAction.item("Save as Markdown…") { [weak self] in self?.saveNoteMarkdown(id) })
        }
        if count == 1, let browser = tiles[id]?.content as? BrowserTile {
            menu.addItem(MenuAction.item("Snapshot to Image") { [weak self] in self?.snapshotPage(id) })
            menu.addItem(MenuAction.item("Open in Browser", enabled: browser.webAddress != nil) { [weak self] in self?.openPageInBrowser(id) })
            menu.addItem(MenuAction.item("Inspect Element", enabled: browser.canShowInspector) { [weak browser] in browser?.showInspector() })
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(count > 1 ? "Copy Object IDs" : "Copy Object ID") { [weak self] in self?.copyIDs() })
        return menu
    }

    /// Zoom Content In, Out, the presets and Reset Content Zoom for the selected tiles and text
    /// shapes (a preset is checked when they all show it), with the main menu's shortcuts; nil
    /// when nothing selected zooms.
    private func contentZoomMenu() -> NSMenuItem? {
        guard let current = zoomTargetLevels else { return nil }
        func shortcut(_ item: NSMenuItem, _ key: String) -> NSMenuItem {
            (item.keyEquivalent, item.keyEquivalentModifierMask) = (key, [.control, .command])
            return item
        }
        let submenu = NSMenu()
        submenu.addItem(shortcut(MenuAction.item("Zoom Content In", enabled: canStepZoom(bigger: true)) { [weak self] in self?.stepZoom(bigger: true) }, "="))
        submenu.addItem(shortcut(MenuAction.item("Zoom Content Out", enabled: canStepZoom(bigger: false)) { [weak self] in self?.stepZoom(bigger: false) }, "-"))
        submenu.addItem(.separator())
        for preset in ObjectZoom.presets {
            let item = MenuAction.item(ObjectZoom.percent(preset)) { [weak self] in self?.setZoom(preset) }
            item.state = current == [preset] ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(shortcut(MenuAction.item("Reset Content Zoom", enabled: current != [1]) { [weak self] in self?.setZoom(1) }, "0"))
        let title = current.count == 1 && current != [1] ? "Content Zoom (\(ObjectZoom.percent(current.first!)))" : "Content Zoom"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Sets the content zoom of the selected tiles and text shapes, else of the tile holding the
    /// keyboard, as one undo step (`setZoom(_:of:)`).
    func setZoom(_ zoom: Double) {
        setZoom(zoom, of: zoomTargets)
    }

    /// Object ▸ Content Zoom ▸ Zoom Content In (⌃⌘=) or Out (⌃⌘-): each target to the next of
    /// `ObjectZoom.levels` that way; one past the last level stays.
    func stepZoom(bigger: Bool) {
        apply(zoomChanges: zoomTargets.compactMap { object in ObjectZoom.step(from: Self.contentZoom(of: object), bigger: bigger).map { (object, $0) } })
    }

    /// Whether Zoom Content In (`bigger`) or Out has a level to step any target to.
    func canStepZoom(bigger: Bool) -> Bool {
        zoomTargets.contains { ObjectZoom.step(from: Self.contentZoom(of: $0), bigger: bigger) != nil }
    }

    /// `objects` at content zoom `zoom`, as one undo step: a tile's `props.zoom` with its frame
    /// as it is (the content lays out again at the new size inside it); a text shape's
    /// `props.textSize`, its box grown or shrunk with its text from its top-left corner.
    func setZoom(_ zoom: Double, of objects: [CanvasObject]) {
        apply(zoomChanges: objects.filter { abs(Self.contentZoom(of: $0) - zoom) >= 0.001 }.map { ($0, zoom) })
    }

    private func apply(zoomChanges changes: [(CanvasObject, Double)]) {
        guard !changes.isEmpty else { return }
        board.transaction {
            for (object, zoom) in changes {
                if object.type == .shape {
                    let ratio = zoom / Self.contentZoom(of: object)
                    let frame = Frame(x: object.frame.x, y: object.frame.y, w: object.frame.w * ratio, h: object.frame.h * ratio)
                    _ = try? board.update(object.id, frame: frame, props: .object(["textSize": ObjectZoom.prop(zoom)]))
                } else {
                    _ = try? board.update(object.id, props: .object(["zoom": ObjectZoom.prop(zoom)]))
                }
            }
        }
    }

    private func groupMenu(for id: ObjectID) -> NSMenu {
        if !selection.contains(id) { setSelection([id]) }
        let menu = NSMenu()
        menu.addItem(MenuAction.item("Enter Group") { [weak self] in self?.enter(group: id) })
        menu.addItem(MenuAction.item("Ungroup") { [weak self] in self?.ungroupSelection() })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Copy Object ID") { [weak self] in self?.copyIDs() })
        return menu
    }

    func emptyCanvasMenu(at point: NSPoint) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuAction.item("New Terminal Here") { [weak self] in self?.createTerminal(at: point) })
        menu.addItem(MenuAction.item("New Note Here") { [weak self] in self?.createNote(at: point) })
        menu.addItem(MenuAction.item("New Browser Here") { [weak self] in self?.createBrowser(at: point) })
        menu.addItem(reviewChangesItem(at: point))
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Clear Attention Markers", enabled: !board.attention.isEmpty) { [weak self] in self?.board.clearAllAttention() })
        if enteredGroup != nil {
            menu.addItem(.separator())
            menu.addItem(MenuAction.item("Exit Group") { [weak self] in self?.exitGroup() })
        }
        return menu
    }

    func copyIDs() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selection.sorted().joined(separator: "\n"), forType: .string)
    }

    // MARK: Navigation (user-initiated only)

    /// Floating window chrome over the canvas edges (the drawing toolbar at the top, the tray at
    /// the bottom, Get Started at the left while it's open), in view points; the window
    /// controller measures it. Jumps and new tiles land clear of it.
    var chromeInsets: () -> NSEdgeInsets = { NSEdgeInsets() }

    /// View › Hide Board Chrome, for presenting: the window hides the drawing toolbar and the
    /// tray (`onChromeHiddenChange`), the canvas its selection rings and handles, author marks,
    /// code tiles' header rows and agents' attention markers (a blocked agent's ring, bubble and
    /// edge pill stay: it needs the user). Esc on the canvas or the menu item again shows them.
    var chromeHidden = false {
        didSet {
            guard chromeHidden != oldValue else { return }
            for (id, group) in groups { group.isSelected = !chromeHidden && selection.contains(id) }
            for id in selection { tiles[id]?.isSelected = !chromeHidden }
            refreshRings()
            for tile in tiles.values { (tile.content as? CodeTile)?.setPresenting(chromeHidden) }
            for id in board.objects.keys { syncAuthor(id) }
            shapeLayer?.needsDisplay = true
            if !chromeHidden { markers.values.forEach { $0.isHidden = false } }
            layoutPills()
            onChromeHiddenChange?()
        }
    }
    var onChromeHiddenChange: (() -> Void)?

    /// The free stretches of the window chrome's toolbar row, in window coordinates: where an
    /// edge pill goes when the edge of the view has no stretch clear of tiles (`PillLayout`).
    var chromeBands: () -> [NSRect] = { [] }

    /// Space kept between a jump's target and the floating chrome, in view points.
    static let chromeMargin: CGFloat = 12

    /// The part of the viewport jumps aim at (view points, top-left origin): clear of the floating
    /// chrome, with a margin; never less than half the viewport either way.
    private var clearArea: CGRect {
        let size = contentView.frame.size
        let insets = chromeInsets()
        let top = insets.top + Self.chromeMargin, bottom = insets.bottom + Self.chromeMargin
        let left = insets.left > 0 ? insets.left + Self.chromeMargin : 0, right = insets.right > 0 ? insets.right + Self.chromeMargin : 0
        let height = max(size.height - top - bottom, size.height / 2)
        let width = max(size.width - left - right, size.width / 2)
        return CGRect(x: min(left, size.width - width), y: min(top, size.height - height), width: width, height: height)
    }

    /// Where a board opens: the top of its content, or of its largest cluster when the content
    /// doesn't fit at this zoom (the middle of a board with a stray tile far away is empty canvas).
    func centerOnContent() {
        viewportMover = .system
        defer { viewportMover = .user }
        let clear = clearArea
        let target = Layout.fitTarget(tiles.values.map(\.frame), viewport: clear.size, padding: Self.fitPadding, minZoom: 1)
            ?? NSRect(origin: CanvasDocumentView.origin, size: .zero)
        let zoom = magnification
        scroll(to: NSPoint(x: target.midX - clear.midX / zoom, y: target.minY - Self.jumpPadding - clear.minY / zoom))
    }

    /// The view a board opens with: where this client left it (zoom and centre), else the top of
    /// its content (`centerOnContent`), as every board's first open.
    private func placeOpeningView() {
        if let saved = viewportRecorder.opened {
            restoreView(saved)
            openedAtSavedView = saved
        } else {
            centerOnContent()
        }
        // Nothing is marked as written for a first open: even if the view never moves, the first
        // close or quit records it (`saveViewport`).
        viewPlaced = true
    }

    /// The zoom and the board point at the centre of the view now, to come back to (`restoreView`):
    /// the centre rather than a corner, so a window of another size shows what the user was
    /// looking at, and of the whole view rather than the part clear of the chrome, so a tray of
    /// another size doesn't move it.
    private var currentViewport: SavedViewport {
        let size = contentView.frame.size, zoom = magnification, origin = contentView.bounds.origin
        return SavedViewport(zoom: Double(zoom), x: Double(origin.x + size.width / 2 / zoom - CanvasDocumentView.origin.x),
                             y: Double(origin.y + size.height / 2 / zoom - CanvasDocumentView.origin.y))
    }

    private func restoreView(_ saved: SavedViewport) {
        restoringView = true
        viewportMover = .system
        defer {
            viewportMover = .user
            restoringView = false
        }
        let zoom = min(maxMagnification, max(minMagnification, CGFloat(saved.zoom)))
        let centre = NSRect(x: CGFloat(saved.x) + CanvasDocumentView.origin.x, y: CGFloat(saved.y) + CanvasDocumentView.origin.y, width: 0, height: 0)
        apply(Layout.center(centre, in: CGRect(origin: .zero, size: contentView.frame.size), zoom: zoom, padding: 0))
        restoredView = (contentView.bounds.origin, magnification)
    }

    /// Whether the view is still exactly where `restoreView` put it: a resize scales the clip
    /// view's bounds around an unchanged origin, within rounding.
    private var isAtRestoredView: Bool {
        let origin = contentView.bounds.origin
        return abs(origin.x - restoredView.origin.x) < 0.01 && abs(origin.y - restoredView.origin.y) < 0.01
            && abs(magnification - restoredView.zoom) < 1e-6
    }

    /// While the board is still at the saved view it opened with and only the window changed
    /// size, shows the saved centre again; a change of origin or zoom is the user's (or a
    /// jump's), and the view is theirs from then on.
    private func keepOpenedViewCentred() {
        guard let opened = openedAtSavedView, !restoringView else { return }
        guard isAtRestoredView else {
            openedAtSavedView = nil
            return
        }
        let now = currentViewport
        if abs(now.x - opened.x) > 0.5 || abs(now.y - opened.y) > 0.5 { restoreView(opened) }
    }

    /// Records the view once it has stopped moving (every pan and pinch step calls this).
    private func scheduleViewportSave() {
        guard viewPlaced else { return }
        viewportSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveViewport() }
        }
        viewportSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes the view now unless the file holds it already: when the board's tab closes and the
    /// app quits. A write that failed is tried again at the next of those.
    func saveViewport() {
        viewportSave?.cancel()
        guard viewPlaced else { return }
        viewportRecorder.record(currentViewport)
    }

    private func scroll(to origin: NSPoint) {
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
        scheduleLiveness()
    }

    /// Moves the view to `jump`; nothing when it is there already.
    private func apply(_ jump: Layout.Jump) {
        guard jump != currentJump else { return }
        if magnification != jump.zoom { magnification = jump.zoom }
        scroll(to: jump.origin)
    }

    /// The viewport now, as a jump (for minimal pans).
    private var currentJump: Layout.Jump {
        Layout.Jump(zoom: magnification, origin: contentView.bounds.origin)
    }

    /// Shows a viewport `viewport` reported earlier (Navigate Back/Forward).
    func show(_ viewport: Viewport) {
        apply(Layout.Jump(zoom: viewport.zoom, origin: CGPoint(x: viewport.rect.x + CanvasDocumentView.origin.x, y: viewport.rect.y + CanvasDocumentView.origin.y)))
    }

    /// Scrolling that reaches the canvas (`CanvasWheel`): a wheel notch pans a useful distance,
    /// ⌘-scroll zooms around the pointer, a trackpad's scroll is the scroll view's own pan.
    override func scrollWheel(with event: NSEvent) {
        let flags = event.modifierFlags
        switch CanvasWheel.action(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                                  command: flags.contains(.command), shift: flags.contains(.shift)) {
        case .system:
            super.scrollWheel(with: event)
        case .pan(let dx, let dy):
            let origin = contentView.bounds.origin
            scroll(to: NSPoint(x: origin.x - dx / magnification, y: origin.y - dy / magnification))
        case .zoom(let factor):
            // A window-less event (input replay) carries its screen location.
            let point = event.window == nil ? window?.convertPoint(fromScreen: event.locationInWindow) ?? event.locationInWindow : event.locationInWindow
            zoom(by: factor, around: contentView.convert(point, from: nil))
        }
    }

    /// The zoom times `factor` (within the limits), keeping the document point `anchor` where it
    /// is on screen.
    private func zoom(by factor: CGFloat, around anchor: NSPoint) {
        let old = magnification
        let zoom = min(maxMagnification, max(minMagnification, old * factor))
        guard zoom != old else { return }
        let origin = contentView.bounds.origin
        magnification = zoom
        scroll(to: NSPoint(x: anchor.x - (anchor.x - origin.x) * old / zoom, y: anchor.y - (anchor.y - origin.y) * old / zoom))
    }

    func zoom(to scale: CGFloat) {
        let visible = documentVisibleRect
        setMagnification(min(maxMagnification, max(minMagnification, scale)), centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        scheduleLiveness()
    }

    /// ⌘= / ⌘-: the next browser-like zoom level (`Layout.zoomStep`).
    func zoomStep(in zoomIn: Bool) {
        zoom(to: Layout.zoomStep(from: magnification, in: zoomIn, limits: minMagnification...maxMagnification))
    }

    /// The part of the viewport clear of the toolbar and tray, in canvas coordinates: where new
    /// objects are placed (`Board.viewport`).
    var clearViewport: Frame {
        let clear = clearArea, zoom = magnification, origin = contentView.bounds.origin
        return Frame(x: origin.x + clear.minX / zoom - CanvasDocumentView.origin.x, y: origin.y + clear.minY / zoom - CanvasDocumentView.origin.y,
                     w: clear.width / zoom, h: clear.height / zoom)
    }

    /// The part of `view` in the viewport clear of the toolbar and tray, in `view`'s
    /// coordinates; empty when none of it is. Its bounds, not its `visibleRect`: a tile's content
    /// (unflipped, in its flipped frame) reported a visible rect a title bar's height above its
    /// bounds, and a note's conflict banner placed by it covered the title bar.
    func clearVisibleRect(of view: NSView) -> NSRect {
        guard let document = documentView else { return .zero }
        return view.bounds.intersection(view.convert(Self.docRect(clearViewport), from: document))
    }

    /// ⌘0: 100%. With a selection, the selection at 100%, centered clear of the chrome (its top
    /// when taller than the view); without one, around the viewport's center.
    func zoomToActualSize() {
        let rects = selection.compactMap(docFrame)
        navigating {
            if let first = rects.first {
                apply(Layout.center(rects.dropFirst().reduce(first) { $0.union($1) }, in: clearArea, zoom: 1, padding: Self.jumpPadding))
            } else {
                zoom(to: 1)
            }
            return nil
        }
    }

    /// Room kept around whatever a fit shows, in document points.
    static let fitPadding: CGFloat = 60
    /// Room kept around a target shown at a fixed zoom, in document points.
    static let jumpPadding: CGFloat = 20
    /// Below this, a target too tall to read when fitted whole fits its width instead.
    static let readableZoom: CGFloat = 0.5

    /// Zooms (at most to 100%) so a document rect fills the viewport clear of the chrome,
    /// centered. `readable`: a tall target fits its width and shows its top instead of shrinking
    /// below `readableZoom` (objects; not Zoom to Fit, which must show everything).
    func fit(_ rect: NSRect, readable: Bool = false) {
        apply(Layout.fit(rect, in: clearArea, padding: Self.fitPadding, zoom: minMagnification...maxMagnification,
                         readable: readable ? Self.readableZoom : nil))
    }

    /// Everything, or when that can't be read at minimum zoom, the largest cluster of objects
    /// (`Layout.fitTarget`): a few strays far away don't shrink the board to nothing.
    func zoomToFit() {
        let rects = selectableRects().map(\.rect) + groups.values.filter { !$0.isHidden }.map(\.frame)
        guard let target = Layout.fitTarget(rects, viewport: clearArea.size, padding: Self.fitPadding, minZoom: minMagnification) else { return }
        navigating {
            fit(target)
            return nil
        }
    }

    /// The navigator's "go to": the object fitted (at most 100%, a tall one by its width; an
    /// agent's terminal with its follow tile, `landing`), selected, and given the keyboard (a
    /// terminal focuses; anything else leaves it with the canvas, so Delete, Esc and ⌘G act on it).
    func go(to id: ObjectID) {
        guard let rect = landing(id, padding: Self.fitPadding) else { return }
        navigating {
            fit(rect, readable: true)
            return nil
        }
        setSelection([id])
        takeKeyboard(id)
    }

    /// What landing on `id` (Go to, ⌘J, an ⌥⌘-arrow step, Return) shows: an agent's terminal
    /// together with its follow tile when both fit, with `padding` (document points) around
    /// them, in the view clear of the chrome at the current zoom; else the object alone. Rust
    /// study F6: landing on omp left the tile following its edits mostly off screen.
    private func landing(_ id: ObjectID, padding: CGFloat) -> NSRect? {
        guard let rect = docFrame(id) else { return nil }
        guard board.objects[id]?.type == .terminal else { return rect }
        let shown = Self.docRect(clearViewport)
        return board.followTiles(of: id).compactMap { docFrame($0.id)?.union(rect) }
            .filter { $0.width + 2 * padding <= shown.width && $0.height + 2 * padding <= shown.height }
            .min { $0.width * $0.height < $1.width * $1.height } ?? rect
    }

    /// Go to's heading row: the note gone to, then (once it is live and laid out, the next
    /// turn) the view moved so the section from the heading down is fitted like Go to fits a
    /// tile: a long note shows its width with the heading at the top. One Back entry.
    func go(to id: ObjectID, heading line: Int) {
        let from = viewport
        navigationDepth += 1
        go(to: id)
        navigationDepth -= 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let note = self.tiles[id]?.content as? NoteTile, let heading = note.reveal(heading: line), let frame = self.docFrame(id) {
                let top = self.document.convert(heading, from: note).minY
                self.fit(NSRect(x: frame.minX, y: top, width: frame.width, height: max(1, frame.maxY - top)), readable: true)
            }
            self.recordNavigation(from: from)
        }
    }

    /// What Go to Next Needs-You visited last, as it was then.
    private var lastNeedsYou: NeedsYouItem?

    /// Go to Next Needs-You (⌘J): the next blocked agent's terminal, then the next marked object,
    /// then the next done agent's terminal not seen yet, on this board (`NeedsYouItem`), framed
    /// like Go to, selected (which acknowledges a marker), and given the keyboard (a terminal
    /// focuses, which sees a done agent). Pressed again from there, the one after it, around;
    /// from anywhere else, the first. When nothing needs the user, a notice says so.
    func goToNextNeedsYou() {
        let items = NeedsYouItem.all(board.objects, attention: board.attention)
        let current = focusedTile ?? (selection.count == 1 ? selection.first : nil)
        let last = lastNeedsYou.flatMap { $0.id == current ? $0 : nil }
        guard let next = NeedsYouItem.next(after: last, in: items) else { return showNotice("Nothing needs you") }
        lastNeedsYou = next
        go(to: next.id)
    }

    /// "Zoom in" on the canvas: this tile at 100%, centered, selected, and focused if it types.
    func focus(tile id: ObjectID) {
        guard let rect = docFrame(id) else { return }
        apply(Layout.center(rect, in: clearArea, zoom: 1, padding: Self.jumpPadding))
        setSelection([id])
        (tiles[id]?.content as? TerminalTile)?.focus()
    }

    /// An attention edge pill: framed like Go to (one step of Navigate Back), and the marker is
    /// acknowledged (the user went there). Selection and keyboard focus stay, except on a
    /// walkthrough (a stop, or a group holding stops: an agent's "Start here"), which is selected
    /// with the canvas holding the keyboard so ⌥⌘→ steps from it (`StepOrder`).
    func jumpToAttention(_ id: ObjectID) {
        guard let rect = docFrame(id) else { return }
        navigating {
            fit(rect, readable: true)
            return nil
        }
        board.clearAttention(id)
        if StepOrder.step(from: id, forward: true, in: board.objects) != .none || StepOrder.start(from: id, center: .zero, in: board.objects) != nil {
            setSelection([id])
            takeKeyboard(id)
        }
    }

    /// The least pan that shows an object the user just opened (a code tile from an HTML link),
    /// clear of the chrome; nothing when it is already in view. `bottomFirst`: an object taller
    /// than the view shows its bottom (a terminal's prompt or question), not its top.
    func reveal(_ id: ObjectID, bottomFirst: Bool = false) {
        docFrame(id).map { reveal(rect: $0, bottomFirst: bottomFirst) }
    }

    /// `reveal` of a document rect, `padding` (document points) around it, by default the jump
    /// padding at this zoom.
    private func reveal(rect: NSRect, padding: CGFloat? = nil, bottomFirst: Bool = false) {
        apply(Layout.reveal(rect, from: currentJump, clear: clearArea, padding: padding ?? Self.jumpPadding / magnification, bottomFirst: bottomFirst))
    }

    /// `reveal`, keeping what shows of `anchor` (the tile it was opened from) in view too when
    /// both fit.
    func reveal(_ id: ObjectID, keeping anchor: ObjectID) {
        guard let rect = docFrame(id), let kept = docFrame(anchor) else { return reveal(id) }
        apply(Layout.reveal(rect, keeping: kept, from: currentJump, clear: clearArea, padding: Self.jumpPadding / magnification))
    }

    /// A tile opened from `source` (document coordinates), e.g. a terminal's ⌘-clicked
    /// reference: panned to only when mostly out of view, never so far that `source` leaves it.
    func reveal(_ id: ObjectID, openedFrom source: NSRect) {
        guard let rect = docFrame(id) else { return }
        apply(Layout.reveal(rect, from: currentJump, clear: clearArea, padding: Self.jumpPadding / magnification, openedFrom: source))
    }

    /// A diagram grown by the user's click on a node (canvas rects): an animated least pan that
    /// shows the whole tile when it fits, else the added nodes with the clicked one
    /// (`Layout.revealGrown`). Never a zoom.
    private func revealExpansion(tile: CGRect, added: CGRect, clicked: CGRect) {
        func doc(_ rect: CGRect) -> CGRect { rect.isNull ? rect : rect.offsetBy(dx: CanvasDocumentView.origin.x, dy: CanvasDocumentView.origin.y) }
        animatePan(to: Layout.revealGrown(doc(tile), added: doc(added), clicked: doc(clicked), from: currentJump, clear: clearArea,
                                          padding: Self.jumpPadding / magnification))
    }

    // MARK: Tray chips

    /// A click on a tray chip: what its mention points at selected and brought into view
    /// (`MentionReveal`; `Layout.revealMention` keeps the zoom unless a tile must turn live to
    /// show the part, never past 100%), then the mentioned lines or note block scrolled to in
    /// the tile, shown, and flashed; a whole object flashes whole. The keyboard stays where it
    /// is, so the prompt still goes where the tray says. One step of Navigate Back.
    func revealMention(_ target: MentionTarget) {
        guard let reveal = MentionReveal(target, on: board) else { return }
        let rects = reveal.objects.compactMap(docFrame)
        guard var rect = rects.first else { return }
        for other in rects.dropFirst() { rect = rect.union(other) }
        let tile = reveal.part.flatMap { tiles[$0] }
        let readable = tile.map { max(Self.readableZoom, $0.content.liveZoom / max($0.zoom, 0.01)) }
        let from = viewport
        navigationDepth += 1
        apply(Layout.revealMention(rect, readable: readable, from: currentJump, clear: clearArea, padding: Self.jumpPadding / magnification,
                                   zoom: minMagnification...maxMagnification))
        setSelection(Set(reveal.objects))
        navigationDepth -= 1
        guard let tile else {
            flashMention(rect)
            return recordNavigation(from: from)
        }
        revealPart(target, in: tile, from: from)
    }

    /// The part once the tile is live and has loaded it (a code tile reads its file first):
    /// scrolled to inside the tile, panned to when it is out of view, and flashed. A tile that
    /// can't find it within `partWait` tries flashes whole instead.
    private func revealPart(_ target: MentionTarget, in tile: TileFrameView, from: Viewport, attempt: Int = 0) {
        if tile.isLive {
            tile.content.scrollToMention(target)
            if let outline = tile.content.outline(for: target), !outline.isEmpty {
                let part = document.convert(outline, from: tile.content)
                apply(Layout.reveal(part, keeping: tile.frame, from: currentJump, clear: clearArea, padding: Self.jumpPadding / magnification))
                flashMention(part)
                return recordNavigation(from: from)
            }
        }
        guard attempt < Self.partWait else {
            flashMention(tile.frame)
            return recordNavigation(from: from)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak tile] in
            guard let self, let tile, tile.superview != nil else { return }
            self.revealPart(target, in: tile, from: from, attempt: attempt + 1)
        }
    }

    /// Tries, 50 ms apart, for a revealed part to show.
    private static let partWait = 30

    /// The revealed mention (document rect) lit for most of a second, then faded out over the
    /// next two (a code tile's own edit flash lasts three).
    private func flashMention(_ rect: NSRect) {
        mentionFlash?.cancel()
        overlay.flash = (rect, 1)
        mentionFlash = Task { @MainActor [weak self] in
            let steps = 60
            try? await Task.sleep(for: .milliseconds(800))
            for step in 1...steps {
                guard !Task.isCancelled, let self else { return }
                let t = CGFloat(step) / CGFloat(steps)
                self.overlay.flash = step == steps ? nil : (rect, 1 - t * t)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    /// A Hyper-click, ⇧⌘M, or a context menu's Mention: stages `target`, or takes it out of the
    /// tray when it is there already, and says so, since the chip leaving is easy to miss.
    func toggleMention(_ target: MentionTarget) {
        if case .unstaged(let mention) = board.toggle(target) { showNotice(TrayChips.unstagedNotice(mention)) }
    }

    /// A context menu's Mention item (⇧⌘M's shortcut shown): what is under `point` (the
    /// right-click, in the tile content's coordinates), as a Hyper-click there would stage it,
    /// else the whole tile; for a drawn shape or arrow, what a Hyper-click on it stages.
    func mentionItem(for id: ObjectID, at point: NSPoint?) -> NSMenuItem {
        let item = MenuAction.item("Mention") { [weak self] in
            guard let self else { return }
            guard let content = self.tiles[id]?.content else {
                // A shape or arrow: what a Hyper-click on it stages.
                return self.toggleMention(MentionContext.drawingTarget(id, selection: self.selection, on: self.board))
            }
            Task { @MainActor [weak self] in
                var target: MentionTarget?
                if let point { target = await content.resolveMention(at: point) }
                self?.toggleMention(target ?? .object(id))
            }
        }
        item.keyEquivalent = "m"
        item.keyEquivalentModifierMask = [.shift, .command]
        return item
    }

    /// `mentionItem` for a right-click `event` inside a tile's content view `view` (a code
    /// tile's rows, a note's text, a page); nil outside any tile.
    static func mentionItem(in view: NSView, for event: NSEvent) -> NSMenuItem? {
        guard let tile = sequence(first: view, next: \.superview).lazy.compactMap({ $0 as? TileFrameView }).first,
              let canvas = sequence(first: tile as NSView, next: \.superview).lazy.compactMap({ $0 as? CanvasView }).first else { return nil }
        return canvas.mentionItem(for: tile.objectID, at: tile.content.convert(event.locationInWindow, from: nil))
    }

    /// A content view's own context menu (a page's, a note's text) with `mentionItem` first.
    static func insertMention(into menu: NSMenu, in view: NSView, for event: NSEvent) {
        guard let item = mentionItem(in: view, for: event) else { return }
        if menu.numberOfItems > 0 { menu.insertItem(.separator(), at: 0) }
        menu.insertItem(item, at: 0)
    }

    private var panAnimation: Task<Void, Never>?
    private var mentionFlash: Task<Void, Never>?

    /// Pans to `jump` (same zoom) over a quarter second, easing out; a newer pan replaces it.
    private func animatePan(to jump: Layout.Jump) {
        guard jump.zoom == magnification, jump != currentJump else { return }
        panAnimation?.cancel()
        let start = contentView.bounds.origin, end = jump.origin, steps = 15
        panAnimation = Task { @MainActor [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self else { return }
                let t = CGFloat(step) / CGFloat(steps), eased = 1 - pow(1 - t, 3)
                self.scroll(to: CGPoint(x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased))
            }
        }
    }

    /// Code a page's or note's link opened: one step of Navigate Back. A tile that already
    /// showed the lines is gone to (`goToShown`); a new or re-aimed one is shown with the least pan.
    private func showOpenedCode(_ id: ObjectID, existing: Bool) {
        navigating(landing: board.objects[id].flatMap(CodeAim.init)) {
            if existing { goToShown(id) } else { reveal(id) }
            return nil
        }
    }

    /// The browser tile a web link opened or found (`Board.openLink`, from a terminal's URL, a
    /// page, a note, code, or `view.open_url`), shown without taking anything from the user: the
    /// least pan that shows it, never so far that `source`, the tile the link is in, leaves
    /// view. Keyboard focus stays where it was: the tile is selected only when that leaves the
    /// keyboard alone (`KeyboardFocus.afterSelectionChange`: a terminal, or the board, holds
    /// it), so a note being edited, a page being typed in or code rows keep both the keyboard and
    /// their selection.
    func showOpenedLink(_ id: ObjectID, openedFrom source: ObjectID?) {
        reveal(id, openedFrom: source.flatMap(docFrame) ?? .null)
        if KeyboardFocus.afterSelectionChange([id], holder: keyboardHolder) == .stay { setSelection([id]) }
    }

    /// An object shown whole like a slide (an agent's terminal with its follow tile, `landing`):
    /// nothing moves while it is in view with a margin; else centered at this zoom, or fitted
    /// when larger than the view (`Layout.present`). A walkthrough's `stop` is fitted like Go to
    /// when the view is zoomed out below readable (`Layout.presentStop`).
    func present(_ id: ObjectID, stop: Bool = false) {
        let padding = Self.jumpPadding / magnification, limits = minMagnification...maxMagnification
        guard let rect = landing(id, padding: padding) else { return }
        apply(stop ? Layout.presentStop(rect, from: currentJump, clear: clearArea, padding: padding, fitPadding: Self.fitPadding, zoom: limits, readable: Self.readableZoom)
                   : Layout.present(rect, from: currentJump, clear: clearArea, padding: padding, zoom: limits, readable: Self.readableZoom))
    }

    // MARK: Attention

    /// Shows the board's marker on an object (`Board.attention`): a pulsing ring and message,
    /// plus an edge pill while the object is offscreen. The user acknowledges it (the board
    /// clears it) by selecting it, focusing it, clicking it or its bubble, or looking at it for
    /// a while; the empty canvas's menu clears them all.
    private func showMarker(_ id: ObjectID, message: String?) {
        guard board.objects[id] != nil else { return }
        if let marker = markers[id] {
            marker.message = message
        } else {
            let marker = AttentionMarker(objectID: id, message: message)
            marker.onClick = { [weak self] in
                self?.board.clearAttention(id)
                self?.select(id, extend: false)
            }
            attention.addSubview(marker)
            markers[id] = marker
        }
        layoutPills()
        scheduleLiveness()
    }

    private func hideMarker(_ id: ObjectID) {
        guard let marker = markers.removeValue(forKey: id) else { return }
        marker.removeFromSuperview()
        layoutPills()
        scheduleLiveness()
    }

    /// Markers, blocked terminals' bubbles, and edge pills live in window space: re-placed on
    /// every pan and pinch step (`boundsChanged`), whenever objects move, on every scene pass,
    /// and when a terminal takes the keyboard, around their objects' rects as they are on screen
    /// now. `PillLayout` keeps them off each other, off blocked terminals and the tile with the
    /// keyboard (above all its cursor's row), a bubble off other tiles where it can, and all of
    /// them off title bars where they can and in the area the chrome leaves clear (`clearArea`,
    /// what jumps aim at). An object in view shows its bubble; one out of view gets an edge pill
    /// instead (a blocked terminal's says why it is blocked, even when it is also marked).
    private func layoutPills() {
        guard !markers.isEmpty || !blocked.isEmpty || !edges.subviews.isEmpty else { return }
        let visible = documentVisibleRect
        let zoom = magnification
        var shownMarkers: [PillLayout.Marker] = []
        var pointers: [ObjectID: AttentionEdgeView.Pointer] = [:]
        func point(_ rect: NSRect) -> NSPoint { edges.convert(NSPoint(x: rect.midX, y: rect.midY), from: document) }
        // Hidden chrome (presenting) hides agents' "look here" markers; a blocked agent still shows.
        if chromeHidden { markers.values.forEach { $0.isHidden = true } }
        let views = (chromeHidden ? [] : Array(markers.values)) + Array(blocked.values)
        var shownRects: [ObjectIdentifier: NSRect] = [:]
        for view in views {
            guard let rect = docFrame(view.objectID) else {
                view.isHidden = true
                continue
            }
            view.isHidden = !rect.intersects(visible)
            if view.isHidden {
                if view.style == .blocked || pointers[view.objectID] == nil {
                    pointers[view.objectID] = .init(id: view.objectID, message: view.message, style: view.style, target: point(rect))
                }
                continue
            }
            let shown = attention.convert(rect, from: document)
            let header = headerOnScreen(view.objectID, zoom: zoom)
            let ringWidth = shown.width + 2 * AttentionMarker.inset
            shownRects[ObjectIdentifier(view)] = shown
            shownMarkers.append(.init(id: view.objectID, target: shown, ringInset: AttentionMarker.inset,
                                      size: CGSize(width: PillLayout.bubbleWidth(natural: view.naturalWidth, ringWidth: ringWidth), height: AttentionMarker.bubbleHeight),
                                      header: header, blocked: view.style == .blocked))
        }
        let onScreen = tiles.values.filter { $0.frame.intersects(visible) }.map {
            PillLayout.Tile(id: $0.objectID, rect: attention.convert($0.frame, from: document), header: headerOnScreen($0.objectID, zoom: zoom))
        }
        let focused = focusedTile
        let caret = focused.flatMap { tiles[$0]?.content as? TerminalTile }.flatMap { terminal in
            terminal.caretRow.map { attention.convert($0, from: terminal.terminal) }
        }
        let clear = clearArea
        let placement = PillLayout.place(markers: shownMarkers, edges: pointers.values.map { .init(id: $0.id, target: $0.target, size: AttentionEdgeView.size(for: $0.message, style: $0.style)) },
                                         tiles: onScreen, focused: focused, caret: caret, clear: clear,
                                         bands: chromeBands().map { edges.convert($0, from: nil) })
        for view in views {
            let bubble = view.style == .blocked ? placement.blocked[view.objectID] : placement.bubbles[view.objectID]
            if let bubble, let shown = shownRects[ObjectIdentifier(view)] { view.place(around: shown, bubble: bubble) }
        }
        edges.show(pointers.values.sorted { $0.id < $1.id }.map { pointer in
            var pointer = pointer
            pointer.frame = placement.edges[pointer.id] ?? .zero
            return pointer
        })
    }

    /// Height of an object's header on screen: a tile's title bar plus its content's controls
    /// strip (a browser's address bar), live or card; a group's title band.
    private func headerOnScreen(_ id: ObjectID, zoom: CGFloat) -> CGFloat {
        if let tile = tiles[id] { return (TileFrameView.titleHeight + tile.content.headerHeight * tile.zoom) * zoom }
        return groups[id] != nil ? CGFloat(GroupSpec.titleHeight) * zoom : 0
    }

    // MARK: Nothing in view

    /// False while the board has objects but none of them is in the viewport; the window then
    /// offers a way back to them. Kept by the scene pass, reported on change.
    private var contentInView = true
    var onContentInViewChange: ((Bool) -> Void)?

    /// Stops at the first object in view and allocates nothing. Tiles first (their views hold
    /// their frames), then group regions, then drawn objects.
    private func updateContentInView() {
        let visible = documentVisibleRect
        let inView = board.objects.isEmpty
            || tiles.values.contains { $0.frame.intersects(visible) }
            || groups.values.contains { !$0.isHidden && $0.frame.intersects(visible) }
            || board.objects.values.contains { object in
                object.type != .group && tiles[object.id] == nil && docFrame(object.id)?.intersects(visible) == true
            }
        guard inView != contentInView else { return }
        contentInView = inView
        onContentInViewChange?(inView)
    }

    // MARK: Seen

    /// The user gave tile `id` the keyboard or typed in it: that counts as seeing it, as selecting
    /// it does (its marker clears; a terminal's done agent is seen).
    func keyboardUsed(_ id: ObjectID) {
        didSee(id)
        scheduleLiveness()
    }

    private func lifecycleChanged(_ terminal: CanvasObject) {
        let lifecycle = terminal.props["lifecycle"]
        // A new `working` report starts a new unseen stretch (Board resets its seen set too), as
        // does the notification of an agent reporting by notification (`NotifyingAgent`: `done`).
        let state = lifecycle?["state"]?.string
        if state == LifecycleState.working.rawValue || state == LifecycleState.done.rawValue, lifecycle?["seen"]?.bool != true {
            seenLocally.remove(terminal.id)
        }
        // A blocked terminal's ring and bubble come and go with the state, the moment it changes.
        if lifecycle?["state"]?.string == LifecycleState.blocked.rawValue {
            let message = lifecycle?["message"]?.string
            if let view = blocked[terminal.id] {
                guard view.message != message else { return scheduleLiveness() }
                view.message = message
            } else {
                let id = terminal.id
                let view = AttentionMarker(objectID: id, message: message, style: .blocked)
                // Answering is what it needs: clicking the bubble shows the terminal (its bottom,
                // where the question is, when it is taller than the view) and puts the keyboard in it.
                view.onClick = { [weak self] in
                    self?.reveal(id, bottomFirst: true)
                    self?.select(id, extend: false)
                    self?.takeKeyboard(id)
                }
                attention.addSubview(view)
                blocked[id] = view
            }
            layoutPills()
        } else if let view = blocked.removeValue(forKey: terminal.id) {
            view.removeFromSuperview()
            layoutPills()
        }
        scheduleLiveness()
    }

    private func didSee(_ id: ObjectID) {
        if tiles[id]?.content is TerminalTile {
            seenLocally.insert(id)
            board.markSeen(id)
        }
        board.clearAttention(id)
    }

    /// What the user can actually look at now: the key window of the active app, at readable zoom,
    /// with at least half of the object (or half the viewport) on screen. Of the terminals only
    /// finished ones: watching an agent work doesn't see its answer (`Board.markSeen`).
    private func updateSeen() {
        guard let window, window.isKeyWindow, NSApp.isActive, magnification >= Self.liveThreshold else {
            return seen.update(visible: [])
        }
        let visible = documentVisibleRect
        var candidates = Set(markers.keys)
        for (id, tile) in tiles where tile.content is TerminalTile && !seenLocally.contains(id) {
            if board.objects[id]?.props["lifecycle"]?["state"]?.string == LifecycleState.done.rawValue { candidates.insert(id) }
        }
        seen.update(visible: candidates.filter { id in
            guard let rect = docFrame(id) else { return false }
            let shown = rect.intersection(visible)
            return !shown.isNull && shown.width * shown.height >= 0.5 * min(rect.width * rect.height, visible.width * visible.height)
        })
    }

    // MARK: Scene pass (zoom LOD, offscreen culling, pills, seen)

    @objc private func boundsChanged() {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("scene.boundsChanged", since: perfStart) }
        keepOpenedViewCentred()
        // Every pan and pinch step, not coalesced: the grid is one layer move, markers a few.
        updateGrid()
        layoutPills()
        if !selection.isEmpty { placeHandles() }
        board.activity.viewportChanged(viewport, actor: viewportMover, rev: board.revision)
        scheduleViewportSave()
        scheduleActivitySettle()
        scheduleLiveness()
    }

    // MARK: Viewport state (view.get, board.history)

    /// What the window shows, in canvas coordinates.
    var viewport: Viewport {
        let visible = documentVisibleRect
        return Viewport(rect: Frame(x: visible.minX - CanvasDocumentView.origin.x, y: visible.minY - CanvasDocumentView.origin.y,
                                    w: visible.width, h: visible.height), zoom: magnification)
    }

    var viewState: ViewState {
        ViewState(viewport: viewport, promptTarget: promptTarget, focused: focusedTile, selection: selection.sorted(),
                  enteredGroup: enteredGroup, visible: window?.occlusionState.contains(.visible) ?? false,
                  appearance: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light")
    }

    /// Viewport and selection changes are logged once they settle; this makes sure that happens
    /// even if nothing reads the log meanwhile.
    private func scheduleActivitySettle() {
        activitySettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.board.activity.settle() }
        }
        activitySettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ActivityLog.settleInterval + 0.05, execute: work)
    }

    @objc private func magnifyStarted() {
        magnifying = true
    }

    @objc private func magnifyEnded() {
        magnifying = false
        scheduleLiveness()
    }

    /// Coalesces every trigger in one run-loop turn into a single pass.
    private func scheduleLiveness() {
        guard !livenessScheduled else { return }
        livenessScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.livenessScheduled = false
            self.updateScene()
        }
    }

    /// The zoom the last scene pass outside a pinch saw.
    private var settledMagnification: CGFloat = 0

    private func updateScene() {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("scene.pass", since: perfStart) }
        if geometryDirty {
            geometryDirty = false
            objectsMoved()
        }
        // Mid-pinch, LOD flips wait for the gesture to end.
        if !magnifying {
            let scale = magnification
            for tile in tiles.values {
                tile.setLive(shouldBeLive(tile, scale: scale))
                tile.zoomedOut = RenderMath.isZoomedOut(magnification: scale, zoom: tile.zoom)
            }
            // A web page's viewport follows its view's device-pixel size (`BrowserTile.webViewFrame`).
            if scale != settledMagnification {
                settledMagnification = scale
                for tile in tiles.values { (tile.content as? BrowserTile)?.zoomChanged() }
            }
        }
        layoutPills()
        updateSeen()
        updateContentInView()
    }

    /// Live: readable at `scale` (a scaled-up tile's content is bigger on screen, so it stays live
    /// further out) and near the viewport; a live tile stays live a little further out and zoomed
    /// out (hysteresis), so small pans and zooms don't swap it back and forth.
    private func shouldBeLive(_ tile: TileFrameView, scale: CGFloat) -> Bool {
        let margin = tile.isLive ? Self.cardMargin : Self.liveMargin
        let readable = scale * tile.zoom >= tile.content.liveZoom * (tile.isLive ? Self.cardHysteresis : 1)
        return readable && tile.frame.intersects(documentVisibleRect.insetBy(dx: -margin, dy: -margin))
    }

    // MARK: Hit testing for mentions

    /// The tile under a window point, and that point in the tile content's coordinates.
    func tile(atWindowPoint point: NSPoint) -> (TileFrameView, NSPoint)? {
        let docPoint = document.convert(point, from: nil)
        let hit = tiles.values.filter { $0.frame.contains(docPoint) }.max { lhs, rhs in
            (document.subviews.firstIndex(of: lhs) ?? 0) < (document.subviews.firstIndex(of: rhs) ?? 0)
        }
        guard let hit else { return nil }
        return (hit, hit.content.convert(point, from: nil))
    }

    func showOutline(_ rect: NSRect?, in tile: TileFrameView?) {
        guard let rect, let tile else {
            overlay.outline = nil
            return
        }
        overlay.outline = overlay.convert(rect, from: tile.content)
    }

    func showOutline(docRect: NSRect?) {
        overlay.outline = docRect.map { overlay.convert($0, from: document) }
    }

    func shape(atWindowPoint point: NSPoint) -> ObjectID? {
        shapeHitTest?(document.convert(point, from: nil))
    }

    /// The innermost shown group whose region (title band or interior) holds a window point.
    func group(atWindowPoint point: NSPoint) -> GroupView? {
        let regions = groups.values.filter { !$0.isHidden && !$0.region.isEmpty }.map { GroupMention.Region(id: $0.objectID, frame: $0.region) }
        return GroupMention.innermost(at: document.convert(point, from: nil), in: regions).flatMap { groups[$0] }
    }

    /// How long a mention waits for a page to list the elements under a shape drawn on it.
    static let pageElementsLimit: Duration = .milliseconds(400)

    /// `Board.pageElements`: asks the tile's page, giving up after `pageElementsLimit` (the
    /// query runs on; its late answer is dropped).
    private func pageElements(_ id: ObjectID, canvasRect: CGRect) async -> PageElements? {
        guard let tile = tiles[id] else { return nil }
        let rect = tile.content.convert(Self.docRect(Frame(canvasRect)), from: document)
        let answer = FirstAnswer<PageElements>()
        return await withCheckedContinuation { continuation in
            answer.continuation = continuation
            Task { @MainActor in answer.give(await tile.content.pageElements(in: rect)) }
            Task { @MainActor in
                try? await Task.sleep(for: Self.pageElementsLimit)
                answer.give(nil)
            }
        }
    }
}

/// Resumes its continuation with the first answer given; later ones are dropped.
@MainActor
private final class FirstAnswer<Value: Sendable> {
    var continuation: CheckedContinuation<Value?, Never>?

    func give(_ value: Value?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
