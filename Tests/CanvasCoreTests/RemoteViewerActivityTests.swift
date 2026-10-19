import Foundation
import Testing
@testable import CanvasCore

@MainActor
final class RemoteViewerActivityTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("rva-\(UUID().uuidString.prefix(8))")
    let activity = RemoteUpdateActivity()
    let registry: BoardRegistry
    let router: ApiRouter
    let host: Board
    let server: SocketServer
    let reports = Locked<[JSONValue]>([])
    let oldServer = Locked(false)
    var socket: String { dir.appendingPathComponent("s").path }

    init() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards"), debounce: 60))
        host = registry.open(root: dir.appendingPathComponent("root"))
        let router = ApiRouter(registry: registry, remoteActivity: activity)
        self.router = router
        let reports = reports, oldServer = oldServer
        server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            if request["method"]?.string == "viewer.activity" {
                reports.withLock { $0.append(request["params"] ?? .null) }
                if oldServer.withLock({ $0 }) {
                    return .object(["id": request["id"] ?? .null, "ok": .bool(false),
                                    "error": .object(["code": "invalid_params", "message": "unknown method viewer.activity"])])
                }
            }
            return await router.handle(request, connection: connection)
        }
        try server.start()
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func mirror() async throws -> BoardMirror {
        let mirror = BoardMirror(hostName: "host", board: host.id,
                                 connection: .unixSocket(socket), renders: .unixSocket(socket))
        _ = try await mirror.load()
        return mirror
    }

    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    func action(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> AppUpdate.AutomaticAction {
        let release = LatestRelease(version: AppVersion("0.2.10")!, url: URL(string: "https://example.com/easl.zip")!,
                                    sha256: String(repeating: "a", count: 64), size: 1,
                                    notes: URL(string: "https://example.com/notes")!)
        return AppUpdate.automaticAction(phase: .ready(release), running: AppVersion("0.2.9")!,
                                         enabled: true, idleSeconds: 600, remoteIdleSeconds: activity.idleSeconds(now: now))
    }

    @Test func boardInputDefersInstallationButAttachmentAndBackgroundTrafficDoNot() async throws {
        let note = host.create(type: .note, props: .object(["markdown": "before"]))
        let mirror = try await mirror()
        defer { mirror.close() }
        try await eventually { activity.sessions.array?.count == 1 }
        #expect(action() == .install)
        _ = try host.update(note.id, props: .object(["markdown": "background edit"]))
        _ = try await mirror.connection.request("board.get", .object(["board": .string(host.id)]))
        #expect(action() == .install)

        mirror.userInput()
        try await eventually { action() == .none }
        let session = try #require(activity.sessions.array?.first)
        #expect(session["kind"] == "board")
        #expect(session["board"] == .string(host.id))
        #expect(session["tile"] == .null)
        mirror.close()
        try await eventually { activity.sessions == .array([]) }
        #expect(action() == .none)
    }

    @Test func terminalTypingDefersWithoutAnAgentPromptAndDeletionEndsItsWarning() async throws {
        let terminal = host.create(type: .terminal, props: .object([:]))
        let mirror = try await mirror()
        defer { mirror.close() }
        try await eventually { activity.sessions.array?.map { $0["kind"] } == [.string("board")] }
        #expect(action() == .install)

        mirror.userInput(terminal: terminal.id)
        try await eventually { action() == .none }
        let session = try #require(activity.sessions.array?.first { $0["kind"] == "terminal" })
        #expect(session["board"] == .string(host.id))
        #expect(session["tile"] == .string(terminal.id))
        try host.delete(terminal.id)
        #expect(activity.sessions.array?.map { $0["kind"] } == [.string("board")])
        #expect(action() == .none)
        registry.setWindowOpen(false, board: host.id)
        #expect(activity.sessions == .array([]))
        #expect(action() == .none)
    }

    @Test func coalescingSendsTheFinalInputInsteadOfShorteningItsProtection() async throws {
        let mirror = try await mirror()
        defer { mirror.close() }
        try await eventually { activity.sessions.array?.count == 1 }
        mirror.userInput()
        try await eventually { reports.withLock { $0.filter { $0["input"] == .bool(true) }.count == 1 } }
        try await Task.sleep(for: .milliseconds(50))
        mirror.userInput()
        mirror.userInput()
        mirror.userInput()
        let finalInput = ProcessInfo.processInfo.systemUptime
        try await eventually { reports.withLock { $0.filter { $0["input"] == .bool(true) }.count == 2 } }
        _ = try await mirror.connection.request("system.ping")
        #expect(action(now: finalInput + 599.999) == .none)
    }

    @Test func receiverRejectsUnattachedAndMissingTargetsWithoutInventingActivity() async throws {
        let link = EaslConnection.unixSocket(socket)
        defer { link.close() }
        try await eventually { link.state == .online }
        do {
            _ = try await link.request("viewer.activity", .object(["board": .string(host.id), "input": .bool(true)]))
            Issue.record("An unsubscribed connection must not report viewer activity")
        } catch let failure as EaslConnection.Failure {
            #expect(failure.code == "invalid_params")
        }
        let note = host.create(type: .note, props: .object(["markdown": "not a terminal"]))
        let mirror = try await mirror()
        defer { mirror.close() }
        try await eventually { activity.sessions.array?.count == 1 }
        let invalidReports: [JSONValue] = [
            .object(["board": .string(host.id), "terminal": .string(note.id), "input": .bool(true)]),
            .object(["board": "brd_missing", "input": .bool(true)]),
        ]
        for params in invalidReports {
            do {
                _ = try await mirror.connection.request("viewer.activity", params)
                Issue.record("A missing activity target must be refused")
            } catch let failure as EaslConnection.Failure {
                #expect(failure.code == "not_found")
            }
        }
        #expect(action() == .install)
        #expect(activity.sessions.array?.map { $0["kind"] } == [.string("board")])
    }

    @Test func oldHostRefusalPreservesEditingAndReconnectRenegotiatesActivity() async throws {
        oldServer.withLock { $0 = true }
        let note = host.create(type: .note, props: .object(["markdown": "before"]))
        let mirror = try await mirror()
        defer { mirror.close() }
        try await eventually { reports.withLock { $0.count == 1 } }
        _ = try await mirror.connection.request("system.ping")
        mirror.userInput()
        _ = try mirror.board?.update(note.id, props: .object(["markdown": "after"]))
        try await eventually { host.objects[note.id]?.props["markdown"] == "after" }
        #expect(reports.withLock { $0 } == [.object(["board": .string(host.id), "input": .bool(false)])])
        #expect(mirror.state == .online)
        #expect(action() == .install)
        server.stop()
        try await eventually { mirror.connection.state != .online }
        oldServer.withLock { $0 = false }
        try server.start()
        mirror.reconnect()
        try await eventually { activity.sessions.array?.map { $0["kind"] } == [.string("board")] }
        #expect(action() == .install)
        mirror.userInput()
        try await eventually { action() == .none }
    }
}
