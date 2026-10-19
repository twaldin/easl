import Foundation

/// Filesystem and network boundaries for HTML tiles: which board files a page may read, which
/// kit files the `canvas-kit:` scheme serves, and which hosts the content rule list lets through.
public enum HtmlKit {
    public static let scheme = "canvas-kit"
    /// Every tile's page is `canvas-kit://html/<tileId>`; the kit is served beside it under `/kit/`,
    /// so kit URLs are same-origin with the page.
    public static let host = "html"
    public static let kitPrefix = "/kit/"

    public static func pageURL(tile: ObjectID) -> URL {
        URL(string: "\(scheme)://\(host)/\(tile)")!
    }

    /// The served page: the kit head, then the tile's html as written. Elements before an
    /// author's own `<html>`/`<head>` land in the implied head, so both fragments and full
    /// documents work. The kit script runs first so its Tailwind theme exists when Tailwind starts.
    public static func document(html: String, policy: String? = nil) -> String {
        """
        <!doctype html>
        <meta charset="utf-8">
        \(policy.map { "<meta http-equiv=\"Content-Security-Policy\" content=\"\($0)\">" } ?? "")
        <meta name="viewport" content="width=device-width">
        <meta name="color-scheme" content="light dark">
        <link rel="stylesheet" href="/kit/canvas-kit.css">
        <script src="/kit/canvas-kit.js"></script>
        <script src="/kit/vendor/tailwindcss-browser.js"></script>
        \(html)
        """
    }

    /// Starting content for File > New HTML Tile.
    public static let emptyTemplate = """
    <main class="space-y-3">
      <h1 class="text-xl font-semibold">Untitled</h1>
      <p class="text-muted-foreground">Edit this tile's <code>html</code> prop. Tailwind, Mermaid, and the kit's components are preloaded.</p>
    </main>
    """

    /// The board file a page asks for. Paths are board-relative and must stay inside the root even
    /// after symlinks resolve; absolute paths, `~`, and `..` components are rejected outright.
    public static func boardRelative(_ path: String) throws -> String {
        guard !path.isEmpty, !path.contains("\0"), !path.hasPrefix("/"), !path.hasPrefix("~") else { throw HtmlError.outsideRoot(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !components.isEmpty, !components.contains("..") else { throw HtmlError.outsideRoot(path) }
        return components.joined(separator: "/")
    }

    public static func boardFile(_ path: String, root: URL) throws -> (relative: String, url: URL) {
        let relative = try boardRelative(path)
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let url = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(rootPath + "/") else { throw HtmlError.outsideRoot(path) }
        return (relative, url)
    }

    /// The kit file for a `canvas-kit:` request path (`/kit/…`, already percent-decoded by URL),
    /// or nil when it isn't a regular file inside `kitRoot`.
    public static func kitFile(requestPath: String, kitRoot: URL) -> URL? {
        guard requestPath.hasPrefix(kitPrefix) else { return nil }
        let components = requestPath.dropFirst(kitPrefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }) else { return nil }
        let rootPath = kitRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let url = kitRoot.appendingPathComponent(components.joined(separator: "/")).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard url.path.hasPrefix(rootPath + "/"), FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return url
    }

    public static func mimeType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "js", "mjs": "text/javascript"
        case "css": "text/css"
        case "html", "htm": "text/html"
        case "json": "application/json"
        case "csv": "text/csv"
        case "txt": "text/plain"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "webm": "video/webm"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "wav": "audio/wav"
        case "ogg": "audio/ogg"
        case "wasm": "application/wasm"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic", "heif": "image/heic"
        case "tif", "tiff": "image/tiff"
        case "bmp": "image/bmp"
        case "pdf": "application/pdf"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        default: "application/octet-stream"
        }
    }

    // MARK: Network

    /// Normalizes one `props.allowNetwork` entry: `host`, `host:port`, or `*.host` (the host and
    /// its subdomains), lowercased with a canonical port. Anything else (schemes, paths, userinfo,
    /// wildcards elsewhere) is not an allowlist entry and is ignored, so a malformed entry never
    /// opens more than it names.
    public static func allowedHost(_ entry: String) -> String? {
        let lower = entry.lowercased()
        let wildcard = lower.hasPrefix("*.")
        var host = wildcard ? String(lower.dropFirst(2)) : lower
        var port: Int?
        if let colon = host.lastIndex(of: ":") {
            let digits = host[host.index(after: colon)...]
            guard (1...5).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits), (1...65535).contains(value) else { return nil }
            port = value
            host = String(host[..<colon])
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...253).contains(host.count), labels.allSatisfy({ label in
            (1...63).contains(label.count) && label.first != "-" && label.last != "-"
                && label.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
        }) else { return nil }
        return (wildcard ? "*." : "") + host + (port.map { ":\($0)" } ?? "")
    }

    /// URL regexes that exempt allowlisted hosts from the network block. WebKit matches rules
    /// against the canonical URL (lowercase host, default port dropped, path always present), so
    /// each pattern pins the whole authority: scheme, the host (no userinfo), an optional numeric
    /// port, then the `/` that starts the path. WebKit's rule regexes have no alternation, hence
    /// one pattern per scheme family.
    public static func exceptionPatterns(allow entries: [String]) -> [String] {
        var patterns: [String] = []
        for entry in Set(entries.compactMap(allowedHost)).sorted() {
            let wildcard = entry.hasPrefix("*.")
            var name = wildcard ? String(entry.dropFirst(2)) : entry
            var port: Int?
            if let colon = name.lastIndex(of: ":") {
                port = Int(name[name.index(after: colon)...])
                name = String(name[..<colon])
            }
            let host = (wildcard ? "([a-z0-9-]+\\.)*" : "") + name.replacingOccurrences(of: ".", with: "\\.")
            guard let port else {
                patterns += ["https?", "wss?"].map { "^\($0)://\(host)(:[0-9]+)?/" }
                continue
            }
            patterns += ["https?", "wss?"].map { "^\($0)://\(host):\(port)/" }
            // An explicit default port is dropped from the canonical URL WebKit matches.
            if port == 443 { patterns += ["^https://\(host)/", "^wss://\(host)/"] }
            if port == 80 { patterns += ["^http://\(host)/", "^ws://\(host)/"] }
        }
        return patterns
    }

    public static func contentSecurityPolicy(allow entries: [String]) -> String {
        var sources = [scheme + ":", "data:", "blob:"]
        for entry in Set(entries.compactMap(allowedHost)).sorted() {
            let wildcard = entry.hasPrefix("*.")
            let hostPort = wildcard ? String(entry.dropFirst(2)) : entry
            let parts = hostPort.split(separator: ":", maxSplits: 1)
            let host = String(parts[0])
            let port = parts.count == 2 ? String(parts[1]) : "*"
            for name in wildcard ? [host, "*." + host] : [host] {
                sources += ["ws", "wss"].map { "\($0)://\(name):\(port)" }
            }
        }
        let allowed = sources.joined(separator: " ")
        return "default-src \(allowed); script-src \(allowed) 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'; style-src \(allowed) 'unsafe-inline'"
    }

    /// Host-independent guard for remote pages. Canonical bytes keep its persisted cache identity
    /// stable across views and application launches.
    public static let remoteNetworkRules: String = {
        var patterns = ["^https?:", "^file:", "^wss?://\\[", "^wss?://0\\.", "^wss?://127\\.",
                        "^wss?://10\\.", "^wss?://192\\.168\\.", "^wss?://169\\.254\\.",
                        // WebKit content rules do not support alternation.
                        "^wss?://100\\.6[4-9]\\.", "^wss?://100\\.[7-9][0-9]\\.",
                        "^wss?://100\\.1[01][0-9]\\.", "^wss?://100\\.12[0-7]\\.",
                        "^wss?://198\\.1[89]\\.",
                        "^wss?://([a-z0-9-]+\\.)*localhost\\.?[:/]",
                        "^wss?://([a-z0-9-]+\\.)*local\\.?[:/]", "^wss?://[a-z0-9-]+(:[0-9]+)?/"]
        patterns += (16...31).map { "^wss?://172\\.\($0)\\." }
        let rules = patterns.map { ["trigger": ["url-filter": $0], "action": ["type": "block"]] }
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }()

    /// WKContentRuleList JSON: block every http(s)/ws(s)/file load, then let allowlisted hosts through.
    public static func networkRules(allow entries: [String]) -> String {
        var rules: [[String: Any]] = ["^https?:", "^wss?:", "^file:"].map {
            ["trigger": ["url-filter": $0], "action": ["type": "block"]]
        }
        for pattern in exceptionPatterns(allow: entries) {
            rules.append(["trigger": ["url-filter": pattern], "action": ["type": "ignore-previous-rules"]])
        }
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
