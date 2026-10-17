import CoreGraphics
import Foundation
import Testing
@testable import CanvasCore

/// Calls diagrams built through the real `LanguageService` from sourcekit-lsp answers recorded
/// on the package these tests write (Fixtures/call-hierarchy-sourcekit.json), replayed by a
/// stand-in server: epoch a, then epoch b after an edit that moves `replay(on:)` down, deletes
/// `relaunch()` and makes `warm()` stop calling; epoch c deletes `Spool.read` itself.
@MainActor
final class DiagramTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-diagram-\(UUID().uuidString.prefix(8))")
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/call-hierarchy-sourcekit.json")
    static let typescriptFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/call-hierarchy-typescript.json")

    static let spool = """
    public enum Spool {
        /// Reads what the spool holds.
        public static func read(from directory: String,
                                limit: Int) -> [String] {
            Array([directory].prefix(limit))
        }
    }

    """

    static let registryA = """
    public struct Registry {
        public init() {}

        public func open(root: String) -> Int {
            replay(on: root)
        }

        func replay(on root: String) -> Int {
            Spool.read(from: root, limit: 1).count
        }
    }

    func relaunch() -> Int {
        Spool.read(from: "/tmp", limit: 1).count + Spool.read(from: "/var", limit: 2).count
    }

    func warm() -> Int {
        Spool.read(from: "/warm", limit: 1).count
    }

    """

    static let registryB = """
    // The registry of open roots.
    // It replays what the spool held
    // when a root opens.
    public struct Registry {
        public init() {}

        public func open(root: String) -> Int {
            replay(on: root)
        }

        func replay(on root: String) -> Int {
            Spool.read(from: root, limit: 1).count
        }
    }

    func warm() -> Int {
        0
    }

    """

    /// Answers each request from the fixture's current epoch (the `.epoch` file in the root);
    /// the capabilities are the fixture's unless the second argument overrides them.
    static let replayServer = #"""
    import json, os, sys, urllib.parse
    fixture = json.load(open(sys.argv[1]))
    capabilities = json.loads(sys.argv[2]) if len(sys.argv) > 2 else fixture["capabilities"]
    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
    root_uri = root = None
    # Like tsserver, workspace/symbol fails while no file of the project is open.
    opened = set()

    def read():
        length = 0
        while True:
            line = stdin.readline()
            if not line:
                sys.exit(0)
            line = line.strip()
            if not line:
                break
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":")[1])
        return json.loads(stdin.read(length))

    def relative(uri):
        return urllib.parse.unquote(uri)[len(root_uri) + 1:]

    while True:
        message = read()
        method, params = message.get("method"), message.get("params") or {}
        if "id" not in message:
            if method == "exit":
                sys.exit(0)
            if method == "textDocument/didOpen":
                opened.add(params["textDocument"]["uri"])
            if method == "textDocument/didClose":
                opened.discard(params["textDocument"]["uri"])
            continue
        if method == "initialize":
            root_uri = params["rootUri"].rstrip("/")
            root = urllib.parse.unquote(root_uri[len("file://"):])
            result = {"capabilities": capabilities}
        elif method == "shutdown":
            result = None
        else:
            marker = os.path.join(root, ".epoch")
            answers = fixture["epochs"][open(marker).read().strip() if os.path.exists(marker) else "a"]
            if method == "textDocument/documentSymbol":
                key = "documentSymbol " + relative(params["textDocument"]["uri"])
            elif method == "textDocument/prepareCallHierarchy":
                key = "prepare %s:%d:%d" % (relative(params["textDocument"]["uri"]), params["position"]["line"], params["position"]["character"])
            elif method == "callHierarchy/incomingCalls":
                key = "incoming " + params["item"]["name"]
            elif method == "callHierarchy/outgoingCalls":
                key = "outgoing " + params["item"]["name"]
            elif method == "workspace/symbol":
                key = "workspaceSymbol " + params["query"]
            else:
                key = None
            result = json.loads(json.dumps(answers.get(key)).replace("file://ROOT", root_uri))
        reply = {"jsonrpc": "2.0", "id": message["id"], "result": result}
        if method == "workspace/symbol" and not opened:
            reply = {"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32603, "message": "No Project."}}
        body = json.dumps(reply).encode()
        stdout.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        stdout.flush()
    """#

    let service: LanguageService

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent(".replay.py")
        try Self.replayServer.write(to: script, atomically: true, encoding: .utf8)
        service = LanguageService(configs: [Self.server(script)])
        try write("Package.swift", "// swift-tools-version: 5.9\n")
        try write("Sources/Lib/Spool.swift", Self.spool)
        try write("Sources/Lib/Registry.swift", Self.registryA)
    }

    deinit {
        let service = service, dir = dir
        Task { await service.stopAll(); try? FileManager.default.removeItem(at: dir) }
    }

    static func typescriptServer(_ script: URL) -> LanguageServerConfig {
        LanguageServerConfig(language: "typescript", command: "/usr/bin/python3", arguments: [script.path, typescriptFixture.path],
                             languageIDs: ["ts": "typescript"], rootMarkers: ["tsconfig.json"])
    }

    static func server(_ script: URL, capabilities: String? = nil) -> LanguageServerConfig {
        LanguageServerConfig(language: "swift", command: "/usr/bin/python3", arguments: [script.path, fixture.path] + (capabilities.map { [$0] } ?? []),
                             languageIDs: ["swift": "swift"], rootMarkers: ["Package.swift"])
    }

    func write(_ relative: String, _ text: String) throws {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Epoch b: the code as edited (and re-indexed).
    func edit() throws {
        try write("Sources/Lib/Registry.swift", Self.registryB)
        try write(".epoch", "b")
    }

    func build(_ spec: DiagramSpec, previous: DiagramGraph? = nil) async throws -> DiagramGraph {
        try await CallGraphBuilder.build(spec, boardRoot: dir, previous: previous, languages: service)
    }

    static let root = "Sources/Lib/Spool.swift#Spool.read(from:limit:)"
    static let replay = "Sources/Lib/Registry.swift#Registry.replay(on:)"
    static let open = "Sources/Lib/Registry.swift#Registry.open(root:)"
    static let relaunch = "Sources/Lib/Registry.swift#relaunch()"
    static let warm = "Sources/Lib/Registry.swift#warm()"

    static let callers = DiagramSpec(path: "Sources/Lib/Spool.swift", symbol: "Spool.read", direction: .incoming, depth: 1)

    // MARK: The graph

    @Test func callersAreSymbolAnchoredNodesWithTheirCallsAndAClickOpensOneMoreLevel() async throws {
        let graph = try await build(Self.callers)
        #expect(graph.error == nil)
        #expect(graph.root == Self.root)
        let root = try #require(graph.node(Self.root))
        #expect(root.container == "Spool" && root.name == "read(from:limit:)" && root.line == 3 && root.lines == LineRange(start: 3, end: 6))
        // A signature over two lines is shown whole, without its brace.
        #expect(root.excerpt == [DiagramExcerptLine(line: 3, text: "public static func read(from directory: String,"),
                                 DiagramExcerptLine(line: 4, text: "limit: Int) -> [String]")])

        // Each caller once, at the level left of the root, showing the lines making its calls;
        // every one has a next level not yet asked for.
        #expect(graph.nodes.filter { $0.level == -1 }.map(\.id) == [Self.replay, Self.relaunch, Self.warm])
        let replay = try #require(graph.node(Self.replay))
        #expect(replay.qualifiedName == "Registry.replay(on:)" && replay.line == 8 && replay.lines == LineRange(start: 8, end: 10))
        #expect(replay.excerpt == [DiagramExcerptLine(line: 9, text: "Spool.read(from: root, limit: 1).count")])
        #expect(graph.nodes.filter { $0.level == -1 }.allSatisfy { $0.expandable == true })
        // relaunch() calls twice on one line: one edge, one line.
        #expect(graph.edges.first { $0.from == Self.relaunch } == DiagramEdge(from: Self.relaunch, to: Self.root, lines: [14]))
        #expect(graph.edges.allSatisfy { $0.to == Self.root })

        var expanded = Self.callers
        expanded.expanded = [Self.replay]
        let deeper = try await build(expanded, previous: graph)
        #expect(deeper.node(Self.replay)?.expanded == true && deeper.node(Self.replay)?.expandable == nil)
        #expect(deeper.node(Self.open)?.level == -2 && deeper.node(Self.open)?.expandable == true)
        #expect(deeper.edges.contains(DiagramEdge(from: Self.open, to: Self.replay, lines: [5])))
        #expect(deeper.node(Self.relaunch)?.expandable == true)
    }

    // MARK: Freshness

    @Test func aNodeWhoseSymbolIsGoneStaysStaleWhileMovedCodeKeepsItsNode() async throws {
        var spec = Self.callers
        spec.expanded = [Self.replay]
        let before = try await build(spec)
        try edit()
        let after = try await build(spec, previous: before)

        // replay(on:) moved down three lines: the same node, re-resolved.
        #expect(after.node(Self.replay)?.line == 11)
        #expect(after.node(Self.replay)?.isStale == false)
        #expect(after.node(Self.open)?.isStale == false)
        // relaunch() is gone from the file: kept as it was, badged, with its call.
        let relaunch = try #require(after.node(Self.relaunch))
        #expect(relaunch.isStale && relaunch.line == 13 && relaunch.expandable == nil)
        #expect(after.edges.contains(DiagramEdge(from: Self.relaunch, to: Self.root, lines: [14], stale: true)))
        // warm() still exists but no longer calls: not a caller, not stale, gone.
        #expect(after.node(Self.warm) == nil)
        #expect(!after.edges.contains { $0.from == Self.warm })

        // A diagram aimed elsewhere carries nothing over.
        var other = spec
        other.direction = .both
        #expect(try await build(other, previous: after).node(Self.relaunch) == nil)

        // The symbol back in its file: a caller again, not stale.
        try write("Sources/Lib/Registry.swift", Self.registryA)
        try write(".epoch", "a")
        let restored = try await build(spec, previous: after)
        #expect(restored.node(Self.relaunch)?.isStale == false)
        #expect(restored.nodes.filter(\.isStale).isEmpty)
    }

    @Test func codeMovedSinceTheLastBuildIsShownWhereItIsNow() async throws {
        // sourcekit-lsp places items and calls where the last build's index saw them.
        try write("Sources/Lib/Registry.swift", "// one\n// two\n// three\n" + Self.registryA)
        try write(".epoch", "d")
        var spec = Self.callers
        spec.expanded = [Self.replay]
        let graph = try await build(spec)
        let replay = try #require(graph.node(Self.replay))
        #expect(replay.line == 11 && replay.lines == LineRange(start: 11, end: 13))
        #expect(replay.excerpt == [DiagramExcerptLine(line: 12, text: "Spool.read(from: root, limit: 1).count")])
        #expect(graph.edges.contains(DiagramEdge(from: Self.relaunch, to: Self.root, lines: [17])))
        #expect(graph.edges.contains(DiagramEdge(from: Self.open, to: Self.replay, lines: [8])))
    }

    @Test func aRootWhoseSymbolIsGoneKeepsTheGraphWithTheRootStale() async throws {
        let before = try await build(Self.callers)
        try write("Sources/Lib/Spool.swift", "public enum Spool {}\n")
        try write(".epoch", "c")
        let after = try await build(Self.callers, previous: before)
        #expect(after.node(Self.root)?.isStale == true)
        #expect(after.nodes.map(\.id) == before.nodes.map(\.id))
        #expect(after.error == "Spool.read(from:limit:) is no longer declared in Sources/Lib/Spool.swift")
    }

    @Test func aServerWithoutCallHierarchySaysSoInsteadOfAnEmptyGraph() async throws {
        let script = dir.appendingPathComponent(".replay.py")
        let service = LanguageService(configs: [Self.server(script, capabilities: #"{"definitionProvider": true}"#)])
        let graph = try await CallGraphBuilder.build(Self.callers, boardRoot: dir, previous: nil, languages: service)
        #expect(graph.nodes.isEmpty)
        #expect(graph.error == "/usr/bin/python3 does not answer call hierarchy requests (no callHierarchyProvider in its capabilities)")
        await #expect(throws: LSPError.unsupportedRequest("/usr/bin/python3 does not answer type definitions requests (no typeDefinitionProvider in its capabilities)")) {
            try await service.typeDefinition(file: self.dir.appendingPathComponent("Sources/Lib/Spool.swift"), boardRoot: self.dir, at: LSPPosition(line: 2, character: 23))
        }
        await service.stopAll()
    }

    // MARK: Mentions and arrows

    func board(with graph: DiagramGraph) -> (Board, CanvasObject) {
        let board = Board(id: "brd_diagram", root: dir)
        var props = (try? JSONValue.encode(["path": "Sources/Lib/Spool.swift", "symbol": "Spool.read", "direction": "incoming"])) ?? .object([:])
        props = props.merging(.object(["depth": .number(1), "graph": graph.json]))
        let diagram = board.create(type: .diagram, props: props, frame: Frame(x: 100, y: 100, w: 900, h: 600))
        return (board, diagram)
    }

    @Test func aNodeMentionNamesItsSymbolAndPathLineAndCarriesItsCode() async throws {
        let graph = try await build(Self.callers)
        let (board, diagram) = board(with: graph)
        let replay = try #require(graph.node(Self.replay))

        let whole = replay.mention(in: diagram.id)
        #expect(MentionContext.label(for: whole, on: board) == "Sources/Lib/Registry.swift:8-10 Registry.replay(on:)")
        let resolved = await MentionContext.resolve(Mention(id: "men_1", target: whole, label: "", stagedAt: Date()), index: 1, on: board)
        let lines = resolved.summary.split(separator: "\n").map(String.init)
        #expect(lines.first == "[1] code Sources/Lib/Registry.swift:8-10 (symbol Registry.replay(on:)) · tile \(diagram.id)")
        #expect(lines.contains { $0.contains("func replay(on root: String) -> Int {") })

        // The excerpt line under the pointer: that call, still named by its symbol.
        let call = replay.mention(in: diagram.id, excerptLine: 9)
        #expect(MentionContext.label(for: call, on: board) == "Sources/Lib/Registry.swift:9 Registry.replay(on:)")
    }

    @Test func anArrowBoundToANodeEndsAtThatNodesBoxAndFollowsIt() async throws {
        let graph = try await build(Self.callers)
        let (board, diagram) = board(with: graph)
        let arrow = board.create(type: .arrow, props: .object([
            "from": .object(["point": .array([.number(-400), .number(0)])]),
            "to": .object(["object": .string(diagram.id), "node": .string(Self.warm)]),
        ]))
        func end() throws -> CGPoint { try #require(board.geometry.routes()[arrow.id]?.last) }
        let box = try #require(DiagramLayout.canvasRect(of: Self.warm, frame: diagram.frame, props: diagram.props))
        // Arrow ends stop a few points short of what they point at.
        #expect(box.insetBy(dx: -6, dy: -6).contains(try end()))
        #expect(!box.insetBy(dx: 2, dy: 2).contains(try end()))
        #expect(box.maxY < diagram.frame.rect.maxY && box.minX > diagram.frame.rect.minX)

        // The tile grows: the node moves with the fitted layout, and so does the arrow's end.
        try board.update(diagram.id, frame: Frame(x: 100, y: 100, w: 1400, h: 900))
        let moved = try #require(DiagramLayout.canvasRect(of: Self.warm, frame: try board.object(diagram.id).frame, props: diagram.props))
        #expect(moved != box)
        #expect(moved.insetBy(dx: -6, dy: -6).contains(try end()))
    }

    // MARK: A bare symbol

    /// The TypeScript project the typescript fixture was recorded on, tracked by git: class
    /// methods (`async callAsAgent(`) carry no declaration keyword, so only the language
    /// server's workspace symbols find them.
    func typescriptProject() throws -> URL {
        let root = dir.appendingPathComponent("ts")
        let files = [
            "tsconfig.json": #"{ "compilerOptions": { "strict": true, "target": "es2020", "module": "commonjs" }, "include": ["packages/**/*.ts"] }"# + "\n",
            "packages/core/src/executor.ts": """
            export class AgentActionExecutor {
              async callAsAgent(action: string): Promise<string> {
                return this.run(action);
              }

              private run(action: string): string {
                return action.toUpperCase();
              }
            }

            export class Scheduler {
              start(): void {}
            }

            """,
            "packages/core/src/tasks.ts": """
            import { AgentActionExecutor } from "./executor";

            export async function runTask(executor: AgentActionExecutor): Promise<string> {
              return executor.callAsAgent("task");
            }

            """,
            "packages/cli/src/main.ts": """
            import { AgentActionExecutor } from "../../core/src/executor";
            import { runTask } from "../../core/src/tasks";

            export class Cli {
              start(): void {}
            }

            export async function main(): Promise<void> {
              const executor = new AgentActionExecutor();
              await executor.callAsAgent("cli");
              await runTask(executor);
            }

            """,
        ]
        for (path, text) in files { try write("ts/" + path, text) }
        for arguments in [["init", "-q"], ["add", "-A"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = arguments
            git.currentDirectoryURL = root
            try git.run()
            git.waitUntilExit()
        }
        return root
    }

    @Test func aBareSymbolWithoutADeclarationKeywordIsFoundThroughTheServersWorkspaceSymbols() async throws {
        let root = try typescriptProject()
        let script = dir.appendingPathComponent(".replay.py")
        let service = LanguageService(configs: [Self.typescriptServer(script)])
        let graph = try await CallGraphBuilder.build(DiagramSpec(symbol: "AgentActionExecutor.callAsAgent", direction: .incoming),
                                                     boardRoot: root, previous: nil, languages: service)
        #expect(graph.error == nil)
        #expect(graph.root == "packages/core/src/executor.ts#AgentActionExecutor.callAsAgent")
        #expect(Set(graph.nodes.map(\.id)) == ["packages/core/src/executor.ts#AgentActionExecutor.callAsAgent", "packages/core/src/tasks.ts#runTask",
                                               "packages/cli/src/main.ts#main"])

        // The server names no container: which `start` is meant comes from the file's symbols.
        var session = CallGraphBuilder.Session(boardRoot: root, languages: service)
        #expect(try await session.locate("Cli.start") == "packages/cli/src/main.ts")
        #expect(try await session.locate("Scheduler.start") == "packages/core/src/executor.ts")

        // Two declarations: the error lists them, ready for props.path.
        let ambiguous = try await CallGraphBuilder.build(DiagramSpec(symbol: "start", direction: .incoming), boardRoot: root, previous: nil, languages: service)
        #expect(ambiguous.nodes.isEmpty)
        #expect(ambiguous.error == "start is declared 2 times; give props.path or a Container.member symbol: packages/core/src/executor.ts:12 (Scheduler.start), packages/cli/src/main.ts:5 (Cli.start)")
        await service.stopAll()
    }

    // MARK: Growing

    @Test func aDiagramGrowsIntoFreeSpaceOnlyAndNeverOverANeighbour() throws {
        let board = Board(id: "brd_grow", root: dir)
        let diagram = board.create(type: .diagram, props: .object(["symbol": .string("Spool.read")]), frame: Frame(x: 0, y: 0, w: 800, h: 500))
        let wanted = CGSize(width: 1600, height: 1100)

        // Free all round: the whole size, where it is.
        #expect(try board.grownFrame(diagram.id, toward: wanted) == Frame(x: 0, y: 0, w: 1600, h: 1100))

        // Neighbours on every side: no corner has room, so it grows right and down up to them.
        for frame in [Frame(x: 1100, y: 0, w: 400, h: 300), Frame(x: 0, y: 800, w: 400, h: 300),
                      Frame(x: -500, y: 0, w: 400, h: 300), Frame(x: 0, y: -400, w: 400, h: 300)] {
            board.create(type: .note, props: .object(["markdown": .string("neighbour")]), frame: frame)
        }
        let grown = try board.grownFrame(diagram.id, toward: wanted)
        #expect(grown.x == 0 && grown.y == 0)
        #expect(grown.w >= 800 && grown.h >= 500 && grown.w * grown.h > 800 * 500)
        #expect(grown.maxX <= 1100 - Board.placementGap && grown.maxY <= 800 - Board.placementGap)
        try board.update(diagram.id, frame: grown)
        #expect(board.overlaps(of: diagram.id).isEmpty)

        // Hemmed in: it stays as it is rather than cover anything.
        let current = try board.object(diagram.id).frame
        board.create(type: .note, props: .object(["markdown": .string("close")]), frame: Frame(x: current.maxX + 10, y: 0, w: 100, h: 100))
        board.create(type: .note, props: .object(["markdown": .string("close")]), frame: Frame(x: 0, y: current.maxY + 10, w: 100, h: 100))
        let hemmed = try board.grownFrame(diagram.id, toward: CGSize(width: 3000, height: 3000))
        #expect(hemmed.w >= current.w && hemmed.h >= current.h)
        try board.update(diagram.id, frame: hemmed)
        #expect(board.overlaps(of: diagram.id).isEmpty)
    }

    // MARK: Through the API

    /// A router computing diagrams with `languages` as the app does on a board without a window,
    /// and a client on its socket.
    func api(_ languages: LanguageService) throws -> (board: Board, router: ApiRouter, server: SocketServer, client: LineClient) {
        let home = dir.appendingPathComponent(".home")
        let registry = BoardRegistry(store: BoardStore(directory: home.appendingPathComponent("boards"), debounce: 60))
        let board = registry.open(root: dir)
        let router = ApiRouter(registry: registry)
        router.refreshDiagram = { board, tile in
            let graph = try await DiagramRefresh.run(tile, on: board, languages: languages)
            return DiagramRefresh.summary(tile, graph: graph, computed: graph != nil)
        }
        let server = SocketServer(path: home.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        return (board, router, server, try LineClient(path: home.appendingPathComponent("s").path))
    }

    /// The replay server, started `delay` seconds late (sourcekit-lsp takes its while).
    func lateServer(_ delay: Int) -> LanguageService {
        LanguageService(configs: [LanguageServerConfig(language: "swift", command: "/bin/sh",
                                                       arguments: ["-c", "sleep \(delay); exec /usr/bin/python3 \"$0\" \"$1\"", dir.appendingPathComponent(".replay.py").path, Self.fixture.path],
                                                       languageIDs: ["swift": "swift"], rootMarkers: ["Package.swift"])])
    }

    static let callersProps = #""props":{"path":"Sources/Lib/Spool.swift","symbol":"Spool.read","direction":"incoming","depth":1}"#

    /// An agent's first "who calls X?" right after launch: `object.create` with `size: "fit"`
    /// before the language server has answered anything. The create waits for the graph and fits
    /// the tile to it.
    @Test func aDiagramCreatedWithSizeFitWaitsForItsFirstGraphAndFitsIt() async throws {
        let slow = lateServer(2)
        let (board, _, server, client) = try api(slow)
        defer { server.stop() }
        func create(_ params: String) async throws -> JSONValue {
            client.send(#"{"id":"1","method":"object.create","params":{"type":"diagram","size":"fit",\#(params)}}"#)
            return try await client.next()
        }

        let reply = try await create(Self.callersProps)
        #expect(reply["ok"] == .bool(true), "\(reply["error"] ?? .null)")
        let id = try #require(reply["result"]?["object"]?["id"]?.string)
        let diagram = try board.object(id)
        let graph = try #require(DiagramGraph(diagram.props["graph"]))
        #expect(graph.nodes.count == 4)
        #expect(reply["result"]?["diagram"]?["loaded"] == .bool(true))
        #expect(reply["result"]?["diagram"]?["nodes"] == .number(4))
        let fit = DiagramLayout(graph).bodySize
        #expect(diagram.frame.w == Double(fit.width) && diagram.frame.h == Double(RenderMath.tileTitleHeight + fit.height))
        #expect(reply["result"]?["object"]?["frame"]?["h"] == .number(diagram.frame.h))

        // At the origin given; the fit is the create's, not an undo step of its own.
        let placed = try await create(#""frame":{"x":4000,"y":-300},\#(Self.callersProps)"#)
        let at = try board.object(try #require(placed["result"]?["object"]?["id"]?.string)).frame
        #expect(at.x == 4000 && at.y == -300 && at.w == diagram.frame.w && at.h == diagram.frame.h)
        #expect(board.undo())
        #expect(board.objects[placed["result"]?["object"]?["id"]?.string ?? ""] == nil)
        await slow.stopAll()

        // Moved by the user while its graph is computed (the server cold again): fitted where it is now.
        client.send(#"{"id":"2","method":"object.create","params":{"type":"diagram","size":"fit","frame":{"x":4000,"y":-300},\#(Self.callersProps)}}"#)
        var moving: CanvasObject?
        for _ in 0..<100 where moving == nil {
            try await Task.sleep(for: .milliseconds(20))
            moving = board.objects.values.first { $0.type == .diagram && $0.id != id }
        }
        let tile = try #require(moving)
        try board.update(tile.id, frame: Frame(x: -900, y: 1200, w: tile.frame.w, h: tile.frame.h))
        let moved = try await client.next()
        #expect(moved["result"]?["diagram"]?["loaded"] == .bool(true))
        let now = try board.object(tile.id).frame
        #expect(now.x == -900 && now.y == 1200 && now.w == diagram.frame.w && now.h == diagram.frame.h)
        await slow.stopAll()

        // Deleted by the user while its graph is computed: the create still succeeded, and says so.
        let before = Set(board.objects.keys)
        client.send(#"{"id":"3","method":"object.create","params":{"type":"diagram","size":"fit",\#(Self.callersProps)}}"#)
        var created: ObjectID?
        for _ in 0..<100 where created == nil {
            try await Task.sleep(for: .milliseconds(20))
            created = board.objects.keys.first { !before.contains($0) }
        }
        try board.delete(try #require(created))
        let gone = try await client.next()
        #expect(gone["ok"] == .bool(true), "\(gone)")
        #expect(gone["result"]?["warnings"]?.array?.contains(.string("\(created ?? "") was deleted while its graph was computed")) == true)
        await slow.stopAll()
    }

    /// A language server that doesn't answer in time (here it starts 120 s late, past the
    /// client's 30 s read) holds neither `object.reload` past its `timeoutMs` nor a fitted create
    /// past the router's wait: each answers with the graph not loaded, and the computation goes on.
    @Test func aDiagramWaitEndsAtItsTimeoutWhileTheServerHasntAnswered() async throws {
        let late = lateServer(120)
        let (board, router, server, client) = try api(late)
        defer { server.stop() }
        router.diagramTimeoutMs = 500
        client.send(#"{"id":"1","method":"object.create","params":{"type":"diagram","size":"fit",\#(Self.callersProps)}}"#)
        let created = try await client.next()
        #expect(created["ok"] == .bool(true), "\(created["error"] ?? .null)")
        #expect(created["result"]?["diagram"]?["loaded"] == .bool(false))
        #expect(created["result"]?["object"]?["frame"]?["w"] == .number(Board.defaultSize(.diagram).w), "the tile is there, at its default size")
        #expect(created["result"]?["warnings"]?.array?.first?.string?.contains("object.reload") == true)
        let id = try #require(created["result"]?["object"]?["id"]?.string)
        #expect(board.objects[id] != nil)

        client.send(#"{"id":"2","method":"object.reload","params":{"id":"\#(id)","timeoutMs":300}}"#)
        let reloaded = try await client.next()
        #expect(reloaded["result"]?["loaded"] == .bool(false), "\(reloaded)")
        await late.stopAll()
    }


    @Test func aViewerComputesEasldsCopyOfADiagramNotItsOwnPreview() async throws {
        let host = DelegatedCallsTests.NoHost()
        let board = Board(remote: "brd_host", root: dir, host: host)
        let easlds = CanvasObject(id: "obj_calls", type: .diagram, frame: Frame(x: 0, y: 0, w: 800, h: 500), z: 0, rev: 4, createdBy: .user, createdAt: Date(),
                                  props: .object(["kind": "calls", "path": "Sources/Lib/Spool.swift", "symbol": "Spool.read", "direction": "incoming", "depth": 1]))
        board.applyHost(easlds)
        try board.update(easlds.id, props: .object(["symbol": "Registry.replay"]))
        let calls = DelegatedCalls(board: board, window: ViewerWindow(
            focused: { false }, viewState: { nil },
            render: { _, _ in throw ApiRouter.Failure("unavailable", "no canvas") }, hostPicture: { _ in false },
            measureHTML: { _, _ in throw ApiRouter.Failure("unavailable", "no page") },
            reload: { _, _, _ in throw ApiRouter.Failure("unavailable", "no browser") },
            submit: { _, _ in false }, surfaceTail: { _, _ in nil },
            block: { _, _ in throw ApiRouter.Failure("unavailable", "no command has finished") }, status: { _ in nil }, languages: { [service] in service }))

        let answer = try await calls.answer(EaslConnection.Call(method: "object.reload", params: .object(["id": "obj_calls", "_diagram": try JSONValue.encode(easlds)]))).get()
        #expect(answer["id"] == "obj_calls" && answer["loaded"] == .bool(true) && answer["rev"] == 4)
        let graph = try #require(DiagramGraph(answer["graph"]))
        #expect(graph.root == Self.root)
        #expect(graph.nodes.filter { $0.level == -1 }.map(\.id) == [Self.replay, Self.relaunch, Self.warm])

        let unsnapshotted = await calls.answer(EaslConnection.Call(method: "object.reload", params: .object(["id": "obj_calls"])))
        guard case .failure(let failure) = unsnapshotted else { Issue.record("a diagram without the host snapshot was computed"); return }
        #expect(failure.code == "unavailable")
    }
}

/// The pan after a user opens a diagram node (`Layout.revealGrown`): a viewport 1000 × 800 at
/// zoom 1 from (0, 0), padding 20.
struct DiagramExpandPanTests {
    let clear = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let view = Layout.Jump(zoom: 1, origin: .zero)

    func shown(_ jump: Layout.Jump) -> CGRect { jump.shown(clear) }

    @Test func aGrownTileThatFitsIsShownWholeByTheLeastPan() {
        // Grown up and left past the view's corner.
        let tile = CGRect(x: -300, y: -200, width: 900, height: 700)
        let jump = Layout.revealGrown(tile, added: CGRect(x: -280, y: -180, width: 300, height: 600), clicked: CGRect(x: 100, y: 300, width: 300, height: 70),
                                      from: view, clear: clear, padding: 20)
        #expect(jump.zoom == 1)
        #expect(jump.origin == CGPoint(x: -320, y: -220))
        #expect(shown(jump).contains(tile.insetBy(dx: -20, dy: -20)))
        // Already in view: nothing moves.
        let inside = CGRect(x: 100, y: 100, width: 400, height: 300)
        #expect(Layout.revealGrown(inside, added: inside, clicked: inside, from: view, clear: clear, padding: 20) == view)
    }

    @Test func aTileTooBigShowsTheAddedNodesWithTheClickedOne() {
        let tile = CGRect(x: -700, y: -900, width: 1600, height: 1800)
        let clicked = CGRect(x: 300, y: 380, width: 300, height: 70)
        // The added column, left of the clicked node, fits with it.
        let added = CGRect(x: -350, y: 100, width: 300, height: 600)
        let jump = Layout.revealGrown(tile, added: added, clicked: clicked, from: view, clear: clear, padding: 20)
        #expect(jump.zoom == 1)
        #expect(shown(jump).contains(added) && shown(jump).contains(clicked))
        #expect(jump.origin.y == 0)

        // Added nodes taller than the view: their left and top edges show, and the clicked node
        // stays wholly in view.
        let tall = CGRect(x: -350, y: -900, width: 300, height: 1800)
        let cut = Layout.revealGrown(tile, added: tall, clicked: clicked, from: view, clear: clear, padding: 20)
        #expect(cut.zoom == 1)
        #expect(shown(cut).contains(clicked))
        #expect(shown(cut).minX <= tall.minX - 20)
        #expect(shown(cut).minY < 0 && shown(cut).maxY >= clicked.maxY)
    }
}
