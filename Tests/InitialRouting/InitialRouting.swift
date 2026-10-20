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

    static func main() async throws {
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"] else {
            fatalError("run.py must provide a disposable EASL_HOME")
        }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let root = URL(fileURLWithPath: home)
        try await opening(root)
        try await followingDuringOpening(root)
        try await editingDuringOpening(root)
        try await exportingDuringOpening(root)
        try await stableAfterOpening(root)
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

    private static func mainRouting(_ board: Board) throws -> ConnectorRouter.Result {
        let canvas = CanvasView(board: board, viewport: nil)
        defer { canvas.discard() }
        let drawing = ShapeLayer(canvas: canvas)
        drawing.settleArrows(includingSnapshot: true)
        guard let result = drawing.routing else { throw CheckFailure(message: "Reference routing is missing") }
        return result
    }

    private static func path(_ fixture: Fixture) throws -> [CGPoint] {
        guard let points = fixture.board.arrowPath?(fixture.arrow.id), points.count >= 2 else {
            throw CheckFailure(message: "The attached arrow has no drawn path")
        }
        return points
    }

    private static func bounds(_ path: [CGPoint]) -> Frame {
        let xs = path.map(\.x), ys = path.map(\.y)
        return Frame(x: xs.min()!, y: ys.min()!, w: xs.max()! - xs.min()!, h: ys.max()! - ys.min()!)
    }

    private static func awaitRouting(_ board: Board, matching expected: ConnectorRouter.Result,
                                     whileWaiting check: () throws -> Void = {}) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            try check()
            if let result = board.settledRouting?(), result.paths == expected.paths && result.labels == expected.labels { return }
            guard ContinuousClock.now < deadline else { throw CheckFailure(message: "Background routes did not settle to the reference paths and labels") }
            try await Task.sleep(for: .milliseconds(1))
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

    private static func opening(_ root: URL) async throws {
        let fixture = try fixture(root, "opening")
        let expected = try mainRouting(fixture.board)
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
        let expected = try mainRouting(fixture.board)
        let opened = OpenBoard(fixture.board)
        defer { opened.close() }
        try await awaitRouting(fixture.board, matching: expected)
        let before = opened.drawing.items.compactMapValues { $0.arrow?.path }
        _ = try fixture.board.update(fixture.target.id, props: .object(["color": .string("red")]))
        _ = fixture.board.reported(fixture.board.snapshot.objects)
        try require(opened.drawing.items.compactMapValues { $0.arrow?.path } == before, "An appearance-only update must not replace settled shared ports with standalone routes")
        _ = try fixture.board.update(fixture.source.id, props: .object(["kind": .string("rect")]))
        let changed = try mainRouting(fixture.board)
        try await awaitRouting(fixture.board, matching: changed)
        print("PASS settled routes survive appearance-only updates and follow changed outlines")
    }

    private static func followingDuringOpening(_ root: URL) async throws {
        let fixture = try fixture(root, "following")
        let opened = OpenBoard(fixture.board)
        defer { opened.close() }
        try await nextTurn {
            _ = try fixture.board.update(fixture.target.id, frame: Frame(x: 1000, y: 0, w: 100, h: 100))
            opened.drawing.viewWillDraw()
            try require(try path(fixture).last == CGPoint(x: 1000 - DrawingGeometry.arrowGap, y: 50), "An opening preview must immediately follow its moved target")
            _ = fixture.board.reported(fixture.board.snapshot.objects)
        }
        let expected = try mainRouting(fixture.board)
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
            let edited = try ApiActivity.shared.dispatch {
                try fixture.board.update(fixture.arrow.id, props: .object([
                    "to": ArrowBinding.object(fixture.other.id).json,
                    "label": .string("edited while opening"),
                ]))
            }
            let reported = fixture.board.reported(edited)
            let expected = try mainRouting(fixture.board)
            try require(try path(fixture) == expected.paths[fixture.arrow.id], "An edited arrow must synchronously report its final route, not its opening preview or old binding")
            try require(reported.frame == bounds(try path(fixture)), "The create/update API contract must still report settled drawn bounds")
        }
        for index in 0..<20 {
            _ = try fixture.board.update(fixture.target.id, frame: Frame(x: 900 + Double(index), y: 0, w: 100, h: 100))
            try await Task.sleep(for: .milliseconds(5))
            try require(try path(fixture).last!.y >= 400 - DrawingGeometry.arrowGap, "An older background route must not overwrite the edited binding")
        }
        let created = fixture.board.create(type: .arrow,
                                           props: ArrowSpec(from: .object(fixture.source.id), to: .object(fixture.other.id), route: .avoid).props)
        opened.drawing.viewWillDraw()
        let reported = fixture.board.reported(created)
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
        let expected = try mainRouting(fixture.board)
        let opened = OpenBoard(fixture.board)
        defer { opened.close() }
        let output = try await opened.canvas.render(RenderRequest(target: .objects([fixture.arrow.id]), scale: 1, chrome: false), format: .png)
        try require(try path(fixture) == expected.paths[fixture.arrow.id], "An explicit export during open must settle the initial arrow before choosing its region")
        try require(!output.image.isEmpty && output.objects.contains { $0.id == fixture.arrow.id && $0.state == .rendered }, "The export must contain the rendered arrow")
        let frame = bounds(expected.paths[fixture.arrow.id]!)
        try require(output.canvasRect.x <= frame.x && output.canvasRect.y <= frame.y && output.canvasRect.x + output.canvasRect.w >= frame.x + frame.w && output.canvasRect.y + output.canvasRect.h >= frame.y + frame.h, "The export must not crop the settled detour to provisional bounds")
        print("PASS explicit initial export settles final geometry before region selection and paints the arrow")
    }
}
