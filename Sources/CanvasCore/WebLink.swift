import Foundation

/// Web addresses as links: which text is one, and when two spellings are the same page.
public enum WebLink {
    /// The http(s) URL `text` is, with a host; nil for anything else (other schemes, relative
    /// paths, bare hosts).
    public static func parse(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), isWeb(url) else { return nil }
        return url
    }

    /// An http or https URL with a host.
    public static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host?.isEmpty == false
    }

    /// The address as browser tiles are compared (`Board.openLink`): scheme and host lowercased,
    /// a default port dropped, an empty path `/`; a `file:` URL's path standardized (`./`, `..`)
    /// and `file://localhost/` as `file:///`. The query and the fragment stay as written (a
    /// single-page app's `#/route` is another page). Nil for a URL that is neither http(s) nor `file:`.
    public static func address(_ url: URL) -> String? {
        if url.isFileURL {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            parts.scheme = "file"
            parts.host = ""
            parts.path = url.standardizedFileURL.path
            return parts.string
        }
        guard isWeb(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = parts.scheme?.lowercased() else { return nil }
        parts.scheme = scheme
        parts.host = parts.host?.lowercased()
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        return parts.string
    }

    /// An http(s) URL found in text: its UTF-16 range in that text and the address.
    public struct Match: Equatable, Sendable {
        public var range: NSRange
        public var url: URL
    }

    /// Every http(s) URL in `text`, as one reads it in a comment, a string or a Markdown line: it
    /// ends at white space, a quote, a backtick, a backslash or an angle bracket (`<https://…>`),
    /// loses trailing sentence punctuation, and loses a closing bracket that nothing in the URL
    /// opened (`(see https://a.com/x)` but `https://en.wikipedia.org/wiki/Foo_(bar)` whole).
    public static func matches(in text: String) -> [Match] {
        let string = text as NSString
        var found: [Match] = []
        var from = 0
        while from < string.length {
            let search = NSRange(location: from, length: string.length - from)
            let start = string.range(of: "http", options: [.caseInsensitive, .literal], range: search)
            guard start.location != NSNotFound else { break }
            from = start.location + start.length
            guard hasScheme(string, at: start.location), boundary(string, before: start.location) else { continue }
            var end = start.location
            while end < string.length, !stops.contains(string.character(at: end)) { end += 1 }
            end = trimmed(string, from: start.location, to: end)
            guard end > start.location else { continue }
            let range = NSRange(location: start.location, length: end - start.location)
            if let url = parse(string.substring(with: range)) { found.append(Match(range: range, url: url)) }
            from = max(from, end)
        }
        return found
    }

    /// The URL whose characters include the one at UTF-16 `offset` of `text`.
    public static func match(in text: String, at offset: Int) -> Match? {
        matches(in: text).first { $0.range.location <= offset && offset < $0.range.location + $0.range.length }
    }

    private static let stops: Set<unichar> = Set(" \t\r\n<>\"'`\\".utf16)

    /// `http://` or `https://` at `index`.
    private static func hasScheme(_ string: NSString, at index: Int) -> Bool {
        let rest = NSRange(location: index, length: string.length - index)
        for prefix in ["https://", "http://"] where string.range(of: prefix, options: [.caseInsensitive, .anchored], range: rest).location != NSNotFound {
            return true
        }
        return false
    }

    /// The URL doesn't start in the middle of a word (`xhttp://`).
    private static func boundary(_ string: NSString, before index: Int) -> Bool {
        guard index > 0, let scalar = Unicode.Scalar(string.character(at: index - 1)) else { return true }
        return !CharacterSet.alphanumerics.contains(scalar)
    }

    /// Closing brackets `)` `]` `}` and the opening one each pairs with.
    private static let closers: [unichar: unichar] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]
    private static let trailing: Set<unichar> = Set(".,;:!?'*".utf16)

    /// `end` pulled back over trailing punctuation and unmatched closing brackets.
    private static func trimmed(_ string: NSString, from start: Int, to end: Int) -> Int {
        var end = end
        while end > start {
            let last = string.character(at: end - 1)
            if trailing.contains(last) {
                end -= 1
            } else if let opener = closers[last] {
                var opened = 0, closed = 0
                for index in start..<end {
                    let unit = string.character(at: index)
                    if unit == opener { opened += 1 } else if unit == last { closed += 1 }
                }
                if closed > opened { end -= 1 } else { break }
            } else {
                break
            }
        }
        return end
    }
}

extension Board {
    /// A web link the user or an agent followed, shown in a browser tile beside `source`: the
    /// tile already showing the same address (`WebLink.address`, compared with each browser
    /// tile's `props.url`; another profile or an explicitly chosen drawing identity is another
    /// page) is returned as it is (`existing`) and nothing is created; otherwise a browser tile
    /// with that `url` and `props` is placed beside `source`
    /// (`place`) and credited to `caller`. Only http(s) and `file:` addresses are matched.
    /// `matchingFilePath` lets a terminal reference reuse a file page at any query or fragment.
    @discardableResult
    public func openLink(_ url: URL, near source: ObjectID?, caller: ObjectID?, props: [String: JSONValue] = [:],
                         matchingFilePath: Bool = false) -> (object: CanvasObject, existing: Bool) {
        func address(_ url: URL) -> String? {
            guard matchingFilePath, url.isFileURL,
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return WebLink.address(url) }
            parts.query = nil
            parts.fragment = nil
            return parts.url.flatMap(WebLink.address)
        }
        let wanted = address(url)
        let here = source.flatMap { objects[$0]?.frame }
        let machine = props["drawingMachine"]?["id"]?.string
        let shown = wanted == nil ? [] : objects.values.filter { object in
            object.type == .browser && object.props["profile"]?.string == props["profile"]?.string
                && (machine == nil || DrawingMachine(object.props)?.id == machine)
                && object.props["url"]?.string.flatMap(URL.init(string:)).flatMap(address) == wanted
        }
        // Several tiles can show one address (the user made a second on purpose): the nearest.
        if let reused = shown.min(by: { (here.map($0.frame.centerDistance) ?? 0, $0.id) < (here.map($1.frame.centerDistance) ?? 0, $1.id) }) {
            return (reused, true)
        }
        var all = props
        all["url"] = .string(url.absoluteString)
        let size = Self.defaultSize(.browser)
        return (create(type: .browser, props: .object(all), frame: place(width: size.w, height: size.h, near: source), caller: caller), false)
    }
}
