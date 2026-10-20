import AppKit
import CanvasCore

@testable import CanvasApp

@main
@MainActor
private enum InitialRouting {
    private struct CheckFailure: Error {
        let message: String
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
            throw CheckFailure(message: message)
        }
    }

    @MainActor
    private final class OpenBoard {
        let board: Board
        let canvas: CanvasView
        let container: NSView
        let drawing: ShapeLayer

        init(_ board: Board) {
            self.board = board
            let canvas = CanvasView(board: board, viewport: nil)
            self.canvas = canvas
            container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
            canvas.frame = container.bounds
            container.addSubview(canvas)
            let drawing = ShapeLayer.install(on: canvas, toolbarIn: container)
            self.drawing = drawing
            board.onEvent = { [unowned canvas, unowned drawing] event in
                canvas.apply(event)
                drawing.apply(event)
            }
        }

        func close() {
            board.onEvent = nil
            board.arrowPath = nil
            board.settleArrows = nil
            board.settledRouting = nil
            canvas.discard()
        }
    }

    private struct Fixture {
        let board: Board
        let source: CanvasObject
        let target: CanvasObject
        let other: CanvasObject
        let wall: CanvasObject
        let arrow: CanvasObject
    }

    private enum DragFinish: String, CaseIterable {
        case cancelled, zeroDelta
    }

    static func main() async throws {
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"] else {
            fatalError("run.py must provide a disposable EASL_HOME")
        }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let root = URL(fileURLWithPath: home)
        try await opening(root)
        try await parallelPreviews(root)
        for finish in DragFinish.allCases {
            try await openingDragReturnsToOrigin(root, finish: finish)
        }
        try await snapshotRetirement(root)
        try await newerEditDuringOpening(root)
        try await followingDuringOpening(root)
        try await editingDuringOpening(root)
        try await exportingDuringOpening(root)
        try await stableAfterOpening(root)
        print("INITIAL_ROUTING_COMPLETE")
    }

    private static func fixture(_ root: URL, _ name: String) throws -> Fixture {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let board = Board(id: name, root: directory)
        let source = board.create(type: .shape, props: ShapeSpec(kind: .ellipse, fill: .solid).props,
                                  frame: Frame(x: 0, y: 0, w: 100, h: 100))
        let target = board.create(type: .shape, props: ShapeSpec(kind: .rect, fill: .solid).props,
                                  frame: Frame(x: 600, y: 0, w: 100, h: 100))
        let other = board.create(type: .shape, props: ShapeSpec(kind: .rect, fill: .solid).props,
                                 frame: Frame(x: 600, y: 400, w: 100, h: 100))
        let wall = board.create(type: .shape, props: ShapeSpec(kind: .rect, fill: .solid).props,
                                frame: Frame(x: 250, y: -100, w: 200, h: 300))
        let arrow = board.create(type: .arrow,
                                 props: ArrowSpec(from: .object(source.id), to: .object(target.id), label: "around", route: .avoid).props)
        _ = board.create(type: .arrow,
                         props: ArrowSpec(from: .point(CGPoint(x: 0, y: 600)), to: .point(CGPoint(x: 700, y: 600)), label: "straight").props)
        _ = board.create(type: .arrow,
                         props: ArrowSpec(from: .point(CGPoint(x: 0, y: 750)), to: .point(CGPoint(x: 700, y: 850)), label: "orthogonal", route: .orthogonal).props)
        _ = try board.update(arrow.id, z: -1)
        return Fixture(board: board, source: source, target: target, other: other, wall: wall, arrow: arrow)
    }

    private static func mainRouting(_ board: Board, continuingFrom previous: ConnectorRouter.Result? = nil) -> ConnectorRouter.Result {
        let geometry = board.geometry
        return BoardGeometry(objects: geometry.objects, labelSizes: geometry.labelSizes, settled: previous).routing()
    }

    private static func path(_ fixture: Fixture) throws -> [CGPoint] {
        guard let points = fixture.board.arrowPath?(fixture.arrow.id), points.count >= 2 else {
            throw CheckFailure(message: "The attached arrow has no drawn path")
        }
        return points
    }

    private static func drawnPaths(_ board: Board) throws -> [ObjectID: [CGPoint]] {
        var paths: [ObjectID: [CGPoint]] = [:]
        for arrow in board.snapshot.objects where arrow.type == .arrow {
            guard let path = board.arrowPath?(arrow.id), path.count >= 2 else {
                throw CheckFailure(message: "Arrow \(arrow.id) has no drawn path")
            }
            paths[arrow.id] = path
        }
        return paths
    }

    private static func drawnPathsMatch(_ board: Board, _ expected: [ObjectID: [CGPoint]]) throws -> Bool {
        let actual = try drawnPaths(board)
        return actual.mapValues { $0.map(ShapeLayer.docPoint) } == expected.mapValues { $0.map(ShapeLayer.docPoint) }
    }

    private static func bounds(_ path: [CGPoint]) -> Frame {
        let xs = path.map(\.x), ys = path.map(\.y)
        return Frame(x: xs.min()!, y: ys.min()!, w: xs.max()! - xs.min()!, h: ys.max()! - ys.min()!)
    }

    private static func awaitRouting(_ board: Board, matching expected: ConnectorRouter.Result,
                                     whileWaiting check: @escaping @MainActor () throws -> Void = {}) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            var matched = false
            try await nextTurn {
                try check()
                if let result = board.settledRouting?(), result.paths == expected.paths, result.labels == expected.labels {
                    matched = try drawnPathsMatch(board, expected.paths)
                }
            }
            if matched { return }
            guard ContinuousClock.now < deadline else {
                throw CheckFailure(message: "Background routing and every drawn arrow did not settle to the reference paths and labels")
            }
        }
    }

    private static func nextTurn(_ operation: @escaping @MainActor () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    do {
                        try operation()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private static func parallelPreviews(_ root: URL) async throws {
        for style in ArrowRouteStyle.allCases {
            let fixture = try fixture(root, "parallel-\(style.rawValue)")
            _ = try fixture.board.update(fixture.arrow.id, props: .object(["route": .string(style.rawValue)]))
            let forward = fixture.board.create(type: .arrow,
                                               props: ArrowSpec(from: .object(fixture.source.id), to: .object(fixture.target.id), route: style).props)
            let backward = fixture.board.create(type: .arrow,
                                                props: ArrowSpec(from: .object(fixture.target.id), to: .object(fixture.source.id), route: style).props)
            let expected = mainRouting(fixture.board)
            let offsets = DrawingGeometry.parallelOffsets([
                (fixture.arrow.id, fixture.source.id, fixture.target.id),
                (forward.id, fixture.source.id, fixture.target.id),
                (backward.id, fixture.target.id, fixture.source.id),
            ])
            let source = DrawingGeometry.ArrowEnd.bound(.ellipse(fixture.source.frame.rect))
            let target = DrawingGeometry.ArrowEnd.bound(.rect(fixture.target.frame.rect))
            let previewStyle: ArrowRouteStyle = style == .avoid ? .orthogonal : style
            var previews = expected.paths
            for id in [fixture.arrow.id, forward.id] {
                previews[id] = DrawingGeometry.path(from: source, to: target, style: previewStyle, offset: offsets[id]!)
            }
            previews[backward.id] = DrawingGeometry.path(from: target, to: source, style: previewStyle, offset: offsets[backward.id]!)
            let opened = OpenBoard(fixture.board)
            defer { opened.close() }
            try require(try drawnPathsMatch(fixture.board, previews), "Every \(style.rawValue) first preview must use the full parallel-arrow set, independent of hydration order")
            let starts = try [fixture.arrow.id, forward.id].map { id -> CGPoint in
                guard let start = fixture.board.arrowPath?(id)?.first else {
                    throw CheckFailure(message: "A parallel preview has no source port")
                }
                return start
            }
            try require(starts[0] != starts[1], "Parallel \(style.rawValue) previews must not overlap at their source")
            opened.drawing.viewWillDraw()
            _ = fixture.board.reported(fixture.board.snapshot.objects)
            try require(try drawnPathsMatch(fixture.board, previews), "Drawing and reporting must preserve every correctly offset opening preview")
            try await awaitRouting(fixture.board, matching: expected)
        }
        print("PASS parallel straight, orthogonal and avoid previews use all siblings before their first draw")
    }

    private static func openingDragReturnsToOrigin(_ root: URL, finish: DragFinish) async throws {
        let fixture = try fixture(root, "drag-\(finish.rawValue)")
        let expected = mainRouting(fixture.board)
        let opened = OpenBoard(fixture.board)
        defer { opened.close() }
        let offset = NSSize(width: 180, height: 0)
        var previews = expected.paths
        previews[fixture.arrow.id] = DrawingGeometry.path(
            from: .bound(.ellipse(fixture.source.frame.rect)),
            to: .bound(.rect(fixture.target.frame.rect.offsetBy(dx: offset.width, dy: offset.height))),
            style: .orthogonal)
        try await nextTurn {
            opened.canvas.onSelectionDrag?([fixture.target.id], offset)
            try require(try drawnPathsMatch(fixture.board, previews), "An opening drag must immediately attach every drawn arrow to the shown endpoints")
        }
        var returned = false
        try await awaitRouting(fixture.board, matching: expected) {
            guard !returned, fixture.board.settledRouting?() != nil else { return }
            try require(try path(fixture).last!.x >= 780 - DrawingGeometry.arrowGap, "Background completion must keep the displayed arrow attached to the dragged target")
            if finish == .zeroDelta {
                opened.canvas.onSelectionDrag?([fixture.target.id], NSSize(width: -80, height: 0))
            }
            opened.canvas.onSelectionDrag?([fixture.target.id], .zero)
            returned = true
            try require(fixture.board.objects[fixture.target.id]?.frame == fixture.target.frame, "A \(finish.rawValue) drag must not need a board frame write to retire its preview")
        }
        try require(returned, "The \(finish.rawValue) fixture must return to its origin after the in-flight result lands")
        try require(!DrawingGeometry.path(try path(fixture), crosses: fixture.wall.frame.rect), "A \(finish.rawValue) opening drag must not leave a snapshot crossing the wall indefinitely")
        print("PASS \(finish.rawValue) opening drag retries and retires every pending preview without a frame write")
    }

    private static func snapshotRetirement(_ root: URL) async throws {
        let fixture = try fixture(root, "retirement")
        _ = try fixture.board.update(fixture.wall.id, frame: Frame(x: 250, y: 1600, w: 200, h: 300))
        _ = try fixture.board.update(fixture.arrow.id, props: .object(["label": .null]))
        let expected = mainRouting(fixture.board)
        let opened = OpenBoard(fixture.board)
        defer { opened.close() }
        try require(try drawnPathsMatch(fixture.board, expected.paths), "The retirement fixture must start with previews that already equal every final path")
        try await awaitRouting(fixture.board, matching: expected)
        _ = try fixture.board.update(fixture.wall.id, frame: fixture.wall.frame)
        opened.canvas.onSelectionDrag?([fixture.target.id], NSSize(width: 180, height: 0))
        let following = try path(fixture)
        try require(following.last!.x >= 780 - DrawingGeometry.arrowGap, "A settled arrow must follow its dragged target")
        try require(!DrawingGeometry.path(following, crosses: fixture.wall.frame.rect), "A matching background result must retire its snapshot even when no path or label changed")
        let beforeReporting = try drawnPaths(fixture.board)
        _ = fixture.board.reported(fixture.board.snapshot.objects)
        try require(try drawnPaths(fixture.board) == beforeReporting, "Reporting must not rebuild arrows whose snapshot previews already retired")
        opened.canvas.onSelectionDrag?([fixture.target.id], .zero)
        let changed = mainRouting(fixture.board, continuingFrom: expected)
        try await awaitRouting(fixture.board, matching: changed)
        print("PASS unchanged background paths retire snapshot previews before later obstacle and endpoint changes")
    }

    private static func newerEditDuringOpening(_ root: URL) async throws {
        let fixture = try fixture(root, "newer-edit")
        let previous = mainRouting(fixture.board)
        let opened = OpenBoard(fixture.board)
        defer { opened.close() }
        let oldPath = previous.paths[fixture.arrow.id]!
        let segment = zip(oldPath, oldPath.dropFirst()).max {
            hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) < hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
        }!
        let movedWall = Frame(x: (segment.0.x + segment.1.x) / 2 - 60,
                              y: (segment.0.y + segment.1.y) / 2 - 60, w: 120, h: 120)
        try require(DrawingGeometry.path(oldPath, crosses: movedWall.rect), "The newer edit must make the old opening route visibly stale")
        ApiActivity.shared.began("object.update")
        defer { ApiActivity.shared.ended("object.update") }
        var edited = fixture.arrow
        try await nextTurn {
            edited = try ApiActivity.shared.dispatch {
                _ = try fixture.board.update(fixture.arrow.id, props: .object([
                    "to": ArrowBinding.object(fixture.other.id).json,
                    "label": .string("newer edit"),
                ]))
                let restored = try fixture.board.update(fixture.arrow.id, props: .object([
                    "to": ArrowBinding.object(fixture.target.id).json,
                    "label": .string("around"),
                ]))
                _ = try fixture.board.update(fixture.wall.id, frame: movedWall)
                return restored
            }
        }
        try await awaitRouting(fixture.board, matching: previous)
        let expected = mainRouting(fixture.board, continuingFrom: previous)
        try require(expected.paths[fixture.arrow.id] != previous.paths[fixture.arrow.id], "The newer obstacle must require a different settled path even though the arrow spec returned to its original value")
        let reported = fixture.board.reported(edited)
        try require(try drawnPathsMatch(fixture.board, expected.paths), "An older snapshot completion must not retire a newer edit before the API reports every settled arrow")
        try require(!DrawingGeometry.path(try path(fixture), crosses: movedWall.rect), "A reverted newer edit must still settle around the newer obstacle")
        try require(reported.frame == bounds(try path(fixture)), "A newer edited arrow must report its settled drawn bounds after the older opening job completes")
        opened.drawing.viewWillDraw()
        try require(try drawnPathsMatch(fixture.board, expected.paths), "A later draw must preserve every route settled for the newer edit")
        print("PASS an older snapshot result cannot retire a newer edit's pending settled geometry")
    }

    private static func opening(_ root: URL) async throws {
        let fixture = try fixture(root, "opening")
        let expected = mainRouting(fixture.board)
        let opened = OpenBoard(fixture.board)
        defer { opened.close() }
        let preview = try path(fixture)
        try require(preview.first == CGPoint(x: 100 + DrawingGeometry.arrowGap, y: 50), "The opening preview must attach to the source ellipse even when its arrow is behind it")
        try require(preview.last == CGPoint(x: 600 - DrawingGeometry.arrowGap, y: 50), "The opening preview must attach to its target")
        try require(DrawingGeometry.path(preview, crosses: fixture.wall.frame.rect), "The fixture must distinguish the attached preview from its settled obstacle-avoiding route")
        opened.drawing.viewWillDraw()
        opened.canvas.zoomToFit()
        let reported = fixture.board.reported(fixture.board.snapshot.objects)
        try require(reported.first { $0.id == fixture.arrow.id }?.frame == bounds(preview), "Initial board.get reporting must describe the drawn attached preview")
        try require(try path(fixture) == preview, "Drawing, fitting and reporting during open must not synchronously replace the preview")
        let hit = ShapeLayer.docPoint(CGPoint(x: 180, y: 50))
        try require(opened.drawing.item(at: hit)?.object.id == fixture.arrow.id, "The opening preview must be drawable and hit-testable")
        try await awaitRouting(fixture.board, matching: expected)
        try require(try path(fixture) == expected.paths[fixture.arrow.id], "Background completion must display exactly the main-thread route")
        try require(!DrawingGeometry.path(try path(fixture), crosses: fixture.wall.frame.rect), "The settled route must avoid the wall")
        try require(fixture.board.reported(fixture.arrow).frame == bounds(try path(fixture)), "Settled API geometry must match the drawn route")
        print("PASS opening previews draw, attach, hit-test and report without settling; final paths and labels match main routing")
    }

    private static func stableAfterOpening(_ root: URL) async throws {
        let fixture = try fixture(root, "stable")
        _ = fixture.board.create(type: .arrow,
                                 props: ArrowSpec(from: .object(fixture.target.id), to: .object(fixture.source.id), label: "return", route: .avoid).props)
        let expected = mainRouting(fixture.board)
        let opened = OpenBoard(fixture.board)
        defer { opened.close() }
        try await awaitRouting(fixture.board, matching: expected)
        let before = try drawnPaths(fixture.board)
        _ = try fixture.board.update(fixture.target.id, props: .object(["color": .string("red")]))
        _ = fixture.board.reported(fixture.board.snapshot.objects)
        try require(try drawnPaths(fixture.board) == before, "An appearance-only update must not replace settled shared ports with standalone routes")
        _ = try fixture.board.update(fixture.source.id, props: .object(["kind": .string("rect")]))
        let changed = mainRouting(fixture.board, continuingFrom: expected)
        try await awaitRouting(fixture.board, matching: changed)
        print("PASS settled routes survive appearance-only updates and follow changed outlines")
    }

    private static func followingDuringOpening(_ root: URL) async throws {
        let fixture = try fixture(root, "following")
        let previous = mainRouting(fixture.board)
        let opened = OpenBoard(fixture.board)
        defer { opened.close() }
        try await nextTurn {
            _ = try fixture.board.update(fixture.target.id, frame: Frame(x: 1000, y: 0, w: 100, h: 100))
            opened.drawing.viewWillDraw()
            try require(try path(fixture).last == CGPoint(x: 1000 - DrawingGeometry.arrowGap, y: 50), "An opening preview must immediately follow its moved target")
            _ = fixture.board.reported(fixture.board.snapshot.objects)
        }
        let expected = mainRouting(fixture.board, continuingFrom: previous)
        try await awaitRouting(fixture.board, matching: expected) {
            try require(try path(fixture).last!.x >= 1000 - DrawingGeometry.arrowGap, "An old background result must never reattach the arrow to its old target frame")
        }
        print("PASS opening previews follow moved ends and reject stale background endpoints")
    }

    private static func editingDuringOpening(_ root: URL) async throws {
        let fixture = try fixture(root, "editing")
        let opened = OpenBoard(fixture.board)
        defer { opened.close() }
        try await nextTurn {
            let previous = fixture.board.settledRouting?()
            let edited = try ApiActivity.shared.dispatch {
                try fixture.board.update(fixture.arrow.id, props: .object([
                    "to": ArrowBinding.object(fixture.other.id).json,
                    "label": .string("edited while opening"),
                ]))
            }
            let expected = mainRouting(fixture.board, continuingFrom: previous)
            let reported = fixture.board.reported(edited)
            try require(try drawnPathsMatch(fixture.board, expected.paths), "An edited arrow must synchronously settle every drawn route, not its opening preview or old binding")
            try require(reported.frame == bounds(try path(fixture)), "The create/update API contract must still report settled drawn bounds")
        }
        for index in 0..<20 {
            _ = try fixture.board.update(fixture.target.id, frame: Frame(x: 900 + Double(index), y: 0, w: 100, h: 100))
            try await Task.sleep(for: .milliseconds(5))
            try require(try path(fixture).last!.y >= 400 - DrawingGeometry.arrowGap, "An older background route must not overwrite the edited binding")
        }
        let previous = fixture.board.settledRouting?()
        let created = fixture.board.create(type: .arrow,
                                           props: ArrowSpec(from: .object(fixture.source.id), to: .object(fixture.other.id), route: .avoid).props)
        let expected = mainRouting(fixture.board, continuingFrom: previous)
        opened.drawing.viewWillDraw()
        let reported = fixture.board.reported(created)
        try require(try drawnPathsMatch(fixture.board, expected.paths), "Creating an arrow must settle every drawn path together with shared ports")
        guard let createdPath = fixture.board.arrowPath?(created.id) else { throw CheckFailure(message: "New arrow has no drawn path") }
        try require(reported.frame == bounds(createdPath), "A user-created arrow must still settle before drawing and reporting")
        guard let settledPath = fixture.board.settledRouting?()?.paths[created.id] else {
            throw CheckFailure(message: "A created arrow has no settled route")
        }
        try require(settledPath.map(ShapeLayer.docPoint) == createdPath.map(ShapeLayer.docPoint),
                    "A created arrow must display its exact settled path; settled canvas: \(settledPath), drawn canvas: \(createdPath)")
        print("PASS edited and user-created arrows keep synchronous settled reporting; stale opening routes do not replace edited ends")
    }

    private static func exportingDuringOpening(_ root: URL) async throws {
        let fixture = try fixture(root, "exporting")
        let expected = mainRouting(fixture.board)
        let opened = OpenBoard(fixture.board)
        defer { opened.close() }
        let output = try await opened.canvas.render(RenderRequest(target: .objects([fixture.arrow.id]), scale: 1, chrome: false), format: .png)
        try require(try drawnPathsMatch(fixture.board, expected.paths), "An explicit export during open must settle every drawn arrow before choosing its region")
        try require(!output.image.isEmpty && output.objects.contains { $0.id == fixture.arrow.id && $0.state == .rendered }, "The export must contain the rendered arrow")
        let frame = bounds(expected.paths[fixture.arrow.id]!)
        try require(output.canvasRect.x <= frame.x && output.canvasRect.y <= frame.y && output.canvasRect.x + output.canvasRect.w >= frame.x + frame.w && output.canvasRect.y + output.canvasRect.h >= frame.y + frame.h, "The export must not crop the settled detour to provisional bounds")
        print("PASS explicit initial export settles final geometry before region selection and paints the arrow")
    }
}
