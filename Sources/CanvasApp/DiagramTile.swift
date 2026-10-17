import AppKit
import CanvasCore

@MainActor
final class DiagramTile: NSView, TileContent {
    /// Posted (object: the tile) when its nodes moved: arrows bound to them follow.
    static let laidOut = Notification.Name("DiagramTile.laidOut")
    /// File events arrive in bursts (a save, a formatter, a branch switch); refresh once they settle.
    static let debounce: TimeInterval = 0.6
    /// Largest body the tile grows to when its first graph arrives.
    static let maxFitBody = CGSize(width: 1600, height: 1100)

    private var object: CanvasObject
    private let board: Board
    private let remote: RemoteSource?
    private var live = true
    private var graph: DiagramGraph?
    private var layout: DiagramLayout
    private enum Computation {
        case idle
        case local(Int, Task<Void, Never>)
        case asking(Int, Task<Void, Never>)
        case hostComputing

        var task: Task<Void, Never>? {
            switch self {
            case .local(_, let task), .asking(_, let task): task
            case .idle, .hostComputing: nil
            }
        }
    }
    private var computation: Computation = .idle
    private var computing: Bool {
        if case .idle = computation { return false }
        return true
    }
    private var computeGeneration = 0
    private var events: FileEvents?
    private var watched: Set<String> = []
    private var hostWatch: HostFileWatch?
    private var hostProbe: HostGitProbe?
    private var hostFailure: String?
    private var pendingRefresh: DispatchWorkItem?
    /// A file changed (or the graph was never checked since launch) while the tile wasn't
    /// live: refresh when it is again.
    private var dirty = false
    /// The first graph arrives into a tile of the default size: grow it to show the graph.
    private var fitOnArrival: Bool

    init(object: CanvasObject, board: Board, remote: RemoteSource? = nil) {
        self.object = object
        self.board = board
        self.remote = remote
        let graph = DiagramGraph(object.props["graph"])
        self.graph = graph
        layout = graph.map(DiagramLayout.init) ?? DiagramLayout(DiagramGraph(aim: DiagramSpec(object.props).aim))
        let size = Board.defaultSize(.diagram)
        fitOnArrival = (graph?.nodes.isEmpty ?? true) && object.frame.w == size.w && object.frame.h == size.h
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        if graph?.aim != DiagramSpec(object.props).aim {
            refresh()
        } else {
            // Computed in an earlier session: checked against the code once the tile shows.
            dirty = true
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    private var spec: DiagramSpec { DiagramSpec(object.props) }

    // MARK: Computing

    private func refresh() {
        computation.task?.cancel()
        pendingRefresh?.cancel()
        dirty = false
        computeGeneration += 1
        let generation = computeGeneration
        if let remote {
            computation = .asking(generation, Task { [weak self] in
                guard let self else { return }
                await self.askHost(remote, generation)
            })
        } else {
            let id = object.id, board = board
            computation = .local(generation, Task { [weak self] in
                _ = try? await DiagramRefresh.run(id, on: board, languages: CodeNavigation.languages)
                self?.computed(generation)
            })
        }
        needsDisplay = true
    }

    private func computed(_ generation: Int) {
        guard case .local(let current, _) = computation, current == generation else { return }
        computation = .idle
        needsDisplay = true
    }

    private func askHost(_ remote: RemoteSource, _ generation: Int) async {
        let failure: String?
        let loaded: Bool
        do {
            loaded = try await remote.mirror.reloadDiagram(object.id)["loaded"]?.bool == true
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            loaded = false
            failure = "Not computed on \(remote.mirror.hostName): \(BoardMirror.reason(error))"
        }
        guard case .asking(let current, _) = computation, current == generation else { return }
        hostFailure = failure
        computation = loaded || failure != nil ? .idle : .hostComputing
        needsDisplay = true
    }

    func hostDidReconnect() {
        guard remote != nil else { return }
        if live, window != nil { refresh() } else { dirty = true }
    }

    func reload() async -> JSONValue {
        refresh()
        if case .local(_, let task) = computation { await task.value }
        return DiagramRefresh.summary(object.id, graph: DiagramGraph(board.objects[object.id]?.props["graph"]), computed: !computing)
    }

    private func watch() {
        guard live, window != nil, let graph else { return stopWatching() }
        if let remote {
            guard let probe = DiagramRefresh.hostProbe(of: object, on: board) else { return stopWatching() }
            guard probe != hostProbe else { return }
            hostWatch?.cancel()
            hostProbe = probe
            let git = remote.git
            hostWatch = HostFileWatch(baseline: nil, probe: { await git.stamp(probe) }) { [weak self] _ in self?.scheduleRefresh() }
            return
        }
        var files = Set(graph.nodes.map { FileEvents.canonical(board.absoluteURL($0.path).path) })
        if let path = spec.path { files.insert(FileEvents.canonical(board.absoluteURL(path).path)) }
        let directories = Array(Set(files.map { FileEvents.watchableDirectory(for: $0) })).sorted()
        watched = files
        guard events?.directories != directories else { return }
        events = FileEvents(directories: directories) { [weak self] paths in
            guard let self, paths.contains(where: self.watched.contains) else { return }
            self.scheduleRefresh()
        }
    }

    private func stopWatching() {
        events = nil
        watched = []
        hostWatch?.cancel()
        hostWatch = nil
        hostProbe = nil
    }

    private func scheduleRefresh() {
        guard live else {
            dirty = true
            return
        }
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopWatching()
            pendingRefresh?.cancel()
            if remote != nil { dirty = true }
        } else {
            watch()
            if dirty, live { refresh() }
        }
    }

    // MARK: Geometry

    /// `id`'s box in this view's coordinates, as drawn.
    func rect(ofNode id: String) -> CGRect? {
        layout.rect(of: id, in: bounds.size)
    }

    private func node(at point: NSPoint) -> (node: DiagramNode, rect: CGRect)? {
        guard let graph else { return nil }
        for node in graph.nodes.reversed() {
            if let rect = rect(ofNode: node.id), rect.contains(point) { return (node, rect) }
        }
        return nil
    }

    /// What of a node is at `point`: its place line (`path:line`, a link) or one excerpt row.
    private enum Part { case name, place, excerpt(Int) }

    private func part(of node: DiagramNode, in rect: CGRect, at point: NSPoint) -> Part {
        let scale = layout.placement(in: bounds.size).scale
        let natural = CGRect(origin: .zero, size: CGSize(width: rect.width / scale, height: rect.height / scale))
        let y = (point.y - rect.minY) / scale
        if let index = DiagramLayout.excerptIndex(of: node, atY: y, in: natural) { return .excerpt(index) }
        let placeTop = DiagramLayout.padding + DiagramLayout.nameHeight
        return y >= placeTop && y < placeTop + DiagramLayout.placeHeight ? .place : .name
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        paint(in: bounds)
    }

    private func paint(in bounds: CGRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        drawHeader(in: bounds)
        guard let graph, let context = NSGraphicsContext.current?.cgContext, !graph.nodes.isEmpty else { return }
        let (scale, origin) = layout.placement(in: bounds.size)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        let levels = Dictionary(graph.nodes.map { ($0.id, $0.level) }, uniquingKeysWith: { first, _ in first })
        for edge in graph.edges {
            guard let from = layout.rects[edge.from], let to = layout.rects[edge.to] else { continue }
            drawEdge(from: from, to: to, step: (levels[edge.to] ?? 0) - (levels[edge.from] ?? 0), stale: edge.stale == true, in: context)
        }
        for node in graph.nodes {
            guard let rect = layout.rects[node.id] else { continue }
            drawNode(node, in: rect, isRoot: node.id == graph.root)
        }
        context.restoreGState()
    }

    private func drawHeader(in bounds: CGRect) {
        let text: String
        var color = NSColor.secondaryLabelColor
        let error = hostFailure ?? graph?.error
        if let error, graph?.nodes.isEmpty ?? true {
            // Nothing to draw: the whole reason, wrapped (an ambiguous name lists its candidates).
            let shown = (computing ? "Asking the language server again… " : "") + error
            NSAttributedString(string: shown, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemOrange])
                .draw(with: CGRect(x: 10, y: 8, width: max(0, bounds.width - 20), height: max(0, bounds.height - 16)),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return
        } else if let error {
            text = (computing ? "Asking the language server again… " : "") + error
            color = .systemOrange
        } else if computing {
            text = graph == nil ? "Asking the language server… (a first answer in a project can take a while)" : "Asking the language server again…"
        } else if let graph {
            let others = graph.nodes.count - 1
            let noun: String
            switch graph.aim.direction {
            case .incoming: noun = others == 1 ? "caller" : "callers"
            case .outgoing: noun = others == 1 ? "callee" : "callees"
            case .both: noun = others == 1 ? "function" : "functions"
            }
            var parts = ["\(others) \(noun)", "depth \(spec.depth)"]
            let stale = graph.nodes.filter(\.isStale).count
            if stale > 0 { parts.append("\(stale) stale") }
            if let omitted = graph.omitted { parts.append("\(omitted) more not shown") }
            parts.append("click a node with + to open its next level")
            text = parts.joined(separator: " · ")
        } else {
            text = ""
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color, .paragraphStyle: style])
            .draw(with: CGRect(x: 10, y: 7, width: max(0, bounds.width - 20), height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// `step`: columns from the caller to the callee. Rightward calls run from the caller's
    /// right edge to the callee's left; a call within one column (a caller of the root that also
    /// calls another caller) loops out left of the column, clear of the boxes; a leftward one
    /// (recursion through a cycle) runs from the caller's left edge to the callee's right.
    private func drawEdge(from: CGRect, to: CGRect, step: Int, stale: Bool, in context: CGContext) {
        let path = NSBezierPath()
        let start: CGPoint, end: CGPoint, c1: CGPoint, c2: CGPoint
        if step > 0 {
            start = CGPoint(x: from.maxX, y: from.midY)
            end = CGPoint(x: to.minX - 1, y: to.midY)
            let reach = max(24, (end.x - start.x) / 2)
            c1 = CGPoint(x: start.x + reach, y: start.y)
            c2 = CGPoint(x: end.x - reach, y: end.y)
        } else if step == 0 {
            let reach = DiagramLayout.margin - 4
            start = CGPoint(x: from.minX, y: from.midY)
            end = CGPoint(x: to.minX - 1, y: to.midY)
            c1 = CGPoint(x: start.x - reach, y: start.y)
            c2 = CGPoint(x: end.x - reach, y: end.y)
        } else {
            start = CGPoint(x: from.minX, y: from.midY)
            end = CGPoint(x: to.maxX + 1, y: to.midY)
            let reach = max(24, (start.x - end.x) / 2)
            c1 = CGPoint(x: start.x - reach, y: start.y)
            c2 = CGPoint(x: end.x + reach, y: end.y)
        }
        path.move(to: start)
        path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
        path.lineWidth = 1.3
        if stale { path.setLineDash([4, 3], count: 2, phase: 0) }
        let color = stale ? NSColor.systemOrange.withAlphaComponent(0.7) : NSColor.secondaryLabelColor.withAlphaComponent(0.8)
        color.setStroke()
        path.stroke()
        // The head, along the curve's last tangent.
        let angle = atan2(end.y - c2.y, end.x - c2.x)
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: CGPoint(x: end.x - 8 * cos(angle - 0.4), y: end.y - 8 * sin(angle - 0.4)))
        head.line(to: CGPoint(x: end.x - 8 * cos(angle + 0.4), y: end.y - 8 * sin(angle + 0.4)))
        head.close()
        color.setFill()
        head.fill()
    }

    private func drawNode(_ node: DiagramNode, in rect: CGRect, isRoot: Bool) {
        let stale = node.isStale
        let box = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isRoot ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        box.fill()
        box.lineWidth = isRoot ? 1.6 : 1
        if stale { box.setLineDash([5, 3], count: 2, phase: 0) }
        (stale ? NSColor.systemOrange : isRoot ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        box.stroke()

        let fade: CGFloat = stale ? 0.55 : 1
        let inner = rect.insetBy(dx: DiagramLayout.padding + 2, dy: 0)
        var y = rect.minY + DiagramLayout.padding
        let badgeWidth: CGFloat = stale ? 46 : (node.expandable == true || node.expanded == true) ? 22 : 0
        let clip = NSMutableParagraphStyle()
        clip.lineBreakMode = .byTruncatingMiddle
        NSAttributedString(string: node.name, attributes: [.font: NSFont.boldSystemFont(ofSize: 12.5), .foregroundColor: NSColor.labelColor.withAlphaComponent(fade), .paragraphStyle: clip])
            .draw(with: CGRect(x: inner.minX, y: y, width: inner.width - badgeWidth, height: DiagramLayout.nameHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        y += DiagramLayout.nameHeight
        let place = [node.container, "\(PathLabel.short(node.path)):\(node.line)"].compactMap { $0 }.joined(separator: " · ")
        NSAttributedString(string: place, attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.linkColor.withAlphaComponent(fade), .paragraphStyle: clip])
            .draw(with: CGRect(x: inner.minX, y: y, width: inner.width, height: DiagramLayout.placeHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        y += DiagramLayout.placeHeight + 4
        let tail = NSMutableParagraphStyle()
        tail.lineBreakMode = .byTruncatingTail
        let code = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let numberWidth: CGFloat = 34
        for row in node.excerpt {
            NSAttributedString(string: "\(row.line)", attributes: [.font: code, .foregroundColor: NSColor.tertiaryLabelColor.withAlphaComponent(fade)])
                .draw(with: CGRect(x: inner.minX, y: y, width: numberWidth, height: DiagramLayout.excerptLineHeight), options: [.usesLineFragmentOrigin])
            NSAttributedString(string: row.text, attributes: [.font: code, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85 * fade), .paragraphStyle: tail])
                .draw(with: CGRect(x: inner.minX + numberWidth, y: y, width: inner.width - numberWidth, height: DiagramLayout.excerptLineHeight),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += DiagramLayout.excerptLineHeight
        }

        if stale {
            let badge = CGRect(x: rect.maxX - 50, y: rect.minY + 7, width: 42, height: 16)
            NSColor.systemOrange.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
            let label = NSAttributedString(string: "stale", attributes: [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white])
            label.draw(at: CGPoint(x: badge.midX - label.size().width / 2, y: badge.minY + 1.5))
        } else if node.expandable == true || node.expanded == true {
            let badge = CGRect(x: rect.maxX - 26, y: rect.minY + 6, width: 18, height: 18)
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(ovalIn: badge).fill()
            let label = NSAttributedString(string: node.expanded == true ? "−" : "+", attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.controlAccentColor])
            let size = label.size()
            label.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        }
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.clickCount == 1, let (node, rect) = node(at: point) else { return super.mouseDown(with: event) }
        if case .place = part(of: node, in: rect, at: point) {
            let opened = board.openForNavigation(CodeAim(path: node.path, range: LineRange(start: node.line, end: node.line), symbol: node.qualifiedName), from: object.id)
            onOpenedCode?(opened.id, opened.existing)
            return
        }
        var expanded = spec.expanded
        if let index = expanded.firstIndex(of: node.id) {
            expanded.remove(at: index)
        } else if node.expandable == true {
            expanded.append(node.id)
            pendingExpand = (node.id, Set(graph?.nodes.map(\.id) ?? []))
        } else {
            return super.mouseDown(with: event)
        }
        _ = try? board.update(object.id, props: .object(["expanded": .array(expanded.map(JSONValue.string))]))
    }

    /// Set by the canvas: a code tile opened (or found showing the lines) from a node.
    var onOpenedCode: ((ObjectID, _ existing: Bool) -> Void)?
    /// Set by the canvas: the user opened a node and the graph that came back grew. easl
    /// rects of the tile, the nodes the expansion added (their union; null when none), and the
    /// node clicked, for the pan that shows them (`Layout.revealGrown`).
    var onExpanded: ((_ tile: CGRect, _ added: CGRect, _ clicked: CGRect) -> Void)?
    /// A node the user clicked open, with the nodes shown then, until the next graph arrives.
    private var pendingExpand: (node: String, shown: Set<String>)?

    override func resetCursorRects() {
        guard let graph else { return }
        for node in graph.nodes {
            guard let rect = rect(ofNode: node.id) else { continue }
            let scale = layout.placement(in: bounds.size).scale
            let placeTop = rect.minY + scale * (DiagramLayout.padding + DiagramLayout.nameHeight)
            addCursorRect(CGRect(x: rect.minX, y: placeTop, width: rect.width, height: scale * DiagramLayout.placeHeight), cursor: .pointingHand)
            if node.expandable == true || node.expanded == true {
                addCursorRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: placeTop - rect.minY), cursor: .pointingHand)
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        laidOut()
    }

    private func laidOut() {
        window?.invalidateCursorRects(for: self)
        NotificationCenter.default.post(name: Self.laidOut, object: self)
    }

    // MARK: TileContent

    func setLive(_ live: Bool) {
        guard live != self.live else { return }
        self.live = live
        if live {
            watch()
            if dirty { refresh() }
        } else {
            stopWatching()
            if remote != nil {
                pendingRefresh?.cancel()
                pendingRefresh = nil
                dirty = true
            }
        }
    }

    func render(_ request: TileRenderRequest) async -> TileRender {
        if graph == nil, case .local(_, let task) = computation { await task.value }
        let size = request.full ? CGSize(width: max(request.size.width, layout.bodySize.width), height: max(request.size.height, layout.bodySize.height)) : request.size
        guard let image = request.image(size: size, { bounds in paint(in: bounds) }) else {
            return TileRender(image: nil, contentSize: request.size, state: .failed, reason: "bitmap allocation failed")
        }
        return TileRender(image: image, contentSize: layout.bodySize, state: .rendered)
    }

    /// A node's symbol (its declaration) or the excerpt line under the pointer; else the tile.
    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard let (node, rect) = node(at: point) else { return .object(object.id) }
        if case .excerpt(let index) = part(of: node, in: rect, at: point) { return node.mention(in: object.id, excerptLine: node.excerpt[index].line) }
        return node.mention(in: object.id)
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .code(_, let path, let lines, _, let symbol, _, _) = target, let graph,
              let node = graph.nodes.first(where: { $0.path == path && $0.qualifiedName == symbol }), let rect = rect(ofNode: node.id) else { return bounds }
        guard lines.start == lines.end, lines != node.lines, let index = node.excerpt.firstIndex(where: { $0.line == lines.start }) else { return rect }
        let scale = layout.placement(in: bounds.size).scale
        let top = rect.minY + scale * (DiagramLayout.padding + DiagramLayout.nameHeight + DiagramLayout.placeHeight + 4 + CGFloat(index) * DiagramLayout.excerptLineHeight)
        return CGRect(x: rect.minX, y: top, width: rect.width, height: scale * DiagramLayout.excerptLineHeight)
    }

    var takesKeyboardFocus: Bool { false }

    func update(_ object: CanvasObject) {
        let previous = self.object
        self.object = object
        if DiagramSpec(previous.props) != DiagramSpec(object.props) {
            refresh()
        } else if remote != nil, computing, object.rev != previous.rev {
            scheduleRefresh()
        }
        guard previous.props["graph"] != object.props["graph"] else { return }
        hostFailure = nil
        switch computation {
        case .asking, .hostComputing: computation = .idle
        case .idle, .local: break
        }
        // An error before any node (a server still loading) isn't the first graph yet.
        let before = graph?.nodes.count ?? 0
        graph = DiagramGraph(object.props["graph"])
        layout = graph.map(DiagramLayout.init) ?? DiagramLayout(DiagramGraph(aim: spec.aim))
        let after = graph?.nodes.count ?? 0
        if before == 0, fitOnArrival, after > 0 {
            fitOnArrival = false
            fit(growingOnly: false)
        } else if after > before, before > 0 {
            // A node opened (or callers appeared): room for them rather than a smaller drawing.
            fit(growingOnly: true)
        }
        if let expand = pendingExpand {
            pendingExpand = nil
            revealExpansion(expand)
        }
        watch()
        needsDisplay = true
        laidOut()
    }

    /// After the user's own expansion: the tile's, added nodes' and clicked node's canvas rects
    /// as the tile now is (grown or not), to the canvas, which pans to show them.
    private func revealExpansion(_ expand: (node: String, shown: Set<String>)) {
        guard let onExpanded, let now = board.objects[object.id], let graph else { return }
        func rect(_ id: String) -> CGRect? { DiagramLayout.canvasRect(of: id, frame: now.frame, props: now.props) }
        guard let clicked = rect(expand.node) else { return }
        let added = graph.nodes.filter { !expand.shown.contains($0.id) }.compactMap { rect($0.id) }.reduce(CGRect.null) { $0.union($1) }
        onExpanded(now.frame.rect, added, clicked)
    }

    /// Sizes the tile to show its graph whole, up to `maxFitBody`: from the default size when
    /// the first graph arrives, and only ever larger when the graph grows (the user's own
    /// resize stays unless the graph needs more), into free space only (`Board.grownFrame`):
    /// what doesn't fit is drawn scaled. The app's write, not an undo step.
    private func fit(growingOnly: Bool) {
        guard remote == nil else { return }
        let zoom = CGFloat(object.zoom)
        let body = layout.bodySize, current = RenderMath.body(of: object)
        var w = min(body.width, Self.maxFitBody.width), h = min(body.height, Self.maxFitBody.height)
        if growingOnly {
            w = max(w, current.width)
            h = max(h, current.height)
            guard w > current.width || h > current.height else { return }
        }
        guard let frame = try? board.grownFrame(object.id, toward: ObjectZoom.zoomed(CGSize(width: w, height: h + RenderMath.tileTitleHeight), zoom: Double(zoom))),
              frame != object.frame else { return }
        _ = try? board.update(object.id, frame: frame, actor: .system)
    }
}
