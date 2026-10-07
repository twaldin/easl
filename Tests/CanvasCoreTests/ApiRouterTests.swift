import CoreGraphics
import Darwin
import Foundation
import Testing
import CanvasCore

/// Drives the real SocketServer + ApiRouter over a Unix socket, the way clients do.
@MainActor
final class ApiRouterTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let router: ApiRouter
    let server: SocketServer
    let board: Board
    var submitted: [String] = []

    init() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards")))
        board = registry.open(root: dir.appendingPathComponent("root"))
        let router = ApiRouter(registry: registry)
        self.router = router
        server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        router.submitToTerminal = { [unowned self] _, _, text in
            submitted.append(text)
            return true
        }
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func connect() throws -> LineClient { try LineClient(path: dir.appendingPathComponent("s").path) }

    func terminal() -> ObjectID {
        board.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
    }

    @Test func waitAfterPromptIgnoresThePrePromptIdle() async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp")
        let client = try connect()

        client.send(#"{"id":"p","method":"agent.prompt","params":{"target":"\#(tile)","text":"explain the repo"}}"#)
        #expect(try await client.next()["ok"] == .bool(true))
        #expect(submitted == ["explain the repo"])

        // The agent is still idle from before the prompt; the wait must not resolve from that.
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(tile)"}}"#)
        client.send(#"{"id":"ping1","method":"system.ping","params":{}}"#)
        #expect(try await client.next()["id"] == .string("ping1"))

        try board.reportLifecycle(tile: tile, kind: "omp", state: .working, message: nil, seq: 2, source: "canvas-omp")
        client.send(#"{"id":"ping2","method":"system.ping","params":{}}"#)
        #expect(try await client.next()["id"] == .string("ping2"))

        try board.reportLifecycle(tile: tile, kind: "omp", state: .idle, message: nil, seq: 3, source: "canvas-omp")
        let reply = try await client.next()
        #expect(reply["id"] == .string("w"))
        #expect(reply["result"]?["agent"]?["lifecycle"]?["state"] == .string("done"), "idle after work, unseen, is done")
    }

    @Test func aPromptThatStartsNoTurnEndsTheWaitOnceItsGraceIsOver() async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "codex", state: .idle, message: nil, seq: 1, source: "canvas-codex")
        router.promptStartGrace = 0.4
        let client = try connect()
        // A slash command is no turn: Codex's hook reports nothing for it, and the tile stays idle.
        #expect(try await call(client, "agent.prompt", ["target": .string(tile), "text": "/status"])["result"]?["waitable"] == .bool(true))
        // Not the pre-prompt idle: the prompt's grace ran out (rather than hanging until the timeout).
        let waited = try await call(client, "agent.wait", ["target": .string(tile), "timeoutMs": 5000])
        #expect(waited["error"]?["code"] == .string("unavailable"), "\(waited)")
        #expect(waited["error"]?["message"]?.string?.contains("started no turn") == true)

        // Another prompt arriving mid-wait moves the grace on; the wait still ends when it runs out.
        _ = try await call(client, "agent.prompt", ["target": .string(tile), "text": "/status"])
        client.send(#"{"id":"w0","method":"agent.wait","params":{"target":"\#(tile)","timeoutMs":5000}}"#)
        try await Task.sleep(for: .milliseconds(200))
        _ = try await call(try connect(), "agent.prompt", ["target": .string(tile), "text": "/model"])
        let moved = try await client.next()
        #expect(moved["id"] == .string("w0") && moved["error"]?["code"] == .string("unavailable"), "\(moved)")

        // A prompt that does start its turn within the grace is waited on to its end, however long.
        _ = try await call(client, "agent.prompt", ["target": .string(tile), "text": "explain the repo"])
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(tile)"}}"#)
        try board.reportLifecycle(tile: tile, kind: "codex", state: .working, message: nil, seq: 2, source: "canvas-codex")
        try await Task.sleep(for: .milliseconds(600))
        client.send(#"{"id":"ping","method":"system.ping","params":{}}"#)
        #expect(try await client.next()["id"] == .string("ping"), "still in its turn past the grace")
        try board.reportLifecycle(tile: tile, kind: "codex", state: .idle, message: nil, seq: 3, source: "canvas-codex")
        let reply = try await client.next()
        #expect(reply["id"] == .string("w") && reply["result"]?["agent"]?["lifecycle"]?["state"] == .string("done"))
    }

    @Test func waitWithoutPromptAnswersFromCurrentState() async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "omp", state: .blocked, message: "approve bash", seq: 1, source: "canvas-omp")
        let client = try connect()
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(tile)"}}"#)
        let reply = try await client.next()
        #expect(reply["result"]?["agent"]?["lifecycle"]?["state"] == .string("blocked"))
        #expect(reply["result"]?["agent"]?["lifecycle"]?["message"] == .string("approve bash"))
    }

    @Test func waitTimesOutWithTimeoutCode() async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        let client = try connect()
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(tile)","until":["idle"],"timeoutMs":30}}"#)
        let reply = try await client.next()
        #expect(reply["ok"] == .bool(false))
        #expect(reply["error"]?["code"] == .string("timeout"))
    }

    @Test func waitRejectsAnUntilThatIsNotAnArrayOfStates() async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp")
        let client = try connect()
        for until in [#""working""#, #"["working","busy"]"#] {
            client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(tile)","until":\#(until)}}"#)
            let reply = try await client.next()
            #expect(reply["error"]?["code"] == .string("invalid_params"), "until \(until) must not wait for the default states: \(reply)")
        }
    }

    @Test func waitFailsWhenTheTerminalCloses() async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        let client = try connect()
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(tile)","until":["idle"]}}"#)
        client.send(#"{"id":"ping","method":"system.ping","params":{}}"#)
        #expect(try await client.next()["id"] == .string("ping"))
        try board.delete(tile)
        let reply = try await client.next()
        #expect(reply["id"] == .string("w"))
        #expect(reply["error"]?["code"] == .string("not_found"))
    }

    @Test func terminalsWithoutAReportingAgentAreListedAndCantBeWaitedOn() async throws {
        let shell = terminal()
        let omp = terminal()
        try board.reportLifecycle(tile: omp, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp")
        let client = try connect()
        let agents = try await call(client, "agent.list", [:])["result"]?["agents"]?.array ?? []
        let byTile = Dictionary(uniqueKeysWithValues: agents.compactMap { entry in entry["tile"]?.string.map { ($0, entry) } })
        #expect(Set(byTile.keys) == [shell, omp], "every terminal, reporting or not")
        #expect(byTile[shell]?["kind"] == .string("unknown"))
        #expect(byTile[shell]?["lifecycle"]?["state"] == .string("unknown"))
        #expect(byTile[omp]?["kind"] == .string("omp"))

        // Prompting works; the reply says a wait can't follow it, and a wait on a terminal that
        // stays silent through the first-report grace fails.
        router.firstReportGrace = 0.3
        let prompted = try await call(client, "agent.prompt", ["target": .string(shell), "text": "make test"])
        #expect(prompted["result"]?["waitable"] == .bool(false))
        let waited = try await call(client, "agent.wait", ["target": .string(shell), "timeoutMs": 60000])
        #expect(waited["error"]?["code"] == .string("unavailable"))
        #expect(waited["error"]?["message"]?.string?.contains("reports no agent lifecycle") == true)
        // Asking for `unknown` itself is answered.
        let unknown = try await call(client, "agent.wait", ["target": .string(shell), "until": ["unknown"]])
        #expect(unknown["result"]?["agent"]?["tile"] == .string(shell))
    }

    @Test func anAgentReportingByNotificationIsWaitedOnUntilItsNextNotification() async throws {
        let aider = terminal()
        // bin/aider says an agent runs here as aider starts.
        try board.reportLifecycle(tile: aider, kind: "aider", state: .unknown, message: nil, seq: nil, source: nil)
        router.firstReportGrace = 0.1
        let client = try connect()
        let prompted = try await call(client, "agent.prompt", ["target": .string(aider), "text": "fix the trailing slash"])
        #expect(prompted["result"]?["waitable"] == .bool(true))
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(aider)"}}"#)
        try await Task.sleep(for: .milliseconds(300))
        client.send(#"{"id":"ping","method":"system.ping","params":{}}"#)
        #expect(try await client.next()["id"] == .string("ping"), "past the first-report grace, still waiting")
        board.terminalNotified(aider, message: "aider: waiting for you", bell: false, program: "aider", watched: false)
        let reply = try await client.next()
        #expect(reply["id"] == .string("w"))
        #expect(reply["result"]?["agent"]?["lifecycle"]?["state"] == .string("done"))
        #expect(reply["result"]?["agent"]?["lifecycle"]?["message"] == .string("aider: waiting for you"))
        // The next prompt: unknown again until the next notification, never the stale done.
        _ = try await call(client, "agent.prompt", ["target": .string(aider), "text": "/add url.go"])
        #expect(board.objects[aider]?.props["lifecycle"]?["state"] == .string("unknown"))
        // Nothing in it drains handed mentions.
        let note = board.create(type: .note, props: .object(["markdown": .string("x")])).id
        let handed = try await call(client, "agent.prompt", ["target": .string(aider), "text": "see this", "mentions": .array([.object(["object": .string(note)])])])
        #expect(handed["error"]?["code"] == .string("unavailable"))
    }

    @Test func listedAgentsSayWhichBoardAndRootTheyAreOn() async throws {
        let here = terminal()
        let otherRoot = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let other = registry.open(root: otherRoot)
        let there = other.create(type: .terminal, props: .object(["cwd": .string(otherRoot.path)])).id
        let client = try connect()
        let agents = try await call(client, "agent.list", [:])["result"]?["agents"]?.array ?? []
        let byTile = Dictionary(uniqueKeysWithValues: agents.compactMap { entry in entry["tile"]?.string.map { ($0, entry) } })
        #expect(byTile[here]?["board"] == .string(board.id))
        #expect(byTile[here]?["root"] == .string(board.root.path))
        #expect(byTile[there]?["board"] == .string(other.id))
        #expect(byTile[there]?["root"] == .string(otherRoot.path))
    }

    @Test func aWaitOnAnAgentJustLaunchedWaitsForItsFirstReport() async throws {
        let fresh = terminal()
        // The grace outlasts a loaded CI runner's round trip: what's tested is that the wait stays open.
        router.firstReportGrace = 60
        let client = try connect()
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(fresh)","timeoutMs":60000}}"#)
        client.send(#"{"id":"ping","method":"system.ping","params":{}}"#)
        #expect(try await client.next()["id"] == .string("ping"), "the wait is still open")
        try board.reportLifecycle(tile: fresh, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp")
        let reply = try await client.next()
        #expect(reply["id"] == .string("w"))
        #expect(reply["result"]?["agent"]?["lifecycle"]?["state"] == .string("idle"))
    }

    @Test func aWaitOnAnAgentThatExitsFailsInsteadOfHanging() async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        let client = try connect()
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(tile)"}}"#)
        client.send(#"{"id":"ping","method":"system.ping","params":{}}"#)
        #expect(try await client.next()["id"] == .string("ping"))
        try board.releaseAgent(tile: tile)
        let reply = try await client.next()
        #expect(reply["id"] == .string("w"))
        #expect(reply["error"]?["code"] == .string("unavailable"))
    }

    @Test func promptSaysItCanBeWaitedOnForAnAgentThatReports() async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp")
        let client = try connect()
        let prompted = try #require(try await call(client, "agent.prompt", ["target": .string(tile), "text": "go"])["result"])
        #expect(prompted["waitable"] == .bool(true))
        #expect(prompted["submittedAt"]?.string.flatMap { try? Date($0, strategy: .iso8601) } != nil)
    }

    @Test func promptingABlockedAgentIsRefusedUnlessForced() async throws {
        let tile = terminal()
        try board.reportLifecycle(tile: tile, kind: "omp", state: .blocked, message: "Which flag should --pair use?", seq: 1, source: "canvas-omp")
        let client = try connect()
        let refused = try await call(client, "agent.prompt", ["target": .string(tile), "text": "use nargs=2"])
        #expect(refused["error"]?["code"] == .string("conflict"))
        #expect(refused["error"]?["message"]?.string?.contains("Which flag should --pair use?") == true, "names what it waits on")
        #expect(submitted.isEmpty, "the text never reached the dialog")
        let forced = try await call(client, "agent.prompt", ["target": .string(tile), "text": "use nargs=2", "force": .bool(true)])
        #expect(forced["result"]?["waitable"] == .bool(true))
        #expect(submitted == ["use nargs=2"])
    }

    @Test func aPromptToAnAgentInItsTurnIsAnsweredWhenThatTurnEnds() async throws {
        // omp takes a prompt typed mid-turn as a steering message and answers both in one turn:
        // no report comes until that turn's idle.
        let omp = terminal()
        try board.reportLifecycle(tile: omp, kind: "omp", state: .working, message: nil, seq: 1, source: "canvas-omp")
        let client = try connect()
        #expect(try await call(client, "agent.prompt", ["target": .string(omp), "text": "also tell me the branch"])["result"]?["waitable"] == .bool(true))
        client.send(#"{"id":"w","method":"agent.wait","params":{"target":"\#(omp)","timeoutMs":5000}}"#)
        client.send(#"{"id":"ping","method":"system.ping","params":{}}"#)
        #expect(try await client.next()["id"] == .string("ping"), "still in its turn")
        try board.reportLifecycle(tile: omp, kind: "omp", state: .idle, message: nil, seq: 2, source: "canvas-omp", final: "Hash 1a2b3c\nBranch study-pair")
        let waited = try await client.next()
        #expect(waited["id"] == .string("w"))
        #expect(waited["result"]?["agent"]?["lifecycle"]?["state"] == .string("done"))
        let final = try await call(client, "agent.read", ["target": .string(omp), "final": .bool(true)])
        #expect(final["result"]?["text"] == .string("Hash 1a2b3c\nBranch study-pair"), "\(final)")

        // Codex takes it before its next tool call, saying so (UserPromptSubmit: `working`), and
        // ends the turn with one Stop whose answer is the prompt's.
        let codex = terminal()
        try board.reportLifecycle(tile: codex, kind: "codex", state: .working, message: nil, seq: 10, source: "canvas-codex")
        _ = try await call(client, "agent.prompt", ["target": .string(codex), "text": "add BANANA"])
        client.send(#"{"id":"w2","method":"agent.wait","params":{"target":"\#(codex)","timeoutMs":5000}}"#)
        try board.reportLifecycle(tile: codex, kind: "codex", state: .working, message: nil, seq: 11, source: "canvas-codex", call: "f0c82fec96cbd7c6")
        try board.reportLifecycle(tile: codex, kind: "codex", state: .working, message: nil, seq: 12, source: "canvas-codex")
        client.send(#"{"id":"ping2","method":"system.ping","params":{}}"#)
        #expect(try await client.next()["id"] == .string("ping2"))
        try board.reportLifecycle(tile: codex, kind: "codex", state: .idle, message: nil, seq: 13, source: "canvas-codex", final: "DONE-ONE\nBANANA")
        #expect(try await client.next()["id"] == .string("w2"))
        #expect(try await call(client, "agent.read", ["target": .string(codex), "final": .bool(true)])["result"]?["text"] == .string("DONE-ONE\nBANANA"))
    }

    @Test func anUpdateMayGiveAnyPartOfTheFrame() async throws {
        let note = board.create(type: .note, props: .object(["markdown": "a"]), frame: Frame(x: 10, y: 20, w: 300, h: 100))
        let client = try connect()
        let taller = try await call(client, "object.update", ["id": .string(note.id), "frame": .object(["h": 420])])
        #expect(try taller["result"]?["object"]?["frame"]?.decode(Frame.self) == Frame(x: 10, y: 20, w: 300, h: 420))
        let moved = try await call(client, "object.update", ["id": .string(note.id), "frame": .object(["x": 50])])
        #expect(try moved["result"]?["object"]?["frame"]?.decode(Frame.self) == Frame(x: 50, y: 20, w: 300, h: 420))
        let partial = try await call(client, "object.create", ["type": "html", "props": .object(["html": "<p>x</p>"]), "frame": .object(["x": 0, "y": 0, "w": 200])])
        #expect(partial["error"]?["code"] == .string("invalid_params"))
        #expect(partial["error"]?["message"]?.string?.contains("frame needs x, y, w, and h (missing h)") == true, "\(partial)")
        // Just a size: placed automatically, clear of what is there.
        let sized = try await call(client, "object.create", ["type": "html", "props": .object(["html": "<p>x</p>"]), "frame": .object(["w": 320, "h": 180])])
        let frame = try #require(try sized["result"]?["object"]?["frame"]?.decode(Frame.self))
        #expect(frame.w == 320 && frame.h == 180)
        #expect(!frame.rect.intersects(Frame(x: 50, y: 20, w: 300, h: 420).rect), "placed beside the note, not over it")
        let halfPlaced = try await call(client, "object.create", ["type": "html", "props": .object(["html": "<p>x</p>"]), "frame": .object(["x": 0, "w": 320, "h": 180])])
        #expect(halfPlaced["error"]?["message"]?.string?.contains("(missing y)") == true)
    }

    @Test func aFrameUpdateThatGrowsOverNeighboursNamesThem() async throws {
        let page = board.create(type: .browser, props: .object(["url": "http://localhost:3000"]), frame: Frame(x: 0, y: 0, w: 390, h: 844))
        let terminal = board.create(type: .terminal, props: .object(["cwd": "/"]), frame: Frame(x: 430, y: 0, w: 600, h: 400))
        let client = try connect()
        let desktop = try await call(client, "object.update", ["id": .string(page.id), "frame": .object(["w": 1280, "h": 858])])
        #expect(desktop["result"]?["overlaps"] == .array([.string(terminal.id)]), "the viewport resize buried the terminal")
        let again = try await call(client, "object.update", ["id": .string(page.id), "frame": .object(["h": 900])])
        #expect(again["result"]?["overlaps"] == nil, "nothing newly covered")
        let away = try await call(client, "object.update", ["id": .string(page.id), "frame": .object(["x": -1400])])
        #expect(away["result"]?["overlaps"] == nil)
    }

    @Test func aZoomUpdateNeverChangesTheFrame() async throws {
        let tile = board.create(type: .terminal, props: .object(["cwd": "/"]), frame: Frame(x: 0, y: 0, w: 1000, h: 620))
        let below = board.create(type: .note, props: .object(["markdown": "b"]), frame: Frame(x: 0, y: 660, w: 400, h: 300))
        let client = try connect()
        let zoomed = try await call(client, "object.update", ["id": .string(tile.id), "props": .object(["zoom": .number(1.5)])])
        #expect(try zoomed["result"]?["object"]?["frame"]?.decode(Frame.self) == Frame(x: 0, y: 0, w: 1000, h: 620))
        #expect(try board.object(tile.id).zoom == 1.5 && zoomed["result"]?["overlaps"] == nil)
        // Out again, in a batch, with a size given too: the size is the frame, the zoom only the content.
        let batch = try await call(client, "object.batch", ["ops": .array([
            .object(["method": "object.update", "params": .object(["id": .string(tile.id), "props": .object(["zoom": .number(0.67)]), "frame": .object(["w": 1200])])]),
        ])])
        #expect(batch["error"] == nil)
        #expect(try board.object(tile.id).frame == Frame(x: 0, y: 0, w: 1200, h: 620) && board.object(tile.id).zoom == 0.67)
        #expect(try board.object(below.id).frame == Frame(x: 0, y: 660, w: 400, h: 300))
        let reset = try await call(client, "object.update", ["id": .string(tile.id), "props": .object(["zoom": .null])])
        #expect(try reset["result"]?["object"]?["frame"]?.decode(Frame.self) == Frame(x: 0, y: 0, w: 1200, h: 620) && board.object(tile.id).zoom == 1)
    }

    @Test func scaleIsRejectedNamingZoom() async throws {
        let tile = board.create(type: .note, props: .object(["markdown": "a"]), frame: Frame(x: 0, y: 0, w: 400, h: 300))
        let client = try connect()
        let calls: [(String, [String: JSONValue])] = [
            ("object.create", ["type": "note", "props": .object(["markdown": "b", "scale": 2])]),
            ("object.create", ["type": "shape", "props": .object(["kind": "text", "text": "hi", "scale": 2])]),
            ("object.update", ["id": .string(tile.id), "props": .object(["scale": 2]), "frame": .object(["w": 800, "h": 600])]),
            ("object.upsert", ["key": "k", "type": "note", "props": .object(["markdown": "c", "scale": 2])]),
            ("object.measure", ["type": "note", "props": .object(["markdown": "d", "scale": 2])]),
            ("object.batch", ["ops": .array([.object(["method": "object.update", "params": .object(["id": .string(tile.id), "props": .object(["scale": 2])])])])]),
        ]
        for (method, params) in calls {
            let response = try await call(client, method, params)
            #expect(response["error"]?["code"] == "invalid_params", "\(method)")
            let message = response["error"]?["message"]?.string ?? ""
            #expect(message.contains("props.zoom") && message.contains("props.textSize"), "\(method): \(message)")
        }
        #expect(try board.object(tile.id).frame == Frame(x: 0, y: 0, w: 400, h: 300) && board.object(tile.id).props["scale"] == nil)
        #expect(board.objects.count == 1, "nothing was created")
    }

    @Test func aNoteIsStoredWithTheAnchorsItsTileWouldWriteBack() async throws {
        let source = dir.appendingPathComponent("root/src/a.ts")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "import x\n\nexport function load() {\n  return 1\n}\n".write(to: source, atomically: true, encoding: .utf8)
        let client = try connect()
        let markdown = "Loading:\n\n```ts file=src/a.ts#L3-5\n```\n"
        let created = try await call(client, "object.create", ["type": "note", "props": .object(["markdown": .string(markdown)]), "frame": .object(["x": 0, "y": 0, "w": 400])])
        let object = try #require(created["result"]?["object"])
        #expect(object["props"]?["markdown"] == .string("Loading:\n\n```ts file=src/a.ts#L3-5 anchor=\"export function load() {\"\n```\n"))
        // Nothing is left for the tile to rewrite, so the returned rev is the one to update with.
        let id = try #require(object["id"]?.string)
        let edited = try await call(client, "object.update", ["id": .string(id), "rev": object["rev"] ?? .null, "props": .object(["markdown": "Loading:\n\n```ts file=src/a.ts#L1-1\n```\n"])])
        #expect(edited["result"]?["object"]?["props"]?["markdown"] == .string("Loading:\n\n```ts file=src/a.ts#L1-1 anchor=\"import x\"\n```\n"))
    }

    /// The window's state with `target` as the terminal the tray shows.
    func showTray(to target: ObjectID?) {
        router.viewState = { _ in
            ViewState(viewport: Viewport(rect: Frame(x: 0, y: 0, w: 1000, h: 800), zoom: 1), promptTarget: target, focused: nil, selection: [], enteredGroup: nil, visible: true, appearance: "dark")
        }
    }

    @Test func onlyTheTerminalTheTrayShowsDrainsIt() async throws {
        let shown = terminal()
        let other = terminal()
        _ = try board.update(other, props: .object(["name": "fees"]))
        showTray(to: shown)
        try board.stage(.terminal(object: other, text: "npm test"))
        try board.stage(.object(shown))
        let client = try connect()

        let held = try #require(try await call(client, "tray.drain", ["caller": .string(other)])["result"])
        #expect(held["mentions"] == .array([]))
        #expect(held["context"] == .string(""))
        #expect(held["held"] == .number(2))
        #expect(held["target"] == .string(shown))
        #expect(board.tray.count == 2, "another terminal's prompt leaves the tray as it is")

        let peeked = try #require(try await call(client, "tray.drain", ["caller": .string(shown), "peek": .bool(true)])["result"])
        let context = try #require(peeked["context"]?.string)
        #expect(context.contains("[1] terminal tile \(other) \"fees\""), "another terminal is named")
        #expect(context.contains("[2] terminal \(shown) \"terminal\" (your terminal)"))
        #expect(board.tray.count == 2)

        // A script (no caller) drains whatever the tray shows.
        let drained = try #require(try await call(client, "tray.drain", [:])["result"])
        #expect(drained["mentions"]?.array?.count == 2)
        #expect(board.tray.isEmpty)
    }

    @Test func withNoTargetShownEveryCallerTerminalIsHeldBack() async throws {
        let a = terminal()
        _ = terminal()
        showTray(to: nil)
        try board.stage(.object(a))
        let client = try connect()
        let held = try #require(try await call(client, "tray.drain", ["caller": .string(a)])["result"])
        #expect(held["held"] == .number(1))
        #expect(held["target"] == nil)
        #expect(board.tray.count == 1)
    }

    @Test func arrowsReportTheBoundsOfTheirRouteNotAZeroSizePoint() async throws {
        let a = board.create(type: .note, props: .object(["markdown": "a"]), frame: Frame(x: 0, y: 0, w: 100, h: 100))
        let b = board.create(type: .note, props: .object(["markdown": "b"]), frame: Frame(x: 400, y: 200, w: 100, h: 100))
        let arrow = board.create(type: .arrow, props: ArrowSpec(from: .object(a.id), to: .object(b.id)).props)
        #expect(arrow.frame.w == 0 && arrow.frame.h == 0, "the stored frame of a bound arrow is a placeholder")
        let route = try #require(board.geometry.routes()[arrow.id])
        let xs = route.map { Double($0.x) }, ys = route.map { Double($0.y) }
        let expected = Frame(x: xs.min()!, y: ys.min()!, w: xs.max()! - xs.min()!, h: ys.max()! - ys.min()!)
        #expect(expected.w > 200 && expected.h > 100)
        let client = try connect()

        let objects = try await call(client, "board.get", [:])["result"]?["objects"]?.array ?? []
        let listed = try #require(objects.first { $0["id"] == .string(arrow.id) })
        #expect(try listed["frame"]?.decode(Frame.self) == expected)
        let got = try await call(client, "object.get", ["id": .string(arrow.id)])
        #expect(try got["result"]?["object"]?["frame"]?.decode(Frame.self) == expected)
        let history = try await call(client, "board.history", [:])["result"]?["entries"]?.array ?? []
        let created = history.compactMap { $0["summary"]?.string }.first { $0.hasPrefix("created arrow") }
        #expect(created?.hasSuffix(String(format: "at (%.0f, %.0f) %.0f×%.0f", expected.x, expected.y, expected.w, expected.h)) == true)

        // With a window, what is drawn (the app's routed line) is what is reported.
        board.arrowPath = { id in id == arrow.id ? [CGPoint(x: 110, y: 50), CGPoint(x: 250, y: 50), CGPoint(x: 250, y: 240), CGPoint(x: 390, y: 240)] : nil }
        let drawn = try await call(client, "object.get", ["id": .string(arrow.id)])
        #expect(try drawn["result"]?["object"]?["frame"]?.decode(Frame.self) == Frame(x: 110, y: 50, w: 280, h: 190))
    }

    /// The app's drawing layer as it routes `avoid` arrows: a new one draws a provisional straight
    /// line and a changed one keeps its last route until the layer settles (the next main-queue
    /// turn, a draw, or `Board.settleArrows`), which routes them all from the board as it is then.
    @MainActor
    final class DrawnArrows {
        var paths: [ObjectID: [CGPoint]] = [:]
        var pending = false
        var settles = 0

        init(_ board: Board) {
            let forward = board.onEvent
            board.onEvent = { [unowned self] event in
                forward?(event)
                switch event {
                case .objectCreated(let object), .objectUpdated(let object):
                    if object.type == .arrow, paths[object.id] == nil { paths[object.id] = [CGPoint(x: -14, y: 251.5), CGPoint(x: 718, y: 251.5)] }
                    pending = true
                default: break
                }
            }
            board.arrowPath = { [unowned self] id in paths[id] }
            board.settleArrows = { [unowned self, unowned board] in
                guard pending else { return }
                pending = false
                settles += 1
                for (id, route) in board.geometry.routes() where paths[id] != nil { paths[id] = route }
            }
        }
    }

    func bounds(_ route: [CGPoint]) -> Frame {
        let xs = route.map { Double($0.x) }, ys = route.map { Double($0.y) }
        return Frame(x: xs.min()!, y: ys.min()!, w: xs.max()! - xs.min()!, h: ys.max()! - ys.min()!)
    }

    func reportedFrames(_ client: LineClient, _ id: ObjectID) async throws -> [Frame?] {
        let objects = try await call(client, "board.get", [:])["result"]?["objects"]?.array ?? []
        let got = try await call(client, "object.get", ["id": .string(id)])
        return [try objects.first { $0["id"] == .string(id) }?["frame"]?.decode(Frame.self),
                try got["result"]?["object"]?["frame"]?.decode(Frame.self)]
    }

    @Test func anAvoidArrowsCreateAndUpdateReportTheRouteItIsDrawnOn() async throws {
        let a = board.create(type: .note, props: .object(["markdown": "a"]), frame: Frame(x: 0, y: 0, w: 100, h: 100))
        let b = board.create(type: .note, props: .object(["markdown": "b"]), frame: Frame(x: 600, y: 0, w: 100, h: 100))
        let c = board.create(type: .note, props: .object(["markdown": "c"]), frame: Frame(x: 600, y: 400, w: 100, h: 100))
        _ = board.create(type: .note, props: .object(["markdown": "wall"]), frame: Frame(x: 250, y: -100, w: 200, h: 300))
        let layer = DrawnArrows(board)
        let client = try connect()

        let created = try await call(client, "object.create", ["type": "arrow", "props": .object([
            "from": .object(["object": .string(a.id)]), "to": .object(["object": .string(b.id)]), "route": "avoid",
        ])])
        let id = try #require(created["result"]?["object"]?["id"]?.string)
        let around = bounds(try #require(board.geometry.routes()[id]))
        #expect(around.y < -100 || around.y + around.h > 200, "the route goes around the wall")
        #expect(try created["result"]?["object"]?["frame"]?.decode(Frame.self) == around, "not the provisional straight line")
        #expect(layer.paths[id].map(bounds) == around, "what is drawn next")
        #expect(try await reportedFrames(client, id) == [around, around])

        let updated = try await call(client, "object.update", ["id": .string(id), "props": .object(["to": .object(["object": .string(c.id)])])])
        let moved = bounds(try #require(board.geometry.routes()[id]))
        #expect(moved != around)
        #expect(try updated["result"]?["object"]?["frame"]?.decode(Frame.self) == moved, "not the route to its old end")
        #expect(try await reportedFrames(client, id) == [moved, moved])
    }

    @Test func aBatchReportsItsAvoidArrowsOnTheRouteTheWholeBatchLeaves() async throws {
        let a = board.create(type: .note, props: .object(["markdown": "a"]), frame: Frame(x: 0, y: 0, w: 100, h: 100))
        let b = board.create(type: .note, props: .object(["markdown": "b"]), frame: Frame(x: 600, y: 0, w: 100, h: 100))
        let layer = DrawnArrows(board)
        let client = try connect()
        func arrow(_ from: CanvasObject, _ to: CanvasObject) -> JSONValue {
            .object(["method": "object.create", "params": .object(["type": "arrow", "props": .object([
                "from": .object(["object": .string(from.id)]), "to": .object(["object": .string(to.id)]), "route": "avoid",
            ])])])
        }
        // The wall arrives after the arrows, in the same batch.
        let batch = try await call(client, "object.batch", ["board": .string(board.id), "ops": .array([
            arrow(a, b), arrow(b, a),
            .object(["method": "object.create", "params": .object(["type": "note", "props": .object(["markdown": "wall"]),
                                                                    "frame": .object(["x": 250, "y": -100, "w": 200, "h": 300])])]),
        ])])
        let results = try #require(batch["result"]?["results"]?.array)
        #expect(layer.settles == 1, "routed once for the whole batch, not once per op")
        let routes = board.geometry.routes()
        for result in results.prefix(2) {
            let id = try #require(result["object"]?["id"]?.string)
            let drawn = bounds(try #require(routes[id]))
            #expect(drawn.y < -100 || drawn.y + drawn.h > 200, "the route goes around the wall")
            #expect(try result["object"]?["frame"]?.decode(Frame.self) == drawn)
            #expect(try await reportedFrames(client, id) == [drawn, drawn])
        }
    }

    @Test func promptFailsWhenTheSurfaceIsNotAttached() async throws {
        let tile = terminal()
        router.submitToTerminal = { _, _, _ in false }
        let client = try connect()
        client.send(#"{"id":"p","method":"agent.prompt","params":{"target":"\#(tile)","text":"hi"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("unavailable"))
    }

    @Test func boardGetSummarizesAFollowTilesHistoryAndObjectGetHasItWhole() async throws {
        let tile = terminal()
        // Follow shows only files that exist in the project.
        let source = dir.appendingPathComponent("root/src/a.ts")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (1...100).map { "line \($0)" }.joined(separator: "\n").write(to: source, atomically: true, encoding: .utf8)
        for line in [10, 40, 90] {
            try board.follow(tile: tile, path: "src/a.ts", range: LineRange(start: line, end: line + 5), action: "read")
        }
        let follow = try #require(board.objects.values.first { $0.props["followOf"]?.string == tile })
        let client = try connect()
        client.send(#"{"id":"g","method":"board.get","params":{"board":"\#(board.id)"}}"#)
        let objects = try await client.next()["result"]?["objects"]?.array ?? []
        let listed = try #require(objects.first { $0["id"] == .string(follow.id) })
        #expect(listed["props"]?["history"]?.string?.contains("3") == true, "history is a short summary: \(listed["props"]?["history"] ?? .null)")
        #expect(listed["props"]?["range"]?["start"] == .number(90), "what the tile shows now stays whole")
        client.send(#"{"id":"o","method":"object.get","params":{"id":"\#(follow.id)"}}"#)
        #expect(try await client.next()["result"]?["object"]?["props"]?["history"]?.array?.count == 3)
    }

    @Test func boardOpenOpensADirectoryOnceAndRejectsBadRoots() async throws {
        let second = dir.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        var opened: [(String, Bool)] = []
        router.openBoard = { [unowned self] root, select in
            opened.append((root.path, select))
            return registry.open(root: root)
        }
        let client = try connect()
        client.send(#"{"id":"a","method":"board.open","params":{"root":"\#(second.path)"}}"#)
        let first = try await client.next()
        let id = try #require(first["result"]?["board"]?.string)
        #expect(id != board.id)
        #expect(registry.boards[id]?.root.path == second.path)
        // Opening it again (asking for its tab) is the same board.
        client.send(#"{"id":"b","method":"board.open","params":{"root":"\#(second.path)/","select":true}}"#)
        #expect(try await client.next()["result"]?["board"]?.string == id)
        #expect(opened.map(\.1) == [false, true])

        client.send(#"{"id":"c","method":"board.open","params":{"root":"relative/dir"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("invalid_params"))
        client.send(#"{"id":"d","method":"board.open","params":{"root":"\#(dir.path)/missing"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("not_found"))
        #expect(opened.count == 2)
    }

    @Test func openRemoteChecksItsParamsAndAnswersWithThePickersFailures() async throws {
        let client = try connect()
        client.send(#"{"id":"u","method":"board.open_remote","params":{"host":"twaldin-work","board":"brd_7f94"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("unsupported"), "without the app UI")

        var asked: [String] = []
        router.openRemoteBoard = { host, board, select in
            asked.append("\(host) \(board) \(select)")
            switch host {
            case "asleep": throw EaslConnection.Failure("unavailable", "asleep is offline: ssh: connect to host asleep port 22: Operation timed out")
            case "gone": throw CancellationError()
            case "work" where board == "brd_nope": throw ApiRouter.Failure("not_found", "couldn't open brd_nope on work: board brd_nope")
            default: return OpenedRemoteBoard(host: host, sshTarget: "\(host).tail1234.ts.net", board: board, root: "/Users/tim/lindy", title: "lindy @ \(host)", window: 42, alreadyOpen: false)
            }
        }
        let refused = [
            #"{"host":"work"}"#, #"{"board":"brd_7f94"}"#, #"{"host":"","board":"brd_7f94"}"#, #"{"host":"two words","board":"brd_7f94"}"#,
            #"{"host":"-oProxyCommand=sh","board":"brd_7f94"}"#, #"{"host":7,"board":"brd_7f94"}"#, #"{"host":"work","board":"lindy"}"#,
            #"{"host":"work","board":"brd_"}"#, #"{"host":"work","board":"brd_a b"}"#, #"{"host":"work","board":"brd_7f94","root":"/x"}"#,
        ]
        for (index, params) in refused.enumerated() {
            client.send(#"{"id":"r\#(index)","method":"board.open_remote","params":\#(params)}"#)
            #expect(try await client.next()["error"]?["code"] == .string("invalid_params"), "\(params)")
        }
        #expect(asked.isEmpty, "nothing malformed reaches the host")

        client.send(#"{"id":"a","method":"board.open_remote","params":{"host":"asleep","board":"brd_7f94"}}"#)
        let offline = try await client.next()["error"]
        #expect(offline?["code"] == .string("unavailable"))
        #expect(offline?["message"]?.string?.contains("asleep is offline") == true)
        client.send(#"{"id":"g","method":"board.open_remote","params":{"host":"gone","board":"brd_7f94"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("unavailable"))
        client.send(#"{"id":"n","method":"board.open_remote","params":{"host":"work","board":"brd_nope"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("not_found"))

        client.send(#"{"id":"o","method":"board.open_remote","params":{"host":"work","board":"brd_7f94"}}"#)
        let opened = try #require(try await client.next()["result"])
        #expect(opened == .object(["host": .string("work"), "sshTarget": .string("work.tail1234.ts.net"), "board": .string("brd_7f94"), "root": .string("/Users/tim/lindy"),
                                   "title": .string("lindy @ work"), "window": .number(42), "alreadyOpen": .bool(false)]))
        client.send(#"{"id":"s","method":"board.open_remote","params":{"host":"work","board":"brd_7f94","select":true}}"#)
        _ = try await client.next()
        #expect(asked == ["asleep brd_7f94 false", "gone brd_7f94 false", "work brd_nope false", "work brd_7f94 false", "work brd_7f94 true"],
                "select is false unless asked")
    }

    @Test func openRemoteAgainAnswersTheTabAlreadyOpen() async throws {
        // The app's side as it keeps its windows: one per host and board, by ssh target.
        var windows: [String: Int] = [:]
        var selected: [Int] = []
        router.openRemoteBoard = { host, board, select in
            let key = "\(host)|\(board)"
            let alreadyOpen = windows[key] != nil
            let window = windows[key] ?? 100 + windows.count
            windows[key] = window
            if select { selected.append(window) }
            return OpenedRemoteBoard(host: host, sshTarget: host, board: board, root: "/r", title: "r @ \(host)", window: window, alreadyOpen: alreadyOpen)
        }
        let client = try connect()
        client.send(#"{"id":"1","method":"board.open_remote","params":{"host":"work","board":"brd_a1"}}"#)
        let first = try #require(try await client.next()["result"])
        client.send(#"{"id":"2","method":"board.open_remote","params":{"host":"work","board":"brd_a1","select":true}}"#)
        let again = try #require(try await client.next()["result"])
        #expect(first["alreadyOpen"] == .bool(false))
        #expect(again["alreadyOpen"] == .bool(true))
        #expect(again["window"] == first["window"], "the same tab, not a second one")
        #expect(selected == [100], "selected when asked")
        client.send(#"{"id":"3","method":"board.open_remote","params":{"host":"home","board":"brd_a1"}}"#)
        let other = try #require(try await client.next()["result"])
        #expect(other["alreadyOpen"] == .bool(false) && other["window"] != first["window"], "another host's board of that id is another tab")
        #expect(windows.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func aSubscriberThatStopsReadingDoesNotStallTheBoardOrOtherClients() async throws {
        let stalled = try connect()
        stalled.send(#"{"id":"s","method":"events.subscribe","params":{}}"#)
        #expect(try await stalled.next()["ok"] == .bool(true))
        // It never reads again, while the board emits far more than a socket buffer holds: the
        // broadcasts run on the main actor, which a blocking write would freeze for good.
        let text = String(repeating: "x", count: 4000)
        for index in 0..<400 { board.create(type: .note, props: .object(["markdown": .string("\(index) \(text)")])) }
        let other = try connect()
        other.send(#"{"id":"p","method":"system.ping","params":{}}"#)
        #expect(try await other.next()["id"] == .string("p"))
    }

    @Test func pipelinedRequestsAreAnsweredInOrder() async throws {
        let note = board.create(type: .note, props: .object(["markdown": .string("a")]))
        let client = try connect()
        var batch = ""
        for index in 0..<20 {
            batch += #"{"id":"u\#(index)","method":"object.update","params":{"id":"\#(note.id)","props":{"markdown":"v\#(index)"}}}"# + "\n"
        }
        batch += #"{"id":"g","method":"object.get","params":{"id":"\#(note.id)"}}"# + "\n"
        client.sendRaw(batch)
        for index in 0..<20 {
            #expect(try await client.next()["id"] == .string("u\(index)"))
        }
        let get = try await client.next()
        #expect(get["id"] == .string("g"))
        #expect(get["result"]?["object"]?["props"]?["markdown"] == .string("v19"))
    }

    @Test func shapeGraphDescribesEnclosureOverlapsAndArrows() async throws {
        let box = board.create(type: .shape, props: .object(["kind": .string("rect"), "text": .string("auth path?")]), frame: Frame(x: 0, y: 0, w: 1000, h: 800))
        let a = board.create(type: .terminal, props: .object([:]), frame: Frame(x: 50, y: 50, w: 300, h: 200))
        let b = board.create(type: .code, props: .object(["path": .string("a.swift")]), frame: Frame(x: 500, y: 50, w: 300, h: 200))
        let outside = board.create(type: .note, props: .object([:]), frame: Frame(x: 2000, y: 0, w: 300, h: 200))
        let straddling = board.create(type: .note, props: .object([:]), frame: Frame(x: 900, y: 600, w: 300, h: 200))
        let inner = board.create(type: .arrow, props: ArrowSpec(from: .object(a.id), to: .object(b.id), relation: "calls").props)
        let scribble = board.create(type: .arrow, props: ArrowSpec(from: .point(CGPoint(x: 100, y: 500)), to: .object(b.id)).props)
        let out = board.create(type: .arrow, props: ArrowSpec(from: .object(box.id), to: .object(outside.id), relation: "hypothesis_about").props)
        // Leaves the box: not drawn inside it, so not part of its structure.
        _ = board.create(type: .arrow, props: ArrowSpec(from: .object(a.id), to: .object(outside.id)).props)

        let client = try connect()
        client.send(#"{"id":"g","method":"object.get","params":{"id":"\#(box.id)","as":"graph"}}"#)
        let graph = try #require(try await client.next()["result"]?["graph"])
        #expect(graph["encloses"] == .array([a.id, b.id].sorted().map(JSONValue.string)))
        #expect(graph["overlaps"] == .array([.string(straddling.id)]))
        #expect(graph["arrowsOut"]?.array?.first?["to"] == .string(outside.id))
        #expect(graph["arrowsOut"]?.array?.first?["relation"] == .string("hypothesis_about"))
        let arrows = graph["arrows"]?.array ?? []
        #expect(arrows.compactMap { $0["arrow"]?.string } == [inner.id, scribble.id].sorted())
        let calls = arrows.first { $0["arrow"] == .string(inner.id) }
        #expect(calls?["from"]?["object"] == .string(a.id))
        #expect(calls?["to"]?["object"] == .string(b.id))
        #expect(calls?["relation"] == .string("calls"))

        client.send(#"{"id":"r","method":"object.get","params":{"id":"\#(out.id)","as":"graph"}}"#)
        let arrowGraph = try #require(try await client.next()["result"]?["graph"])
        #expect(arrowGraph["from"]?["object"] == .string(box.id))
        #expect(arrowGraph["to"]?["object"] == .string(outside.id))

        // The prompt context says the same thing in one line.
        try board.stage(.object(box.id))
        let context = await board.drain().context
        #expect(context.contains("encloses \([a.id, b.id].sorted().joined(separator: ", "))"))
        #expect(context.contains("inner arrow \(a.id) → \(b.id) (calls)"))
        #expect(context.contains("arrow → \(outside.id) (hypothesis_about)"))
    }

    /// One request on `client`; the whole reply.
    func call(_ client: LineClient, _ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let request: JSONValue = .object(["id": .string(method), "method": .string(method), "params": .object(params)])
        client.send(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        return try await client.next()
    }

    @Test func deletingATerminalThroughTheApiEndsItsSessionUnlessTheBatchFails() async throws {
        var ended: [ObjectID] = []
        registry.onTerminalsEnded = { _, objects in ended += objects.map(\.id) }
        let client = try connect()

        let deleted = terminal()
        #expect(try await call(client, "object.delete", ["id": .string(deleted)])["ok"] == .bool(true))
        #expect(ended == [deleted])
        // ⌘Z brings the tile back (it starts a new session); nothing more ends.
        #expect(board.undo())
        #expect(board.objects[deleted]?.type == .terminal)
        #expect(ended == [deleted])

        // A batch that fails puts its deleted terminal back: its session must survive.
        let kept = terminal()
        let failed = try await call(client, "object.batch", ["board": .string(board.id), "ops": .array([
            .object(["method": "object.delete", "params": .object(["id": .string(kept)])]),
            .object(["method": "object.update", "params": .object(["id": "obj_missing", "props": .object([:])])]),
        ])])
        #expect(failed["ok"] == .bool(false))
        #expect(board.objects[kept] != nil)
        #expect(ended == [deleted])

        // One that succeeds ends every terminal it deleted, once it has committed.
        let other = terminal()
        let batch = try await call(client, "object.batch", ["board": .string(board.id), "ops": .array([
            .object(["method": "object.delete", "params": .object(["id": .string(kept)])]),
            .object(["method": "object.delete", "params": .object(["id": .string(other)])]),
        ])])
        #expect(batch["ok"] == .bool(true))
        #expect(ended == [deleted, kept, other])
    }

    @Test func anAgentsNewMarkerClearsItsMarkersFromEarlierTurnsOnly() async throws {
        let agent = terminal(), other = terminal()
        let a = board.create(type: .note, props: .object(["markdown": .string("a")]))
        let b = board.create(type: .note, props: .object(["markdown": .string("b")]))
        let c = board.create(type: .note, props: .object(["markdown": .string("c")]))
        let d = board.create(type: .note, props: .object(["markdown": .string("d")]))
        let client = try connect()
        func raise(_ id: ObjectID, by caller: ObjectID?) async throws -> JSONValue {
            var params: [String: JSONValue] = ["id": .string(id), "message": .string("look")]
            if let caller { params["caller"] = .string(caller) }
            let reply = try await call(client, "view.attention", params)
            #expect(reply["result"]?["active"] == .bool(true), "\(reply)")
            return reply["result"] ?? .null
        }
        var seq = 0
        func report(_ tile: ObjectID, _ state: LifecycleState) throws {
            seq += 1
            try board.reportLifecycle(tile: tile, kind: "omp", state: state, message: nil, seq: seq, source: "canvas-omp")
        }

        try report(agent, .working)
        _ = try await raise(a.id, by: agent)
        _ = try await raise(b.id, by: agent)
        #expect(Set(board.attention.keys) == [a.id, b.id], "one answer may point at several things")
        try report(other, .working)
        _ = try await raise(c.id, by: other)
        _ = try await raise(d.id, by: nil)

        // Repeated working reports, and an approval answered (blocked → working), continue the turn.
        try report(agent, .working)
        #expect(try await raise(a.id, by: agent)["cleared"] == nil)
        try report(agent, .blocked)
        try report(agent, .working)
        #expect(try await raise(b.id, by: agent)["cleared"] == nil, "markers from before the approval belong to the same answer")
        #expect(Set(board.attention.keys) == [a.id, b.id, c.id, d.id])

        // The user's next prompt: idle, then working again.
        try report(agent, .idle)
        try report(agent, .working)
        try report(other, .idle)
        try report(other, .working)
        let next = try await raise(d.id, by: agent)
        #expect(next["cleared"] == .array([a.id, b.id].sorted().map(JSONValue.string)))
        #expect(Set(board.attention.keys) == [c.id, d.id], "another agent's marker and the new one stay")
        #expect(board.attention[d.id]?.raisedBy == agent, "raising on a marked object takes it over")

        // Clearing and deleting remove markers; the user seeing an object is the board's clear.
        #expect(try await call(client, "view.attention", ["id": .string(c.id), "clear": .bool(true)])["result"]?["active"] == .bool(false))
        try board.delete(d.id)
        #expect(board.attention.isEmpty)
    }

    @Test func anAgentIsCreditedOnAnotherBoardItWorksOn() async throws {
        let agent = terminal()
        let otherRoot = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let other = registry.open(root: otherRoot)
        let client = try connect()
        let created = try await call(client, "object.create", ["board": .string(other.id), "caller": .string(agent), "type": .string("note"),
                                                               "props": .object(["markdown": .string("from next door")])])
        let id = try #require(created["result"]?["object"]?["id"]?.string, "\(created)")
        #expect(other.objects[id]?.createdBy == .agent(tile: agent))
        _ = try await call(client, "object.update", ["id": .string(id), "caller": .string(agent), "props": .object(["markdown": .string("edited")])])
        #expect(other.objects[id]?.updatedBy == .agent(tile: agent))
        let note = board.create(type: .note, props: .object(["markdown": .string("not a terminal")]))
        let fake = try await call(client, "object.create", ["board": .string(other.id), "caller": .string(note.id), "type": .string("note"),
                                                            "props": .object(["markdown": .string("x")])])
        let fakeID = try #require(fake["result"]?["object"]?["id"]?.string)
        #expect(other.objects[fakeID]?.createdBy == .user, "only a terminal tile is an agent")
    }

    @Test func unknownOrMissingParamsNameWhatTheMethodTakes() async throws {
        let note = board.create(type: .note, props: .object(["markdown": .string("n")]))
        let client = try connect()
        let guessed = try await call(client, "layout.translate", ["ids": .array([.string(note.id)]), "delta": .array([.number(10), .number(0)])])
        #expect(guessed["error"]?["code"] == .string("invalid_params"))
        #expect(guessed["error"]?["message"] == .string("unknown param delta; missing dx, dy; layout.translate takes ids (required), dx (required), dy (required), caller"))
        let batch = try await call(client, "object.batch", ["ops": .array([.object(["method": .string("object.update"), "params": .object(["id": .string(note.id), "text": .string("x")])])])])
        #expect(batch["error"]?["message"] == .string("op 0 (object.update): unknown param text; object.update takes id (required), rev, frame, size, props, caller"))
        #expect(board.objects[note.id]?.frame.x == note.frame.x, "nothing moved")
    }

    @Test func openingAUrlShowsItBesideTheCallerAndReusesTheTile() async throws {
        let caller = terminal()
        var shown: [(tile: ObjectID, source: ObjectID?)] = []
        router.showOpenedLink = { _, tile, source in shown.append((tile, source)) }
        let client = try connect()

        let first = try await call(client, "view.open_url", ["url": "http://127.0.0.1:8000/x.html", "caller": .string(caller)])
        let tile = try #require(first["result"]?["object"]?["id"]?.string)
        #expect(first["result"]?["existing"] == .bool(false))
        #expect(board.objects[tile]?.type == .browser && board.objects[tile]?.props["url"]?.string == "http://127.0.0.1:8000/x.html")
        #expect(board.objects[tile]?.createdBy == Actor(caller: caller))

        let again = try await call(client, "view.open_url", ["url": "HTTP://127.0.0.1:8000/x.html", "caller": .string(caller)])
        #expect(again["result"]?["object"]?["id"]?.string == tile && again["result"]?["existing"] == .bool(true))
        #expect(board.objects.values.filter { $0.type == .browser }.count == 1)
        #expect(shown.map(\.tile) == [tile, tile] && shown.allSatisfy { $0.source == caller })

        for refused in ["file:///etc/hosts", "mailto:a@b.c", "example.com", "/tmp/x.html"] {
            let reply = try await call(client, "view.open_url", ["url": .string(refused), "caller": .string(caller)])
            #expect(reply["error"]?["code"] == .string("invalid_params"), "\(refused)")
        }
        #expect(board.objects.values.filter { $0.type == .browser }.count == 1)
    }
}

/// Minimal blocking NDJSON client; reads happen off the main actor so the server can answer.
final class LineClient: @unchecked Sendable {
    let fd: Int32
    private var buffer = Data()

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
    }

    deinit { close(fd) }

    func send(_ line: String) { sendRaw(line + "\n") }

    func sendRaw(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { return }
            offset += written
        }
    }

    /// Next response line, failing after `timeout` seconds (the timeout only detects hangs).
    func next(timeout: Double = 30) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try await nextLine(timeout: timeout))
    }

    /// Next response line as text, for protocols that answer some commands outside JSON.
    func nextText(timeout: Double = 30) async throws -> String {
        String(decoding: try await nextLine(timeout: timeout), as: UTF8.self)
    }

    /// The blocking read runs on a thread of its own, never on Swift's cooperative pool or GCD's
    /// global queues: suites run in parallel, and a pool full of threads parked in poll() starves
    /// the server tasks that would answer them, or starts this read after a peer's deadline (the
    /// relay gate's 5 s handshake) has passed.
    private func nextLine(timeout: Double) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result { try self.readLine(timeout: timeout) })
            }
        }
    }

    /// `nextText`, blocking the calling thread: for an exchange that must run on one thread
    /// from start to end (never this from a task on the cooperative pool).
    func nextTextNow(timeout: Double = 30) throws -> String {
        String(decoding: try readLine(timeout: timeout), as: UTF8.self)
    }

    private func readLine(timeout: Double) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard remaining > 0, poll(&poller, 1, remaining) > 0 else { throw POSIXError(.ETIMEDOUT) }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &chunk, chunk.count)
            guard count > 0 else { throw POSIXError(.ECONNRESET) }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
