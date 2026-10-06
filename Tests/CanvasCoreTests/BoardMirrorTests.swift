import Foundation
import Testing
@testable import CanvasCore

/// A remote board (docs/design.md "Client mode"): a `BoardMirror` of a board served by a real
/// router over a real socket, as a viewer reaches its host (the ssh relay is just the transport).
@MainActor
final class BoardMirrorTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("bm-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let router: ApiRouter
    var server: SocketServer
    let host: Board
    var socket: String { dir.appendingPathComponent("s").path }
    var mirrors: [BoardMirror] = []
    /// What each host terminal was sent, in order.
    var typed: [ObjectID: [String]] = [:]

    init() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards"), debounce: 60))
        host = registry.open(root: dir.appendingPathComponent("root"))
        router = ApiRouter(registry: registry)
        server = Self.serve(router, at: dir.appendingPathComponent("s").path)
        try server.start()
        router.submitToTerminal = { [unowned self] _, tile, text in
            typed[tile, default: []].append(text)
            return true
        }
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    static func serve(_ router: ApiRouter, at path: String) -> SocketServer {
        SocketServer(path: path) { request, connection in await router.handle(request, connection: connection) }
    }

    func mirror() async throws -> (BoardMirror, Board) {
        let fast = EaslConnection.Backoff(initial: .milliseconds(50), maximum: .milliseconds(200))
        let mirror = BoardMirror(hostName: "home", board: host.id, connection: .unixSocket(socket, backoff: fast), renders: .unixSocket(socket, backoff: fast))
        mirrors.append(mirror)
        return (mirror, try await mirror.load())
    }

    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    func note(_ markdown: String, at x: Double = 0) -> CanvasObject {
        host.create(type: .note, props: .object(["markdown": .string(markdown)]), frame: Frame(x: x, y: 0, w: 280, h: 200))
    }

    @Test func theViewerShowsTheHostsBoardWholeAndFollowsItsChanges() async throws {
        let long = String(repeating: "word ", count: 120)
        let first = note(long)
        let shape = host.create(type: .shape, props: .object(["kind": .string("rect")]), frame: Frame(x: 400, y: 0, w: 100, h: 80))
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        #expect(board.isRemote)
        // board.get cuts a long note; the viewer reads it whole.
        #expect(board.objects[first.id]?.props["markdown"]?.string == long)
        #expect(board.objects[shape.id] == host.objects[shape.id])

        _ = try host.update(first.id, frame: Frame(x: 50, y: 60, w: 280, h: 200))
        try await eventually { board.objects[first.id]?.frame.x == 50 }
        #expect(board.objects[first.id]?.rev == host.objects[first.id]?.rev)
        try host.delete(shape.id)
        try await eventually { board.objects[shape.id] == nil }
        let added = note("new on the host", at: 900)
        try await eventually { board.objects[added.id] != nil }
    }

    @Test func aMoveShowsAtOnceAndTheHostsVersionReplacesIt() async throws {
        let moved = note("drag me")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        _ = try board.update(moved.id, frame: Frame(x: 300, y: 40, w: 280, h: 200))
        #expect(board.objects[moved.id]?.frame.x == 300)
        try await eventually { host.objects[moved.id]?.frame.x == 300 }
        try await eventually { board.objects[moved.id] == host.objects[moved.id] }
        // And the other way.
        _ = try host.update(moved.id, frame: Frame(x: 10, y: 10, w: 280, h: 200))
        try await eventually { board.objects[moved.id]?.frame.x == 10 }
    }

    @Test func anEditThatCrossedTheHostsIsRefusedAndTheHostsTextComesBack() async throws {
        let edited = note("before")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        var notices: [String] = []
        mirror.onNotice = { notices.append($0) }
        // Nothing can arrive between these two: the viewer's edit is based on the old revision.
        _ = try host.update(edited.id, props: .object(["markdown": .string("the host's")]))
        _ = try board.update(edited.id, props: .object(["markdown": .string("the viewer's")]))
        #expect(board.objects[edited.id]?.props["markdown"]?.string == "the viewer's")
        try await eventually { board.objects[edited.id]?.props["markdown"]?.string == "the host's" }
        #expect(host.objects[edited.id]?.props["markdown"]?.string == "the host's")
        #expect(notices.count == 1 && notices[0].contains("changed on home meanwhile"))
    }

    @Test func createsAndDeletesGoToTheHost() async throws {
        let doomed = note("delete me")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        let provisional = board.create(type: .note, props: .object(["markdown": .string("from the viewer")]), frame: Frame(x: 600, y: 0, w: 280, h: 200))
        _ = try board.update(provisional.id, frame: Frame(x: 640, y: 20, w: 280, h: 200))
        try board.delete(doomed.id)
        #expect(board.objects[doomed.id] == nil)
        try await eventually { host.objects[doomed.id] == nil }
        func made() -> [CanvasObject] { host.objects.values.filter { $0.props["markdown"]?.string == "from the viewer" } }
        try await eventually { made().first?.frame.x == 640 }
        #expect(made().count == 1)
        let created = try #require(made().first)
        // The provisional object made way for the host's, under the host's id.
        try await eventually { board.objects[provisional.id] == nil && board.objects[created.id] == created }
        #expect(board.objects.values.filter { $0.props["markdown"]?.string == "from the viewer" }.count == 1)
    }

    @Test func theAppsWriteBacksStayWithTheHost() async throws {
        let anchored = note("plain")
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        _ = try board.update(anchored.id, props: .object(["markdown": .string("rewritten by the app")]), actor: .system)
        #expect(board.objects[anchored.id]?.props["markdown"]?.string == "plain")
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.objects[anchored.id]?.props["markdown"]?.string == "plain")
    }

    @Test func theComposersPromptIsTypedOnTheHostAndAnswersABlockedAgent() async throws {
        let agent = host.create(type: .terminal, props: .object(["cwd": .string(dir.path), "name": .string("worker")])).id
        try host.reportLifecycle(tile: agent, kind: "omp", state: .idle, message: nil, seq: 1, source: nil)
        let (mirror, _) = try await mirror()
        defer { mirror.close() }
        try await mirror.prompt("fix the build", to: agent, mentions: [], answer: false)
        #expect(typed[agent] == ["fix the build"])
        try host.reportLifecycle(tile: agent, kind: "omp", state: .blocked, message: "Run tests?", seq: 2, source: nil)
        await #expect(throws: ApiRouter.Failure.self) { try await mirror.prompt("more", to: agent, mentions: [], answer: false) }
        try await mirror.prompt("yes", to: agent, mentions: [], answer: true)
        #expect(typed[agent] == ["fix the build", "yes"])
    }

    @Test func theHostChecksComposerParamsBeforeAnythingElse() async throws {
        let client = try LineClient(path: socket)
        for (params, message) in [
            (#"{"target":"nobody","text":"x","answer":true}"#, "needs composer: true"),
            (#"{"target":"nobody","text":"x","composer":true,"caller":"obj_1"}"#, "takes no caller"),
            (#"{"target":"nobody","text":"x","composer":true,"force":true}"#, "never forces"),
        ] {
            client.send(#"{"id":"1","method":"agent.prompt","params":\#(params)}"#)
            let reply = try await client.next()
            #expect(reply["error"]?["code"]?.string == "invalid_params")
            #expect(reply["error"]?["message"]?.string?.contains(message) == true)
        }
        client.send(#"{"id":"2","method":"view.render","params":{"target":"nobody","inline":true,"out":"/tmp/x.png"}}"#)
        #expect(try await client.next()["error"]?["code"]?.string == "invalid_params")
    }

    @Test func backOnlineTheViewerCatchesUpWithWhatChangedMeanwhile() async throws {
        let kept = note("kept")
        let gone = note("gone", at: 400)
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        var states: [EaslConnection.State] = []
        mirror.onState = { states.append($0) }
        server.stop()
        try await eventually { mirror.state != .online }
        try host.delete(gone.id)
        _ = try host.update(kept.id, props: .object(["markdown": .string("changed while away")]))
        let added = note("added while away", at: 800)
        server = Self.serve(router, at: socket)
        try server.start()
        try await eventually { mirror.state == .online }
        try await eventually { board.objects[gone.id] == nil && board.objects[added.id] != nil && board.objects[kept.id] == host.objects[kept.id] }
        #expect(states.last == .online && states.contains { $0 != .online })
    }
}
