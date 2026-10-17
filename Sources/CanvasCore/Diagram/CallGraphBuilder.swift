import Foundation

/// Computes a calls diagram (`DiagramKind.calls`) from the language server's call hierarchy:
/// the root function, its callers and/or callees `depth` levels out, one more level under each
/// expanded node. Only symbols in the board's files are nodes (not the SDK's, not generated
/// code). Nodes re-resolve by symbol on every build, and a node of the previous graph whose
/// symbol is gone from its file stays, stale (`DiagramGraph.merged`). Every read, search and
/// listing of the code goes through `languages`, on that service's machine: this Mac, or a
/// remote board's host.
public enum CallGraphBuilder {
    /// Past this many nodes the rest are counted (`DiagramGraph.omitted`), not drawn.
    public static let maxNodes = 60
    /// Excerpt lines a node shows.
    static let maxExcerptLines = 3
    /// A bare symbol is looked up in the projects of at most this many of the files mentioning
    /// it, in at most `maxSymbolProjects` projects.
    static let maxMentioningFiles = 40
    static let maxSymbolProjects = 3
    /// How long an empty answer for a function is asked again (a server still loading the
    /// project), every `loadingRetry`.
    static let loadingWait: Duration = .seconds(45)
    static let loadingRetry: Duration = .milliseconds(1500)

    /// Never throws but for cancellation: what went wrong is the graph's `error` (with the
    /// previous graph kept when there was one).
    /// `scope` is the checkout the graph is of (default the board root): the board root's
    /// counterpart in another worktree for a diagram there (`DiagramRefresh.scope`). Its files are
    /// the nodes and where a bare symbol is looked for; paths are written as the board stores
    /// them, relative to `boardRoot` or absolute.
    public static func build(_ spec: DiagramSpec, boardRoot: URL, scope: URL? = nil, previous: DiagramGraph?, languages: LanguageService) async throws -> DiagramGraph {
        let aim = spec.aim
        let previous = previous?.aim == aim ? previous : nil
        var session = Session(boardRoot: boardRoot, scope: scope, languages: languages)
        do {
            let root = try await session.resolveRoot(spec, previous: previous)
            let fresh = try await session.walk(from: root, spec: spec)
            var vanished: Set<String> = []
            for node in previous?.nodes ?? [] where fresh.node(node.id) == nil {
                if try await session.isGone(node) { vanished.insert(node.id) }
            }
            return DiagramGraph.merged(fresh: fresh, previous: previous, vanished: vanished)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as Failure {
            if case .rootGone(let reason) = failure, let previous { return DiagramGraph.stalled(previous, reason: reason) }
            return failed(aim, previous: previous, reason: failure.message)
        } catch let error as HostFileError where languages.hostName != nil {
            return failed(aim, previous: previous, reason: HostGit.refusal(error))
        } catch {
            return failed(aim, previous: previous, reason: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// The previous graph (unchanged but for the reason) when there is one, so a server that is
    /// down or restarting doesn't blank the diagram.
    static func failed(_ aim: DiagramAim, previous: DiagramGraph?, reason: String) -> DiagramGraph {
        guard var graph = previous else { return DiagramGraph(aim: aim, error: reason) }
        graph.error = reason
        graph.computedAt = DiagramGraph.now()
        return graph
    }

    enum Failure: Error {
        /// The root's symbol is no longer declared where it was.
        case rootGone(String)
        case unresolved(String)

        var message: String {
            switch self {
            case .rootGone(let reason), .unresolved(let reason): reason
            }
        }
    }

    // MARK: Names

    /// `Container.name(labels:)` split at its last dot outside parentheses, as sourcekit-lsp
    /// names call hierarchy items; other servers name the bare function and may put the
    /// container in `detail`.
    static func split(_ item: LSPCallHierarchyItem) -> (container: String?, name: String) {
        let (container, name) = split(item.name)
        if container == nil, let detail = item.detail, detail.allSatisfy({ $0.isLetter || $0.isNumber || "_.$".contains($0) }) {
            return (detail, name)
        }
        return (container, name)
    }

    static func split(_ qualified: String) -> (container: String?, name: String) {
        var depth = 0
        var lastDot: String.Index?
        for index in qualified.indices {
            switch qualified[index] {
            case "(", "<", "[": depth += 1
            case ")", ">", "]": depth -= 1
            case "." where depth == 0: lastDot = index
            default: break
            }
        }
        guard let lastDot, lastDot != qualified.startIndex else { return (nil, qualified) }
        return (String(qualified[..<lastDot]), String(qualified[qualified.index(after: lastDot)...]))
    }

    /// A name as written by a person or a document symbol: `read` for `read(from:tiles:)`,
    /// `file` for sourcekit-lsp's accessor `getter:file`.
    static func baseName(_ name: String) -> String {
        var name = Substring(name)
        for prefix in ["getter:", "setter:", "_modify:", "modify:", "didSet:", "willSet:"] where name.hasPrefix(prefix) { name = name.dropFirst(prefix.count) }
        return String(name.prefix { $0 != "(" && $0 != "<" })
    }

    /// Whether `wanted` (`read`, `read(from:tiles:)`) names the symbol `name`.
    static func names(_ wanted: String, _ name: String) -> Bool {
        wanted == name || (!wanted.contains("(") && baseName(wanted) == baseName(name))
    }

    /// Compiler-made callers (Swift Testing's `$s…` thunks) and the like.
    static func isGenerated(_ name: String) -> Bool { name.hasPrefix("$") || name.hasPrefix("__") }

    static let callableKinds: Set<Int> = [6, 9, 12]

    // MARK: One build

    struct Session {
        let boardRoot: URL
        /// The checkout searched and drawn (`build`'s `scope`).
        let scope: URL
        let languages: LanguageService
        private var symbols: [URL: [(symbol: LSPSymbol, containers: [String])]] = [:]
        private var texts: [URL: [String]?] = [:]
        /// Lines each node's declaration moved since the server's index saw it (sourcekit-lsp
        /// places call hierarchy items and calls where the last build found them): what the
        /// node's calls shift by too.
        private var shifts: [String: Int] = [:]

        init(boardRoot: URL, scope: URL? = nil, languages: LanguageService) {
            self.boardRoot = boardRoot
            self.scope = scope ?? boardRoot
            self.languages = languages
        }

        func url(_ path: String) -> URL {
            URL(fileURLWithPath: path.hasPrefix("/") ? path : boardRoot.appendingPathComponent(path, isDirectory: false).path, isDirectory: false).standardizedFileURL
        }

        func boardPath(_ url: URL) -> String { languages.relativePath(url.path, boardRoot: boardRoot) }

        /// Whether `url` is one of the files the graph is of (in `scope`).
        func inScope(_ url: URL) -> Bool { !languages.relativePath(url.path, boardRoot: scope).hasPrefix("/") }

        /// Every symbol of `file` with the names of the symbols it is inside, outermost first.
        mutating func documentSymbols(_ file: URL) async throws -> [(symbol: LSPSymbol, containers: [String])] {
            if let known = symbols[file] { return known }
            func walk(_ list: [LSPSymbol], _ containers: [String]) -> [(symbol: LSPSymbol, containers: [String])] {
                list.flatMap { [($0, containers)] + walk($0.children, containers + [$0.name]) }
            }
            let found = walk(try await languages.documentSymbols(file: file, boardRoot: scope), [])
            symbols[file] = found
            return found
        }

        mutating func source(_ file: URL) async throws -> [String]? {
            if let known = texts[file] { return known }
            let read: [String]?
            do {
                let text = try await languages.text(file: file, boardRoot: scope)
                read = await offPool { NoteSource.lines(of: text) }
            } catch HostFileError.notFound(_) {
                read = nil
            }
            texts[file] = read
            return read
        }

        mutating func lines(_ file: URL) async -> [String] {
            (try? await source(file)) ?? []
        }

        /// The symbol `qualified` (`Type.member`, a bare name, labels optional) declares in
        /// `file`, callables first, in source order.
        mutating func declaration(_ qualified: String, in file: URL) async throws -> LSPSymbol? {
            let (container, name) = CallGraphBuilder.split(qualified)
            let wantedContainers = container.map(Self.containerNames) ?? []
            let matches = try await documentSymbols(file).filter { entry in
                names(name, entry.symbol.name) && entry.containers.map(baseName).reversed().starts(with: wantedContainers.map(baseName).reversed())
            }.map(\.symbol)
            return matches.first { callableKinds.contains($0.kind) } ?? matches.first
        }

        /// Where `item` is declared in its file's current text: the document symbol at its
        /// position, else the one of its name nearest to it (code moved since the index).
        mutating func currentDeclaration(of item: LSPCallHierarchyItem) async -> LSPSymbol? {
            guard let symbols = try? await documentSymbols(item.url) else { return nil }
            let start = item.selectionRange.start
            if let exact = symbols.first(where: { $0.symbol.selectionRange.start == start }) { return exact.symbol }
            let (container, name) = CallGraphBuilder.split(item)
            let wantedContainers = container.map(Self.containerNames) ?? []
            return symbols.filter { entry in
                names(name, entry.symbol.name) && entry.containers.map(baseName).reversed().starts(with: wantedContainers.map(baseName).reversed())
            }.map(\.symbol).min { abs($0.selectionRange.start.line - start.line) < abs($1.selectionRange.start.line - start.line) }
        }

        /// `A.B.C` as `["A", "B", "C"]`, dots inside parentheses kept.
        static func containerNames(_ containerPath: String) -> [String] {
            var parts: [String] = []
            var rest = containerPath
            while true {
                let (container, name) = CallGraphBuilder.split(rest)
                parts.insert(name, at: 0)
                guard let container else { return parts }
                rest = container
            }
        }

        // MARK: Finding a bare symbol

        mutating func locate(_ symbol: String) async throws -> String {
            if let found = try await languages.locate(symbol: symbol, boardRoot: boardRoot, scope: scope).map({ boardPath(scope.appendingPathComponent($0)) }),
               try await declaration(symbol, in: url(found)) != nil {
                return found
            }
            return try await locateInWorkspace(symbol)
        }

        mutating func locateInWorkspace(_ symbol: String) async throws -> String {
            let (container, name) = CallGraphBuilder.split(symbol)
            let base = baseName(name)
            guard !base.isEmpty, base.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) else {
                throw Failure.unresolved("\(symbol) is not a symbol name; give props.path")
            }
            let mentioning = try await languages.mentioningFiles(base, boardRoot: boardRoot, scope: scope, limit: CallGraphBuilder.maxMentioningFiles)
            let projects = try await languages.projects(mentioning.map { scope.appendingPathComponent($0) }, boardRoot: scope).prefix(CallGraphBuilder.maxSymbolProjects)
            guard !projects.isEmpty else { throw Failure.unresolved("no file of the board that a language server reads mentions \(base); give props.path") }
            let wanted = container.map(Self.containerNames) ?? []
            /// The answers that are declarations of `symbol` in the board's files, once each.
            func declarations() async throws -> [(path: String, symbol: LSPSymbol, containers: [String])] {
                var found: [(path: String, symbol: LSPSymbol, containers: [String])] = []
                for answer in try await languages.workspaceSymbols(base, files: Array(projects), boardRoot: scope) where names(name, answer.name) {
                    guard inScope(answer.location.url) else { continue }
                    let path = boardPath(answer.location.url)
                    let line = answer.location.range.start.line
                    let declared = (try? await documentSymbols(answer.location.url)) ?? []
                    guard let entry = declared.first(where: { entry in
                        names(name, entry.symbol.name) && (entry.symbol.selectionRange.start.line == line || entry.symbol.range.start.line == line)
                    }), entry.containers.map(baseName).reversed().starts(with: wanted.map(baseName).reversed()) else { continue }
                    guard !found.contains(where: { $0.path == path && $0.symbol.selectionRange.start == entry.symbol.selectionRange.start }) else { continue }
                    found.append((path, entry.symbol, entry.containers))
                }
                return found
            }
            // A server still reading the project answers with part of it (tsserver, just
            // started: the opened file's declarations only), so an answer counts once the next
            // one, `loadingRetry` later, finds the same declarations.
            var found = try await declarations()
            var waited = Duration.zero
            while waited < CallGraphBuilder.loadingWait {
                try await Task.sleep(for: CallGraphBuilder.loadingRetry)
                waited += CallGraphBuilder.loadingRetry
                let again = try await declarations()
                let same = again.map(\.path) == found.map(\.path) && again.map(\.symbol.selectionRange.start) == found.map(\.symbol.selectionRange.start)
                found = again
                if same, !found.isEmpty { break }
            }
            let callables = found.filter { callableKinds.contains($0.symbol.kind) }
            if !callables.isEmpty { found = callables }
            guard found.count <= 1 else {
                let listed = found.prefix(8).map { "\($0.path):\($0.symbol.selectionRange.start.line + 1) (\(($0.containers + [$0.symbol.name]).joined(separator: ".")))" }
                throw Failure.unresolved("\(symbol) is declared \(found.count) times; give props.path or a Container.member symbol: \(listed.joined(separator: ", "))")
            }
            guard let only = found.first else {
                throw Failure.unresolved("the language server knows no \(symbol) in the board's files; give props.path")
            }
            return only.path
        }

        // MARK: Root

        mutating func resolveRoot(_ spec: DiagramSpec, previous: DiagramGraph?) async throws -> LSPCallHierarchyItem {
            let path: String
            if let given = spec.path {
                path = given
            } else if let root = previous?.root.flatMap({ previous?.node($0) }) {
                // Found before: the root is re-found in its file below.
                path = root.path
            } else if let symbol = spec.symbol {
                path = try await locate(symbol)
            } else {
                throw Failure.unresolved("a calls diagram needs props.symbol or props.path")
            }
            let file = url(path)
            guard try await source(file) != nil else {
                if previous != nil { throw Failure.rootGone("\(path) is gone") }
                throw Failure.unresolved("no file \(path)")
            }
            var rootFile = file
            let declared: LSPSymbol
            if let rootID = previous?.root, let root = previous?.node(rootID) {
                // Where the symbol the diagram was of is now, however the code around it moved.
                rootFile = url(root.path)
                guard let symbol = try await declaration(root.qualifiedName, in: rootFile) else {
                    throw Failure.rootGone("\(root.qualifiedName) is no longer declared in \(root.path)")
                }
                declared = symbol
            } else if let wanted = spec.symbol {
                guard let symbol = try await declaration(wanted, in: file) else { throw Failure.unresolved("\(path) declares no \(wanted)") }
                declared = symbol
            } else {
                let line = (spec.line ?? 1) - 1
                let all = try await documentSymbols(file).map(\.symbol)
                if let named = all.first(where: { $0.selectionRange.start.line == line }) {
                    declared = named
                } else if let enclosing = all.filter({ callableKinds.contains($0.kind) && $0.range.start.line <= line && line <= $0.range.end.line })
                    .min(by: { $0.range.end.line - $0.range.start.line < $1.range.end.line - $1.range.start.line }) {
                    declared = enclosing
                } else {
                    throw Failure.unresolved("no function is declared at \(path):\(line + 1)")
                }
            }
            let position = declared.selectionRange.start
            var items = try await languages.prepareCallHierarchy(file: rootFile, boardRoot: scope, at: position)
            // A function the server names nothing at: it is still loading the project (sourcekit-lsp
            // answers from fallback settings until its package is loaded), so ask again a while.
            var waited = Duration.zero
            while items.isEmpty, callableKinds.contains(declared.kind), waited < CallGraphBuilder.loadingWait {
                try await Task.sleep(for: CallGraphBuilder.loadingRetry)
                waited += CallGraphBuilder.loadingRetry
                items = try await languages.prepareCallHierarchy(file: rootFile, boardRoot: scope, at: position)
            }
            guard let item = items.first else {
                let hint = await languages.existingServer(for: rootFile, boardRoot: scope)?.config.emptyResultHint.map { " \($0)" } ?? ""
                throw Failure.unresolved("the language server names no callable at \(boardPath(rootFile)):\(position.line + 1).\(hint)")
            }
            return item
        }

        // MARK: Walk

        private struct Pending {
            var item: LSPCallHierarchyItem
            var id: String
            var level: Int
            var direction: CallDirection
            var remaining: Int
        }

        mutating func walk(from rootItem: LSPCallHierarchyItem, spec: DiagramSpec) async throws -> DiagramGraph {
            var graph = DiagramGraph(aim: spec.aim)
            var ids: [String: String] = [:]
            var edges: [String: Int] = [:]
            var omitted = 0
            let expanded = Set(spec.expanded)

            func identity(_ item: LSPCallHierarchyItem, path: String) -> String {
                let (container, name) = CallGraphBuilder.split(item)
                let base = "\(path)#\(container.map { "\($0)." } ?? "")\(name)"
                let exact = "\(base)@\(item.selectionRange.start.line + 1)"
                if let known = ids[exact] { return known }
                let id = ids.values.contains(base) ? exact : base
                ids[exact] = id
                return id
            }

            let rootPath = boardPath(rootItem.url)
            let rootID = identity(rootItem, path: rootPath)
            graph.root = rootID
            graph.nodes.append(try await makeNode(rootItem, id: rootID, path: rootPath, level: 0, calls: nil))
            var queue: [Pending] = []
            if spec.direction.includesIncoming { queue.append(Pending(item: rootItem, id: rootID, level: 0, direction: .incoming, remaining: spec.depth)) }
            if spec.direction.includesOutgoing { queue.append(Pending(item: rootItem, id: rootID, level: 0, direction: .outgoing, remaining: spec.depth)) }

            while !queue.isEmpty {
                try Task.checkCancellation()
                let current = queue.removeFirst()
                let incoming = current.direction == .incoming
                let calls = incoming ? try await languages.incomingCalls(current.item, boardRoot: scope)
                                     : try await languages.outgoingCalls(current.item, boardRoot: scope)
                var found: [(item: LSPCallHierarchyItem, path: String, lines: [Int])] = []
                for call in calls {
                    guard inScope(call.item.url), !isGenerated(CallGraphBuilder.split(call.item).name) else { continue }
                    let path = boardPath(call.item.url)
                    let lines = Array(Set(call.fromRanges.map { $0.start.line + 1 })).sorted()
                    if let index = found.firstIndex(where: { $0.item.url == call.item.url && $0.item.selectionRange.start == call.item.selectionRange.start && $0.item.name == call.item.name }) {
                        found[index].lines = Array(Set(found[index].lines + lines)).sorted()
                    } else {
                        found.append((call.item, path, lines))
                    }
                }
                found.sort { ($0.path, $0.item.selectionRange.start.line) < ($1.path, $1.item.selectionRange.start.line) }
                for (item, path, lines) in found {
                    let id = identity(item, path: path)
                    guard id != current.id else { continue }
                    if graph.node(id) == nil {
                        guard graph.nodes.count < CallGraphBuilder.maxNodes else {
                            omitted += 1
                            continue
                        }
                        let level = current.level + (incoming ? -1 : 1)
                        var node = try await makeNode(item, id: id, path: path, level: level, calls: incoming ? lines : nil)
                        if current.remaining > 1 {
                            queue.append(Pending(item: item, id: id, level: level, direction: current.direction, remaining: current.remaining - 1))
                        } else if expanded.contains(id) {
                            node.expanded = true
                            queue.append(Pending(item: item, id: id, level: level, direction: current.direction, remaining: 1))
                        } else {
                            node.expandable = true
                        }
                        graph.nodes.append(node)
                    }
                    let (from, to) = incoming ? (id, current.id) : (current.id, id)
                    let lines = lines.map { $0 + (shifts[from] ?? 0) }
                    if let index = edges["\(from)\n\(to)"] {
                        graph.edges[index].lines = Array(Set(graph.edges[index].lines + lines)).sorted()
                    } else {
                        edges["\(from)\n\(to)"] = graph.edges.count
                        graph.edges.append(DiagramEdge(from: from, to: to, lines: lines))
                    }
                }
            }
            graph.omitted = omitted > 0 ? omitted : nil
            return graph
        }

        /// A node for `item`: its declaration's lines from the file's document symbols, and as
        /// excerpt the lines of `calls` (a caller's calls toward the root) or its signature.
        private mutating func makeNode(_ item: LSPCallHierarchyItem, id: String, path: String, level: Int, calls: [Int]?) async throws -> DiagramNode {
            let (container, name) = CallGraphBuilder.split(item)
            let declared = await currentDeclaration(of: item)
            let start = declared?.selectionRange.start ?? item.selectionRange.start
            let shift = start.line - item.selectionRange.start.line
            shifts[id] = shift
            let calls = calls?.map { $0 + shift }
            let lines = declared?.range.lines ?? item.range.lines
            let source = await self.lines(item.url)
            func text(_ line: Int) -> String? { source.indices.contains(line - 1) ? source[line - 1].trimmingCharacters(in: .whitespaces) : nil }
            var excerpt: [DiagramExcerptLine] = []
            if let calls {
                excerpt = calls.prefix(CallGraphBuilder.maxExcerptLines).compactMap { line in text(line).map { DiagramExcerptLine(line: line, text: $0) } }
            } else {
                // The signature: from the name's line to the one opening the body.
                for line in (start.line + 1)...(start.line + CallGraphBuilder.maxExcerptLines) {
                    guard var shown = text(line) else { break }
                    let opens = shown.hasSuffix("{") || shown.hasSuffix(":") || shown.hasSuffix("=>")
                    if shown.hasSuffix("{") { shown = String(shown.dropLast()).trimmingCharacters(in: .whitespaces) }
                    if !shown.isEmpty { excerpt.append(DiagramExcerptLine(line: line, text: shown)) }
                    if opens || line >= lines.end { break }
                }
            }
            return DiagramNode(id: id, name: name, container: container, kind: LSPSymbol.kindName(item.kind), path: path, line: start.line + 1,
                               lines: lines, excerpt: excerpt, level: level)
        }

        // MARK: Freshness

        /// Whether `node`'s symbol is no longer declared in its file (or the file is gone).
        mutating func isGone(_ node: DiagramNode) async throws -> Bool {
            let file = url(node.path)
            guard try await source(file) != nil else { return true }
            return try await declaration(node.qualifiedName, in: file) == nil
        }
    }
}
