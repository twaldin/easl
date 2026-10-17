import Foundation

/// Computes a diagram tile's graph from the code and writes it back as `props.graph`
/// (bookkeeping: no rev, no undo step), for the tile (on creation, a file change, a click that
/// expands a node) and for `object.reload`. A remote board's graph is its host's to write: the
/// host computes it, or easld asks a viewer (`compute`, `DelegatedCalls`) and writes the answer.
@MainActor
public enum DiagramRefresh {
    /// The graph written, or nil when the object is gone or was re-aimed, re-expanded, or
    /// re-scoped while this ran (the refresh that change started writes instead).
    public static func run(_ id: ObjectID, on board: Board, languages: LanguageService) async throws -> DiagramGraph? {
        guard let object = board.objects[id], object.type == .diagram else { return nil }
        let graph = try await compute(object, on: board, languages: languages)
        guard let now = board.objects[id], DiagramSpec(now.props) == DiagramSpec(object.props) else { return nil }
        try board.writeBookkeeping(id, props: .object(["graph": graph.json]))
        return graph
    }

    static func compute(_ diagram: CanvasObject, on board: Board, languages: LanguageService) async throws -> DiagramGraph {
        let spec = DiagramSpec(diagram.props)
        let previous = DiagramGraph(diagram.props["graph"])
        do {
            let scope = try await scope(of: diagram, on: board, languages: languages)
            switch spec.kind {
            case .calls: return try await CallGraphBuilder.build(spec, boardRoot: board.root, scope: scope, previous: previous, languages: languages)
            }
        } catch let error as HostFileError {
            return CallGraphBuilder.failed(spec.aim, previous: previous?.aim == spec.aim ? previous : nil, reason: HostGit.refusal(error))
        }
    }

    static func scope(of diagram: CanvasObject, on board: Board, languages: LanguageService) async throws -> URL {
        let spec = DiagramSpec(diagram.props)
        let graph = DiagramGraph(diagram.props["graph"])
        let path = spec.path ?? graph?.root.flatMap { graph?.node($0)?.path }
        var agent: ObjectID?
        if case .agent(let tile) = diagram.createdBy, board.objects[tile]?.type == .terminal { agent = tile }
        guard board.isRemote else {
            if let path { return board.checkoutRoot(of: path) }
            if let checkout = board.callerCheckout(for: agent) { return URL(fileURLWithPath: checkout) }
            return board.workingRoot
        }
        if let path { return try await languages.checkoutRoot(file: board.absoluteURL(path), boardRoot: board.root) }
        if let agent { return try await languages.checkoutRoot(file: URL(fileURLWithPath: board.workingDirectory(of: agent), isDirectory: true), boardRoot: board.root) }
        return board.root
    }

    /// What a remote diagram tile polls on its host (`HostGit.stamp`): the metadata of the files
    /// its graph shows and of its `path`, in one host process. Nil without a file to watch.
    public static func hostProbe(of diagram: CanvasObject, on board: Board) -> HostGitProbe? {
        var paths = Set(DiagramGraph(diagram.props["graph"])?.nodes.map(\.path) ?? [])
        if let path = DiagramSpec(diagram.props).path { paths.insert(path) }
        guard !paths.isEmpty else { return nil }
        let files = paths.map { board.absoluteURL($0).path }.sorted()
        return HostGitProbe(boardRoot: board.root.path, spec: .object(["dir": .string(board.root.path), "files": .array(files.map(JSONValue.string))]))
    }

    /// What `object.reload` answers for a diagram: counts, not the graph (`object.get` has it).
    public static func summary(_ id: ObjectID, graph: DiagramGraph?, computed: Bool) -> JSONValue {
        var result: [String: JSONValue] = ["id": .string(id), "loaded": .bool(computed)]
        if let graph {
            result["nodes"] = .number(Double(graph.nodes.count))
            result["edges"] = .number(Double(graph.edges.count))
            result["stale"] = .array(graph.nodes.filter(\.isStale).map { .string($0.id) })
            if let root = graph.root { result["root"] = .string(root) }
            if let error = graph.error { result["error"] = .string(error) }
        }
        return .object(result)
    }
}
