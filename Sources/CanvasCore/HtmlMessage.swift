import Foundation

/// A message from an HTML tile's page over its one native channel (`canvas` script handler).
/// Pages are agent-generated and untrusted, so every message is parsed against a strict schema:
/// a known `type`, only that type's fields, bounded sizes. Anything else is rejected.
public enum HtmlMessage: Equatable, Sendable {
    /// `<canvas-code>`: a grounded excerpt read from disk.
    case excerpt(path: String, lines: LineRange?, symbol: String?)
    /// `<canvas-code>` / `<canvas-link>` click: open (or re-aim) a code tile beside the HTML tile.
    case openCode(path: String, lines: LineRange?, symbol: String?)
    /// Tile state (`props.state`): one key, or the whole object when `key` is nil.
    case getState(key: String?)
    /// Persist one state key; `null` removes it.
    case setState(key: String, value: JSONValue)
    /// Submit saved fields as one gesture-authorized instruction.
    case submit(keys: [String])
    /// The page finished (re)rendering or scrolling; the tile refreshes its snapshot.
    case rendered(scrollY: Double?)
    /// `canvasKit.send(payload)`: hand a JSON value to the agent terminal that created the tile.
    case send(payload: JSONValue)
    case goTo(ObjectTarget)

    public static let maxMessageBytes = 64 * 1024
    public static let maxStateValueBytes = 16 * 1024
    public static let maxPathLength = 1024
    public static let maxSymbolLength = 200
    public static let maxLine = 10_000_000

    private static let fields: [String: Set<String>] = [
        "code.excerpt": ["path", "lines", "symbol"],
        "code.open": ["path", "lines", "symbol"],
        "state.get": ["key"],
        "state.set": ["key", "value"],
        "state.submit": ["keys"],
        "view.rendered": ["scrollY"],
        "send": ["payload"],
        "object.goTo": ["id", "key"],
    ]

    /// Parses the serialized message body. The size cap applies before any decoding.
    public static func parse(_ data: Data) throws -> HtmlMessage {
        guard data.count <= maxMessageBytes else { throw HtmlError.tooLarge(data.count, limit: maxMessageBytes) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw HtmlError.malformed("not JSON") }
        return try parse(value)
    }

    public static func parse(_ value: JSONValue) throws -> HtmlMessage {
        guard let object = value.object else { throw HtmlError.malformed("message must be an object") }
        guard let type = object["type"]?.string else { throw HtmlError.malformed("missing type") }
        guard let allowed = fields[type] else { throw HtmlError.unknownType(type) }
        if let extra = object.keys.filter({ $0 != "type" && !allowed.contains($0) }).sorted().first {
            throw HtmlError.unexpectedField(extra)
        }
        switch type {
        case "object.goTo":
            return .goTo(try ObjectTarget.parse(object))
        case "code.excerpt":
            return .excerpt(path: try path(object), lines: try lines(object), symbol: try symbol(object))
        case "code.open":
            return .openCode(path: try path(object), lines: try lines(object), symbol: try symbol(object))
        case "state.get":
            return .getState(key: object["key"] == nil ? nil : try key(object["key"]))
        case "state.set":
            let key = try key(object["key"])
            guard key != "submitted" else { throw HtmlError.invalidField("key", "submitted is reserved for Submit") }
            guard let value = object["value"] else { throw HtmlError.invalidField("value", "required") }
            let size = (try? JSONEncoder().encode(value).count) ?? Int.max
            guard size <= maxStateValueBytes else { throw HtmlError.tooLarge(size, limit: maxStateValueBytes) }
            return .setState(key: key, value: value)
        case "state.submit":
            guard let values = object["keys"]?.array, values.allSatisfy({ $0.string != nil }) else {
                throw HtmlError.invalidField("keys", "must be an array of state keys")
            }
            let keys = values.compactMap(\.string)
            try checkSubmitKeys(keys)
            return .submit(keys: keys)
        case "send":
            guard let payload = object["payload"] else { throw HtmlError.invalidField("payload", "required") }
            try checkPayload(payload)
            return .send(payload: payload)
        default:
            guard let raw = object["scrollY"] else { return .rendered(scrollY: nil) }
            guard let y = raw.number, y.isFinite, y >= 0, y <= 10_000_000 else { throw HtmlError.invalidField("scrollY", "must be a number between 0 and 10000000") }
            return .rendered(scrollY: y)
        }
    }

    private static func path(_ object: [String: JSONValue]) throws -> String {
        guard let path = object["path"]?.string, !path.isEmpty else { throw HtmlError.invalidField("path", "required string") }
        guard path.utf8.count <= maxPathLength else { throw HtmlError.invalidField("path", "longer than \(maxPathLength) bytes") }
        guard !path.contains("\0") else { throw HtmlError.invalidField("path", "contains NUL") }
        return path
    }

    /// `"12"` or `"10-40"` (1-based, inclusive), as written in component attributes.
    private static func lines(_ object: [String: JSONValue]) throws -> LineRange? {
        guard let raw = object["lines"] else { return nil }
        guard let text = raw.string, let range = parseLines(text) else {
            throw HtmlError.invalidField("lines", "must be \"N\" or \"N-M\" with 1 <= N <= M")
        }
        return range
    }

    public static func parseLines(_ text: String) -> LineRange? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 8 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let start = Int(parts[0]), let end = Int(parts.last!), start >= 1, end >= start, end <= maxLine else { return nil }
        return LineRange(start: start, end: end)
    }

    /// Identifiers, optionally qualified (`Board.update`, `mod::func`).
    private static func symbol(_ object: [String: JSONValue]) throws -> String? {
        guard let raw = object["symbol"] else { return nil }
        guard let symbol = raw.string, !symbol.isEmpty, symbol.count <= maxSymbolLength,
              symbol.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_$.:".unicodeScalars.contains($0) }) else {
            throw HtmlError.invalidField("symbol", "must be an identifier of at most \(maxSymbolLength) characters")
        }
        return symbol
    }

    private static func key(_ value: JSONValue?) throws -> String {
        guard let key = value?.string, (1...128).contains(key.count),
              key.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.:-".unicodeScalars.contains($0)) }) else {
            throw HtmlError.invalidField("key", "must be 1-128 characters of [A-Za-z0-9_.:-]")
        }
        return key
    }

    static func checkSubmitKeys(_ keys: [String]) throws {
        guard (1...16).contains(keys.count), Set(keys).count == keys.count else {
            throw HtmlError.invalidField("keys", "must contain 1-16 distinct state keys")
        }
        for name in keys {
            _ = try key(.string(name))
            guard name != "submitted", name != "applied" else {
                throw HtmlError.invalidField("keys", "submitted and applied cannot be submitted")
            }
        }
    }

    static func checkPayload(_ payload: JSONValue) throws {
        let size = (try? JSONEncoder().encode(payload).count) ?? Int.max
        guard size <= maxMessageBytes else { throw HtmlError.tooLarge(size, limit: maxMessageBytes) }
    }
}

public enum HtmlError: Error, Equatable, CustomStringConvertible {
    case tooLarge(Int, limit: Int)
    case malformed(String)
    case unknownType(String)
    case unexpectedField(String)
    case invalidField(String, String)
    case outsideRoot(String)
    case notFound(String)
    case unavailable(String)
    /// Too much outstanding work from this page; retry after earlier replies arrive.
    case busy
    /// The tile detached before the work finished.
    case cancelled
    /// A page send was refused because a queue or rate cap was already full. Nothing was kept.
    case overBudget(String)

    public var description: String {
        switch self {
        case .tooLarge(let size, let limit): "message too large (\(size) bytes, limit \(limit))"
        case .malformed(let why): "malformed message: \(why)"
        case .unknownType(let type): "unknown message type \(type)"
        case .unexpectedField(let field): "unexpected field \(field)"
        case .invalidField(let field, let why): "invalid \(field): \(why)"
        case .outsideRoot(let path): "\(path) is outside the board root"
        case .notFound(let path): "\(path) not found"
        case .unavailable(let reason): reason
        case .busy: "too many outstanding requests"
        case .cancelled: "cancelled"
        case .overBudget(let reason): reason
        }
    }
}
