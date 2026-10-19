import Foundation

final class HostLanguageSource: LanguageSource {
    let host: String
    let files: HostFiles
    private let git: HostGit
    private let reaper: HostGit
    private let configs: [LanguageServerConfig]
    private let placed = Locked<[PlaceKey: (place: Place, at: ContinuousClock.Instant)]>([:])
    private let realRoots = Locked<[String: String]>([:])
    private let binaries = Locked<[String: (binary: ServerBinary?, at: ContinuousClock.Instant)]>([:])

    static let placeLifetime: Duration = .seconds(30)
    static let maxCandidates = 64
    static let readBatch = 8

    init(files: HostFiles, configs: [LanguageServerConfig]) {
        host = files.hostName
        self.files = files
        git = HostGit(files: files)
        reaper = HostGit(files: files.cleanup)
        self.configs = configs
    }

    var hostName: String? { host }


    func places(_ files: [URL], boardRoot: URL) async throws -> [URL: Placement] {
        let known: [URL: Place]
        do {
            known = try await place(files, boardRoot: boardRoot)
        } catch {
            throw failure(error)
        }
        var placements: [URL: Placement] = [:]
        for given in files {
            guard let place = known[given], place.refused != true, let path = place.file else {
                placements[given] = .refused
                continue
            }
            if let language = place.language, let project = place.project, let config = configs.first(where: { $0.language == language }) {
                placements[given] = .read(file: Self.file(path), config: config, project: Self.directory(project))
            } else {
                placements[given] = .unsupported
            }
        }
        return placements
    }

    func locate(_ config: LanguageServerConfig) async throws -> ServerBinary {
        let key = config.language + "\0" + config.command
        if let known = binaries.withLock({ $0[key] }) {
            if let binary = known.binary { return binary }
            if known.at.duration(to: .now) < LoginShell.missRetry { throw LSPError.unavailable(config.notFound(on: host)) }
        }
        var request = Request("server")
        request.command = config.command
        request.probes = LoginShell.probes(config)
        request.directories = LanguageServerConfig.toolDirectories + config.directories
        let reply: Reply
        do {
            reply = try await call(request, timeout: 20)
        } catch {
            throw failure(error)
        }
        let binary = reply.path.map { path in ServerBinary(path: path, environment: reply.searchPath.map { ["PATH": $0] } ?? [:]) }
        binaries.withLock { $0[key] = (binary, .now) }
        guard let binary else { throw LSPError.unavailable(config.notFound(on: host)) }
        return binary
    }

    func launch(_ binary: ServerBinary, config: LanguageServerConfig, project: URL) async throws -> LSPLaunch {
        let ssh: (executable: String, arguments: [String])
        do {
            ssh = try await files.channel(Self.launcher, [binary.path, project.path, binary.environment["PATH"] ?? ""] + config.arguments)
        } catch {
            throw failure(error)
        }
        return LSPLaunch(executable: URL(fileURLWithPath: ssh.executable), arguments: ssh.arguments, environment: ProcessInfo.processInfo.environment,
                         directory: nil, name: "\((binary.path as NSString).lastPathComponent) on \(host)", remote: true)
    }

    static let launcher = #"""
    for b in "$(command -v bun)" "$HOME/.bun/bin/bun" /opt/homebrew/bin/bun /usr/local/bin/bun; do
      if [ -n "$b" ] && [ -x "$b" ]; then
        exec "$b" --env-file=/dev/null -e '
    const cp = require("node:child_process");
    const [binary, directory, searchPath, ...args] = process.argv.slice(2);
    const child = cp.spawn(binary, args, {
      cwd: directory, env: searchPath ? { ...process.env, PATH: searchPath } : process.env,
      detached: true, stdio: ["pipe", "pipe", "inherit"]
    });
    let stopped = false;
    const stop = () => {
      if (stopped) return;
      stopped = true;
      process.stdin.unpipe(child.stdin);
      process.stdin.pause();
      if (child.pid) cp.spawnSync("/bin/kill", ["-KILL", "--", String(-child.pid)], { stdio: "ignore" });
    };
    process.stdin.on("end", stop);
    process.stdin.on("error", stop);
    process.stdout.on("error", stop);
    for (const signal of ["SIGHUP", "SIGINT", "SIGTERM"]) process.on(signal, stop);
    child.stdin.on("error", stop);
    child.on("error", error => { console.error(error.message); process.exit(127); });
    child.on("exit", stop);
    child.on("close", code => process.exit(code ?? 1));
    if (child.pid) {
      const body = JSON.stringify({ jsonrpc: "2.0", method: "easl/hostProcess", params: { pid: child.pid } });
      process.stdout.write("Content-Length: " + Buffer.byteLength(body) + "\r\n\r\n" + body);
    }
    child.stdout.pipe(process.stdout);
    process.stdin.pipe(child.stdin);
    ' -- easl-lsp "$@"
      fi
    done
    echo "bun isn't installed on the host" >&2
    exit 127
    """#

    func documents(_ requests: [DocumentRequest]) async throws -> [URL: DocumentRead] {
        let reads: [Read]
        do {
            reads = try await read(requests)
        } catch {
            throw failure(error)
        }
        var documents: [URL: DocumentRead] = [:]
        for (request, read) in zip(requests, reads) {
            switch read.kind {
            case "text":
                if let stamp = read.stamp, let text = Self.text(read) {
                    documents[request.file] = .text(.host(stamp), text)
                } else {
                    documents[request.file] = .unreadable("\(request.file.path) on \(host) (not UTF-8 text)")
                }
            case "unchanged":
                documents[request.file] = .unchanged
            default:
                let why = ["missing": "not found", "refused": "outside the board", "tooLarge": "over \(GitDiffEngine.maxFileSize >> 20) MiB"][read.kind] ?? "unreadable"
                documents[request.file] = .unreadable("\(request.file.path) on \(host) (\(why))")
            }
        }
        return documents
    }

    func reap(_ pid: Int32, binary: ServerBinary) async {
        var request = Request("reap")
        request.pid = pid
        request.binary = binary.path
        let _: Reply? = try? await reaper.call(request, timeout: 8)
    }


    func text(file: URL, boardRoot: URL) async throws -> String {
        guard let document = try await read([DocumentRequest(file: file, boardRoot: boardRoot, stamp: nil)]).first else { throw HostFileError.unreadable }
        switch document.kind {
        case "text":
            guard let text = Self.text(document) else { throw HostFileError.unreadable }
            return text
        case "missing": throw HostFileError.notFound(commit: nil)
        case "refused": throw HostFileError.refused
        case "tooLarge": throw HostFileError.tooLarge(limit: GitDiffEngine.maxFileSize)
        default: throw HostFileError.unreadable
        }
    }

    func files(boardRoot: URL, scope: URL) async throws -> [String] {
        var request = Request("list", boardRoot: boardRoot.path)
        request.scope = scope.path
        request.limit = LanguageService.maxListedFiles
        guard let paths = try await call(request, timeout: 30).paths else { throw HostFileError.unavailable("invalid host file list reply") }
        return paths
    }

    func checkoutRoot(file: URL, boardRoot: URL) async throws -> URL {
        guard let found = try await place([file], boardRoot: boardRoot)[file], found.refused != true, found.own != true,
              let checkout = found.checkout else { return boardRoot }
        return Self.directory(checkout)
    }

    func relativePath(_ path: String, boardRoot: URL) -> String {
        let written = Board.hostRelativePath(path, root: boardRoot.path)
        guard written.hasPrefix("/"), let real = realRoots.withLock({ $0[boardRoot.path] }) else { return written }
        return Board.hostRelativePath(path, root: real)
    }

    func locate(symbol: String, boardRoot: URL, scope: URL) async throws -> String? {
        guard let pattern = NoteSource.symbolPattern(symbol) else { return nil }
        var candidates = try await grep(pattern, mode: "declared", boardRoot: boardRoot, scope: scope, limit: Self.maxCandidates)[...]
        while !candidates.isEmpty {
            let batch = Array(candidates.prefix(Self.readBatch))
            candidates = candidates.dropFirst(Self.readBatch)
            let reads = try await read(batch.map { DocumentRequest(file: Self.file(scope.path + "/" + $0), boardRoot: boardRoot, stamp: nil) })
            for (candidate, read) in zip(batch, reads) {
                if let text = Self.text(read), NoteAnchor.symbolRange(symbol, in: NoteSource.lines(of: text)) != nil { return candidate }
            }
        }
        return nil
    }

    func mentioningFiles(_ name: String, boardRoot: URL, scope: URL, limit: Int) async throws -> [String] {
        try await grep(name, mode: "mentions", boardRoot: boardRoot, scope: scope, limit: limit)
    }


    private struct PlaceKey: Hashable {
        let boardRoot: String
        let file: String
    }

    private struct Place: Decodable {
        var refused: Bool?
        var file: String?
        var own: Bool?
        var checkout: String?
        var language: String?
        var project: String?
    }

    private func place(_ files: [URL], boardRoot: URL) async throws -> [URL: Place] {
        let now = ContinuousClock.now
        var known: [URL: Place] = [:]
        var missing: [URL] = []
        placed.withLock { cache in
            for file in files where known[file] == nil && !missing.contains(file) {
                if let entry = cache[PlaceKey(boardRoot: boardRoot.path, file: file.path)], entry.at.duration(to: now) < Self.placeLifetime {
                    known[file] = entry.place
                } else {
                    missing.append(file)
                }
            }
        }
        guard !missing.isEmpty else { return known }
        var request = Request("place", boardRoot: boardRoot.path)
        request.files = missing.map(\.path)
        request.configs = configs.map { Config(language: $0.language, extensions: $0.languageIDs.keys.sorted(), markers: $0.rootMarkers) }
        let reply = try await call(request, timeout: 20)
        guard let root = reply.root, let places = reply.places, places.count == missing.count else {
            throw HostFileError.unavailable("invalid host place reply")
        }
        let at = ContinuousClock.now
        realRoots.withLock { $0[boardRoot.path] = root }
        placed.withLock { cache in
            cache = cache.filter { $0.value.at.duration(to: at) < Self.placeLifetime }
            for (file, place) in zip(missing, places) {
                cache[PlaceKey(boardRoot: boardRoot.path, file: file.path)] = (place, at)
                known[file] = place
            }
        }
        return known
    }

    private func read(_ requests: [DocumentRequest]) async throws -> [Read] {
        guard !requests.isEmpty else { return [] }
        var request = Request("documents")
        request.documents = requests.map { Document(path: $0.file.path, boardRoot: $0.boardRoot.path, stamp: $0.stamp?.hostValue) }
        guard let documents = try await call(request, timeout: 60).documents, documents.count == requests.count else {
            throw HostFileError.unavailable("invalid host document reply")
        }
        return documents
    }

    private func grep(_ pattern: String, mode: String, boardRoot: URL, scope: URL, limit: Int) async throws -> [String] {
        var request = Request("grep", boardRoot: boardRoot.path)
        request.scope = scope.path
        request.pattern = pattern
        request.mode = mode
        request.limit = limit
        guard let paths = try await call(request, timeout: 30).paths else { throw HostFileError.unavailable("invalid host search reply") }
        return paths
    }

    private func call(_ request: Request, timeout: TimeInterval) async throws -> Reply {
        let reply: Reply = try await git.call(request, timeout: timeout)
        guard reply.ok else { throw HostFileError(code: reply.code, message: reply.message, limit: reply.limit) }
        return reply
    }

    private func failure(_ error: Error) -> Error {
        guard let error = error as? HostFileError else { return error }
        if case .unavailable(let message) = error { return LSPError.unavailable("\(host) is unavailable: \(message)") }
        return LSPError.unavailable("\(host): \(HostGit.refusal(error))")
    }

    private static func text(_ read: Read) -> String? {
        guard read.kind == "text" else { return nil }
        return read.data.flatMap { Data(base64Encoded: $0) }.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Host paths as URLs, made without asking this Mac's disk whether they are directories.
    private static func file(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: false) }
    private static func directory(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    private struct Request: Encodable {
        var op: String
        var boardRoot: String
        var limits = HostGit.Limits()
        var files: [String]?
        var configs: [Config]?
        var documents: [Document]?
        var scope: String?
        var pattern: String?
        var mode: String?
        var limit: Int?
        var command: String?
        var probes: [String]?
        var directories: [String]?
        var pid: Int32?
        var binary: String?

        init(_ op: String, boardRoot: String = "") {
            self.op = op
            self.boardRoot = boardRoot
        }
    }

    private struct Config: Encodable {
        var language: String
        var extensions: [String]
        var markers: [String]
    }

    private struct Document: Encodable {
        var path: String
        var boardRoot: String
        var stamp: String?
    }

    private struct Reply: Decodable {
        var ok: Bool
        var code: String?
        var message: String?
        var limit: Int?
        var root: String?
        var places: [Place]?
        var documents: [Read]?
        var paths: [String]?
        var path: String?
        var searchPath: String?
    }

    private struct Read: Decodable {
        var kind: String
        var stamp: String?
        var data: String?
    }
}
