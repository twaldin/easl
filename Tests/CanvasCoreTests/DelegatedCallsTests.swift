import AppKit
import Foundation
import Testing
@testable import CanvasCore

/// A remote board's window answering its easld's delegated calls (`DelegatedCalls`). Its
/// terminal's surface is `screen`: a prompt goes onto it as the agent's input line, and the
/// agent's `reply` follows.
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
    var shot: (output: RenderOutput, viewport: Viewport)?

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
            snapshot: { [unowned self] _ in shot },
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
    }

    @Test func aPromptWithNowhereToTypeTypesNothingAndSaysWhy() async {
        let calls = delegated(surface: false)
        let prompt = await answer(calls, "agent.prompt", .object(["target": .string(terminal), "text": "hi"]))
        #expect(prompt == .failure(EaslConnection.Failure("unavailable", "terminal obj_term has no attached surface")))
        #expect(code(await answer(calls, "agent.prompt", .object(["target": "obj_gone", "text": "hi"]))) == "not_found")
        #expect(screen == ["$ omp", "> ready"])
    }

    /// The picture is saved on this Mac. A caller's `out` names a file on easld's machine: nothing
    /// is written at that path here.
    @Test func aSnapshotIsSavedOnThisMacAndAnOutIsRefused() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let viewport = Viewport(rect: Frame(x: 100, y: 50, w: 600, h: 400), zoom: 1)
        shot = (RenderOutput(image: png, format: .png, width: 1200, height: 800, canvasRect: viewport.rect, scale: 2, objects: []), viewport)
        let calls = delegated()
        let out = dir.appendingPathComponent("shot.png").path
        let refused = await answer(calls, "view.snapshot", .object(["board": "brd_host", "out": .string(out)]))
        #expect(code(refused) == "unavailable")
        #expect(!FileManager.default.fileExists(atPath: out))
        let saved = try await answer(calls, "view.snapshot", .object(["board": "brd_host"])).get()
        let path = try #require(saved["path"]?.string)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().path == ApiRouter.scratchImages.path)
        #expect(FileManager.default.contents(atPath: path) == png)
        #expect(saved["viewport"] == viewport.json)
        #expect(saved["scale"] == .number(2))
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
        #expect(code(await answer(calls, "view.render", .object(["board": "brd_host", "target": .string(terminal)]))) == "unsupported")
        let shown = try await answer(calls, "view.get", .object(["board": "brd_host"])).get()
        #expect(shown == .object([
            "board": "brd_host", "viewport": .object(["rect": .object(["x": 0, "y": 0, "w": 1200, "h": 800]), "zoom": 1]),
            "selection": ["obj_note"], "visible": .bool(true), "appearance": "dark", "promptTarget": .string(terminal),
        ]))
    }
}
