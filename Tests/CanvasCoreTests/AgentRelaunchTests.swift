import Foundation
import Testing
import CanvasCore

/// An agent's lifecycle across an easl quit and relaunch: each launch is a new registry, router
/// and socket on the same board store, as the app sets them up; what an integration said while
/// easl was away waits in the spool (`AgentReportSpool`, written by extensions/agent-hooks/report.ts).
@MainActor
final class AgentRelaunchTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-\(UUID().uuidString.prefix(8))")
    var root: URL { dir.appendingPathComponent("root") }
    var spool: URL { dir.appendingPathComponent("agent-reports") }
    var servers: [SocketServer] = []
    /// Text `agent.prompt` typed into a terminal, any launch.
    var typed: [String] = []

    @MainActor
    struct Launch {
        let registry: BoardRegistry
        let board: Board
        let socket: String

        func quit() {
            registry.store.save(board)
        }
    }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        for server in servers { server.stop() }
        try? FileManager.default.removeItem(at: dir)
    }

    func launch() async throws -> Launch {
        let registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards"), debounce: 60), agentReports: spool)
        let board = await registry.open(root: root)
        let router = ApiRouter(registry: registry)
        router.submitToTerminal = { [unowned self] _, _, text in
            typed.append(text)
            return true
        }
        let socket = dir.appendingPathComponent("s\(servers.count)").path
        let server = SocketServer(path: socket) { request, connection in await router.handle(request, connection: connection) }
        try server.start()
        servers.append(server)
        return Launch(registry: registry, board: board, socket: socket)
    }

    /// A report the integration couldn't deliver, as report.ts spools it.
    @discardableResult
    func spooled(_ tile: ObjectID, seq: Int, method: String = "agent.report", _ params: [String: JSONValue]) throws -> URL {
        let folder = spool.appendingPathComponent(tile, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var params = params
        params["tile"] = .string(tile)
        let entry: JSONValue = .object(["seq": .number(Double(seq)), "method": .string(method), "params": .object(params)])
        let file = folder.appendingPathComponent("\(seq)-1-\(UUID().uuidString.prefix(8)).json")
        try JSONEncoder().encode(entry).write(to: file)
        return file
    }

    func spoolIsEmpty(_ tile: ObjectID) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: spool.appendingPathComponent(tile).path)) ?? []).isEmpty
    }

    /// Waits (up to 3 s) for the replay that opening the board started.
    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    func call(_ launch: Launch, _ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let client = try LineClient(path: launch.socket)
        let request: JSONValue = .object(["id": .string(method), "method": .string(method), "params": .object(params)])
        client.send(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        return try await client.next()
    }

    @Test func anAgentThatFinishedWhileCanvasWasAwayComesBackDoneWithItsAnswer() async throws {
        let before = try await launch()
        let codex = before.board.create(type: .terminal, props: .object(["cwd": .string(root.path)])).id
        try before.board.reportLifecycle(tile: codex, kind: "codex", state: .working, message: nil, seq: 100, source: "canvas-codex")
        before.quit()

        // Codex worked on and finished while easl was closed; its hooks spooled every report.
        // One from before the last applied report (it timed out as easl quit) is stale.
        try spooled(codex, seq: 50, ["kind": "codex", "state": "idle", "source": "canvas-codex", "final": "an older answer"])
        try spooled(codex, seq: 150, ["kind": "codex", "state": "working", "source": "canvas-codex", "call": "f0c82fec96cbd7c6"])
        try spooled(codex, seq: 200, ["kind": "codex", "state": "idle", "source": "canvas-codex", "final": "No blocking findings in d93c070."])

        let after = try await launch()
        func lifecycle() -> JSONValue? { after.board.objects[codex]?.props["lifecycle"] }
        try await eventually { lifecycle()?["state"] == .string("done") }
        #expect(lifecycle()?["seen"] == .bool(false), "unseen: the user hasn't read it")
        #expect(NeedsYouItem.all(after.board.objects, attention: after.board.attention).map(\.id) == [codex], "⌘J goes to it")
        let waited = try await call(after, "agent.wait", ["target": .string(codex), "timeoutMs": 2000])
        #expect(waited["result"]?["agent"]?["lifecycle"]?["state"] == .string("done"), "\(waited)")
        let final = try await call(after, "agent.read", ["target": .string(codex), "final": .bool(true)])
        #expect(final["result"]?["text"] == .string("No blocking findings in d93c070."), "\(final)")
        try await eventually { spoolIsEmpty(codex) }
    }

    @Test func theLastAnswerOutlastsARelaunchUntilTheNextTurn() async throws {
        let before = try await launch()
        let omp = before.board.create(type: .terminal, props: .object(["cwd": .string(root.path)])).id
        try before.board.reportLifecycle(tile: omp, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        try before.board.reportLifecycle(tile: omp, kind: "omp", state: .idle, message: nil, seq: 2, source: "canvas-omp", final: "Committed d327349.")
        before.board.markSeen(omp)
        before.quit()

        let after = try await launch()
        let final = try await call(after, "agent.read", ["target": .string(omp), "final": .bool(true)])
        #expect(final["result"]?["text"] == .string("Committed d327349."), "\(final)")
        // A report older than one applied before the quit is stale after it too.
        try after.board.reportLifecycle(tile: omp, kind: "omp", state: .working, message: nil, seq: 2, source: "canvas-omp")
        #expect(after.board.objects[omp]?.props["lifecycle"]?["state"] == .string("idle"))
        // The next turn clears it.
        try after.board.reportLifecycle(tile: omp, kind: "omp", state: .working, message: nil, seq: 3, source: "canvas-omp")
        try after.board.reportLifecycle(tile: omp, kind: "omp", state: .idle, message: nil, seq: 4, source: "canvas-omp")
        #expect(try await call(after, "agent.read", ["target": .string(omp), "final": .bool(true)])["error"]?["code"] == .string("unavailable"))
    }

    @Test func anAgentThatExitedWhileCanvasWasAwayComesBackReleased() async throws {
        let before = try await launch()
        let omp = before.board.create(type: .terminal, props: .object(["cwd": .string(root.path)])).id
        try before.board.reportLifecycle(tile: omp, kind: "omp", state: .working, message: nil, seq: 100, source: "canvas-omp")
        try before.board.reportLifecycle(tile: omp, kind: "omp", state: .idle, message: nil, seq: 200, source: "canvas-omp")
        before.quit()

        // A release older than the last report applied (a new session had started) is stale.
        try spooled(omp, seq: 150, method: "agent.release", ["kind": "omp", "source": "canvas-omp"])
        let stale = try await launch()
        try await eventually { spoolIsEmpty(omp) }
        #expect(stale.board.objects[omp]?.props["lifecycle"]?["state"] == .string("done"))
        stale.quit()

        try spooled(omp, seq: 300, method: "agent.release", ["kind": "omp", "source": "canvas-omp"])
        let after = try await launch()
        try await eventually { after.board.objects[omp]?.props["agent"] == nil }
        #expect(after.board.objects[omp]?.props["lifecycle"] == nil, "a plain shell again")
    }

    @Test func anAgentThatAskedWhileCanvasWasAwayIsBlockedAndAPromptIsRefused() async throws {
        let before = try await launch()
        let omp = before.board.create(type: .terminal, props: .object(["cwd": .string(root.path)])).id
        try before.board.reportLifecycle(tile: omp, kind: "omp", state: .working, message: nil, seq: 100, source: "canvas-omp")
        before.quit()

        // omp's `ask` came up while easl was closed; the extension spooled its blocked report.
        try spooled(omp, seq: 101, ["kind": "omp", "state": "blocked", "source": "canvas-omp", "message": "Commit?"])
        let after = try await launch()
        func lifecycle() -> JSONValue? { after.board.objects[omp]?.props["lifecycle"] }
        try await eventually { lifecycle()?["state"] == .string("blocked") }
        #expect(lifecycle()?["message"] == .string("Commit?") && lifecycle()?["restored"] == nil, "confirmed by the replay")
        #expect(NeedsYouItem.all(after.board.objects, attention: after.board.attention).map(\.reason) == [.blocked], "⌘J goes to it")
        let refused = try await call(after, "agent.prompt", ["target": .string(omp), "text": "Don't commit yet"])
        #expect(refused["error"]?["code"] == .string("conflict"))
        #expect(refused["error"]?["message"]?.string?.contains("Commit?") == true, "\(refused)")
        #expect(typed.isEmpty, "Return never picked the dialog's default")
    }

    @Test func aWorkingStateNobodyConfirmedSinceTheRelaunchIsNotTypedInto() async throws {
        let before = try await launch()
        let omp = before.board.create(type: .terminal, props: .object(["cwd": .string(root.path)])).id
        try before.board.reportLifecycle(tile: omp, kind: "omp", state: .working, message: nil, seq: 100, source: "canvas-omp")
        before.quit()

        // An extension from before the spool dropped what it said while easl was closed.
        let after = try await launch()
        let listed = try await call(after, "agent.list", [:])["result"]?["agents"]?.array?.first
        #expect(listed?["lifecycle"]?["state"] == .string("working") && listed?["lifecycle"]?["restored"] == .bool(true), "\(String(describing: listed))")
        let refused = try await call(after, "agent.prompt", ["target": .string(omp), "text": "Don't commit yet"])
        #expect(refused["error"]?["code"] == .string("conflict"), "\(refused)")
        #expect(typed.isEmpty)
        let forced = try await call(after, "agent.prompt", ["target": .string(omp), "text": "Don't commit yet", "force": .bool(true)])
        #expect(forced["result"]?["waitable"] == .bool(true))
        #expect(typed == ["Don't commit yet"])
        // Its next report is live again.
        try after.board.reportLifecycle(tile: omp, kind: "omp", state: .working, message: nil, seq: 101, source: "canvas-omp")
        #expect(after.board.objects[omp]?.props["lifecycle"]?["restored"] == nil)
        #expect(try await call(after, "agent.prompt", ["target": .string(omp), "text": "also the branch"])["ok"] == .bool(true))
    }

    @Test func aReportCanvasCouldNotReadWaitsForTheNextOpenWhileAFileThatIsNoReportIsDeleted() throws {
        let manager = FileManager.default
        let codex = "obj_codex"
        let report = try spooled(codex, seq: 200, ["kind": "codex", "state": "idle", "source": "canvas-codex", "final": "Done."])
        let garbage = spool.appendingPathComponent(codex).appendingPathComponent("junk.json")
        try Data("not a report".utf8).write(to: garbage)

        // Unreadable at this open (permissions): left out, and left in place.
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: report.path)
        #expect(AgentReportSpool.read(from: spool, tiles: [codex]).isEmpty)
        #expect(manager.fileExists(atPath: report.path))
        #expect(!manager.fileExists(atPath: garbage.path), "a file that reads but isn't a report goes")

        // Readable at the next open: replayed.
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: report.path)
        #expect(AgentReportSpool.read(from: spool, tiles: [codex]).map(\.seq) == [200])
    }
}
