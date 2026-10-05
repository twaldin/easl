import Foundation

/// A browser tile's "Reload When Files Change" (`props.reloadOnChange`): a page served from this
/// Mac reloads when a file behind it changes, for static servers and builds with no hot reload
/// of their own. Which pages qualify, which directory is behind them, and which changes count.
public enum LocalPage {
    /// A page served from this Mac: http(s) on localhost, a `.localhost` name, 127.0.0.0/8 or
    /// [::1], or a file.
    public static func isLocal(_ url: URL) -> Bool {
        if url.isFileURL { return true }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "[::1]" || isLoopbackIPv4(host)
    }

    /// A dotted IPv4 address in 127.0.0.0/8 (`127.0.0.1`), not a name that starts like one
    /// (`127.example.com`).
    static func isLoopbackIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && UInt8($0) != nil }) else { return false }
        return octets[0] == "127"
    }

    /// The directory whose files are behind `url`: a file page's own folder, else the board's
    /// root (the repository the local server serves); nil for a page that isn't local.
    public static func directory(for url: URL, boardRoot: URL) -> URL? {
        guard isLocal(url) else { return nil }
        return url.isFileURL ? url.deletingLastPathComponent().standardizedFileURL : boardRoot.standardizedFileURL
    }

    /// Whether a change to `path` under `root` reloads the page: not inside a hidden directory
    /// (`.git`, `.build`, editors' swap folders), `node_modules`, or a hidden file (`.DS_Store`,
    /// an editor's `.swp`), which change all the time without the page changing.
    public static func counts(_ path: String, under root: String) -> Bool {
        let base = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(base) else { return false }
        let parts = path.dropFirst(base.count).split(separator: "/")
        guard !parts.isEmpty else { return false }
        return !parts.contains { $0.hasPrefix(".") || $0 == "node_modules" }
    }
}

/// Watches a directory tree for `LocalPage`: `onChange` runs on the main actor once per burst
/// of counted changes (FSEvents coalesces them over `latency`). Stops when released.
public final class LocalPageWatch {
    private var stream: FileEventStream?

    /// FSEvents reports real paths (/private/tmp, not /tmp), so the root is resolved first, with
    /// realpath(3): Foundation's `resolvingSymlinksInPath` strips `/private` again.
    public init?(directory: URL, latency: TimeInterval = 0.3, onChange: @escaping @MainActor @Sendable () -> Void) {
        let root = realpath(directory.path, nil).map { resolved in
            defer { free(resolved) }
            return String(cString: resolved)
        } ?? directory.path
        stream = FileEventStream(paths: [root], latency: latency) { paths in
            guard paths.contains(where: { LocalPage.counts($0, under: root) }) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { onChange() } }
        }
        if stream == nil { return nil }
    }
}
