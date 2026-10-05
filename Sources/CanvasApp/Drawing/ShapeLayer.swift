import AppKit
import CanvasCore

/// The hand-drawn layer: renders `.shape` and `.arrow` objects in document coordinates above the
/// tiles and below the Hyper outline. Only strokes, text, and fills take the mouse (plus the whole
/// canvas while a drawing tool is active); everything else passes through to the tiles beneath.
/// All changes go through `board.create`/`board.update` as the user, so undo and persistence apply.
@MainActor
final class ShapeLayer: NSView {
    enum Tool: String, CaseIterable {
        case select, rect, ellipse, arrow, text, ink

        var key: String {
            switch self {
            case .select: "v"
            case .rect: "r"
            case .ellipse: "o"
            case .arrow: "a"
            case .text: "t"
            case .ink: "p"
            }
        }

        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .rect: "rectangle"
            case .ellipse: "circle"
            case .arrow: "arrow.up.right"
            case .text: "textformat"
            case .ink: "scribble"
            }
        }

        var title: String {
            switch self {
            case .select: "Select"
            case .rect: "Rectangle"
            case .ellipse: "Ellipse"
            case .arrow: "Arrow"
            case .text: "Text"
            case .ink: "Draw"
            }
        }
    }

    unowned let canvas: CanvasView
    var board: Board { canvas.board }

    var tool: Tool = .select {
        didSet {
            guard tool != oldValue else { return }
            cancelGesture()
            // Resize handles show only with the select tool.
            for item in resizable { invalidate(handleArea(item.frame)) }
            window?.invalidateCursorRects(for: self)
            onToolChange?()
        }
    }
    /// Palette name for new objects; nil is the default ink.
    var color: String? { didSet { onToolChange?() } }
    var fill: ShapeSpec.Fill = .none { didSet { onToolChange?() } }
    var onToolChange: (() -> Void)?
    /// The floating tool strip at the top of the window (viewport jumps keep clear of it).
    private(set) weak var toolbar: NSView?

    private(set) var items: [ObjectID: DrawnItem] = [:]
    /// Each tile's frame and z as last seen, so a tile that moves or restacks redraws the
    /// default-ink drawings over where it was and where it is (`surfaceChanged`).
    var surfaceFrames: [ObjectID: (frame: Frame, z: Double)] = [:]
    /// Item ids in paint order (ascending z); rebuilt lazily after inserts and z changes.
    private var paintOrder: [ObjectID] = []
    private var paintOrderStale = true
    /// Arrows bound to each object, so a move re-routes only those.
    private var arrowsBound: [ObjectID: Set<ObjectID>] = [:]
    /// The board's routing is due (`ConnectorRouter`: `avoid` arrows routed together, every label
    /// placed with the rest); it runs once per burst of changes, off the main thread (see
    /// `scheduleRouting`).
    private var routingStale = false
    /// Arrows created or changed since the board last routed. They hold a provisional route that
    /// is never drawn or reported: the board routes on the main thread first (`settleProvisional`).
    private var provisional: Set<ObjectID> = []
    /// Bumped by every change the board's routing depends on, so a routing that finishes after
    /// more changes knows its inputs are older.
    private var routingGeneration = 0
    /// A routing is running on `routingQueue`; when it lands, a routing due since starts.
    private var routingInFlight = false
    /// The object whose change last made the board's routing due (`app.metrics` top triggers).
    private var routingTrigger: ObjectID?
    private static let routingQueue = DispatchQueue(label: "easl.routing", qos: .userInitiated)
    /// A live change (a tile dragged or its code scrolled) routes only the arrows it moves; the
    /// board routes again once the change pauses for `routingPause` (`routeAfterPause`).
    private var routingPaused = false
    private var pauseGeneration = 0
    static let routingPause: TimeInterval = 0.25
    /// The board's last routing (canvas coordinates), which the next routes on from.
    private(set) var routing: ConnectorRouter.Result?
    /// What the board's routing depends on of each object that isn't an arrow, as last routed.
    private var routedAs: [ObjectID: RoutingKey] = [:]

    private struct RoutingKey: Equatable {
        var frame: Frame
        var blocks: Bool
        var flow: String?

        init(_ object: CanvasObject) {
            frame = object.frame
            blocks = BoardGeometry.blocksRoutes(object)
            flow = object.type == .group ? object.props["flow"]?.string : nil
        }
    }

    /// Selection-drag preview from the scene: these drawn objects are painted offset.
    private var dragPreview: (ids: Set<ObjectID>, offset: NSSize) = ([], .zero)

    var gesture: Gesture?
    var editor: ShapeEditing?

    enum Gesture {
        case box(tool: Tool, start: NSPoint, current: NSPoint)
        case arrow(from: ArrowBinding, start: NSPoint, current: NSPoint)
        case ink(points: [InkPoint], pressured: Bool)
        case resize(id: ObjectID, anchor: NSPoint, frame: NSRect)
    }

    // MARK: Install

    /// Adds the layer to `canvas` (above its tiles), its toolbar to `container`, and sets the
    /// canvas' drawn-object seams.
    @discardableResult
    static func install(on canvas: CanvasView, toolbarIn container: NSView) -> ShapeLayer {
        let layer = ShapeLayer(canvas: canvas)
        canvas.installShapeLayer(layer)
        canvas.shapeHitTest = { [unowned layer] point in layer.item(at: point)?.object.id }
        canvas.shapeOutline = { [unowned layer] id in layer.outlineRect(id) }
        canvas.drawingOwnsPoint = { [unowned layer] point in layer.ownsPoint(point) }
        canvas.onSelectionChange = { [unowned layer] in layer.selectionChanged() }
        canvas.onSelectionDrag = { [unowned layer] ids, offset in layer.previewDrag(ids, offset: offset) }
        canvas.moveProps = { object, dx, dy in ShapeLayer.moveProps(object, dx: dx, dy: dy) }
        canvas.board.arrowPath = { [unowned layer] id in
            layer.followNow(id)
            return layer.items[id]?.arrow.map { $0.path.map(ShapeLayer.canvasPoint) }
        }
        canvas.board.settleArrows = { [unowned layer] in layer.settleArrows() }
        canvas.board.settledRouting = { [unowned layer] in layer.routing }
        let toolbar = DrawingToolbar(layer: layer)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)
        layer.toolbar = toolbar
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            toolbar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
        return layer
    }

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: canvas.document.bounds)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for object in board.snapshot.objects {
            refresh(object)
            if object.type != .arrow { routedAs[object.id] = RoutingKey(object) }
        }
        // Tiles move live while dragged but commit their frame only on drop; follow them live.
        NotificationCenter.default.addObserver(self, selector: #selector(viewFrameChanged(_:)), name: NSView.frameDidChangeNotification, object: nil)
        // A code tile's rows scroll under arrows bound to its lines.
        NotificationCenter.default.addObserver(self, selector: #selector(anchorsMoved(_:)), name: CodeTile.rowsMoved, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(anchorsMoved(_:)), name: DiagramTile.laidOut, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(tileSurfaceChanged(_:)), name: .tileSurfaceChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func viewFrameChanged(_ note: Notification) {
        guard let tile = note.object as? TileFrameView, tile.superview === canvas.document else { return }
        reroute(boundTo: tile.objectID)
        // A frame the API wrote is a board change (`apply` schedules its routing for the burst's
        // end); anything else is live (a drag, a resize) and routes when it pauses.
        if ApiActivity.shared.dispatching == 0 { routeAfterPause() }
    }

    /// A code tile's rows or a diagram's nodes moved inside it: arrows bound to its lines or
    /// nodes follow.
    @objc private func anchorsMoved(_ note: Notification) {
        guard let content = note.object as? NSView, let tile = content.superview?.superview as? TileFrameView, tile.superview === canvas.document,
              let arrows = arrowsBound[tile.objectID] else { return }
        var moved = false
        for id in arrows {
            guard let spec = items[id]?.arrow?.spec else { continue }
            let boundInside = [spec.from, spec.to].contains { binding in
                guard case .object(tile.objectID, let lines, _, let node) = binding else { return false }
                return lines != nil || node != nil
            }
            if boundInside {
                reroute(arrow: id)
                moved = true
            }
        }
        if moved { routeAfterPause() }
    }

    @objc private func tileSurfaceChanged(_ note: Notification) {
        guard let content = note.object as? NSView, let tile = canvas.tiles.values.first(where: { $0.content === content }) else { return }
        surfaceChanged(tile.frame)
    }

    nonisolated override var isFlipped: Bool { true }
    /// Drawing never takes the keyboard: it stays with the prompt-target terminal. Only the
    /// inline editors take focus, and they hand it back when they close.
    override var acceptsFirstResponder: Bool { false }

    // MARK: Coordinates

    static func docRect(_ frame: Frame) -> NSRect {
        NSRect(x: frame.x + CanvasDocumentView.origin.x, y: frame.y + CanvasDocumentView.origin.y, width: frame.w, height: frame.h)
    }

    static func canvasFrame(_ rect: NSRect) -> Frame {
        Frame(x: rect.minX - CanvasDocumentView.origin.x, y: rect.minY - CanvasDocumentView.origin.y, w: rect.width, h: rect.height)
    }

    static func docPoint(_ point: CGPoint) -> NSPoint {
        NSPoint(x: point.x + CanvasDocumentView.origin.x, y: point.y + CanvasDocumentView.origin.y)
    }

    static func canvasPoint(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x - CanvasDocumentView.origin.x, y: point.y - CanvasDocumentView.origin.y)
    }

    /// A few screen points, in document points at the current zoom.
    var tolerance: CGFloat { 6 / max(canvas.magnification, 0.1) }

    // MARK: Board events

    func apply(_ event: BoardEvent) {
        tileMoved(event)
        switch event {
        case .objectCreated(let object), .objectUpdated(let object):
            refresh(object)
            if object.type != .arrow, routedAs[object.id] != RoutingKey(object) {
                routedAs[object.id] = RoutingKey(object)
                scheduleRouting(trigger: object.id)
            }
            reroute(boundTo: object.id)
        case .objectDeleted(let id):
            if let item = items.removeValue(forKey: id) {
                invalidate(item)
                paintOrderStale = true
                if let spec = item.arrow?.spec { unbind(arrow: id, spec) }
            }
            routedAs.removeValue(forKey: id)
            provisional.remove(id)
            scheduleRouting(trigger: id)
            // Arrows bound to a deleted object keep their last route; undo re-binds them.
        default:
            break
        }
    }

    /// Rebuild one drawn object's geometry from its latest revision.
    func refresh(_ object: CanvasObject, frameOverride: NSRect? = nil) {
        let old = items[object.id]
        switch object.type {
        case .shape:
            guard let spec = ShapeSpec(object.props) else { return }
            items[object.id] = DrawnItem.shape(object, spec, frame: frameOverride ?? Self.docRect(object.frame))
        case .arrow:
            guard let spec = ArrowSpec(object.props) else { return }
            if let oldSpec = old?.arrow?.spec { unbind(arrow: object.id, oldSpec) }
            for id in [spec.from.objectID, spec.to.objectID].compactMap({ $0 }) { arrowsBound[id, default: []].insert(object.id) }
            // The board's routing places it with the rest before anything draws; until then an
            // `avoid` arrow keeps its last route (a new one a provisional one), others route alone.
            if spec.route == .avoid, let previous = old?.arrow {
                items[object.id] = DrawnItem.arrow(object, spec, path: previous.path, label: old?.labelRect.map { ConnectorRouter.Label(rect: $0, leader: old?.labelLeader) })
            } else {
                items[object.id] = routed(object, spec, previous: old, style: spec.route == .avoid ? .orthogonal : nil)
            }
            // Only a new arrow or a changed spec moves routes (a restack doesn't).
            if old?.arrow?.spec != spec {
                provisional.insert(object.id)
                scheduleRouting(trigger: object.id)
            }
        default:
            return
        }
        if let old { invalidate(old) }
        if old?.object.z != object.z || old == nil { paintOrderStale = true }
        if let item = items[object.id] { invalidate(item) }
    }

    private func unbind(arrow id: ObjectID, _ spec: ArrowSpec) {
        for bound in [spec.from.objectID, spec.to.objectID].compactMap({ $0 }) {
            arrowsBound[bound]?.remove(id)
            if arrowsBound[bound]?.isEmpty == true { arrowsBound.removeValue(forKey: bound) }
        }
    }

    /// Arrows bound to `id` follow it. A change the API is making (a write, each operation of
    /// an `object.batch`) only marks them (`followPending`): they follow once, when anything
    /// reads or draws them (`followNow`) or on the next main-queue turn, so a batch that moves a
    /// tile several times, or many tiles one arrow joins, routes each arrow alone once, outside
    /// the batch's own turn.
    func reroute(boundTo id: ObjectID) {
        guard let arrows = arrowsBound[id] else { return }
        guard ApiActivity.shared.dispatching > 0 else {
            for arrowID in arrows { reroute(arrow: arrowID) }
            return
        }
        if followPending.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.followNow() }
        }
        followPending.formUnion(arrows)
    }

    private var followPending: Set<ObjectID> = []

    /// Routes the arrows `reroute(boundTo:)` marked, or only `id` among them.
    func followNow(_ id: ObjectID? = nil) {
        if let id {
            guard followPending.remove(id) != nil else { return }
            reroute(arrow: id)
            return
        }
        guard !followPending.isEmpty else { return }
        let arrows = followPending
        followPending = []
        for arrowID in arrows.sorted() { reroute(arrow: arrowID) }
    }

    /// Routes one arrow alone, following a change to what it is bound to (a drag, a scroll, an
    /// agent's write), so it stays attached until the board's routing places it with the rest. A
    /// provisional arrow waits for that routing instead.
    private func reroute(arrow id: ObjectID) {
        guard !provisional.contains(id), let old = items[id], let spec = old.arrow?.spec else { return }
        let item = routed(old.object, spec, previous: old)
        Metrics.shared.record("route.arrow")
        guard item.arrow?.path != old.arrow?.path || item.labelRect != old.labelRect || item.labelLeader != old.labelLeader else { return }
        invalidate(old)
        items[id] = item
        invalidate(item)
    }

    /// The board's routing looks at every arrow and tile, and any change may change it, so it
    /// runs once per burst of changes, after it, off the main thread: a change the API made waits
    /// until the API is quiet (`ApiActivity`: an agent writing tile after tile routes the board
    /// once, when it stops), any other on the next main-queue turn. Meanwhile arrows bound to a
    /// changed object follow it alone (`reroute`). A new or changed arrow is never drawn or
    /// reported with its provisional route: drawing and the API route the board first, on the
    /// main thread (`settleProvisional`).
    private func scheduleRouting(trigger: ObjectID?) {
        routingGeneration += 1
        if let trigger { routingTrigger = trigger }
        if ApiActivity.shared.dispatching > 0 {
            guard !routingStale else { return }
            routingStale = true
            ApiActivity.shared.whenQuiet { [weak self] in self?.startRouting() }
        } else {
            // Not the API's: no waiting for a burst to end (`startRouting` runs one at a time).
            routingStale = true
            DispatchQueue.main.async { [weak self] in self?.startRouting() }
        }
    }

    /// A live change routes the board once it pauses (a drag held still, a drop, a scroll that
    /// stops), not on every frame of it.
    private func routeAfterPause() {
        routingPaused = true
        pauseGeneration += 1
        let generation = pauseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.routingPause) { [weak self] in
            guard let self, self.pauseGeneration == generation, self.routingPaused else { return }
            self.routingPaused = false
            self.scheduleRouting(trigger: nil)
        }
    }

    /// Before the API reports arrows (`Board.settleArrows`): new or changed arrows get their
    /// place in the board's routing now. Others report the route they are drawn on, which
    /// follows their ends; the board's routing catches up when the burst of changes ends.
    func settleArrows() {
        followNow()
        settleProvisional()
    }

    /// Routes the board on the main thread when an arrow is still provisional.
    private func settleProvisional() {
        guard !provisional.isEmpty else { return }
        guard let inputs = routingInputs() else {
            provisional = []
            return
        }
        let started = Metrics.now()
        let result = Metrics.shared.span("route", "route.board", detail: "\(inputs.connectors.count) arrows, \(inputs.obstacles.count) obstacles (main)") {
            ConnectorRouter(connectors: inputs.connectors, obstacles: inputs.obstacles, regions: inputs.regions).route(previous: routing)
        }
        routed(result, inputs, ms: (Metrics.now() - started) * 1000)
    }

    /// What the board's routing is given, from what is shown, in canvas coordinates like
    /// `layout.check`: every arrow's ends, every tile and blocking shape, and the groups.
    private struct RoutingInputs {
        var connectors: [ConnectorRouter.Connector]
        var obstacles: [ConnectorRouter.Obstacle]
        var regions: [ConnectorRouter.Region]
        /// Each routed arrow's spec and ends (document coordinates) as given.
        var given: [ObjectID: (spec: ArrowSpec, from: DrawingGeometry.ArrowEnd, to: DrawingGeometry.ArrowEnd)]
        /// The arrows that were provisional when the inputs were taken.
        var provisional: Set<ObjectID>
        var generation: Int
        /// Routings in the order their inputs were taken: an older one never replaces a newer one.
        var sequence: Int
        var trigger: ObjectID?
    }

    private var routingSequence = 0
    private var appliedSequence = 0

    private func routingInputs() -> RoutingInputs? {
        let arrows = items.values.compactMap { item in item.arrow.map { (item, $0.spec) } }.sorted { $0.0.object.id < $1.0.object.id }
        guard !arrows.isEmpty else { return nil }
        let origin = CanvasDocumentView.origin
        func canvasRect(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -origin.x, dy: -origin.y) }
        func canvasEnd(_ end: DrawingGeometry.ArrowEnd) -> DrawingGeometry.ArrowEnd {
            switch end {
            case .point(let point): .point(Self.canvasPoint(point))
            case .bound(.rect(let rect)): .bound(.rect(canvasRect(rect)))
            case .bound(.ellipse(let rect)): .bound(.ellipse(canvasRect(rect)))
            case .row(let rect, let y): .row(canvasRect(rect), y: y - origin.y)
            }
        }
        var connectors: [ConnectorRouter.Connector] = []
        var given: [ObjectID: (spec: ArrowSpec, from: DrawingGeometry.ArrowEnd, to: DrawingGeometry.ArrowEnd)] = [:]
        for (item, spec) in arrows {
            let id = item.object.id
            guard let fromDoc = arrowEnd(spec.from, of: id), let toDoc = arrowEnd(spec.to, of: id) else { continue }
            let from = canvasEnd(fromDoc), to = canvasEnd(toDoc)
            let path = spec.route == .avoid ? nil : DrawingGeometry.path(from: from, to: to, style: spec.route, offset: parallelOffset(id, spec))
            connectors.append(.init(id: id, from: from, to: to, fromObject: spec.from.objectID, toObject: spec.to.objectID,
                                    label: DrawingStyle.arrowLabel(spec)?.size, path: path))
            given[id] = (spec, fromDoc, toDoc)
        }
        var obstacles = canvas.tiles.map { id, tile in ConnectorRouter.Obstacle(id: id, rect: canvasRect(tile.frame)) }
        for (id, item) in items where canvas.tiles[id] == nil {
            guard let object = board.objects[id], BoardGeometry.blocksRoutes(object) else { continue }
            obstacles.append(.init(id: id, rect: canvasRect(item.frame)))
        }
        obstacles.sort { $0.id < $1.id }
        // Groups as shown: a tile held mid-drag has moved but its groups commit only on drop.
        let shown = Dictionary(obstacles.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
        let regions = BoardGeometry(objects: board.objects, labelSizes: [:]).regions(shown: shown)
        let trigger = routingTrigger
        routingTrigger = nil
        routingSequence += 1
        return RoutingInputs(connectors: connectors, obstacles: obstacles, regions: regions, given: given, provisional: provisional,
                             generation: routingGeneration, sequence: routingSequence, trigger: trigger)
    }

    /// Starts the board's routing on `routingQueue` when it is due and none is running.
    private func startRouting() {
        guard routingStale, !routingInFlight, !routingPaused else { return }
        routingStale = false
        guard let inputs = Metrics.shared.span("route", "route.inputs", { routingInputs() }) else {
            provisional = []
            return
        }
        routingInFlight = true
        let previous = routing
        let detail = "\(inputs.connectors.count) arrows, \(inputs.obstacles.count) obstacles"
        let router = ConnectorRouter(connectors: inputs.connectors, obstacles: inputs.obstacles, regions: inputs.regions)
        Self.routingQueue.async { [weak self] in
            let started = Metrics.now()
            let result = Metrics.shared.span("route", "route.board", detail: detail) { router.route(previous: previous) }
            let ms = (Metrics.now() - started) * 1000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.routingInFlight = false
                    self.routed(result, inputs, ms: ms)
                    if self.routingStale {
                        if ApiActivity.shared.isQuiet {
                            self.startRouting()
                        } else {
                            ApiActivity.shared.whenQuiet { [weak self] in self?.startRouting() }
                        }
                    }
                }
            }
        }
    }

    /// Takes a finished routing: every arrow whose spec and ends are still what the routing was
    /// given moves to its route and label and redraws if they changed. An arrow that changed
    /// since keeps what it shows (its own route) for the routing that change made due. Ends are
    /// compared even when no routing was scheduled since: a drag, a resize, a scroll or a
    /// selection-drag preview moves them before its pause schedules one.
    private func routed(_ result: ConnectorRouter.Result, _ inputs: RoutingInputs, ms: Double) {
        DevPerf.record("route.board", ms: ms)
        if let trigger = inputs.trigger { Metrics.shared.offender("routingTriggers", trigger, ms: ms) }
        guard inputs.sequence > appliedSequence else {
            // A routing on the main thread (`settleProvisional`) overtook this one.
            Metrics.shared.record("route.superseded")
            return
        }
        appliedSequence = inputs.sequence
        Metrics.shared.span("route", "route.apply") {
            let current = inputs.generation == routingGeneration
            if current { routingStale = false } else { Metrics.shared.record("route.stale") }
            routing = result
            let origin = CanvasDocumentView.origin
            var changedSince: Set<ObjectID> = []
            for (id, given) in inputs.given {
                guard let item = items[id], let spec = item.arrow?.spec else { continue }
                if spec != given.spec || arrowEnd(spec.from, of: id) != given.from || arrowEnd(spec.to, of: id) != given.to {
                    changedSince.insert(id)
                    continue
                }
                guard let path = result.paths[id] else { continue }
                let label = result.labels[id].map { ConnectorRouter.Label(rect: $0.rect.offsetBy(dx: origin.x, dy: origin.y), leader: $0.leader?.map(Self.docPoint)) }
                let routed = DrawnItem.arrow(item.object, spec, path: path.map(Self.docPoint), label: label)
                guard routed.arrow?.path != item.arrow?.path || routed.labelRect != item.labelRect || routed.labelLeader != item.labelLeader else { continue }
                invalidate(item)
                items[id] = routed
                invalidate(routed)
            }
            // Arrows provisional when the routing started are settled now (routed, or left on
            // their last route when an end is gone), unless they changed again since.
            provisional.subtract(inputs.provisional.subtracting(changedSince))
        }
    }

    override func viewWillDraw() {
        followNow()
        settleProvisional()
        super.viewWillDraw()
    }

    /// Arrows bound to both of `spec`'s objects, in either direction.
    private func parallels(of spec: ArrowSpec) -> Set<ObjectID> {
        guard let a = spec.from.objectID, let b = spec.to.objectID, a != b else { return [] }
        return (arrowsBound[a] ?? []).intersection(arrowsBound[b] ?? [])
    }

    // The board's routing (`startRouting`) moves siblings between the same two objects apart.

    /// This arrow's sideways offset among the arrows between the same two objects.
    private func parallelOffset(_ id: ObjectID, _ spec: ArrowSpec) -> CGFloat {
        let siblings = parallels(of: spec).union([id])
        guard siblings.count > 1 else { return 0 }
        let entries = siblings.compactMap { sibling -> (id: ObjectID, from: ObjectID?, to: ObjectID?)? in
            let siblingSpec = sibling == id ? spec : items[sibling]?.arrow?.spec ?? board.objects[sibling].flatMap { ArrowSpec($0.props) }
            return siblingSpec.map { (sibling, $0.from.objectID, $0.to.objectID) }
        }
        return DrawingGeometry.parallelOffsets(entries)[id] ?? 0
    }

    /// What arrows route and set their labels around, in document coordinates: tiles as shown
    /// (mid-drag included) and blocking shapes, minus `excluded`.
    private func obstacles(near area: NSRect, excluding excluded: Set<ObjectID>) -> [CGRect] {
        var rects = canvas.tiles.compactMap { id, tile in excluded.contains(id) || !tile.frame.intersects(area) ? nil : tile.frame }
        for (id, item) in items where !excluded.contains(id) && item.frame.intersects(area) {
            guard let object = board.objects[id], BoardGeometry.blocksRoutes(object) else { continue }
            rects.append(item.frame)
        }
        return rects
    }

    /// `style` overrides the arrow's own route style (a provisional route until a settle).
    private func routed(_ object: CanvasObject, _ spec: ArrowSpec, previous: DrawnItem?, style: ArrowRouteStyle? = nil) -> DrawnItem {

        let ends = Set([spec.from.objectID, spec.to.objectID].compactMap { $0 })
        if let from = arrowEnd(spec.from, of: object.id), let to = arrowEnd(spec.to, of: object.id) {
            let offset = parallelOffset(object.id, spec)
            let style = style ?? spec.route
            let reach = from.aim.union(to.aim).insetBy(dx: -600, dy: -600)
            let blockers = style == .avoid ? obstacles(near: reach, excluding: ends.union([object.id])) : []
            let path = DrawingGeometry.path(from: from, to: to, style: style, offset: offset, obstacles: blockers)
            guard style == spec.route else { return DrawnItem.arrow(object, spec, path: path) }
            let xs = path.map { $0.x }, ys = path.map { $0.y }
            let span = NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -300, dy: -300)
            return DrawnItem.arrow(object, spec, path: path, obstacles: obstacles(near: span, excluding: [object.id]))
        }
        // A bound object is gone (deleted, possibly about to be restored by undo): keep the last
        // route, or fall back to the arrow's recorded frame.
        if let previous = previous?.arrow {
            return DrawnItem.arrow(object, spec, path: previous.path)
        }
        let rect = Self.docRect(object.frame)
        return DrawnItem.arrow(object, spec, path: [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.maxY)])
    }

    /// Where an arrow's end attaches, as currently shown (document coordinates): a free point
    /// (carried along while the arrow is selection-dragged), else `end(of:lines:node:)`.
    private func arrowEnd(_ binding: ArrowBinding, of arrow: ObjectID) -> DrawingGeometry.ArrowEnd? {
        switch binding {
        case .point(let point):
            let shift = dragPreview.ids.contains(arrow) ? dragPreview.offset : .zero
            let doc = Self.docPoint(point)
            return .point(CGPoint(x: doc.x + shift.width, y: doc.y + shift.height))
        case .object(let id, let lines, _, let node):
            return end(of: id, lines: lines, node: node)
        }
    }

    /// Where an arrow bound to `id` (and to `lines` or a `node` of it) attaches, as currently
    /// shown (tiles mid-drag included): a code tile's line at its row as scrolled now
    /// (`CodeTile.lineY`), a diagram node's box as drawn, anything else by its outline. Lines or
    /// nodes of other tiles bind the whole tile.
    func end(of id: ObjectID, lines: LineRange?, node: String? = nil) -> DrawingGeometry.ArrowEnd? {
        // The title bar is 1×; the body below it shows the content at the tile's zoom.
        if let lines, let tile = canvas.tiles[id], let code = tile.content as? CodeTile {
            let zoom = tile.zoom, title = TileFrameView.titleHeight
            let y = code.lineY(lines.start, frameHeight: title + (tile.frame.height - title) / zoom)
            return .row(tile.frame, y: tile.frame.minY + title + zoom * (y - title))
        }
        if let node, let tile = canvas.tiles[id], let diagram = tile.content as? DiagramTile, let box = diagram.rect(ofNode: node) {
            let zoom = tile.zoom, top = tile.frame.minY + TileFrameView.titleHeight
            return .bound(.rect(CGRect(x: tile.frame.minX + zoom * box.minX, y: top + zoom * box.minY, width: zoom * box.width, height: zoom * box.height)))
        }
        return outline(of: id).map { .bound($0) }
    }

    /// Where an arrow bound to the whole of `id` attaches, as currently shown (tiles mid-drag included).
    func outline(of id: ObjectID) -> DrawingGeometry.Outline? {
        if let tile = canvas.tiles[id] { return .rect(tile.frame) }
        if let item = items[id], item.shape != nil {
            let offset = dragPreview.ids.contains(id) ? dragPreview.offset : .zero
            let frame = item.frame.offsetBy(dx: offset.width, dy: offset.height)
            return item.shape?.kind == .ellipse ? .ellipse(frame) : .rect(frame)
        }
        guard let object = board.objects[id], object.type != .arrow else { return nil }
        return .rect(Self.docRect(object.frame))
    }

    // MARK: Painting

    private func invalidate(_ item: DrawnItem) {
        invalidate(item.bounds)
        if dragPreview.ids.contains(item.object.id) {
            invalidate(item.bounds.offsetBy(dx: dragPreview.offset.width, dy: dragPreview.offset.height))
        }
        if canvas.selection.contains(item.object.id) { invalidate(handleArea(item.frame)) }
    }

    func invalidate(_ rect: NSRect) {
        setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
    }

    private var ordered: [ObjectID] {
        if paintOrderStale {
            paintOrder = items.values.sorted { ($0.object.z, $0.object.id) < ($1.object.z, $1.object.id) }.map(\.object.id)
            paintOrderStale = false
        }
        return paintOrder
    }

    override func draw(_ dirtyRect: NSRect) {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("draw.ShapeLayer", since: perfStart) }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(DrawingGeometry.strokeWidth)
        for id in ordered {
            guard let item = items[id], editor?.editing != id else { continue }
            let offset = dragPreview.ids.contains(id) && item.shape != nil ? dragPreview.offset : .zero
            guard item.bounds.offsetBy(dx: offset.width, dy: offset.height).intersects(dirtyRect) else { continue }
            if offset != .zero {
                context.saveGState()
                context.translateBy(x: offset.width, y: offset.height)
                item.draw(in: context, ink: ink(for: item))
                context.restoreGState()
            } else {
                item.draw(in: context, ink: ink(for: item))
            }
        }
        drawGesture(in: context)
        drawHandles(in: context, dirtyRect: dirtyRect)
    }

    /// `view.render`: draws the committed drawn objects whose bounds meet `docRect` (document
    /// coordinates; the context maps them) in paint order, without handles, gestures, or drag
    /// previews, and returns what it drew.
    func renderItems(in context: CGContext, docRect: NSRect, excluding excluded: RenderExclusion) -> [(object: CanvasObject, bounds: NSRect)] {
        settleArrows()
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(DrawingGeometry.strokeWidth)
        var drawn: [(object: CanvasObject, bounds: NSRect)] = []
        for id in ordered {
            guard let item = items[id], !excluded.hides(item.object), item.bounds.intersects(docRect) else { continue }
            item.draw(in: context, ink: ink(for: item, excluding: excluded))
            drawn.append((item.object, item.bounds))
        }
        return drawn
    }

    // MARK: Hit testing

    /// Topmost drawn object whose stroke, text, or fill is at a document point.
    func item(at point: NSPoint) -> DrawnItem? {
        let tolerance = self.tolerance
        for id in ordered.reversed() {
            guard let item = items[id], item.bounds.contains(point), item.hits(point, tolerance: tolerance) else { continue }
            return item
        }
        return nil
    }

    func outlineRect(_ id: ObjectID) -> NSRect? {
        guard let item = items[id] else { return nil }
        if item.arrow != nil {
            let union = item.labelRect.map { item.frame.union($0) } ?? item.frame
            return union.insetBy(dx: -4, dy: -4)
        }
        return item.frame
    }

    func ownsPoint(_ point: NSPoint) -> Bool {
        tool != .select || gesture != nil || handle(at: point) != nil || editor?.frame.contains(point) == true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point), hit !== self { return hit }
        guard frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if tool != .select || handle(at: local) != nil { return self }
        return item(at: local) != nil ? self : nil
    }

    /// A drawn object gets the same menu as a tile (close, order, scale, group, copy id).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard tool == .select, let item = item(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return canvas.objectMenu(for: item.object.id)
    }

    override func resetCursorRects() {
        if tool != .select { addCursorRect(visibleRect, cursor: tool == .text ? .iBeam : .crosshair) }
    }

    // MARK: Selection

    /// Resize handle size in screen points.
    let handleSize: CGFloat = 12

    /// Selected rect/ellipse shapes get corner handles for resizing, text shapes for scaling
    /// (the scene draws the selection); none while the canvas chrome is hidden (presenting).
    private var resizable: [DrawnItem] {
        guard !canvas.chromeHidden else { return [] }
        return canvas.selection.compactMap { items[$0] }.filter { [.rect, .ellipse, .text].contains($0.shape?.kind) }
    }

    /// Handles are a fixed size on screen, so in document points they grow as the canvas zooms out.
    private var handleDocSize: CGFloat { handleSize / max(canvas.magnification, 0.1) }

    /// Everything the handles of `frame` paint, including their border.
    func handleArea(_ frame: NSRect) -> NSRect {
        let outset = handleDocSize / 2 + 2 / max(canvas.magnification, 0.1)
        return frame.insetBy(dx: -outset, dy: -outset)
    }

    private func handleRects(_ frame: NSRect) -> [(corner: NSPoint, opposite: NSPoint, rect: NSRect)] {
        let size = handleDocSize
        let corners = [NSPoint(x: frame.minX, y: frame.minY), NSPoint(x: frame.maxX, y: frame.minY),
                       NSPoint(x: frame.maxX, y: frame.maxY), NSPoint(x: frame.minX, y: frame.maxY)]
        return corners.indices.map { index in
            let corner = corners[index]
            return (corner, corners[(index + 2) % 4], NSRect(x: corner.x - size / 2, y: corner.y - size / 2, width: size, height: size))
        }
    }

    /// The resize handle under a document point: which shape, and the corner that stays put.
    func handle(at point: NSPoint) -> (id: ObjectID, anchor: NSPoint)? {
        guard tool == .select else { return nil }
        for item in resizable {
            if let handle = handleRects(item.frame).first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) {
                return (item.object.id, handle.opposite)
            }
        }
        return nil
    }

    private func drawHandles(in context: CGContext, dirtyRect: NSRect) {
        guard tool == .select else { return }
        for item in resizable {
            var frame = item.frame
            if case .resize(let id, _, let resized) = gesture, id == item.object.id { frame = resized }
            for handle in handleRects(frame) where handle.rect.intersects(dirtyRect) {
                context.setFillColor(NSColor.white.cgColor)
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(1.5 / max(canvas.magnification, 0.1))
                context.addRect(handle.rect)
                context.drawPath(using: .fillStroke)
            }
        }
        context.setLineWidth(DrawingGeometry.strokeWidth)
    }

    private var selectionShown: Set<ObjectID> = []

    func selectionChanged() {
        let current = Set(canvas.selection.filter { items[$0] != nil })
        for id in current.symmetricDifference(selectionShown) {
            if let item = items[id] { invalidate(handleArea(item.frame)) }
        }
        selectionShown = current
    }

    // MARK: Scene seams

    func previewDrag(_ ids: Set<ObjectID>, offset: NSSize) {
        let drawn = ids.filter { items[$0] != nil }
        let before = dragPreview
        for id in before.ids { if let item = items[id] { invalidate(item) } }
        dragPreview = (drawn, offset)
        for id in drawn { if let item = items[id] { invalidate(item) } }
        // Arrows follow the shapes they are bound to; tiles report their own frame changes.
        for id in before.ids.union(drawn) where items[id]?.shape != nil { reroute(boundTo: id) }
        for id in before.ids.union(drawn) where items[id]?.arrow != nil {
            if let item = items[id], let spec = item.arrow?.spec {
                invalidate(item)
                items[id] = routed(item.object, spec, previous: item)
                invalidate(items[id]!)
            }
        }
    }

    /// A moved arrow carries its free ends along; bound ends follow their objects.
    static func moveProps(_ object: CanvasObject, dx: Double, dy: Double) -> JSONValue? {
        guard object.type == .arrow, let spec = ArrowSpec(object.props)?.translated(dx: dx, dy: dy) else { return nil }
        return .object(["from": spec.from.json, "to": spec.to.json])
    }
}
