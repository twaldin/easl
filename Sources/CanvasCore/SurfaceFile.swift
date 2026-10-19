import Foundation

public struct SurfaceFile: Sendable, Equatable {
    public static let maxCount = 32
    public static let maxBytes = 8 << 20

    public let name: String
    public let type: String
    public let modified: Double?
    public let data: String
    public let byteCount: Int

    public init(name: String, type: String, modified: Double? = nil, bytes: Data) throws {
        guard bytes.count <= Self.maxBytes else { throw Self.invalid("files exceed the 8 MiB upload limit") }
        try Self.checkMetadata(name: name, type: type, modified: modified)
        self.name = name
        self.type = type
        self.modified = modified
        data = bytes.base64EncodedString()
        byteCount = bytes.count
    }

    public init(_ value: JSONValue) throws {
        guard let fields = value.object, fields.keys.allSatisfy({ $0 == "name" || $0 == "type" || $0 == "modified" || $0 == "data" }),
              let name = fields["name"]?.string, let type = fields["type"]?.string, let data = fields["data"]?.string else {
            throw Self.invalid("a file is {name, type, modified?, data}")
        }
        let modified: Double?
        if let value = fields["modified"] {
            guard let number = value.number else { throw Self.invalid("file modified must be a number") }
            modified = number
        } else {
            modified = nil
        }
        try Self.checkMetadata(name: name, type: type, modified: modified)
        let count = try Self.decodedSize(data)
        guard count <= Self.maxBytes else { throw Self.invalid("files exceed the 8 MiB upload limit") }
        self.name = name
        self.type = type
        self.modified = modified
        self.data = data
        byteCount = count
    }

    public var json: JSONValue {
        var fields: [String: JSONValue] = ["name": .string(name), "type": .string(type), "data": .string(data)]
        if let modified { fields["modified"] = .number(modified) }
        return .object(fields)
    }

    public static func parse(_ value: JSONValue?) throws -> [SurfaceFile]? {
        guard let value else { return nil }
        guard let values = value.array, !values.isEmpty, values.count <= maxCount else {
            throw invalid("files must be an array of 1 to \(maxCount) files")
        }
        var bytes = 0
        return try values.map { value in
            let file = try SurfaceFile(value)
            bytes += file.byteCount
            guard bytes <= maxBytes else { throw invalid("files exceed the 8 MiB upload limit") }
            return file
        }
    }

    private static func checkMetadata(name: String, type: String, modified: Double?) throws {
        guard !name.isEmpty, name.utf8.count <= 1024, type.utf8.count <= 256 else {
            throw invalid("file name must contain 1 to 1024 UTF-8 bytes and type at most 256")
        }
        if let modified, !modified.isFinite || modified < 0 {
            throw invalid("file modified must be a finite nonnegative timestamp")
        }
    }

    private static func decodedSize(_ data: String) throws -> Int {
        let count = data.utf8.count
        guard count <= ((maxBytes + 2) / 3) * 4, count % 4 == 0 else { throw invalid("file data must be bounded base64") }
        var padding = 0
        for byte in data.utf8 {
            if byte == 61 {
                padding += 1
                guard padding <= 2 else { throw invalid("file data must be base64") }
            } else {
                guard padding == 0, (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 43 || byte == 47 else {
                    throw invalid("file data must be base64")
                }
            }
        }
        return count / 4 * 3 - padding
    }

    private static func invalid(_ message: String) -> ApiRouter.Failure {
        ApiRouter.Failure("invalid_params", message)
    }
}
