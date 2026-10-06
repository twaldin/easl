import CoreGraphics
import Foundation

/// Routes a board's `avoid` arrows together, after libavoid's orthogonal connector routing
/// (Wybrow, Marriott & Stuckey, "Orthogonal connector routing", GD 2009) and ELK's layered
/// edge routing, then places every arrow's label:
///
/// 1. **Sides.** Each arrow searches an orthogonal grid (tile edges ± `avoidMargin`, the midlines
///    of the channels between tiles, lines just outside groups, and port lines) from every side
///    of its source to every side of its target. Length, bends, running along a group border or
///    through a title band, and sides that don't face the flow all cost; the sides it lands on are
///    kept.
/// 2. **Ports.** Arrows sharing a side get distinct ports spread along it, ordered by where their
///    other ends lie so they don't cross at the side; a line-bound end keeps its row.
/// 3. **Routes.** Every arrow searches again between its ports, shortest first, paying for
///    crossing or sharing a grid edge with arrows already routed; then each is ripped up and
///    rerouted once against all the others.
/// 4. **Nudging.** Collinear segments of different arrows that overlap are spread into parallel
///    tracks `parallelSpacing` apart (closer in tight channels), ordered to cross least, kept clear
///    of tiles and off group borders and title bands.
/// 5. **Labels.** Each caption goes beside its own arrow's longest segment that no other arrow runs
///    along, clear of tiles, group titles, other arrows and other labels; else a short leader away.
///    Beside a bundle of parallel lines, a chip is led to its own stub, where its line runs alone.
///
/// A pure function of its input: the same board routes the same way, and a route whose
/// neighbourhood doesn't change stays put when something elsewhere moves.
public struct ConnectorRouter: Sendable {
    /// Which way a diagram reads (`GroupProps.flow`): arrows leave the side of their source that
    /// faces downstream and enter their target's upstream side where they can.
    public enum Flow: String, Sendable, CaseIterable {
        case right, down, left, up

        /// Outward heading of the downstream side: 0 right, 1 down, 2 left, 3 up.
        var heading: Int {
            switch self {
            case .right: 0
            case .down: 1
            case .left: 2
            case .up: 3
            }
        }
    }

    public struct Connector: Sendable {
        public var id: ObjectID
        public var from: DrawingGeometry.ArrowEnd
        public var to: DrawingGeometry.ArrowEnd
        /// Objects the ends are bound to: an arrow's own ends are never in its way.
        public var fromObject: ObjectID?
        public var toObject: ObjectID?
        /// The caption chip's size; nil without a caption.
        public var label: CGSize?
        /// A route drawn as given (a straight or orthogonal arrow): routed arrows keep off it and
        /// its label is placed with the rest. Nil routes it here.
        public var path: [CGPoint]?

        public init(id: ObjectID, from: DrawingGeometry.ArrowEnd, to: DrawingGeometry.ArrowEnd, fromObject: ObjectID? = nil,
                    toObject: ObjectID? = nil, label: CGSize? = nil, path: [CGPoint]? = nil) {
            self.id = id
            self.from = from
            self.to = to
            self.fromObject = fromObject
            self.toObject = toObject
            self.label = label
            self.path = path
        }
    }

    /// Something arrows go around and labels keep off: a tile, text, or filled shape.
    public struct Obstacle: Sendable {
        public var id: ObjectID
        public var rect: CGRect

        public init(id: ObjectID, rect: CGRect) {
            self.id = id
            self.rect = rect
        }
    }

    /// A group: arrows cross its border but don't run along it, and keep off its title band.
    public struct Region: Sendable {
        public var id: ObjectID
        public var frame: CGRect
        /// Leaf members (nested groups expanded).
        public var members: Set<ObjectID>
        public var flow: Flow?

        public init(id: ObjectID, frame: CGRect, members: Set<ObjectID>, flow: Flow? = nil) {
            self.id = id
            self.frame = frame
            self.members = members
            self.flow = flow
        }

        /// The band holding the title (`GroupSpec.titleHeight`).
        public var title: CGRect {
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: min(frame.height, CGFloat(GroupSpec.titleHeight)))
        }
    }

    /// Where a caption's chip is drawn.
    public struct Label: Equatable, Sendable {
        public var rect: CGRect
        /// A line from the route to the chip when the chip sits away from the route; nil beside it.
        public var leader: [CGPoint]?

        public init(rect: CGRect, leader: [CGPoint]? = nil) {
            self.rect = rect
            self.leader = leader
        }
    }

    public struct Result: Sendable {
        public var paths: [ObjectID: [CGPoint]]
        public var labels: [ObjectID: Label]
        /// What these routes came from, so routing the board again keeps what nothing touched.
        var memo = Memo()
    }

    /// Each routed arrow's route before nudging, with what it was routed around.
    struct Memo: Sendable {
        var centerlines: [ObjectID: [CGPoint]] = [:]
        /// Each arrow's first route (pass 1), which ordered the ports on its sides.
        var sketches: [ObjectID: [CGPoint]] = [:]
        var ends: [ObjectID: [DrawingGeometry.ArrowEnd]] = [:]
        var flows: [ObjectID: Flow] = [:]
        var obstacles: [ObjectID: CGRect] = [:]
        var regions: [ObjectID: CGRect] = [:]
        /// Each labelled arrow's caption size, for keeping its label (`keptLabels`).
        var labelSizes: [ObjectID: CGSize] = [:]
    }

    public var connectors: [Connector]
    public var obstacles: [Obstacle]
    public var regions: [Region]
    /// The flow of arrows no region's `flow` covers; nil infers it from the arrows between groups.
    public var flow: Flow?

    public init(connectors: [Connector], obstacles: [Obstacle], regions: [Region] = [], flow: Flow? = nil) {
        self.connectors = connectors
        self.obstacles = obstacles
        self.regions = regions
        self.flow = flow
    }

    // MARK: Tuning

    static let bendCost: CGFloat = 60
    /// Per crossing of an arrow already routed.
    static let crossCost: CGFloat = 50
    /// Per point of length run on a grid edge another arrow already uses: none, since nudging
    /// spreads shared runs into parallel tracks, and arrows bundled in one channel read best.
    static let shareCost: CGFloat = 0
    /// Extra per point of length run right along a tile's margin rather than mid-channel.
    static let hugCost: CGFloat = 0.3
    /// Per point of length and arrow already there, in a gap only one track wide (tiles' margins
    /// meeting on both sides), where nudging can't spread arrows apart.
    static let narrowShareCost: CGFloat = 2
    /// Extra per point of length run within `borderBand` of a group border, or through a title band.
    static let borderCost: CGFloat = 1.5
    static let titleCost: CGFloat = 2
    static let borderBand: CGFloat = 6
    /// A side that faces the other end but not downstream, when the downstream one does: about
    /// two bends, so a diagram reads with its flow unless that costs a detour.
    static let offFlowCost: CGFloat = 150
    /// The less separated of two facing sides.
    static let offAxisCost: CGFloat = 20
    /// A side facing neither toward nor away from the other end (leaving sideways, around
    /// what lies between).
    static let sideExitCost: CGFloat = 100
    /// A side facing away from the other end.
    static let uTurnCost: CGFloat = 240
    /// Nudged tracks keep this clear of tiles…
    static let trackClearance: CGFloat = 10
    /// …and this clear of group borders and title bands where the channel allows.
    static let borderClearance: CGFloat = 8
    /// Grid lines run this far outside every group.
    static let regionClearance: CGFloat = 12
    /// Shortest first or last segment a nudge leaves, so arrowheads and tails stay visible.
    static let minStub: CGFloat = 10
    /// How far beyond its ends an arrow's first search looks before searching the whole board.
    static let searchReach: CGFloat = 480
    /// Leader lengths tried when a label fits nowhere beside its route.
    static let leaderReaches: [CGFloat] = [24, 44, 72, 96, 120, 160]
    /// A label spot's cost for a leader (so a spot right by its line with another line close by
    /// wins over one away from it), one more for a leader longer than `shortLeader` that
    /// isn't a tether, and for each other arrow's line under the chip (a spot is acceptable
    /// below it).
    static let leaderCost = 2
    static let shortLeader: CGFloat = 72
    static let underCost = 5
    /// A spot beside a stretch other arrows run alongside, or a leader from one: the chip reads
    /// as naming the whole bundle, so a spot on its own line, by its stub where it still runs
    /// alone, or tethered to that stub wins.
    static let bundleCost = 3
    /// A label spot's cost for each tile, title band, or label it covers.
    static let coverCost = 12

    // MARK: Routing

    /// Routes and labels every connector. With `previous` (this board's last routing), an arrow
    /// whose ends, flow, and surroundings haven't changed keeps its route (so moving a tile never
    /// reshuffles routes it doesn't touch): only arrows that are new, whose ends moved, whose route
    /// runs within `avoidMargin` of a tile or group border that came, went, or moved, or that
    /// share a side with one of those route again, around the rest. Tracks are placed afresh, so
    /// they follow; a label stays where it was when its arrow's line and caption are unchanged and
    /// nothing changed near the label (`keptLabels`), and the rest are placed around those.
    public func route(previous: Result? = nil) -> Result {
        var routes = connectors.map { $0.path ?? [] }
        var movable = [Bool](repeating: false, count: connectors.count)
        let pending = connectors.indices.filter { connectors[$0].path == nil }.sorted { connectors[$0].id < connectors[$1].id }
        let flows = self.flows(pending)
        var memo = Memo()
        for obstacle in obstacles { memo.obstacles[obstacle.id] = obstacle.rect }
        for region in regions { memo.regions[region.id] = region.frame }
        for connector in connectors { if let size = connector.label { memo.labelSizes[connector.id] = size } }
        if !pending.isEmpty {
            var planner = Planner(router: self)
            for (index, path) in planner.solve(pending, flows: flows, keep: kept(pending, flows: flows, previous: previous?.memo)) {
                let connector = connectors[index]
                routes[index] = path.points
                movable[index] = path.nudges
                memo.centerlines[connector.id] = path.points
                memo.sketches[connector.id] = path.sketch ?? path.points
                memo.ends[connector.id] = [connector.from, connector.to]
                memo.flows[connector.id] = flows[index]
            }
        }
        let rects = obstacles.map(\.rect)
        let soft = softLines()
        let titles = regions.map(\.title)
        let centered = routes
        func settle(_ routes: inout [[CGPoint]], around chips: [CGRect]) -> [ObjectID: Label] {
            Self.nudge(&routes, movable: movable, obstacles: rects + chips, soft: soft, vertical: true)
            Self.nudge(&routes, movable: movable, obstacles: rects + chips, soft: soft, vertical: false)
            for index in routes.indices where movable[index] { routes[index] = DrawingGeometry.simplified(routes[index]) }
            return Self.placeLabels(connectors: connectors, routes: routes, obstacles: rects, titles: titles, groups: regions.map(\.frame),
                                    keep: keptLabels(routes: routes, previous: previous))
        }
        var labels = settle(&routes, around: [])
        // A label left on another arrow's line: nudge that line's track clear of the chip, and
        // keep the result when it leaves fewer labels on lines, tiles, or titles.
        let clashing = clashes(labels, routes: routes, obstacles: rects + titles)
        if !clashing.isEmpty {
            var retry = centered
            let chips = clashing.map { (owner: $0, rect: labels[connectors[$0].id]!.rect) }
            for chip in chips { Self.clear(&retry, of: chip.rect, owner: chip.owner, movable: movable, obstacles: rects) }
            let relabelled = settle(&retry, around: chips.map(\.rect))
            if clashes(relabelled, routes: retry, obstacles: rects + titles).count < clashing.count,
               !zip(routes.indices, retry).contains(where: { index, route in movable[index] && rects.contains { DrawingGeometry.path(route, crosses: $0) } && !rects.contains { DrawingGeometry.path(routes[index], crosses: $0) } }) {
                routes = retry
                labels = relabelled
            }
        }
        var paths: [ObjectID: [CGPoint]] = [:]
        for (index, connector) in connectors.enumerated() where routes[index].count >= 2 { paths[connector.id] = routes[index] }
        return Result(paths: paths, labels: labels, memo: memo)
    }

    /// How far from a label a change makes it be placed again.
    static let labelReach: CGFloat = 24

    /// The labels of `previous` that stand: the arrow's line is the same as then, its caption the
    /// same size, and no line, tile, title band or group border came, went or moved within
    /// `labelReach` of the chip or its leader. Keyed by connector index.
    func keptLabels(routes: [[CGPoint]], previous: Result?) -> [Int: Label] {
        guard let previous, !previous.labels.isEmpty else { return [:] }
        let memo = previous.memo
        // Everything that changed, as boxes: segments only one routing has, obstacles and group
        // frames (with their title bands) that moved, came or went.
        var changed: [CGRect] = []
        func box(_ a: CGPoint, _ b: CGPoint) -> CGRect { CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)) }
        func segments(_ route: [CGPoint]) -> Set<[CGFloat]> { Set(zip(route, route.dropFirst()).map { [$0.x, $0.y, $1.x, $1.y] }) }
        var current: [ObjectID: [CGPoint]] = [:]
        for (index, connector) in connectors.enumerated() where routes[index].count >= 2 { current[connector.id] = routes[index] }
        for id in Set(current.keys).union(previous.paths.keys) {
            let now = current[id] ?? [], before = previous.paths[id] ?? []
            guard now != before else { continue }
            let a = segments(now), b = segments(before)
            for s in a.symmetricDifference(b) { changed.append(box(CGPoint(x: s[0], y: s[1]), CGPoint(x: s[2], y: s[3]))) }
        }
        var obstacleNow: [ObjectID: CGRect] = [:]
        for obstacle in obstacles { obstacleNow[obstacle.id] = obstacle.rect }
        for id in Set(obstacleNow.keys).union(memo.obstacles.keys) where obstacleNow[id] != memo.obstacles[id] {
            changed += [obstacleNow[id], memo.obstacles[id]].compactMap { $0 }
        }
        var regionNow: [ObjectID: CGRect] = [:]
        for region in regions { regionNow[region.id] = region.frame }
        for id in Set(regionNow.keys).union(memo.regions.keys) where regionNow[id] != memo.regions[id] {
            changed += [regionNow[id], memo.regions[id]].compactMap { $0 }
        }
        var kept: [Int: Label] = [:]
        for (index, connector) in connectors.enumerated() {
            guard let size = connector.label, let label = previous.labels[connector.id], memo.labelSizes[connector.id] == size,
                  routes[index].count >= 2, previous.paths[connector.id] == routes[index] else { continue }
            var area = label.rect
            if let leader = label.leader { for point in leader { area = area.union(CGRect(origin: point, size: .zero)) } }
            area = area.insetBy(dx: -Self.labelReach, dy: -Self.labelReach)
            if changed.contains(where: { $0.insetBy(dx: -0.5, dy: -0.5).intersects(area) }) { continue }
            kept[index] = label
        }
        return kept
    }

    /// Connectors whose label lies on another arrow's line, or on a tile or title.
    func clashes(_ labels: [ObjectID: Label], routes: [[CGPoint]], obstacles: [CGRect]) -> [Int] {
        connectors.indices.filter { index in
            guard let label = labels[connectors[index].id] else { return false }
            let inner = label.rect.insetBy(dx: 0.5, dy: 0.5)
            if obstacles.contains(where: { $0.intersects(inner) }) { return true }
            return routes.indices.contains { other in
                other != index && zip(routes[other], routes[other].dropFirst()).contains { DrawingGeometry.segment($0, $1, intersects: inner) }
            }
        }
    }

    /// Moves the inner segments of other arrows that run through `chip` to the roomier side of
    /// it, between it and the nearest tile, so nudging (with the chip as an obstacle) keeps them
    /// there.
    static func clear(_ routes: inout [[CGPoint]], of chip: CGRect, owner: Int, movable: [Bool], obstacles: [CGRect]) {
        for r in routes.indices where r != owner && movable[r] && routes[r].count >= 4 {
            var points = routes[r]
            for i in 1..<(points.count - 2) {
                let a = points[i], b = points[i + 1]
                guard DrawingGeometry.segment(a, b, intersects: chip) else { continue }
                let vertical = abs(a.x - b.x) < 0.01
                let (c0, c1) = vertical ? (chip.minX, chip.maxX) : (chip.minY, chip.maxY)
                let (e0, e1) = vertical ? (min(a.y, b.y), max(a.y, b.y)) : (min(a.x, b.x), max(a.x, b.x))
                var below = c0 - searchReach
                var above = c1 + searchReach
                for rect in obstacles {
                    let (r0, r1, s0, s1) = vertical ? (rect.minX, rect.maxX, rect.minY, rect.maxY) : (rect.minY, rect.maxY, rect.minX, rect.maxX)
                    guard s0 < e1, s1 > e0 else { continue }
                    if r1 <= c0 { below = max(below, r1) } else if r0 >= c1 { above = min(above, r0) }
                }
                let target = c0 - below >= above - c1 ? (below + c0) / 2 : (c1 + above) / 2
                if vertical { points[i].x = target; points[i + 1].x = target } else { points[i].y = target; points[i + 1].y = target }
            }
            routes[r] = points
        }
    }

    /// The previous routes (before nudging) of `pending` arrows nothing has touched since.
    func kept(_ pending: [Int], flows: [Int: Flow], previous: Memo?) -> [Int: (route: [CGPoint], sketch: [CGPoint])] {
        guard let previous else { return [:] }
        var changed: [CGRect] = []
        var current: [ObjectID: CGRect] = [:]
        for obstacle in obstacles { current[obstacle.id] = obstacle.rect }
        for (id, rect) in previous.obstacles where current[id] != rect { changed.append(rect) }
        for (id, rect) in current where previous.obstacles[id] != rect { changed.append(rect) }
        var frames: [ObjectID: CGRect] = [:]
        for region in regions { frames[region.id] = region.frame }
        var moved: [CGRect] = []
        for (id, frame) in previous.regions where frames[id] != frame { moved.append(frame) }
        for (id, frame) in frames where previous.regions[id] != frame { moved.append(frame) }
        let reach = DrawingGeometry.avoidMargin + 2
        var areas = changed.map { $0.insetBy(dx: -reach, dy: -reach) }
        for frame in moved {
            // Only a group's border and title band change costs.
            let band = Self.borderBand + reach
            areas += [CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: CGFloat(GroupSpec.titleHeight)).insetBy(dx: -band, dy: -band),
                      CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: 0).insetBy(dx: -band, dy: -band),
                      CGRect(x: frame.minX, y: frame.minY, width: 0, height: frame.height).insetBy(dx: -band, dy: -band),
                      CGRect(x: frame.maxX, y: frame.minY, width: 0, height: frame.height).insetBy(dx: -band, dy: -band)]
        }
        var result: [Int: (route: [CGPoint], sketch: [CGPoint])] = [:]
        for index in pending {
            let connector = connectors[index]
            guard let route = previous.centerlines[connector.id], route.count >= 2, previous.ends[connector.id] == [connector.from, connector.to],
                  previous.flows[connector.id] == flows[index], !areas.contains(where: { DrawingGeometry.path(route, crosses: $0) }) else { continue }
            result[index] = (route, previous.sketches[connector.id] ?? route)
        }
        return result
    }

    /// Borders and title bands nudged tracks keep off: `vertical` ones bound vertical segments.
    func softLines() -> [(rect: CGRect, vertical: Bool)] {
        var lines: [(rect: CGRect, vertical: Bool)] = []
        for region in regions {
            let f = region.frame
            lines.append((CGRect(x: f.minX, y: f.minY, width: 0, height: f.height), true))
            lines.append((CGRect(x: f.maxX, y: f.minY, width: 0, height: f.height), true))
            lines.append((CGRect(x: f.minX, y: f.maxY, width: f.width, height: 0), false))
            lines.append((region.title, false))
        }
        return lines
    }

    /// The flow each arrow follows: the innermost group holding both ends that sets one, else
    /// the innermost holding its source, else the board's (`flow`, else the way arrows between
    /// groups mostly point).
    func flows(_ indices: [Int]) -> [Int: Flow] {
        let byArea = regions.sorted { ($0.frame.width * $0.frame.height, $0.id) < ($1.frame.width * $1.frame.height, $1.id) }
        func innermost(_ id: ObjectID?) -> Region? {
            guard let id else { return nil }
            return byArea.first { $0.members.contains(id) }
        }
        let board = flow ?? {
            var sx: CGFloat = 0
            var sy: CGFloat = 0
            for across in [true, false] where sx == 0 && sy == 0 {
                for connector in connectors {
                    guard let a = connector.fromObject, let b = connector.toObject, a != b else { continue }
                    if across, regions.isEmpty || innermost(a)?.id == innermost(b)?.id { continue }
                    sx += connector.to.aim.midX - connector.from.aim.midX
                    sy += connector.to.aim.midY - connector.from.aim.midY
                }
            }
            if abs(sx) >= abs(sy) { return sx >= 0 ? .right : .left }
            return sy >= 0 ? .down : .up
        }()
        var result: [Int: Flow] = [:]
        for index in indices {
            let connector = connectors[index]
            let both = byArea.first { region in
                region.flow != nil && [connector.fromObject, connector.toObject].allSatisfy { $0.map(region.members.contains) ?? false }
            }
            let source = byArea.first { region in region.flow != nil && (connector.fromObject.map(region.members.contains) ?? false) }
            result[index] = both?.flow ?? source?.flow ?? board
        }
        return result
    }

    // MARK: Ports

    struct Port {
        /// On the outline (plus the arrow gap), where the arrow starts or ends.
        var point: CGPoint
        /// `avoidMargin` out from the outline: where the grid search starts or ends.
        var stub: CGPoint
        /// Outward: 0 right, 1 down, 2 left, 3 up.
        var heading: Int
        /// Added to a route that uses it (a side against the flow).
        var cost: CGFloat = 0
    }

    /// The port on `end`'s side `heading`, `along` it (nil: lined up with `other` where their
    /// extents overlap, else the side's middle). A row end has only its left and right ports at
    /// its row; a free point is its own port every way.
    static func port(_ end: DrawingGeometry.ArrowEnd, heading: Int, along: CGFloat?, toward other: CGRect) -> Port? {
        let margin = DrawingGeometry.avoidMargin
        let gap = DrawingGeometry.arrowGap
        switch end {
        case .point(let point):
            return Port(point: point, stub: point, heading: heading)
        case .row(let rect, let y):
            guard heading % 2 == 0 else { return nil }
            let right = heading == 0
            return Port(point: CGPoint(x: right ? rect.maxX + gap : rect.minX - gap, y: y),
                        stub: CGPoint(x: right ? rect.maxX + margin : rect.minX - margin, y: y), heading: heading)
        case .bound(let outline):
            let rect = outline.bounds
            let horizontal = heading % 2 == 0
            let sign: CGFloat = heading < 2 ? 1 : -1
            let position: CGFloat
            if horizontal {
                position = DrawingGeometry.clamp(along ?? DrawingGeometry.overlap(rect.minY, rect.maxY, other.minY, other.maxY) ?? rect.midY, rect.minY + 4, rect.maxY - 4)
            } else {
                position = DrawingGeometry.clamp(along ?? DrawingGeometry.overlap(rect.minX, rect.maxX, other.minX, other.maxX) ?? rect.midX, rect.minX + 4, rect.maxX - 4)
            }
            let origin = horizontal ? CGPoint(x: rect.midX, y: position) : CGPoint(x: position, y: rect.midY)
            let direction = horizontal ? CGPoint(x: sign, y: 0) : CGPoint(x: 0, y: sign)
            let edge = DrawingGeometry.boundary(outline, from: origin, direction: direction)
            let point = CGPoint(x: edge.x + direction.x * gap, y: edge.y + direction.y * gap)
            let stub = horizontal ? CGPoint(x: sign > 0 ? rect.maxX + margin : rect.minX - margin, y: position)
                : CGPoint(x: position, y: sign > 0 ? rect.maxY + margin : rect.minY - margin)
            return Port(point: point, stub: stub, heading: heading)
        }
    }

    /// What leaving (`source`) or entering an end by side `heading` costs: nothing for a side
    /// facing the other end along the flow (or, when the ends aren't in flow order, facing it
    /// across the wider gap); a little for another facing side; more for a side facing across,
    /// and a lot for a side facing away (a U-turn), when some side faces the other end at all.
    static func sideCost(_ heading: Int, box: CGRect?, other: CGRect, flow: Flow, source: Bool) -> CGFloat {
        guard let box else { return 0 }
        let gaps = [other.minX - box.maxX, other.minY - box.maxY, box.minX - other.maxX, box.minY - other.maxY]
        guard gaps.contains(where: { $0 > 0 }) else { return 0 }
        guard gaps[heading] > 0 else { return gaps[(heading + 2) % 4] > 0 ? uTurnCost : sideExitCost }
        let preferred = source ? flow.heading : (flow.heading + 2) % 4
        if gaps[preferred] > 0 { return heading == preferred ? 0 : offFlowCost }
        let widest = (0..<4).filter { gaps[$0] > 0 }.max { (gaps[$0], -$0) < (gaps[$1], -$1) } ?? heading
        return heading == widest ? 0 : offAxisCost
    }

    // MARK: Planner

    struct Planned {
        var points: [CGPoint]
        /// The first route (pass 1), which ordered its ports; nil for a fallback.
        var sketch: [CGPoint]? = nil
        /// Found by the search (interior segments may nudge), not a fallback.
        var nudges: Bool
    }

    /// Passes 1–3: sides, ports, and routes of the arrows routed here.
    struct Planner {
        let router: ConnectorRouter
        let margin = DrawingGeometry.avoidMargin

        struct Prepared {
            var index: Int
            var from: DrawingGeometry.ArrowEnd
            var to: DrawingGeometry.ArrowEnd
            var flow: Flow
            /// Inflated obstacles this arrow may pass through (holding one of its ends).
            var exempt: [CGRect]
            /// Inflated end boxes that aren't obstacles (a group, an unfilled shape).
            var extra: [CGRect]
        }

        init(router: ConnectorRouter) {
            self.router = router
        }

        func prepare(_ index: Int, flow: Flow) -> Prepared {
            let connector = router.connectors[index]
            let ends: Set<ObjectID> = Set([connector.fromObject, connector.toObject].compactMap { $0 })
            let boxes = [connector.from.box, connector.to.box].compactMap { $0 }
            let centers = [connector.from.aim, connector.to.aim].map { CGPoint(x: $0.midX, y: $0.midY) }
            var exempt: [CGRect] = []
            for obstacle in router.obstacles where !ends.contains(obstacle.id) {
                let rect = obstacle.rect
                if centers.contains(where: { rect.contains($0) }) || boxes.contains(where: { $0.contains(rect) }) {
                    exempt.append(rect.insetBy(dx: -margin, dy: -margin))
                }
            }
            let obstacleIDs = Set(router.obstacles.map(\.id))
            var extra: [CGRect] = []
            for (object, box) in [(connector.fromObject, connector.from.box), (connector.toObject, connector.to.box)] {
                guard let box, object.map({ !obstacleIDs.contains($0) }) ?? true else { continue }
                extra.append(box.insetBy(dx: -margin, dy: -margin))
            }
            return Prepared(index: index, from: connector.from, to: connector.to, flow: flow, exempt: exempt, extra: extra)
        }

        /// Grid lines every search shares: inflated obstacle edges, channel midlines, lines
        /// just outside groups, and the edges of non-obstacle end boxes.
        func baseLines(_ prepared: [Prepared]) -> (xs: [CGFloat], ys: [CGFloat], blocks: [CGRect]) {
            var xs: [CGFloat] = []
            var ys: [CGFloat] = []
            let rects = router.obstacles.map(\.rect)
            let blocks = rects.map { $0.insetBy(dx: -margin, dy: -margin) }
            for block in blocks {
                xs += [block.minX, block.maxX]
                ys += [block.minY, block.maxY]
            }
            func midlines(_ boxes: [CGRect], minimum: CGFloat) {
                for a in boxes {
                    var right: CGFloat = .infinity
                    var below: CGFloat = .infinity
                    for b in boxes {
                        if b.minX >= a.maxX, b.minY < a.maxY, b.maxY > a.minY { right = min(right, b.minX) }
                        if b.minY >= a.maxY, b.minX < a.maxX, b.maxX > a.minX { below = min(below, b.minY) }
                    }
                    if right.isFinite, right - a.maxX > minimum { xs.append((a.maxX + right) / 2) }
                    if below.isFinite, below - a.maxY > minimum { ys.append((a.maxY + below) / 2) }
                }
            }
            midlines(rects, minimum: 2 * margin)
            let frames = router.regions.map(\.frame)
            midlines(frames, minimum: 2 * ConnectorRouter.regionClearance)
            for frame in frames {
                let c = ConnectorRouter.regionClearance
                xs += [frame.minX - c, frame.maxX + c]
                ys += [frame.minY - c, frame.maxY + c]
            }
            for item in prepared {
                for box in item.extra {
                    xs += [box.minX, box.maxX]
                    ys += [box.minY, box.maxY]
                }
                for end in [item.from, item.to] {
                    switch end {
                    case .point(let point):
                        xs.append(point.x)
                        ys.append(point.y)
                    case .row(let rect, let y):
                        xs += [rect.minX - margin, rect.maxX + margin]
                        ys.append(y)
                    case .bound: break
                    }
                }
            }
            return (xs, ys, blocks)
        }

        func candidates(_ item: Prepared, source: Bool) -> [Port] {
            let end = source ? item.from : item.to
            let other = source ? item.to.aim : item.from.aim
            return (0..<4).compactMap { heading in
                guard var port = ConnectorRouter.port(end, heading: heading, along: nil, toward: other) else { return nil }
                port.cost = ConnectorRouter.sideCost(heading, box: end.box, other: other, flow: item.flow, source: source)
                return port
            }
        }

        func query(_ item: Prepared, grid: Grid, starts: [Port], goals: [Port], congestion: Bool, whole: Bool) -> Grid.Query {
            var window = (i0: 0, i1: grid.nx - 1, j0: 0, j1: grid.ny - 1)
            if !whole {
                let reach = item.from.aim.union(item.to.aim).insetBy(dx: -ConnectorRouter.searchReach, dy: -ConnectorRouter.searchReach)
                window = (grid.lower(grid.xs, reach.minX), max(0, grid.upper(grid.xs, reach.maxX) - 1),
                          grid.lower(grid.ys, reach.minY), max(0, grid.upper(grid.ys, reach.maxY) - 1))
            }
            return Grid.Query(starts: starts, goals: goals, window: window, exempt: item.exempt, extra: item.extra, congestion: congestion)
        }

        func search(_ item: Prepared, grid: Grid, starts: [Port], goals: [Port], congestion: Bool) -> Grid.Found? {
            grid.search(query(item, grid: grid, starts: starts, goals: goals, congestion: congestion, whole: false))
                ?? grid.search(query(item, grid: grid, starts: starts, goals: goals, congestion: congestion, whole: true))
        }

        /// Routes `indices`: those in `keep` keep their routes (unless a side they share gets new
        /// ports), the rest go through passes 1–3 around them.
        mutating func solve(_ indices: [Int], flows: [Int: Flow], keep: [Int: (route: [CGPoint], sketch: [CGPoint])]) -> [Int: Planned] {
            let prepared = indices.map { prepare($0, flow: flows[$0] ?? .right) }
            let base = baseLines(prepared)
            var result: [Int: Planned] = [:]

            // Kept routes' ports, read off their first and last segments.
            var chosen: [Int: (start: Port, goal: Port, path: [CGPoint])] = [:]
            for item in prepared {
                guard let route = keep[item.index]?.route, let start = derivedPort(item, route, source: true),
                      let goal = derivedPort(item, route.reversed(), source: false) else { continue }
                chosen[item.index] = (start, goal, keep[item.index]!.sketch)
            }
            var kept = Set(chosen.keys)

            // Pass 1: every side of both ends, each arrow alone.
            var candidates: [Int: (starts: [Port], goals: [Port])] = [:]
            for item in prepared {
                candidates[item.index] = (self.candidates(item, source: true), self.candidates(item, source: false))
            }
            let fresh = prepared.filter { !kept.contains($0.index) }
            if !fresh.isEmpty {
                var xs1 = base.xs
                var ys1 = base.ys
                for item in fresh {
                    for port in candidates[item.index]!.starts + candidates[item.index]!.goals {
                        xs1 += [port.stub.x, port.point.x]
                        ys1 += [port.stub.y, port.point.y]
                    }
                }
                guard let grid1 = Grid(xs: xs1, ys: ys1, blocks: base.blocks, regions: router.regions) else { return fallback(prepared) }
                for item in fresh {
                    let ends = candidates[item.index]!
                    guard let found = search(item, grid: grid1, starts: ends.starts, goals: ends.goals, congestion: false) else { continue }
                    chosen[item.index] = (found.start, found.goal, grid1.points(found))
                }
            }

            // Ports: arrows sharing a side spread along it; a kept route whose port moves routes
            // again.
            let assigned = assignPorts(prepared, chosen: chosen)
            for index in kept {
                guard let ports = assigned[index], let pick = chosen[index] else { continue }
                if ports.start.heading != pick.start.heading || ports.goal.heading != pick.goal.heading
                    || hypot(ports.start.point.x - pick.start.point.x, ports.start.point.y - pick.start.point.y) > 0.5
                    || hypot(ports.goal.point.x - pick.goal.point.x, ports.goal.point.y - pick.goal.point.y) > 0.5 {
                    kept.remove(index)
                }
            }

            // Passes 2 and 3: between the ports, around kept routes and the arrows routed so
            // far, then each rerouted against all the others.
            var xs2 = base.xs
            var ys2 = base.ys
            for ports in assigned.values {
                for port in [ports.start, ports.goal] {
                    xs2 += [port.stub.x, port.point.x]
                    ys2 += [port.stub.y, port.point.y]
                }
            }
            for item in prepared where !kept.contains(item.index) {
                let ends = candidates[item.index]!
                for port in ends.starts + ends.goals {
                    xs2 += [port.stub.x, port.point.x]
                    ys2 += [port.stub.y, port.point.y]
                }
            }
            for index in kept {
                xs2 += keep[index]!.route.map(\.x)
                ys2 += keep[index]!.route.map(\.y)
            }
            guard let grid = Grid(xs: xs2, ys: ys2, blocks: base.blocks, regions: router.regions) else {
                for item in prepared {
                    result[item.index] = chosen[item.index].map { Planned(points: $0.path, sketch: $0.path, nudges: true) } ?? fallbackPath(item)
                }
                return result
            }
            for index in kept.sorted() {
                if let nodes = grid.nodes(along: keep[index]!.route) { grid.use(nodes, 1) }
            }
            let order = prepared.filter { assigned[$0.index] != nil && !kept.contains($0.index) }.sorted { a, b in
                let pa = assigned[a.index]!, pb = assigned[b.index]!
                let la = abs(pa.start.point.x - pa.goal.point.x) + abs(pa.start.point.y - pa.goal.point.y)
                let lb = abs(pb.start.point.x - pb.goal.point.x) + abs(pb.start.point.y - pb.goal.point.y)
                return (la, router.connectors[a.index].id) < (lb, router.connectors[b.index].id)
            }
            var found: [Int: Grid.Found] = [:]
            func routeOne(_ item: Prepared) -> Grid.Found? {
                let ports = assigned[item.index]!
                if let path = search(item, grid: grid, starts: [ports.start], goals: [ports.goal], congestion: true) { return path }
                let ends = candidates[item.index]!
                return search(item, grid: grid, starts: ends.starts, goals: ends.goals, congestion: true)
            }
            for item in order {
                guard let path = routeOne(item) else { continue }
                grid.use(path.nodes, 1)
                found[item.index] = path
            }
            for item in order {
                guard let old = found[item.index] else { continue }
                grid.use(old.nodes, -1)
                let path = routeOne(item) ?? old
                grid.use(path.nodes, 1)
                found[item.index] = path
            }
            for item in prepared {
                let sketch = chosen[item.index]?.path
                if kept.contains(item.index) {
                    result[item.index] = Planned(points: keep[item.index]!.route, sketch: sketch, nudges: true)
                } else if let path = found[item.index] {
                    result[item.index] = Planned(points: grid.points(path), sketch: sketch, nudges: true)
                } else if let first = chosen[item.index] {
                    result[item.index] = Planned(points: first.path, sketch: sketch, nudges: true)
                } else {
                    result[item.index] = fallbackPath(item)
                }
            }
            return result
        }

        /// The port a kept route leaves `item`'s source by (`source`), or enters its target by
        /// (`route` reversed), read off its first segment.
        func derivedPort(_ item: Prepared, _ route: [CGPoint], source: Bool) -> Port? {
            guard route.count >= 2 else { return nil }
            let a = route[0], b = route[1]
            let heading = abs(b.x - a.x) >= abs(b.y - a.y) ? (b.x > a.x ? 0 : 2) : (b.y > a.y ? 1 : 3)
            let end = source ? item.from : item.to
            let other = source ? item.to.aim : item.from.aim
            guard var port = ConnectorRouter.port(end, heading: heading, along: heading % 2 == 0 ? a.y : a.x, toward: other) else { return nil }
            port.cost = ConnectorRouter.sideCost(heading, box: end.box, other: other, flow: item.flow, source: source)
            return port
        }

        func fallbackPath(_ item: Prepared) -> Planned {
            Planned(points: DrawingGeometry.orthogonal(from: item.from, to: item.to, offset: 0, gap: DrawingGeometry.arrowGap), nudges: false)
        }

        func fallback(_ prepared: [Prepared]) -> [Int: Planned] {
            var result: [Int: Planned] = [:]
            for item in prepared { result[item.index] = fallbackPath(item) }
            return result
        }

        struct SideKey: Hashable {
            var object: ObjectID
            var heading: Int
        }

        /// Each arrow's two ports: a side one arrow uses keeps its lined-up port; a side several
        /// share spreads them `parallelSpacing` apart (closer on a short side) around its middle,
        /// in the order in which their first routes head along it (so they don't cross leaving
        /// it). Rows and free points keep theirs.
        func assignPorts(_ prepared: [Prepared], chosen: [Int: (start: Port, goal: Port, path: [CGPoint])]) -> [Int: (start: Port, goal: Port)] {
            var assigned: [Int: (start: Port, goal: Port)] = [:]
            struct Member {
                var index: Int
                var source: Bool
                var key: CGFloat
                var tie: CGFloat
                var id: ObjectID
            }
            var sides: [SideKey: [Member]] = [:]
            var prepares: [Int: Prepared] = [:]
            for item in prepared {
                prepares[item.index] = item
                guard let pick = chosen[item.index] else { continue }
                assigned[item.index] = (pick.start, pick.goal)
                let connector = router.connectors[item.index]
                for (source, end, other, object, port) in [(true, item.from, item.to.aim, connector.fromObject, pick.start),
                                                           (false, item.to, item.from.aim, connector.toObject, pick.goal)] {
                    guard case .bound = end, let object else { continue }
                    let alongY = port.heading % 2 == 0
                    // Where the route heads along the side once it has left it: the end of its
                    // second segment, else its far end.
                    let path = source ? pick.path : pick.path.reversed()
                    let heading = path.count > 2 ? path[2] : path[path.count - 1]
                    sides[SideKey(object: object, heading: port.heading), default: []]
                        .append(Member(index: item.index, source: source, key: alongY ? heading.y : heading.x, tie: alongY ? other.midY : other.midX, id: connector.id))
                }
            }
            for (side, members) in sides where members.count > 1 {
                let ordered = members.sorted { ($0.key, $0.tie, $0.id, $0.source ? 0 : 1) < ($1.key, $1.tie, $1.id, $1.source ? 0 : 1) }
                guard let first = prepares[ordered[0].index] else { continue }
                let end = ordered[0].source ? first.from : first.to
                guard let box = end.box else { continue }
                let alongY = side.heading % 2 == 0
                let low = alongY ? box.minY : box.minX
                let high = alongY ? box.maxY : box.maxX
                let length = high - low
                let pad = min(16, length / 4)
                let spacing = min(DrawingGeometry.parallelSpacing, (length - 2 * pad) / CGFloat(ordered.count - 1))
                let middle = (low + high) / 2
                for (rank, member) in ordered.enumerated() {
                    guard let item = prepares[member.index], let pick = assigned[member.index] else { continue }
                    let along = middle + (CGFloat(rank) - CGFloat(ordered.count - 1) / 2) * spacing
                    let end = member.source ? item.from : item.to
                    let other = member.source ? item.to.aim : item.from.aim
                    guard var port = ConnectorRouter.port(end, heading: side.heading, along: along, toward: other) else { continue }
                    port.cost = member.source ? pick.start.cost : pick.goal.cost
                    assigned[member.index] = member.source ? (port, pick.goal) : (pick.start, port)
                }
            }
            return assigned
        }
    }

    // MARK: Grid

    /// The orthogonal grid searches run on: what blocks each node and edge, what running each
    /// edge costs extra (group borders, title bands), and which arrows use it.
    final class Grid {
        let xs: [CGFloat]
        let ys: [CGFloat]
        let nx: Int
        let ny: Int
        /// Obstacles whose inside covers the node / the edge to the right / the edge down.
        private var node: [UInt16]
        private var right: [UInt16]
        private var down: [UInt16]
        /// Extra cost per point of length of the edge to the right / down.
        private var rightFactor: [Float]
        private var downFactor: [Float]
        /// Tiles' margins the edge to the right / down runs along: 2 is a one-track gap.
        private var rightHugs: [UInt8]
        private var downHugs: [UInt8]
        /// Arrows routed on the edge to the right / down.
        private var usedRight: [UInt16]
        private var usedDown: [UInt16]
        private var best: [CGFloat]
        private var parent: [Int32]
        private var stamp: [UInt32]
        private var generation: UInt32 = 0

        static let epsilon: CGFloat = 0.001

        init?(xs: [CGFloat], ys: [CGFloat], blocks: [CGRect], regions: [Region]) {
            self.xs = Self.lines(xs)
            self.ys = Self.lines(ys)
            nx = self.xs.count
            ny = self.ys.count
            guard nx > 0, ny > 0, nx * ny <= 1_000_000 else { return nil }
            let count = nx * ny
            node = [UInt16](repeating: 0, count: count)
            right = [UInt16](repeating: 0, count: count)
            down = [UInt16](repeating: 0, count: count)
            rightFactor = [Float](repeating: 0, count: count)
            downFactor = [Float](repeating: 0, count: count)
            rightHugs = [UInt8](repeating: 0, count: count)
            downHugs = [UInt8](repeating: 0, count: count)
            usedRight = [UInt16](repeating: 0, count: count)
            usedDown = [UInt16](repeating: 0, count: count)
            best = [CGFloat](repeating: .infinity, count: count * 4)
            parent = [Int32](repeating: -1, count: count * 4)
            stamp = [UInt32](repeating: 0, count: count * 4)
            for rect in blocks { cover(rect) }
            for region in regions { soften(region) }
        }

        /// Sorted, with values within 0.01 of each other merged.
        static func lines(_ values: [CGFloat]) -> [CGFloat] {
            var result: [CGFloat] = []
            for value in values.filter(\.isFinite).sorted() where result.last.map({ value - $0 > 0.01 }) ?? true {
                result.append(value)
            }
            return result
        }

        /// First index whose value is ≥ `value` - epsilon.
        func lower(_ values: [CGFloat], _ value: CGFloat) -> Int {
            var low = 0
            var high = values.count
            while low < high {
                let mid = (low + high) / 2
                if values[mid] < value - Self.epsilon { low = mid + 1 } else { high = mid }
            }
            return low
        }

        /// First index whose value is > `value` + epsilon.
        func upper(_ values: [CGFloat], _ value: CGFloat) -> Int {
            var low = 0
            var high = values.count
            while low < high {
                let mid = (low + high) / 2
                if values[mid] <= value + Self.epsilon { low = mid + 1 } else { high = mid }
            }
            return low
        }

        func index(_ point: CGPoint) -> Int? {
            let i = lower(xs, point.x - 0.01)
            let j = lower(ys, point.y - 0.01)
            guard i < nx, j < ny, abs(xs[i] - point.x) <= 0.01, abs(ys[j] - point.y) <= 0.01 else { return nil }
            return j * nx + i
        }

        static func inside(_ rect: CGRect, _ x: CGFloat, _ y: CGFloat) -> Bool {
            x > rect.minX + epsilon && x < rect.maxX - epsilon && y > rect.minY + epsilon && y < rect.maxY - epsilon
        }

        static func spansRight(_ rect: CGRect, _ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) -> Bool {
            y > rect.minY + epsilon && y < rect.maxY - epsilon && x0 >= rect.minX - epsilon && x1 <= rect.maxX + epsilon
        }

        static func spansDown(_ rect: CGRect, _ y0: CGFloat, _ y1: CGFloat, _ x: CGFloat) -> Bool {
            x > rect.minX + epsilon && x < rect.maxX - epsilon && y0 >= rect.minY - epsilon && y1 <= rect.maxY + epsilon
        }

        /// Blocks what lies inside `rect`; running right along its edges (a tile's margin) costs
        /// `hugCost` extra.
        private func cover(_ rect: CGRect) {
            let i0 = lower(xs, rect.minX)
            let i1 = upper(xs, rect.maxX) - 1
            let j0 = lower(ys, rect.minY)
            let j1 = upper(ys, rect.maxY) - 1
            guard i0 <= i1, j0 <= j1 else { return }
            let hug = Float(ConnectorRouter.hugCost)
            for j in j0...j1 {
                let edgeY = abs(ys[j] - rect.minY) < Self.epsilon || abs(ys[j] - rect.maxY) < Self.epsilon
                for i in i0...i1 {
                    let n = j * nx + i
                    if Self.inside(rect, xs[i], ys[j]) { node[n] += 1 }
                    if i < i1 {
                        if Self.spansRight(rect, xs[i], xs[i + 1], ys[j]) {
                            right[n] += 1
                        } else if edgeY {
                            rightFactor[n] += hug
                            rightHugs[n] &+= 1
                        }
                    }
                    if j < j1 {
                        let edgeX = abs(xs[i] - rect.minX) < Self.epsilon || abs(xs[i] - rect.maxX) < Self.epsilon
                        if Self.spansDown(rect, ys[j], ys[j + 1], xs[i]) {
                            down[n] += 1
                        } else if edgeX {
                            downFactor[n] += hug
                            downHugs[n] &+= 1
                        }
                    }
                }
            }
        }

        /// Running along a group's border, or across its title band, costs extra.
        private func soften(_ region: Region) {
            let frame = region.frame
            let band = ConnectorRouter.borderBand
            let title = region.title
            let border = Float(ConnectorRouter.borderCost)
            let titled = Float(ConnectorRouter.titleCost)
            let i0 = lower(xs, frame.minX - band)
            let i1 = upper(xs, frame.maxX + band) - 1
            let j0 = lower(ys, frame.minY - band)
            let j1 = upper(ys, frame.maxY + band) - 1
            guard i0 <= i1, j0 <= j1 else { return }
            for j in j0...j1 {
                let y = ys[j]
                for i in i0...i1 {
                    let x = xs[i]
                    let n = j * nx + i
                    if i + 1 < nx, xs[i + 1] > frame.minX, x < frame.maxX {
                        if abs(y - frame.minY) < band || abs(y - frame.maxY) < band || abs(y - title.maxY) < band { rightFactor[n] += border }
                        if y > title.minY, y < title.maxY { rightFactor[n] += titled }
                    }
                    if j + 1 < ny, ys[j + 1] > frame.minY, y < frame.maxY {
                        if abs(x - frame.minX) < band || abs(x - frame.maxX) < band { downFactor[n] += border }
                    }
                }
            }
        }

        struct Query {
            var starts: [Port]
            var goals: [Port]
            var window: (i0: Int, i1: Int, j0: Int, j1: Int)
            var exempt: [CGRect]
            var extra: [CGRect]
            var congestion: Bool
        }

        struct Found {
            var nodes: [Int]
            var start: Port
            var goal: Port
            var cost: CGFloat
        }

        private func nodeBlocked(_ n: Int, _ q: Query) -> Bool {
            let count = Int(node[n])
            if q.exempt.isEmpty && q.extra.isEmpty { return count > 0 }
            let x = xs[n % nx]
            let y = ys[n / nx]
            if count > 0, count > q.exempt.reduce(0, { $0 + (Self.inside($1, x, y) ? 1 : 0) }) { return true }
            return q.extra.contains { Self.inside($0, x, y) }
        }

        private func edgeBlocked(_ n: Int, horizontal: Bool, _ q: Query) -> Bool {
            let count = Int(horizontal ? right[n] : down[n])
            if q.exempt.isEmpty && q.extra.isEmpty { return count > 0 }
            let i = n % nx
            let j = n / nx
            if horizontal {
                let x0 = xs[i], x1 = xs[i + 1], y = ys[j]
                if count > 0, count > q.exempt.reduce(0, { $0 + (Self.spansRight($1, x0, x1, y) ? 1 : 0) }) { return true }
                return q.extra.contains { Self.spansRight($0, x0, x1, y) }
            }
            let y0 = ys[j], y1 = ys[j + 1], x = xs[i]
            if count > 0, count > q.exempt.reduce(0, { $0 + (Self.spansDown($1, y0, y1, x) ? 1 : 0) }) { return true }
            return q.extra.contains { Self.spansDown($0, y0, y1, x) }
        }

        /// Adds (`delta` 1) or removes (-1) a route's use of its grid edges.
        func use(_ nodes: [Int], _ delta: Int) {
            for (a, b) in zip(nodes, nodes.dropFirst()) where a != b {
                let n = min(a, b)
                if abs(a - b) == 1 {
                    usedRight[n] = UInt16(max(0, Int(usedRight[n]) + delta))
                } else {
                    usedDown[n] = UInt16(max(0, Int(usedDown[n]) + delta))
                }
            }
        }

        /// The grid nodes along an axis-aligned polyline whose corners lie on grid lines, in order;
        /// nil when one doesn't.
        func nodes(along points: [CGPoint]) -> [Int]? {
            var result: [Int] = []
            for (a, b) in zip(points, points.dropFirst()) {
                guard let from = index(a), let to = index(b) else { return nil }
                let (i0, j0, i1, j1) = (from % nx, from / nx, to % nx, to / nx)
                if j0 == j1 {
                    let step = i1 >= i0 ? 1 : -1
                    var i = i0
                    while i != i1 { result.append(j0 * nx + i); i += step }
                } else if i0 == i1 {
                    let step = j1 >= j0 ? 1 : -1
                    var j = j0
                    while j != j1 { result.append(j * nx + i0); j += step }
                } else {
                    return nil
                }
            }
            if let last = points.last, let n = index(last) { result.append(n) }
            return result
        }

        func points(_ found: Found) -> [CGPoint] {
            DrawingGeometry.simplified([found.start.point] + found.nodes.map { CGPoint(x: xs[$0 % nx], y: ys[$0 / nx]) } + [found.goal.point])
        }

        /// The cheapest route from a start port's stub to a goal port's stub (A* over (node,
        /// heading) states, reversing never allowed), within the query's window.
        func search(_ q: Query) -> Found? {
            generation &+= 1
            if generation == 0 {
                stamp = [UInt32](repeating: 0, count: stamp.count)
                generation = 1
            }
            let bend = ConnectorRouter.bendCost
            var goalAt: [Int: [Int]] = [:]
            var goalStubs: [CGPoint] = []
            for (k, goal) in q.goals.enumerated() {
                guard let n = index(goal.stub), !nodeBlocked(n, q) else { continue }
                goalAt[n, default: []].append(k)
                goalStubs.append(goal.stub)
            }
            guard !goalAt.isEmpty else { return nil }
            func estimate(_ n: Int) -> CGFloat {
                let x = xs[n % nx], y = ys[n / nx]
                var least = CGFloat.infinity
                for stub in goalStubs { least = min(least, abs(stub.x - x) + abs(stub.y - y)) }
                return least
            }
            var heap = MinHeap()
            var startAt: [Int: Int] = [:]
            for (k, start) in q.starts.enumerated() {
                guard let n = index(start.stub), !nodeBlocked(n, q) else { continue }
                let state = n * 4 + start.heading
                let cost = start.cost + abs(start.point.x - start.stub.x) + abs(start.point.y - start.stub.y)
                if stamp[state] == generation, best[state] <= cost { continue }
                stamp[state] = generation
                best[state] = cost
                parent[state] = -1
                startAt[state] = k
                heap.push(state, cost + estimate(n))
            }
            let (i0, i1, j0, j1) = q.window
            var finish: (state: Int, cost: CGFloat, goal: Int)?
            while let (state, _) = heap.pop() {
                let cost = best[state]
                if let finish, cost >= finish.cost { break }
                let n = state / 4
                let heading = state % 4
                if let goals = goalAt[n] {
                    for k in goals {
                        let goal = q.goals[k]
                        let turn: CGFloat = heading == (goal.heading + 2) % 4 ? 0 : bend
                        let total = cost + turn + goal.cost + abs(goal.point.x - goal.stub.x) + abs(goal.point.y - goal.stub.y)
                        if finish == nil || total < finish!.cost { finish = (state, total, k) }
                    }
                }
                let i = n % nx
                let j = n / nx
                for direction in 0..<4 where direction != (heading + 2) % 4 {
                    let ni = i + (direction == 0 ? 1 : direction == 2 ? -1 : 0)
                    let nj = j + (direction == 1 ? 1 : direction == 3 ? -1 : 0)
                    guard ni >= i0, ni <= i1, nj >= j0, nj <= j1 else { continue }
                    let next = nj * nx + ni
                    let horizontal = direction % 2 == 0
                    let edge = min(n, next)
                    guard !edgeBlocked(edge, horizontal: horizontal, q), !nodeBlocked(next, q) else { continue }
                    let length = abs(xs[ni] - xs[i]) + abs(ys[nj] - ys[j])
                    var step = length * (1 + CGFloat(horizontal ? rightFactor[edge] : downFactor[edge]))
                    if direction != heading { step += bend }
                    if q.congestion {
                        let used = horizontal ? usedRight[edge] : usedDown[edge]
                        step += length * ConnectorRouter.shareCost * CGFloat(used)
                        if used > 0, (horizontal ? rightHugs[edge] : downHugs[edge]) >= 2 { step += length * ConnectorRouter.narrowShareCost * CGFloat(used) }
                        if horizontal {
                            if nj > 0, usedDown[next] > 0, usedDown[next - nx] > 0 { step += ConnectorRouter.crossCost * CGFloat(min(usedDown[next], usedDown[next - nx])) }
                        } else if ni > 0, usedRight[next] > 0, usedRight[next - 1] > 0 {
                            step += ConnectorRouter.crossCost * CGFloat(min(usedRight[next], usedRight[next - 1]))
                        }
                    }
                    let nextCost = cost + step
                    let nextState = next * 4 + direction
                    if stamp[nextState] == generation, best[nextState] <= nextCost { continue }
                    stamp[nextState] = generation
                    best[nextState] = nextCost
                    parent[nextState] = Int32(state)
                    heap.push(nextState, nextCost + estimate(next))
                }
            }
            guard let finish else { return nil }
            var states = [finish.state]
            while let last = states.last, parent[last] >= 0 { states.append(Int(parent[last])) }
            guard let first = states.last, let start = startAt[first] else { return nil }
            return Found(nodes: states.reversed().map { $0 / 4 }, start: q.starts[start], goal: q.goals[finish.goal], cost: finish.cost)
        }
    }

    // MARK: Nudging

    /// Spreads collinear, overlapping segments of different arrows into parallel tracks: the
    /// vertical ones (`vertical`) along x, else the horizontal ones along y. Segments that
    /// overlap along their extent and see each other across free space (within three track
    /// spacings) share a channel; a channel's segments are ordered so that their turns cross
    /// each other least, then placed as near where they were as that order allows,
    /// `parallelSpacing` apart where the channel is wide enough, else as far apart as it is. Only
    /// interior segments of `movable` routes move (first and last segments sit at their ports);
    /// tracks keep `trackClearance` from tiles and, where there is room, `borderClearance` from
    /// group borders and title bands.
    static func nudge(_ routes: inout [[CGPoint]], movable: [Bool], obstacles: [CGRect], soft: [(rect: CGRect, vertical: Bool)], vertical: Bool) {
        struct Segment {
            var route: Int
            var index: Int
            var coord: CGFloat
            var low: CGFloat
            var high: CGFloat
            var movable: Bool
            /// Free space either side, up to the nearest tile.
            var free: ClosedRange<CGFloat>
            /// Where it may move (its coordinate alone when fixed), and where it may move keeping
            /// off borders and title bands.
            var hard: ClosedRange<CGFloat>
            var soft: ClosedRange<CGFloat>
            /// Each end's position along the segment and which way (±1) the next segment turns.
            var turns: [(at: CGFloat, way: CGFloat)]
        }
        func c(_ p: CGPoint) -> CGFloat { vertical ? p.x : p.y }
        func e(_ p: CGPoint) -> CGFloat { vertical ? p.y : p.x }
        func span(_ r: CGRect) -> (c0: CGFloat, c1: CGFloat, e0: CGFloat, e1: CGFloat) {
            vertical ? (r.minX, r.maxX, r.minY, r.maxY) : (r.minY, r.maxY, r.minX, r.maxX)
        }
        var segments: [Segment] = []
        for (r, points) in routes.enumerated() where points.count >= 2 {
            let last = points.count - 2
            for i in 0...last {
                let a = points[i], b = points[i + 1]
                guard abs(c(a) - c(b)) < 0.01, abs(e(a) - e(b)) > 0.5 else { continue }
                let coord = c(a)
                let low = min(e(a), e(b)), high = max(e(a), e(b))
                var turns: [(at: CGFloat, way: CGFloat)] = []
                if i > 0 { turns.append((e(a), c(points[i - 1]) < coord ? -1 : 1)) }
                if i < last { turns.append((e(b), c(points[i + 2]) < coord ? -1 : 1)) }
                var freeLow = -CGFloat.infinity
                var freeHigh = CGFloat.infinity
                for rect in obstacles {
                    let s = span(rect)
                    guard s.e0 < high + 1, s.e1 > low - 1 else { continue }
                    if s.c1 <= coord { freeLow = max(freeLow, s.c1 + trackClearance) } else if s.c0 >= coord { freeHigh = min(freeHigh, s.c0 - trackClearance) }
                }
                freeLow = min(freeLow, coord)
                freeHigh = max(freeHigh, coord)
                var segment = Segment(route: r, index: i, coord: coord, low: low, high: high, movable: movable[r] && i > 0 && i < last,
                                      free: freeLow...freeHigh, hard: coord...coord, soft: coord...coord, turns: turns)
                if segment.movable {
                    var lowBound = freeLow
                    var highBound = freeHigh
                    // Keep the first and last segments long enough, and pointing the same way.
                    if i == 1 {
                        let port = c(points[0])
                        if coord > port { lowBound = max(lowBound, port + minStub) } else { highBound = min(highBound, port - minStub) }
                    }
                    if i == last - 1 {
                        let port = c(points[last + 1])
                        if port > coord { highBound = min(highBound, port - minStub) } else { lowBound = max(lowBound, port + minStub) }
                    }
                    lowBound = min(lowBound, coord)
                    highBound = max(highBound, coord)
                    // Borders and title bands split the free range into pieces; the segment keeps
                    // to its own piece (the larger neighbour when it runs on or right by one),
                    // `borderClearance` in from its ends.
                    var cuts: [(CGFloat, CGFloat)] = []
                    for line in soft where line.vertical == vertical {
                        let s = span(line.rect)
                        guard s.e0 < high, s.e1 > low, s.c1 > lowBound - borderClearance, s.c0 < highBound + borderClearance else { continue }
                        cuts.append((s.c0, s.c1))
                    }
                    // The gaps between cuts, and what of each the segment may use.
                    var gaps: [(low: CGFloat, high: CGFloat)] = []
                    var previous = -CGFloat.infinity
                    for (c0, c1) in cuts.sorted(by: { $0.0 < $1.0 }) {
                        if c0 > previous { gaps.append((previous, c0)) }
                        previous = max(previous, c1)
                    }
                    gaps.append((previous, .infinity))
                    typealias Piece = (gap: (low: CGFloat, high: CGFloat), usable: ClosedRange<CGFloat>)
                    let pieces = gaps.compactMap { gap -> Piece? in
                        let usableLow = max(lowBound, gap.low + borderClearance)
                        let usableHigh = min(highBound, gap.high - borderClearance)
                        return usableLow <= usableHigh ? (gap, usableLow...usableHigh) : nil
                    }
                    func width(_ piece: Piece) -> CGFloat { piece.usable.upperBound - piece.usable.lowerBound }
                    func distance(_ piece: Piece) -> CGFloat { max(piece.usable.lowerBound - coord, coord - piece.usable.upperBound, 0) }
                    let near = pieces.filter { $0.gap.low - borderClearance < coord && coord < $0.gap.high + borderClearance }
                    segment.hard = lowBound...highBound
                    segment.soft = (near.max { width($0) < width($1) } ?? pieces.min { distance($0) < distance($1) })?.usable ?? segment.hard
                }
                segments.append(segment)
            }
        }
        guard !segments.isEmpty else { return }

        // Channels.
        let spacing = DrawingGeometry.parallelSpacing
        var parent = Array(segments.indices)
        func root(_ a: Int) -> Int {
            var a = a
            while parent[a] != a {
                parent[a] = parent[parent[a]]
                a = parent[a]
            }
            return a
        }
        let byCoord = segments.indices.sorted { (segments[$0].coord, $0) < (segments[$1].coord, $1) }
        for (position, a) in byCoord.enumerated() {
            let sa = segments[a]
            for b in byCoord[(position + 1)...] {
                let sb = segments[b]
                guard sb.coord - sa.coord < 3 * spacing else { break }
                guard sa.movable || sb.movable || sb.coord - sa.coord < spacing - 0.5 else { continue }
                // Moving segments on either side of a border or title band are separate channels.
                guard !(sa.movable && sb.movable) || sa.soft.overlaps(sb.soft) else { continue }
                guard sa.route != sb.route || abs(sa.index - sb.index) > 1 else { continue }
                guard min(sa.high, sb.high) - max(sa.low, sb.low) > -1, sa.free.contains(sb.coord), sb.free.contains(sa.coord) else { continue }
                parent[root(a)] = root(b)
            }
        }
        var channels: [Int: [Int]] = [:]
        for index in segments.indices { channels[root(index), default: []].append(index) }

        /// Crossings of the two segments' turns with each other when `a` lies before `b`.
        func crossings(_ a: Segment, before b: Segment) -> Int {
            var count = 0
            for turn in b.turns where turn.way < 0 && turn.at > a.low + 0.5 && turn.at < a.high - 0.5 { count += 1 }
            for turn in a.turns where turn.way > 0 && turn.at > b.low + 0.5 && turn.at < b.high - 0.5 { count += 1 }
            return count
        }
        func feasible(_ order: [Int], _ bounds: (Int) -> ClosedRange<CGFloat>, _ gap: CGFloat) -> Bool {
            var x = -CGFloat.infinity
            for member in order {
                x = max(bounds(member).lowerBound, x + gap)
                if x > bounds(member).upperBound + 0.001 { return false }
            }
            return true
        }

        var moved: [(segment: Int, coord: CGFloat)] = []
        for key in channels.keys.sorted() {
            let members = channels[key]!
            if members.count == 1 {
                let segment = segments[members[0]]
                if segment.movable, !segment.soft.contains(segment.coord) {
                    moved.append((members[0], min(max(segment.coord, segment.soft.lowerBound), segment.soft.upperBound)))
                }
                continue
            }
            guard members.contains(where: { segments[$0].movable }) else { continue }
            // Each overlapping pair prefers the order in which their turns cross less; take an
            // order honouring those preferences (by position where none holds), breaking a cycle
            // at the segment fewest prefer to come after.
            let key = { (m: Int) in (segments[m].coord, segments[m].route, segments[m].index) }
            var after: [Int: [Int]] = [:]
            var waiting: [Int: Int] = [:]
            for (position, a) in members.enumerated() {
                for b in members[(position + 1)...] {
                    let sa = segments[a], sb = segments[b]
                    guard min(sa.high, sb.high) - max(sa.low, sb.low) > -1 else { continue }
                    let ab = crossings(sa, before: sb)
                    let ba = crossings(sb, before: sa)
                    guard ab != ba else { continue }
                    let (first, second) = ab < ba ? (a, b) : (b, a)
                    after[first, default: []].append(second)
                    waiting[second, default: 0] += 1
                }
            }
            var remaining = Set(members)
            var preferred: [Int] = []
            while !remaining.isEmpty {
                let ready = remaining.filter { (waiting[$0] ?? 0) == 0 }
                let next = ready.min { key($0) < key($1) }
                    ?? remaining.min { ((waiting[$0] ?? 0), key($0).0, key($0).1, key($0).2) < ((waiting[$1] ?? 0), key($1).0, key($1).1, key($1).2) }!
                remaining.remove(next)
                preferred.append(next)
                for later in after[next] ?? [] where remaining.contains(later) { waiting[later, default: 0] -= 1 }
            }
            let byPosition = members.sorted { key($0) < key($1) }
            var plan: (order: [Int], gap: CGFloat, soft: Bool)?
            search: for (useSoft, gaps) in [(true, [spacing, 16, 13, 10, 8, 6] as [CGFloat]), (false, [spacing, 16, 13, 10, 8, 6, 4, 2])] {
                for order in [preferred, byPosition] {
                    for gap in gaps where feasible(order, { useSoft ? segments[$0].soft : segments[$0].hard }, gap) {
                        plan = (order, gap, useSoft)
                        break search
                    }
                }
            }
            guard let plan else { continue }
            let bounds = { (m: Int) in plan.soft ? segments[m].soft : segments[m].hard }
            let order = plan.order
            let k = order.count
            // Nearest to where they were, in order and `gap` apart (pool adjacent violators on
            // positions less their rank's share of the gaps), then within reach of the bounds.
            var pools: [(sum: CGFloat, count: Int)] = []
            for (rank, m) in order.enumerated() {
                pools.append((segments[m].coord - CGFloat(rank) * plan.gap, 1))
                while pools.count > 1, pools[pools.count - 2].sum / CGFloat(pools[pools.count - 2].count) > pools[pools.count - 1].sum / CGFloat(pools[pools.count - 1].count) {
                    let top = pools.removeLast()
                    pools[pools.count - 1].sum += top.sum
                    pools[pools.count - 1].count += top.count
                }
            }
            var desired: [CGFloat] = []
            for pool in pools { desired += Array(repeating: pool.sum / CGFloat(pool.count), count: pool.count) }
            var earliest = [CGFloat](repeating: 0, count: k)
            var latest = [CGFloat](repeating: 0, count: k)
            var x = -CGFloat.infinity
            for (rank, m) in order.enumerated() {
                x = max(bounds(m).lowerBound, x + plan.gap)
                earliest[rank] = x
            }
            x = .infinity
            for (rank, m) in order.enumerated().reversed() {
                x = min(bounds(m).upperBound, x - plan.gap)
                latest[rank] = x
            }
            for (rank, m) in order.enumerated() {
                let position = min(max(desired[rank] + CGFloat(rank) * plan.gap, earliest[rank]), max(earliest[rank], latest[rank]))
                if segments[m].movable, abs(position - segments[m].coord) > 0.001 { moved.append((m, position)) }
            }
        }
        for (m, coord) in moved {
            let segment = segments[m]
            for p in [segment.index, segment.index + 1] {
                if vertical { routes[segment.route][p].x = coord } else { routes[segment.route][p].y = coord }
            }
        }
    }

    // MARK: Labels

    struct LabelCandidate {
        var rect: CGRect
        var leader: [CGPoint]?
        /// Centred on its own route (the chip interrupts the line).
        var onLine = false
        /// Beside a stretch of its route that other arrows run alongside (a bundle), or led from
        /// one: the chip reads as naming the whole bundle.
        var bundled = false
        /// Beside a bundled stretch of its own line, led to a stretch where its line runs alone
        /// (its stub before it joins the bundle), so the chip names that one line.
        var tethered = false
    }

    /// Where each caption goes: beside its arrow's segments, the ones no other arrow runs along
    /// first (longest first), from their middles outward; then on the line itself (the chip
    /// interrupting it); then `leaderReaches` away with a leader. A spot must keep off tiles,
    /// title bands, other arrows' lines and labels, and (beside or on the route) have no other
    /// arrow nearer than its own. A spot beside a stretch other lines run alongside costs more,
    /// and is tried first tethered to a stretch where its line runs alone. Labels with the fewest
    /// clear spots go first; one left without takes a spot a single other label is in the way of
    /// when that one can move, else the spot with the fewest collisions (`layout.check` reports it).
    ///
    /// `keep` (by connector index) are labels that stand as they are (`keptLabels`): the others
    /// are placed around them, and one moves only when it is the single label in the way of one
    /// left without a clear spot (a caption that came or grew beside it) and has another.
    static func placeLabels(connectors: [Connector], routes: [[CGPoint]], obstacles: [CGRect], titles: [CGRect], groups: [CGRect] = [],
                            keep: [Int: Label] = [:]) -> [ObjectID: Label] {
        let labelled = connectors.indices.filter { connectors[$0].label != nil && routes[$0].count >= 2 && keep[$0] == nil }
        var result: [ObjectID: Label] = [:]
        for (index, label) in keep { result[connectors[index].id] = label }
        guard !labelled.isEmpty else { return result }
        let segments = LabelSegments(routes: routes, obstacles: obstacles, titles: titles, groups: groups)
        var candidates: [Int: [LabelCandidate]] = [:]
        var clear: [Int: Int] = [:]
        /// A label's acceptable spots, best first (clear beside or on the route, then beside it
        /// with another line close by, then a clear leader), and how many are clear.
        func prepare(_ index: Int) {
            let all = labelCandidates(route: routes[index], owner: index, size: connectors[index].label!, segments: segments)
            let open = all.enumerated().compactMap { order, spot -> (score: Int, order: Int, spot: LabelCandidate)? in
                let score = segments.collisions(spot, owner: index, labels: [], limit: underCost)
                return score < underCost ? (score, order, spot) : nil
            }.sorted { ($0.score, $0.order) < ($1.score, $1.order) }.map(\.spot)
            candidates[index] = open.isEmpty ? all : open
            clear[index] = open.count
        }
        for index in labelled { prepare(index) }
        /// Whether two placed labels get in each other's way: chips closer than 2 points, or a
        /// leader through the other chip.
        func clash(_ a: LabelCandidate, _ b: LabelCandidate) -> Bool {
            if a.rect.insetBy(dx: -2, dy: -2).intersects(b.rect.insetBy(dx: 0.5, dy: 0.5)) { return true }
            if let leader = a.leader, leader.count == 2, DrawingGeometry.segment(leader[0], leader[1], intersects: b.rect) { return true }
            if let leader = b.leader, leader.count == 2, DrawingGeometry.segment(leader[0], leader[1], intersects: a.rect) { return true }
            return false
        }
        let order = labelled.sorted { (clear[$0]!, connectors[$0].id) < (clear[$1]!, connectors[$1].id) }
        var chosen: [Int: LabelCandidate] = [:]
        for (index, label) in keep { chosen[index] = LabelCandidate(rect: label.rect, leader: label.leader) }
        var stuck: [Int] = []
        for index in order {
            if clear[index]! > 0, let spot = candidates[index]!.first(where: { spot in !chosen.values.contains { clash(spot, $0) } }) {
                chosen[index] = spot
                continue
            }
            stuck.append(index)
            let placed = chosen.values.map(\.rect)
            var fewest = Int.max
            for candidate in candidates[index]! {
                let count = segments.collisions(candidate, owner: index, labels: placed, limit: fewest)
                if count < fewest {
                    fewest = count
                    chosen[index] = candidate
                }
            }
        }
        // A label left without a clear spot takes one that a single other label is in the way
        // of, when that label has another clear spot.
        for index in stuck where clear[index]! > 0 {
            search: for spot in candidates[index]! {
                let blocking = chosen.filter { $0.key != index && clash(spot, $0.value) }.map(\.key)
                guard blocking.count == 1, let other = blocking.first else { continue }
                if keep[other] != nil, candidates[other] == nil { prepare(other) }
                guard let room = clear[other], room > 0 else { continue }
                for move in candidates[other]! where !clash(move, spot) {
                    guard !chosen.contains(where: { $0.key != index && $0.key != other && clash(move, $0.value) }) else { continue }
                    chosen[other] = move
                    chosen[index] = spot
                    break search
                }
            }
        }
        for (index, spot) in chosen { result[connectors[index].id] = Label(rect: spot.rect, leader: spot.leader) }
        return result
    }

    /// Every route's segments, tiles, title bands, and group frames (whose borders a tether
    /// keeps off), for label collision tests.
    struct LabelSegments {
        var owners: [Int] = []
        var starts: [CGPoint] = []
        var ends: [CGPoint] = []
        var bounds: [CGRect] = []
        let routes: [[CGPoint]]
        let obstacles: [CGRect]
        let titles: [CGRect]
        let groups: [CGRect]

        init(routes: [[CGPoint]], obstacles: [CGRect], titles: [CGRect], groups: [CGRect]) {
            self.routes = routes
            self.obstacles = obstacles
            self.titles = titles
            self.groups = groups
            for (owner, route) in routes.enumerated() {
                for (a, b) in zip(route, route.dropFirst()) {
                    owners.append(owner)
                    starts.append(a)
                    ends.append(b)
                    bounds.append(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
                }
            }
        }

        /// Whether another arrow's line comes within `reach` of `rect`.
        func othersNear(_ rect: CGRect, owner: Int, reach: CGFloat) -> Bool {
            let area = rect.insetBy(dx: -reach, dy: -reach)
            for k in owners.indices where owners[k] != owner {
                guard bounds[k].insetBy(dx: -0.5, dy: -0.5).intersects(area) else { continue }
                if DrawingGeometry.segment(starts[k], ends[k], intersects: area) { return true }
            }
            return false
        }

        /// How many other arrows' segments cross segment a–b.
        func othersCrossing(_ a: CGPoint, _ b: CGPoint, owner: Int) -> Int {
            let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -0.5, dy: -0.5)
            var count = 0
            for k in owners.indices where owners[k] != owner && bounds[k].intersects(box) {
                if ConnectorRouter.properlyIntersect(a, b, starts[k], ends[k]) { count += 1 }
            }
            return count
        }

        /// How many other arrows' segments run under `rect`.
        func othersUnder(_ rect: CGRect, owner: Int) -> Int {
            var count = 0
            for k in owners.indices where owners[k] != owner && bounds[k].insetBy(dx: -0.5, dy: -0.5).intersects(rect) {
                if DrawingGeometry.segment(starts[k], ends[k], intersects: rect) { count += 1 }
            }
            return count
        }

        /// How bad a label at `candidate` would be, 0 when clear, counted up to `limit`: a tile,
        /// title band, placed label, or its own route under it (unless on it) counts `coverCost`;
        /// another arrow's line under it `underCost`; a leader `leaderCost`; another arrow nearer
        /// than its own (beside the route) 1; each line its leader crosses 3 (a last resort short
        /// of covering something), and each tile or label `coverCost`.
        func collisions(_ candidate: LabelCandidate, owner: Int, labels: [CGRect], limit: Int) -> Int {
            let rect = candidate.rect
            let inner = rect.insetBy(dx: 0.5, dy: 0.5)
            var count = 0
            for obstacle in obstacles where obstacle.intersects(inner) {
                count += coverCost
                if count >= limit { return count }
            }
            for title in titles where title.intersects(inner) {
                count += coverCost
                if count >= limit { return count }
            }
            for label in labels where label.insetBy(dx: -2, dy: -2).intersects(inner) {
                count += coverCost
                if count >= limit { return count }
            }
            let under = othersUnder(inner, owner: owner)
            count += ConnectorRouter.underCost * under
            if count >= limit { return count }
            if let leader = candidate.leader, leader.count == 2 {
                count += ConnectorRouter.leaderCost
                if !candidate.tethered, hypot(leader[1].x - leader[0].x, leader[1].y - leader[0].y) > ConnectorRouter.shortLeader + DrawingGeometry.labelClearance { count += 1 }
                if under == 0, othersNear(rect, owner: owner, reach: 3) { count += 1 }
                count += 3 * othersCrossing(leader[0], leader[1], owner: owner)
                for obstacle in obstacles where DrawingGeometry.segment(leader[0], leader[1], intersects: obstacle.insetBy(dx: 0.5, dy: 0.5)) { count += coverCost }
                for label in labels where DrawingGeometry.segment(leader[0], leader[1], intersects: label) { count += coverCost }
            } else if under == 0, !candidate.onLine, othersNear(rect, owner: owner, reach: DrawingGeometry.labelClearance - 1) {
                count += 1
            }
            // A leader from a bundle costs what a spot beside it does.
            if candidate.bundled { count += candidate.leader == nil ? ConnectorRouter.bundleCost : ConnectorRouter.bundleCost - ConnectorRouter.leaderCost }
            if count < limit, !candidate.onLine, DrawingGeometry.distance(fromPath: routes[owner], to: rect) < DrawingGeometry.labelClearance - 1 { count += coverCost }
            return count
        }
    }

    static func labelCandidates(route: [CGPoint], owner: Int, size: CGSize, segments: LabelSegments) -> [LabelCandidate] {
        let spacing = DrawingGeometry.parallelSpacing * 1.5
        // Each segment's length that no other arrow runs alongside (within 1.5 track spacings).
        var ranked: [(index: Int, distinct: CGFloat, length: CGFloat)] = []
        // The stretches of each segment other arrows run alongside, where the route is bundled,
        // and those no other line runs closer to than half a track spacing, where a leader's
        // foot names this line alone.
        var bundles: [Int: [(CGFloat, CGFloat)]] = [:]
        var alone: [Int: [(CGFloat, CGFloat)]] = [:]
        for (index, (a, b)) in zip(route, route.dropFirst()).enumerated() {
            let horizontal = abs(a.y - b.y) < 0.5
            let vertical = abs(a.x - b.x) < 0.5
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0.5 else { continue }
            let low = horizontal ? min(a.x, b.x) : min(a.y, b.y)
            let high = horizontal ? max(a.x, b.x) : max(a.y, b.y)
            var covered: [(CGFloat, CGFloat)] = []
            var close: [(CGFloat, CGFloat)] = []
            if horizontal || vertical {
                for k in segments.owners.indices where segments.owners[k] != owner {
                    let p = segments.starts[k], q = segments.ends[k]
                    let parallel = horizontal ? abs(p.y - q.y) < 0.5 : abs(p.x - q.x) < 0.5
                    let gap = horizontal ? abs(p.y - a.y) : abs(p.x - a.x)
                    guard parallel, gap < spacing else { continue }
                    let l = max(low, horizontal ? min(p.x, q.x) : min(p.y, q.y)), h = min(high, horizontal ? max(p.x, q.x) : max(p.y, q.y))
                    guard h > l else { continue }
                    covered.append((l, h))
                    if gap < DrawingGeometry.parallelSpacing / 2 { close.append((l, h)) }
                }
            }
            var union: CGFloat = 0
            var reach = -CGFloat.infinity
            for (l, h) in covered.sorted(by: { $0.0 < $1.0 }) {
                let start = max(l, reach)
                if h > start { union += h - start }
                reach = max(reach, h)
            }
            ranked.append((index, length - union, length))
            bundles[index] = covered
            guard horizontal || vertical else { continue }
            var free: [(CGFloat, CGFloat)] = []
            var open = low
            for (l, h) in close.sorted(by: { $0.0 < $1.0 }) {
                if l > open { free.append((open, l)) }
                open = max(open, h)
            }
            if high > open { free.append((open, high)) }
            alone[index] = free.filter { $0.1 - $0.0 >= 8 }
        }
        ranked.sort { ($0.distinct, $0.length, -$0.index) > ($1.distinct, $1.length, -$1.index) }
        /// Spots along a segment of `length`, from its middle outward, about every 12 points.
        func fractions(_ length: CGFloat) -> [CGFloat] {
            let steps = max(2, min(24, Int(length / 12)))
            return (0...steps).map { CGFloat($0) / CGFloat(steps) }.sorted { (abs($0 - 0.5), $0) < (abs($1 - 0.5), $1) }
        }
        let w = size.width, h = size.height
        let clearance = DrawingGeometry.labelClearance
        let first = route[0], last = route[route.count - 1]
        var result: [LabelCandidate] = []
        /// Whether a chip beside segment `index` spanning `low...high` along it (a leader: its
        /// foot) sits by a bundled stretch.
        func bundled(_ index: Int, _ low: CGFloat, _ high: CGFloat) -> Bool {
            bundles[index, default: []].contains { min($0.1, high) - max($0.0, low) > 0 }
        }
        /// The shortest leader from `chip` straight to a stretch where the route runs alone,
        /// within the chip's extent, longer than the chip's clearance (a stretch right beside it
        /// is where it already sits) and no longer than the longest leader.
        func tether(_ chip: CGRect) -> [CGPoint]? {
            var best: [CGPoint]?
            var shortest = leaderReaches.last! + clearance
            for (index, stretches) in alone.sorted(by: { $0.key < $1.key }) {
                let a = route[index], b = route[index + 1]
                let horizontal = abs(a.y - b.y) < 0.5
                let (across, span) = horizontal ? (a.y, (chip.minX + 4, chip.maxX - 4)) : (a.x, (chip.minY + 4, chip.maxY - 4))
                let (near, far) = horizontal ? (chip.minY, chip.maxY) : (chip.minX, chip.maxX)
                guard across < near || across > far else { continue }
                let edge = across < near ? near : far
                let length = abs(edge - across)
                guard length > clearance + 1, length < shortest else { continue }
                for (l, h) in stretches {
                    let from = max(l, span.0), to = min(h, span.1)
                    guard to >= from else { continue }
                    // Off group borders it would run along: the spot in the stretch farthest from
                    // them (up to `borderClearance`), nearest its middle.
                    let (low, high) = (min(across, edge), max(across, edge))
                    let borders = segments.groups.flatMap { frame -> [CGFloat] in
                        let (start, end) = horizontal ? (frame.minY, frame.maxY) : (frame.minX, frame.maxX)
                        guard start < high, end > low else { return [] }
                        return horizontal ? [frame.minX, frame.maxX] : [frame.minY, frame.maxY]
                    }
                    let middle = (from + to) / 2
                    let spots = [middle, from, to] + borders.flatMap { [$0 - borderClearance, $0 + borderClearance] }.filter { $0 >= from && $0 <= to }
                    func room(_ t: CGFloat) -> CGFloat { min(borderClearance, borders.map { abs($0 - t) }.min() ?? borderClearance) }
                    let t = spots.max { (room($0), -abs($0 - middle)) < (room($1), -abs($1 - middle)) }!
                    best = horizontal ? [CGPoint(x: t, y: across), CGPoint(x: t, y: edge)] : [CGPoint(x: across, y: t), CGPoint(x: edge, y: t)]
                    shortest = length
                    break
                }
            }
            return best
        }
        // Beside the route (0), on it (-1), then leaders.
        for reach in [clearance, -1] + leaderReaches.map({ $0 + clearance }) {
            let onLine = reach < 0
            let leader = reach > clearance
            for segment in ranked {
                let a = route[segment.index], b = route[segment.index + 1]
                let horizontal = abs(a.y - b.y) < 0.5
                let vertical = abs(a.x - b.x) < 0.5
                for fraction in fractions(segment.length) {
                    if horizontal {
                        let low = min(a.x, b.x), high = max(a.x, b.x)
                        var x = low + (high - low) * fraction
                        if high - low >= w { x = min(max(x, low + w / 2), high - w / 2) }
                        if onLine {
                            result.append(LabelCandidate(rect: CGRect(x: x - w / 2, y: a.y - h / 2, width: w, height: h), onLine: true))
                            continue
                        }
                        // Centred on the spot, or (a segment shorter than the chip) hanging off
                        // either end of it.
                        let shifts: [CGFloat] = high - low >= w ? [0] : [0, w / 2 - 10, 10 - w / 2]
                        for shift in shifts {
                            let above = CGRect(x: x - w / 2 + shift, y: a.y - reach - h, width: w, height: h)
                            let below = CGRect(x: x - w / 2 + shift, y: a.y + reach, width: w, height: h)
                            result.append(LabelCandidate(rect: above, leader: leader ? [CGPoint(x: x, y: a.y), CGPoint(x: x, y: above.maxY)] : nil,
                                                         bundled: leader ? bundled(segment.index, x - 0.5, x + 0.5) : bundled(segment.index, above.minX, above.maxX)))
                            result.append(LabelCandidate(rect: below, leader: leader ? [CGPoint(x: x, y: a.y), CGPoint(x: x, y: below.minY)] : nil,
                                                         bundled: leader ? bundled(segment.index, x - 0.5, x + 0.5) : bundled(segment.index, below.minX, below.maxX)))
                        }
                    } else if vertical {
                        let low = min(a.y, b.y), high = max(a.y, b.y)
                        var y = low + (high - low) * fraction
                        if high - low >= h { y = min(max(y, low + h / 2), high - h / 2) }
                        if onLine {
                            result.append(LabelCandidate(rect: CGRect(x: a.x - w / 2, y: y - h / 2, width: w, height: h), onLine: true))
                            continue
                        }
                        let right = CGRect(x: a.x + reach, y: y - h / 2, width: w, height: h)
                        let left = CGRect(x: a.x - reach - w, y: y - h / 2, width: w, height: h)
                        let spanBundled = leader ? bundled(segment.index, y - 0.5, y + 0.5) : bundled(segment.index, y - h / 2, y + h / 2)
                        result.append(LabelCandidate(rect: right, leader: leader ? [CGPoint(x: a.x, y: y), CGPoint(x: right.minX, y: y)] : nil, bundled: spanBundled))
                        result.append(LabelCandidate(rect: left, leader: leader ? [CGPoint(x: a.x, y: y), CGPoint(x: left.maxX, y: y)] : nil, bundled: spanBundled))
                    } else {
                        let length = hypot(b.x - a.x, b.y - a.y)
                        let point = CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
                        if onLine {
                            result.append(LabelCandidate(rect: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h), onLine: true))
                            continue
                        }
                        var normal = CGPoint(x: (a.y - b.y) / length, y: (b.x - a.x) / length)
                        if normal.y > 0 { normal = CGPoint(x: -normal.x, y: -normal.y) }
                        for sign in [1.0, -1.0] as [CGFloat] {
                            let n = CGPoint(x: normal.x * sign, y: normal.y * sign)
                            let lift = abs(n.x) * w / 2 + abs(n.y) * h / 2 + reach
                            let center = CGPoint(x: point.x + n.x * lift, y: point.y + n.y * lift)
                            let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
                            let edge = CGPoint(x: center.x - n.x * (lift - reach), y: center.y - n.y * (lift - reach))
                            result.append(LabelCandidate(rect: rect, leader: leader ? [point, edge] : nil))
                        }
                    }
                }
            }
        }
        // A chip on the line never hides the arrowhead or the tail; one beside a bundle is tried
        // first led to where its line runs alone.
        return result.flatMap { spot -> [LabelCandidate] in
            if spot.onLine { return spot.rect.insetBy(dx: -12, dy: -12).contains(last) || spot.rect.insetBy(dx: -6, dy: -6).contains(first) ? [] : [spot] }
            guard spot.bundled, spot.leader == nil, let leader = tether(spot.rect) else { return [spot] }
            return [LabelCandidate(rect: spot.rect, leader: leader, tethered: true), spot]
        }
    }

    /// Whether segments a–b and c–d cross at a point inside both (touching ends or running
    /// along each other doesn't count).
    static func properlyIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ p: CGPoint, _ q: CGPoint) -> CGFloat { (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x) }
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        let scale = max(1, hypot(b.x - a.x, b.y - a.y) * hypot(d.x - c.x, d.y - c.y)) * 1e-6
        return ((d1 > scale && d2 < -scale) || (d1 < -scale && d2 > scale)) && ((d3 > scale && d4 < -scale) || (d3 < -scale && d4 > scale))
    }
}
