import CoreGraphics
import Foundation

/// A board's objects as a value, with the arrow label sizes the drawing layer measured: the pure
/// geometry of arrow routes, label placement, and layout checks. Being a value, it computes off
/// the main actor (`layout.check` routes every arrow, each `avoid` route a grid search).
public struct BoardGeometry: Sendable {
    public let objects: [ObjectID: CanvasObject]
    /// Label chip sizes by arrow (`DrawingStyle.arrowLabel`, measured on the main actor);
    /// arrows without a caption have none.
    public let labelSizes: [ObjectID: CGSize]
    /// The routing drawn last (`Board.settledRouting`): routes nothing has touched since stay
    /// as drawn.
    public let settled: ConnectorRouter.Result?

    public init(objects: [ObjectID: CanvasObject], labelSizes: [ObjectID: CGSize], settled: ConnectorRouter.Result? = nil) {
        self.objects = objects
        self.labelSizes = labelSizes
        self.settled = settled
    }

    /// Whether arrows route around this object and count as crossing it: tiles, text, and filled
    /// shapes. Unfilled rects and ellipses are regions drawn around things; ink, arrows, and
    /// groups never block.
    public static func blocksRoutes(_ object: CanvasObject) -> Bool {
        switch object.type {
        case .terminal, .browser, .code, .note, .html, .changes, .image, .diagram, .question: return true
        case .shape:
            guard let spec = ShapeSpec(object.props) else { return false }
            return spec.kind == .text || (spec.kind != .ink && spec.fill != .none)
        case .arrow, .group: return false
        }
    }

    /// Members of a group, nested groups expanded, without the groups themselves.
    public static func leafMembers(of id: ObjectID, in objects: [ObjectID: CanvasObject]) -> [ObjectID] {
        var seen: Set<ObjectID> = [id]
        var result: [ObjectID] = []
        var queue = [id]
        while let next = queue.popLast() {
            guard let group = objects[next], let spec = GroupSpec(group.props) else { continue }
            for member in spec.members where !seen.contains(member) {
                seen.insert(member)
                guard let object = objects[member] else { continue }
                if object.type == .group { queue.append(member) } else { result.append(member) }
            }
        }
        return result
    }

    /// Every arrow's routed polyline from object frames alone (the app routes the same way from
    /// what it draws; see `routing`). `only` returns just those arrows (all are routed together).
    public func routes(rows: [ObjectID: CodeRows] = [:], only: Set<ObjectID>? = nil) -> [ObjectID: [CGPoint]] {
        let paths = routing(rows: rows).paths
        guard let only else { return paths }
        return paths.filter { only.contains($0.key) }
    }

    /// Every arrow's route and label placement, as drawn: straight and orthogonal arrows between
    /// the same two objects offset apart; `avoid` arrows routed together around blocking objects
    /// (`ConnectorRouter`: distinct ports, nudged tracks, the flow of their groups); an end bound
    /// to `lines` of a code tile at that line's row (`CodeMetrics.lineY`, freshly aimed; `rows`
    /// gives a tile's visual rows when known, else one row per line); captions (`labelSizes`)
    /// clear of tiles, group titles, other arrows, and each other where there is room. Routes
    /// that nothing has touched since `settled` keep their way.
    public func routing(rows: [ObjectID: CodeRows] = [:]) -> ConnectorRouter.Result {
        let arrows = objects.values.filter { $0.type == .arrow }.sorted { $0.id < $1.id }.compactMap { arrow in ArrowSpec(arrow.props).map { (arrow, $0) } }
        let offsets = DrawingGeometry.parallelOffsets(arrows.filter { $0.1.route != .avoid }.map { ($0.0.id, $0.1.from.objectID, $0.1.to.objectID) })
        var connectors: [ConnectorRouter.Connector] = []
        for (arrow, spec) in arrows {
            guard let from = arrowEnd(spec.from, rows: rows), let to = arrowEnd(spec.to, rows: rows) else { continue }
            let path = spec.route == .avoid ? nil : DrawingGeometry.path(from: from, to: to, style: spec.route, offset: offsets[arrow.id] ?? 0)
            connectors.append(.init(id: arrow.id, from: from, to: to, fromObject: spec.from.objectID, toObject: spec.to.objectID,
                                    label: labelSizes[arrow.id], path: path))
        }
        let obstacles = objects.values.filter(Self.blocksRoutes).sorted { $0.id < $1.id }.map { ConnectorRouter.Obstacle(id: $0.id, rect: $0.frame.rect) }
        return ConnectorRouter(connectors: connectors, obstacles: obstacles, regions: regions).route(previous: settled)
    }

    /// The board's groups as the router sees them: frame, leaf members, and `flow`.
    public var regions: [ConnectorRouter.Region] {
        objects.values.filter { $0.type == .group }.sorted { $0.id < $1.id }.compactMap { group in
            guard let spec = GroupSpec(group.props) else { return nil }
            return ConnectorRouter.Region(id: group.id, frame: group.frame.rect, members: Set(Self.leafMembers(of: group.id, in: objects)), flow: spec.flow)
        }
    }

    /// The groups as they are shown while objects are shown away from their frames (tiles held
    /// mid-drag, which commit on drop): a group holding such a member, nested groups included,
    /// takes the frame the drop will fit it to (`GroupSpec.frame(around:)`, as `Board`
    /// re-fits); every other group keeps its frame. So routing the board mid-drag sees the
    /// regions the drop commits, and the drop changes nothing more.
    public func regions(shown: [ObjectID: CGRect]) -> [ConnectorRouter.Region] {
        let moved = Set(shown.compactMap { id, rect in objects[id].map { $0.frame.rect != rect } == true ? id : nil })
        guard !moved.isEmpty else { return regions }
        var fitted: [ObjectID: CGRect?] = [:]
        func frame(ofGroup id: ObjectID, visiting: Set<ObjectID>) -> CGRect? {
            if let known = fitted[id] { return known }
            guard let group = objects[id], let spec = GroupSpec(group.props) else { return nil }
            let leaves = Self.leafMembers(of: id, in: objects)
            var result = group.frame.rect
            if leaves.contains(where: moved.contains) {
                let rects = spec.members.compactMap { member -> CGRect? in
                    guard member != id, !visiting.contains(member), let object = objects[member], object.type != .arrow else { return nil }
                    if object.type == .group { return frame(ofGroup: member, visiting: visiting.union([id])) }
                    return shown[member] ?? object.frame.rect
                }
                result = spec.frame(around: rects) ?? result
            }
            fitted[id] = result
            return result
        }
        return regions.map { region in
            var region = region
            region.frame = frame(ofGroup: region.id, visiting: []) ?? region.frame
            return region
        }
    }

    /// What a binding attaches to: a point, an object's frame (an ellipse's curve), the row of
    /// the first of `lines` on a code tile, or a diagram node's box. Nil when the object is gone.
    func arrowEnd(_ binding: ArrowBinding, rows: [ObjectID: CodeRows]) -> DrawingGeometry.ArrowEnd? {
        switch binding {
        case .point(let point): return .point(point)
        case .object(let id, let lines, _, let node):
            guard let object = objects[id] else { return nil }
            if let lines, object.type == .code {
                return .row(object.frame.rect, y: CodeMetrics.lineY(line: lines.start, frame: object.frame, props: object.props, rows: rows[id]))
            }
            if let node, object.type == .diagram, let rect = DiagramLayout.canvasRect(of: node, frame: object.frame, props: object.props) {
                return .bound(.rect(rect))
            }
            let isEllipse = object.type == .shape && ShapeSpec(object.props)?.kind == .ellipse
            return .bound(isEllipse ? .ellipse(object.frame.rect) : .rect(object.frame.rect))
        }
    }
}

extension Board {
    /// The objects as they are now, with their arrows' label sizes, for route and layout math
    /// off the main actor.
    public var geometry: BoardGeometry {
        var labelSizes: [ObjectID: CGSize] = [:]
        for object in objects.values where object.type == .arrow {
            guard let spec = ArrowSpec(object.props), let label = DrawingStyle.arrowLabel(spec) else { continue }
            labelSizes[object.id] = label.size
        }
        return BoardGeometry(objects: objects, labelSizes: labelSizes, settled: settledRouting?())
    }
}
