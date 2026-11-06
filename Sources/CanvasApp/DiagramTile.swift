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
    /// A graph node whose full detail is expanded below the diagram.
    private var expandedNode: String? {
        didSet {
            cancelDetail()
            detailScrollOffset = 0
        }
    }
    private var detailLayout: DetailLayout?
    private var detailScrollOffset: CGFloat = 0

    /// Set by the canvas: focus the terminal tile a graph node's source names.
    var onFocusTile: ((ObjectID) -> Void)?
    /// Set by the canvas: a graph node's source can't be resolved on this board.
    var onSourceNotice: ((String) -> Void)?

    init(object: CanvasObject, board: Board, remote: RemoteSource? = nil) {
        self.object = object
        self.board = board
        self.remote = remote
        let graph = DiagramGraph.stored(in: object.props)
        self.graph = graph
        layout = graph.map(DiagramLayout.init) ?? DiagramLayout(DiagramGraph(aim: DiagramSpec(object.props).aim))
        let size = Board.defaultSize(.diagram)
        fitOnArrival = (graph?.nodes.isEmpty ?? true) && object.frame.w == size.w && object.frame.h == size.h
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        if graph?.aim != DiagramSpec(object.props).aim, DiagramSpec(object.props).kind != .graph {
            refresh()
        } else if DiagramSpec(object.props).kind != .graph {
            // Computed in an earlier session: checked against the code once the tile shows.
            dirty = true
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    private var spec: DiagramSpec { DiagramSpec(object.props) }

    // MARK: Computing

    private var isGraph: Bool { spec.kind == .graph }

    private func refresh() {
        computation.task?.cancel()
        pendingRefresh?.cancel()
        dirty = false
        // A graph diagram's nodes and edges are the caller's: there is nothing to compute.
        guard !isGraph else {
            computation = .idle
            needsDisplay = true
            return
        }
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
        if isGraph {
            let graph = DiagramGraph.stored(in: board.objects[object.id]?.props)
            return DiagramRefresh.summary(object.id, graph: graph, computed: graph != nil)
        }
        refresh()
        if case .local(_, let task) = computation { await task.value }
        return DiagramRefresh.summary(object.id, graph: DiagramGraph.stored(in: board.objects[object.id]?.props), computed: !computing)
    }

    private func watch() {
        guard live, window != nil, let graph, graph.aim.kind != .graph else { return stopWatching() }
        if let remote {
            guard let probe = DiagramRefresh.hostProbe(of: object, on: board) else { return stopWatching() }
            guard probe != hostProbe else { return }
            hostWatch?.cancel()
            hostProbe = probe
            let git = remote.git
            hostWatch = HostFileWatch(baseline: nil, probe: { await git.stamp(probe) }) { [weak self] _ in self?.scheduleRefresh() }
            return
        }
        var files = Set(graph.nodes.compactMap(\.path).map { FileEvents.canonical(board.absoluteURL($0).path) })
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
            cancelDetail()
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
        layout.rect(of: id, in: graphBodySize)
    }

    /// The body the graph draws in: below nothing, above the expanded detail panel when there is one.
    private var graphBodySize: CGSize {
        let panel = detailPanel(in: CGRect(origin: .zero, size: bounds.size))
        return CGSize(width: bounds.size.width, height: max(1, bounds.size.height - (panel?.height ?? 0)))
    }

    private func node(at point: NSPoint) -> (node: DiagramNode, rect: CGRect)? {
        guard let graph else { return nil }
        for node in graph.nodes.reversed() {
            if let rect = rect(ofNode: node.id), rect.contains(point) { return (node, rect) }
        }
        return nil
    }

    /// What of a node is at `point`: a graph node's source badge, its status badge or the rest
    /// of its box (a click expands its detail); a code node's place line (`path:line`, a link),
    /// one excerpt row, or its name.
    private enum Part { case name, place, excerpt(Int), source, status }

    private func part(of node: DiagramNode, in rect: CGRect, at point: NSPoint) -> Part {
        let scale = max(0.0001, layout.placement(in: graphBodySize).scale)
        let natural = CGRect(origin: .zero, size: CGSize(width: rect.width / scale, height: rect.height / scale))
        let local = CGPoint(x: (point.x - rect.minX) / scale, y: (point.y - rect.minY) / scale)
        if isGraph || node.detail != nil {
            if sourceBadgeRect(node, in: natural)?.contains(local) == true { return .source }
            if statusBadgeRect(node, in: natural)?.contains(local) == true { return .status }
            return .name
        }
        let y = local.y
        if let index = DiagramLayout.excerptIndex(of: node, atY: y, in: natural) { return .excerpt(index) }
        let placeTop = DiagramLayout.padding + DiagramLayout.nameHeight
        return y >= placeTop && y < placeTop + DiagramLayout.placeHeight ? .place : .name
    }

    private func statusBadgeRect(_ node: DiagramNode, in rect: CGRect) -> CGRect? {
        guard let status = node.status else { return nil }
        let width = ceil(textWidth(status.rawValue, font: Self.badgeFont)) + 14
        return CGRect(x: rect.maxX - width - 8, y: rect.minY + 5, width: width, height: 18)
    }

    private func sourceBadgeRect(_ node: DiagramNode, in rect: CGRect) -> CGRect? {
        guard let count = node.sources?.count, count > 0 else { return nil }
        let label = count > 1 ? "\(count) ↗" : "↗"
        let width = ceil(textWidth(label, font: Self.badgeFont)) + 12
        let right = statusBadgeRect(node, in: rect).map { $0.minX - 4 } ?? rect.maxX - 8
        return CGRect(x: right - width, y: rect.minY + 5, width: width, height: 18)
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    private static let badgeFont = NSFont.boldSystemFont(ofSize: 9.5)
    private static let detailFont = NSFont.systemFont(ofSize: 10.5)

    // MARK: Drawing

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cancelDetail()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        paint(in: bounds)
    }

    private func paint(in bounds: CGRect) {
        let panel = detailPanel(in: bounds)
        paint(in: bounds, graph: graph, layout: layout, panel: panel, scrollOffset: detailScrollOffset)
    }

    private func paint(in bounds: CGRect, graph: DiagramGraph?, layout: DiagramLayout, panel: DetailPanel?, scrollOffset: CGFloat) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        drawHeader(in: bounds, graph: graph)
        guard let graph, let context = NSGraphicsContext.current?.cgContext, !graph.nodes.isEmpty else { return }
        let body = CGSize(width: bounds.width, height: max(1, bounds.height - (panel?.height ?? 0)))
        let (scale, origin) = layout.placement(in: body)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        let levels = Dictionary(graph.nodes.map { ($0.id, $0.level) }, uniquingKeysWith: { first, _ in first })
        for edge in graph.edges {
            guard let from = layout.rects[edge.from], let to = layout.rects[edge.to] else { continue }
            drawEdge(from: from, to: to, step: (levels[edge.to] ?? 0) - (levels[edge.from] ?? 0), stale: edge.stale == true,
                     label: graph.aim.kind == .graph ? edge.label : nil, in: context)
        }
        for node in graph.nodes {
            guard let rect = layout.rects[node.id] else { continue }
            if graph.aim.kind == .graph {
                drawGraphNode(node, in: rect)
            } else {
                drawNode(node, in: rect, isRoot: node.id == graph.root)
            }
        }
        context.restoreGState()
        if let panel { drawDetailPanel(panel, in: bounds, scrollOffset: scrollOffset) }
    }

    private func drawHeader(in bounds: CGRect, graph: DiagramGraph?) {
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
        } else if let graph, graph.aim.kind == .graph {
            let levels = Set(graph.nodes.map(\.level)).count
            var parts = ["\(graph.nodes.count) nodes", "\(graph.edges.count) links", "\(levels) levels"]
            let weak = graph.nodes.filter { $0.status == .weak }.count
            if weak > 0 { parts.append("\(weak) weak") }
            parts.append("click a node for its detail")
            text = parts.joined(separator: " · ")
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
    private func drawEdge(from: CGRect, to: CGRect, step: Int, stale: Bool, label: String?, in context: CGContext) {
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
        guard let label, !label.isEmpty else { return }
        let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
        let size = text.size()
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let box = CGRect(x: mid.x - size.width / 2 - 4, y: mid.y - size.height / 2 - 1, width: size.width + 8, height: size.height + 2)
        NSColor.textBackgroundColor.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: box.minX + 4, y: box.minY + 1))
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
        let place = [node.container, node.path.flatMap { path in node.line.map { "\(PathLabel.short(path)):\($0)" } }].compactMap { $0 }.joined(separator: " · ")
        NSAttributedString(string: place, attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.linkColor.withAlphaComponent(fade), .paragraphStyle: clip])
            .draw(with: CGRect(x: inner.minX, y: y, width: inner.width, height: DiagramLayout.placeHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        y += DiagramLayout.placeHeight + 4
        let tail = NSMutableParagraphStyle()
        tail.lineBreakMode = .byTruncatingTail
        let code = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let numberWidth: CGFloat = 34
        for row in node.excerpt ?? [] {
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

    /// A graph node: its label, two rows of detail (a click expands the rest) and badges for
    /// practice status and where it came from.
    private func drawGraphNode(_ node: DiagramNode, in rect: CGRect) {
        let statusColor = node.status.map(Self.statusColor)
        let box = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        box.fill()
        box.lineWidth = statusColor == nil ? 1 : 1.4
        (statusColor ?? NSColor.separatorColor).setStroke()
        box.stroke()

        let status = statusBadgeRect(node, in: rect)
        let source = sourceBadgeRect(node, in: rect)
        let reserved = [status, source].compactMap { $0 }.map { rect.maxX - $0.minX }.max() ?? 0
        let inner = rect.insetBy(dx: DiagramLayout.padding + 2, dy: 0)
        let clip = NSMutableParagraphStyle()
        clip.lineBreakMode = .byTruncatingMiddle
        // A node with only a label sits it in the middle of its box; one with detail starts at the top.
        let nameY = node.detail == nil ? rect.midY - DiagramLayout.nameHeight / 2 : rect.minY + DiagramLayout.padding
        NSAttributedString(string: node.name, attributes: [.font: NSFont.boldSystemFont(ofSize: 12.5), .foregroundColor: NSColor.labelColor, .paragraphStyle: clip])
            .draw(with: CGRect(x: inner.minX, y: nameY, width: inner.width - reserved - 4, height: DiagramLayout.nameHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let detail = node.detail {
            let tail = NSMutableParagraphStyle()
            tail.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: Self.detailPreview(detail), attributes: [.font: Self.detailFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: tail])
                .draw(with: CGRect(x: inner.minX, y: rect.minY + DiagramLayout.padding + DiagramLayout.nameHeight + 4,
                                   width: inner.width, height: CGFloat(DiagramLayout.detailLines) * DiagramLayout.excerptLineHeight),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        if let status, let statusValue = node.status {
            statusColor?.setFill()
            NSBezierPath(roundedRect: status, xRadius: 9, yRadius: 9).fill()
            let label = NSAttributedString(string: statusValue.rawValue, attributes: [.font: Self.badgeFont, .foregroundColor: NSColor.white])
            let size = label.size()
            label.draw(at: CGPoint(x: status.midX - size.width / 2, y: status.midY - size.height / 2))
        }
        if let source {
            NSColor.secondaryLabelColor.withAlphaComponent(0.24).setFill()
            NSBezierPath(roundedRect: source, xRadius: 9, yRadius: 9).fill()
            NSColor.separatorColor.setStroke()
            let outline = NSBezierPath(roundedRect: source, xRadius: 9, yRadius: 9)
            outline.lineWidth = 1
            outline.stroke()
            let count = node.sources?.count ?? 0
            let labelText = count > 1 ? "\(count) ↗" : "↗"
            let label = NSAttributedString(string: labelText, attributes: [.font: Self.badgeFont, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85)])
            let size = label.size()
            label.draw(at: CGPoint(x: source.midX - size.width / 2, y: source.midY - size.height / 2))
        }
    }

    private static func statusColor(_ status: DiagramNodeStatus) -> NSColor {
        switch status {
        case .taught: .systemPurple
        case .practiced: .systemBlue
        case .retained: .systemGreen
        case .weak: .systemOrange
        }
    }

    /// The first words of `detail` as one plain line: a collapsed node shows its argument, not
    /// its markdown (headings, fences and list markers are the expanded panel's).
    static func detailPreview(_ detail: String) -> String {
        for raw in detail.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("```") else { continue }
            for marker in ["**", "__", "`"] { line = line.replacingOccurrences(of: marker, with: "") }
            for prefix in ["> ", "- ", "* ", "+ "] where line.hasPrefix(prefix) { line.removeFirst(prefix.count) }
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
        }
        return ""
    }

    // MARK: Expanded detail

    private struct DetailPanel {
        var node: DiagramNode
        var text: NSAttributedString
        var textHeight: CGFloat
        var height: CGFloat
        var width: CGFloat

        init(node: DiagramNode, text: NSAttributedString, textHeight: CGFloat, in bounds: CGRect) {
            self.node = node
            self.text = text
            self.textHeight = textHeight
            height = min(textHeight + 46, min(320, max(0, bounds.height * 0.4)))
            width = max(1, bounds.width - 24)
        }
    }

    private struct DetailLayout {
        var id: String
        var detail: String
        var width: CGFloat
        var zoom: Double
        var appearance: NSAppearance.Name
        var text: NSAttributedString
        var textHeight: CGFloat
    }

    private func cancelDetail() {
        detailLayout = nil
    }

    private func detailPanel(in bounds: CGRect) -> DetailPanel? {
        guard isGraph, let id = expandedNode, let node = graph?.node(id), let detail = node.detail, !detail.isEmpty else {
            cancelDetail()
            detailScrollOffset = 0
            return nil
        }
        let width = max(1, bounds.width - 24)
        let appearance = effectiveAppearance.name
        if detailLayout?.id != id || detailLayout?.detail != detail || detailLayout?.width != width
            || detailLayout?.zoom != object.zoom || detailLayout?.appearance != appearance {
            cancelDetail()
            let renderer = NoteRenderer(excerpts: [:], source: detail, width: width)
            let document = NoteMarkdown.parse(detail)
            let text = renderer.render(document, placeholder: "")
            let measured = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            detailLayout = DetailLayout(id: id, detail: detail, width: width, zoom: object.zoom,
                                        appearance: appearance, text: text, textHeight: ceil(measured))
            detailScrollOffset = 0
        }
        guard let cached = detailLayout else { return nil }
        let panel = DetailPanel(node: node, text: cached.text, textHeight: cached.textHeight, in: bounds)
        detailScrollOffset = min(detailScrollOffset, max(0, cached.textHeight - max(0, panel.height - 36)))
        return panel
    }

    private func drawDetailPanel(_ panel: DetailPanel, in bounds: CGRect, scrollOffset: CGFloat) {
        let rect = CGRect(x: 0, y: bounds.maxY - panel.height, width: bounds.width, height: panel.height)
        NSColor.controlBackgroundColor.setFill()
        rect.fill()
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath()
        line.move(to: CGPoint(x: rect.minX, y: rect.minY))
        line.line(to: CGPoint(x: rect.maxX, y: rect.minY))
        line.lineWidth = 1
        line.stroke()
        var heading = panel.node.name
        if let status = panel.node.status { heading += " · \(status.rawValue)" }
        if panel.textHeight > max(0, panel.height - 36) { heading += " · scroll for detail" }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: heading, attributes: [.font: NSFont.boldSystemFont(ofSize: 11.5), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
            .draw(with: CGRect(x: 12, y: rect.minY + 8, width: panel.width, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let viewport = CGRect(x: 12, y: rect.minY + 28, width: panel.width, height: max(0, panel.height - 36))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.clip(to: viewport)
        panel.text.draw(with: CGRect(x: viewport.minX, y: viewport.minY - scrollOffset,
                                     width: panel.width, height: panel.textHeight),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    func canScroll(at point: NSPoint, direction: CGVector) -> Bool {
        guard direction.dx == 0, let panel = detailPanel(in: bounds),
              bounds.contains(point), point.y >= bounds.maxY - panel.height else { return false }
        return CanvasWheel.canScroll(offset: detailScrollOffset,
                                     maximum: panel.textHeight - max(0, panel.height - 36), delta: direction.dy)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let panel = detailPanel(in: bounds) else { return }
        let maximum = max(0, panel.textHeight - max(0, panel.height - 36))
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 16)
        detailScrollOffset = min(maximum, max(0, detailScrollOffset - delta))
        needsDisplay = true
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.clickCount == 1, let (node, rect) = node(at: point) else { return super.mouseDown(with: event) }
        if isGraph {
            switch part(of: node, in: rect, at: point) {
            case .source:
                let sources = node.sources ?? []
                if let tile = sources.lazy.compactMap({ self.resolvedTile(for: $0) }).first {
                    onFocusTile?(tile)
                } else if let source = sources.first {
                    onSourceNotice?(Self.sourceProblem(source, on: board))
                }
            case .status:
                return
            case .name, .place, .excerpt:
                guard let detail = node.detail, !detail.isEmpty else { return }
                expandedNode = expandedNode == node.id ? nil : node.id
                needsDisplay = true
                laidOut()
                if expandedNode != nil, remote == nil { fit(growingOnly: true) }
            }
            return
        }
        if case .place = part(of: node, in: rect, at: point), let path = node.path, let line = node.line {
            let opened = board.openForNavigation(CodeAim(path: path, range: LineRange(start: line, end: line), symbol: node.qualifiedName), from: object.id)
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

    /// The terminal tile a graph node's source names, when this board can show it.
    func resolvedTile(for source: DiagramSource) -> ObjectID? {
        if let boardID = source.board, boardID != board.id { return nil }
        if let tile = source.tile {
            guard let object = board.objects[tile] else { return nil }
            return object.type == .terminal ? tile : nil
        }
        guard let session = source.session else { return nil }
        for object in board.objects.values where object.type == .terminal {
            let agent = object.props["agent"]
            if agent?["sessionId"]?.string == session || agent?["sessionPath"]?.string == session { return object.id }
        }
        return nil
    }

    /// Why a graph node's source can't be shown here (the badge stays a record of where it came from).
    static func sourceProblem(_ source: DiagramSource, on board: Board) -> String {
        if let boardID = source.board, boardID != board.id { return "Source is on board \(boardID), not this one" }
        if let tile = source.tile {
            return board.objects[tile].map { "\(tile) is a \($0.type.rawValue) tile, not a terminal" } ?? "Source tile \(tile) isn't on this board"
        }
        if let session = source.session { return "No terminal on this board is session \(session)" }
        if let message = source.message { return "Source message \(message) isn't a tile on this board" }
        return "Source isn't on this board"
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
            if isGraph || node.detail != nil {
                addCursorRect(rect, cursor: .pointingHand)
                continue
            }
            let scale = layout.placement(in: graphBodySize).scale
            let placeTop = rect.minY + scale * (DiagramLayout.padding + DiagramLayout.nameHeight)
            addCursorRect(CGRect(x: rect.minX, y: placeTop, width: rect.width, height: scale * DiagramLayout.placeHeight), cursor: .pointingHand)
            if node.expandable == true || node.expanded == true {
                addCursorRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: placeTop - rect.minY), cursor: .pointingHand)
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != bounds.width
        super.setFrameSize(newSize)
        if widthChanged { cancelDetail() }
        needsDisplay = true
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
            cancelDetail()
            watch()
            if dirty { refresh() }
        } else {
            stopWatching()
            cancelDetail()
            if remote != nil {
                pendingRefresh?.cancel()
                pendingRefresh = nil
                dirty = true
            }
        }
    }

    func render(_ request: TileRenderRequest) async -> TileRender {
        if graph == nil, case .local(_, let task) = computation { await task.value }
        guard !Task.isCancelled else { return .placeholder(request, "cancelled") }
        let graph = graph, layout = layout, expandedNode = expandedNode
        let scrollOffset = detailScrollOffset
        var content = layout.bodySize
        let width = request.full ? max(request.size.width, content.width) : request.size.width
        var panel: DetailPanel?
        if graph?.aim.kind == .graph, let id = expandedNode, let node = graph?.node(id),
           let detail = node.detail, !detail.isEmpty {
            let textWidth = max(1, width - 24)
            let renderer = NoteRenderer(excerpts: [:], source: detail, width: textWidth)
            let text = renderer.render(NoteMarkdown.parse(detail), placeholder: "")
            let measured = text.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            panel = DetailPanel(node: node, text: text, textHeight: ceil(measured),
                                in: CGRect(origin: .zero, size: CGSize(width: width, height: content.height)))
        }
        content.height += panel?.height ?? 0
        let size = request.full ? CGSize(width: max(request.size.width, content.width), height: max(request.size.height, content.height)) : request.size
        if let prepared = panel {
            panel = DetailPanel(node: prepared.node, text: prepared.text, textHeight: prepared.textHeight,
                                in: CGRect(origin: .zero, size: size))
        }
        let offset = min(scrollOffset, max(0, (panel?.textHeight ?? 0) - max(0, (panel?.height ?? 0) - 36)))
        guard let image = request.image(size: size, { bounds in
            paint(in: bounds, graph: graph, layout: layout, panel: panel, scrollOffset: offset)
        }) else {
            return TileRender(image: nil, contentSize: request.size, state: .failed, reason: "bitmap allocation failed")
        }
        return TileRender(image: image, contentSize: content, state: .rendered)
    }

    /// A code node's symbol or excerpt line under the pointer; a graph node is its tile (its
    /// detail expands in place, it opens no code).
    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard !isGraph, let (node, rect) = node(at: point) else { return .object(object.id) }
        if case .excerpt(let index) = part(of: node, in: rect, at: point), let line = node.excerpt?[index].line {
            return node.mention(in: object.id, excerptLine: line)
        }
        return node.mention(in: object.id)
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .code(_, let path, let lines, _, let symbol, _, _) = target, let graph,
              let node = graph.nodes.first(where: { $0.path == path && $0.qualifiedName == symbol }), let rect = rect(ofNode: node.id) else { return bounds }
        guard lines.start == lines.end, lines != node.lines, let index = node.excerpt?.firstIndex(where: { $0.line == lines.start }) else { return rect }
        let scale = layout.placement(in: graphBodySize).scale
        let top = rect.minY + scale * (DiagramLayout.padding + DiagramLayout.nameHeight + DiagramLayout.placeHeight + 4 + CGFloat(index) * DiagramLayout.excerptLineHeight)
        return CGRect(x: rect.minX, y: top, width: rect.width, height: scale * DiagramLayout.excerptLineHeight)
    }


    func update(_ object: CanvasObject) {
        let previous = self.object
        self.object = object
        if previous.zoom != object.zoom { cancelDetail() }
        if DiagramSpec(previous.props) != DiagramSpec(object.props) {
            refresh()
        } else if remote != nil, computing, object.rev != previous.rev {
            scheduleRefresh()
        }
        let graphKey = isGraph ? "knowledge" : "graph"
        guard previous.props["kind"] != object.props["kind"] || previous.props[graphKey] != object.props[graphKey] else { return }
        cancelDetail()
        hostFailure = nil
        switch computation {
        case .asking, .hostComputing: computation = .idle
        case .idle, .local: break
        }
        // An error before any node (a server still loading) isn't the first graph yet.
        let before = graph?.nodes.count ?? 0
        graph = DiagramGraph.stored(in: object.props)
        layout = graph.map(DiagramLayout.init) ?? DiagramLayout(DiagramGraph(aim: spec.aim))
        if let expandedNode, graph?.node(expandedNode) == nil { self.expandedNode = nil }
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
        let panelHeight = detailPanel(in: CGRect(origin: .zero, size: CGSize(width: layout.bodySize.width, height: layout.bodySize.height)))?.height ?? 0
        let body = CGSize(width: layout.bodySize.width, height: layout.bodySize.height + panelHeight)
        let current = RenderMath.body(of: object)
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
