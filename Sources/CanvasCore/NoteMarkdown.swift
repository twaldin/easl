import Foundation
import Markdown

/// Note markdown structure the tile and its persistence need: which fences are anchored, and
/// writing a resolved range's first line back into its fence as `anchor="…"`.
public enum NoteMarkdown {
    /// An anchored fence (excerpt or proposal). Fences with the same info string resolve once.
    public struct AnchoredFence: Equatable, Sendable {
        /// The info string, trimmed: the fence's identity in a note.
        public var key: String
        public var fence: NoteFence
        public var body: [String]
        /// 1-based markdown lines of every opening fence with this info string.
        public var lines: [Int]
    }

    public static func parse(_ markdown: String) -> Document {
        Document(parsing: markdown, options: [.disableSmartOpts])
    }

    /// A section heading: its 1-based markdown line, level (1–6), and plain text.
    public struct Heading: Equatable, Sendable {
        public var line: Int
        public var level: Int
        public var title: String
    }

    /// The note's top-level headings in order (the sections a block sits in, what Go to lists).
    public static func headings(in document: Document) -> [Heading] {
        document.children.compactMap { child in
            guard let heading = child as? Markdown.Heading, let line = heading.range?.lowerBound.line else { return nil }
            return Heading(line: line, level: heading.level, title: heading.plainText)
        }
    }

    /// One line of note markdown as it reads (a chip's words, the title of a note without one):
    /// its inline markup resolved, escapes and entities decoded, a heading's `#`s and a list
    /// marker gone, as `plainText` reads a block. A line with no text (a fence, a rule) as written.
    public static func plainText(ofLine line: some StringProtocol) -> String {
        var node: Markup = parse(String(line))
        while let child = node.child(at: 0) {
            if let inline = child as? InlineContainer { return inline.plainText.trimmingCharacters(in: .whitespaces) }
            node = child
        }
        return line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
    }

    public static func anchoredFences(in document: Document) -> [AnchoredFence] {
        var out: [AnchoredFence] = []
        var index: [String: Int] = [:]
        func walk(_ markup: Markup) {
            if let block = markup as? CodeBlock {
                let key = (block.language ?? "").trimmingCharacters(in: .whitespaces)
                let fence = NoteFence(info: key)
                guard fence.mode != .free else { return }
                let line = block.range?.lowerBound.line
                if let existing = index[key] {
                    if let line { out[existing].lines.append(line) }
                } else {
                    index[key] = out.count
                    out.append(AnchoredFence(key: key, fence: fence, body: NoteSource.lines(of: block.code), lines: line.map { [$0] } ?? []))
                }
                return
            }
            for child in markup.children { walk(child) }
        }
        walk(document)
        return out
    }

    /// A line-range fence the tile anchors: no `anchor=`, `symbol=`, or pinned commit yet.
    public static func needsAnchor(_ fence: AnchoredFence) -> Bool {
        fence.fence.lines != nil && fence.fence.anchor == nil && fence.fence.symbol == nil && fence.fence.commit == nil
    }

    /// `markdown` with each fence that `needsAnchor` anchored at its resolved first line (exact
    /// resolutions only; fences that can't hold it are skipped), as the app writes them back: the
    /// note tile once it shows them, and the API on storing a note, so a note an agent just wrote
    /// isn't rewritten under it (a new `rev`) a moment later. Files are read as `reading` says (a
    /// `ref`), with the tile's `captured` text by fence key, and only inside `areas`: an anchor
    /// never carries text from outside the board, whatever the tile may show.
    public static func anchoringRanges(_ markdown: String, reading: LinkReading, within areas: BoardAreas, captured: [String: [String]] = [:]) async -> String {
        let fences = anchoredFences(in: parse(markdown)).filter(needsAnchor)
        guard !fences.isEmpty else { return markdown }
        let results = await NoteSource.excerpts(for: reading.fences(fences), root: reading.root, captured: captured, within: areas)
        var text = markdown
        for fence in fences {
            guard let excerpt = results[fence.key], excerpt.status == .exact, let first = excerpt.lines.first,
                  let anchored = anchoring(text, fenceLines: fence.lines, anchor: first) else { continue }
            text = anchored
        }
        return text
    }

    /// `object.get`'s `fences` for a note: each anchored fence as written (its info string, the
    /// markdown lines opening it, `symbol`, `commit`, whether it proposes) with how it resolves
    /// now (`NoteExcerpt.statusJSON`); `path` is the file a symbol search found, else as written.
    public static func status(of fences: [AnchoredFence], excerpts: [String: NoteExcerpt]) -> JSONValue {
        .array(fences.map { fence in
            var out: [String: JSONValue] = [
                "info": .string(fence.key),
                "markdownLines": .array(fence.lines.map { .number(Double($0)) }),
                "propose": .bool(fence.fence.mode == .propose),
            ]
            if let symbol = fence.fence.symbol { out["symbol"] = .string(symbol) }
            if let commit = fence.fence.commit { out["commit"] = .string(commit) }
            let excerpt = excerpts[fence.key]
            if let path = excerpt.flatMap({ $0.path.isEmpty ? nil : $0.path }) ?? fence.fence.path { out["path"] = .string(path) }
            if let excerpt { out.merge(excerpt.statusJSON) { $1 } }
            return .object(out)
        })
    }

    /// `markdown` with ` anchor="…"` appended to the opening fence lines `fenceLines` (1-based),
    /// or nil when the anchor can't be written there: a backtick fence can't hold a backtick in
    /// its info string, and a multi-line or blank anchor anchors nothing.
    ///
    /// CommonMark processes backslash escapes and entity references in info strings, so the text
    /// is escaped for that first; the fence parser then reads the quoted value back verbatim.
    public static func anchoring(_ markdown: String, fenceLines: [Int], anchor: String) -> String? {
        let text = anchor.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(where: \.isNewline), !fenceLines.isEmpty else { return nil }
        var lines = markdown.components(separatedBy: "\n")
        let attribute = " anchor=" + escapeForCommonMark(quoted(text))
        for number in fenceLines {
            guard number >= 1, number <= lines.count, let marker = fenceMarker(in: lines[number - 1]) else { return nil }
            if marker == "`", text.contains("`") { return nil }
            var line = lines[number - 1]
            let carriageReturn = line.hasSuffix("\r")
            if carriageReturn { line.removeLast() }
            while line.last?.isWhitespace == true { line.removeLast() }
            lines[number - 1] = line + attribute + (carriageReturn ? "\r" : "")
        }
        return lines.joined(separator: "\n")
    }

    /// The fence character (`` ` `` or `~`) when the line opens a fence after its container
    /// prefix (indentation, `>` quotes, list markers).
    static func fenceMarker(in line: String) -> Character? {
        for marker: Character in ["`", "~"] {
            let run = String(repeating: marker, count: 3)
            guard let range = line.range(of: run) else { continue }
            let prefix = line[..<range.lowerBound]
            if prefix.allSatisfy({ $0.isWhitespace || $0 == ">" || $0 == "-" || $0 == "*" || $0 == "+" || $0 == "." || $0.isNumber }) { return marker }
        }
        return nil
    }

    /// Double quotes, unless the text has some and no single quotes: then single, unescaped.
    static func quoted(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
        if text.contains("\""), !text.contains("'") { return "'" + escaped + "'" }
        return "\"" + escaped.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func escapeForCommonMark(_ info: String) -> String {
        info.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "&", with: "\\&")
    }
}
