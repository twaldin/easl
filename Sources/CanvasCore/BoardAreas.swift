import Foundation

/// The files the app may read into note metadata it writes or reports itself (a fence's
/// `anchor=`, `object.get`'s `fences`), by the board file policy a remote host's reader applies
/// (`boardAreas` in `HostFiles.prelude`). An area is the board root, or its place in another
/// registered worktree of the board's repository, as written and with symlinks resolved. A live
/// file must be written inside an area and still lie inside it once symlinks resolve; a file at a
/// commit must be written inside one and not be a symlink in that commit. The note tile still
/// shows any file on this Mac (`NoteSource.excerpts` without areas).
public struct BoardAreas: Sendable {
    struct Area: Sendable {
        var lexical: String
        var real: String

        func holds(_ path: String) -> Bool { Self.inside(lexical, path) || Self.inside(real, path) }

        static func inside(_ directory: String, _ path: String) -> Bool {
            directory == "/" || path == directory || path.hasPrefix(directory + "/")
        }
    }

    let areas: [Area]

    /// The areas of the board rooted at `boardRoot` (the canonical root, not a tile's link root
    /// or ref worktree: those are checked against the areas).
    public init(boardRoot: URL) {
        let lexical = Board.hostPath(boardRoot.path, under: "/")
        let real = Self.resolved(lexical)
        var areas = [Area(lexical: lexical, real: real)]
        if let checkout = GitWorktree.containing(real), let place = Self.place(of: real, in: Self.resolved(checkout.toplevel)) {
            for worktree in checkout.siblings {
                let canonical = Board.hostPath(place, under: Self.resolved(worktree.toplevel))
                let aliases = [Board.hostPath(place, under: worktree.toplevel), Board.hostPath(Self.relative(canonical, from: real), under: lexical)]
                for alias in aliases where Self.resolved(alias) == canonical && !areas.contains(where: { $0.lexical == alias }) {
                    areas.append(Area(lexical: alias, real: canonical))
                }
            }
        }
        self.areas = areas
    }

    /// Whether files may be read relative to `root` (a link root or a ref's worktree) at all.
    func permits(root: URL) -> Bool {
        resolve(live: Board.hostPath(root.path, under: "/")) != nil
    }

    /// `path` (absolute, as written) with symlinks resolved, when it is written in an area and
    /// still lies in that area once they are.
    func resolve(live path: String) -> String? {
        let real = Self.resolved(path)
        return areas.contains { $0.holds(path) && Area.inside($0.real, real) } ? real : nil
    }

    /// The area `path` (absolute, as written) is written in, and the spelling it is written under.
    func written(_ path: String) -> (area: Area, base: String)? {
        for area in areas {
            if Area.inside(area.lexical, path) { return (area, area.lexical) }
            if Area.inside(area.real, path) { return (area, area.real) }
        }
        return nil
    }

    /// The text of `path` (relative to `root`, or absolute) on disk, or at `commit`, read only
    /// where the areas permit: `NoteSourceError.refused` outside them.
    func read(_ path: String, commit: String?, root: URL) async throws -> String {
        guard !path.isEmpty, !path.contains("\0"), !path.hasPrefix("~") else { throw NoteSourceError.refused }
        let requested = Board.hostPath(path, under: root.path)
        guard let commit else {
            guard let real = resolve(live: requested) else { throw NoteSourceError.refused }
            return try await offPool { Result { try Self.readRegular(real) } }.get()
        }
        guard NoteSource.isRevision(commit) else { throw NoteSourceError.invalidRevision(commit) }
        guard let found = written(requested) else { throw NoteSourceError.refused }
        let relative = String(requested.dropFirst(found.base.count).drop(while: { $0 == "/" }))
        guard !relative.isEmpty else { throw NoteSourceError.notAtCommit(commit) }
        let directory = URL(fileURLWithPath: found.area.real)
        let entry: Data
        do {
            entry = try await GitRunner.shared.run(["--literal-pathspecs", "ls-tree", "-z", commit, "--", relative], in: directory, timeout: NoteSource.timeout)
        } catch GitError.failed {
            throw await NoteSource.missing(commit, in: directory)
        }
        let mode = String(decoding: entry.prefix(7), as: UTF8.self)
        // A symlink's blob names a file elsewhere: refused, as the host's reader refuses it.
        if mode == "120000 " { throw NoteSourceError.refused }
        guard mode == "100644 " || mode == "100755 " else { throw NoteSourceError.notAtCommit(commit) }
        return try await NoteSource.show(["show", "--end-of-options", "\(commit):./\(relative)"], commit: commit, in: directory)
    }

    /// `real` (symlink-free) read through one descriptor opened with no symlink anywhere on its
    /// path (`O_NOFOLLOW_ANY`), so a directory swapped for a symlink since the check can't lead
    /// the read outside.
    static func readRegular(_ real: String) throws -> String {
        let descriptor = open(real, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ELOOP, ENOTDIR: throw NoteSourceError.refused
            case ENOENT: throw CocoaError(.fileReadNoSuchFile)
            default: throw CocoaError(.fileReadUnknown)
            }
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadNoSuchFile) }
        let data = try file.readToEnd() ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }

    static func resolved(_ path: String) -> String {
        GitDiffEngine.realPath(URL(fileURLWithPath: path)).path
    }

    /// `path`'s place under `top`: "" for `top` itself, nil outside it.
    static func place(of path: String, in top: String) -> String? {
        if path == top { return "" }
        return path.hasPrefix(top + "/") ? String(path.dropFirst(top.count + 1)) : nil
    }

    /// `path` relative to `base`, both absolute, climbing out with `..` where they part.
    static func relative(_ path: String, from base: String) -> String {
        let from = base.split(separator: "/"), to = path.split(separator: "/")
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
        return (Array(repeating: "..", count: from.count - common) + to[common...].map(String.init)).joined(separator: "/")
    }
}
