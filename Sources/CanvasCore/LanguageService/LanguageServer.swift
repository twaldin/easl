import Darwin
import Foundation

/// One language server for a (language, project root): started on the first request, restarted
/// on the next request after a crash. It runs where its service's `LanguageSource` says: this
/// Mac, or a host over ssh.
///
/// Documents are client-owned only while needed: for the duration of a request, or while a
/// code view pins them (`pin`/`unpin`). Every request first re-syncs each open document whose
/// file changed, so the server never answers from stale client-supplied text. Those reads take
/// turns, so an older read never lands after a newer one.
public actor LanguageServer {
    public nonisolated let config: LanguageServerConfig
    public nonisolated let root: URL
    private let binary: ServerBinary
    private let source: any LanguageSource
    private let live: LiveConnections

    /// The initialized process.
    private var connection: LSPConnection?
    /// The process between spawn and a successful initialize; `stop()` must reach it too.
    private var launching: LSPConnection?
    private var starting: Task<LSPConnection, Error>?
    /// Bumped per launch and on stop: a launch or exit from an older generation is discarded.
    private var generation = 0
    private var documents: [URL: Document] = [:]
    private var pinned: Set<URL>
    private var inFlight = 0
    private var syncQueue: [CheckedContinuation<Void, Never>]?
    /// What the running server said it can answer (`initialize` result `capabilities`).
    private var capabilities: JSONValue = .object([:])
    public private(set) var status: LanguageServerStatus = .stopped

    static let requestTimeout: Duration = .seconds(60)

    private struct Document {
        var version: Int
        var stamp: DocumentStamp
        var hash: Int
        /// Requests currently relying on the document being open.
        var users: Int
        var boardRoot: URL
    }

    private struct DocumentUse {
        let file: URL
        let connection: LSPConnection
    }

    init(config: LanguageServerConfig, root: URL, binary: ServerBinary, source: any LanguageSource, live: LiveConnections, pinned: Set<URL> = []) {
        self.config = config
        self.root = root
        self.binary = binary
        self.source = source
        self.live = live
        self.pinned = pinned
    }

    var isBusy: Bool { inFlight > 0 || starting != nil }

    /// The server process on the machine it runs on, while starting or running; a host's server
    /// is named by its pid there, never by the ssh process here.
    public var pid: Int32? { (connection ?? launching)?.serverPID }

    /// Documents the server currently holds as client-owned.
    public var openDocumentCount: Int { documents.count }

    /// Background work the server reports (e.g. "Indexing"), which explains empty answers.
    public var activity: [String] { connection?.activity ?? [] }


    public func hover(_ file: URL, boardRoot: URL, at position: LSPPosition) async throws -> LSPHover? {
        let result = try await request("textDocument/hover", file, boardRoot) { uri in
            .object(["textDocument": .object(["uri": .string(uri)]), "position": position.json])
        }
        return LSPHover(result)
    }

    public func definition(_ file: URL, boardRoot: URL, at position: LSPPosition) async throws -> [LSPLocation] {
        LSPLocation.list(try await request("textDocument/definition", file, boardRoot) { uri in
            .object(["textDocument": .object(["uri": .string(uri)]), "position": position.json])
        })
    }

    /// References including the declaration.
    public func references(_ file: URL, boardRoot: URL, at position: LSPPosition) async throws -> [LSPLocation] {
        LSPLocation.list(try await request("textDocument/references", file, boardRoot) { uri in
            .object(["textDocument": .object(["uri": .string(uri)]), "position": position.json,
                     "context": .object(["includeDeclaration": .bool(true)])])
        })
    }

    /// Where the type of the value at `position` is declared.
    public func typeDefinition(_ file: URL, boardRoot: URL, at position: LSPPosition) async throws -> [LSPLocation] {
        try await require("typeDefinitionProvider", "type definitions")
        return LSPLocation.list(try await request("textDocument/typeDefinition", file, boardRoot) { uri in
            .object(["textDocument": .object(["uri": .string(uri)]), "position": position.json])
        })
    }

    /// The callable declared at `position` (its name), as the server's call hierarchy knows it:
    /// empty when nothing callable is there.
    public func prepareCallHierarchy(_ file: URL, boardRoot: URL, at position: LSPPosition) async throws -> [LSPCallHierarchyItem] {
        try await require("callHierarchyProvider", "call hierarchy")
        let result = try await request("textDocument/prepareCallHierarchy", file, boardRoot) { uri in
            .object(["textDocument": .object(["uri": .string(uri)]), "position": position.json])
        }
        return (result.array ?? []).compactMap(LSPCallHierarchyItem.init)
    }

    /// What calls `item`, each caller with the ranges of its calls (in the caller's file).
    public func incomingCalls(_ item: LSPCallHierarchyItem, boardRoot: URL) async throws -> [LSPCallHierarchyCall] {
        try await require("callHierarchyProvider", "call hierarchy")
        let result = try await request("callHierarchy/incomingCalls", item.url, boardRoot) { _ in .object(["item": item.json]) }
        return (result.array ?? []).compactMap { LSPCallHierarchyCall($0, end: "from") }
    }

    /// What `item` calls, each callee with the ranges of the calls (in `item`'s file).
    public func outgoingCalls(_ item: LSPCallHierarchyItem, boardRoot: URL) async throws -> [LSPCallHierarchyCall] {
        try await require("callHierarchyProvider", "call hierarchy")
        let result = try await request("callHierarchy/outgoingCalls", item.url, boardRoot) { _ in .object(["item": item.json]) }
        return (result.array ?? []).compactMap { LSPCallHierarchyCall($0, end: "to") }
    }

    /// Starts the server if needed and throws `unsupportedRequest` unless its capabilities list
    /// `provider` (present and not false).
    private func require(_ provider: String, _ what: String) async throws {
        _ = try await connected()
        switch capabilities[provider] {
        case nil, .null?, .bool(false)?: throw LSPError.unsupportedRequest("\(config.command) does not answer \(what) requests (no \(provider) in its capabilities)")
        default: return
        }
    }

    public func documentSymbols(_ file: URL, boardRoot: URL) async throws -> [LSPSymbol] {
        let result = try await request("textDocument/documentSymbol", file, boardRoot) { uri in
            .object(["textDocument": .object(["uri": .string(uri)])])
        }
        return (result.array ?? []).compactMap(LSPSymbol.init)
    }

    /// Symbols matching `query` anywhere in the server's project (`workspace/symbol`).
    /// `file`, one of the project's, is open for the request: tsserver answers only for the
    /// projects of open files ("No Project" otherwise).
    public func workspaceSymbols(_ query: String, opening file: URL, boardRoot: URL) async throws -> [LSPWorkspaceSymbol] {
        let result = try await request("workspace/symbol", file, boardRoot) { _ in .object(["query": .string(query)]) }
        return (result.array ?? []).compactMap(LSPWorkspaceSymbol.init)
    }

    private func request(_ method: String, _ file: URL, _ boardRoot: URL, _ params: (String) -> JSONValue) async throws -> JSONValue {
        inFlight += 1
        defer { inFlight -= 1 }
        let connection = try await connected()
        let use = try await open(file, boardRoot: boardRoot, on: connection)
        defer { release(use) }
        return try await connection.request(method, params(file.absoluteString), timeout: Self.requestTimeout)
    }

    // MARK: Documents

    /// Keeps `file` open between requests (a code view shows it).
    func pin(_ file: URL) {
        pinned.insert(file)
    }

    func unpin(_ file: URL) {
        pinned.remove(file)
        if let connection, documents[file]?.users == 0 { close(file, on: connection) }
    }

    private func open(_ file: URL, boardRoot: URL, on connection: LSPConnection) async throws -> DocumentUse {
        await takeSyncTurn()
        defer { passSyncTurn() }
        guard connection === self.connection else { throw LSPError.serverExited("\(config.command) restarted") }
        let claimed = documents[file] == nil ? nil : DocumentUse(file: file, connection: connection)
        if claimed != nil { documents[file]?.users += 1 }
        var wanted = documents.map { DocumentRequest(file: $0.key, boardRoot: $0.value.boardRoot, stamp: $0.value.stamp) }
        if claimed == nil { wanted.append(DocumentRequest(file: file, boardRoot: boardRoot, stamp: nil)) }
        let read: [URL: DocumentRead]
        do {
            read = try await source.documents(wanted)
        } catch {
            if let claimed { release(claimed) }
            throw error
        }
        guard connection === self.connection else { throw LSPError.serverExited("\(config.command) restarted") }
        for (other, result) in read where other != file { apply(result, to: other, on: connection) }
        if let claimed {
            if case .unreadable(let why)? = read[file] {
                documents[file]?.users -= 1
                apply(.unreadable(why), to: file, on: connection)
                throw LSPError.unreadable(why)
            }
            if let result = read[file] { apply(result, to: file, on: connection) }
            return claimed
        }
        switch read[file] {
        case .text(let stamp, let text)?:
            connection.notify("textDocument/didOpen", .object([
                "textDocument": .object(["uri": .string(file.absoluteString), "languageId": .string(config.languageID(for: file) ?? config.language),
                                         "version": .number(1), "text": .string(text)]),
            ]))
            documents[file] = Document(version: 1, stamp: stamp, hash: text.hashValue, users: 1, boardRoot: boardRoot)
            return DocumentUse(file: file, connection: connection)
        case .unreadable(let why)?:
            throw LSPError.unreadable(why)
        case .unchanged?, nil:
            throw LSPError.unreadable(file.path)
        }
    }

    private func takeSyncTurn() async {
        guard syncQueue != nil else {
            syncQueue = []
            return
        }
        await withCheckedContinuation { syncQueue?.append($0) }
    }

    private func passSyncTurn() {
        guard let next = syncQueue?.first else {
            syncQueue = nil
            return
        }
        syncQueue?.removeFirst()
        next.resume()
    }

    private func apply(_ read: DocumentRead, to file: URL, on connection: LSPConnection) {
        guard let document = documents[file] else { return }
        switch read {
        case .unchanged:
            return
        case .unreadable:
            if document.users == 0 { close(file, on: connection) }
        case .text(let stamp, let text):
            documents[file]?.stamp = stamp
            let hash = text.hashValue
            guard hash != document.hash else { return }
            let version = document.version + 1
            connection.notify("textDocument/didChange", .object([
                "textDocument": .object(["uri": .string(file.absoluteString), "version": .number(Double(version))]),
                "contentChanges": .array([.object(["text": .string(text)])]),
            ]))
            documents[file]?.version = version
            documents[file]?.hash = hash
        }
    }

    private func release(_ use: DocumentUse) {
        guard use.connection === connection, documents[use.file] != nil else { return }
        documents[use.file]?.users -= 1
        if documents[use.file]?.users == 0, !pinned.contains(use.file) { close(use.file, on: use.connection) }
    }

    private func close(_ file: URL, on connection: LSPConnection) {
        guard documents.removeValue(forKey: file) != nil else { return }
        connection.notify("textDocument/didClose", .object(["textDocument": .object(["uri": .string(file.absoluteString)])]))
    }

    // MARK: Lifecycle

    private func connected() async throws -> LSPConnection {
        if let connection { return connection }
        if let starting { return try await starting.value }
        status = .starting
        let task = Task { try await self.launch() }
        starting = task
        defer { starting = nil }
        do {
            return try await task.value
        } catch {
            // A stop while starting already set .stopped; anything else is a failed start.
            if status == .starting { status = .crashed((error as? LocalizedError)?.errorDescription ?? "\(error)") }
            throw error
        }
    }

    private func launch() async throws -> LSPConnection {
        generation += 1
        let launched = generation
        let launch = try await source.launch(binary, config: config, project: root)
        guard launched == generation else { throw LSPError.serverExited("\(config.command) was stopped while starting") }
        let connection = LSPConnection(launch) { [weak self] connection, reason in
            Task { await self?.exited(connection, generation: launched, reason: reason) }
        }
        do {
            try connection.start()
        } catch {
            throw LSPError.startFailed("\(binary.path)\(source.hostName.map { " on \($0)" } ?? ""): \(error.localizedDescription)")
        }
        live.insert(connection, binary: binary)
        launching = connection
        defer { if launching === connection { launching = nil } }
        let initialized: JSONValue
        do {
            initialized = try await connection.request("initialize", initializeParams, timeout: Self.requestTimeout)
        } catch {
            connection.kill()
            if launched == generation { await reapOnHost(connection) }
            live.remove(connection)
            throw error
        }
        // stop() ran during initialize and already terminated this process; never publish it.
        guard launched == generation else {
            live.remove(connection)
            connection.kill()
            throw LSPError.serverExited("\(config.command) was stopped while starting")
        }
        guard let pid = connection.serverPID else {
            connection.kill()
            live.remove(connection)
            throw LSPError.startFailed("\(launch.name) didn't say its pid")
        }
        connection.notify("initialized", .object([:]))
        documents = [:]
        capabilities = initialized["capabilities"] ?? .object([:])
        self.connection = connection
        status = .running(pid: pid)
        return connection
    }

    private func exited(_ exited: LSPConnection, generation launched: Int, reason: String) async {
        guard launched == generation, exited === connection else {
            live.remove(exited)
            return
        }
        connection = nil
        documents = [:]
        status = .crashed(reason)
        // ssh can end without its server (the master gone): that one is ended too.
        await reapOnHost(exited)
        live.remove(exited)
    }

    private func reapOnHost(_ connection: LSPConnection) async {
        guard connection.launch.remote, let pid = connection.serverPID else { return }
        await source.reap(pid, binary: binary)
    }

    /// LSP shutdown/exit for a running server, SIGTERM for one still starting, escalating to
    /// SIGKILL for either that won't leave; then, for a host's, its host ends it if it outlived
    /// its ssh.
    public func stop() async {
        generation += 1
        status = .stopped
        let running = connection
        let starting = launching
        connection = nil
        launching = nil
        documents = [:]
        if let starting {
            await starting.terminate(grace: .seconds(1))
            await reapOnHost(starting)
            live.remove(starting)
        }
        if let running {
            _ = try? await running.request("shutdown", .null, timeout: .seconds(2))
            running.notify("exit", nil)
            if await !running.waitForExit(timeout: .seconds(2)) { await running.terminate(grace: .seconds(2)) }
            await reapOnHost(running)
            live.remove(running)
        }
    }

    /// A host's server gets no `processId`: this app's pid means nothing there.
    private var initializeParams: JSONValue {
        let rootURI = JSONValue.string(root.absoluteString)
        var params: [String: JSONValue] = [
            "processId": source.hostName == nil ? .number(Double(getpid())) : .null,
            "clientInfo": .object(["name": .string("easl")]),
            "rootUri": rootURI,
            "rootPath": .string(root.path),
            "workspaceFolders": .array([.object(["uri": rootURI, "name": .string(root.lastPathComponent)])]),
            "capabilities": .object([
                "general": .object(["positionEncodings": .array([.string("utf-16")])]),
                "window": .object(["workDoneProgress": .bool(true)]),
                "workspace": .object(["configuration": .bool(true), "workspaceFolders": .bool(true), "symbol": .object([:])]),
                "textDocument": .object([
                    "synchronization": .object(["dynamicRegistration": .bool(false), "didSave": .bool(false)]),
                    "hover": .object(["contentFormat": .array([.string("markdown"), .string("plaintext")])]),
                    "definition": .object(["linkSupport": .bool(true)]),
                    "references": .object([:]),
                    "documentSymbol": .object(["hierarchicalDocumentSymbolSupport": .bool(true)]),
                    "typeDefinition": .object(["linkSupport": .bool(true)]),
                    "callHierarchy": .object(["dynamicRegistration": .bool(false)]),
                ]),
            ]),
        ]
        if let options = config.initializationOptions { params["initializationOptions"] = options }
        return .object(params)
    }
}

/// Every server process that has been spawned and not yet reaped, reachable without the actors
/// so app quit can end them.
final class LiveConnections: @unchecked Sendable {
    private let source: any LanguageSource
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: (connection: LSPConnection, binary: ServerBinary)] = [:]

    init(source: any LanguageSource) {
        self.source = source
    }

    var count: Int { lock.withLock { connections.count } }

    func insert(_ connection: LSPConnection, binary: ServerBinary) {
        lock.withLock { connections[ObjectIdentifier(connection)] = (connection, binary) }
    }

    func remove(_ connection: LSPConnection) {
        lock.withLock { _ = connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    func terminateAll(grace: Duration) async {
        let all = lock.withLock { Array(connections.values) }
        await withTaskGroup(of: Void.self) { group in
            for (connection, binary) in all {
                group.addTask {
                    connection.notify("exit", nil)
                    if connection.launch.remote {
                        if await !connection.waitForExit(timeout: grace) { await connection.terminate(grace: .seconds(1)) }
                        if let pid = connection.serverPID { await self.source.reap(pid, binary: binary) }
                    } else {
                        await connection.terminate(grace: grace)
                    }
                    self.remove(connection)
                }
            }
        }
    }
}
