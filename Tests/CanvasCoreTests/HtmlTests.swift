import Foundation
import Testing
import CanvasCore

private func message(_ json: String) throws -> HtmlMessage {
    try HtmlMessage.parse(Data(json.utf8))
}

private func rejection(_ json: String) -> HtmlError? {
    do {
        _ = try message(json)
        return nil
    } catch {
        return error as? HtmlError
    }
}

struct HtmlMessageTests {
    @Test func acceptsEachMessageType() throws {
        #expect(try message(#"{"type":"code.excerpt","path":"src/a.swift","lines":"10-40","symbol":"Board.update"}"#)
            == .excerpt(path: "src/a.swift", lines: LineRange(start: 10, end: 40), symbol: "Board.update"))
        #expect(try message(#"{"type":"code.open","path":"src/a.swift","lines":"12"}"#)
            == .openCode(path: "src/a.swift", lines: LineRange(start: 12, end: 12), symbol: nil))
        #expect(try message(#"{"type":"state.set","key":"plan","value":{"choice":"b"}}"#)
            == .setState(key: "plan", value: .object(["choice": .string("b")])))
        #expect(try message(#"{"type":"state.set","key":"plan","value":null}"#) == .setState(key: "plan", value: .null))
        #expect(try message(#"{"type":"state.get"}"#) == .getState(key: nil))
        #expect(try message(#"{"type":"view.rendered","scrollY":120}"#) == .rendered(scrollY: 120))
        #expect(try message(#"{"type":"send","payload":{"choice":"b"}}"#) == .send(payload: .object(["choice": .string("b")])))
        #expect(try message(#"{"type":"send","payload":null}"#) == .send(payload: .null))
    }

    @Test func rejectsUnknownTypesAndFields() {
        #expect(rejection(#"{"type":"fs.read","path":"x"}"#) == .unknownType("fs.read"))
        #expect(rejection(#"{"type":"code.excerpt","path":"x","url":"https://evil"}"#) == .unexpectedField("url"))
        #expect(rejection(#"{"path":"x"}"#) == .malformed("missing type"))
        #expect(rejection(#"["code.excerpt"]"#) == .malformed("message must be an object"))
        #expect(rejection("not json") == .malformed("not JSON"))
        #expect(rejection(#"{"type":"send"}"#) == .invalidField("payload", "required"))
        #expect(rejection(#"{"type":"send","payload":1,"to":"obj_x"}"#) == .unexpectedField("to"))
    }

    @Test func rejectsOversizePayloads() {
        let payload = JSONValue.string(String(repeating: "z", count: HtmlMessage.maxMessageBytes))
        do {
            _ = try HtmlMessage.parse(.object(["type": .string("send"), "payload": payload]))
            Issue.record("a payload over the byte cap must be rejected")
        } catch {
            #expect((error as? HtmlError) == .tooLarge(HtmlMessage.maxMessageBytes + 2, limit: HtmlMessage.maxMessageBytes))
        }
    }

    @Test func rejectsMalformedFields() {
        for lines in ["40-10", "0", "1-2-3", "abc", "-4", "1-", "１２"] {
            #expect(rejection(#"{"type":"code.excerpt","path":"a","lines":"\#(lines)"}"#) != nil, "lines \(lines)")
        }
        #expect(rejection(#"{"type":"code.excerpt","path":""}"#) != nil)
        #expect(rejection(#"{"type":"code.excerpt","path":"a","symbol":"x;rm -rf"}"#) != nil)
        #expect(rejection(#"{"type":"state.set","key":"../x","value":1}"#) != nil)
        #expect(rejection(#"{"type":"state.set","key":"k"}"#) == .invalidField("value", "required"))
        #expect(rejection(#"{"type":"view.rendered","scrollY":-1}"#) != nil)
    }

    @Test func rejectsOversizeMessagesAndValues() {
        let big = String(repeating: "x", count: HtmlMessage.maxMessageBytes)
        guard case .tooLarge(_, HtmlMessage.maxMessageBytes) = rejection(#"{"type":"code.excerpt","path":"\#(big)"}"#) else {
            Issue.record("a message over the byte cap must be rejected before decoding")
            return
        }
        let value = String(repeating: "y", count: HtmlMessage.maxStateValueBytes)
        guard case .tooLarge(_, HtmlMessage.maxStateValueBytes) = rejection(#"{"type":"state.set","key":"k","value":"\#(value)"}"#) else {
            Issue.record("a state value over the cap must be rejected")
            return
        }
    }
}

struct HtmlPathTests {
    let root: URL
    let outside: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-html-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try "code".write(to: root.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    }

    @Test func boardFilesStayInsideTheRoot() throws {
        #expect(try HtmlKit.boardFile("./src//a.swift", root: root).relative == "src/a.swift")
        for path in ["../outside/secret.txt", "src/../../outside/secret.txt", "/etc/passwd", "~/.ssh/id_rsa", "escape/secret.txt", ".", ""] {
            #expect(throws: HtmlError.self, "\(path)") { try HtmlKit.boardFile(path, root: root) }
        }
    }

    @Test func kitServesOnlyRegularFilesInsideTheKit() throws {
        let kit = root.appendingPathComponent("kit")
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("vendor"), withIntermediateDirectories: true)
        try "js".write(to: kit.appendingPathComponent("vendor/m.js"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: kit.appendingPathComponent("out"), withDestinationURL: outside)

        #expect(HtmlKit.kitFile(requestPath: "/kit/vendor/m.js", kitRoot: kit)?.lastPathComponent == "m.js")
        for path in ["/kit/../src/a.swift", "/kit/vendor/../../src/a.swift", "/kit/out/secret.txt", "/kit/vendor", "/kit/vendor//m.js", "/other/m.js", "/kit/missing.js"] {
            #expect(HtmlKit.kitFile(requestPath: path, kitRoot: kit) == nil, "\(path)")
        }
        // URL decodes percent escapes before the path reaches the check.
        let encoded = URL(string: "canvas-kit://html/kit/%2e%2e/src/a.swift")!
        #expect(HtmlKit.kitFile(requestPath: encoded.path, kitRoot: kit) == nil)
    }

    @Test func networkAllowlistAcceptsOnlyHosts() {
        #expect(HtmlKit.allowedHost("LOCALHOST:08123") == "localhost:8123")
        #expect(HtmlKit.allowedHost("*.GitHub.io") == "*.github.io")
        #expect(HtmlKit.allowedHost("api.example.com") == "api.example.com")
        for entry in ["https://example.com", "example.com/path", "exa mple.com", "a|b.com", "*", "*.", "host:99999", "host:0", "-bad.com", "a..b", "user@example.com", "example.com:x@evil.com"] {
            #expect(HtmlKit.allowedHost(entry) == nil, "\(entry)")
        }
    }

    /// Whether any exception pattern lets `url` through. WebKit matches url-filters
    /// case-insensitively against the canonical URL string, as here.
    private func allowed(_ url: String, by entries: [String]) -> Bool {
        HtmlKit.exceptionPatterns(allow: entries).contains { pattern in
            let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
    }

    @Test func exceptionsPinTheWholeAuthority() {
        let entries = ["allowed.example"]
        for url in ["https://allowed.example/", "http://allowed.example:8080/x?y", "wss://allowed.example/socket", "HTTPS://ALLOWED.EXAMPLE/"] {
            #expect(allowed(url, by: entries), "\(url)")
        }
        for url in [
            "https://allowed.example:x@attacker.example/",
            "https://allowed.example:1@attacker.example/",
            "https://allowed.example@attacker.example/",
            "https://user@attacker.example/allowed.example/",
            "https://allowed.example.attacker.com/",
            "https://allowed.example%2eattacker.com/",
            "https://notallowed.example/",
            "https://sub.allowed.example/",
            "https://attacker.com/?u=https://allowed.example/",
            "file://allowed.example/etc/passwd",
            "ftp://allowed.example/",
        ] {
            #expect(!allowed(url, by: entries), "\(url)")
        }
    }

    @Test func wildcardAndPortEntriesStayNarrow() {
        let wildcard = ["*.allowed.example"]
        #expect(allowed("https://allowed.example/", by: wildcard))
        #expect(allowed("https://a.b.allowed.example/", by: wildcard))
        #expect(!allowed("https://evilallowed.example/", by: wildcard))
        #expect(!allowed("https://x.allowed.example.evil.com/", by: wildcard))
        #expect(!allowed("https://x.allowed.example:1@evil.com/", by: wildcard))

        let port = ["localhost:8123"]
        #expect(allowed("http://localhost:8123/", by: port))
        #expect(!allowed("http://localhost:8124/", by: port))
        #expect(!allowed("http://localhost/", by: port))
        #expect(!allowed("http://localhost:81234/", by: port))
        #expect(!allowed("http://localhost:8123@evil.com/", by: port))
    }

    @Test func explicitDefaultPortsMatchCanonicalURLs() {
        // WebKit drops a scheme's default port before matching, so `:443` must match the bare host.
        let https = ["example.com:0443"]
        #expect(allowed("https://example.com/", by: https))
        #expect(allowed("wss://example.com/", by: https))
        #expect(allowed("http://example.com:443/", by: https))
        #expect(!allowed("http://example.com/", by: https), "port 80 is not port 443")
        #expect(!allowed("https://example.com:8443/", by: https))

        let http = ["example.com:80"]
        #expect(allowed("http://example.com/", by: http))
        #expect(allowed("ws://example.com/", by: http))
        #expect(!allowed("https://example.com/", by: http))
    }

    @Test func remoteRulesHaveCanonicalPersistentIdentity() throws {
        let encoded = Data(HtmlKit.remoteNetworkRules.utf8)
        let rules = try JSONSerialization.jsonObject(with: encoded)
        let canonical = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        #expect(encoded == canonical, "Dictionary iteration order must not create a new persisted WK rule list")
    }

    @Test func remoteRulesBlockViewerFilesAndPrivateNetworkWithoutBlockingTheHostScheme() throws {
        let rules = try #require(JSONSerialization.jsonObject(with: Data(HtmlKit.remoteNetworkRules.utf8)) as? [[String: [String: String]]])
        let filters = try rules.map { rule in
            #expect(rule["action"]?["type"] == "block")
            return try NSRegularExpression(pattern: #require(rule["trigger"]?["url-filter"]), options: .caseInsensitive)
        }
        func blocked(_ url: String) -> Bool {
            filters.contains { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        }
        for url in ["http://public.example/data", "https://public.example/data", "file:///tmp/private",
                    "ws://127.0.0.1/socket", "wss://10.1.2.3/socket", "ws://100.64.0.1/socket",
                    "ws://100.127.255.254/socket", "wss://172.16.0.1/socket", "ws://172.31.1.2/socket",
                    "wss://[::1]/socket", "ws://service.local/socket", "wss://deckbox:5199/socket"] {
            #expect(blocked(url), "\(url)")
        }
        for url in ["canvas-kit://html/page", "canvas-kit://p-opaque/data", "wss://public.example/socket",
                    "ws://100.128.0.1/socket", "wss://172.32.0.1/socket"] {
            #expect(!blocked(url), "\(url)")
        }
    }
}

@MainActor
struct HtmlWorkQueueTests {
    /// A job that runs until released, recording that it started and whether it saw cancellation.
    @MainActor final class Gate {
        var started = 0
        var cancelled = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func job() async throws -> Int {
            started += 1
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiters.append($0) }
            } onCancel: {
                Task { @MainActor in self.releaseAll() }
            }
            if Task.isCancelled { cancelled += 1 }
            try Task.checkCancellation()
            return started
        }

        func releaseAll() {
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func boundsRunningAndQueuedWorkAndRejectsTheRest() async throws {
        let queue = HtmlWorkQueue(maxRunning: 2, maxQueued: 3)
        let gate = Gate()
        let jobs = (0..<5).map { _ in Task { try await queue.perform { try await gate.job() } } }
        await settle()
        #expect(gate.started == 2 && queue.running == 2 && queue.queued == 3)

        await #expect(throws: HtmlError.busy) { try await queue.perform { try await gate.job() } }

        // Finishing jobs hand their slots to the queue in order until everything has run.
        while gate.started < 5 {
            gate.releaseAll()
            await settle()
        }
        gate.releaseAll()
        for job in jobs { _ = try await job.value }
        #expect(queue.running == 0 && queue.queued == 0)
    }

    @Test func cancelAllFailsQueuedCancelsRunningAndKeepsServing() async throws {
        let queue = HtmlWorkQueue(maxRunning: 1, maxQueued: 2)
        let gate = Gate()
        let running = Task { try await queue.perform { try await gate.job() } }
        let queued = Task { try await queue.perform { try await gate.job() } }
        await settle()
        #expect(gate.started == 1 && queue.queued == 1)

        queue.cancelAll()
        await #expect(throws: HtmlError.cancelled) { try await queued.value }
        await #expect(throws: (any Error).self) { try await running.value }
        #expect(gate.cancelled == 1, "the running job observed cancellation")
        #expect(gate.started == 1, "the queued job never started")
        #expect(queue.running == 0)

        let after = Task { try await queue.perform { 42 } }
        #expect(try await after.value == 42)
    }

    @Test func cancelAllRejectsHandedOffWorkBeforeExecutionAndReleasesItsSlot() async throws {
        let queue = HtmlWorkQueue(maxRunning: 1, maxQueued: 1)
        let gate = Gate()
        var executed: [String] = []
        let first = Task {
            _ = try await queue.perform { try await gate.job() }
            #expect(queue.running == 1 && queue.queued == 0)
            queue.cancelAll()
            return try await queue.perform {
                executed.append("after cancellation")
                return 42
            }
        }
        while gate.started == 0 { await Task.yield() }
        let handedOff = Task {
            try await queue.perform {
                executed.append("stale work")
                return -1
            }
        }
        while queue.queued == 0 { await Task.yield() }
        #expect(queue.running == 1 && queue.queued == 1)

        gate.releaseAll()
        await #expect(throws: HtmlError.cancelled) { try await handedOff.value }
        #expect(try await first.value == 42)
        #expect(executed == ["after cancellation"])
        #expect(queue.running == 0 && queue.queued == 0)
    }
}

struct SourceExcerptTests {
    static let swift = """
    import Foundation

    /// Holds things.
    @MainActor
    final class Store {
        var items: [String] = []

        /// Adds one.
        func add(_ item: String) {
            if item.isEmpty { return }
            items.append("{\\(item)}")
        }
    }

    let limit = 5
    """

    @Test func linesResolveExactly() {
        let excerpt = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: LineRange(start: 5, end: 6), symbol: nil)
        #expect(excerpt.lines == ["final class Store {", "    var items: [String] = []"])
        #expect((excerpt.start, excerpt.end, excerpt.stale) == (5, 6, false))
        #expect(excerpt.language == "swift")
    }

    @Test func symbolsResolveToTheirDeclarationWithDocs() {
        let store = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: nil, symbol: "Store")
        #expect((store.start, store.end, store.stale) == (3, 13, false), "doc comment and attribute through the closing brace")

        let add = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: LineRange(start: 1, end: 2), symbol: "Store.add")
        #expect((add.start, add.end) == (8, 12), "the symbol wins over drifted lines; braces inside strings don't count")
        #expect(add.lines.last == "    }")

        let constant = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: nil, symbol: "limit")
        #expect((constant.start, constant.end) == (15, 15))
    }

    @Test func pythonBlocksEndAtDedent() {
        let python = "import os\n\ndef load(path,\n         mode):\n    # read it\n    with open(path) as f:\n        return f.read()\n\nx = load('a', 'r')\n"
        let excerpt = SourceExcerpt.resolve(text: python, path: "a.py", lines: nil, symbol: "load")
        #expect((excerpt.start, excerpt.end) == (3, 7))
    }

    @Test func lostAnchorsAreStaleWithAReason() {
        let missing = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: nil, symbol: "remove")
        #expect(missing.stale && missing.lines.isEmpty)
        #expect(missing.reason?.contains("remove") == true)

        let fallback = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: LineRange(start: 9, end: 9), symbol: "remove")
        #expect(fallback.stale && fallback.lines == ["    func add(_ item: String) {"], "a lost symbol still shows the recorded lines, marked stale")

        let past = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: LineRange(start: 40, end: 50), symbol: nil)
        #expect(past.stale && past.lines.isEmpty)

        let clamped = SourceExcerpt.resolve(text: Self.swift, path: "Store.swift", lines: LineRange(start: 14, end: 50), symbol: nil)
        #expect(clamped.stale && (clamped.start, clamped.end) == (14, 15))

        let file = SourceExcerpt.load(url: URL(fileURLWithPath: "/nonexistent/x.swift"), path: "x.swift", lines: LineRange(start: 1, end: 2), symbol: nil)
        #expect(file.stale && file.reason == "x.swift not found")
    }

    @Test func longRangesAreTruncated() {
        let text = (1...1000).map { "line \($0)" }.joined(separator: "\n")
        let excerpt = SourceExcerpt.resolve(text: text, path: "big.txt", lines: LineRange(start: 100, end: 900), symbol: nil)
        #expect(excerpt.truncated && !excerpt.stale)
        #expect(excerpt.lines.count == SourceExcerpt.maxLines && excerpt.lines.first == "line 100")
    }
}

@MainActor
struct HtmlChannelTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-html-\(UUID().uuidString)")
    let board: Board
    let html: CanvasObject

    init() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try SourceExcerptTests.swift.write(to: root.appendingPathComponent("src/Store.swift"), atomically: true, encoding: .utf8)
        board = Board(id: "brd_test", root: root)
        html = board.create(type: .html, props: .object(["html": .string("<p>hi</p>")]), frame: Frame(x: 0, y: 0, w: 640, h: 480))
    }

    @Test func excerptsReadBoardFilesButNotOutsideIt() async throws {
        let excerpt = try await HtmlChannel.handle(.excerpt(path: "src/Store.swift", lines: nil, symbol: "Store.add"), tile: html.id, board: board)
        #expect(excerpt["start"] == .number(8) && excerpt["stale"] == .bool(false))

        await #expect(throws: HtmlError.outsideRoot("../etc/passwd")) {
            try await HtmlChannel.handle(.excerpt(path: "../etc/passwd", lines: nil, symbol: nil), tile: html.id, board: board)
        }
    }

    @Test func openCodeCreatesBesideThenReaimsTheSameTile() async throws {
        let first = try await HtmlChannel.handle(.openCode(path: "src/Store.swift", lines: nil, symbol: "Store.add"), tile: html.id, board: board)
        #expect(first["created"] == .bool(true))
        let id = try #require(first["tile"]?.string)
        let code = try board.object(id)
        #expect(code.frame.x >= html.frame.maxX, "opens to the right of the HTML tile")
        #expect(code.props == .object(["path": .string("src/Store.swift"), "range": .object(["start": .number(8), "end": .number(12)]), "symbol": .string("Store.add")]))
        #expect(code.createdBy == .user)

        let second = try await HtmlChannel.handle(.openCode(path: "./src/Store.swift", lines: LineRange(start: 15, end: 15), symbol: nil), tile: html.id, board: board)
        #expect(second == .object(["tile": .string(id), "created": .bool(false), "existing": .bool(false)]))
        #expect(try board.object(id).props["range"] == .object(["start": .number(15), "end": .number(15)]))
        #expect(try board.object(id).props["symbol"] == nil)

        await #expect(throws: HtmlError.notFound("src/Missing.swift")) {
            try await HtmlChannel.handle(.openCode(path: "src/Missing.swift", lines: nil, symbol: nil), tile: html.id, board: board)
        }
    }

    @Test func followTilesAreNeverReaimed() async throws {
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]))
        let follow = try #require(try board.follow(tile: terminal.id, path: "src/Store.swift", range: nil, action: "read"))
        let opened = try await HtmlChannel.handle(.openCode(path: "src/Store.swift", lines: LineRange(start: 1, end: 1), symbol: nil), tile: html.id, board: board)
        #expect(opened["created"] == .bool(true) && opened["tile"]?.string != follow.id)
    }

    @Test func stateKeysPersistAndClear() async throws {
        _ = try await HtmlChannel.handle(.setState(key: "plan", value: .string("b")), tile: html.id, board: board)
        _ = try await HtmlChannel.handle(.setState(key: "notes", value: .array([.number(1)])), tile: html.id, board: board)
        #expect(try board.object(html.id).props["state"] == .object(["plan": .string("b"), "notes": .array([.number(1)])]))
        #expect(try board.object(html.id).props["html"] == .string("<p>hi</p>"))

        _ = try await HtmlChannel.handle(.setState(key: "plan", value: .null), tile: html.id, board: board)
        let got = try await HtmlChannel.handle(.getState(key: "plan"), tile: html.id, board: board)
        #expect(got == .object(["value": .null]))

        let chunk = JSONValue.string(String(repeating: "z", count: 15_000))
        await #expect(throws: HtmlError.self, "total state is capped") {
            for index in 0..<20 {
                _ = try await HtmlChannel.handle(.setState(key: "k\(index)", value: chunk), tile: html.id, board: board)
            }
        }
    }

    @Test func aPagesSendReachesTheAgentTerminalThatCreatedIt() async throws {
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path)])).id
        try board.reportLifecycle(tile: terminal, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp", protocol: 3)
        let page = board.create(type: .html, props: .object(["html": .string("<p>quiz</p>"), "title": .string("Quiz")]), caller: terminal)

        let reply = try await HtmlChannel.handle(.send(payload: .object(["answer": .string("b"), "question": .number(2)])), tile: page.id, board: board)
        #expect(reply["terminal"] == .string(terminal))
        #expect(board.messages[terminal] == nil)
        let queued = try #require(board.htmlMessages[terminal])
        #expect(queued.count == 1)
        let message = try #require(queued.first)
        #expect(reply["message"] == .string(message.id))
        #expect(message.from == nil && message.label == nil && message.html == page.id)
        #expect(message.attribution == "html")
        #expect(message.mayStartTurn == false)
        #expect(message.when == .now && message.mentions.isEmpty)
        #expect(message.text == "{\"answer\":\"b\",\"question\":2}")
    }

    @Test func aSendIsRefusedWhenTheCreatingTerminalIsGone() async throws {
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path)])).id
        try board.reportLifecycle(tile: terminal, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp", protocol: 1)
        let page = board.create(type: .html, props: .object(["html": .string("<p>quiz</p>")]), caller: terminal)
        try board.delete(terminal)

        await #expect(throws: HtmlError.unavailable("the terminal that created this page (\(terminal)) is gone")) {
            try await HtmlChannel.handle(.send(payload: .string("x")), tile: page.id, board: board)
        }
        #expect(board.messages.isEmpty)
    }

    @Test func aSendIsRefusedWhenTheCreatingTileIsNotATerminal() async throws {
        let note = board.create(type: .note, props: .object(["markdown": .string("Plan")])).id
        let page = board.create(type: .html, props: .object(["html": .string("<p>quiz</p>")]), caller: note)

        await #expect(throws: HtmlError.unavailable("the tile that created this page (\(note)) is not a terminal")) {
            try await HtmlChannel.handle(.send(payload: .string("x")), tile: page.id, board: board)
        }
        #expect(board.messages.isEmpty)
    }

    @Test func aSendIsRefusedWhenTheCreatingTerminalTakesNoMessages() async throws {
        let shell = board.create(type: .terminal, props: .object(["cwd": .string(root.path)])).id
        let page = board.create(type: .html, props: .object(["html": .string("<p>quiz</p>")]), caller: shell)

        await #expect(throws: HtmlError.unavailable("the agent in terminal \(shell) that created this page takes no messages: it needs an integration that takes them (agent.report protocol ≥ 1)")) {
            try await HtmlChannel.handle(.send(payload: .string("x")), tile: page.id, board: board)
        }
        #expect(board.messages.isEmpty)
    }

    @Test func aSendIsRefusedWhenTheCreatingAgentExited() async throws {
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path)])).id
        try board.reportLifecycle(tile: terminal, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp", protocol: 1)
        let page = board.create(type: .html, props: .object(["html": .string("<p>quiz</p>")]), caller: terminal)
        board.terminalProgram(terminal, is: nil)
        #expect(board.agentExited(terminal))

        await #expect(throws: HtmlError.unavailable("the agent in terminal \(terminal) that created this page exited: nothing takes its messages until an agent reports there again")) {
            try await HtmlChannel.handle(.send(payload: .string("x")), tile: page.id, board: board)
        }
        #expect(board.messages.isEmpty)
    }

    @Test func aSendFromAUsersTileIsRefused() async throws {
        await #expect(throws: HtmlError.unavailable("this tile was made by the user, so canvasKit.send has no agent terminal to send to")) {
            try await HtmlChannel.handle(.send(payload: .string("x")), tile: html.id, board: board)
        }
        #expect(board.messages.isEmpty)
    }

    @Test func aSendIsRefusedWhenThePayloadIsOverTheMessageCap() async throws {
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path)])).id
        try board.reportLifecycle(tile: terminal, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp", protocol: 1)
        let page = board.create(type: .html, props: .object(["html": .string("<p>quiz</p>")]), caller: terminal)

        await #expect(throws: HtmlError.tooLarge(HtmlMessage.maxMessageBytes + 2, limit: HtmlMessage.maxMessageBytes)) {
            try await HtmlChannel.handle(.send(payload: .string(String(repeating: "x", count: HtmlMessage.maxMessageBytes))), tile: page.id, board: board)
        }
        #expect(board.messages.isEmpty)
    }
}
