import CoreGraphics
import Foundation
import Testing
import CanvasCore

private typealias G = DrawingGeometry

private func moved(_ frame: Frame, _ dx: Double, _ dy: Double) -> Frame {
    Frame(x: frame.x + dx, y: frame.y + dy, w: frame.w, h: frame.h)
}

// Literal params keep the request bodies below readable.
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

/// Layout over the socket, as agents drive it: measure, fit, place/stack, batch, check.
@MainActor
final class LayoutApiTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-layout-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let server: SocketServer
    let board: Board
    let client: LineClient
    var sequence = 0

    init() throws {
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 100 lines; line 12 is a tab plus 60 x's (64 columns), line 50 is the longest in the file.
        var lines = (1...100).map { "line \($0)" }
        lines[11] = "\t" + String(repeating: "x", count: 60)
        lines[49] = String(repeating: "y", count: 120)
        try lines.joined(separator: "\n").write(to: root.appendingPathComponent("src.txt"), atomically: true, encoding: .utf8)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards")))
        board = registry.open(root: root)
        let router = ApiRouter(registry: registry)
        server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        client = try LineClient(path: dir.appendingPathComponent("s").path)
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    /// One request; returns the whole reply (`ok`, `result` or `error`).
    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        sequence += 1
        let request: JSONValue = .object(["id": .string("r\(sequence)"), "method": .string(method), "params": params])
        client.send(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        return try await client.next()
    }

    func result(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let reply = try await call(method, params)
        #expect(reply["ok"] == .bool(true), "\(method): \(reply["error"] ?? .null)")
        return reply["result"] ?? .null
    }

    static func size(_ value: JSONValue?) -> CGSize {
        CGSize(width: value?["w"]?.number ?? -1, height: value?["h"]?.number ?? -1)
    }

    static func code(_ start: Int, _ end: Int, caption: String? = nil) -> JSONValue {
        var props: [String: JSONValue] = ["path": .string("src.txt"), "range": .object(["start": .number(Double(start)), "end": .number(Double(end))])]
        if let caption { props["caption"] = .string(caption) }
        return .object(props)
    }

    // MARK: Measure and fit

    @Test func codeMeasuresExactlyItsRangeWithTabsExpanded() async throws {
        let measured = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(10, 19)])))
        #expect(measured == CodeMetrics.size(lines: 10, longestLine: 64, caption: false))
        let captioned = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(10, 19, caption: "why")])))
        #expect(captioned.height == measured.height + CodeMetrics.captionHeight)
        // The file's longest line (50) is outside the range and doesn't widen it.
        let wide = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(45, 54)])))
        #expect(wide.width > measured.width)
    }

    @Test func codeFitsUnderAMaxWidthByWrappingLongLines() async throws {
        // Lines 45-54 hold the 120-column line 50: 120 columns fit under the default 200.
        let natural = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(45, 54)])))
        #expect(natural == CodeMetrics.size(lines: 10, longestLine: 120, caption: false), "under the max, exactly as wide as the longest line")
        let roomy = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(45, 54), "width": 2000])))
        #expect(roomy == natural, "a larger max doesn't widen it")

        // At 500 pt the text column is 59 wide: line 50 takes 59 + 57 + 4 columns, 3 rows.
        #expect(CodeMetrics.textColumns(width: 500, lineCount: 100) == 59)
        let narrow = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(45, 54), "width": 500])))
        #expect(narrow == CGSize(width: 500, height: CodeMetrics.size(lines: 12, longestLine: 0, caption: false).height))
        let floor = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(45, 54), "width": 100])))
        #expect(floor.width == CodeMetrics.minWidth, "never narrower than the header needs")

        let fitted = try await result("object.create", .object(["type": "code", "props": Self.code(45, 54), "frame": .object(["x": 0, "y": 0, "w": 500]), "size": "fit"]))
        let frame = try #require(fitted["object"]?["frame"]).decode(Frame.self)
        #expect(CGSize(width: frame.w, height: frame.h) == narrow)
        // A re-fit without a width uses the default max, not the tile's current width.
        let refit = try await result("object.update", .object(["id": try #require(fitted["object"]?["id"]), "size": "fit"]))
        #expect(try #require(refit["object"]?["frame"]).decode(Frame.self).w == Double(natural.width))
    }

    @Test func aCodeTileFitsItsRangeEvenWithASymbolAndCheckFlagsOneThatDoesnt() async throws {
        // The codex study's evaluateTradeUp: a signature over five lines, then the body.
        let source = ["import pg from \"pg\";", "", "export async function evaluate(", "  pool: pg.Pool,", "  inputs: Input[],", "  outcomes: Outcome[]",
                      "): Promise<TradeUp | null> {"] + (1...40).map { "  const step\($0) = \($0);" } + ["  return null;", "}"]
        try source.joined(separator: "\n").write(to: board.root.appendingPathComponent("eval.ts"), atomically: true, encoding: .utf8)
        func props(_ extra: [String: JSONValue]) -> JSONValue { .object(["path": "eval.ts"].merging(extra) { $1 }) }
        let range: JSONValue = .object(["start": 3, "end": 49])
        let byRange = Self.size(try await result("object.measure", .object(["type": "code", "props": props(["range": range])])))
        #expect(byRange.height > 47 * 16, "all 47 rows")
        let both = Self.size(try await result("object.measure", .object(["type": "code", "props": props(["range": range, "symbol": "evaluate"])])))
        #expect(both == byRange, "the tile shows its range; the symbol only names it")
        let bySymbol = Self.size(try await result("object.measure", .object(["type": "code", "props": props(["symbol": "evaluate"])])))
        #expect(bySymbol == byRange, "a multi-line signature doesn't cut the declaration short")

        let small = try await result("object.create", .object(["type": "code", "props": props(["range": range, "symbol": "evaluate"]),
                                                                "frame": .object(["x": 0, "y": 0, "w": 344, "h": 124])]))
        let check = try await result("layout.check", .object(["ids": [try #require(small["object"]?["id"])]]))
        #expect(check["scrolls"]?.array?.first?["y"]?.number ?? 0 > 600, "a tile far shorter than its range scrolls to it")
        #expect(check["overflow"] == .array([]))
    }

    @Test func unmeasurableContentSaysWhy() async throws {
        let browser = try await call("object.measure", .object(["type": "browser", "props": .object(["url": "https://example.com"])]))
        #expect(browser["error"]?["code"] == .string("unsupported"))
        let past = try await call("object.measure", .object(["type": "code", "props": Self.code(150, 160)]))
        #expect(past["error"]?["code"] == .string("unavailable"))
    }

    /// HTML is laid out by the app's WebKit; this stand-in reflows like a page of prose, whose
    /// height is inversely proportional to its width (`html` characters × 1000 / width).
    static func proseHeight(_ props: JSONValue, _ width: CGFloat) -> CGFloat {
        CGFloat(props["html"]?.string?.count ?? 0) * 1000 / width
    }

    @Test func htmlFitsItsPageHeightAtItsWidthUpToTheCapAndCheckReportsOverflow() async throws {
        ObjectMeasure.html = { props, width, _ in CGSize(width: width, height: Self.proseHeight(props, width)) }
        defer { ObjectMeasure.html = nil }
        let page: JSONValue = .object(["html": .string(String(repeating: "x", count: 320))])
        let title = CGFloat(RenderMath.tileTitleHeight)

        // Default width: a new HTML tile's; the height is the title bar plus the document.
        let measured = Self.size(try await result("object.measure", .object(["type": "html", "props": page])))
        #expect(measured == CGSize(width: 640, height: title + 500))
        let narrow = Self.size(try await result("object.measure", .object(["type": "html", "props": page, "width": 400])))
        #expect(narrow == CGSize(width: 400, height: title + 800))

        // Fit on create at a width, and at a zoom (the page laid out at width ÷ zoom and drawn zoom
        // times under the 1× title bar).
        let fitted = try await result("object.create", .object(["type": "html", "props": page, "frame": .object(["x": 0, "y": 0, "w": 400]), "size": "fit"]))
        let id = try #require(fitted["object"]?["id"]?.string)
        #expect(try #require(fitted["object"]?["frame"]).decode(Frame.self) == Frame(x: 0, y: 0, w: 400, h: Double(title + 800)))
        var zoomedProps = page.object ?? [:]
        zoomedProps["zoom"] = 2
        let zoomed = Self.size(try await result("object.measure", .object(["type": "html", "props": .object(zoomedProps), "width": 800])))
        #expect(zoomed == CGSize(width: 800, height: title + 800 * 2))

        // A re-fit keeps the tile's width; a page taller than the cap stops at it.
        let longer = try await result("object.update", .object(["id": .string(id), "props": .object(["html": .string(String(repeating: "x", count: 640))]), "size": "fit"]))
        #expect(try #require(longer["object"]?["frame"]).decode(Frame.self).h == Double(title + 1600))
        let huge = try await result("object.update", .object(["id": .string(id), "props": .object(["html": .string(String(repeating: "x", count: 4000))]), "size": "fit"]))
        #expect(try #require(huge["object"]?["frame"]).decode(Frame.self) == Frame(x: 0, y: 0, w: 400, h: ObjectMeasure.maxHtmlFitHeight))

        // layout.check measures pages at their frame's width: the capped tile overflows, a fitted one doesn't.
        let fits = try await result("object.create", .object(["type": "html", "props": page, "frame": .object(["x": 1000, "y": 0, "w": 400]), "size": "fit"]))
        let short = board.create(type: .html, props: page, frame: Frame(x: 2000, y: 0, w: 640, h: 300))
        let report = try await result("layout.check", .object([:]))
        let overflow = Dictionary(uniqueKeysWithValues: (report["overflow"]?.array ?? []).compactMap { entry in entry["id"]?.string.map { ($0, entry) } })
        #expect(overflow[id]?["y"] == .number(Double(title) + 10_000 - ObjectMeasure.maxHtmlFitHeight))
        #expect(overflow[short.id]?["y"] == .number(Double(title) + 500 - 300))
        #expect(overflow[try #require(fits["object"]?["id"]?.string)] == nil)
    }

    // MARK: Props

    @Test func unknownPropsAreKeptButNamedInWarnings() async throws {
        let created = try await result("object.create", .object(["type": "note", "props": .object(["markdown": "hi", "colour": "red"]), "frame": .object(["x": 0, "y": 0, "w": 200, "h": 100])]))
        let warnings = (created["warnings"]?.array ?? []).compactMap(\.string)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("\"colour\"") && warnings[0].contains("note") && warnings[0].contains("markdown"))
        let id = try #require(created["object"]?["id"]?.string)
        #expect(try board.object(id).props["colour"] == .string("red"), "kept: agents may rely on it")

        let updated = try await result("object.update", .object(["id": .string(id), "props": .object(["markdwon": "typo", "title": "Plan"])]))
        #expect((updated["warnings"]?.array ?? []).compactMap(\.string).map { $0.contains("\"markdwon\"") } == [true])
        let clean = try await result("object.update", .object(["id": .string(id), "props": .object(["markdown": "fixed"])]))
        #expect(clean["warnings"] == nil)

        // Each batch op's result carries its own.
        let batch = try await result("object.batch", .object(["ops": .array([
            .object(["method": "object.create", "params": .object(["type": "shape", "props": .object(["kind": "rect", "fil": "solid"]), "frame": .object(["x": 0, "y": 300, "w": 100, "h": 100])])]),
            .object(["method": "object.create", "params": .object(["type": "shape", "props": .object(["kind": "rect", "fill": "solid"]), "frame": .object(["x": 200, "y": 300, "w": 100, "h": 100])])]),
        ])]))
        let results = try #require(batch["results"]?.array)
        #expect(results[0]["warnings"]?.array?.count == 1 && results[1]["warnings"] == nil)
    }

    /// A prop the schema defines must never be reported as unknown.
    @Test func knownPropsAreExactlyTheSchemas() throws {
        let schema = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../schema/easl-api.json")
        let definitions = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: schema))["definitions"]
        for type in ObjectType.allCases {
            let name = type.rawValue.prefix(1).uppercased() + type.rawValue.dropFirst() + "Props"
            let keys = Set(try #require(definitions?[name]?["properties"]?.object, "\(name)").keys)
            #expect(type.knownProps == keys, "\(type)")
        }
    }

    @Test func noteHeightFollowsItsWrapWidthAndResolvedFences() async throws {
        let prose: JSONValue = .object(["markdown": .string(String(repeating: "A sentence that wraps across the note. ", count: 12))])
        let narrow = Self.size(try await result("object.measure", .object(["type": "note", "props": prose, "width": 240])))
        let wide = Self.size(try await result("object.measure", .object(["type": "note", "props": prose, "width": 720])))
        #expect(narrow.width == 240 && wide.width == 720)
        #expect(narrow.height > wide.height * 2, "about three times the lines at a third of the width")
        let oneLine = Self.size(try await result("object.measure", .object(["type": "note", "props": .object(["markdown": "Short."]), "width": 720])))
        #expect(oneLine.height < wide.height)

        // A live excerpt renders the file's rows, so 30 rows measure taller than 3.
        func fence(_ end: Int) -> JSONValue { .object(["markdown": .string("Intro\n\n```txt file=src.txt#L1-\(end)\n```")]) }
        let short = Self.size(try await result("object.measure", .object(["type": "note", "props": fence(3), "width": 480])))
        let long = Self.size(try await result("object.measure", .object(["type": "note", "props": fence(30), "width": 480])))
        #expect(long.height - short.height > 27 * 12)
    }

    @Test func sizeFitCreatesAndRefitsAtTheGivenOrigin() async throws {
        let created = try await result("object.create", .object(["type": "code", "props": Self.code(1, 20), "frame": .object(["x": 100, "y": 200]), "size": "fit"]))
        let id = try #require(created["object"]?["id"]?.string)
        let expected = CodeMetrics.size(lines: 20, longestLine: 64, caption: false)
        #expect(created["object"]?["frame"] == .object(["x": 100, "y": 200, "w": .number(expected.width), "h": .number(expected.height)]))

        let refit = try await result("object.update", .object(["id": .string(id), "props": .object(["range": .object(["start": 1, "end": 5])]), "size": "fit"]))
        let frame = try #require(refit["object"]?["frame"]).decode(Frame.self)
        #expect(frame.x == 100 && frame.y == 200)
        #expect(frame.h == Double(CodeMetrics.size(lines: 5, longestLine: 7, caption: false).height))

        let note = try await result("object.create", .object(["type": "note", "props": .object(["markdown": "# Title\n\nBody"]), "frame": .object(["x": 0, "y": 0, "w": 400]), "size": "fit"]))
        #expect(note["object"]?["frame"]?["w"] == .number(400))
    }

    // MARK: Batch

    @Test func batchResolvesEarlierIdsAndUndoesAsOneStep() async throws {
        let before = board.revision
        let steps = board.history.undoSteps.count
        let reply = try await result("object.batch", .object(["ops": .array([
            .object(["method": "object.create", "params": .object(["type": "note", "props": .object(["markdown": "a"]), "frame": .object(["x": 0, "y": 0, "w": 200, "h": 100])])]),
            .object(["method": "object.create", "params": .object(["type": "note", "props": .object(["markdown": "b"]), "frame": .object(["x": 0, "y": 0, "w": 200, "h": 100])])]),
            .object(["method": "layout.place", "params": .object(["id": "$1", "near": "$0", "side": "right", "gap": 60])]),
            .object(["method": "object.create", "params": .object(["type": "arrow", "props": .object(["from": .object(["object": "$0"]), "to": .object(["object": "$1"])])])]),
            .object(["method": "object.create", "params": .object(["type": "group", "props": .object(["members": ["$0", "$1"], "title": "Lane"])])]),
        ])]))
        let results = try #require(reply["results"]?.array)
        let a = try #require(results[0]["object"]?["id"]?.string)
        let b = try #require(results[1]["object"]?["id"]?.string)
        let arrow = try board.object(try #require(results[3]["object"]?["id"]?.string))
        #expect(arrow.props["from"]?["object"] == .string(a) && arrow.props["to"]?["object"] == .string(b))
        #expect(try board.object(b).frame.x == 260)
        #expect(board.revision == before + 1, "one revision for the whole batch")
        #expect(board.history.undoSteps.count == steps + 1)
        #expect(board.changed(since: before).count == 4)

        board.undo()
        #expect(board.objects.isEmpty)
    }

    @Test func aFailingOpRollsBackEverythingBeforeIt() async throws {
        let note = board.create(type: .note, props: .object(["markdown": "keep"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let steps = board.history.undoSteps.count
        let reply = try await call("object.batch", .object(["ops": .array([
            .object(["method": "object.create", "params": .object(["type": "note", "props": .object(["markdown": "new"])])]),
            .object(["method": "object.update", "params": .object(["id": .string(note.id), "frame": .object(["x": 500, "y": 500, "w": 200, "h": 100])])]),
            .object(["method": "object.update", "params": .object(["id": .string(note.id), "rev": 1, "props": .object(["markdown": "stale"])])]),
        ])]))
        #expect(reply["error"]?["code"] == .string("conflict"))
        #expect(reply["error"]?["message"]?.string?.hasPrefix("op 2 (object.update)") == true)
        #expect(board.objects.count == 1, "the created note is gone")
        let restored = try board.object(note.id)
        #expect(restored.frame == note.frame && restored.props == note.props)
        #expect(board.history.undoSteps.count == steps, "nothing to undo")

        let forward = try await call("object.batch", .object(["ops": .array([
            .object(["method": "object.delete", "params": .object(["id": "$1"])]),
        ])]))
        #expect(forward["error"]?["code"] == .string("invalid_params"))
    }

    /// Build offscreen, then lay out: a batch creates tiles in two lanes and grids them by `$n`,
    /// so each column lines up across both lanes at its widest cell.
    @Test func gridInsideABatchAlignsColumnsAcrossGroups() async throws {
        func note(_ w: Int, _ h: Int) -> JSONValue {
            .object(["method": "object.create", "params": .object(["type": "note", "props": .object(["markdown": "n"]), "frame": .object(["x": 20000, "y": 0, "w": .number(Double(w)), "h": .number(Double(h))])])])
        }
        func cell(_ ref: String, _ row: Int, _ col: Int) -> JSONValue { .object(["id": .string(ref), "row": .number(Double(row)), "col": .number(Double(col))]) }
        let before = board.revision
        let reply = try await result("object.batch", .object(["ops": .array([
            note(300, 100), note(200, 150), note(250, 80), note(400, 120),
            .object(["method": "object.create", "params": .object(["type": "group", "props": .object(["members": ["$0", "$1"]])])]),
            .object(["method": "object.create", "params": .object(["type": "group", "props": .object(["members": ["$2", "$3"]])])]),
            .object(["method": "layout.grid", "params": .object(["cells": .array([cell("$0", 0, 0), cell("$1", 0, 1), cell("$2", 1, 0), cell("$3", 1, 1)]),
                                                                  "colGap": 50, "rowGap": 120, "origin": .object(["x": 0, "y": 0])])]),
        ])]))
        let results = try #require(reply["results"]?.array)
        let ids = try (0..<6).map { try #require(results[$0]["object"]?["id"]?.string) }
        let frames = try ids.map { try board.object($0).frame }
        // Column 0 is 300 wide (row 0's note), column 1 starts 50 past it; rows are 150 and 120 tall.
        #expect(frames[0...3].map(\.x) == [0, 350, 0, 350])
        #expect(frames[0...3].map(\.y) == [0, 0, 270, 270])
        #expect(results[6]["columns"] == .array([.object(["col": 0, "x": 0, "w": 300]), .object(["col": 1, "x": 350, "w": 400])]))
        #expect(results[6]["rows"] == .array([.object(["row": 0, "y": 0, "h": 150]), .object(["row": 1, "y": 270, "h": 120])]))
        // The lanes were re-fit to their members' new places before the batch returned.
        let top = GroupSpec.titleHeight, pad = GroupSpec.defaultPadding
        #expect(frames[4] == Frame(x: -pad, y: -pad - top, w: 550 + 2 * pad, h: 150 + 2 * pad + top))
        #expect(results[6]["frames"]?[ids[3]] == .object(["x": 350, "y": 270, "w": 400, "h": 120]))
        #expect(board.revision == before + 1)

        board.undo()
        #expect(board.objects.isEmpty, "the whole build is one step")
    }

    @Test func translateInABatchMovesGroupsAndArrowEnds() async throws {
        let a = board.create(type: .note, props: .object(["markdown": "a"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let lane = board.create(type: .group, props: .object(["members": .array([.string(a.id)])]))
        let free = board.create(type: .arrow, props: .object(["from": .object(["object": .string(a.id)]), "to": .object(["point": [500, 50]])]))
        let reply = try await result("object.batch", .object(["ops": .array([
            .object(["method": "layout.translate", "params": .object(["ids": .array([.string(lane.id), .string(a.id), .string(free.id)]), "dx": -12000, "dy": 30])]),
        ])]))
        #expect(try board.object(a.id).frame == Frame(x: -12000, y: 30, w: 200, h: 100), "listed beside its group, it still moves once")
        #expect(reply["results"]?.array?.first?["frames"]?[lane.id] == (try JSONValue.encode(moved(lane.frame, -12000, 30))))
        let spec = try #require(ArrowSpec(try board.object(free.id).props))
        #expect(spec.to == .point(CGPoint(x: -11500, y: 80)) && spec.from == .object(a.id))
    }

    // MARK: Check

    @Test func checkReportsOverlapsCrossingsAndOverflow() async throws {
        let a = board.create(type: .note, props: .object(["markdown": "a"]), frame: Frame(x: 0, y: 0, w: 200, h: 200))
        let b = board.create(type: .note, props: .object(["markdown": "b"]), frame: Frame(x: 400, y: 0, w: 200, h: 200))
        let c = board.create(type: .note, props: .object(["markdown": "c"]), frame: Frame(x: 800, y: 0, w: 200, h: 200))
        let stray = board.create(type: .note, props: .object(["markdown": "stray"]), frame: Frame(x: 150, y: 150, w: 200, h: 100))
        let region = board.create(type: .shape, props: .object(["kind": "rect"]), frame: Frame(x: -50, y: -100, w: 1100, h: 450))
        let group = board.create(type: .group, props: .object(["members": .array([.string(b.id), .string(c.id)])]))
        let through = board.create(type: .arrow, props: .object(["from": .object(["object": .string(a.id)]), "to": .object(["object": .string(c.id)])]))
        let around = board.create(type: .arrow, props: .object(["from": .object(["object": .string(a.id)]), "to": .object(["object": .string(c.id)]), "route": "avoid"]))
        let tiny = board.create(type: .code, props: Self.code(1, 30), frame: Frame(x: 0, y: 600, w: 300, h: 100))

        let report = try await result("layout.check", .object([:]))
        let overlaps = Set(report["overlaps"]?.array?.compactMap { $0.array?.compactMap(\.string) } ?? [])
        #expect(overlaps.contains([a.id, stray.id].sorted()))
        #expect(!overlaps.contains { $0.contains(region.id) }, "a drawn region around things isn't an overlap")
        #expect(!overlaps.contains([b.id, group.id].sorted()), "nor is a group around its members")
        #expect(overlaps.contains([a.id, group.id].sorted()) == false)
        let crossings = report["arrowCrossings"]?.array ?? []
        #expect(crossings.contains(.object(["arrow": .string(through.id), "crosses": .array([.string(b.id)])])))
        #expect(!crossings.contains { $0["arrow"] == .string(around.id) }, "an avoid route goes around b")
        // Code wraps at its tile's width: at 300 pt (32 columns) line 12's 64 columns take 3 rows,
        // which the tile scrolls through; that's `scrolls`, not content cut off.
        #expect(report["scrolls"]?.array?.first { $0["id"] == .string(tiny.id) } == .object(["id": .string(tiny.id), "y": .number(Double(CodeMetrics.size(lines: 32, longestLine: 64, caption: false).height) - 100)]))
        #expect(report["overflow"]?.array?.contains { $0["id"] == .string(tiny.id) } == false)

        let scoped = try await result("layout.check", .object(["ids": .array([.string(c.id)])]))
        #expect(scoped["overlaps"] == .array([]) && scoped["arrowCrossings"] == .array([]))
    }

    @Test func fitTilesAreExactlyTheirMeasuredBoxAndGroupsPadThatBox() async throws {
        let created = try await result("object.create", .object(["type": "code", "props": Self.code(10, 19, caption: "why"), "frame": .object(["x": 0, "y": 0]), "size": "fit"]))
        let code = try board.object(try #require(created["object"]?["id"]?.string))
        let measured = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(10, 19, caption: "why")])))
        #expect(code.frame.w == Double(measured.width) && code.frame.h == Double(measured.height))
        // The body under the title bar holds the header, the caption strip, and the range's ten rows: nothing more.
        #expect(RenderMath.body(of: code).height == CodeMetrics.headerHeight + CodeMetrics.captionHeight + 2 * CodeMetrics.verticalPadding + 10 * CodeMetrics.rowHeight)
        let createdNote = try await result("object.create", .object(["type": "note", "props": .object(["markdown": "# Title\n\nBody"]), "frame": .object(["x": 0, "y": 400, "w": 300]), "size": "fit"]))
        let note = try board.object(try #require(createdNote["object"]?["id"]?.string))
        let noteSize = Self.size(try await result("object.measure", .object(["type": "note", "props": .object(["markdown": "# Title\n\nBody"]), "width": 300])))
        #expect(note.frame.h == Double(noteSize.height))
        let lane = board.create(type: .group, props: .object(["members": .array([.string(code.id)]), "padding": 24]))
        #expect(lane.frame.maxY == code.frame.maxY + 24, "the padding starts where the tile's drawn box ends")
    }

    @Test func aTileRefittedToItsRangeShowsExactlyItAndNoTint() async throws {
        // The owner study's repro: a code tile at the default frame, then refit at a new width.
        let created = try await result("object.create", .object(["type": "code", "props": Self.code(10, 19), "frame": .object(["x": 0, "y": 0, "w": 640, "h": 446])]))
        let id = try #require(created["object"]?["id"]?.string)
        _ = try await result("object.update", .object(["id": .string(id), "size": "fit", "frame": .object(["x": 0, "y": 0, "w": 760])]))
        let fit = try board.object(id)
        let rows = CodeRows(lineCount: 100)
        let range = rows.index(ofLine: 10)..<rows.rows(ofLine: 19).upperBound
        func shown(_ frame: Frame) -> (rows: Range<Int>, tinted: Bool) {
            let viewport = CGFloat(frame.h) - CodeMetrics.chromeHeight(caption: false)
            let scroll = CodeMetrics.scrollOffset(toRow: range.lowerBound, count: range.count, viewport: viewport, totalRows: rows.count)
            return (CodeMetrics.visibleRows(scroll: scroll, viewport: viewport, totalRows: rows.count),
                    CodeMetrics.tintsRange(range, scroll: scroll, viewport: viewport, totalRows: rows.count))
        }
        // Aimed at its range, the fitted tile shows exactly the range's rows: nothing to tint.
        let fitted = shown(fit.frame)
        #expect(fitted.rows == range && !fitted.tinted)
        let last = CodeMetrics.lineY(line: 19, frame: fit.frame, props: fit.props, rows: rows)
        #expect(last == CGFloat(fit.frame.y + fit.frame.h) - CodeMetrics.verticalPadding - CodeMetrics.rowHeight / 2, "the range's last line is the bottom row, not cut off")
        // The taller default frame shows context around the range, so the range is tinted.
        let tall = shown(Frame(x: 0, y: 0, w: 640, h: 446))
        #expect(tall.rows.lowerBound == range.lowerBound - CodeMetrics.rangeContext && tall.rows.upperBound > range.upperBound && tall.tinted)
        // A whole-file range in a tile taller than the file: every visible row is the range.
        #expect(!CodeMetrics.tintsRange(0..<100, scroll: 0, viewport: 2000, totalRows: 100))
        // Scrolled so rows outside the range show, even a fit tile tints it.
        let viewport = CGFloat(fit.frame.h) - CodeMetrics.chromeHeight(caption: false)
        #expect(CodeMetrics.tintsRange(range, scroll: CGFloat(range.lowerBound - 1) * CodeMetrics.rowHeight, viewport: viewport, totalRows: rows.count))
    }

    @Test func notesCreatedWithoutAHeightFitTheirMarkdown() async throws {
        let markdown: JSONValue = "# Findings\n\nThe daemon exits when phase 4b throws.\n\n- checkpoint doesn't move\n- crash loop"
        func measured(_ props: JSONValue, width: Int?) async throws -> CGSize {
            var params: [String: JSONValue] = ["type": "note", "props": props]
            if let width { params["width"] = .number(Double(width)) }
            return Self.size(try await result("object.measure", .object(params)))
        }
        func created(_ params: [String: JSONValue]) async throws -> CanvasObject {
            var params = params
            params["type"] = "note"
            let reply = try await result("object.create", .object(params))
            return try board.object(try #require(reply["object"]?["id"]?.string))
        }
        let plain: JSONValue = .object(["markdown": markdown])
        let at420 = try await measured(plain, width: 420), atDefault = try await measured(plain, width: nil)
        let atWidth = try await created(["props": plain, "frame": .object(["x": 0, "y": 0, "w": 420])])
        #expect(atWidth.frame == Frame(x: 0, y: 0, w: 420, h: Double(at420.height)))
        let placed = try await created(["props": plain])
        #expect(placed.frame.w == Double(ObjectMeasure.defaultNoteWidth) && placed.frame.h == Double(atDefault.height))
        let sized = try await created(["props": plain, "frame": .object(["x": 0, "y": 0, "w": 420, "h": 90])])
        #expect(sized.frame.h == 90, "an explicit height is kept (the note scrolls)")

        // A title names the tile; it doesn't change what the note measures.
        let titled: JSONValue = .object(["markdown": markdown, "title": "Bug report"])
        let titledSize = try await measured(titled, width: 420)
        #expect(titledSize == at420)
        let note = try await created(["props": titled, "frame": .object(["x": 0, "y": 600, "w": 420])])
        #expect(note.props["title"] == "Bug report" && note.frame.h == atWidth.frame.h)
        let staged = try await result("tray.stage", .object(["target": .object(["kind": "object", "object": .string(note.id)])]))
        #expect(staged["mention"]?["label"]?.string?.contains("Bug report") == true, "mentions name the note by its title")
    }

    @Test func zoomedTilesLayOutTheirBodyAtItsNaturalSizeUnderA1xTitleBar() async throws {
        let title = CGFloat(RenderMath.tileTitleHeight)
        let zoomed = Self.code(10, 19).merging(.object(["zoom": 2]))
        let natural = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(10, 19)])))
        let measured = Self.size(try await result("object.measure", .object(["type": "code", "props": zoomed])))
        #expect(measured == CGSize(width: natural.width * 2, height: title + (natural.height - title) * 2))
        // 600 canvas points at 2× wrap like a 300-point tile: line 12's 64 columns still take 3 rows.
        let wide = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(1, 30).merging(.object(["zoom": 2])), "width": 600])))
        let narrow = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(1, 30), "width": 300])))
        #expect(wide == CGSize(width: narrow.width * 2, height: title + (narrow.height - title) * 2))

        let created = try await result("object.create", .object(["type": "code", "props": zoomed, "frame": .object(["x": 0, "y": 0]), "size": "fit"]))
        let fit = try board.object(try #require(created["object"]?["id"]?.string))
        #expect(fit.frame.w == Double(measured.width) && fit.frame.h == Double(measured.height))

        // 200 tall at 2×: a 26-point title bar over a body of 87 content points.
        let tiny = board.create(type: .code, props: Self.code(1, 30).merging(.object(["zoom": 2])), frame: Frame(x: 0, y: 600, w: 600, h: 200))
        let report = try await result("layout.check", .object(["ids": .array([.string(tiny.id)])]))
        let scrolled = try #require(report["scrolls"]?.array?.first { $0["id"] == .string(tiny.id) })
        #expect(scrolled["y"]?.number == 2 * (Double(CodeMetrics.size(lines: 32, longestLine: 64, caption: false).height) - (26 + 87)))
    }

    /// A zoomed tile's natural width comes back a hair under the points it was fitted at
    /// (frame.w ÷ zoom): checking it must not lose a column, wrap the longest line, and report
    /// the fitted tile a row short (presenter study: "overflow y=19" on fit tiles at 1.1–1.25).
    @Test func zoomedFitCodeTilesCheckClean() async throws {
        var ids: [String] = []
        for (index, zoom) in [1.1, 1.15, 1.2, 1.25, 1.3, 1.35, 1.45, 1.7, 2.3].enumerated() {
            for (row, range) in [(10, 19), (45, 60), (1, 12)].enumerated() {
                let props = Self.code(range.0, range.1).merging(.object(["zoom": .number(zoom)]))
                let created = try await result("object.create", .object(["type": "code", "props": props,
                                                                          "frame": .object(["x": .number(Double(index) * 2000), "y": .number(Double(row) * 2000)]), "size": "fit"]))
                ids.append(try #require(created["object"]?["id"]?.string))
            }
        }
        let report = try await result("layout.check", .object(["ids": .array(ids.map(JSONValue.string))]))
        #expect(report["scrolls"] == .array([]) && report["overflow"] == .array([]))
    }

    @Test func zoomIsClampedAndEveryTileButAnImageTakesIt() {
        #expect(ObjectZoom.of(.object([:])) == 1)
        #expect(ObjectZoom.of(.object(["zoom": 100])) == ObjectZoom.range.upperBound)
        #expect(ObjectZoom.of(.object(["zoom": .number(0.01)])) == ObjectZoom.range.lowerBound)
        #expect(ObjectZoom.of(.object(["zoom": .number(-2)])) == 1 && ObjectZoom.of(.object(["zoom": "2"])) == 1)
        let text = board.create(type: .shape, props: .object(["kind": "text", "text": "hi", "zoom": 2]), frame: Frame(x: 0, y: 0, w: 100, h: 100))
        let image = board.create(type: .image, props: .object(["path": "a.png", "zoom": 2]), frame: Frame(x: 0, y: 0, w: 400, h: 300))
        let note = board.create(type: .note, props: .object(["markdown": "n", "zoom": 2]), frame: Frame(x: 0, y: 0, w: 400, h: 300))
        #expect(text.zoom == 1 && image.zoom == 1 && note.zoom == 2)
        #expect(note.naturalFrame == Frame(x: 0, y: 0, w: 200, h: 26 + 137), "the title bar stays; the body lays out at half its size")
        #expect(RenderMath.body(of: image) == CGSize(width: 400, height: 274), "a picture fills its frame at any zoom")
    }

    @Test func zoomInAndOutStepThroughTheLevelsFromAnyZoom() {
        #expect(ObjectZoom.step(from: 1, bigger: true) == 1.1 && ObjectZoom.step(from: 1, bigger: false) == 0.9)
        #expect(ObjectZoom.step(from: 0.75, bigger: false) == 0.67, "the level a browser has")
        #expect(ObjectZoom.step(from: 5, bigger: true) == nil && ObjectZoom.step(from: 0.25, bigger: false) == nil, "the ends")
        #expect(ObjectZoom.step(from: 1.05, bigger: true) == 1.1 && ObjectZoom.step(from: 1.05, bigger: false) == 1, "an agent's zoom steps to the levels either side")
        #expect(ObjectZoom.step(from: 7, bigger: false) == 5, "past the last level steps back into them")
    }

    @Test func captionsWidenMeasureAndTruncatedCaptionsAreReported() async throws {
        let rows = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(10, 19)])))
        let short = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(10, 19, caption: "why")])))
        #expect(short.width == rows.width, "a caption that fits doesn't widen the tile")
        let long = String(repeating: "The JSON is a spec, not the `runtime` config. ", count: 8)
        let wide = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(10, 19, caption: long), "width": 3000])))
        #expect(wide.width == ObjectMeasure.captionWidth(long) && wide.width > rows.width + 400)
        let capped = Self.size(try await result("object.measure", .object(["type": "code", "props": Self.code(10, 19, caption: long)])))
        #expect(capped.width == CodeMetrics.defaultFitWidth && capped.height == wide.height, "past the max width the caption truncates")

        let cut = board.create(type: .code, props: Self.code(10, 19, caption: long), frame: Frame(x: 0, y: 0, w: Double(rows.width), h: Double(wide.height)))
        let report = try await result("layout.check", .object(["ids": .array([.string(cut.id)])]))
        #expect(report["truncated"] == .array([.object(["id": .string(cut.id), "what": "caption", "x": .number(Double(wide.width - rows.width))])]))
        #expect(report["overflow"] == .array([]) && report["scrolls"] == .array([]), "the rows fit; only the caption is cut")
        _ = try board.update(cut.id, frame: Frame(x: 0, y: 0, w: Double(wide.width), h: Double(wide.height)))
        #expect(try await result("layout.check", .object(["ids": .array([.string(cut.id)])]))["truncated"] == .array([]))
    }

    @Test func labelsOnTilesAreReportedAndLabelsKeepOffEachOther() async throws {
        // Two notes 30 pt apart, walled in above and below: nowhere near the route is clear.
        let a = board.create(type: .note, props: .object(["markdown": "a"]), frame: Frame(x: 0, y: 0, w: 200, h: 100))
        let b = board.create(type: .note, props: .object(["markdown": "b"]), frame: Frame(x: 230, y: 0, w: 200, h: 100))
        let above = board.create(type: .note, props: .object(["markdown": "above"]), frame: Frame(x: -300, y: -700, w: 1030, h: 695))
        let below = board.create(type: .note, props: .object(["markdown": "below"]), frame: Frame(x: -300, y: 105, w: 1030, h: 695))
        let squeezed = board.create(type: .arrow, props: .object(["from": .object(["object": .string(a.id)]), "to": .object(["object": .string(b.id)]), "label": "this.forward() → bridgeFetch()"]))
        let one = board.create(type: .arrow, props: .object(["from": .object(["point": [1000, 0]]), "to": .object(["point": [1400, 0]]), "label": "BridgeConfig.load()"]))
        let two = board.create(type: .arrow, props: .object(["from": .object(["point": [1000, 8]]), "to": .object(["point": [1400, 8]]), "label": "start() writes"]))
        let report = try await result("layout.check", .object([:]))
        let entries = report["labelOverlaps"]?.array ?? []
        func under(_ arrow: CanvasObject) -> Set<String> {
            Set(entries.first { $0["arrow"] == .string(arrow.id) }?["overlaps"]?.array?.compactMap(\.string) ?? [])
        }
        #expect(!under(squeezed).isEmpty && under(squeezed).isSubset(of: [a.id, b.id, above.id, below.id]), "no room anywhere near the route: reported with what it lies on")
        #expect(under(one).isEmpty && under(two).isEmpty, "arrows 8 pt apart label their outer sides, not on each other: \(entries)")
    }

    /// A tile put down over an arrow's label: checking just that tile reports the label (its
    /// text and where it is drawn, which the arrow's frame doesn't include) and the route.
    @Test func checkingATileReportsArrowLabelsLyingOnIt() async throws {
        let arrow = board.create(type: .arrow, props: .object(["from": .object(["point": [0, 0]]), "to": .object(["point": [400, 0]]), "label": "read back (:656)"]))
        let report = board.create(type: .html, props: .object(["html": "<p>report</p>"]), frame: Frame(x: 60, y: -150, w: 300, h: 300))
        let checked = try await result("layout.check", .object(["ids": [.string(report.id)]]))
        let entry = try #require(checked["labelOverlaps"]?.array?.first)
        #expect(entry["arrow"] == .string(arrow.id) && entry["label"] == "read back (:656)" && entry["overlaps"] == [.string(report.id)])
        let label = try #require(entry["frame"].flatMap { try? $0.decode(Frame.self) })
        #expect(label.w > 0 && label.h > 0 && label.intersects(report.frame) && label.x >= 0 && label.maxX <= 400, "the chip, beside the route")
        #expect(checked["arrowCrossings"] == [.object(["arrow": .string(arrow.id), "crosses": [.string(report.id)]])])

        _ = try board.update(report.id, frame: Frame(x: 60, y: 200, w: 300, h: 300))
        let clear = try await result("layout.check", .object(["ids": [.string(report.id)]]))
        #expect(clear["labelOverlaps"] == [] && clear["arrowCrossings"] == [])
    }

    /// `size: "fit"` on an update that gives no origin grows away from a tile it would cover;
    /// boxed in, it grows in place and the result names what it covers.
    @Test func refitGrowsAwayFromNeighboursOrReportsWhatItCovers() async throws {
        let long: JSONValue = .string((1...30).map { "Finding \($0): the daemon exits when phase \($0) throws." }.joined(separator: "\n\n"))
        let tall = Self.size(try await result("object.measure", .object(["type": "note", "props": .object(["markdown": long]), "width": 300])))
        let note = board.create(type: .note, props: .object(["markdown": "short"]), frame: Frame(x: 0, y: 0, w: 300, h: 100))
        _ = board.create(type: .note, props: .object(["markdown": "below"]), frame: Frame(x: 0, y: 130, w: 600, h: 400))
        let grown = try await result("object.update", .object(["id": .string(note.id), "props": .object(["markdown": long]), "size": "fit"]))
        let frame = try board.object(note.id).frame
        #expect(frame == Frame(x: 0, y: 100 - Double(tall.height), w: 300, h: Double(tall.height)), "grown up, its bottom edge kept")
        #expect(grown["overlaps"] == nil)

        let boxed = board.create(type: .note, props: .object(["markdown": "short"]), frame: Frame(x: -5000, y: 0, w: 300, h: 100))
        _ = board.create(type: .note, props: .object(["markdown": "above"]), frame: Frame(x: -9000, y: -4000, w: 8000, h: 3980))
        let under = board.create(type: .note, props: .object(["markdown": "under"]), frame: Frame(x: -9000, y: 130, w: 8000, h: 3000))
        let covering = try await result("object.update", .object(["id": .string(boxed.id), "props": .object(["markdown": long]), "size": "fit"]))
        #expect(try board.object(boxed.id).frame == Frame(x: -5000, y: 0, w: 300, h: Double(tall.height)), "no room nearby: grown in place")
        #expect(covering["overlaps"] == [.string(under.id)])
    }

    @Test func followTilesAreFixedViewersThatNeverOverflow() async throws {
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(board.root.path), "command": []]))
        let follow = try #require(try board.follow(tile: terminal.id, path: "src.txt", range: LineRange(start: 1, end: 80), action: "read"))
        let plain = board.create(type: .code, props: Self.code(1, 80), frame: follow.frame)
        let report = try await result("layout.check", .object(["ids": .array([.string(follow.id), .string(plain.id)])]))
        let scrolling = Set(report["scrolls"]?.array?.compactMap { $0["id"]?.string } ?? [])
        #expect(scrolling == [plain.id], "80 rows don't fit either frame; only the ordinary tile is reported")
    }

    /// `layout.check` reads each file once and wraps it once per width, off the main actor: its
    /// report is the one the board gives with every line-bound tile's rows computed on its own.
    @Test func checkWithSharedFilesAtSeveralWidthsMatchesPerTileRows() async throws {
        // src.txt line 50 is 120 columns: it wraps at 300 pt and 420 pt into different row counts.
        let narrow = board.create(type: .code, props: Self.code(45, 60), frame: Frame(x: 0, y: 0, w: 300, h: 300))
        let wider = board.create(type: .code, props: Self.code(45, 60), frame: Frame(x: 0, y: 400, w: 420, h: 300))
        let missing = board.create(type: .code, props: .object(["path": "gone.txt"]), frame: Frame(x: 0, y: 800, w: 300, h: 200))
        let target = board.create(type: .note, props: .object(["markdown": "t"]), frame: Frame(x: 900, y: 0, w: 200, h: 900))
        let wall = board.create(type: .note, props: .object(["markdown": "wall"]), frame: Frame(x: 600, y: -100, w: 60, h: 1100))
        func bound(_ tile: CanvasObject, _ line: Int) -> JSONValue {
            .object(["object": .string(tile.id), "lines": .object(["start": .number(Double(line)), "end": .number(Double(line))])])
        }
        for (tile, line) in [(narrow, 55), (wider, 52), (missing, 3)] {
            _ = board.create(type: .arrow, props: .object(["from": bound(tile, line), "to": .object(["object": .string(target.id)]), "route": "straight", "label": "calls"]))
        }
        let text = try String(contentsOf: board.root.appendingPathComponent("src.txt"), encoding: .utf8)
        let rows = [narrow.id: CodeRows(file: text, width: 300), wider.id: CodeRows(file: text, width: 420)]
        #expect(rows[narrow.id]!.index(ofLine: 55) != rows[wider.id]!.index(ofLine: 55), "the widths wrap line 50 differently")
        let expected = board.geometry.layoutCheck(rows: rows)
        #expect(expected.crossings.count == 3 && expected.crossings.allSatisfy { $0.crosses == [wall.id] })

        let report = try await result("layout.check", .object([:]))
        #expect(report["arrowCrossings"] == .array(expected.crossings.map { .object(["arrow": .string($0.arrow), "crosses": .array($0.crosses.map(JSONValue.string))]) }))
        #expect(report["labelOverlaps"]?.array?.map { [$0["arrow"] ?? .null] + ($0["overlaps"]?.array ?? []) }
            == expected.labelOverlaps.map { [.string($0.arrow)] + $0.overlaps.map(JSONValue.string) })
        #expect(report["overlaps"] == .array(expected.overlaps.map { .array($0.map(JSONValue.string)) }))
    }
}

/// Board-level layout: place/stack math and steps, groups as regions, and arrow routing.
@MainActor
struct LayoutBoardTests {
    let board = Board(id: "brd_layout", root: URL(fileURLWithPath: NSTemporaryDirectory()))

    func note(_ x: Double, _ y: Double, _ w: Double = 200, _ h: Double = 100) -> CanvasObject {
        board.create(type: .note, props: .object(["markdown": "n"]), frame: Frame(x: x, y: y, w: w, h: h))
    }

    @Test func placeAlignsOnEverySide() {
        let anchor = CGRect(x: 100, y: 100, width: 200, height: 100)
        let size = CGSize(width: 50, height: 40)
        #expect(Layout.place(size, near: anchor, side: .right, gap: 10, align: .start) == CGPoint(x: 310, y: 100))
        #expect(Layout.place(size, near: anchor, side: .right, gap: 10, align: .end) == CGPoint(x: 310, y: 160))
        #expect(Layout.place(size, near: anchor, side: .left, gap: 10, align: .center) == CGPoint(x: 40, y: 130))
        #expect(Layout.place(size, near: anchor, side: .below, gap: 10, align: .center) == CGPoint(x: 175, y: 210))
        #expect(Layout.place(size, near: anchor, side: .above, gap: 10, align: .end) == CGPoint(x: 250, y: 50))
    }

    @Test func refitTakesTheFirstCornerThatCoversNothingNew() {
        let current = Frame(x: 0, y: 0, w: 200, h: 100)
        let size = CGSize(width: 200, height: 300)
        let below = Frame(x: 0, y: 130, w: 200, h: 100)
        let alreadyUnder = Frame(x: 150, y: 50, w: 100, h: 100)
        #expect(Layout.refit(current, to: size, clearOf: [alreadyUnder]) == Frame(x: 0, y: 0, w: 200, h: 300), "what it covered before doesn't count")
        #expect(Layout.refit(current, to: size, clearOf: [below]) == Frame(x: 0, y: -200, w: 200, h: 300), "grown up instead of down")
        let wider = CGSize(width: 400, height: 300)
        let right = Frame(x: 250, y: -500, w: 100, h: 1000)
        #expect(Layout.refit(current, to: wider, clearOf: [right]) == Frame(x: -200, y: 0, w: 400, h: 300), "grown left")
        #expect(Layout.refit(current, to: wider, clearOf: [below, right]) == Frame(x: -200, y: -200, w: 400, h: 300), "grown left and up")
        let left = Frame(x: -150, y: -500, w: 100, h: 1000)
        #expect(Layout.refit(current, to: wider, clearOf: [below, right, left]) == nil, "every corner covers something")
    }

    @Test func refitBoxedInAtEveryCornerMovesToANearbyFreeSlot() throws {
        let tile = note(0, 0, 200, 100)
        let below = note(0, 130, 200, 400)
        let above = note(-300, -400, 800, 380)
        let frame = try board.refitFrame(tile.id, to: CGSize(width: 200, height: 300))
        #expect(frame == Frame(x: -224, y: 4, w: 200, h: 300), "beside the tile below (left ties right; top-left first), clear of the one above, the gap kept")
        // Wholly in view only right of the one above (529 pt away): a slot partly in view nearby wins.
        board.viewport = { Frame(x: -250, y: -100, w: 2000, h: 400) }
        #expect(try board.refitFrame(tile.id, to: CGSize(width: 200, height: 300)) == frame)
        _ = try board.update(tile.id, frame: frame)
        #expect(board.overlaps(of: tile.id).isEmpty && board.overlaps(of: below.id).isEmpty && board.overlaps(of: above.id).isEmpty)
    }

    @Test func stackWrapsLinesAndAlignsAcrossThem() {
        let sizes = [CGSize(width: 100, height: 50), CGSize(width: 100, height: 80), CGSize(width: 100, height: 30)]
        #expect(Layout.stack(sizes, from: .zero, direction: .row, gap: 10) == [CGPoint(x: 0, y: 0), CGPoint(x: 110, y: 0), CGPoint(x: 220, y: 0)])
        // 210 fits two boxes; the third wraps below the thicker of them.
        #expect(Layout.stack(sizes, from: .zero, direction: .row, gap: 10, wrapAt: 210, align: .end) == [CGPoint(x: 0, y: 30), CGPoint(x: 110, y: 0), CGPoint(x: 0, y: 90)])
        #expect(Layout.stack(sizes, from: CGPoint(x: 5, y: 5), direction: .column, gap: 20, align: .center) == [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 75), CGPoint(x: 5, y: 175)])
    }

    /// A 13 × 10 board of 800 × 500 tiles 100 pt apart, from the origin.
    func mainBoard() -> [CGRect] {
        (0..<130).map { CGRect(x: CGFloat($0 % 13) * 900, y: CGFloat($0 / 13) * 600, width: 800, height: 500) }
    }

    @Test func fitIgnoresAFarOutlierThatWouldShrinkTheBoardPastMinimumZoom() throws {
        let board = mainBoard()
        let strays = [CGRect(x: 40_000, y: 45_000, width: 860, height: 560), CGRect(x: 41_000, y: 45_000, width: 860, height: 560)]
        let target = try #require(Layout.fitTarget(board + strays, viewport: CGSize(width: 1512, height: 954), padding: 60, minZoom: 0.1))
        #expect(target == CGRect(x: 0, y: 0, width: 12 * 900 + 800, height: 9 * 600 + 500))
    }

    @Test func fitShowsEverythingWhenEverythingFitsAtMinimumZoom() throws {
        // Two clusters far apart, but the whole span still fits at 10%.
        let frames = [CGRect(x: 0, y: 0, width: 800, height: 500), CGRect(x: 10_000, y: 0, width: 800, height: 500), CGRect(x: 10_900, y: 0, width: 800, height: 500)]
        #expect(Layout.clusters(frames).count == 2)
        #expect(Layout.fitTarget(frames, viewport: CGSize(width: 1512, height: 954), padding: 60, minZoom: 0.1) == CGRect(x: 0, y: 0, width: 11_700, height: 500))
        #expect(Layout.fitTarget([], viewport: CGSize(width: 1512, height: 954), padding: 60, minZoom: 0.1) == nil)
    }

    @Test func fitPrefersTheClusterWithMoreObjectsThenMoreArea() throws {
        let small = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 200, y: 0, width: 100, height: 100)]
        let large = [CGRect(x: 50_000, y: 0, width: 2000, height: 2000)]
        let viewport = CGSize(width: 1000, height: 1000)
        #expect(Layout.fitTarget(small + large, viewport: viewport, padding: 0, minZoom: 0.1) == CGRect(x: 0, y: 0, width: 300, height: 100), "two objects beat one bigger one")
        let pair = [CGRect(x: 50_000, y: 0, width: 2000, height: 2000), CGRect(x: 52_500, y: 0, width: 100, height: 100)]
        #expect(Layout.fitTarget(small + pair, viewport: viewport, padding: 0, minZoom: 0.1) == CGRect(x: 50_000, y: 0, width: 2600, height: 2000), "equal counts: more area wins")
    }

    /// A 1440 × 872 viewport under a floating toolbar and above a tray (each 46 pt, plus a 12 pt margin).
    let clear = CGRect(x: 0, y: 58, width: 1440, height: 756)

    /// Where a document rect lands in the viewport after a jump, in view points.
    func shown(_ rect: CGRect, after jump: Layout.Jump) -> CGRect {
        CGRect(x: (rect.minX - jump.origin.x) * jump.zoom, y: (rect.minY - jump.origin.y) * jump.zoom, width: rect.width * jump.zoom, height: rect.height * jump.zoom)
    }

    func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

    @Test func fitFillsTheAreaBetweenTheChromeNotTheWholeViewport() {
        let board = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let jump = Layout.fit(board, in: clear, padding: 60, zoom: 0.1...1)
        let padded = shown(board.insetBy(dx: -60, dy: -60), after: jump)
        #expect(close(padded.minY, clear.minY) && close(padded.maxY, clear.maxY), "height-bound: the padded board spans exactly the clear band")
        #expect(padded.minX >= 0 && padded.maxX <= clear.maxX)
        #expect(close(padded.midX, clear.midX))
    }

    @Test func aTallTargetFitsItsWidthAndShowsItsTopInsteadOfShrinkingPastReadable() {
        let page = CGRect(x: 1000, y: 0, width: 820, height: 3100)
        let whole = Layout.fit(page, in: clear, padding: 60, zoom: 0.1...1)
        #expect(whole.zoom < 0.5, "fitted whole, the page is unreadable")
        let readable = Layout.fit(page, in: clear, padding: 60, zoom: 0.1...1, readable: 0.5)
        #expect(readable.zoom == 1, "its width fits at 100%, the zoom cap")
        #expect(close(shown(page, after: readable).minY, clear.minY + 60), "its top sits just below the toolbar")
        #expect(close(shown(page, after: readable).midX, clear.midX))
        // A target that fits whole at a readable zoom is centered as before.
        let tile = CGRect(x: 0, y: 0, width: 800, height: 500)
        let fitted = Layout.fit(tile, in: clear, padding: 60, zoom: 0.1...1, readable: 0.5)
        #expect(fitted.zoom == 1 && close(shown(tile, after: fitted).midY, clear.midY))
    }

    @Test func centerShowsTheTopOfWhatDoesntFitBelowTheChrome() {
        let page = CGRect(x: 0, y: 0, width: 820, height: 3100)
        let jump = Layout.center(page, in: clear, zoom: 1, padding: 20)
        #expect(shown(page, after: jump).minY == clear.minY + 20)
        #expect(shown(page, after: jump).midX == clear.midX, "the width fits, so it is centered")
    }

    @Test func revealPansTheLeastThatBringsTheTargetIntoTheClearArea() {
        let now = Layout.Jump(zoom: 0.5, origin: .zero)
        // In view: no move.
        #expect(Layout.reveal(CGRect(x: 100, y: 200, width: 300, height: 300), from: now, clear: clear, padding: 40) == now)
        // Past the right edge: only x moves, just enough for its padded right edge.
        let right = Layout.reveal(CGRect(x: 2800, y: 500, width: 640, height: 446), from: now, clear: clear, padding: 40)
        #expect(right == Layout.Jump(zoom: 0.5, origin: CGPoint(x: 600, y: 0)))
        // Under the toolbar: it comes down to just below it.
        let up = Layout.reveal(CGRect(x: 100, y: 0, width: 300, height: 300), from: now, clear: clear, padding: 40)
        #expect(shown(CGRect(x: 100, y: 0, width: 300, height: 300), after: up).minY == clear.minY + 20)
        #expect(up.origin.x == 0)
    }

    @Test func aBlockedTerminalTallerThanTheViewShowsItsBottomWhereTheQuestionIs() {
        let now = Layout.Jump(zoom: 0.5, origin: .zero)  // shows y 116…1628
        let terminal = CGRect(x: 100, y: 1000, width: 700, height: 2000)
        let jump = Layout.reveal(terminal, from: now, clear: clear, padding: 40, bottomFirst: true)
        #expect(shown(terminal, after: jump).maxY == clear.maxY - 20, "its padded bottom edge at the view's bottom")
        #expect(Layout.reveal(terminal, from: now, clear: clear, padding: 40).origin.y < jump.origin.y, "without it, the top shows")
        #expect(Layout.reveal(terminal, from: jump, clear: clear, padding: 40, bottomFirst: true) == jump, "the bottom in view: no move")
        let short = CGRect(x: 100, y: 1500, width: 700, height: 400)
        #expect(Layout.reveal(short, from: now, clear: clear, padding: 40, bottomFirst: true) == Layout.reveal(short, from: now, clear: clear, padding: 40), "one that fits shows whole")
    }

    @Test func aTileOpenedFromAReferencePansOnlyWhenMostlyHiddenAndKeepsTheReferenceInView() {
        let now = Layout.Jump(zoom: 0.5, origin: .zero)  // shows x 0…2880, y 116…1628
        let reference = CGRect(x: 100, y: 600, width: 200, height: 17)
        let halfShown = CGRect(x: 2500, y: 600, width: 640, height: 446)
        #expect(Layout.reveal(halfShown, from: now, clear: clear, padding: 40, openedFrom: reference) == now, "more than half shows: no pan")
        let hidden = CGRect(x: 2700, y: 600, width: 640, height: 446)
        #expect(Layout.reveal(hidden, from: now, clear: clear, padding: 40, openedFrom: .null) == Layout.Jump(zoom: 0.5, origin: CGPoint(x: 500, y: 0)))
        #expect(Layout.reveal(hidden, from: now, clear: clear, padding: 40, openedFrom: reference) == Layout.Jump(zoom: 0.5, origin: CGPoint(x: 100, y: 0)),
                "the pan stops where the clicked reference would leave the view")
    }

    @Test func nearbyGroupsAreOneClusterAndALoneObjectIsItsOwn() {
        let left = [CGRect(x: 0, y: 0, width: 400, height: 300), CGRect(x: 500, y: 0, width: 400, height: 300)]
        // 1400 pt right of `left`: within the margin, so the groups join.
        let right = [CGRect(x: 2300, y: 0, width: 400, height: 300), CGRect(x: 2300, y: 400, width: 400, height: 300)]
        // 1000 pt right of and below the lower `right` tile, far from `left`: it joins through `right`.
        let chained = CGRect(x: 3700, y: 1700, width: 200, height: 200)
        let lone = CGRect(x: 0, y: 20_000, width: 400, height: 300)
        #expect(Layout.clusters(left + right + [chained, lone]) == [[0, 1, 2, 3, 4], [5]])
        // Exactly `margin` apart still joins; one point more doesn't.
        #expect(Layout.clusters([CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 1510, y: 0, width: 10, height: 10)]).count == 1)
        #expect(Layout.clusters([CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 1511, y: 0, width: 10, height: 10)]).count == 2)
        #expect(Layout.clusters([lone]) == [[0]])
    }

    @Test func stackingGroupsMovesTheirMembersInOneStep() throws {
        let a = note(0, 0), b = note(300, 0), c = note(1000, 1000)
        let lane1 = board.create(type: .group, props: .object(["members": .array([.string(a.id), .string(b.id)])]))
        let lane2 = board.create(type: .group, props: .object(["members": .array([.string(c.id)])]))
        let before = board.revision
        let steps = board.history.undoSteps.count
        let frames = try board.stack([lane1.id, lane2.id], direction: .column, gap: 40)
        let first = try #require(frames[lane1.id])
        #expect(try board.object(lane2.id).frame.y == first.maxY + 40)
        #expect(try board.object(lane2.id).frame.x == first.x)
        #expect(try board.object(c.id).frame.x == a.frame.x, "members moved with their lane")
        #expect(board.revision == before + 1)
        #expect(board.history.undoSteps.count == steps + 1)
        board.undo()
        #expect(try board.object(c.id).frame == c.frame)
        #expect(try board.object(lane2.id).frame == lane2.frame)
    }

    @Test func groupIsItsMembersBoundsPlusPaddingAndTitle() throws {
        let a = note(0, 0), b = note(300, 200)
        let group = board.create(type: .group, props: .object(["members": .array([.string(a.id), .string(b.id)]), "padding": 10]))
        let top = GroupSpec.titleHeight
        #expect(group.frame == Frame(x: -10, y: -10 - top, w: 520, h: 320 + top))

        // A member moves: the group follows in the same undo step.
        let outside = note(700, 50)
        #expect(!board.enclosed(by: try board.object(group.id)).map(\.id).contains(outside.id))
        try board.update(b.id, frame: Frame(x: 800, y: 200, w: 200, h: 100))
        let grown = try board.object(group.id)
        #expect(grown.frame.maxX == 1010)
        #expect(board.enclosed(by: grown).map(\.id).contains(outside.id), "encloses follows the region")
        board.undo()
        #expect(try board.object(group.id).frame == group.frame)

        // A frame written to a group is ignored; deleting a member shrinks it.
        try board.update(group.id, frame: Frame(x: 0, y: 0, w: 1, h: 1))
        #expect(try board.object(group.id).frame == group.frame)
        try board.delete(b.id)
        #expect(try board.object(group.id).frame == Frame(x: -10, y: -10 - top, w: 220, h: 120 + top))
    }

    @Test func nestedGroupsRefitOutward() throws {
        let a = note(0, 0), b = note(300, 0)
        let inner = board.create(type: .group, props: .object(["members": .array([.string(a.id)])]))
        let outer = board.create(type: .group, props: .object(["members": .array([.string(inner.id), .string(b.id)])]))
        try board.update(a.id, frame: Frame(x: 0, y: 500, w: 200, h: 100))
        let innerNow = try board.object(inner.id).frame
        #expect(try board.object(outer.id).frame.contains(innerNow))
        #expect(innerNow.maxY == 600 + GroupSpec.defaultPadding)
        _ = outer
    }

    @Test func storedGroupsGetTitlesAndRealFrames() throws {
        let a = note(0, 0)
        var group = board.create(type: .group, props: .object(["members": .array([.string(a.id)])]))
        group.props = .object(["members": .array([.string(a.id)]), "name": "Old lane"])
        group.frame = Frame(x: 18, y: -50, w: 0, h: 0)
        let stored: JSONValue = .object(["id": "brd_x", "root": "/tmp", "revision": 3, "objects": try JSONValue.encode([a, group])])
        let loaded = Board(snapshot: try stored.decode(BoardSnapshot.self))
        let migrated = try loaded.object(group.id)
        #expect(migrated.props["title"] == .string("Old lane") && migrated.props["name"] == nil)
        #expect(migrated.frame.w > 200 && migrated.frame.contains(a.frame))
    }

    // MARK: Routing

    @Test func avoidRoutesAroundATileTheStraightLineCrosses() {
        let from = CGRect(x: 0, y: 0, width: 100, height: 100)
        let to = CGRect(x: 600, y: 0, width: 100, height: 100)
        let wall = CGRect(x: 250, y: -100, width: 200, height: 300)
        let straight = G.path(from: .bound(.rect(from)), to: .bound(.rect(to)), style: .straight)
        #expect(G.path(straight, crosses: wall))
        let avoid = G.path(from: .bound(.rect(from)), to: .bound(.rect(to)), style: .avoid, obstacles: [wall])
        #expect(!G.path(avoid, crosses: wall.insetBy(dx: -G.avoidMargin + 1, dy: -G.avoidMargin + 1)), "keeps its margin")
        #expect(!G.path(avoid, crosses: from) && !G.path(avoid, crosses: to))
        for (p, q) in zip(avoid, avoid.dropFirst()) { #expect(p.x == q.x || p.y == q.y, "axis-aligned segments") }
        let end = avoid[avoid.count - 1]
        #expect(to.insetBy(dx: -G.arrowGap - 1, dy: -G.arrowGap - 1).contains(end) && !to.contains(end))
    }

    @Test func orthogonalJogsBetweenOffsetBoxes() {
        let path = G.path(from: .bound(.rect(CGRect(x: 0, y: 0, width: 100, height: 100))), to: .bound(.rect(CGRect(x: 400, y: 300, width: 100, height: 100))), style: .orthogonal)
        #expect(path.count == 4)
        for (p, q) in zip(path, path.dropFirst()) { #expect(p.x == q.x || p.y == q.y) }
        #expect(path[0].x == 100 + G.arrowGap && path[3].x == 400 - G.arrowGap)
    }

    @Test func parallelArrowsInBothDirectionsDrawApart() {
        let offsets = G.parallelOffsets([("obj_1", "obj_a", "obj_b"), ("obj_2", "obj_b", "obj_a"), ("obj_3", "obj_a", "obj_c")])
        #expect(offsets["obj_3"] == nil)
        let a = DrawingGeometry.ArrowEnd.bound(.rect(CGRect(x: 0, y: 0, width: 200, height: 100)))
        let b = DrawingGeometry.ArrowEnd.bound(.rect(CGRect(x: 500, y: 40, width: 200, height: 100)))
        for style in [ArrowRouteStyle.straight, .orthogonal] {
            let forward = G.path(from: a, to: b, style: style, offset: offsets["obj_1"] ?? 0)
            let back = G.path(from: b, to: a, style: style, offset: offsets["obj_2"] ?? 0)
            // Reversed, the return arrow's route must not coincide with the forward one anywhere.
            let separation = forward.map { G.distance($0, toPath: back) }.min() ?? 0
            #expect(separation >= G.parallelSpacing - 0.5, "\(style): \(forward) vs \(back)")
        }
        // Diagonal pairs separate too.
        let c = DrawingGeometry.ArrowEnd.bound(.rect(CGRect(x: 600, y: 600, width: 100, height: 100)))
        let forward = G.path(from: a, to: c, style: .straight, offset: 10)
        let back = G.path(from: c, to: a, style: .straight, offset: 10)
        #expect(G.distance(forward[0], toPath: back) > 15)
    }

    @Test func aLabelSitsBesideItsRouteClearOfBoxes() {
        let path = [CGPoint(x: 0, y: 100), CGPoint(x: 400, y: 100)]
        let size = CGSize(width: 80, height: 20)
        let free = G.label(along: path, size: size, obstacles: []).rect
        #expect(!G.path(path, crosses: free) && (free.maxY <= 100 - G.labelClearance + 0.5 || free.minY >= 100 + G.labelClearance - 0.5), "beside the line")
        #expect(free.minX >= 0 && free.maxX <= 400, "along it, not past its ends")
        let box = CGRect(x: 0, y: 50, width: 400, height: 45)
        let moved = G.label(along: path, size: size, obstacles: [box]).rect
        #expect(!moved.intersects(box) && !G.path(path, crosses: moved), "the other side when a box covers one")
    }

    // MARK: Translate and grid

    @Test func gridColumnsAndRowsTakeTheirLargestCell() {
        let cells = [
            Layout.GridCell(row: 0, col: 0, size: CGSize(width: 100, height: 40)),
            Layout.GridCell(row: 0, col: 2, size: CGSize(width: 60, height: 90)),
            Layout.GridCell(row: 3, col: 0, size: CGSize(width: 180, height: 20)),
            Layout.GridCell(row: 3, col: 2, size: CGSize(width: 20, height: 30)),
        ]
        let grid = Layout.grid(cells, origin: CGPoint(x: 10, y: 5), colGap: 10, rowGap: 20)
        // Unused column 1 and rows 1–2 take no space.
        #expect(grid.columns == [Layout.Track(index: 0, start: 10, length: 180), Layout.Track(index: 2, start: 200, length: 60)])
        #expect(grid.rows == [Layout.Track(index: 0, start: 5, length: 90), Layout.Track(index: 3, start: 115, length: 30)])
        #expect(grid.origins == [CGPoint(x: 10, y: 5), CGPoint(x: 200, y: 5), CGPoint(x: 10, y: 115), CGPoint(x: 200, y: 115)])
        let centered = Layout.grid(cells, origin: .zero, colGap: 10, rowGap: 20, colAlign: .center, rowAlign: .end)
        #expect(centered.origins[0] == CGPoint(x: 40, y: 50))
        #expect(centered.origins[3] == CGPoint(x: 210, y: 110))
    }

    @Test func gridOfLaneMembersIsOneStepAndRejectsAGroupBesideItsMember() throws {
        let a = note(0, 0, 300, 100), b = note(1000, 0, 100, 100), c = note(0, 500, 150, 100), d = note(900, 500, 250, 100)
        let top = board.create(type: .group, props: .object(["members": .array([.string(a.id), .string(b.id)])]))
        let bottom = board.create(type: .group, props: .object(["members": .array([.string(c.id), .string(d.id)])]))
        let steps = board.history.undoSteps.count
        let placed = try board.grid([(a.id, 0, 0), (b.id, 0, 1), (c.id, 1, 0), (d.id, 1, 1)], colGap: 40, rowGap: 200)
        #expect(placed.frames[b.id]?.x == 340 && placed.frames[d.id]?.x == 340, "column 1 starts past column 0's widest cell")
        #expect(try board.object(bottom.id).frame.y == 300 - GroupSpec.defaultPadding - GroupSpec.titleHeight, "row 1 starts at 100 + rowGap; its lane follows")
        #expect(board.history.undoSteps.count == steps + 1)
        board.undo()
        #expect(try board.object(d.id).frame == d.frame && (try board.object(top.id).frame) == top.frame)

        #expect(throws: BoardError.self) { try board.grid([(top.id, 0, 0), (a.id, 0, 1)]) }
        #expect(try board.object(a.id).frame == a.frame, "a rejected grid moves nothing")
    }

    @Test func translateMovesEverythingOnceInOneStep() throws {
        let a = note(0, 0), b = note(300, 0), c = note(0, 400)
        let inner = board.create(type: .group, props: .object(["members": .array([.string(a.id)])]))
        let outer = board.create(type: .group, props: .object(["members": .array([.string(inner.id), .string(b.id)])]))
        let bound = board.create(type: .arrow, props: .object(["from": .object(["object": .string(b.id)]), "to": .object(["object": .string(c.id)])]))
        let before = board.revision
        let frames = try board.translate([outer.id, b.id], dx: 100, dy: -50)
        #expect(try board.object(a.id).frame.rect.origin == CGPoint(x: 100, y: -50))
        #expect(try board.object(b.id).frame.rect.origin == CGPoint(x: 400, y: -50))
        #expect(frames[outer.id] == moved(outer.frame, 100, -50))
        #expect(try board.object(inner.id).frame == moved(inner.frame, 100, -50))
        #expect(try board.object(c.id).frame == c.frame)
        #expect(try board.object(bound.id).props == bound.props, "a bound arrow follows by routing, not by rewriting")
        #expect(board.revision == before + 1)
        board.undo()
        #expect(try board.object(outer.id).frame == outer.frame && (try board.object(a.id).frame) == a.frame)
    }

    @Test func unfilledRectsAndEllipsesAreAnnotationsNotOverlaps() {
        let a = note(0, 0, 300, 200), b = note(400, 0, 300, 200)
        #expect(board.geometry.layoutCheck().overlaps.isEmpty)
        // Drawn across both notes (not around either), the way users mark a column or a pair.
        let box = board.create(type: .shape, props: .object(["kind": "rect"]), frame: Frame(x: 200, y: 100, w: 300, h: 200))
        let ring = board.create(type: .shape, props: .object(["kind": "ellipse"]), frame: Frame(x: 250, y: -50, w: 100, h: 400))
        let filled = board.create(type: .shape, props: .object(["kind": "rect", "fill": "semi"]), frame: Frame(x: 250, y: 150, w: 100, h: 100))
        let overlaps = Set(board.geometry.layoutCheck().overlaps)
        #expect(overlaps == [[a.id, filled.id].sorted()], "only the filled rect covers anything: \(overlaps)")
        #expect(board.geometry.layoutCheck(scope: [box.id, ring.id, b.id]).overlaps.isEmpty)
    }

    @Test func anArrowCaptionIsItsLabelElseItsRelationAndAnEmptyLabelHidesIt() throws {
        let a = note(0, 0), b = note(600, 0)
        func caption(_ props: [String: JSONValue]) -> String? {
            var props = props
            props["from"] = .object(["object": .string(a.id)])
            props["to"] = .object(["object": .string(b.id)])
            return ArrowSpec(.object(props)).flatMap(DrawingStyle.arrowLabel)?.text.string
        }
        #expect(caption(["relation": "calls"]) == "calls", "without a label the relation shows")
        #expect(caption(["relation": "calls", "label": "retries"]) == "retries")
        #expect(caption(["relation": "calls", "label": ""]) == nil, "an explicitly empty label shows nothing")
        #expect(caption([:]) == nil)
        // Labels are placed (and checked) only for arrows that draw one.
        let hidden = board.create(type: .arrow, props: .object(["from": .object(["object": .string(a.id)]), "to": .object(["object": .string(b.id)]), "relation": "calls", "label": ""]))
        let shown = board.create(type: .arrow, props: .object(["from": .object(["object": .string(b.id)]), "to": .object(["object": .string(a.id)]), "relation": "calls"]))
        let labels = board.geometry.routing().labels
        #expect(labels[hidden.id] == nil && labels[shown.id] != nil)
        // Clearing the label back to absent brings the relation back.
        try board.update(hidden.id, props: .object(["label": .null]))
        #expect(board.geometry.routing().labels[hidden.id] != nil)
    }

    // MARK: Line-bound arrows

    @Test func lineAnchorsFollowTheRangeScrollRuleAndClampToTheRows() {
        let range: JSONValue = .object(["path": "src.txt", "range": .object(["start": 10, "end": 19])])
        let rowsTop = CodeMetrics.titleHeight + CodeMetrics.headerHeight
        func middle(ofRow row: Int, scroll: CGFloat) -> CGFloat { rowsTop + CodeMetrics.verticalPadding + CGFloat(row) * CodeMetrics.rowHeight - scroll + CodeMetrics.rowHeight / 2 }
        // Fit to its range: no context rows, line 10 is the first row.
        let fit = Frame(x: 0, y: 100, w: 400, h: Double(rowsTop + 2 * CodeMetrics.verticalPadding + 10 * CodeMetrics.rowHeight))
        #expect(CodeMetrics.lineY(line: 10, frame: fit, props: range, rows: nil) == 100 + middle(ofRow: 0, scroll: 0))
        #expect(CodeMetrics.lineY(line: 12, frame: fit, props: range, rows: nil) == 100 + middle(ofRow: 2, scroll: 0))
        // Room for 30 rows: three rows of context above the range.
        let tall = Frame(x: 0, y: 0, w: 400, h: Double(rowsTop + 2 * CodeMetrics.verticalPadding + 30 * CodeMetrics.rowHeight))
        #expect(CodeMetrics.lineY(line: 10, frame: tall, props: range, rows: nil) == middle(ofRow: 3, scroll: 0))
        // Lines scrolled out of view pin to the top of the rows or the bottom of the tile.
        #expect(CodeMetrics.lineY(line: 1, frame: tall, props: range, rows: nil) == rowsTop)
        #expect(CodeMetrics.lineY(line: 99, frame: tall, props: range, rows: nil) == CGFloat(tall.h))
        // Near the end of the file the scroll stops at the last row, which shifts the range down.
        let end: JSONValue = .object(["path": "src.txt", "range": .object(["start": 95, "end": 100])])
        #expect(CodeMetrics.lineY(line: 95, frame: tall, props: end, rows: CodeRows(lineCount: 100)) == middle(ofRow: 30 - 6, scroll: 0))
        #expect(CodeMetrics.lineY(line: 95, frame: tall, props: end, rows: nil) == middle(ofRow: 3, scroll: 0), "without the file's length: context above, unclamped")
        // A caption strip moves the rows down.
        let captioned: JSONValue = .object(["path": "src.txt", "caption": "why", "range": .object(["start": 10, "end": 19])])
        #expect(CodeMetrics.lineY(line: 10, frame: fit, props: captioned, rows: nil) == 100 + middle(ofRow: 0, scroll: 0) + CodeMetrics.captionHeight)
        // At 2× in a frame whose body is twice the size, the tile shows the same rows, twice as
        // far below its 1× title bar.
        let zoomed: JSONValue = .object(["path": "src.txt", "zoom": 2, "range": .object(["start": 10, "end": 19])])
        let title = CodeMetrics.titleHeight
        let doubled = Frame(x: 0, y: 50, w: 800, h: Double(title) + (tall.h - Double(title)) * 2)
        #expect(CodeMetrics.lineY(line: 10, frame: doubled, props: zoomed, rows: nil) == 50 + title + 2 * (middle(ofRow: 3, scroll: 0) - title))
        #expect(CodeMetrics.lineY(line: 99, frame: doubled, props: zoomed, rows: nil) == 50 + CGFloat(doubled.h))
    }

    @Test func lineAnchorsBelowAWrappedLineLandOnTheirVisualRow() {
        // 20 lines; line 12 is 120 columns, which a 400 pt tile (45 columns) wraps onto 3 rows.
        var lines = (1...20).map { "line \($0)" }
        lines[11] = String(repeating: "w", count: 120)
        let text = lines.joined(separator: "\n")
        #expect(CodeMetrics.textColumns(width: 400, lineCount: 20) == 45)
        let rows = CodeRows(file: text, width: 400)
        #expect(rows.rows(ofLine: 12) == 11..<14 && rows.index(ofLine: 13) == 14)

        let range: JSONValue = .object(["path": "src.txt", "range": .object(["start": 10, "end": 19])])
        let rowsTop = CodeMetrics.titleHeight + CodeMetrics.headerHeight
        func middle(ofRow row: Int) -> CGFloat { rowsTop + CodeMetrics.verticalPadding + CGFloat(row) * CodeMetrics.rowHeight + CodeMetrics.rowHeight / 2 }
        // Fit to its range, 10 lines in 12 rows: line 10 is the first row, line 13 the sixth.
        let fit = Frame(x: 0, y: 100, w: 400, h: Double(rowsTop + 2 * CodeMetrics.verticalPadding + 12 * CodeMetrics.rowHeight))
        #expect(CodeMetrics.lineY(line: 10, frame: fit, props: range, rows: rows) == 100 + middle(ofRow: 0))
        #expect(CodeMetrics.lineY(line: 12, frame: fit, props: range, rows: rows) == 100 + middle(ofRow: 2), "a wrapped line anchors on its first row")
        #expect(CodeMetrics.lineY(line: 13, frame: fit, props: range, rows: rows) == 100 + middle(ofRow: 5))
        #expect(CodeMetrics.lineY(line: 19, frame: fit, props: range, rows: rows) == 100 + middle(ofRow: 11), "the whole wrapped range is in view")

        // Arrows route to the wrapped row when the board is given the tile's rows.
        let tile = board.create(type: .code, props: range, frame: fit)
        let note = board.create(type: .note, props: .object(["markdown": "why"]), frame: Frame(x: 600, y: 100, w: 200, h: 100))
        let bound = board.create(type: .arrow, props: .object([
            "from": .object(["object": .string(note.id)]),
            "to": .object(["object": .string(tile.id), "lines": .object(["start": 13, "end": 13])]),
        ]))
        let path = try! #require(board.geometry.routes(rows: [tile.id: rows])[bound.id])
        #expect(path.last == CGPoint(x: 400 + G.arrowGap, y: 100 + middle(ofRow: 5)))
    }

    func code(_ x: Double, _ y: Double, lines: ClosedRange<Int>) -> CanvasObject {
        let props: JSONValue = .object(["path": "src.txt", "range": .object(["start": .number(Double(lines.lowerBound)), "end": .number(Double(lines.upperBound))])])
        let h = Double(CodeMetrics.titleHeight + CodeMetrics.headerHeight + 2 * CodeMetrics.verticalPadding) + Double(lines.count) * Double(CodeMetrics.rowHeight)
        return board.create(type: .code, props: props, frame: Frame(x: x, y: y, w: 400, h: h))
    }

    func arrow(_ from: CanvasObject, _ fromLine: Int, _ to: CanvasObject, _ toLine: Int, route: String) -> CanvasObject {
        func end(_ object: CanvasObject, _ line: Int) -> JSONValue { .object(["object": .string(object.id), "lines": .object(["start": .number(Double(line)), "end": .number(Double(line))])]) }
        return board.create(type: .arrow, props: .object(["from": end(from, fromLine), "to": end(to, toLine), "route": .string(route)]))
    }

    func y(_ object: CanvasObject, _ line: Int) -> CGFloat { CodeMetrics.lineY(line: line, frame: object.frame, props: object.props, rows: nil) }

    @Test func lineBoundArrowsLandOnTheirLinesForEveryRoute() {
        let a = code(0, 0, lines: 10...19)
        let b = code(600, 100, lines: 40...49)
        _ = board.create(type: .note, props: .object(["markdown": "wall"]), frame: Frame(x: 450, y: -50, w: 100, h: 500))
        for route in ["straight", "orthogonal", "avoid"] {
            let forward = arrow(a, 12, b, 45, route: route)
            let back = arrow(b, 41, a, 18, route: route)
            let routes = board.geometry.routes()
            let there = try! #require(routes[forward.id]), home = try! #require(routes[back.id])
            #expect(there[0] == CGPoint(x: 400 + G.arrowGap, y: y(a, 12)) && there[there.count - 1] == CGPoint(x: 600 - G.arrowGap, y: y(b, 45)), "\(route): \(there)")
            #expect(home[0] == CGPoint(x: 600 - G.arrowGap, y: y(b, 41)) && home[home.count - 1] == CGPoint(x: 400 + G.arrowGap, y: y(a, 18)), "\(route): \(home)")
            if route != "straight" { for (p, q) in zip(there, there.dropFirst()) { #expect(p.x == q.x || p.y == q.y) } }
            try! board.delete(forward.id)
            try! board.delete(back.id)
        }
        #expect(y(a, 12) != y(a, 18) && y(b, 45) != y(b, 41), "distinct lines, distinct rows")
    }

    @Test func stackedLineBoundTilesLoopAroundTheirRightEdges() {
        let a = code(0, 0, lines: 10...19)
        let c = code(0, 400, lines: 10...19)
        let loop = arrow(a, 12, c, 15, route: "orthogonal")
        let path = try! #require(board.geometry.routes()[loop.id])
        #expect(path.first == CGPoint(x: 400 + G.arrowGap, y: y(a, 12)) && path.last == CGPoint(x: 400 + G.arrowGap, y: y(c, 15)))
        #expect(path.allSatisfy { $0.x >= 400 }, "never through either tile: \(path)")
        #expect(!G.path(path, crosses: a.frame.rect) && !G.path(path, crosses: c.frame.rect))
    }
}
