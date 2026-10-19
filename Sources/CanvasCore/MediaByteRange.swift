import Foundation

public struct MediaByteRange: Sendable, Equatable {
    public enum Failure: Error { case unsatisfiable }

    public let bytes: Range<Int64>
    public let partial: Bool
    public var count: Int64 { bytes.upperBound - bytes.lowerBound }

    public init(header: String?, size: Int64) throws {
        guard size >= 0 else { throw Failure.unsatisfiable }
        guard let header else {
            bytes = 0..<size
            partial = false
            return
        }
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("bytes="), size > 0 else { throw Failure.unsatisfiable }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw Failure.unsatisfiable }
        func number(_ part: Substring) -> Int64? {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int64(part)
        }
        if parts[0].isEmpty {
            guard let suffix = number(parts[1]), suffix > 0 else { throw Failure.unsatisfiable }
            bytes = max(0, size - suffix)..<size
        } else {
            guard let start = number(parts[0]), start < size else { throw Failure.unsatisfiable }
            if parts[1].isEmpty {
                bytes = start..<size
            } else {
                guard let end = number(parts[1]), end >= start else { throw Failure.unsatisfiable }
                bytes = start..<(min(end, size - 1) + 1)
            }
        }
        partial = true
    }

    public func headers(size: Int64) -> [String: String] {
        var headers = ["Accept-Ranges": "bytes", "Content-Length": String(count)]
        if partial { headers["Content-Range"] = "bytes \(bytes.lowerBound)-\(bytes.upperBound - 1)/\(size)" }
        return headers
    }
}
