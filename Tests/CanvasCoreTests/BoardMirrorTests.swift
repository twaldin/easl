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

    func mirror(rendersAt renderSocket: String? = nil) async throws -> (BoardMirror, Board) {
        // The whole suite keeps the main actor (the router's) busy for seconds at a time.
        let fast = EaslConnection.Backoff(initial: .milliseconds(50), maximum: .milliseconds(200))
        func link(_ path: String) -> EaslConnection { .unixSocket(path, backoff: fast, handshakeTimeout: .seconds(60)) }
        let mirror = BoardMirror(hostName: "home", board: host.id, connection: link(socket), renders: link(renderSocket ?? socket))
        mirrors.append(mirror)
        return (mirror, try await mirror.load())
    }

    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    func note(_ markdown: String, at x: Double = 0) -> CanvasObject {
        host.create(type: .note, props: .object(["markdown": .string(markdown)]), frame: Frame(x: x, y: 0, w: 280, h: 200))
    }

    // MARK: Host-drawn tiles

    /// The host's render link as the tiles see it, on a socket of its own: counts each
    /// `view.render` it gets by object and answers it with a canned image.
    let renderCounts = Locked<[ObjectID: Int]>([:])
    var renderSocket: String { dir.appendingPathComponent("r").path }
    var rendered: [ObjectID: Int] { renderCounts.withLock { $0 } }

    func serveRenders() -> SocketServer {
        let counts = renderCounts, router = router
        return SocketServer(path: renderSocket) { request, connection in
            guard request["method"]?.string == "view.render" else { return await router.handle(request, connection: connection) }
            counts.withLock { $0[request["params"]?["target"]?.string ?? "?", default: 0] += 1 }
            return .object(["id": request["id"] ?? .null, "ok": .bool(true), "result": .object([
                "data": .string(Data("not a picture".utf8).base64EncodedString()),
                "canvasRect": .object(["x": .number(0), "y": .number(0), "w": .number(10), "h": .number(10)]), "scale": .number(1),
            ])])
        }
    }

    /// What `CanvasView` does with a remote board's host-drawn tiles: one `RemoteDrawing` per
    /// object, drawn when the object appears, again when it changes, and when the mirror says so.
    @MainActor final class Tiles {
        private let mirror: BoardMirror
        private var drawings: [ObjectID: RemoteDrawing] = [:]
        /// How often the mirror said to draw again.
        private(set) var redraws = 0
        /// Each answer by object: whether it was the host's drawing.
        private(set) var answers: [ObjectID: [Bool]] = [:]

        init(_ mirror: BoardMirror, on board: Board) {
            self.mirror = mirror
            board.onEvent = { [unowned self] event in
                switch event {
                case .objectCreated(let object): add(object)
                case .objectUpdated(let object): drawings[object.id]?.changed()
                default: break
                }
            }
            mirror.onRedraw = { [unowned self] in
                redraws += 1
                for drawing in drawings.values { drawing.redraw() }
            }
            for object in board.objects.values { add(object) }
        }

        private func add(_ object: CanvasObject) {
            guard drawings[object.id] == nil else { return }
            let id = object.id
            let drawing = RemoteDrawing(object: id, mirror: mirror, settle: 0.2, scale: { 1 }, drawn: { [unowned self] outcome in
                if case .success = outcome { answers[id, default: []].append(true) } else { answers[id, default: []].append(false) }
            })
            drawings[id] = drawing
            drawing.draw()
        }
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

    /// Typed even into an omp that takes peer messages (`protocol`): the composer's prompt is never queued as one.
    @Test func theComposersPromptIsTypedOnTheHostAndAnswersABlockedAgent() async throws {
        let agent = host.create(type: .terminal, props: .object(["cwd": .string(dir.path), "name": .string("worker")])).id
        try host.reportLifecycle(tile: agent, kind: "omp", state: .idle, message: nil, seq: 1, source: nil, protocol: 1)
        let (mirror, _) = try await mirror()
        defer { mirror.close() }
        try await mirror.prompt("fix the build", to: agent, mentions: [], answer: false)
        #expect(typed[agent] == ["fix the build"])
        #expect(host.messages[agent]?.isEmpty ?? true)
        try host.reportLifecycle(tile: agent, kind: "omp", state: .blocked, message: "Run tests?", seq: 2, source: nil, protocol: 1)
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
            (#"{"target":"nobody","text":"x","composer":true,"from":"machine-watch"}"#, "takes no from"),
            (#"{"target":"nobody","text":"x","composer":true,"when":"next-turn"}"#, "takes no when"),
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

    // MARK: Host-drawn tiles after a reconnect (`RemoteDrawing`, `BoardMirror.onRedraw`)

    @Test func afterOnlyTheBoardLinkDropsEachTileDrawsOnceMoreAndOneBuiltMeanwhileDrawsOnce() async throws {
        let renderServer = serveRenders()
        try renderServer.start()
        defer { renderServer.stop() }
        let kept = note("kept"), changed = note("changed", at: 400)
        let (mirror, board) = try await mirror(rendersAt: renderSocket)
        defer { mirror.close() }
        let tiles = Tiles(mirror, on: board)
        try await eventually { rendered == [kept.id: 1, changed.id: 1] }
        // Only the board's link drops: the render link stays up while the host changes.
        server.stop()
        try await eventually { mirror.state != .online }
        #expect(mirror.rendersState == .online)
        #expect(tiles.redraws == 0, "nothing is drawn while the host can't be reached")
        let added = note("added while away", at: 800)
        _ = try host.update(changed.id, props: .object(["markdown": .string("changed while away")]))
        server = Self.serve(router, at: socket)
        try server.start()
        // The read makes the added object's tile (it asks for its drawing at once, the request not
        // sent yet) and tells the changed one's (its own redraw waits for the changes to settle);
        // then the mirror says "draw again". Each is asked for exactly once more, the new one once.
        try await eventually { tiles.redraws == 1 && board.objects[added.id] != nil }
        try await eventually { rendered == [kept.id: 2, changed.id: 2, added.id: 1] }
        try await eventually { tiles.answers.values.map(\.count).reduce(0, +) == 5 }
        // Every answer is in and the settle time has passed: nothing follows.
        try await Task.sleep(for: .milliseconds(800))
        #expect(rendered == [kept.id: 2, changed.id: 2, added.id: 1])
        #expect(tiles.redraws == 1)
        #expect(tiles.answers.values.flatMap { $0 }.allSatisfy { $0 }, "each answer was a drawing")
    }

    @Test func aRenderLinkConnectingHeardLateIsNoDropAndEachTileDrawsOnce() async throws {
        let renderServer = serveRenders()
        try renderServer.start()
        defer { renderServer.stop() }
        let first = note("first"), second = note("second", at: 400)
        let (mirror, board) = try await mirror(rendersAt: renderSocket)
        defer { mirror.close() }
        let tiles = Tiles(mirror, on: board)
        try await eventually { rendered == [first.id: 1, second.id: 1] }
        // The render link's first `connecting` reaches the mirror only now, after the board was
        // read and the tiles drew (a relay's launch can hold the link's queue for longer than the
        // board's read takes; the stream can't be held up here), and then its `online`: the first
        // connect, no disconnect, so nothing is drawn again.
        mirror.rendersChanged(.connecting)
        mirror.rendersChanged(.online)
        try await Task.sleep(for: .milliseconds(800))
        #expect(tiles.redraws == 0)
        #expect(rendered == [first.id: 1, second.id: 1])
    }

    @Test func aDrawingThatFailedBecauseTheRenderLinkWasDownIsAskedForOnceItIsBack() async throws {
        let first = note("first"), second = note("second", at: 400)
        // Nothing listens on the render socket: the link's first connect fails.
        let (mirror, board) = try await mirror(rendersAt: renderSocket)
        defer { mirror.close() }
        let tiles = Tiles(mirror, on: board)
        try await eventually { tiles.answers.values.flatMap { $0 } == [false, false] }
        #expect(rendered.isEmpty && tiles.redraws == 0)
        let renderServer = serveRenders()
        try renderServer.start()
        defer { renderServer.stop() }
        try await eventually { tiles.redraws == 1 }
        try await eventually { rendered == [first.id: 1, second.id: 1] }
        try await Task.sleep(for: .milliseconds(800))
        #expect(rendered == [first.id: 1, second.id: 1])
        #expect(tiles.redraws == 1)
        #expect(tiles.answers.values.flatMap { $0 }.sorted { !$0 && $1 } == [false, false, true, true])
    }

    @Test func theTilesDrawAgainOnlyOnceTheRenderLinkIsBackToo() async throws {
        // The render link has its own socket here, so it can be the last to come back.
        var renderServer = serveRenders()
        try renderServer.start()
        defer { renderServer.stop() }
        let kept = note("kept")
        let (mirror, board) = try await mirror(rendersAt: renderSocket)
        defer { mirror.close() }
        let tiles = Tiles(mirror, on: board)
        try await eventually { rendered == [kept.id: 1] }
        server.stop()
        renderServer.stop()
        try await eventually { mirror.state != .online && mirror.rendersState != .online }
        let added = note("added while away", at: 800)
        server = Self.serve(router, at: socket)
        try server.start()
        // The board link is back and read; nothing is drawn through a render link that is not.
        try await eventually { board.objects[added.id] != nil }
        #expect(mirror.state == .online && tiles.redraws == 0)
        renderServer = serveRenders()
        try renderServer.start()
        try await eventually { tiles.redraws == 1 }
        // The tile built while the render link was down failed at once; the one before it is drawn again.
        try await eventually { rendered == [kept.id: 2, added.id: 1] }
        try await Task.sleep(for: .milliseconds(800))
        #expect(rendered == [kept.id: 2, added.id: 1])
        #expect(tiles.redraws == 1)
    }

    /// Runs `body` once, on the main actor (a test's host changes, from a server's handler).
    @MainActor final class Once {
        var body: (() -> Void)?
        func run() {
            body?()
            body = nil
        }
    }

    @Test func whatTheHostChangesWhileTheViewerReadsItAgainStays() async throws {
        let edited = note("before")
        let doomed = note("doomed", at: 400)
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        server.stop()
        try await eventually { mirror.state != .online }
        // The read after the drop is answered with the board as it was, after the host changed
        // it: the changes' events reach the viewer ahead of that answer.
        var created: ObjectID?
        let once = Once()
        once.body = { [unowned self] in
            _ = try? host.update(edited.id, props: .object(["markdown": .string("changed during the read")]))
            try? host.delete(doomed.id)
            created = note("created during the read", at: 800).id
        }
        let router = router
        server = SocketServer(path: socket) { request, connection in
            let reply = await router.handle(request, connection: connection)
            if request["method"]?.string == "board.get" { await once.run() }
            return reply
        }
        try server.start()
        try await eventually { once.body == nil }
        try await eventually { mirror.reading == nil }
        let added = try #require(created)
        // The events left the host ahead of the read's answer, but the mirror's event listener and
        // its read are two tasks on the main actor: on a loaded machine the answer can be handled
        // first, and the events after it. Either way the board ends as the host's, never with the
        // read's older state undoing them.
        try await eventually {
            board.objects[edited.id] == host.objects[edited.id] && board.objects[doomed.id] == nil && board.objects[added] == host.objects[added]
        }
        #expect(board.objects[edited.id]?.props["markdown"]?.string == "changed during the read")
    }

    @Test func queuedWritesKeepTheHostRevisionTheyWereBasedOn() async throws {
        let moved = note("moved")
        let edited = note("edited", at: 400)
        let chained = note("chained", at: 800)
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        var notices: [String] = []
        mirror.onNotice = { notices.append($0) }
        // Nothing reaches the host before the host's own edits below: each viewer write is based
        // on the revision before them.
        // A move, then an edit made on its preview; the host's edit crossed both.
        _ = try board.update(moved.id, frame: Frame(x: 0, y: 300, w: 280, h: 200))
        _ = try board.update(moved.id, props: .object(["markdown": .string("the viewer's")]))
        _ = try host.update(moved.id, props: .object(["markdown": .string("the host's")]))
        // Two edits, the second made on the first's preview; the host's crossed both.
        _ = try board.update(edited.id, props: .object(["markdown": .string("first")]))
        _ = try board.update(edited.id, props: .object(["markdown": .string("second")]))
        _ = try host.update(edited.id, props: .object(["markdown": .string("the host's")]))
        // A move and an edit nobody crossed: the edit builds on the answered move.
        _ = try board.update(chained.id, frame: Frame(x: 800, y: 300, w: 280, h: 200))
        _ = try board.update(chained.id, props: .object(["markdown": .string("after the move")]))
        try await eventually { notices.count == 3 && host.objects[chained.id]?.props["markdown"]?.string == "after the move" }
        #expect(notices.allSatisfy { $0.contains("changed on home meanwhile") })
        #expect(host.objects[moved.id]?.frame.y == 300)
        #expect(host.objects[moved.id]?.props["markdown"]?.string == "the host's")
        #expect(host.objects[edited.id]?.props["markdown"]?.string == "the host's")
        #expect(host.objects[chained.id]?.frame.y == 300)
        try await eventually { [moved, edited, chained].allSatisfy { board.objects[$0.id] == host.objects[$0.id] } }
    }

    @Test func aNewObjectGoesOnUnderTheHostsIDWithWhatTheUserHadGoingOnIt() async throws {
        let (mirror, board) = try await mirror()
        defer { mirror.close() }
        var swaps: [(provisional: ObjectID, host: ObjectID)] = []
        board.onHostRekey = { provisional, id in
            // Heard while the provisional note is still here, so its open editor can be taken over.
            #expect(board.objects[provisional] != nil && board.objects[id] == nil)
            swaps.append((provisional, id))
        }
        let provisional = board.create(type: .note, props: .object(["markdown": .string("")]), frame: Frame(x: 0, y: 300, w: 280, h: 200))
        _ = try board.update(provisional.id, frame: Frame(x: 40, y: 320, w: 280, h: 200))
        try await eventually { swaps.count == 1 }
        let id = try #require(swaps.first).host
        #expect(swaps.first?.provisional == provisional.id)
        // The preview, the move queued behind the create included, goes on under the host's id.
        #expect(board.objects[provisional.id] == nil)
        #expect(board.objects[id]?.frame.x == 40)
        // The note's draft, saved under the host's id once editing ends, reaches the host.
        _ = try board.update(id, props: .object(["markdown": .string("typed before the host answered")]))
        try await eventually { host.objects[id]?.props["markdown"]?.string == "typed before the host answered" && host.objects[id]?.frame.x == 40 }
        try await eventually { board.objects[id] == host.objects[id] }
        #expect(host.objects.values.filter { $0.type == .note }.count == 1)
    }
}
