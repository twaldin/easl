import Foundation

/// A note code fence's info string (docs/design.md "Notes"). Every mode is plain markdown, so
/// agents read and write them without an SDK:
///
///     ```ts file=src/app.ts#L10-40                  excerpt, rendered live from disk
///     ```swift file=Sources/Board.swift symbol=Board.update
///     ```ts symbol=restoreSnapshot                  symbol searched across the workspace
///     ```ts file=src/app.ts@1a2b3c4#L10-40          pinned to a commit (read via `git show`)
///     ```ts file=src/app.ts#L10-40 propose          proposed change: diff of the range → body
///     ```ts file=src/app.ts#L10-40 anchor="export function load() {"
///     ```ts                                         free-written
public struct NoteFence: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case free, excerpt, propose
    }

    public var language: String?
    public var path: String?
    public var commit: String?
    public var lines: LineRange?
    public var symbol: String?
    /// Text of the range's first line, used to re-find the range after lines move.
    public var anchor: String?
    public var propose: Bool

    public init(language: String? = nil, path: String? = nil, commit: String? = nil, lines: LineRange? = nil, symbol: String? = nil, anchor: String? = nil, propose: Bool = false) {
        self.language = language
        self.path = path
        self.commit = commit
        self.lines = lines
        self.symbol = symbol
        self.anchor = anchor
        self.propose = propose
    }

    public init(info: String) {
        self.init()
        for token in Self.tokens(info) {
            guard let equals = token.firstIndex(of: "=") else {
                if token == "propose" { propose = true } else if language == nil { language = token }
                continue
            }
            let key = token[..<equals]
            let value = Self.unquote(token[token.index(after: equals)...])
            switch key {
            case "file", "path": parseLocation(value)
            case "symbol": symbol = value.isEmpty ? nil : value
            case "anchor": anchor = value.isEmpty ? nil : value
            case "commit": commit = value.isEmpty ? nil : value
            case "lines": lines = Self.lineRange(value)
            default: break
            }
        }
    }

    public var mode: Mode {
        guard path != nil || symbol != nil else { return .free }
        return propose ? .propose : .excerpt
    }

    /// `path[@commit][#L10[-L40]]`. A path segment may itself contain `@` (`node_modules/@types`),
    /// so only a trailing `@ref` without a slash is a commit.
    private mutating func parseLocation(_ value: String) {
        var rest = Substring(value)
        if let hash = rest.lastIndex(of: "#"), let first = rest[rest.index(after: hash)...].first, first == "L" || first.isNumber {
            // An unusable range (`#L0`, `#L9-7`) leaves a whole-file excerpt rather than a bogus path.
            lines = Self.lineRange(String(rest[rest.index(after: hash)...]))
            rest = rest[..<hash]
        }
        if let at = rest.lastIndex(of: "@"), at != rest.startIndex {
            let ref = rest[rest.index(after: at)...]
            if !ref.isEmpty, !ref.contains("/"), ref.allSatisfy({ $0.isLetter || $0.isNumber || "._~^-".contains($0) }) {
                commit = String(ref)
                rest = rest[..<at]
            }
        }
        path = rest.isEmpty ? nil : String(rest)
    }

    /// `L10`, `L10-40`, `L10-L40`, `10-40`.
    static func lineRange(_ text: String) -> LineRange? {
        let parts = text.split(separator: "-", maxSplits: 1).map { $0.hasPrefix("L") ? $0.dropFirst() : $0 }
        guard let first = parts.first, let start = Int(first), start >= 1 else { return nil }
        guard parts.count == 2 else { return LineRange(start: start, end: start) }
        guard let end = Int(parts[1]), end >= start else { return nil }
        return LineRange(start: start, end: end)
    }

    /// Whitespace-separated tokens; `key="a b"` and `key='a b'` keep their spaces, `\"` escapes.
    static func tokens(_ info: String) -> [String] {
        tokenRanges(info).map { String(info[$0]) }
    }

    static func tokenRanges(_ info: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var quote: Character?
        var escaped = false
        for index in info.indices {
            let character = info[index]
            if start == nil, !character.isWhitespace { start = index }
            if escaped {
                // The escaped character cannot end a quote.
                escaped = false
            } else if character == "\\", quote != nil {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if let first = start { ranges.append(first..<index) }
                start = nil
            }
        }
        if let start { ranges.append(start..<info.endIndex) }
        return ranges
    }

    /// Inside quotes, `\` escapes only the quote and itself; any other backslash is literal,
    /// so code like `split("\d")` survives in an anchor.
    static func unquote(_ value: Substring) -> String {
        guard let first = value.first, first == "\"" || first == "'", value.count >= 2, value.last == first else { return String(value) }
        let inner = Array(value.dropFirst().dropLast())
        var out = ""
        var index = 0
        while index < inner.count {
            if inner[index] == "\\", index + 1 < inner.count, inner[index + 1] == first || inner[index + 1] == "\\" {
                index += 1
            }
            out.append(inner[index])
            index += 1
        }
        return out
    }
}

/// `path:line` and `path:start-end` references in free-written text, which the note makes
/// clickable (they open a code tile beside it).
public enum NoteReferences {
    public struct Reference: Equatable, Sendable {
        /// UTF-16 range of the whole reference in the searched string.
        public var range: NSRange
        public var path: String
        public var lines: LineRange
    }

    // A path needs a file extension, so `localhost:3000` and `12:30` never match; the lookbehind
    // keeps `https://example.com:443` out.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\w./@:~-])((?:~|\.{1,2})?/?(?:[\w@.+-]+/)*[\w@+-][\w@.+-]*\.[A-Za-z][A-Za-z0-9]*):(\d+)(?:-(\d+))?(?!\d)"#)

    public static func find(in text: String) -> [Reference] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let start = Int(ns.substring(with: match.range(at: 2))), start >= 1 else { return nil }
            let endRange = match.range(at: 3)
            let end = endRange.location == NSNotFound ? start : Int(ns.substring(with: endRange)) ?? start
            return Reference(range: match.range, path: ns.substring(with: match.range(at: 1)), lines: LineRange(start: start, end: max(start, end)))
        }
    }
}
