import Foundation

/// The language servers of one machine: one per (language, project root), shared by every tile.
/// Servers start on their first request, shut down after `idleTimeout` without requests, and at
/// most `maxRunning` exist at once (the least recently used one is stopped to make room).
///
/// The machine is fixed when the service is made: this Mac, or a host (`init(host:)`), where its
/// servers run and every file it reads, lists or searches is read, under the host's board policy.
/// URLs name files on that machine; a host's never reach this Mac's filesystem.
public actor LanguageService {
    struct Key: Hashable {
        let language: String
        let root: URL
    }

    private struct Retainer: Hashable {
        let file: URL
        let boardRoot: URL
    }

    private struct Pin: Hashable {
        let key: Key
        let file: URL
    }

    private struct Retention {
        var count: Int
        var pin: Pin?
    }

    /// Files a listing gives at most: past this, a monorepo's generated trees are left out.
    public static let maxListedFiles = 200_000

    /// The host the servers run on; nil for this Mac.
    public nonisolated let hostName: String?

    private let source: any LanguageSource
    private let idleTimeout: Duration
    private let maxRunning: Int
    private let live: LiveConnections

    private var servers: [Key: LanguageServer] = [:]
    private var lastUse: [Key: Int] = [:]
    private var uses = 0
    private var idleTimers: [Key: (token: Int, task: Task<Void, Never>)] = [:]
    /// Files code views show, with how many views retain each (see `retain`).
    private var retained: [Retainer: Retention] = [:]

    /// This Mac's servers, found through the login shell.
    public init(configs: [LanguageServerConfig] = LanguageServerConfig.defaults, idleTimeout: Duration = .seconds(300),
                maxRunning: Int = 4, shell: LoginShell = .shared) {
        self.init(source: LocalLanguageSource(configs: configs, shell: shell), idleTimeout: idleTimeout, maxRunning: maxRunning)
    }

    /// A host's servers, found through its login shell and run there over its ssh master.
    public init(host: HostFiles, configs: [LanguageServerConfig] = LanguageServerConfig.defaults, idleTimeout: Duration = .seconds(300),
                maxRunning: Int = 4) {
        self.init(source: HostLanguageSource(files: host, configs: configs), idleTimeout: idleTimeout, maxRunning: maxRunning)
    }

    init(source: any LanguageSource, idleTimeout: Duration, maxRunning: Int) {
        self.source = source
        hostName = source.hostName
        live = LiveConnections(source: source)
        self.idleTimeout = idleTimeout
        self.maxRunning = max(1, maxRunning)
    }


    public func hover(file: URL, boardRoot: URL, at position: LSPPosition) async throws -> LSPHover? {
        let (server, file) = try await server(for: file, boardRoot: boardRoot)
        return try await server.hover(file, boardRoot: boardRoot, at: position)
    }

    public func definition(file: URL, boardRoot: URL, at position: LSPPosition) async throws -> [LSPLocation] {
        let (server, file) = try await server(for: file, boardRoot: boardRoot)
        return try await server.definition(file, boardRoot: boardRoot, at: position)
    }

    public func references(file: URL, boardRoot: URL, at position: LSPPosition) async throws -> [LSPLocation] {
        let (server, file) = try await server(for: file, boardRoot: boardRoot)
        return try await server.references(file, boardRoot: boardRoot, at: position)
    }

    public func documentSymbols(file: URL, boardRoot: URL) async throws -> [LSPSymbol] {
        let (server, file) = try await server(for: file, boardRoot: boardRoot)
        return try await server.documentSymbols(file, boardRoot: boardRoot)
    }

    public func typeDefinition(file: URL, boardRoot: URL, at position: LSPPosition) async throws -> [LSPLocation] {
        let (server, file) = try await server(for: file, boardRoot: boardRoot)
        return try await server.typeDefinition(file, boardRoot: boardRoot, at: position)
    }

    public func prepareCallHierarchy(file: URL, boardRoot: URL, at position: LSPPosition) async throws -> [LSPCallHierarchyItem] {
        let (server, file) = try await server(for: file, boardRoot: boardRoot)
        return try await server.prepareCallHierarchy(file, boardRoot: boardRoot, at: position)
    }

    /// Asked of the server of the item's file, which is the server that named it.
    public func incomingCalls(_ item: LSPCallHierarchyItem, boardRoot: URL) async throws -> [LSPCallHierarchyCall] {
        let (server, _) = try await server(for: item.url, boardRoot: boardRoot)
        return try await server.incomingCalls(item, boardRoot: boardRoot)
    }

    public func outgoingCalls(_ item: LSPCallHierarchyItem, boardRoot: URL) async throws -> [LSPCallHierarchyCall] {
        let (server, _) = try await server(for: item.url, boardRoot: boardRoot)
        return try await server.outgoingCalls(item, boardRoot: boardRoot)
    }

    /// Workspace symbols matching `query` from the server of each project `files` fall in (one
    /// request per language and project root, started if needed), in the servers' order. A
    /// project whose server is missing or fails adds nothing; only when every one failed is the
    /// first error thrown.
    public func workspaceSymbols(_ query: String, files: [URL], boardRoot: URL) async throws -> [LSPWorkspaceSymbol] {
        var symbols: [LSPWorkspaceSymbol] = []
        var failure: Error?
        var answered = false
        for file in try await projects(files, boardRoot: boardRoot) {
            do {
                let (server, file) = try await server(for: file, boardRoot: boardRoot)
                symbols += try await server.workspaceSymbols(query, opening: file, boardRoot: boardRoot)
                answered = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = failure ?? error
            }
        }
        if !answered, let failure { throw failure }
        return symbols
    }

    /// One file per project (language and project root) among `files`, in their order: what
    /// `workspaceSymbols` would ask one server each for. Files no server answers for are left out.
    public func projects(_ files: [URL], boardRoot: URL) async throws -> [URL] {
        let placements = try await source.places(files, boardRoot: boardRoot)
        var seen: Set<Key> = []
        return files.filter { file in
            guard case .read(_, let config, let project)? = placements[file] else { return false }
            return seen.insert(Key(language: config.language, root: project)).inserted
        }
    }

    /// The server that would answer for `file`, if one exists (running, crashed, or starting).
    public func existingServer(for file: URL, boardRoot: URL) async -> LanguageServer? {
        guard case .read(_, let config, let project)? = try? await source.places([file], boardRoot: boardRoot)[file] else { return nil }
        return servers[Key(language: config.language, root: project)]
    }

    /// A code view shows `file`: keep it open in its server between requests (re-synced before
    /// each one) until every view that retained it releases it. What it resolved to is kept, so
    /// the release unpins what the retain pinned however the file is placed by then.
    public func retain(file: URL, boardRoot: URL) async {
        let retainer = Retainer(file: file, boardRoot: boardRoot)
        if retained[retainer] != nil {
            retained[retainer]?.count += 1
            return
        }
        retained[retainer] = Retention(count: 1)
        guard case .read(let resolved, let config, let project)? = try? await source.places([file], boardRoot: boardRoot)[file],
              retained[retainer]?.pin == nil, retained[retainer] != nil else { return }
        let pin = Pin(key: Key(language: config.language, root: project), file: resolved)
        retained[retainer]?.pin = pin
        await servers[pin.key]?.pin(pin.file)
    }

    public func release(file: URL, boardRoot: URL) async {
        let retainer = Retainer(file: file, boardRoot: boardRoot)
        guard let retention = retained[retainer] else { return }
        guard retention.count <= 1 else {
            retained[retainer]?.count -= 1
            return
        }
        retained[retainer] = nil
        guard let pin = retention.pin, !retained.values.contains(where: { $0.pin == pin }) else { return }
        await servers[pin.key]?.unpin(pin.file)
    }


    public nonisolated func text(file: URL, boardRoot: URL) async throws -> String {
        try await source.text(file: file, boardRoot: boardRoot)
    }

    /// The tracked files and the untracked ones git doesn't ignore under `scope` (default the
    /// board root), relative to it, at most `maxListedFiles`; none outside a git repository.
    public nonisolated func files(boardRoot: URL, scope: URL? = nil) async throws -> [String] {
        try await source.files(boardRoot: boardRoot, scope: scope ?? boardRoot)
    }

    /// The checkout `file` belongs to: the board root, or the board root's counterpart in the
    /// other worktree of its repository that `file` lies in.
    public nonisolated func checkoutRoot(file: URL, boardRoot: URL) async throws -> URL {
        try await source.checkoutRoot(file: file, boardRoot: boardRoot)
    }

    /// A server result relative to its board, using root spellings resolved on the server's machine.
    public nonisolated func relativePath(_ path: String, boardRoot: URL) -> String {
        source.relativePath(path, boardRoot: boardRoot)
    }

    nonisolated func locate(symbol: String, boardRoot: URL, scope: URL) async throws -> String? {
        try await source.locate(symbol: symbol, boardRoot: boardRoot, scope: scope)
    }

    nonisolated func mentioningFiles(_ name: String, boardRoot: URL, scope: URL, limit: Int) async throws -> [String] {
        try await source.mentioningFiles(name, boardRoot: boardRoot, scope: scope, limit: limit)
    }

    /// The source line of each location (trimmed), reading every file once, for reference
    /// lists; a file that can't be read gives empty lines.
    public nonisolated func lineTexts(_ locations: [LSPLocation], boardRoot: URL) async -> [String] {
        var seen: Set<URL> = []
        let files = locations.map(\.url).filter { seen.insert($0).inserted }
        let read = (try? await source.documents(files.map { DocumentRequest(file: $0, boardRoot: boardRoot, stamp: nil) })) ?? [:]
        return await offPool {
            var lines: [URL: [Substring]] = [:]
            return locations.map { location in
                if lines[location.url] == nil {
                    guard case .text(_, let text)? = read[location.url] else {
                        lines[location.url] = []
                        return ""
                    }
                    lines[location.url] = text.split(separator: "\n", omittingEmptySubsequences: false)
                }
                let fileLines = lines[location.url] ?? []
                let index = location.range.start.line
                return fileLines.indices.contains(index) ? fileLines[index].trimmingCharacters(in: .whitespaces) : ""
            }
        }
    }

    // MARK: Registry

    private func server(for file: URL, boardRoot: URL) async throws -> (LanguageServer, URL) {
        let (resolved, config, project): (URL, LanguageServerConfig, URL)
        switch try await source.places([file], boardRoot: boardRoot)[file] {
        case .read(let placed, let found, let root)?:
            (resolved, config, project) = (placed, found, root)
        case .refused?:
            throw LSPError.unreadable("\(file.path) on \(hostName ?? "this Mac") (outside the board)")
        case .unsupported?, nil:
            throw LSPError.unsupportedLanguage(file.pathExtension.isEmpty ? file.lastPathComponent : ".\(file.pathExtension) files")
        }
        let key = Key(language: config.language, root: project)
        let retainer = Retainer(file: file, boardRoot: boardRoot)
        let adopted = retained[retainer] != nil && retained[retainer]?.pin == nil
        if adopted { retained[retainer]?.pin = Pin(key: key, file: resolved) }
        let server = try await server(key, config: config)
        if adopted { await server.pin(resolved) }
        return (server, resolved)
    }

    private func server(_ key: Key, config: LanguageServerConfig) async throws -> LanguageServer {
        if let existing = servers[key] {
            touch(key)
            return existing
        }
        let binary = try await source.locate(config)
        if let existing = servers[key] {
            touch(key)
            return existing
        }
        if servers.count >= maxRunning, let oldest = lastUse.min(by: { $0.value < $1.value })?.key {
            retire(oldest)
        }
        let pinned = Set(retained.values.compactMap(\.pin).filter { $0.key == key }.map(\.file))
        let server = LanguageServer(config: config, root: key.root, binary: binary, source: source, live: live, pinned: pinned)
        servers[key] = server
        touch(key)
        return server
    }

    private func touch(_ key: Key) {
        uses += 1
        lastUse[key] = uses
        idleTimers[key]?.task.cancel()
        let token = uses
        let timeout = idleTimeout
        idleTimers[key] = (token, Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.expire(key, token: token)
        })
    }

    private func expire(_ key: Key, token: Int) async {
        guard idleTimers[key]?.token == token, let server = servers[key] else { return }
        // A request still waiting (a slow first index, say) counts as use.
        let busy = await server.isBusy
        guard idleTimers[key]?.token == token else { return }
        if busy { touch(key) } else { retire(key) }
    }

    /// Removes a server from the registry synchronously (so no request can reach it) and stops it.
    private func retire(_ key: Key) {
        guard let server = servers.removeValue(forKey: key) else { return }
        lastUse[key] = nil
        idleTimers.removeValue(forKey: key)?.task.cancel()
        Task { await server.stop() }
    }

    /// Graceful shutdown of every server.
    public func stopAll() async {
        let all = Array(servers.values)
        servers = [:]
        lastUse = [:]
        for timer in idleTimers.values { timer.task.cancel() }
        idleTimers = [:]
        await withTaskGroup(of: Void.self) { group in
            for server in all { group.addTask { await server.stop() } }
        }
    }

    /// Server processes spawned and not yet reaped (a host's: until its host has ended it).
    public nonisolated var liveProcessCount: Int { live.count }

    /// App quit: tells every server process to exit, SIGTERMs it, and SIGKILLs any still alive
    /// after `grace`; returns once they're reaped, a host's once its host ended it. Needs no
    /// actor, so it can't queue behind a busy registry or wait for the main actor.
    public nonisolated func terminateAll(grace: Duration = .seconds(2)) async {
        await live.terminateAll(grace: grace)
    }
}
