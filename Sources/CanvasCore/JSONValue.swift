import Foundation

/// Schema-faithful JSON value. Object props stay as JSON so the Swift side never drifts
/// from schema/easl-api.json; typed accessors live next to the code that needs them.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var int: Int? { number.map { Int($0) } }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Shallow merge used by object.update: keys in `patch` replace keys in self; `null` deletes.
    public func merging(_ patch: JSONValue) -> JSONValue {
        guard case .object(var base) = self, case .object(let changes) = patch else { return patch }
        for (key, value) in changes {
            if value == .null { base.removeValue(forKey: key) } else { base[key] = value }
        }
        return .object(base)
    }

    /// Round-trips any Encodable through JSON. Hot paths build their values directly instead
    /// (`init(_: CanvasObject)`): the round trip re-parses everything it just wrote.
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}

extension JSONValue {
    /// An object as its `Codable` form encodes (`JSONValue.encode(object)` gives the same value),
    /// built without encoding: `props` is already JSON, so the API's board manifests, write
    /// results and events cost a few dictionary inserts per object rather than a re-parse of
    /// every prop.
    public init(_ object: CanvasObject) {
        var fields: [String: JSONValue] = [
            "id": .string(object.id), "type": .string(object.type.rawValue), "frame": JSONValue(object.frame),
            "z": .number(object.z), "rev": .number(Double(object.rev)), "createdBy": JSONValue(object.createdBy),
            // JSONEncoder's default date strategy: seconds since the reference date.
            "createdAt": .number(object.createdAt.timeIntervalSinceReferenceDate),
            "updatedAt": .number(object.updatedAt.timeIntervalSinceReferenceDate), "props": object.props,
        ]
        if let parent = object.parent { fields["parent"] = .string(parent) }
        if let updatedBy = object.updatedBy { fields["updatedBy"] = JSONValue(updatedBy) }
        self = .object(fields)
    }

    public init(_ frame: Frame) {
        self = .object(["x": .number(frame.x), "y": .number(frame.y), "w": .number(frame.w), "h": .number(frame.h)])
    }

    public init(_ actor: Actor) {
        switch actor {
        case .user: self = .object(["kind": .string("user")])
        case .agent(let tile): self = .object(["kind": .string("agent"), "tile": .string(tile)])
        }
    }
}
