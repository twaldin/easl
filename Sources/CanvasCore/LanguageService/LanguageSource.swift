import Darwin
import Foundation

protocol LanguageSource: Sendable {
    var hostName: String? { get }

    func places(_ files: [URL], boardRoot: URL) async throws -> [URL: Placement]
    func locate(_ config: LanguageServerConfig) async throws -> ServerBinary
    func launch(_ binary: ServerBinary, config: LanguageServerConfig, project: URL) async throws -> LSPLaunch
    func documents(_ requests: [DocumentRequest]) async throws -> [URL: DocumentRead]
    func reap(_ pid: Int32, binary: ServerBinary) async

    func text(file: URL, boardRoot: URL) async throws -> String
    func files(boardRoot: URL, scope: URL) async throws -> [String]
    func checkoutRoot(file: URL, boardRoot: URL) async throws -> URL
    func relativePath(_ path: String, boardRoot: URL) -> String
    func locate(symbol: String, boardRoot: URL, scope: URL) async throws -> String?
    func mentioningFiles(_ name: String, boardRoot: URL, scope: URL, limit: Int) async throws -> [String]
}

enum Placement: Sendable {
    case read(file: URL, config: LanguageServerConfig, project: URL)
    case unsupported
    case refused
}

struct ServerBinary: Sendable, Equatable {
    var path: String
    var environment: [String: String]
}

enum DocumentStamp: Hashable, Sendable {
    case local(inode: ino_t, size: off_t, seconds: time_t, nanoseconds: Int)
    case host(String)

    var hostValue: String? {
        if case .host(let value) = self { return value }
        return nil
    }
}

struct DocumentRequest: Sendable {
    var file: URL
    var boardRoot: URL
    var stamp: DocumentStamp?
}

enum DocumentRead: Sendable {
    case text(DocumentStamp, String)
    case unchanged
    case unreadable(String)
}

struct LocalLanguageSource: LanguageSource {
    let configs: [LanguageServerConfig]
    let shell: LoginShell

    var hostName: String? { nil }

    func places(_ files: [URL], boardRoot: URL) async throws -> [URL: Placement] {
        let root = GitDiffEngine.realPath(boardRoot)
        var placed: [URL: Placement] = [:]
        for given in files {
            let file = GitDiffEngine.realPath(given)
            guard let config = configs.first(where: { $0.languageID(for: file) != nil }) else {
                placed[given] = .unsupported
                continue
            }
            let boundary = file.path.hasPrefix(root.path + "/") ? root
                : GitWorktree.counterpart(of: root.path, toward: file.path).map { GitDiffEngine.realPath(URL(fileURLWithPath: $0)) } ?? root
            placed[given] = .read(file: file, config: config, project: config.projectRoot(for: file, within: boundary))
        }
        return placed
    }

    func locate(_ config: LanguageServerConfig) async throws -> ServerBinary {
        let shell = shell
        let (found, environment) = await offPool { (shell.locate(config), shell.environment) }
        guard let found else { throw LSPError.unavailable(config.notFound()) }
        return ServerBinary(path: found.path, environment: environment)
    }

    func launch(_ binary: ServerBinary, config: LanguageServerConfig, project: URL) async throws -> LSPLaunch {
        let executable = URL(fileURLWithPath: binary.path)
        return LSPLaunch(executable: executable, arguments: config.arguments, environment: binary.environment, directory: project,
                         name: executable.lastPathComponent, remote: false)
    }

    func documents(_ requests: [DocumentRequest]) async throws -> [URL: DocumentRead] {
        await offPool {
            var read: [URL: DocumentRead] = [:]
            for request in requests {
                guard let stamp = Self.stamp(request.file) else {
                    read[request.file] = .unreadable(request.file.path)
                    continue
                }
                if stamp == request.stamp {
                    read[request.file] = .unchanged
                } else {
                    read[request.file] = (try? String(contentsOf: request.file, encoding: .utf8)).map { DocumentRead.text(stamp, $0) } ?? .unreadable(request.file.path)
                }
            }
            return read
        }
    }

    func reap(_ pid: Int32, binary: ServerBinary) async {}

    private static func stamp(_ file: URL) -> DocumentStamp? {
        var info = stat()
        guard stat(file.path, &info) == 0 else { return nil }
        return .local(inode: info.st_ino, size: info.st_size, seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }

    func text(file: URL, boardRoot: URL) async throws -> String {
        try await offPool { () -> Result<String, HostFileError> in
            do {
                return .success(try String(contentsOf: file, encoding: .utf8))
            } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
                return .failure(.notFound(commit: nil))
            } catch {
                return .failure(.unreadable)
            }
        }.get()
    }

    func files(boardRoot: URL, scope: URL) async throws -> [String] {
        let data = try await GitRunner.shared.run(["ls-files", "--cached", "--others", "--exclude-standard", "--deduplicate", "-z"],
                                                  in: scope, maxOutput: 64 << 20, timeout: 10)
        try Task.checkCancellation()
        return await offPool { data.split(separator: 0).prefix(LanguageService.maxListedFiles).map { String(decoding: $0, as: UTF8.self) } }
    }

    func checkoutRoot(file: URL, boardRoot: URL) async throws -> URL {
        GitWorktree.counterpart(of: boardRoot.path, toward: file.path).map(URL.init(fileURLWithPath:)) ?? boardRoot
    }

    func relativePath(_ path: String, boardRoot: URL) -> String {
        Board.relativePath(path, root: boardRoot)
    }

    func locate(symbol: String, boardRoot: URL, scope: URL) async throws -> String? {
        await NoteSource.locate(symbol: symbol, root: scope)
    }

    func mentioningFiles(_ name: String, boardRoot: URL, scope: URL, limit: Int) async throws -> [String] {
        let data = try? await GitRunner.shared.run(["grep", "-n", "-I", "-w", "-F", "-e", name], in: scope, allowedStatus: [0, 1],
                                                   maxOutput: NoteSource.maxOutput, timeout: NoteSource.timeout)
        try Task.checkCancellation()
        guard let data, let output = String(data: data, encoding: .utf8) else { return [] }
        let declared = try? NSRegularExpression(pattern: #"(^|[^\w.$])"# + NSRegularExpression.escapedPattern(for: name) + #"\s*[(<=:]"#)
        var order: [String] = []
        var seen: Set<String> = []
        var looksDeclared: Set<String> = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let path = String(parts[0]), text = String(parts[2])
            if seen.insert(path).inserted { order.append(path) }
            if declared?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil { looksDeclared.insert(path) }
        }
        return Array((order.filter(looksDeclared.contains) + order.filter { !looksDeclared.contains($0) }).prefix(limit))
    }
}
