import Foundation

/// An object on the source tile's board, named directly or by its board-local key.
public enum ObjectTarget: Equatable, Sendable {
    case id(ObjectID)
    case key(String)

    public static func parse(_ fields: [String: JSONValue]) throws -> ObjectTarget {
        guard (fields["id"] != nil) != (fields["key"] != nil) else {
            throw HtmlError.malformed("exactly one of id or key is required")
        }
        let field = fields["id"] == nil ? "key" : "id"
        guard let value = fields[field]?.string, !value.isEmpty, value.utf8.count <= 1024, !value.contains("\0") else {
            throw HtmlError.invalidField(field, "required nonempty string of at most 1024 bytes without NUL")
        }
        return field == "id" ? .id(value) : .key(value)
    }

    @MainActor
    public func resolve(on board: Board, from source: ObjectID) throws -> ObjectID {
        guard !board.isClosed else { throw HtmlError.unavailable("host closed this board") }
        guard board.objects[source] != nil else { throw HtmlError.notFound("source object on this board") }
        let object: CanvasObject?
        switch self {
        case .id(let id): object = board.objects[id]
        case .key(let key): object = try board.holder(ofKey: key)
        }
        guard let object else { throw HtmlError.notFound("target object on this board") }
        guard !object.isHidden else { throw HtmlError.unavailable("target object is hidden") }
        return object.id
    }

    public var encoded: String {
        let kind: String
        let value: String
        switch self {
        case .id(let id): kind = "object"; value = id
        case .key(let key): kind = "key"; value = key
        }
        let escaped = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return "easl:\(kind)/\(escaped)"
    }

    public init?(encoded: String) {
        let prefix: String
        if encoded.hasPrefix("easl:object/") { prefix = "easl:object/" }
        else if encoded.hasPrefix("easl:key/") { prefix = "easl:key/" }
        else { return nil }
        let raw = String(encoded.dropFirst(prefix.count))
        guard !raw.isEmpty, !raw.contains("/"), !raw.contains("?"), !raw.contains("#"),
              let value = raw.removingPercentEncoding,
              let target = try? Self.parse([prefix == "easl:object/" ? "id" : "key": .string(value)]) else { return nil }
        self = target
    }
}
