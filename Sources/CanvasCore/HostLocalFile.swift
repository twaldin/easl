import Darwin
import Foundation

struct HostLocalFile: Sendable {
    let root: String
    let path: String
    let request: HostFileRequest
    let limit: Int?
    let metadataLimit: Bool

    init(_ request: HostFileRequest) throws {
        try request.range?.validate()
        let rootURL: URL
        switch request.source {
        case .directory(let directory):
            rootURL = URL(fileURLWithPath: directory)
        case .liveRoot(let ref, let boardRoot):
            let board = URL(fileURLWithPath: boardRoot)
            rootURL = NoteSource.isRevision(ref) ? RefSource.liveRoot(ref: ref, boardRoot: board) ?? board : board
        case .ref:
            throw HostFileError.refused
        }
        let root = Board.hostPath(rootURL.path, under: FileManager.default.currentDirectoryPath)
        let base = BoardAreas.resolved(root)
        let path: String
        let limit: Int?
        let metadataLimit: Bool
        switch request.policy {
        case .boardFile(let relative):
            let relative = try HtmlKit.boardRelative(relative)
            let candidate = BoardAreas.resolved(Board.hostPath(relative, under: root))
            guard candidate != base, BoardAreas.Area.inside(base, candidate) else { throw HostFileError.refused }
            path = candidate
            limit = SourceExcerpt.maxFileBytes
            metadataLimit = false
        case .boardImage(let input), .boardAsset(let input):
            guard !input.isEmpty, !input.contains("\0"), !input.hasPrefix("~") else { throw HostFileError.refused }
            let inputPath: String
            if input.prefix(5).lowercased() == "file:" {
                guard let url = URL(string: input), url.isFileURL,
                      url.host == nil || url.host == "" || url.host == "localhost" else { throw HostFileError.refused }
                inputPath = url.path
            } else {
                guard input.range(of: "^[a-z][a-z0-9+.-]*://", options: [.regularExpression, .caseInsensitive]) == nil else {
                    throw HostFileError.refused
                }
                inputPath = input
            }
            guard !inputPath.contains("\0") else { throw HostFileError.refused }
            let requested = Board.hostPath(inputPath, under: root)
            let candidate: String
            if case .boardAsset = request.policy, !BoardAreas.Area.inside(root, requested) {
                guard let allowed = BoardAreas(boardRoot: URL(fileURLWithPath: root)).resolve(live: requested) else {
                    throw HostFileError.refused
                }
                candidate = allowed
            } else {
                guard requested != root, BoardAreas.Area.inside(root, requested) else { throw HostFileError.refused }
                candidate = BoardAreas.resolved(requested)
                guard candidate != base, BoardAreas.Area.inside(base, candidate) else { throw HostFileError.refused }
            }
            path = candidate
            limit = SourceExcerpt.maxFileBytes
            if case .boardImage = request.policy { metadataLimit = true }
            else { metadataLimit = false }
        case .pageImage(let relative, let absolute, let temps):
            let dirs = [base] + temps.map { BoardAreas.resolved(Board.hostPath($0, under: root)) }
            func allowed(_ candidate: String) -> Bool {
                LocalImage.extensions.contains(URL(fileURLWithPath: candidate).pathExtension.lowercased()) &&
                    dirs.contains { BoardAreas.Area.inside($0, candidate) }
            }
            if let relative, !relative.contains("\0"),
               let candidate = Self.existing(Board.hostPath(relative, under: root)), allowed(candidate) {
                path = candidate
            } else {
                guard let absolute, !absolute.contains("\0") else { throw HostFileError.refused }
                guard let candidate = Self.existing(Board.hostPath(absolute, under: root)) else { throw HostFileError.notFound(commit: nil) }
                guard allowed(candidate) else { throw HostFileError.refused }
                path = candidate
            }
            limit = nil
            metadataLimit = false
        }
        self.root = root
        self.path = path
        self.request = request
        self.limit = limit
        self.metadataLimit = metadataLimit
    }

    func read() throws -> HostFile {
        let descriptor = try Self.openRegular(path)
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw HostFileError.unreadable }
        guard info.st_mode & S_IFMT == S_IFREG else { throw HostFileError.notFound(commit: nil) }
        let size = Int64(info.st_size)
        let offset = request.range?.offset ?? 0
        guard size >= 0, offset <= size else { throw HostFileError.refused }
        if request.range == nil, let limit, size > Int64(limit), request.bytes || metadataLimit {
            throw HostFileError.tooLarge(limit: limit)
        }
        let stamp = Self.stamp(info)
        var data = Data()
        if request.bytes {
            let count = request.range.map { min(Int64($0.length), size - offset) } ?? size
            guard let capacity = Int(exactly: count) else { throw HostFileError.unreadable }
            data = Data(count: capacity)
            let used = try data.withUnsafeMutableBytes { buffer -> Int in
                var used = 0
                while used < capacity {
                    let count = pread(descriptor, buffer.baseAddress!.advanced(by: used), capacity - used, off_t(offset + Int64(used)))
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw HostFileError.unreadable
                    }
                    if count == 0 { break }
                    used += count
                }
                return used
            }
            data.count = used
            var after = stat()
            guard fstat(descriptor, &after) == 0, Self.stamp(after) == stamp else { throw HostFileError.unreadable }
        }
        return HostFile(root: root, path: path, commit: nil, data: data, stamp: stamp, size: size, offset: offset)
    }

    private static func stamp(_ info: stat) -> String {
        let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        let ctime = Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(mtime):\(ctime)"
    }

    private static func existing(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    private static func openRegular(_ path: String) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var directory = open("/", flags)
        guard directory >= 0 else { throw openError() }
        defer { close(directory) }
        let components = path.split(separator: "/")
        guard let name = components.last else { throw HostFileError.notFound(commit: nil) }
        for component in components.dropLast() {
            let next = openat(directory, String(component), flags)
            guard next >= 0 else { throw openError() }
            close(directory)
            directory = next
        }
        let descriptor = openat(directory, String(name), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw openError() }
        return descriptor
    }

    private static func openError() -> HostFileError {
        switch errno {
        case ELOOP, ENOTDIR: .refused
        case ENOENT: .notFound(commit: nil)
        default: .unreadable
        }
    }
}
