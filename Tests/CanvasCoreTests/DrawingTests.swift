import CoreGraphics
import Foundation
import Testing
import CanvasCore

struct ArrowRoutingTests {
    typealias G = DrawingGeometry
    let gap = DrawingGeometry.arrowGap

    @Test func sideBySideObjectsConnectFacingEdgesThroughTheirOverlap() {
        let a = CGRect(x: 0, y: 0, width: 200, height: 100)
        let b = CGRect(x: 400, y: 20, width: 200, height: 100)
        let route = G.route(from: .bound(.rect(a)), to: .bound(.rect(b)))
        // Vertical extents overlap on 20…100, so the arrow runs flat through y = 60.
        #expect(route.start == CGPoint(x: a.maxX + gap, y: 60))
        #expect(route.end == CGPoint(x: b.minX - gap, y: 60))
    }

    @Test func movingABoundObjectReroutesToTheNewNearestEdges() {
        let a = CGRect(x: 0, y: 0, width: 200, height: 100)
        let before = G.route(from: .bound(.rect(a)), to: .bound(.rect(CGRect(x: 400, y: 0, width: 200, height: 100))))
        let moved = CGRect(x: 50, y: 300, width: 200, height: 100)
        let after = G.route(from: .bound(.rect(a)), to: .bound(.rect(moved)))
        #expect(before.start.x == a.maxX + gap, "right edge while b is to the right")
        // Now stacked with horizontal overlap 50…200: bottom edge of a to top edge of b.
        #expect(after.start == CGPoint(x: 125, y: a.maxY + gap))
        #expect(after.end == CGPoint(x: 125, y: moved.minY - gap))
    }

    @Test func diagonalObjectsAimCenterToCenterAndStayOutsideBothOutlines() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 300, y: 250, width: 100, height: 100)
        let route = G.route(from: .bound(.rect(a)), to: .bound(.rect(b)))
        #expect(!a.contains(route.start) && !b.contains(route.start))
        #expect(!a.contains(route.end) && !b.contains(route.end))
        // Each tip sits `gap` beyond its outline.
        #expect(abs(G.distanceToSegment(route.start, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)) - gap) < 0.5
            || abs(G.distanceToSegment(route.start, CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100)) - gap) < 0.5)
        #expect(route.start.x > a.midX && route.start.y > a.midY, "leaves from the corner facing b")
        #expect(route.end.x < b.midX && route.end.y < b.midY)
    }

    @Test func ellipseOutlinesAttachOnTheCurveNotTheBoundingBox() {
        let circle = CGRect(x: 0, y: 0, width: 100, height: 100)
        let route = G.route(from: .bound(.ellipse(circle)), to: .point(CGPoint(x: 300, y: 300)))
        let center = CGPoint(x: 50, y: 50)
        #expect(abs(hypot(route.start.x - center.x, route.start.y - center.y) - (50 + gap)) < 0.01)
        #expect(route.end == CGPoint(x: 300, y: 300), "free ends stay exactly where they were put")
    }
}

struct DrawingHitTests {
    typealias G = DrawingGeometry
    let frame = CGRect(x: 100, y: 100, width: 200, height: 120)

    @Test func unfilledRectHitsOnItsStrokeButPassesThroughItsInterior() {
        let rect = ShapeSpec(kind: .rect)
        #expect(G.hits(rect, frame: frame, at: CGPoint(x: 200, y: 101), tolerance: 4))
        #expect(G.hits(rect, frame: frame, at: CGPoint(x: 305, y: 160), tolerance: 4), "just outside the edge, within tolerance")
        #expect(!G.hits(rect, frame: frame, at: CGPoint(x: 200, y: 160), tolerance: 4), "empty interior must not block tiles beneath")
        #expect(!G.hits(rect, frame: frame, at: CGPoint(x: 330, y: 160), tolerance: 4))
    }

    @Test func filledShapesHitInside() {
        #expect(G.hits(ShapeSpec(kind: .rect, fill: .semi), frame: frame, at: CGPoint(x: 200, y: 160), tolerance: 4))
        #expect(G.hits(ShapeSpec(kind: .ellipse, fill: .solid), frame: frame, at: CGPoint(x: 200, y: 160), tolerance: 4))
        // The ellipse's bounding-box corner is outside its fill.
        #expect(!G.hits(ShapeSpec(kind: .ellipse, fill: .solid), frame: frame, at: CGPoint(x: 110, y: 110), tolerance: 4))
    }

    @Test func unfilledEllipseHitsOnlyNearItsCurve() {
        let ellipse = ShapeSpec(kind: .ellipse)
        #expect(G.hits(ellipse, frame: frame, at: CGPoint(x: 300, y: 160), tolerance: 4), "right extreme of the curve")
        #expect(G.hits(ellipse, frame: frame, at: CGPoint(x: 200, y: 98), tolerance: 4), "top extreme, just outside")
        #expect(!G.hits(ellipse, frame: frame, at: CGPoint(x: 200, y: 160), tolerance: 4))
        #expect(!G.hits(ellipse, frame: frame, at: CGPoint(x: 105, y: 105), tolerance: 4), "bounding-box corner is empty space")
    }

    @Test func labelsAndTextHitAnywhereInTheirBounds() {
        let rect = ShapeSpec(kind: .rect, text: "auth path?")
        let label = CGRect(x: 160, y: 150, width: 80, height: 20)
        #expect(G.hits(rect, frame: frame, at: CGPoint(x: 200, y: 160), tolerance: 4, labelRect: label))
        #expect(G.hits(ShapeSpec(kind: .text, text: "note"), frame: frame, at: CGPoint(x: 200, y: 160), tolerance: 4))
    }

    func inkHits(_ points: [InkPoint], at point: CGPoint) -> Bool {
        let ink = ShapeSpec(kind: .ink, points: points)
        return G.hits(ink, frame: .zero, at: point, tolerance: 4, inkOutline: DrawingInk.outline(points))
    }

    @Test func inkHitsAlongItsPathOnly() {
        let points = (0...20).map { InkPoint(x: Double($0) * 10, y: 0) }
        #expect(inkHits(points, at: CGPoint(x: 150, y: 4)))
        #expect(!inkHits(points, at: CGPoint(x: 150, y: 30)))
    }

    @Test func inkHitsWhereTheSmoothedStrokeIsPaintedNotAtRawInputCorners() {
        // Streamlining pulls the middle input point to (57.5, 0): the painted stroke cuts the
        // corner diagonally toward (100, 100) and never reaches (100, 0).
        let points = [InkPoint(x: 0, y: 0), InkPoint(x: 100, y: 0), InkPoint(x: 100, y: 100)]
        #expect(inkHits(points, at: CGPoint(x: 78.75, y: 50)), "on the painted diagonal")
        #expect(!inkHits(points, at: CGPoint(x: 100, y: 2)), "the raw corner is empty canvas")
    }

    @Test func arrowsHitAlongTheShaft() {
        let shaft = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
        #expect(G.hitsArrow(path: shaft, at: CGPoint(x: 50, y: 5), tolerance: 4))
        #expect(!G.hitsArrow(path: shaft, at: CGPoint(x: 50, y: 20), tolerance: 4))
        #expect(!G.hitsArrow(path: shaft, at: CGPoint(x: 120, y: 0), tolerance: 4))
        // A routed arrow hits along its bends, not along the chord between its ends.
        let bent = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        #expect(G.hitsArrow(path: bent, at: CGPoint(x: 103, y: 60), tolerance: 4))
        #expect(!G.hitsArrow(path: bent, at: CGPoint(x: 50, y: 50), tolerance: 4))
    }
}

struct InkOutlineTests {
    /// Shoelace area of an implicitly closed polygon.
    func area(_ polygon: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    @Test func singlePointBecomesARoundDot() {
        let outline = DrawingInk.outline([InkPoint(x: 10, y: 20)])
        #expect(outline.count >= 8)
        #expect(outline.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let box = bounds(outline)
        #expect(box.insetBy(dx: -0.5, dy: -0.5).contains(CGPoint(x: 10, y: 20)))
        // Roughly a disc of the stroke's diameter, not a sliver.
        #expect(area(outline) > 0.3 * .pi * pow(DrawingGeometry.inkSize / 2, 2) * 0.5)
        #expect(box.width > 1 && box.height > 1)
    }

    @Test func longStrokeOutlineCoversItsPathWithVariableWidth() {
        let points = (0..<60).map { index in InkPoint(x: Double(index) * 4, y: sin(Double(index) / 6) * 30) }
        let outline = DrawingInk.outline(points)
        #expect(outline.count > points.count / 2)
        #expect(outline.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let box = bounds(outline).insetBy(dx: -0.5, dy: -0.5)
        #expect(points.allSatisfy { box.contains($0.point) }, "the outline must wrap the whole path")
        let pathLength = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        // A band along the path: at least a thin ribbon, at most the full-pressure width.
        #expect(area(outline) > pathLength * DrawingGeometry.inkSize * 0.2)
        #expect(area(outline) < pathLength * DrawingGeometry.inkSize * 1.5)
    }

    @Test func realPressureWidensTheStroke() {
        let light = (0..<30).map { InkPoint(x: Double($0) * 5, y: 0, pressure: 0.1) }
        let heavy = (0..<30).map { InkPoint(x: Double($0) * 5, y: 0, pressure: 1) }
        #expect(area(DrawingInk.outline(heavy)) > area(DrawingInk.outline(light)) * 1.5)
    }

    @Test func twoPointStrokeIsNonDegenerate() {
        let outline = DrawingInk.outline([InkPoint(x: 0, y: 0), InkPoint(x: 40, y: 0)])
        #expect(area(outline) > 40 * DrawingGeometry.inkSize * 0.2)
    }
}

struct RoughStrokeTests {
    func endpoints(_ strokes: [DrawingRough.Stroke]) -> [CGPoint] {
        strokes.flatMap { [$0.start] + $0.curves.map(\.end) }
    }

    @Test func sameIdDrawsTheSameStrokesAndDifferentIdsDiffer() {
        let rect = CGRect(x: 0, y: 0, width: 240, height: 140)
        var first = DrawingRough.Random(seed: DrawingRough.seed("obj_A"))
        var again = DrawingRough.Random(seed: DrawingRough.seed("obj_A"))
        var other = DrawingRough.Random(seed: DrawingRough.seed("obj_B"))
        let a = DrawingRough.rectangle(rect, random: &first)
        #expect(a == DrawingRough.rectangle(rect, random: &again))
        #expect(a != DrawingRough.rectangle(rect, random: &other))
    }

    @Test func jitterStaysWithinTheHitAllowance() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 180)
        for id in ["obj_1", "obj_2", "obj_3", "obj_4"] {
            var random = DrawingRough.Random(seed: DrawingRough.seed(id))
            for point in endpoints(DrawingRough.rectangle(rect, random: &random)) {
                #expect(rect.insetBy(dx: -3, dy: -3).contains(point))
            }
            var ellipseRandom = DrawingRough.Random(seed: DrawingRough.seed(id))
            for point in endpoints(DrawingRough.ellipse(rect, random: &ellipseRandom)) {
                #expect(rect.insetBy(dx: -rect.width * 0.08, dy: -rect.height * 0.08).contains(point))
            }
        }
    }
}

@MainActor
struct ArrowBindingLifecycleTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-drawing-\(UUID().uuidString)")

    @Test func deletingABoundObjectLeavesTheArrowEndWhereItWasAndItsOtherEndStillFollows() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BoardStore(directory: root.appendingPathComponent("boards"))
        let board = await store.load(root: root)
        let left = board.create(type: .shape, props: .object(["kind": .string("rect")]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let right = board.create(type: .shape, props: .object(["kind": .string("rect")]), frame: Frame(x: 400, y: 0, w: 200, h: 100))
        // Drawn right to left: its direction must survive losing the source.
        let arrow = board.create(type: .arrow, props: ArrowSpec(from: .object(right.id), to: .object(left.id)).props)

        try board.delete(right.id)
        let detached = try #require(ArrowSpec(try board.object(arrow.id).props))
        #expect(detached.from == .point(CGPoint(x: 400 - DrawingGeometry.arrowGap, y: 50)))
        #expect(detached.to == .object(left.id), "the surviving end stays bound")

        store.save(board)
        let reloaded = try #require(ArrowSpec(try await store.load(root: root).object(arrow.id).props))
        #expect(reloaded == detached)

        // Moving the survivor still re-routes that end; the free end holds still.
        try board.update(left.id, frame: Frame(x: 0, y: 300, w: 200, h: 100))
        let route = DrawingGeometry.route(from: .point(CGPoint(x: 394, y: 50)), to: .bound(.rect(CGRect(x: 0, y: 300, width: 200, height: 100))))
        #expect(route.start == CGPoint(x: 394, y: 50))
        #expect(route.end.y < 300, "attaches to the moved rect's upper side")
    }

    @Test func theAppsDrawnRouteWinsOverFrameGeometry() throws {
        let board = Board(id: "brd_t", root: root)
        let a = board.create(type: .shape, props: .object(["kind": .string("ellipse")]), frame: Frame(x: 0, y: 0, w: 100, h: 100))
        let b = board.create(type: .terminal, props: .object([:]), frame: Frame(x: 300, y: 0, w: 100, h: 100))
        let arrow = board.create(type: .arrow, props: ArrowSpec(from: .object(a.id), to: .object(b.id)).props)
        board.arrowPath = { id in id == arrow.id ? [CGPoint(x: 106, y: 50), CGPoint(x: 200, y: 50), CGPoint(x: 294, y: 63)] : nil }
        try board.delete(b.id)
        #expect(ArrowSpec(try board.object(arrow.id).props)?.to == .point(CGPoint(x: 294, y: 63)))
    }

    @Test func hugeFreeCoordinatesDescribeWithoutCrashing() async throws {
        let board = Board(id: "brd_t", root: root)
        let arrow = board.create(type: .arrow, props: ArrowSpec(from: .point(CGPoint(x: 1e20, y: -1e20)), to: .point(CGPoint(x: 0, y: 0))).props)
        try board.stage(.object(arrow.id))
        #expect(await board.drain().context.contains("(100000000000000000000, -100000000000000000000) → (0, 0)"))
    }

    @Test func oneUndoRestoresTheDeletedObjectAndTheArrowBinding() throws {
        let board = Board(id: "brd_t", root: root)
        let a = board.create(type: .shape, props: .object(["kind": .string("rect")]), frame: Frame(x: 0, y: 0, w: 100, h: 100))
        let b = board.create(type: .shape, props: .object(["kind": .string("rect")]), frame: Frame(x: 300, y: 0, w: 100, h: 100))
        let arrow = board.create(type: .arrow, props: ArrowSpec(from: .object(a.id), to: .object(b.id)).props)
        try board.delete(b.id)
        #expect(ArrowSpec(try board.object(arrow.id).props)?.to.objectID == nil)
        #expect(board.undo())
        #expect(board.objects[b.id] != nil)
        #expect(ArrowSpec(try board.object(arrow.id).props)?.to == .object(b.id))
    }
}

/// Text shapes typed on the canvas: a clicked one grows with its text and wraps at the default
/// width; a dragged one (or one given any other width) keeps its width and wraps there.
@MainActor
struct TextShapeLayoutTests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("canvas-text-\(UUID().uuidString)")
    let long = "dots dangle at line ends: keep link + dot together, one per line on phone? and the footer links too"

    @Test func aClickedTextGrowsWithItsTextThenWrapsAtTheDefaultWidth() {
        let short = TextShapeLayout.size("hi", textSize: 1, wrapWidth: nil)
        let line = TextShapeLayout.size("x", textSize: 1, wrapWidth: nil).height
        #expect(short.width < 60 && short.height == line)
        let wrapped = TextShapeLayout.size(long, textSize: 1, wrapWidth: nil)
        #expect(wrapped.width <= TextShapeLayout.autoWidth + 2, "\(wrapped.width) wide: it stops growing at the default width")
        #expect(wrapped.height > 2 * line, "and wraps onto more lines")
        let scaled = TextShapeLayout.size(long, textSize: 2, wrapWidth: nil)
        #expect(scaled.width > TextShapeLayout.autoWidth + 2 && scaled.width <= 2 * TextShapeLayout.autoWidth + 2, "the default width scales with the font")
    }

    @Test func aDraggedTextKeepsItsWidthAndWrapsThere() {
        let narrow = TextShapeLayout.size(long, textSize: 1, wrapWidth: 180)
        #expect(narrow.width == 180)
        #expect(narrow.height > TextShapeLayout.size(long, textSize: 1, wrapWidth: nil).height)
        #expect(TextShapeLayout.size("hi", textSize: 1, wrapWidth: 400).width == 400, "wider than its text: the width stays")
    }

    @Test func editingATextKeepsTheWayItWasSized() {
        let board = Board(id: "brd_t", root: root)
        func text(_ string: String, _ size: CGSize) -> CanvasObject {
            board.create(type: .shape, props: ShapeSpec(kind: .text, text: string).props, frame: Frame(x: 0, y: 0, w: size.width, h: size.height))
        }
        #expect(TextShapeLayout.wrapWidth(of: text("hi", TextShapeLayout.size("hi", textSize: 1, wrapWidth: nil))) == nil, "grown to its text: keeps growing")
        #expect(TextShapeLayout.wrapWidth(of: text(long, TextShapeLayout.size(long, textSize: 1, wrapWidth: nil))) == nil, "wrapped at the default width: still grows")
        #expect(TextShapeLayout.wrapWidth(of: text("hi", CGSize(width: 250, height: 30))) == 250, "a dragged width stays")
        #expect(TextShapeLayout.wrapWidth(of: text(long, CGSize(width: 180, height: 200))) == 180)
    }
}
