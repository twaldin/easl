import Foundation
import Testing
@testable import CanvasCore

/// Generic caller-supplied graphs (`DiagramKind.graph`) through the API: levels computed from
/// the reasoning edges, provenance and practice status kept, and nothing recomputed from code.
@MainActor
final class GraphDiagramTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-graph-\(UUID().uuidString.prefix(8))")
    var computed = 0

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A router on a socket, its diagram refresh counting calls: a graph diagram never asks it.
    func api() async throws -> (board: Board, router: ApiRouter, server: SocketServer, client: LineClient) {
        let home = dir.appendingPathComponent(".home")
        let registry = BoardRegistry(store: BoardStore(directory: home.appendingPathComponent("boards"), debounce: 60))
        let board = try await registry.open(root: dir)
        let router = ApiRouter(registry: registry)
        router.refreshDiagram = { _, _ in
            self.computed += 1
            throw ApiRouter.Failure("internal", "a graph diagram must not be computed from code")
        }
        let server = SocketServer(path: home.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        return (board, router, server, try LineClient(path: home.appendingPathComponent("s").path))
    }

    func call(_ client: LineClient, _ id: String, _ method: String, _ params: String) async throws -> JSONValue {
        client.send(#"{"id":"\#(id)","method":"\#(method)","params":\#(params)}"#)
        return try await client.next()
    }

    static let reasoningProps = #" {"kind":"graph","title":"Why the cache lies","knowledge":{ "nodes":[ {"id":"cold","label":"Tests fail on a cold start","detail":"The first read after launch returns an empty cache.","sources":[{"session":"sess-1"}],"status":"weak"}, {"id":"stale","label":"The cache keeps a stale stamp","detail":"**Root cause**: the stamp is written before the read.","sources":[{"message":"m-9"}],"status":"taught"}, {"id":"fix","label":"Write the stamp after the read","sources":[{"tile":"obj_term"}],"status":"practiced"}, {"id":"verify","label":"Cold-start tests pass","status":"retained"} ], "edges":[ {"from":"cold","to":"stale","label":"observed by"}, {"from":"stale","to":"fix","label":"fixed by"}, {"from":"fix","to":"verify","label":"verified by"} ] }}"#

    @Test func callerGraphsGetReasoningLevelsAndKeepDetailSourcesAndStatus() async throws {
        let (_, _, server, client) = try await api()
        defer { server.stop() }
        let created = try await call(client, "1", "object.create", #"{"type":"diagram","props":\#(Self.reasoningProps)}"#)
        #expect(created["ok"] == .bool(true), "\(created["error"] ?? .null)")
        let id = try #require(created["result"]?["object"]?["id"]?.string)
        let got = try await call(client, "2", "object.get", #"{"id":"\#(id)"}"#)
        let props = try #require(got["result"]?["object"]?["props"])
        let graph = try #require(DiagramGraph(props["knowledge"]))

        #expect(graph.aim.kind == .graph)
        #expect(graph.nodes.map(\.id) == ["cold", "stale", "fix", "verify"])
        // Premises sit at level 0; each conclusion is one deeper than its deepest premise.
        #expect(graph.nodes.map(\.level) == [0, 1, 2, 3])
        #expect(graph.node("stale")?.name == "The cache keeps a stale stamp")
        #expect(graph.node("stale")?.detail == "**Root cause**: the stamp is written before the read.")
        #expect(graph.node("stale")?.sources == [DiagramSource(message: "m-9")])
        #expect(graph.node("stale")?.status == .taught)
        #expect(graph.node("verify")?.status == .retained)
        #expect(graph.edges.map(\.from) == ["cold", "stale", "fix"])
        #expect(graph.edges.map(\.label) == ["observed by", "fixed by", "verified by"])
        #expect(self.computed == 0)
    }

    /// Each rule a caller's graph must keep is named by the refusal, in the caller's own terms.
    @Test func invalidGraphsAreRefusedWithTheRuleTheyBreak() async throws {
        let (_, _, server, client) = try await api()
        defer { server.stop() }
        let cases: [(props: String, rule: String)] = [
            (#"{"kind":"graph","knowledge":{"nodes":[{"id":"a","label":"A"},{"id":"a","label":"B"}]}}"#, "duplicate node id \"a\""),
            (#"{"kind":"graph","knowledge":{"nodes":[{"id":"a","label":"A"}],"edges":[{"from":"a","to":"ghost"}]}}"#, "edges[0].to \"ghost\" is not a node"),
            (#"{"kind":"graph","knowledge":{"nodes":[{"id":"a","label":"  "}]}}"#, "nodes[0].label must not be empty"),
            (#"{"kind":"graph","knowledge":{"nodes":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"edges":[{"from":"a","to":"b"},{"from":"b","to":"a"}]}}"#, "cycle through node \"a\""),
            (#"{"kind":"graph","knowledge":{"nodes":[{"id":"a","label":"A","status":"known"}]}}"#, "status must be one of taught, practiced, retained, weak"),
            (#"{"kind":"graph","knowledge":{"nodes":[{"id":"a","label":"A","sources":[{"author":"me"}]}]}}"#, "needs a session, message, board, or tile"),
            (#"{"kind":"graph","knowledge":{"nodes":[{"id":"a","label":"A","sources":[{"tile":""}]}]}}"#, "sources[0].tile must be a non-empty string"),
            (#"{"kind":"graph","knowledge":{"nodes":[]}}"#, "needs at least one node"),
            (#"{"kind":"graph","knowledge":{"nodes":[{"id":"a","label":"A"}],"edges":[{"from":"a"}]}}"#, "edges[0].to must be a node id"),
        ]
        for (index, entry) in cases.enumerated() {
            let reply = try await call(client, "bad\(index)", "object.create", #"{"type":"diagram","props":\#(entry.props)}"#)
            #expect(reply["ok"] == .bool(false), "\(entry.props) was accepted")
            #expect(reply["error"]?["code"]?.string == "invalid_params", "\(reply["error"] ?? .null)")
            #expect(reply["error"]?["message"]?.string?.contains(entry.rule) == true, "\(reply["error"]?["message"] ?? .null) does not name \(entry.rule)")
        }
    }

    /// Levels are only required where they would have to be computed: a cycle drawn on purpose is
    /// accepted when every node says its level.
    @Test func anExplicitlyLevelledCycleIsAccepted() async throws {
        let (_, _, server, client) = try await api()
        defer { server.stop() }
        let props = #"{"kind":"graph","knowledge":{"nodes":[{"id":"a","label":"A","level":0},{"id":"b","label":"B","level":1}],"edges":[{"from":"a","to":"b"},{"from":"b","to":"a"}]}}"#
        let created = try await call(client, "1", "object.create", #"{"type":"diagram","props":\#(props)}"#)
        #expect(created["ok"] == .bool(true), "\(created["error"] ?? .null)")
        let id = try #require(created["result"]?["object"]?["id"]?.string)
        let got = try await call(client, "2", "object.get", #"{"id":"\#(id)"}"#)
        let graph = try #require(DiagramGraph(got["result"]?["object"]?["props"]?["knowledge"]))
        #expect(graph.nodes.map(\.level) == [0, 1])
        #expect(graph.edges.count == 2)
    }

    static func nodeList(_ count: Int) -> String {
        (0..<count).map { #"{"id":"n\#($0)","label":"Node \#($0)"}"# }.joined(separator: ",")
    }

    /// A knowledge graph is authored on purpose, so it may be far larger than a calls graph: up to
    /// 500 nodes, and not one more.
    @Test func theNodeCapIsFiveHundred() async throws {
        let (_, _, server, client) = try await api()
        defer { server.stop() }
        let atCap = try await call(client, "1", "object.create",
                                    #"{"type":"diagram","props":{"kind":"graph","knowledge":{"nodes":[\#(Self.nodeList(500))],"edges":[]}}}"#)
        #expect(atCap["ok"] == .bool(true), "\(atCap["error"] ?? .null)")
        let id = try #require(atCap["result"]?["object"]?["id"]?.string)
        let got = try await call(client, "2", "object.get", #"{"id":"\#(id)"}"#)
        #expect(DiagramGraph(got["result"]?["object"]?["props"]?["knowledge"])?.nodes.count == 500)

        let over = try await call(client, "3", "object.create",
                                  #"{"type":"diagram","props":{"kind":"graph","knowledge":{"nodes":[\#(Self.nodeList(501))],"edges":[]}}}"#)
        #expect(over["ok"] == .bool(false))
        #expect(over["error"]?["message"]?.string?.contains("501 nodes: at most 500") == true, "\(over["error"] ?? .null)")
    }

    @Test func graphEdgeLimitsRejectTenThousandDuplicatesAndPreserveRefusedUpdates() async throws {
        let (_, _, server, client) = try await api()
        defer { server.stop() }
        var distinct: [String] = []
        edgePairs: for from in 0..<500 {
            for to in (from + 1)..<500 {
                distinct.append(#"{"from":"n\#(from)","to":"n\#(to)"}"#)
                if distinct.count == 2001 { break edgePairs }
            }
        }
        let nodes = Self.nodeList(500)
        let created = try await call(client, "at", "object.create",
                                     #"{"type":"diagram","props":{"kind":"graph","knowledge":{"nodes":[\#(nodes)],"edges":[\#(distinct.prefix(2000).joined(separator: ","))]}}}"#)
        #expect(created["ok"] == .bool(true), "\(created["error"] ?? .null)")
        let id = try #require(created["result"]?["object"]?["id"]?.string)
        let over = try await call(client, "over", "object.create",
                                  #"{"type":"diagram","props":{"kind":"graph","knowledge":{"nodes":[\#(nodes)],"edges":[\#(distinct.joined(separator: ","))]}}}"#)
        #expect(over["ok"] == .bool(false))
        #expect(over["error"]?["message"]?.string?.contains("2001 edges: at most 2000") == true)
        let repeated = Array(repeating: #"{"from":"a","to":"b"}"#, count: 10000).joined(separator: ",")
        let props = #"{"kind":"graph","knowledge":{"nodes":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"edges":[\#(repeated)]}}"#
        let refusedCreate = try await call(client, "duplicates", "object.create", #"{"type":"diagram","props":\#(props)}"#)
        #expect(refusedCreate["ok"] == .bool(false))
        #expect(refusedCreate["error"]?["message"]?.string?.contains("10000 edges: at most 2000") == true)
        let refusedUpdate = try await call(client, "update", "object.update", #"{"id":"\#(id)","props":\#(props)}"#)
        #expect(refusedUpdate["ok"] == .bool(false))
        #expect(refusedUpdate["error"]?["message"]?.string?.contains("10000 edges: at most 2000") == true)
        let got = try await call(client, "get", "object.get", #"{"id":"\#(id)"}"#)
        let graph = try #require(DiagramGraph(got["result"]?["object"]?["props"]?["knowledge"]))
        #expect(graph.nodes.count == 500)
        #expect(graph.edges.count == 2000)
        #expect(got["result"]?["object"]?["rev"]?.int == 1)
    }

    static func boundedGraphProps(nodes: [JSONValue], edges: [JSONValue] = []) -> JSONValue {
        .object(["kind": "graph", "knowledge": .object(["nodes": .array(nodes), "edges": .array(edges)])])
    }

    @Test func graphDuplicateEdgesUseDirectedEndpointsRegardlessOfLabel() throws {
        let nodes: [JSONValue] = [
            .object(["id": "a", "label": "A", "level": 0]),
            .object(["id": "b", "label": "B", "level": 1]),
        ]
        let first: JSONValue = .object(["from": "a", "to": "b", "label": "first"])
        let labels: [JSONValue] = [.null, "first", "different", .number(7)]
        for label in labels {
            let duplicate: JSONValue = .object(["from": "a", "to": "b", "label": label])
            let result = DiagramSpec.graph(Self.boundedGraphProps(nodes: nodes, edges: [first, duplicate]))
            #expect(result.graph == nil)
            #expect(result.problem == #"props.knowledge.edges[1] duplicates directed edge "a" -> "b""#)
        }
        let distinct: [JSONValue] = [first, .object(["from": "b", "to": "a"]), .object(["from": "a", "to": "a"])]
        let result = DiagramSpec.graph(Self.boundedGraphProps(nodes: nodes, edges: distinct))
        #expect(result.problem == nil)
        let graph = try #require(result.graph)
        #expect(graph.edges.count == 3)
        let collisionNodes: [JSONValue] = ["a->b", "c", "a", "b->c"].map {
            .object(["id": .string($0), "label": .string($0)])
        }
        let collisionEdges: [JSONValue] = [
            .object(["from": "a->b", "to": "c"]), .object(["from": "a", "to": "b->c"]),
        ]
        #expect(DiagramSpec.graph(Self.boundedGraphProps(nodes: collisionNodes, edges: collisionEdges)).graph?.edges.count == 2)
    }

    static func graphTextProps(_ field: String, _ text: String) -> JSONValue {
        var node: [String: JSONValue] = ["id": "a", "label": "A"]
        var edges: [JSONValue] = []
        switch field {
        case "edgeLabel":
            edges = [.object(["from": "a", "to": "b", "label": .string(text)])]
        case "session", "message", "board", "tile":
            node["sources"] = .array([.object([field: .string(text)])])
        case "name":
            node.removeValue(forKey: "label")
            node["name"] = .string(text)
        default:
            node[field] = .string(text)
        }
        return boundedGraphProps(nodes: [.object(node), .object(["id": "b", "label": "B"])], edges: edges)
    }

    @Test func graphTextLimitsCountUTF8BytesAndKeepBoundaryText() throws {
        let fields: [(String, Int, String)] = [
            ("id", 256, "props.knowledge.nodes[0].id"),
            ("label", 512, "props.knowledge.nodes[0].label"),
            ("name", 512, "props.knowledge.nodes[0].label"),
            ("detail", 8192, "props.knowledge.nodes[0].detail"),
            ("edgeLabel", 256, "props.knowledge.edges[0].label"),
            ("session", 256, "props.knowledge.nodes[0].sources[0].session"),
            ("message", 256, "props.knowledge.nodes[0].sources[0].message"),
            ("board", 256, "props.knowledge.nodes[0].sources[0].board"),
            ("tile", 256, "props.knowledge.nodes[0].sources[0].tile"),
        ]
        for (field, limit, path) in fields {
            for unit in ["x", "é", "🙂"] {
                let text = String(repeating: unit, count: limit / unit.utf8.count)
                let accepted = DiagramSpec.graph(Self.graphTextProps(field, text))
                #expect(accepted.problem == nil, "\(field): \(accepted.problem ?? "")")
                let graph = try #require(accepted.graph)
                let stored: String?
                switch field {
                case "edgeLabel": stored = graph.edges.first?.label
                case "session", "message", "board", "tile":
                    stored = graph.json["nodes"]?.array?.first?["sources"]?.array?.first?[field]?.string
                case "label", "name": stored = graph.nodes.first?.name
                case "detail": stored = graph.nodes.first?.detail
                default: stored = graph.nodes.first?.id
                }
                #expect(stored == text)
                let refused = DiagramSpec.graph(Self.graphTextProps(field, text + "x"))
                #expect(refused.graph == nil)
                #expect(refused.problem == "\(path) exceeds \(limit) UTF-8 bytes")
            }
        }
    }

    @Test func graphSourceCountsAndValidationOrderAreBounded() throws {
        let source: JSONValue = .object(["session": "s", "message": "m", "board": "b", "tile": "t"])
        let node: JSONValue = .object(["id": "a", "label": "A", "sources": .array(Array(repeating: source, count: 8))])
        let accepted = DiagramSpec.graph(Self.boundedGraphProps(nodes: [node]))
        #expect(accepted.problem == nil)
        let graph = try #require(accepted.graph)
        #expect(graph.nodes.first?.sources?.count == 8)
        let tooMany: JSONValue = .object(["id": "a", "label": "A", "sources": .array(Array(repeating: .null, count: 9))])
        let refused = DiagramSpec.graph(Self.boundedGraphProps(nodes: [tooMany]))
        #expect(refused.graph == nil)
        #expect(refused.problem == "props.knowledge.nodes[0].sources has 9 entries: at most 8")
        let badEdges = Array(repeating: JSONValue.null, count: 2001)
        let plain: JSONValue = .object(["id": "a", "label": "A"])
        #expect(DiagramSpec.graph(Self.boundedGraphProps(nodes: [plain], edges: badEdges)).problem == "props.knowledge.edges has 2001 edges: at most 2000")
        let badNode: JSONValue = .object(["id": "a", "label": .string(String(repeating: "x", count: 513))])
        #expect(DiagramSpec.graph(Self.boundedGraphProps(nodes: [badNode], edges: badEdges)).problem == "props.knowledge.nodes[0].label exceeds 512 UTF-8 bytes")
    }

    /// What practice shows feeds back as a node's status through `object.update`; a reload is a
    /// no-op success that neither recomputes nor overwrites the caller's graph.
    @Test func practiceStatusFeedsBackThroughObjectUpdateAndReloadKeepsTheGraph() async throws {
        let (_, _, server, client) = try await api()
        defer { server.stop() }
        let created = try await call(client, "1", "object.create", #"{"type":"diagram","props":\#(Self.reasoningProps)}"#)
        let id = try #require(created["result"]?["object"]?["id"]?.string)
        let stronger = Self.reasoningProps.replacingOccurrences(of: #""status":"weak""#, with: #""status":"retained""#)
        let reply = try await call(client, "2", "object.update", #"{"id":"\#(id)","props":\#(stronger)}"#)
        #expect(reply["ok"] == .bool(true), "\(reply["error"] ?? .null)")
        let updated = try await call(client, "3", "object.get", #"{"id":"\#(id)"}"#)
        let graph = try #require(DiagramGraph(updated["result"]?["object"]?["props"]?["knowledge"]))
        #expect(graph.nodes.map(\.status) == [.retained, .taught, .practiced, .retained])
        #expect(graph.nodes.map(\.level) == [0, 1, 2, 3], "an update recomputes the levels the caller left out")
        #expect(graph.node("cold")?.detail == "The first read after launch returns an empty cache.")

        let reloaded = try await call(client, "4", "object.reload", #"{"id":"\#(id)"}"#)
        #expect(reloaded["ok"] == .bool(true), "\(reloaded["error"] ?? .null)")
        #expect(reloaded["result"]?["loaded"] == .bool(true))
        #expect(reloaded["result"]?["nodes"] == .number(4))
        #expect(self.computed == 0, "a graph diagram is never computed from code")
        let after = try await call(client, "5", "object.get", #"{"id":"\#(id)"}"#)
        #expect(DiagramGraph(after["result"]?["object"]?["props"]?["knowledge"]) == graph)
    }

    /// A fitted graph grows to its reasoning levels: four levels are four columns, whatever the
    /// code-measuring path would say about a graph with no symbols.
    @Test func aFittedGraphDiagramSizesToItsDeepestLevel() async throws {
        let (_, _, server, client) = try await api()
        defer { server.stop() }
        let created = try await call(client, "1", "object.create", #"{"type":"diagram","size":"fit","props":\#(Self.reasoningProps)}"#)
        #expect(created["ok"] == .bool(true), "\(created["error"] ?? .null)")
        #expect(created["result"]?["diagram"]?["loaded"] == .bool(true))
        // 4 * 300 wide, 3 * 76 between them, 36 either side.
        #expect(created["result"]?["object"]?["frame"]?["w"] == .number(1500))
    }

    @Test func measurementKeepsDiagramKindsAndValidationErrorsSeparate() async throws {
        let (_, _, server, client) = try await api()
        defer { server.stop() }
        let cases = [
            (#"{"kind":"calls","symbol":"Foo.bar","knowledge":{"nodes":[{"id":"a","label":"A"}]}}"#, "unavailable"),
            (#"{"kind":"graph","knowledge":{"nodes":[{"id":"a","label":"A","level":1.5}]}}"#, "invalid_params"),
            (#"{"kind":"graph","knowledge":{"nodes":[]}}"#, "invalid_params"),
        ]
        for (index, entry) in cases.enumerated() {
            let reply = try await call(client, "measure-\(index)", "object.measure", #"{"type":"diagram","props":\#(entry.0)}"#)
            #expect(reply["ok"] == .bool(false))
            #expect(reply["error"]?["code"]?.string == entry.1)
        }
    }

    @Test func graphLevelsRejectUnsafeNumbersAndKeepExactBoundaries() throws {
        let upper = Double(Int.max).nextDown
        for raw in [1e300, -1e300, 1.5, Double.nan, Double.infinity, -1, Double(Int.max)] {
            let result = DiagramSpec.graph(Self.boundedGraphProps(nodes: [
                .object(["id": "a", "label": "A", "level": .number(raw)]),
            ]))
            #expect(result.graph == nil)
            #expect(result.problem == "props.knowledge.nodes[0].level must be a non-negative integer")
        }
        for raw in [0.0, 1.0, upper] {
            let result = DiagramSpec.graph(Self.boundedGraphProps(nodes: [
                .object(["id": "a", "label": "A", "level": .number(raw)]),
            ]))
            #expect(result.problem == nil)
            #expect(result.graph?.nodes.first?.level == Int(exactly: raw))
        }
    }

    @Test func sparseExtremeLevelsUseOnlyOccupiedColumnsAndSafeArrowArithmetic() throws {
        for raw in [1e18, Double(Int.max).nextDown] {
            let result = DiagramSpec.graph(Self.boundedGraphProps(nodes: [
                .object(["id": "a", "label": "A", "level": 0]),
                .object(["id": "b", "label": "B", "level": .number(raw)]),
            ], edges: [.object(["from": "a", "to": "b"]), .object(["from": "b", "to": "a"])]))
            let graph = try #require(result.graph, "\(result.problem ?? "")")
            #expect(DiagramLayout(graph).size.width == 748)
            #expect(graph.nodes[1].level - graph.nodes[0].level == Int(exactly: raw))
            #expect(graph.nodes[0].level - graph.nodes[1].level == -Int(exactly: raw)!)
            let props: JSONValue = .object(["kind": "graph", "knowledge": graph.json])
            #expect(DiagramLayout.canvasRect(of: "b", frame: Frame(x: 0, y: 0, w: 760, h: 480), props: props) != nil)
        }
    }

    @Test func oldRefreshKeepsKnowledgeThroughSaveAndHeadReload() async throws {
        let (board, _, server, client) = try await api()
        defer { server.stop() }
        let created = try await call(client, "create", "object.create", #"{"type":"diagram","props":\#(Self.reasoningProps)}"#)
        let id = try #require(created["result"]?["object"]?["id"]?.string)
        let before = try board.object(id)
        let knowledge = try #require(before.props["knowledge"])
        #expect(before.props["graph"] == nil)
        let oldCache = DiagramGraph(aim: DiagramAim(kind: .calls, path: nil, symbol: nil, line: nil, direction: .incoming),
                                    error: "the old app treats an unknown kind as calls")
        try board.writeBookkeeping(id, props: .object(["graph": oldCache.json]))
        let refreshed = try board.object(id)
        #expect(refreshed.props["graph"] == oldCache.json)
        #expect(refreshed.props["knowledge"] == knowledge)
        #expect(refreshed.rev == before.rev)
        #expect(DiagramGraph.stored(in: refreshed.props) == DiagramGraph(knowledge))
        let data = try JSONEncoder().encode(board.snapshot)
        let restored = Board(snapshot: try JSONDecoder().decode(BoardSnapshot.self, from: data))
        let loaded = try restored.object(id)
        #expect(loaded.props["knowledge"] == knowledge)
        #expect(DiagramGraph.stored(in: loaded.props)?.nodes.map(\.status) == [.weak, .taught, .practiced, .retained])
        let reload = try await call(client, "reload", "object.reload", #"{"id":"\#(id)"}"#)
        #expect(reload["result"]?["loaded"] == .bool(true))
        #expect(reload["result"]?["nodes"] == .number(4))
        #expect(try board.object(id).props["knowledge"] == knowledge)
        #expect(self.computed == 0)
        let size = try await ObjectMeasure.size(type: .diagram, props: refreshed.props, width: nil, root: dir)
        #expect(size.width == 1500)
        #expect(DiagramLayout.canvasRect(of: "cold", frame: refreshed.frame, props: refreshed.props) != nil)
    }

    @Test func corruptedKnowledgeNeverFallsBackToLegacyGraph() throws {
        let graph = try #require(DiagramSpec.graph(Self.boundedGraphProps(nodes: [
            .object(["id": "a", "label": "A"]),
        ])).graph)
        let corruptions: [JSONValue] = [.null, .string("broken"), .object([:]),
                               graph.json.merging(.object(["aim": .object(["kind": "calls", "direction": "incoming"])])),
                               graph.json.merging(.object(["nodes": .array([.object(["id": "a", "name": "A", "level": -1])])]))]
        for bad in corruptions {
            let props: JSONValue = .object(["kind": "graph", "graph": graph.json, "knowledge": bad])
            #expect(DiagramGraph.stored(in: props) == nil)
            #expect(DiagramLayout.canvasRect(of: "a", frame: Frame(x: 0, y: 0, w: 760, h: 480), props: props) == nil)
        }
        #expect(DiagramGraph.stored(in: .object(["kind": "calls", "graph": graph.json])) == graph)
    }

    @Test func repositoryRerootKeepsAuthoredIDsAndBoundArrows() throws {
        let board = Board(id: "brd_graph", root: dir)
        let graph = try #require(DiagramSpec.graph(Self.boundedGraphProps(nodes: [
            .object(["id": "claim#one", "label": "A", "detail": "Keep me", "status": "weak",
                     "sources": .array([.object(["message": "m"])])]),
        ])).graph)
        let diagram = board.create(type: .diagram, props: .object(["kind": "graph", "knowledge": graph.json]))
        let arrow = board.create(type: .arrow, props: .object([
            "from": .object(["object": .string(diagram.id), "node": "claim#one"]),
            "to": .object(["x": 100, "y": 100]),
        ]))
        var rerooter = Rerooter(oldRoot: "/old/sub", top: "/old", live: true, anchor: .main, destinationRoot: dir)
        rerooter.knowledgeDiagrams = [diagram.id]
        #expect(rerooter.reroot(diagram, branch: nil).props == diagram.props)
        #expect(rerooter.reroot(arrow, branch: nil).props == arrow.props)
    }

}
