import Foundation

public struct ObjectExpiry: Codable, Equatable, Sendable {
    public var date: Date

    public init(_ date: Date) { self.date = date }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = Self.parse(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "expires must be an RFC3339 timestamp")
        }
        self.date = date
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stamp)
    }

    public var stamp: String {
        let seconds = date.timeIntervalSinceReferenceDate
        let whole = Date(timeIntervalSinceReferenceDate: floor(seconds))
        let nanos = Int(((seconds - floor(seconds)) * 1_000_000_000).rounded())
        let fraction = String(format: "%09d", nanos).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        let stamp = QuestionSpec.stamp(whole)
        return String(stamp.dropLast()) + (fraction.isEmpty ? "" : "." + fraction) + "Z"
    }

    public static func parse(_ text: String) -> Date? {
        guard text.range(of: #"^\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])[Tt](?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.\d+)?(?:[Zz]|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])$"#, options: .regularExpression) != nil else { return nil }
        let local = String(text.prefix(19)).uppercased()
        guard let calendarDate = QuestionSpec.date(local + "Z"), QuestionSpec.stamp(calendarDate) == local + "Z" else { return nil }
        guard let point = text.firstIndex(of: ".") else { return QuestionSpec.date(text.uppercased()) }
        let digits = text.index(after: point)
        let end = text[digits...].firstIndex { !$0.isNumber } ?? text.endIndex
        guard let fraction = Double("0." + text[digits..<end]),
              let whole = QuestionSpec.date(String(text[..<point]) + text[end...].uppercased()) else { return nil }
        return whole.addingTimeInterval(fraction)
    }

    public static func duration(_ value: JSONValue) throws -> TimeInterval {
        guard let text = value.string,
              text.range(of: #"^[0-9]+(?:\.[0-9]+)?[smhd]$"#, options: .regularExpression) != nil,
              let amount = Double(text.dropLast()) else {
            throw BoardError.invalidParams("duration must be a nonnegative number followed by s, m, h, or d")
        }
        let multiplier: Double = switch text.last { case "m": 60; case "h": 3600; case "d": 86400; default: 1 }
        let seconds = amount * multiplier
        guard seconds.isFinite, seconds < Double(Int64.max) / 1_000_000_000 else { throw BoardError.invalidParams("duration overflows") }
        return seconds
    }
}

public enum ObjectExpiryPatch: Equatable, Sendable {
    case unchanged
    case set(ObjectExpiry?)

    public init(_ params: JSONValue, now: Date = Date()) throws {
        guard params["expires"] == nil || params["expiresIn"] == nil else {
            throw BoardError.invalidParams("expires and expiresIn are mutually exclusive")
        }
        if let relative = params["expiresIn"] {
            let seconds = try ObjectExpiry.duration(relative)
            let date = now.addingTimeInterval(seconds)
            guard date.timeIntervalSinceReferenceDate.isFinite, date <= Date.distantFuture else {
                throw BoardError.invalidParams("expiresIn overflows")
            }
            self = .set(ObjectExpiry(date))
        } else if let value = params["expires"] {
            if value == .null { self = .set(nil) }
            else if let text = value.string, let date = ObjectExpiry.parse(text) { self = .set(ObjectExpiry(date)) }
            else { throw BoardError.invalidParams("expires must be an RFC3339 timestamp or null") }
        } else { self = .unchanged }
    }
}
