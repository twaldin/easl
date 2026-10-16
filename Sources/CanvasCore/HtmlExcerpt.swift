import Foundation

/// A grounded excerpt of a file on disk, anchored by a line range and/or a symbol, as rendered by
/// `<canvas-code>`. Symbols win over lines (lines drift, names rarely do); when the anchor can't
/// be found the excerpt is `stale` and says why instead of showing the wrong code.
public struct SourceExcerpt: Codable, Equatable, Sendable {
    public var path: String
    /// 1-based inclusive range of `lines` in the file; 0...0 when nothing could be shown.
    public var start: Int
    public var end: Int
    public var lines: [String]
    public var symbol: String?
    public var language: String?
    public var stale: Bool
    public var reason: String?
    /// The anchored range was longer than `maxLines`; `lines` holds its beginning.
    public var truncated: Bool

    public static let maxLines = 400
    public static let maxFileBytes = 4 * 1024 * 1024

    /// Reads and resolves; never throws, because a missing file is a stale excerpt, not an error.
    public static func load(url: URL, path: String, lines: LineRange?, symbol: String?) -> SourceExcerpt {
        let language = language(for: path)
        func failed(_ reason: String) -> SourceExcerpt {
            SourceExcerpt(path: path, start: 0, end: 0, lines: [], symbol: symbol, language: language, stale: true, reason: reason, truncated: false)
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return failed("\(path) not found") }
        guard (attributes[.size] as? Int ?? 0) <= maxFileBytes else { return failed("\(path) is larger than \(maxFileBytes / 1024 / 1024) MB") }
        guard let data = try? Data(contentsOf: url) else { return failed("\(path) is unreadable") }
        guard !data.prefix(8192).contains(0) else { return failed("\(path) is a binary file") }
        // The page that asked went away while reading; skip the (possibly large) symbol search.
        guard !Task.isCancelled else { return failed("cancelled") }
        return resolve(text: String(decoding: data, as: UTF8.self), path: path, lines: lines, symbol: symbol)
    }

    public static func from(_ file: HostFile, path: String, lines: LineRange?, symbol: String?) -> SourceExcerpt {
        if let commit = file.commit {
            guard let text = String(data: file.data, encoding: .utf8) else {
                return failed(path: path, symbol: symbol, reason: "\(path) not found at \(commit.prefix(7))")
            }
            return resolve(text: text, path: path, lines: lines, symbol: symbol)
        }
        guard !file.data.prefix(8192).contains(0) else {
            return failed(path: path, symbol: symbol, reason: "\(path) is a binary file")
        }
        guard !Task.isCancelled else { return failed(path: path, symbol: symbol, reason: "cancelled") }
        return resolve(text: String(decoding: file.data, as: UTF8.self), path: path, lines: lines, symbol: symbol)
    }

    static func failed(path: String, symbol: String?, reason: String) -> SourceExcerpt {
        SourceExcerpt(path: path, start: 0, end: 0, lines: [], symbol: symbol, language: language(for: path), stale: true, reason: reason, truncated: false)
    }

    public static func resolve(text: String, path: String, lines range: LineRange?, symbol: String?) -> SourceExcerpt {
        var fileLines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        if text.hasSuffix("\n") { fileLines.removeLast() }
        let language = language(for: path)
        var excerpt = SourceExcerpt(path: path, start: 0, end: 0, lines: [], symbol: symbol, language: language, stale: false, reason: nil, truncated: false)
        func show(_ start: Int, _ end: Int) {
            excerpt.start = start
            excerpt.end = min(end, start + maxLines - 1)
            excerpt.truncated = excerpt.end < end
            excerpt.lines = Array(fileLines[(start - 1)..<excerpt.end])
        }

        if let symbol {
            if let found = symbolRange(symbol, in: fileLines, language: language) {
                show(found.start, found.end)
                return excerpt
            }
            excerpt.stale = true
            excerpt.reason = "symbol \(symbol) not found in \(path)"
            guard range != nil else { return excerpt }
        }
        guard let range else {
            if !fileLines.isEmpty { show(1, fileLines.count) }
            return excerpt
        }
        guard range.start <= fileLines.count else {
            excerpt.stale = true
            excerpt.reason = (excerpt.reason.map { $0 + "; " } ?? "") + "lines \(range.start)-\(range.end) are past the end of \(path) (\(fileLines.count) lines)"
            return excerpt
        }
        if range.end > fileLines.count {
            excerpt.stale = true
            excerpt.reason = (excerpt.reason.map { $0 + "; " } ?? "") + "\(path) has only \(fileLines.count) lines"
        }
        show(range.start, min(range.end, fileLines.count))
        return excerpt
    }

    // MARK: Symbols

    /// Declaration keywords across the languages agents commonly write in (`DeclarationKeywords`,
    /// bindings too). This is a textual search, not a parse: good enough to anchor an excerpt,
    /// and a miss is reported as stale.
    private static let modifiers = #"(?:(?:export|default|public|private|internal|fileprivate|open|static|final|async|override|abstract|protected|mutating|nonisolated|readonly|declare|extern|inline|virtual|unsafe|pub(?:\([^)]*\))?|@[\w.]+(?:\([^)]*\))?)\s+)*"#
    private static let keywords = "(?:" + DeclarationKeywords.alternation(DeclarationKeywords.kinds.keys) + ")"

    /// 1-based inclusive range of a declaration, including the doc comments and attributes
    /// directly above it. `Outer.inner` (or `Outer::inner`) finds `inner` inside `Outer`.
    public static func symbolRange(_ symbol: String, in lines: [String], language: String?) -> LineRange? {
        let parts = symbol.replacingOccurrences(of: "::", with: ".").split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return nil }
        var window = 0..<lines.count
        var found: (decl: Int, end: Int)?
        for (depth, name) in parts.enumerated() {
            let searchFrom = depth == 0 ? window.lowerBound : window.lowerBound + 1
            guard searchFrom < window.upperBound, let decl = declaration(of: name, in: lines, range: searchFrom..<window.upperBound) else { return nil }
            let end = extent(from: decl, in: lines, language: language)
            found = (decl, end)
            window = decl..<(end + 1)
        }
        guard let found else { return nil }
        var start = found.decl
        while start > 0, isPreamble(lines[start - 1]) { start -= 1 }
        return LineRange(start: start + 1, end: found.end + 1)
    }

    private static func declaration(of name: String, in lines: [String], range: Range<Int>) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            #"^\s*"# + modifiers + keywords + #"\s+"# + escaped + #"(?![\w$])"#,
            // Go methods: func (r *T) Name(
            #"^\s*func\s+\([^)]*\)\s*"# + escaped + #"\s*\("#,
            // Class members declared without a keyword (JS/TS methods): name(args) {
            #"^\s*(?:(?:public|private|protected|static|async|readonly|override|get|set)\s+)*"# + escaped + #"\s*(?:<[^>]*>)?\s*\([^)]*\)\s*(?::[^{=]+)?\{\s*$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for index in range {
                let line = lines[index]
                if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { return index }
            }
        }
        return nil
    }

    private static func isPreamble(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return ["///", "//", "/**", "/*", "*", "@", "#["].contains { trimmed.hasPrefix($0) }
    }

    /// Last line (0-based) of the declaration starting at `start`: brace-matched for brace
    /// languages, indentation-based for Python-like blocks, else the (possibly continued) line.
    private static func extent(from start: Int, in lines: [String], language: String?) -> Int {
        var braces = 0, parens = 0
        var opened = false, inBlockComment = false
        let indentBlock = language == "python" || lines[start].trimmingCharacters(in: .whitespaces).hasSuffix(":")
        var index = start
        while index < lines.count {
            let chars = Array(lines[index])
            var i = 0
            var quote: Character?
            while i < chars.count {
                let c = chars[i]
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if inBlockComment {
                    if c == "*", next == "/" { inBlockComment = false; i += 1 }
                } else if let open = quote {
                    if c == "\\" { i += 1 } else if c == open { quote = nil }
                } else if c == "/", next == "/" {
                    break
                } else if c == "/", next == "*" {
                    inBlockComment = true
                    i += 1
                } else if c == "#", indentBlock {
                    break
                } else if c == "\"" || c == "'" || c == "`" {
                    quote = c
                } else if c == "(" || c == "[" {
                    parens += 1
                } else if c == ")" || c == "]" {
                    parens -= 1
                } else if c == "{", !indentBlock {
                    braces += 1
                    opened = true
                } else if c == "}", !indentBlock {
                    braces -= 1
                    if opened, braces <= 0 { return index }
                }
                i += 1
            }
            if !opened, parens <= 0 {
                if indentBlock { return indentedEnd(from: index, declIndent: indent(lines[start]), in: lines) }
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                let continues = ["(", ",", "=", "->", "=>", ":", "<", "&&", "||", "+"].contains { trimmed.hasSuffix($0) }
                    || (index + 1 < lines.count && lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix("{"))
                if !continues { return index }
            }
            index += 1
        }
        return lines.count - 1
    }

    /// For indentation blocks: the last non-blank line indented deeper than the declaration.
    private static func indentedEnd(from header: Int, declIndent: Int, in lines: [String]) -> Int {
        var last = header
        for index in (header + 1)..<max(header + 1, lines.count) {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if indent(line) <= declIndent { break }
            last = index
        }
        return last
    }

    private static func indent(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    public static func language(for path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "ts", "tsx", "mts", "cts": "typescript"
        case "js", "jsx", "mjs", "cjs": "javascript"
        case "py": "python"
        case "rs": "rust"
        case "go": "go"
        case "rb": "ruby"
        case "java": "java"
        case "kt", "kts": "kotlin"
        case "c", "h": "c"
        case "cc", "cpp", "cxx", "hpp", "hh": "cpp"
        case "m", "mm": "objc"
        case "cs": "csharp"
        case "sh", "bash", "zsh": "shell"
        case "json": "json"
        case "yaml", "yml": "yaml"
        case "toml": "toml"
        case "md", "markdown": "markdown"
        case "html", "htm": "html"
        case "css": "css"
        case "sql": "sql"
        case "zig": "zig"
        case "lua": "lua"
        default: nil
        }
    }
}
