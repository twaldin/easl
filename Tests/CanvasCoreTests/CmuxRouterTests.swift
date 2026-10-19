import Foundation
import Testing
import CanvasCore

/// The cmux subset over a real Unix socket, framed the way omp's cmux socket client sends it.
@MainActor
final class CmuxRouterTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cx-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let board: Board
    var servers: [SocketServer] = []
    /// Commands that reached the WebKit side, with their surface and driving terminal.
    var performed: [(ObjectID, CmuxBrowserCommand)] = []
    var drivers: [ObjectID?] = []

    init() async throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards")))
        board = await registry.open(root: dir.appendingPathComponent("root"))
    }

    deinit {
        servers.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: dir)
    }

    func connect(password: String? = nil) throws -> LineClient {
        let router = CmuxRouter(registry: registry, password: password)
        router.perform = { [unowned self] _, object, command, driver in
            performed.append((object.id, command))
            drivers.append(driver)
            return .object(["value": .number(1)])
        }
        let path = dir.appendingPathComponent("c\(servers.count)").path
        let server = SocketServer(path: path, acceptsTextLines: true) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        servers.append(server)
        return try LineClient(path: path)
    }

    func terminal(at frame: Frame) -> CanvasObject {
        board.create(type: .terminal, props: .object([:]), frame: frame)
    }

    func browser() -> CanvasObject {
        board.create(type: .browser, props: .object(["url": .string("http://localhost:1/")]), frame: Frame(x: -2000, y: -2000, w: 400, h: 300))
    }

    @Test func openSplitPlacesTheBrowserBesideTheCallingTerminal() async throws {
        let caller = terminal(at: Frame(x: 100, y: 50, w: 820, h: 520))
        _ = board.create(type: .note, props: .object([:]), frame: Frame(x: 944, y: 50, w: 320, h: 200))
        let client = try connect()
        client.send(#"{"id":"o","method":"browser.open_split","params":{"url":"localhost:8000/form.html","focus":false,"workspace_id":"\#(board.id)","surface_id":"\#(caller.id)"}}"#)
        let reply = try await client.next()
        #expect(reply["id"] == .string("o"))
        let id = try #require(reply["result"]?["surface_id"]?.string)
        let tile = try board.object(id)
        #expect(tile.type == .browser)
        #expect(tile.createdBy == .agent(tile: caller.id))
        #expect(tile.props["url"] == .string("http://localhost:8000/form.html"), "bare host:port is loaded over http")
        #expect(reply["result"]?["url"] == .string("http://localhost:8000/form.html"))
        #expect(tile.frame.x == caller.frame.maxX + 24, "right of the caller")
        #expect(tile.frame.y == 50 + 200 + 24, "stacked below the note already beside the caller")
        #expect(reply["result"]?["workspace_id"] == .string(board.id))
    }

    @Test func openSplitWithoutACallerUsesTheWorkspaceViewport() async throws {
        board.viewport = { Frame(x: 0, y: 0, w: 2000, h: 2000) }
        let client = try connect()
        client.send(#"{"id":1,"method":"browser.open_split","params":{"workspace_id":"\#(board.id)"}}"#)
        let reply = try await client.next()
        let tile = try board.object(try #require(reply["result"]?["surface_id"]?.string))
        #expect(tile.props["url"] == .string("about:blank"))
        #expect(tile.createdBy == .user)
        #expect(tile.frame.x + tile.frame.w / 2 == 1000)
        #expect(reply["result"]?["placement_strategy"] == .string("viewport"))
    }

    @Test func browserCommandsRunOnTheirSurfaceAndNameIt() async throws {
        let page = browser()
        let client = try connect()
        client.send(##"{"id":"w","method":"browser.wait","params":{"surface_id":"\##(page.id)","selector":"#done","timeout_ms":1500}}"##)
        let reply = try await client.next()
        #expect(reply["ok"] == .bool(true))
        #expect(reply["result"]?["surface_id"] == .string(page.id), "omp rejects results for a different surface")
        #expect(performed.map(\.0) == [page.id])
        #expect(performed.map(\.1) == [.wait(.selector("#done"), timeoutMs: 1500)])

        client.send(#"{"id":"f","method":"browser.fill","params":{"surface_id":"\#(page.id)","selector":"@e4","text":""}}"#)
        #expect(try await client.next()["ok"] == .bool(true), "filling with empty text clears a field")
        #expect(performed.last?.1 == .fill(selector: "@e4", text: ""))
    }

    @Test func requestErrorsUseCmuxErrorShapeAndEchoTheId() async throws {
        let page = browser()
        let shell = terminal(at: Frame(x: 0, y: 0, w: 100, h: 100))
        let client = try connect()
        let cases: [(String, String)] = [
            (#"{"id":"a","method":"browser.tabs.new","params":{}}"#, "method_not_found"),
            (#"{"id":"b","method":"browser.click","params":{"surface_id":"obj_missing","selector":"a"}}"#, "not_found"),
            (#"{"id":"c","method":"browser.click","params":{"surface_id":"\#(shell.id)","selector":"a"}}"#, "invalid_params"),
            (#"{"id":"d","method":"browser.click","params":{"surface_id":"\#(page.id)"}}"#, "invalid_params"),
            (#"{"id":"e","method":"browser.wait","params":{"surface_id":"\#(page.id)","selector":"a","url_contains":"x"}}"#, "invalid_params"),
            (#"{"id":"f","method":"browser.wait","params":{"surface_id":"\#(page.id)","load_state":"networkidle"}}"#, "invalid_params"),
            (#"{"id":"g","method":"browser.navigate","params":{"surface_id":"\#(page.id)","url":"not a url"}}"#, "invalid_params"),
            (#"{"id":"h","method":"browser.scroll","params":{"surface_id":"\#(page.id)","dy":"down"}}"#, "invalid_params"),
            (#"{"id":"i","method":"surface.close","params":{"surface_id":"\#(shell.id)"}}"#, "invalid_params"),
            (#"{"id":"j","method":"browser.wait","params":{"surface_id":"obj_missing","selector":"a","timeout_ms":-1}}"#, "invalid_params"),
            (#"{"id":"k","method":"browser.snapshot","params":{"surface_id":"\#(page.id)","max_depth":-3}}"#, "invalid_params"),
        ]
        for (request, code) in cases {
            client.send(request)
            let reply = try await client.next()
            #expect(reply["ok"] == .bool(false), "\(request)")
            #expect(reply["error"]?["code"] == .string(code), "\(request)")
            #expect(reply["error"]?["message"]?.string?.isEmpty == false)
            #expect(reply["id"] == (request.firstMatch(of: /"id":"(\w)"/).map { .string(String($0.1)) }))
        }
        #expect(performed.isEmpty, "invalid requests never reach a page")
        #expect(board.objects[shell.id] != nil, "the cmux socket never closes terminals")
    }

    @Test func hugeNumbersAreClampedNotFatal() async throws {
        let page = browser()
        let client = try connect()
        client.send(#"{"id":"w","method":"browser.wait","params":{"surface_id":"\#(page.id)","load_state":"complete","timeout_ms":1e100}}"#)
        #expect(try await client.next()["ok"] == .bool(true))
        client.send(#"{"id":"s","method":"browser.snapshot","params":{"surface_id":"\#(page.id)","max_depth":1e300}}"#)
        #expect(try await client.next()["ok"] == .bool(true))
        #expect(performed.map(\.1) == [.wait(.loadState(.complete), timeoutMs: 600_000), .snapshot(interactive: false, maxDepth: 1_000)])
    }

    @Test func closedSurfacesLeaveTheBoardAndTheList() async throws {
        let shell = terminal(at: Frame(x: 0, y: 0, w: 100, h: 100))
        let page = browser()
        try board.update(page.id, props: .object(["title": .string("checkout at 390")]))
        try board.writeBookkeeping(page.id, props: .object(["pageTitle": .string("Checkout – Shop")]))
        let client = try connect()
        client.send(#"{"id":"l","method":"surface.list","params":{"surface_id":"\#(shell.id)"}}"#)
        let listed = try await client.next()["result"]
        #expect(listed?["workspace_id"] == .string(board.id))
        #expect(listed?["surfaces"]?.array?.compactMap { $0["id"]?.string } == [shell.id, page.id])
        #expect(listed?["surfaces"]?.array?.last?["type"] == .string("browser"))
        #expect(listed?["surfaces"]?.array?.last?["title"] == .string("Checkout – Shop"), "cmux's title is the page's own")

        client.send(#"{"id":"x","method":"surface.close","params":{"surface_id":"\#(page.id)"}}"#)
        #expect(try await client.next()["ok"] == .bool(true))
        #expect(board.objects[page.id] == nil)
        client.send(#"{"id":"u","method":"browser.url.get","params":{"surface_id":"\#(page.id)"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("not_found"))
    }

    @Test func closingASurfaceCreditsTheCallingTerminal() async throws {
        let agent = terminal(at: Frame(x: 0, y: 0, w: 400, h: 300))
        let other = terminal(at: Frame(x: 0, y: 400, w: 400, h: 300))
        let client = try connect()
        // omp opens from its own terminal, then closes with only the browser's id.
        client.send(#"{"id":"o","method":"browser.open_split","params":{"surface_id":"\#(agent.id)"}}"#)
        let opened = try #require(try await client.next()["result"]?["surface_id"]?.string)
        client.send(#"{"id":"c","method":"surface.close","params":{"surface_id":"\#(opened)"}}"#)
        #expect(try await client.next()["ok"] == .bool(true))
        #expect(board.activity.entries.last { $0.kind == .deleted }?.actor == .agent(agent.id))

        // Another agent's connection closing a tile it didn't open is credited to that agent.
        let theirs = try connect()
        theirs.send(#"{"id":"o","method":"browser.open_split","params":{"surface_id":"\#(other.id)"}}"#)
        _ = try await theirs.next()
        client.send(#"{"id":"o2","method":"browser.open_split","params":{"surface_id":"\#(agent.id)"}}"#)
        let second = try #require(try await client.next()["result"]?["surface_id"]?.string)
        theirs.send(#"{"id":"c","method":"surface.close","params":{"surface_id":"\#(second)"}}"#)
        _ = try await theirs.next()
        #expect(board.activity.entries.last { $0.kind == .deleted }?.actor == .agent(other.id))

        // A fresh connection (omp reconnected) falls back to the terminal that opened the tile.
        client.send(#"{"id":"o3","method":"browser.open_split","params":{"surface_id":"\#(agent.id)"}}"#)
        let third = try #require(try await client.next()["result"]?["surface_id"]?.string)
        let fresh = try connect()
        fresh.send(#"{"id":"c","method":"surface.close","params":{"surface_id":"\#(third)"}}"#)
        _ = try await fresh.next()
        #expect(board.activity.entries.last { $0.kind == .deleted }?.actor == .agent(agent.id))
    }

    @Test func openingACanvasTileAddressDrivesThatTileAndClosingLetsGoOfIt() async throws {
        let agent = terminal(at: Frame(x: 0, y: 0, w: 400, h: 300))
        let users = browser()
        let count = board.objects.count
        let client = try connect()
        // omp's browser.open({url: "canvas:<tile id>"}): no new tile, the user's one.
        client.send(#"{"id":"o","method":"browser.open_split","params":{"url":"canvas:\#(users.id)","surface_id":"\#(agent.id)"}}"#)
        let opened = try await client.next()["result"]
        #expect(opened?["surface_id"] == .string(users.id))
        #expect(opened?["url"] == .string("http://localhost:1/"), "its current page")
        #expect(board.objects.count == count)
        client.send(#"{"id":"r","method":"browser.reload","params":{"surface_id":"\#(users.id)"}}"#)
        _ = try await client.next()
        #expect(drivers == [agent.id], "the agent drives it")
        // Two opens, two closes: the tile stays through both.
        client.send(#"{"id":"o2","method":"browser.open_split","params":{"url":"canvas://\#(users.id)"}}"#)
        _ = try await client.next()
        for id in ["c1", "c2"] {
            client.send(#"{"id":"\#(id)","method":"surface.close","params":{"surface_id":"\#(users.id)"}}"#)
            #expect(try await client.next()["ok"] == .bool(true))
        }
        #expect(board.objects[users.id] != nil, "closing lets go of someone else's tile")
        // An address that names no browser tile fails like any unknown surface.
        client.send(#"{"id":"x","method":"browser.open_split","params":{"url":"canvas:\#(agent.id)"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("invalid_params"))
        client.send(#"{"id":"y","method":"browser.open_split","params":{"url":"canvas:obj_gone"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("not_found"))
    }

    @Test func commandsNameTheTerminalDrivingThePage() async throws {
        let agent = terminal(at: Frame(x: 0, y: 0, w: 400, h: 300))
        let other = terminal(at: Frame(x: 0, y: 400, w: 400, h: 300))
        let client = try connect()
        client.send(#"{"id":"o","method":"browser.open_split","params":{"surface_id":"\#(agent.id)"}}"#)
        let opened = try #require(try await client.next()["result"]?["surface_id"]?.string)
        client.send(#"{"id":"u","method":"browser.url.get","params":{"surface_id":"\#(opened)"}}"#)
        _ = try await client.next()

        // Another agent's connection drives a tile it didn't open: that agent drives it.
        let theirs = try connect()
        theirs.send(#"{"id":"o","method":"browser.open_split","params":{"surface_id":"\#(other.id)"}}"#)
        _ = try await theirs.next()
        theirs.send(#"{"id":"u","method":"browser.url.get","params":{"surface_id":"\#(opened)"}}"#)
        _ = try await theirs.next()

        // A fresh connection falls back to the tile's opener; a user's tile has no known driver.
        let fresh = try connect()
        fresh.send(#"{"id":"u","method":"browser.url.get","params":{"surface_id":"\#(opened)"}}"#)
        _ = try await fresh.next()
        let users = browser()
        fresh.send(#"{"id":"v","method":"browser.url.get","params":{"surface_id":"\#(users.id)"}}"#)
        _ = try await fresh.next()
        #expect(drivers == [agent.id, other.id, agent.id, nil])
    }

    @Test func passwordGatesRequestsUntilAuth() async throws {
        let page = browser()
        let client = try connect(password: "s3cret")
        client.send(#"{"id":"early","method":"browser.url.get","params":{"surface_id":"\#(page.id)"}}"#)
        #expect(try await client.next()["error"]?["code"] == .string("unauthorized"))

        client.send("auth wrong")
        #expect(try await client.nextText().hasPrefix("ERROR:"))
        client.send("auth s3cret")
        #expect(try await !client.nextText().hasPrefix("ERROR:"))
        client.send(#"{"id":"late","method":"browser.url.get","params":{"surface_id":"\#(page.id)"}}"#)
        #expect(try await client.next()["ok"] == .bool(true))
        #expect(performed.map(\.1) == [.urlGet])
    }

    @Test func authWithoutAPasswordIsAccepted() async throws {
        let client = try connect()
        client.send("auth anything")
        #expect(try await !client.nextText().hasPrefix("ERROR:"), "omp sends auth whenever CMUX_SOCKET_PASSWORD is set")
        client.send("frobnicate")
        #expect(try await client.nextText().hasPrefix("ERROR: Unknown command"))
    }
}

struct BrowserURLTests {
    @Test func addressesBecomeLoadableURLs() {
        #expect(BrowserURL.normalize("https://example.com/a?b=1")?.absoluteString == "https://example.com/a?b=1")
        #expect(BrowserURL.normalize("example.com/docs")?.absoluteString == "https://example.com/docs")
        #expect(BrowserURL.normalize("localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(BrowserURL.normalize("127.0.0.1:8000/x")?.absoluteString == "http://127.0.0.1:8000/x")
        #expect(BrowserURL.normalize("devbox:8080")?.absoluteString == "http://devbox:8080")
        #expect(BrowserURL.normalize(" about:blank ")?.absoluteString == "about:blank")
        #expect(BrowserURL.normalize("file:///tmp/a.html")?.absoluteString == "file:///tmp/a.html")
    }

    @Test func textThatIsNotAnAddressIsRejected() {
        #expect(BrowserURL.normalize("how do forms work") == nil)
        #expect(BrowserURL.normalize("intranet") == nil)
        #expect(BrowserURL.normalize("javascript:alert(1)") == nil)
        #expect(BrowserURL.normalize("") == nil)
    }
}

@MainActor
struct CmuxEvalTests {
    /// One expression is awaited (its body returns it); statements run as a program.
    @Test func onlyASingleExpressionIsAwaited() {
        #expect(CmuxEval.awaitingBody("fetch('/x').then(r => r.status)") != nil)
        #expect(CmuxEval.awaitingBody("(await fetch('/x')).status") != nil, "await works inside an expression")
        #expect(CmuxEval.awaitingBody("document.title // trailing comment") != nil)
        #expect(CmuxEval.awaitingBody("(() => { const a = 1; return a })()") != nil)
        #expect(CmuxEval.awaitingBody("var x = 2; x * 3") == nil)
        #expect(CmuxEval.awaitingBody("document.title;") == nil)
        #expect(CmuxEval.awaitingBody("1)); alert((1") == nil, "nothing that escapes the wrapper counts as an expression")
    }
}

struct NavigationCreditTests {
    @Test func pageChangesGoToWhoeverActedLastWhileRecent() {
        let start = Date()
        var credit = NavigationCredit()
        #expect(credit.actor(at: start) == .system, "nobody acted: the page did it")

        credit.user(at: start)
        #expect(credit.actor(at: start.addingTimeInterval(1)) == .user)
        credit.agent("obj_agent", at: start.addingTimeInterval(2))
        #expect(credit.actor(at: start.addingTimeInterval(3)) == .agent("obj_agent"), "the latest actor wins")
        #expect(credit.actor(at: start.addingTimeInterval(2 + NavigationCredit.window)) == .agent("obj_agent"))
        #expect(credit.actor(at: start.addingTimeInterval(2.5 + NavigationCredit.window)) == .system, "long after, a page's own change")

        credit.agent(nil, at: start.addingTimeInterval(30))
        #expect(credit.actor(at: start.addingTimeInterval(31)) == .system, "a command from no known terminal credits nobody")
        credit.user(at: start.addingTimeInterval(32))
        #expect(credit.actor(at: start.addingTimeInterval(33)) == .user)
    }
}

/// soak study: after a relaunch a browser tile on a dev server (`localhost:5391`) raced the
/// server's restart and stayed blank white; a dead port was white too.
struct BrowserLoadFailureTests {
    func failure(_ address: String, _ code: Int, domain: String = NSURLErrorDomain, attempt: Int = 1) -> BrowserLoadFailure? {
        BrowserLoadFailure(url: URL(string: address)!, domain: domain, code: code, description: "The operation couldn’t be completed.", attempt: attempt)
    }

    @Test func aLocalServerNotUpYetIsRetriedWithBackoffThenWatchedUntilItAnswers() throws {
        let refused = try #require(failure("http://localhost:5391/", NSURLErrorCannotConnectToHost))
        #expect(refused.headline == "Can't reach localhost:5391" && refused.detail == "Connection refused · trying again in 1 s")
        #expect(refused.summary == "can't reach localhost:5391 (connection refused)")
        let attempts = (1...6).compactMap { failure("http://127.0.0.1:3000/app", NSURLErrorCannotConnectToHost, attempt: $0) }
        #expect(attempts.map(\.retryDelay) == BrowserLoadFailure.retryDelays.map(Optional.some) + [nil], "a few tries, further apart")
        #expect(attempts.map(\.watches) == [false, false, false, false, false, true], "then the server is watched instead")
        #expect(attempts[5].detail == "Connection refused · loads when the server answers")
        #expect(failure("http://app.localhost:8080/", NSURLErrorTimedOut)?.retryDelay == 1)
    }

    @Test func remoteAndPermanentFailuresWaitForTheUserAndCancellationsAreNoFailure() {
        #expect(failure("https://example.com/", NSURLErrorCannotConnectToHost)?.retryDelay == nil, "a remote site waits for Reload")
        #expect(failure("https://example.com/", NSURLErrorCannotConnectToHost, attempt: 6)?.watches == false, "nor is it watched")
        #expect(failure("https://nosuch.example/", NSURLErrorCannotFindHost)?.detail == "Server not found")
        #expect(failure("http://localhost:5391/", NSURLErrorSecureConnectionFailed)?.retryDelay == nil, "retrying can't fix a bad certificate")
        #expect(failure("http://localhost:5391/", NSURLErrorCancelled) == nil, "a navigation that was superseded")
        #expect(failure("https://example.com/a.zip", 102, domain: "WebKitErrorDomain") == nil, "handed to a download")
        #expect(failure("file:///tmp/gone/index.html", NSURLErrorFileDoesNotExist)?.headline == "Can't open index.html")
    }
}
