import CoreGraphics
import Foundation

/// Placement math for `layout.*`: pure functions over sizes and rects, applied to the board by
/// the `Board` extension below in one undo step and one revision.
public enum Layout {
    public enum Side: String, Sendable, CaseIterable { case right, left, above, below }
    public enum Align: String, Sendable, CaseIterable { case start, center, end }
    public enum Direction: String, Sendable, CaseIterable { case row, column }

    public static let defaultGap = 40.0

    /// Origin for a `size` box `gap` away from `anchor` on `side`, aligned along that side
    /// (start: top or left edges line up; end: bottom or right edges).
    public static func place(_ size: CGSize, near anchor: CGRect, side: Side, gap: CGFloat, align: Align) -> CGPoint {
        func along(_ start: CGFloat, _ length: CGFloat, _ extent: CGFloat) -> CGFloat {
            switch align {
            case .start: start
            case .center: start + (length - extent) / 2
            case .end: start + length - extent
            }
        }
        switch side {
        case .right: return CGPoint(x: anchor.maxX + gap, y: along(anchor.minY, anchor.height, size.height))
        case .left: return CGPoint(x: anchor.minX - gap - size.width, y: along(anchor.minY, anchor.height, size.height))
        case .below: return CGPoint(x: along(anchor.minX, anchor.width, size.width), y: anchor.maxY + gap)
        case .above: return CGPoint(x: along(anchor.minX, anchor.width, size.width), y: anchor.minY - gap - size.height)
        }
    }

    /// Origins for boxes laid one after another from `origin`: a row runs right, a column runs
    /// down, `gap` apart. With `wrapAt`, a line that would grow longer than `wrapAt` points
    /// starts a new line (below a row, right of a column) `gap` past the previous line's
    /// thickest box. `align` places each box across its line.
    public static func stack(_ sizes: [CGSize], from origin: CGPoint, direction: Direction, gap: CGFloat, wrapAt: CGFloat? = nil, align: Align = .start) -> [CGPoint] {
        let row = direction == .row
        func main(_ size: CGSize) -> CGFloat { row ? size.width : size.height }
        func cross(_ size: CGSize) -> CGFloat { row ? size.height : size.width }
        // Break into lines first: alignment needs each line's thickness.
        var lines: [[Int]] = [[]]
        var length: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let grown = lines[lines.count - 1].isEmpty ? main(size) : length + gap + main(size)
            if let wrapAt, !lines[lines.count - 1].isEmpty, grown > wrapAt {
                lines.append([index])
                length = main(size)
            } else {
                lines[lines.count - 1].append(index)
                length = grown
            }
        }
        var origins = [CGPoint](repeating: origin, count: sizes.count)
        var crossOffset: CGFloat = 0
        for line in lines where !line.isEmpty {
            let thickness = line.map { cross(sizes[$0]) }.max() ?? 0
            var mainOffset: CGFloat = 0
            for index in line {
                let size = sizes[index]
                let slack = thickness - cross(size)
                let shift = align == .start ? 0 : align == .center ? slack / 2 : slack
                origins[index] = row
                    ? CGPoint(x: origin.x + mainOffset, y: origin.y + crossOffset + shift)
                    : CGPoint(x: origin.x + crossOffset + shift, y: origin.y + mainOffset)
                mainOffset += main(size) + gap
            }
            crossOffset += thickness + gap
        }
        return origins
    }

    /// A grid cell: the box at `row`, `col` (any non-negative numbers; unused numbers take no space).
    public struct GridCell: Equatable, Sendable {
        public var row: Int
        public var col: Int
        public var size: CGSize

        public init(row: Int, col: Int, size: CGSize) {
            self.row = row
            self.col = col
            self.size = size
        }
    }

    /// One column (x, width) or row (y, height) of a grid.
    public struct Track: Equatable, Sendable {
        public var index: Int
        public var start: CGFloat
        public var length: CGFloat

        public init(index: Int, start: CGFloat, length: CGFloat) {
            self.index = index
            self.start = start
            self.length = length
        }
    }

    public struct Grid: Equatable, Sendable {
        /// Each cell's origin, in the order the cells were given.
        public var origins: [CGPoint]
        /// Used columns and rows, ascending.
        public var columns: [Track]
        public var rows: [Track]
    }

    /// Cells in shared columns and rows from `origin`: a column is as wide as its widest cell and
    /// a row as tall as its tallest, `colGap`/`rowGap` apart, so a column lines up across every
    /// row whatever else sits in them. `colAlign` places a cell across its column's width (start:
    /// left edges), `rowAlign` down its row's height (start: top edges).
    public static func grid(_ cells: [GridCell], origin: CGPoint, colGap: CGFloat, rowGap: CGFloat, colAlign: Align = .start, rowAlign: Align = .start) -> Grid {
        func tracks(_ index: (GridCell) -> Int, _ extent: (GridCell) -> CGFloat, from start: CGFloat, gap: CGFloat) -> [Track] {
            var lengths: [Int: CGFloat] = [:]
            for cell in cells { lengths[index(cell)] = max(lengths[index(cell)] ?? 0, extent(cell)) }
            var position = start
            return lengths.keys.sorted().map { key in
                defer { position += lengths[key]! + gap }
                return Track(index: key, start: position, length: lengths[key]!)
            }
        }
        func offset(_ slack: CGFloat, _ align: Align) -> CGFloat {
            align == .start ? 0 : align == .center ? slack / 2 : slack
        }
        let columns = tracks(\.col, \.size.width, from: origin.x, gap: colGap)
        let rows = tracks(\.row, \.size.height, from: origin.y, gap: rowGap)
        let columnAt = Dictionary(uniqueKeysWithValues: columns.map { ($0.index, $0) })
        let rowAt = Dictionary(uniqueKeysWithValues: rows.map { ($0.index, $0) })
        let origins = cells.map { cell -> CGPoint in
            let column = columnAt[cell.col]!, row = rowAt[cell.row]!
            return CGPoint(x: column.start + offset(column.length - cell.size.width, colAlign),
                           y: row.start + offset(row.length - cell.size.height, rowAlign))
        }
        return Grid(origins: origins, columns: columns, rows: rows)
    }

    /// Objects within this many points of each other belong to one cluster for Zoom to Fit.
    public static let clusterMargin: CGFloat = 1500

    /// Groups `frames` into clusters: frames at most `margin` apart (edge to edge) join, and
    /// clusters are transitive. Each cluster lists frame indices ascending; clusters are ordered
    /// by their first index.
    public static func clusters(_ frames: [CGRect], margin: CGFloat = clusterMargin) -> [[Int]] {
        var parent = Array(frames.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        // Each frame grows by half the margin, so two frames `margin` apart just touch. Sweep in
        // x order: a frame only meets later frames that start before it ends.
        let grown = frames.map { $0.insetBy(dx: -margin / 2, dy: -margin / 2) }
        let order = grown.indices.sorted { grown[$0].minX < grown[$1].minX }
        for (position, index) in order.enumerated() {
            let rect = grown[index]
            for other in order[(position + 1)...] {
                let candidate = grown[other]
                if candidate.minX > rect.maxX { break }
                if candidate.minY <= rect.maxY, rect.minY <= candidate.maxY {
                    parent[root(other)] = root(index)
                }
            }
        }
        var members: [Int: [Int]] = [:]
        for index in frames.indices { members[root(index), default: []].append(index) }
        return members.values.sorted { $0[0] < $1[0] }
    }

    /// What Zoom to Fit shows: all of `frames` when their bounds, `padding` added on every side,
    /// fit `viewport` at `minZoom` or closer; otherwise the bounds of the largest cluster (most
    /// frames, then most total area), so a few far-off strays don't shrink the board to nothing.
    /// Nil without frames.
    public static func fitTarget(_ frames: [CGRect], viewport: CGSize, padding: CGFloat, minZoom: CGFloat, margin: CGFloat = clusterMargin) -> CGRect? {
        func bounds(_ indices: some Sequence<Int>) -> CGRect? {
            indices.reduce(nil) { union, index in union?.union(frames[index]) ?? frames[index] }
        }
        guard let all = bounds(frames.indices) else { return nil }
        let zoom = min(viewport.width / (all.width + 2 * padding), viewport.height / (all.height + 2 * padding))
        if zoom >= minZoom { return all }
        func area(_ cluster: [Int]) -> CGFloat { cluster.reduce(0) { $0 + frames[$1].width * frames[$1].height } }
        let largest = clusters(frames, margin: margin).max { lhs, rhs in
            lhs.count != rhs.count ? lhs.count < rhs.count : area(lhs) < area(rhs)
        }
        return largest.flatMap { bounds($0) }
    }

    // MARK: Viewport jumps

    /// Where a viewport jump lands: the zoom, and the document point at the viewport's top-left
    /// corner. Jumps aim at `clear`, the part of the viewport (view points, top-left origin) that
    /// the window's floating chrome (drawing toolbar, tray) leaves uncovered.
    public struct Jump: Equatable, Sendable {
        public var zoom: CGFloat
        public var origin: CGPoint

        public init(zoom: CGFloat, origin: CGPoint) {
            self.zoom = zoom
            self.origin = origin
        }

        /// The document rect `clear` shows at this jump.
        func shown(_ clear: CGRect) -> CGRect {
            CGRect(x: origin.x + clear.minX / zoom, y: origin.y + clear.minY / zoom, width: clear.width / zoom, height: clear.height / zoom)
        }
    }

    /// `rect` with `padding` on every side fitted into `clear` and centered there, the zoom
    /// clamped to `zoom`. With `readable`, a target so tall that fitting it whole would land below
    /// that zoom (a long HTML page, a tall note) fits its width instead and shows its top.
    public static func fit(_ rect: CGRect, in clear: CGRect, padding: CGFloat, zoom limits: ClosedRange<CGFloat>, readable: CGFloat? = nil) -> Jump {
        let padded = rect.insetBy(dx: -padding, dy: -padding)
        func clamp(_ zoom: CGFloat) -> CGFloat { min(limits.upperBound, max(limits.lowerBound, zoom)) }
        let widthZoom = clamp(clear.width / padded.width)
        let whole = clamp(min(widthZoom, clear.height / padded.height))
        if let readable, whole < readable, widthZoom > whole {
            return Jump(zoom: widthZoom, origin: CGPoint(x: padded.midX - clear.midX / widthZoom, y: padded.minY - clear.minY / widthZoom))
        }
        return Jump(zoom: whole, origin: CGPoint(x: padded.midX - clear.midX / whole, y: padded.midY - clear.midY / whole))
    }

    /// `rect` at `zoom`, centered in `clear`; along an axis where it (with `padding`) doesn't fit,
    /// its left or top edge shows instead.
    public static func center(_ rect: CGRect, in clear: CGRect, zoom: CGFloat, padding: CGFloat) -> Jump {
        func axis(_ min: CGFloat, _ mid: CGFloat, _ length: CGFloat, clearMin: CGFloat, clearMid: CGFloat, clearLength: CGFloat) -> CGFloat {
            length + 2 * padding > clearLength / zoom ? min - padding - clearMin / zoom : mid - clearMid / zoom
        }
        return Jump(zoom: zoom, origin: CGPoint(
            x: axis(rect.minX, rect.midX, rect.width, clearMin: clear.minX, clearMid: clear.midX, clearLength: clear.width),
            y: axis(rect.minY, rect.midY, rect.height, clearMin: clear.minY, clearMid: clear.midY, clearLength: clear.height)))
    }

    /// A tray chip's click (`MentionReveal`): `rect` (the mentioned objects, document
    /// coordinates) shown at the zoom the view has, with the least pan, nothing when it is in
    /// view already; the zoom changes only when `rect` can't show whole, and then only down.
    /// `readable`: the mention is a part of a tile (a line, a block) that only a live tile can
    /// scroll to and flash, so below that zoom `rect` is fitted at `readable`…the most instead,
    /// like Go to; at or above it the zoom stays and a tile too big to show whole shows its top
    /// left (the part is revealed inside it next). The zoom never goes past `limits` (100%).
    public static func revealMention(_ rect: CGRect, readable: CGFloat?, from jump: Jump, clear: CGRect, padding: CGFloat, zoom limits: ClosedRange<CGFloat>) -> Jump {
        if let readable, jump.zoom < readable {
            return fit(rect, in: clear, padding: padding, zoom: min(readable, limits.upperBound)...limits.upperBound)
        }
        let shown = jump.shown(clear)
        let padded = rect.insetBy(dx: -padding, dy: -padding)
        if readable != nil || padded.width <= shown.width && padded.height <= shown.height {
            return reveal(rect, from: jump, clear: clear, padding: padding)
        }
        return fit(rect, in: clear, padding: padding, zoom: limits.lowerBound...min(max(jump.zoom, limits.lowerBound), limits.upperBound))
    }

    /// The least pan that brings `rect` (with `padding`) into view clear of the chrome, from a
    /// viewport at `jump`; along an axis where it doesn't fit, its left or top edge shows, or
    /// with `bottomFirst` its bottom edge (a terminal's question sits there), not moving while
    /// that edge is in view. The same `jump` when the rect is already in view.
    public static func reveal(_ rect: CGRect, from jump: Jump, clear: CGRect, padding: CGFloat, bottomFirst: Bool = false) -> Jump {
        let shown = jump.shown(clear)
        let target = rect.insetBy(dx: -padding, dy: -padding)
        func shift(_ min: CGFloat, _ max: CGFloat, shownMin: CGFloat, shownMax: CGFloat, endFirst: Bool = false) -> CGFloat {
            if max - min > shownMax - shownMin, endFirst { return (shownMin...shownMax).contains(max) ? 0 : max - shownMax }
            if max - min > shownMax - shownMin || min < shownMin { return min - shownMin }
            return max > shownMax ? max - shownMax : 0
        }
        return Jump(zoom: jump.zoom, origin: CGPoint(x: jump.origin.x + shift(target.minX, target.maxX, shownMin: shown.minX, shownMax: shown.maxX),
                                                     y: jump.origin.y + shift(target.minY, target.maxY, shownMin: shown.minY, shownMax: shown.maxY, endFirst: bottomFirst)))
    }

    /// `reveal`, keeping what shows of `kept` (the tile something was opened from) in view too
    /// when both fit, with the padding cut down to what room is left (a code tile opened beside
    /// a changes tile that together just fit shows both whole); otherwise `rect` alone.
    public static func reveal(_ rect: CGRect, keeping kept: CGRect, from jump: Jump, clear: CGRect, padding: CGFloat) -> Jump {
        let shown = jump.shown(clear)
        let visible = kept.intersection(shown)
        guard !visible.isNull, !visible.isEmpty else { return reveal(rect, from: jump, clear: clear, padding: padding) }
        let both = rect.union(visible)
        guard both.width <= shown.width, both.height <= shown.height else { return reveal(rect, from: jump, clear: clear, padding: padding) }
        let room = min(padding, (shown.width - both.width) / 2, (shown.height - both.height) / 2)
        return reveal(both, from: jump, clear: clear, padding: room)
    }

    /// A tile opened from `source` (a ⌘-clicked reference, in document coordinates): no pan
    /// while at least half of `rect` shows clear of the chrome; otherwise `reveal`'s least pan,
    /// cut short where it would take `source` out of view.
    public static func reveal(_ rect: CGRect, from jump: Jump, clear: CGRect, padding: CGFloat, openedFrom source: CGRect) -> Jump {
        let shown = jump.shown(clear)
        let visible = rect.intersection(shown)
        if !visible.isNull, visible.width * visible.height >= rect.width * rect.height / 2 { return jump }
        let full = reveal(rect, from: jump, clear: clear, padding: padding)
        guard !source.isNull, !source.isEmpty else { return full }
        func clamp(_ shift: CGFloat, _ sourceMin: CGFloat, _ sourceMax: CGFloat, _ shownMin: CGFloat, _ shownMax: CGFloat) -> CGFloat {
            // The shifts that keep the source wholly in view (none when it isn't now).
            let lower = min(0, sourceMax - shownMax), upper = max(0, sourceMin - shownMin)
            return min(max(shift, lower), upper)
        }
        return Jump(zoom: jump.zoom, origin: CGPoint(
            x: jump.origin.x + clamp(full.origin.x - jump.origin.x, source.minX, source.maxX, shown.minX, shown.maxX),
            y: jump.origin.y + clamp(full.origin.y - jump.origin.y, source.minY, source.maxY, shown.minY, shown.maxY)))
    }

    /// A diagram tile the user just grew by opening a node: the least pan that shows the whole
    /// `tile` (with `padding`) when it fits in view at this zoom; else the least pan that shows
    /// the `added` nodes together with the `clicked` one when those fit; else the least pan
    /// toward the added nodes' left and top edges (with `padding`), cut short where it would take the clicked
    /// node out of view (when it is in view now). Never a zoom; the same `jump` when nothing
    /// needs to move.
    public static func revealGrown(_ tile: CGRect, added: CGRect, clicked: CGRect, from jump: Jump, clear: CGRect, padding: CGFloat) -> Jump {
        let shown = jump.shown(clear)
        func fits(_ rect: CGRect, _ room: CGFloat) -> Bool { rect.width + 2 * room <= shown.width && rect.height + 2 * room <= shown.height }
        if fits(tile, padding) { return reveal(tile, from: jump, clear: clear, padding: padding) }
        guard !added.isNull, !added.isEmpty else { return reveal(clicked, from: jump, clear: clear, padding: 0) }
        let both = added.union(clicked)
        if fits(both, 0) {
            let room = min(padding, (shown.width - both.width) / 2, (shown.height - both.height) / 2)
            return reveal(both, from: jump, clear: clear, padding: room)
        }
        let full = reveal(added, from: jump, clear: clear, padding: padding)
        guard shown.contains(clicked) else { return full }
        func clamp(_ shift: CGFloat, _ keptMin: CGFloat, _ keptMax: CGFloat, _ shownMin: CGFloat, _ shownMax: CGFloat) -> CGFloat {
            min(max(shift, keptMax - shownMax), keptMin - shownMin)
        }
        return Jump(zoom: jump.zoom, origin: CGPoint(
            x: jump.origin.x + clamp(full.origin.x - jump.origin.x, clicked.minX, clicked.maxX, shown.minX, shown.maxX),
            y: jump.origin.y + clamp(full.origin.y - jump.origin.y, clicked.minY, clicked.maxY, shown.minY, shown.maxY)))
    }

    /// A stop stepped to (⌥⌘-arrows), like a slide advance: nothing moves while `rect` with
    /// `padding` shows whole; else it is centered at this zoom, or, when it doesn't fit at this
    /// zoom, fitted (`fit`, `readable` for a tall one) so the audience sees the one stop rather
    /// than half of the last one beside the least pan.
    public static func present(_ rect: CGRect, from jump: Jump, clear: CGRect, padding: CGFloat, zoom limits: ClosedRange<CGFloat>, readable: CGFloat? = nil) -> Jump {
        let zoom = jump.zoom, shown = jump.shown(clear)
        let padded = rect.insetBy(dx: -padding, dy: -padding)
        if shown.contains(padded) { return jump }
        guard padded.width <= shown.width, padded.height <= shown.height else {
            return fit(rect, in: clear, padding: padding, zoom: limits.lowerBound...min(limits.upperBound, zoom), readable: readable)
        }
        return center(rect, in: clear, zoom: zoom, padding: padding)
    }

    /// A walkthrough's stop (`StepOrder`) stepped to: `present`, except that a view zoomed out
    /// below `readable` (the overview a walkthrough is often started from) fits the stop instead,
    /// with `fitPadding` and up to `limits`' top (`fit`, `readable` for a tall one), so each step
    /// reads like a slide. From a readable zoom the presenter's zoom stays.
    public static func presentStop(_ rect: CGRect, from jump: Jump, clear: CGRect, padding: CGFloat, fitPadding: CGFloat, zoom limits: ClosedRange<CGFloat>, readable: CGFloat) -> Jump {
        guard jump.zoom < readable else { return present(rect, from: jump, clear: clear, padding: padding, zoom: limits, readable: readable) }
        return fit(rect, in: clear, padding: fitPadding, zoom: limits, readable: readable)
    }

    /// Keyboard zoom levels (⌘= / ⌘-), browser-like: fine steps near 100%, coarse far out.
    public static let zoomLevels: [CGFloat] = [0.1, 0.15, 0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 3, 4]

    /// The next keyboard zoom level above (`in`) or below `zoom` within `limits`: the nearest
    /// level past it (a zoom already within a hair of a level counts as on it), else the limit
    /// itself; `zoom` clamped when it's at the limit already.
    public static func zoomStep(from zoom: CGFloat, in zoomIn: Bool, limits: ClosedRange<CGFloat>) -> CGFloat {
        let tolerance: CGFloat = 0.005
        let levels = zoomLevels.filter(limits.contains)
        let next = zoomIn ? levels.first { $0 > zoom + tolerance } : levels.last { $0 < zoom - tolerance }
        return min(limits.upperBound, max(limits.lowerBound, next ?? (zoomIn ? limits.upperBound : limits.lowerBound)))
    }

    public enum Heading: String, Sendable, CaseIterable {
        case left, right, up, down

        public var opposite: Heading {
            switch self {
            case .left: .right
            case .right: .left
            case .up: .down
            case .down: .up
            }
        }
    }

    /// The index of the frame nearest `from` toward `heading` (⌥⌘-arrow between tiles), among
    /// frames whose center lies past `from`'s center that way and that start past its near edge.
    /// Frames in line with `from` come first: those overlapping its span across the heading by at
    /// least a quarter of the narrower of the two spans (a tile below that shares a column, not
    /// one to the side reaching a little way down), nearest by the gap along the heading, then by
    /// center. Only when none is in line: the least gap along the heading plus twice the gap
    /// across it (a tile in the same row or column wins over a nearer diagonal one), then the
    /// nearest center. Nil when none lies that way.
    public static func neighbor(of from: CGRect, among frames: [CGRect], toward heading: Heading) -> Int? {
        frames.indices.compactMap { index in neighborKey(from, frames[index], heading).map { (index, $0) } }
            .min { precedes($0.1, $1.1) }?.0
    }

    /// The tile the selection goes to when the selected one closes (⌘W keeps going): the best
    /// neighbor in any direction by `neighbor`'s ranking (in line first, then the least gap),
    /// else, among tiles no heading reaches (overlapping it), the nearest center. Nil when
    /// `frames` is empty.
    public static func nearest(to from: CGRect, among frames: [CGRect]) -> Int? {
        let ranked = frames.indices.compactMap { index in
            Heading.allCases.compactMap { neighborKey(from, frames[index], $0) }.min(by: precedes).map { (index, $0) }
        }
        if let best = ranked.min(by: { precedes($0.1, $1.1) }) { return best.0 }
        return frames.indices.min { hypot(frames[$0].midX - from.midX, frames[$0].midY - from.midY) < hypot(frames[$1].midX - from.midX, frames[$1].midY - from.midY) }
    }

    private typealias NeighborKey = (inLine: Bool, score: CGFloat, distance: CGFloat)

    private static func precedes(_ l: NeighborKey, _ r: NeighborKey) -> Bool {
        if l.inLine != r.inLine { return l.inLine }
        return (l.score, l.distance) < (r.score, r.distance)
    }

    private static func neighborKey(_ from: CGRect, _ frame: CGRect, _ heading: Heading) -> NeighborKey? {
        let along: CGFloat, ahead: Bool
        let horizontal = heading == .left || heading == .right
        switch heading {
        case .right:
            ahead = frame.midX > from.midX && frame.minX > from.minX
            along = max(0, frame.minX - from.maxX)
        case .left:
            ahead = frame.midX < from.midX && frame.maxX < from.maxX
            along = max(0, from.minX - frame.maxX)
        case .down:
            ahead = frame.midY > from.midY && frame.minY > from.minY
            along = max(0, frame.minY - from.maxY)
        case .up:
            ahead = frame.midY < from.midY && frame.maxY < from.maxY
            along = max(0, from.minY - frame.maxY)
        }
        guard ahead else { return nil }
        let (fromStart, fromEnd, start, end) = horizontal ? (from.minY, from.maxY, frame.minY, frame.maxY) : (from.minX, from.maxX, frame.minX, frame.maxX)
        let across = max(0, start - fromEnd, fromStart - end)
        let overlap = min(fromEnd, end) - max(fromStart, start)
        let inLine = overlap > 0 && overlap >= min(fromEnd - fromStart, end - start) / 4
        let distance = hypot(frame.midX - from.midX, frame.midY - from.midY)
        return (inLine, inLine ? along : along + 2 * across, distance)
    }
}

extension Layout {
    /// Where an object refitted from `current` to `size` goes without covering anything new:
    /// grown from its top-left corner (the usual refit), else from its top-right, bottom-left, or
    /// bottom-right corner (growing left, up, or both), the first that overlaps none of
    /// `neighbours` that `current` didn't already overlap. Nil when every corner does.
    public static func refit(_ current: Frame, to size: CGSize, clearOf neighbours: [Frame]) -> Frame? {
        let fresh = neighbours.filter { !$0.intersects(current) }
        let left = current.x, right = current.maxX - size.width
        let top = current.y, bottom = current.maxY - size.height
        for (x, y) in [(left, top), (right, top), (left, bottom), (right, bottom)] {
            let frame = Frame(x: x, y: y, w: size.width, h: size.height)
            if !fresh.contains(where: { $0.intersects(frame) }) { return frame }
        }
        return nil
    }
}

/// ⌥⌘-arrow moves between tiles, reversible: the opposite arrow right after a move goes back to
/// the tile it came from (up then down returns, even when another tile is the nearer one below),
/// and a run of moves unwinds the same way. Any other start (a click, Go to, nothing selected)
/// forgets the trail.
public struct TileWalk: Sendable {
    private struct Move: Sendable {
        var from: ObjectID
        var to: ObjectID
        var heading: Layout.Heading
    }

    private var trail: [Move] = []
    private static let limit = 64

    public init() {}

    /// The tile a move toward `heading` goes to from `source` (whose frame, or the viewport
    /// center without one, is `from`), among `tiles` (the source not included); nil when none
    /// lies that way.
    public mutating func step(from source: ObjectID?, frame from: CGRect, toward heading: Layout.Heading,
                              among tiles: [(id: ObjectID, frame: CGRect)]) -> ObjectID? {
        if let last = trail.last, let source, last.to == source {
            if last.heading == heading.opposite, tiles.contains(where: { $0.id == last.from }) {
                trail.removeLast()
                return last.from
            }
        } else {
            trail.removeAll()
        }
        guard let index = Layout.neighbor(of: from, among: tiles.map(\.frame), toward: heading) else { return nil }
        let target = tiles[index].id
        if let source {
            trail.append(Move(from: source, to: target, heading: heading))
            if trail.count > Self.limit { trail.removeFirst() }
        }
        return target
    }
}

/// One code tile of an excerpt layout (`Board.openExcerpts`): a range of a file, captioned, at
/// its measured size.
public struct CodeExcerpt: Sendable, Equatable {
    public var path: String
    public var lines: LineRange
    public var caption: String?
    public var size: CGSize

    public init(path: String, lines: LineRange, caption: String?, size: CGSize) {
        self.path = path
        self.lines = lines
        self.caption = caption
        self.size = size
    }
}

extension Board {
    /// Code tiles for `excerpts` in a group titled `title` beside `anchor`, like an editor's
    /// multibuffer (Find References → Open All): stacked top to bottom in order, `gap` apart,
    /// a new column right of the last once one grows past `columnHeight`; the group takes the
    /// free slot nearest `anchor` (`place(near:)`). One undo step.
    @discardableResult
    public func openExcerpts(_ excerpts: [CodeExcerpt], title: String, beside anchor: ObjectID, gap: Double = Board.placementGap,
                             columnHeight: Double = 2400, caller: ObjectID? = nil) throws -> (group: ObjectID, tiles: [ObjectID]) {
        guard !excerpts.isEmpty else { throw BoardError.invalidParams("no excerpts") }
        _ = try object(anchor)
        let origins = Layout.stack(excerpts.map(\.size), from: .zero, direction: .column, gap: CGFloat(gap), wrapAt: CGFloat(columnHeight))
        let rects = zip(origins, excerpts).map { CGRect(origin: $0, size: $1.size) }
        let spec = GroupSpec(.object(["members": .array([])]))!
        let bounds = spec.frame(around: rects)!
        let slot = place(width: Double(bounds.width), height: Double(bounds.height), near: anchor)
        let dx = slot.x - Double(bounds.minX), dy = slot.y - Double(bounds.minY)
        return try atomically {
            let tiles = zip(excerpts, rects).map { excerpt, rect in
                var props: [String: JSONValue] = ["path": .string(excerpt.path), "range": excerpt.lines.json]
                if let caption = excerpt.caption { props["caption"] = .string(caption) }
                return create(type: .code, props: .object(props), frame: Frame(x: Double(rect.minX) + dx, y: Double(rect.minY) + dy, w: Double(rect.width), h: Double(rect.height)), caller: caller).id
            }
            let group = create(type: .group, props: .object(["members": .array(tiles.map(JSONValue.string)), "title": .string(title)]), caller: caller)
            return (group.id, tiles)
        }
    }

    /// Moves `id` `gap` beside `anchor`; one undo step. Groups move their members.
    @discardableResult
    public func place(_ id: ObjectID, near anchor: ObjectID, side: Layout.Side, gap: Double = Layout.defaultGap, align: Layout.Align = .start, caller: ObjectID? = nil) throws -> [ObjectID: Frame] {
        let moving = try object(id)
        let target = try object(anchor)
        guard id != anchor else { throw BoardError.invalidParams("an object can't be placed beside itself") }
        let origin = Layout.place(moving.frame.rect.size, near: target.frame.rect, side: side, gap: CGFloat(gap), align: align)
        return try shift([(id, origin.x - moving.frame.x, origin.y - moving.frame.y)], caller: caller)
    }

    /// Lays `ids` out in a row or column starting where the first one is (or at `origin`); one
    /// undo step. Groups move their members.
    @discardableResult
    public func stack(_ ids: [ObjectID], direction: Layout.Direction, gap: Double = Layout.defaultGap, wrapAt: Double? = nil, align: Layout.Align = .start, origin: CGPoint? = nil, caller: ObjectID? = nil) throws -> [ObjectID: Frame] {
        guard !ids.isEmpty else { return [:] }
        guard Set(ids).count == ids.count else { throw BoardError.invalidParams("ids repeat") }
        let frames = try ids.map { try object($0).frame.rect }
        let start = origin ?? frames[0].origin
        let origins = Layout.stack(frames.map(\.size), from: start, direction: direction, gap: CGFloat(gap), wrapAt: wrapAt.map { CGFloat($0) }, align: align)
        return try shift(zip(ids, zip(frames, origins)).map { (id: $0, dx: Double($1.1.x - $1.0.minX), dy: Double($1.1.y - $1.0.minY)) }, caller: caller)
    }

    /// Moves `ids` by (dx, dy) in one undo step. Groups move their members (a member listed
    /// beside its group moves once); arrows carry their free ends, and bound ends follow.
    @discardableResult
    public func translate(_ ids: [ObjectID], dx: Double, dy: Double, caller: ObjectID? = nil) throws -> [ObjectID: Frame] {
        guard !ids.isEmpty else { return [:] }
        return try shift(ids.map { ($0, dx, dy) }, caller: caller)
    }

    /// Places `cells` in shared columns and rows (`Layout.grid`, sized by the cells' current
    /// frames) from `origin`, default the cells' current top-left; one undo step. Groups move
    /// their members.
    public func grid(_ cells: [(id: ObjectID, row: Int, col: Int)], colGap: Double = Layout.defaultGap, rowGap: Double = Layout.defaultGap, colAlign: Layout.Align = .start,
                     rowAlign: Layout.Align = .start, origin: CGPoint? = nil, caller: ObjectID? = nil) throws -> (frames: [ObjectID: Frame], grid: Layout.Grid) {
        guard !cells.isEmpty else { throw BoardError.invalidParams("cells must not be empty") }
        guard Set(cells.map(\.id)).count == cells.count else { throw BoardError.invalidParams("cell ids repeat") }
        var taken: Set<[Int]> = []
        for cell in cells {
            guard cell.row >= 0, cell.col >= 0 else { throw BoardError.invalidParams("cell \(cell.id): row and col must be non-negative") }
            guard taken.insert([cell.row, cell.col]).inserted else { throw BoardError.invalidParams("two cells at row \(cell.row), col \(cell.col)") }
        }
        let frames = try cells.map { try object($0.id).frame.rect }
        let start = origin ?? CGPoint(x: frames.map(\.minX).min()!, y: frames.map(\.minY).min()!)
        let grid = Layout.grid(zip(cells, frames).map { Layout.GridCell(row: $0.row, col: $0.col, size: $1.size) }, origin: start,
                               colGap: CGFloat(colGap), rowGap: CGFloat(rowGap), colAlign: colAlign, rowAlign: rowAlign)
        let moves = zip(cells, zip(frames, grid.origins)).map { (id: $0.id, dx: Double($1.1.x - $1.0.minX), dy: Double($1.1.y - $1.0.minY)) }
        return (try shift(moves, caller: caller), grid)
    }

    /// Moves each object by its offset as one undo step and one revision, then returns the
    /// objects' frames. A group moves its members (nested groups' too) and is re-fit once, after
    /// every member moved; an object reached twice with the same offset (a member listed beside
    /// its group) moves once, with different offsets it is an error. Arrows carry free ends.
    private func shift(_ moves: [(id: ObjectID, dx: Double, dy: Double)], caller: ObjectID?) throws -> [ObjectID: Frame] {
        var offsets: [ObjectID: (dx: Double, dy: Double)] = [:]
        var order: [ObjectID] = []
        for move in moves {
            let object = try object(move.id)
            for target in object.type == .group ? BoardGeometry.leafMembers(of: move.id, in: objects) : [move.id] {
                if let earlier = offsets[target] {
                    guard earlier == (move.dx, move.dy) else {
                        throw BoardError.invalidParams("\(target) would move twice: \(move.id) and a group containing it are both listed")
                    }
                    continue
                }
                offsets[target] = (move.dx, move.dy)
                order.append(target)
            }
        }
        return try atomically {
            try deferringRefits {
                for target in order {
                    let (dx, dy) = offsets[target]!
                    guard dx != 0 || dy != 0 else { continue }
                    let current = try object(target)
                    var frame = current.frame
                    frame.x += dx
                    frame.y += dy
                    let props = current.type == .arrow ? ArrowSpec(current.props)?.translated(dx: dx, dy: dy).props : nil
                    try update(target, frame: frame, props: props, caller: caller)
                }
            }
            return try Dictionary(moves.map { ($0.id, try object($0.id).frame) }, uniquingKeysWith: { first, _ in first })
        }
    }
}

extension ArrowSpec {
    /// Free ends moved by (dx, dy); bound ends follow their objects anyway.
    public func translated(dx: Double, dy: Double) -> ArrowSpec {
        func moved(_ binding: ArrowBinding) -> ArrowBinding {
            guard case .point(let point) = binding else { return binding }
            return .point(CGPoint(x: point.x + dx, y: point.y + dy))
        }
        var spec = self
        spec.from = moved(from)
        spec.to = moved(to)
        return spec
    }
}

// MARK: Checks

extension BoardGeometry {
    public struct LayoutReport: Equatable, Sendable {
        /// Pairs (sorted ids) whose frames overlap by accident.
        public var overlaps: [[ObjectID]]
        /// Arrows whose route runs through objects other than their own ends.
        public var crossings: [Crossing]
        /// Arrows whose label lies on a tile, text, or filled shape (their own ends included), a
        /// group's title, another arrow's label, or another arrow's line.
        public var labelOverlaps: [LabelOverlap]
        /// Pairs of arrows drawn on top of each other along some length.
        public var arrowOverlaps: [ConnectorRouter.Overlap]
        /// Pairs of arrows whose lines cross.
        public var arrowIntersections: [ConnectorRouter.Intersection]
        /// Advice that isn't a fault: more than `sameColorLimit` labelled arrows all one color,
        /// where a label chip (outlined in its arrow's color) can't show which line it names.
        public var hints: [String] = []
    }

    /// Labelled arrows past which one shared color gets a hint to color them by lane or flow.
    public static let sameColorLimit = 6

    public struct Crossing: Equatable, Sendable {
        public var arrow: ObjectID
        public var crosses: [ObjectID]
    }

    public struct LabelOverlap: Equatable, Sendable {
        public var arrow: ObjectID
        /// The caption as drawn (`label`, else `relation`).
        public var label: String
        /// Where the label chip is drawn; an arrow's own `frame` doesn't include it.
        public var frame: Frame
        /// Objects under the label; an arrow id means that arrow's label, a group id its title.
        public var overlaps: [ObjectID]
        /// Other arrows whose line runs under the label.
        public var lines: [ObjectID]
    }

    /// Whether an object can overlap others by accident: not arrows, ink, or unfilled rects and
    /// ellipses (annotations drawn over or around things).
    public static func countsForOverlaps(_ object: CanvasObject) -> Bool {
        switch object.type {
        case .arrow: return false
        case .shape:
            guard let spec = ShapeSpec(object.props) else { return true }
            return spec.kind != .ink && !((spec.kind == .rect || spec.kind == .ellipse) && spec.fill == .none)
        default: return true
        }
    }

    /// Pairs (sorted ids) of objects that overlap by accident, involving `scope` (every object
    /// when nil): `countsForOverlaps` objects, a group and its (nested) members never.
    public func overlaps(scope: Set<ObjectID>? = nil) -> [[ObjectID]] {
        let solid = objects.values.filter(Self.countsForOverlaps)
        var groupMembers: [ObjectID: Set<ObjectID>] = [:]
        func members(of group: CanvasObject) -> Set<ObjectID> {
            if let cached = groupMembers[group.id] { return cached }
            var all = Set(Self.leafMembers(of: group.id, in: objects))
            var queue = [group.id]
            while let next = queue.popLast() {
                for member in GroupSpec(objects[next]?.props ?? .null)?.members ?? [] where objects[member]?.type == .group && !all.contains(member) {
                    all.insert(member)
                    queue.append(member)
                }
            }
            groupMembers[group.id] = all
            return all
        }
        func separate(_ a: CanvasObject, _ b: CanvasObject) -> Bool {
            (a.type == .group && members(of: a).contains(b.id)) || (b.type == .group && members(of: b).contains(a.id))
        }
        var overlaps: [[ObjectID]] = []
        if let scope {
            // Only pairs with a scoped object (a write's response checks one object: the
            // board's other pairs are never looked at).
            var found: Set<[ObjectID]> = []
            for a in solid where scope.contains(a.id) {
                for b in solid where b.id != a.id && a.frame.intersects(b.frame) && !separate(a, b) {
                    found.insert(a.id < b.id ? [a.id, b.id] : [b.id, a.id])
                }
            }
            return found.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }
        }
        let sorted = solid.sorted { $0.id < $1.id }
        for (index, a) in sorted.enumerated() {
            for b in sorted[(index + 1)...] where a.frame.intersects(b.frame) && !separate(a, b) {
                overlaps.append([a.id, b.id])
            }
        }
        return overlaps
    }

    /// Overlaps, arrow crossings, label overlaps, and arrows overlapping or crossing each other,
    /// involving `scope` (every object when nil): an arrow crossing or a label lying on a scoped
    /// object is reported whether or not the arrow is in scope, so checking a new tile finds the
    /// labels it covers.
    /// Not overlaps: a group and its (nested) members, and anything with an unfilled rect or
    /// ellipse (an annotation drawn over or around things, like ink). Arrow routes and labels
    /// are computed as drawn (`routing`: offsets, the board's `avoid` routing, line-bound ends
    /// with `rows`, label placement); an arrow never crosses its own ends or what contains them.
    public func layoutCheck(scope: Set<ObjectID>? = nil, rows: [ObjectID: CodeRows] = [:]) -> LayoutReport {
        func involved(_ arrow: ObjectID, _ others: [ObjectID]) -> Bool {
            scope == nil || scope!.contains(arrow) || others.contains { scope!.contains($0) }
        }
        let overlaps = overlaps(scope: scope)
        let routing = routing(rows: rows)
        let routes = routing.paths
        let blockers = objects.values.filter(Self.blocksRoutes).sorted { $0.id < $1.id }
        var crossings: [Crossing] = []
        for (arrowID, path) in routes.sorted(by: { $0.key < $1.key }) {
            guard let spec = objects[arrowID].flatMap({ ArrowSpec($0.props) }) else { continue }
            var endRects: [CGRect] = []
            var endIDs: Set<ObjectID> = []
            for binding in [spec.from, spec.to] {
                if let id = binding.objectID {
                    endIDs.insert(id)
                    if let frame = objects[id]?.frame.rect { endRects.append(frame) }
                } else if case .point(let point) = binding {
                    endRects.append(CGRect(origin: point, size: .zero))
                }
            }
            let crossed = blockers.filter { blocker in
                let rect = blocker.frame.rect
                guard !endIDs.contains(blocker.id), !endRects.contains(where: { $0.size == .zero ? rect.contains($0.origin) : rect.contains($0) }) else { return false }
                return DrawingGeometry.path(path, crosses: rect)
            }.map(\.id)
            if !crossed.isEmpty, involved(arrowID, crossed) { crossings.append(Crossing(arrow: arrowID, crosses: crossed)) }
        }
        let titles = regions.map { ($0.id, $0.title) }
        let labels = routing.labels.mapValues(\.rect)
        var labelOverlaps: [LabelOverlap] = []
        for (arrowID, label) in labels.sorted(by: { $0.key < $1.key }) {
            let inner = label.insetBy(dx: 0.5, dy: 0.5)
            let under = blockers.filter { $0.frame.rect.intersects(inner) }.map(\.id)
                + titles.filter { $0.1.intersects(inner) }.map(\.0)
                + labels.filter { $0.key != arrowID && $0.value.intersects(inner) }.map(\.key).sorted()
            let lines = routes.filter { $0.key != arrowID && zip($0.value, $0.value.dropFirst()).contains { DrawingGeometry.segment($0, $1, intersects: inner) } }.map(\.key).sorted()
            guard !under.isEmpty || !lines.isEmpty, involved(arrowID, under + lines), let spec = objects[arrowID].flatMap({ ArrowSpec($0.props) }) else { continue }
            labelOverlaps.append(LabelOverlap(arrow: arrowID, label: spec.label ?? spec.relation ?? "", frame: Frame(label), overlaps: under, lines: lines))
        }
        let arrowOverlaps = ConnectorRouter.overlaps(routes).filter { involved($0.arrows[0], [$0.arrows[1]]) }
        let arrowIntersections = ConnectorRouter.intersections(routes).filter { involved($0.arrows[0], [$0.arrows[1]]) }
        var hints: [String] = []
        // Arrows drawn with a caption (`label`, else `relation`), as `DrawingStyle.arrowLabel`.
        let labelled = objects.values.compactMap { object -> ArrowSpec? in
            guard object.type == .arrow, let spec = ArrowSpec(object.props), !(spec.label ?? spec.relation ?? "").isEmpty,
                  involved(object.id, [spec.from.objectID, spec.to.objectID].compactMap { $0 }) else { return nil }
            return spec
        }
        let colors = Set(labelled.map { $0.color?.lowercased() ?? "black" })
        if labelled.count > Self.sameColorLimit, colors.count == 1, let color = colors.first {
            hints.append("\(labelled.count) labelled arrows are all \(color): color them by lane or flow (props.color, e.g. blue for the request path, green for replies) so each label reads with its own line")
        }
        return LayoutReport(overlaps: overlaps, crossings: crossings, labelOverlaps: labelOverlaps, arrowOverlaps: arrowOverlaps,
                            arrowIntersections: arrowIntersections, hints: hints)
    }
}
