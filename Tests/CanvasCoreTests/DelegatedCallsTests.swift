import AppKit
import Foundation
import Testing
@testable import CanvasCore

/// A remote board's window answering its easld's delegated calls (`DelegatedCalls`). Its
/// terminal's surface is `screen`: a prompt goes onto it as the agent's input line, and the
/// agent's `reply` follows. It draws renders as `drawing`, its tiles of `hostPictures` show only
/// the host's picture, and its WebKit lays a page out as `page` lays it out.
@MainActor
final class DelegatedCallsTests {
    final class NoHost: BoardHost {
        func send(_ write: RemoteWrite) {}
    }

    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("dc-\(UUID().uuidString.prefix(8))")
    let host = NoHost()
    let board: Board
    let terminal = "obj_term"
    var screen = ["$ omp", "> ready"]
    var reply: [String] = []
    var view: ViewState?
    var hostPictures: Set<ObjectID> = []
    var drawing = RenderOutput(image: Data([0x89, 0x50, 0x4E, 0x47]), format: .png, width: 40, height: 30,
                               canvasRect: Frame(x: 0, y: 0, w: 20, h: 15), scale: 2, objects: [])
    /// What the window was asked to draw, in order.
    var drawn: [RenderTarget] = []
    var page: (JSONValue, CGFloat) -> CGSize = { _, width in CGSize(width: width, height: 900.2) }
    /// The widths the window laid pages out at, in order.
    var laidOut: [CGFloat] = []
    var reloaded: [ObjectID] = []
    var browsed: [Browsed] = []
    var pageAnswer: (CmuxBrowserCommand) throws -> JSONValue = { _ in .object([:]) }

    struct Browsed: Equatable {
        var id: ObjectID
        var command: CmuxBrowserCommand
        var caller: ObjectID?
    }

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        board = Board(remote: "brd_host", root: URL(fileURLWithPath: "/home/tim/repo"), host: host)
        board.applyHost(CanvasObject(id: terminal, type: .terminal, frame: Frame(x: 0, y: 0, w: 600, h: 400), z: 0, createdBy: .user, createdAt: Date(),
                                     props: .object(["name": "worker", "lifecycle": .object(["state": "idle"])])))
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func delegated(surface: Bool = true) -> DelegatedCalls {
        DelegatedCalls(board: board, window: ViewerWindow(
            focused: { false },
            viewState: { [unowned self] in view },
            render: { [unowned self] request, format in
                drawn.append(request.target)
                var output = drawing
                output.format = format
                return output
            },
            hostPicture: { [unowned self] id in hostPictures.contains(id) },
            measureHTML: { [unowned self] props, width in
                laidOut.append(width)
                return page(props, width)
            },
            reload: { [unowned self] id, _, _ in
                reloaded.append(id)
                return .object(["id": .string(id), "loaded": .bool(true)])
            },
            browse: { [unowned self] id, command, caller in
                browsed.append(Browsed(id: id, command: command, caller: caller))
                return try pageAnswer(command)
            },
            submit: { [unowned self] id, text in
                guard surface, id == terminal else { return false }
                screen += ["> \(text)"] + reply
                return true
            },
            surfaceTail: { [unowned self] id, lines in
                guard surface, id == terminal else { return nil }
                var tail = TerminalTail(limit: lines)
                tail.append(Data(screen.joined(separator: "\n").utf8))
                return tail.finish()
            },
            block: { _, _ in throw ApiRouter.Failure("unavailable", "no command has finished") },
            status: { _ in TerminalStatus(title: "omp") }))
    }

    @discardableResult
    func tile(_ id: ObjectID, _ type: ObjectType, at x: Double) -> CanvasObject {
        let object = CanvasObject(id: id, type: type, frame: Frame(x: x, y: 500, w: 300, h: 200), z: 1, createdBy: .user, createdAt: Date(), props: .object([:]))
        board.applyHost(object)
        return object
    }

    func answer(_ calls: DelegatedCalls, _ method: String, _ params: JSONValue) async -> Result<JSONValue, EaslConnection.Failure> {
        await calls.answer(EaslConnection.Call(method: method, params: params))
    }

    func code(_ answer: Result<JSONValue, EaslConnection.Failure>) -> String? {
        if case .failure(let failure) = answer { return failure.code }
        return nil
    }

    @Test func sincePromptReadsWhatFollowedThisViewersLastPrompt() async throws {
        let calls = delegated()
        let early = await answer(calls, "agent.read", .object(["target": .string(terminal), "since": "prompt"]))
        #expect(code(early) == "not_found", "nothing typed through this viewer yet")
        reply = ["● Looking at the build", "● Fixed: a missing import"]
        let typed = try await answer(calls, "agent.prompt", .object(["target": .string(terminal), "text": "fix the build", "composer": .bool(true)])).get()
        #expect(typed["delivery"] == .string("typed"))
        #expect(typed["waitable"] == .bool(true))
        #expect(screen == ["$ omp", "> ready", "> fix the build", "● Looking at the build", "● Fixed: a missing import"])
        let read = try await answer(calls, "agent.read", .object(["target": .string(terminal), "since": "prompt"])).get()
        #expect(read["text"] == .string("> fix the build\n● Looking at the build\n● Fixed: a missing import"))
        #expect(read["lines"] == .number(3))
        #expect(read["truncated"] == .bool(false))
        let cut = try await answer(calls, "agent.read", .object(["target": .string(terminal), "since": "prompt", "lines": 1])).get()
        #expect(cut["text"] == .string("● Fixed: a missing import"))
        #expect(cut["truncated"] == .bool(true))
        let tail = try await answer(calls, "agent.read", .object(["target": .string(terminal), "lines": 2])).get()
        #expect(tail["text"] == .string("● Looking at the build\n● Fixed: a missing import"))
    }

    @Test func sincePromptSurvivesScrollbackTrimmingAndMarksLostContext() async throws {
        screen = (0..<500).map { "history \($0)" }
        let calls = delegated()
        reply = ["reply one", "reply two"]
        _ = try await answer(calls, "agent.prompt", .object(["target": .string(terminal), "text": "go"])).get()
        screen.removeFirst(10)
        let shifted = try await answer(calls, "agent.read", .object(["target": .string(terminal), "since": "prompt"])).get()
        #expect(shifted["text"] == .string("> go\nreply one\nreply two"))
        #expect(shifted["truncated"] == .bool(false))
        screen = ["new first", "new second", "new third"]
        let lost = try await answer(calls, "agent.read", .object(["target": .string(terminal), "since": "prompt"])).get()
        #expect(lost["text"] == .string("new first\nnew second\nnew third"))
        #expect(lost["truncated"] == .bool(true))
        let cut = try await answer(calls, "agent.read", .object(["target": .string(terminal), "since": "prompt", "lines": 1])).get()
        #expect(cut["text"] == .string("new third"))
        #expect(cut["lines"] == .number(1))
        #expect(cut["truncated"] == .bool(true))
    }

    @Test func aRewrittenPromptNeverAlignsOntoTheNextPrompt() async throws {
        screen = ["~/repo", "❯"]
        let calls = delegated()
        _ = try await answer(calls, "agent.prompt", .object(["target": .string(terminal), "text": "go"])).get()
        screen = ["~/repo", "❯ go", "out", "~/repo", "❯"]
        let read = try await answer(calls, "agent.read", .object(["target": .string(terminal), "since": "prompt"])).get()
        #expect(read["text"] == .string("❯ go\nout\n~/repo\n❯"))
        #expect(read["truncated"] == .bool(false))
    }

    @Test func aPromptWithNowhereToTypeTypesNothingAndSaysWhy() async {
        let calls = delegated(surface: false)
        let prompt = await answer(calls, "agent.prompt", .object(["target": .string(terminal), "text": "hi"]))
        #expect(prompt == .failure(EaslConnection.Failure("unavailable", "terminal obj_term has no attached surface")))
        #expect(code(await answer(calls, "agent.prompt", .object(["target": "obj_gone", "text": "hi"]))) == "not_found")
        #expect(screen == ["$ omp", "> ready"])
    }

    /// A batch needing the host's files fails even when the same paths exist on this Mac.
    @Test func aNoteNeedingTheHostsFilesFailsTheWholeBatch() async throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "let a = 1\nlet b = 2\n".write(to: dir.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appendingPathComponent("chart.png"))
        let calls = delegated()
        func measure(_ markdown: String) async -> Result<JSONValue, EaslConnection.Failure> {
            await answer(calls, "text.measure", .object(["items": [
                .object(["kind": "label", "text": "Ship it"]),
                .object(["kind": "note", "text": .string(markdown), "root": .string(dir.path)]),
            ]]))
        }
        #expect(code(await measure("Before\n\n```swift file=src/a.swift#L1-2\n```")) == "unavailable")
        #expect(code(await measure("Chart:\n\n![chart](chart.png)")) == "unavailable")
    }

    /// next.md "Versions": a param this build doesn't know fails just that call, and a method it
    /// doesn't serve is refused.
    @Test func whatThisBuildDoesntKnowFailsOnlyItsOwnCall() async throws {
        view = ViewState(viewport: Viewport(rect: Frame(x: 0, y: 0, w: 1200, h: 800), zoom: 1), promptTarget: terminal, focused: nil,
                         selection: ["obj_note"], enteredGroup: nil, visible: true, appearance: "dark")
        let calls = delegated()
        #expect(code(await answer(calls, "view.get", .object(["board": "brd_host", "zoom": 2]))) == "invalid_params")
        #expect(code(await answer(calls, "text.measure", .object(["items": [.object(["kind": "label", "text": "x", "font": "Menlo"])]]))) == "invalid_params")
        #expect(code(await answer(calls, "view.snapshot", .object(["board": "brd_host"]))) == "unsupported")
        let output = dir.appendingPathComponent("shot.png")
        #expect(code(await answer(calls, "view.snapshot", .object(["board": "brd_host", "out": .string(output.path)]))) == "unsupported")
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let shown = try await answer(calls, "view.get", .object(["board": "brd_host"])).get()
        #expect(shown == .object([
            "board": "brd_host", "viewport": .object(["rect": .object(["x": 0, "y": 0, "w": 1200, "h": 800]), "zoom": 1]),
            "selection": ["obj_note"], "visible": .bool(true), "appearance": "dark", "promptTarget": .string(terminal),
        ]))
    }

    /// RenderQueue would otherwise take the returned stand-in as its own host picture.
    @Test func whatOnlyTheHostDrawsIsNeverDrawnOrReloadedHere() async throws {
        tile("obj_note", .note, at: 0)
        tile("obj_code", .code, at: 400)
        tile("obj_diagram", .diagram, at: 800)
        hostPictures = ["obj_code", "obj_diagram"]
        let calls = delegated()
        let named = await answer(calls, "view.render", .object(["board": "brd_host", "target": ["obj_note", "obj_code"], "inline": .bool(true)]))
        #expect(code(named) == "unavailable")
        #expect(drawn.isEmpty)
        #expect(code(await answer(calls, "object.reload", .object(["id": "obj_diagram"]))) == "unavailable")
        #expect(reloaded.isEmpty)
    }

    @Test func aViewerRefusesFileDelivery() async throws {
        tile("obj_note", .note, at: 0)
        let calls = delegated()
        let out = dir.appendingPathComponent("render.png")
        #expect(code(await answer(calls, "view.render", .object(["board": "brd_host", "target": "obj_note"]))) == "invalid_params")
        #expect(code(await answer(calls, "view.render", .object(["board": "brd_host", "target": "obj_note", "inline": .bool(true), "out": .string(out.path)]))) == "invalid_params")
        #expect(drawn.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    /// easld closes a link whose line runs past 64 MiB, failing every call on it, so a render
    /// that long fails by itself. 25 MiB of 0xFF is 33 MiB of base64, every character a `/`,
    /// which the reply writes as two bytes.
    @Test func aRenderTooLongForEasldsLineFailsByItself() async throws {
        tile("obj_note", .note, at: 0)
        drawing.image = Data(repeating: 0xFF, count: 25 << 20)
        let calls = delegated()
        #expect(code(await answer(calls, "view.render", .object(["board": "brd_host", "target": "obj_note", "inline": .bool(true)]))) == "invalid_params")
    }

    /// An HTML page measures as the whole frame its tile needs, framed as the app frames it: laid
    /// out at the width over its zoom (default 640), the 26-pt title bar at 1× over the zoomed
    /// document, at most 4000 tall. Other types are easld's to measure.
    @Test func anHtmlPageMeasuresAsItsTilesWholeFrame() async throws {
        let calls = delegated()
        func measure(_ props: JSONValue, width: Double? = nil) async throws -> JSONValue {
            var params: [String: JSONValue] = ["board": "brd_host", "type": "html", "props": props]
            if let width { params["width"] = .number(width) }
            return try await answer(calls, "object.measure", .object(params)).get()
        }
        #expect(try await measure(.object(["html": "<p>hi</p>"])) == .object(["w": 640, "h": 927]))
        #expect(try await measure(.object(["html": "<p>hi</p>", "zoom": 2]), width: 500) == .object(["w": 500, "h": 1828]))
        #expect(laidOut == [640, 250])
        page = { _, width in CGSize(width: width, height: 9000) }
        #expect(try await measure(.object(["html": "<p>long</p>"])) == .object(["w": 640, "h": 4000]))
        #expect(code(await answer(calls, "object.measure", .object(["board": "brd_host", "type": "note", "props": .object(["markdown": "hi"])]))) == "unsupported")
    }


    @Test func aBrowserCallFailsWithThePagesOwnCodeOrBeforeReachingIt() async throws {
        tile("obj_page", .browser, at: 0)
        tile("obj_note", .note, at: 400)
        pageAnswer = { command in
            if case .eval = command { throw CmuxError("js_error", "ReferenceError: missing is not defined") }
            throw CmuxError("timeout", "timed out waiting for #done")
        }
        let calls = delegated()
        func call(_ id: ObjectID, _ method: String, _ params: JSONValue) async -> Result<JSONValue, EaslConnection.Failure> {
            await answer(calls, "browser.call", .object(["id": .string(id), "method": .string(method), "params": params]))
        }
        #expect(await call("obj_page", "browser.eval", .object(["script": "missing"])) == .failure(EaslConnection.Failure("js_error", "ReferenceError: missing is not defined")))
        #expect(await call("obj_page", "browser.wait", .object(["selector": "#done", "timeout_ms": 50])) == .failure(EaslConnection.Failure("timeout", "timed out waiting for #done")))
        #expect(browsed.map(\.command) == [.eval(script: "missing"), .wait(.selector("#done"), timeoutMs: 50)])
        browsed = []
        #expect(await call("obj_page", "browser.wait", .object(["selector": "#done", "load_state": "complete"])) == .failure(EaslConnection.Failure("invalid_params", "browser.wait takes exactly one of load_state, url_contains, selector")))
        #expect(code(await call("obj_page", "browser.open_split", .object(["url": "https://example.com/"]))) == "invalid_params")
        #expect(code(await call("obj_note", "browser.url.get", .object([:]))) == "not_found")
        #expect(code(await call("obj_gone", "browser.url.get", .object([:]))) == "not_found")
        #expect(browsed.isEmpty)
    }
}
