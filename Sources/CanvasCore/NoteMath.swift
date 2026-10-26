import AppKit
import Markdown
import SwiftMath

/// LaTeX in notes, typeset by SwiftMath: `$…$` runs inline, `$$…$$` on its own centered line.
/// Delimiters follow Pandoc's rule so currency stays prose, and `\$` is a literal dollar.
@MainActor
enum NoteMath {
    /// A formula in one text node: its characters (without the delimiters) and whether it is
    /// display math.
    struct Span {
        let start: Int
        let end: Int
        let latex: String
        let display: Bool
    }

    /// One text node's decoded characters, with the raw source each came from (so LaTeX keeps
    /// `\,` and `\{` that CommonMark would otherwise unescape) and which `$`s were written `\$`.
    struct Text {
        let characters: [Character]
        let source: [String]
        let escapedDollar: [Bool]
    }

    /// `raw` decoded as CommonMark decodes a text node, or nil when it can't be reproduced
    /// exactly (an entity beyond the numeric and XML ones), which leaves the node as prose.
    static func text(raw: String, decoded: String) -> Text? {
        text(raw: Array(raw), decoded: decoded)
    }

    /// The buffer uses contiguous integer offsets; collection input makes scanner work observable.
    static func text<Characters: RandomAccessCollection>(raw: Characters, decoded: String) -> Text? where Characters.Element == Character, Characters.Index == Int {
        var characters: [Character] = []
        var source: [String] = []
        var escapedDollar: [Bool] = []
        let scalars = raw
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let character = scalars[index]
            if character == "\\", index + 1 < scalars.endIndex, isPunctuation(scalars[index + 1]) {
                let escaped = scalars[index + 1]
                characters.append(escaped)
                source.append(String([character, escaped]))
                escapedDollar.append(escaped == "$")
                index += 2
                continue
            }
            if character == "&", let semicolon = scalars[index..<min(index + 33, scalars.endIndex)].firstIndex(of: ";"),
               let decoded = entity(scalars[(index + 1)..<semicolon]) {
                characters.append(contentsOf: decoded)
                for _ in decoded { source.append(String(scalars[index...semicolon])) }
                for _ in decoded { escapedDollar.append(false) }
                index = semicolon + 1
                continue
            }
            characters.append(character)
            source.append(String(character))
            escapedDollar.append(false)
            index += 1
        }
        guard String(characters) == decoded else { return nil }
        return Text(characters: characters, source: source, escapedDollar: escapedDollar)
    }

    /// The formulas `text` holds, with the LaTeX as written. An unclosed or currency-shaped `$`
    /// stays prose, as does a `$` written `\$`.
    static func spans(in text: Text) -> [Span] {
        let characters = text.characters
        var spans: [Span] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "$", !text.escapedDollar[index] else {
                index += 1
                continue
            }
            if index + 1 < characters.count, characters[index + 1] == "$" {
                if let close = closing(of: "$$", in: characters, from: index + 2, escaped: text.escapedDollar) {
                    let latex = latex(text, from: index + 2, to: close).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !latex.isEmpty {
                        spans.append(Span(start: index, end: close + 2, latex: latex, display: true))
                        index = close + 2
                        continue
                    }
                }
                index += 2
                continue
            }
            guard index + 1 < characters.count, !characters[index + 1].isWhitespace else {
                index += 1
                continue
            }
            if let close = closing(of: "$", in: characters, from: index + 1, escaped: text.escapedDollar) {
                spans.append(Span(start: index, end: close + 1, latex: latex(text, from: index + 1, to: close), display: false))
                index = close + 1
                continue
            }
            index += 1
        }
        return spans
    }

    /// `source` without surrounding whitespace when it is one display formula and nothing else.
    static func displayMath(in source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5, trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$") else { return nil }
        let latex = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        return latex.isEmpty ? nil : latex
    }

    /// A formula as a text attachment, or nil when SwiftMath can't typeset it. The picture draws
    /// in `NSColor.labelColor` at draw time, so it follows light and dark.
    static func attachment(latex: String, fontSize: CGFloat, display: Bool) -> NSTextAttachment? {
        guard let nativeLatex = NativeMathInput.prepare(latex) else { return nil }
        let label = MTMathUILabel()
        label.fontSize = fontSize
        label.labelMode = display ? .display : .text
        label.textAlignment = .left
        label.latex = nativeLatex
        guard label.error == nil else { return nil }
        let fitting = label.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return nil }
        label.frame = CGRect(origin: .zero, size: fitting)
        label.layout()
        guard let list = label.displayList else { return nil }
        let size = CGSize(width: list.width, height: list.ascent + list.descent)
        guard size.width > 0, size.height > 0 else { return nil }
        let image = NSImage(size: size, flipped: false) { _ in
            guard NSGraphicsContext.current?.cgContext != nil else { return false }
            label.textColor = NSColor.labelColor
            label.draw(label.bounds)
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -list.descent, width: size.width, height: size.height)
        return attachment
    }

    // SwiftMath 1.7.3 recursively parses arguments, groups, infix denominators and table
    // cells. This bounded structural scan builds no math tree and leaves syntax errors to it.
    private struct NativeMathInput {
        private enum Frame: Equatable {
            case argument(Int), group, degree, left, environment(String), table, remainder
        }

        private let characters: String
        private var index: String.Index
        private var frames: [Frame] = []
        private var colorCommands: [Range<String.Index>] = []
        // Radicals and accents dominate the measured typesetter cost; breadth needs a
        // budget independently of stack depth. Other structural entries cost one.
        private var remainingWork = 128

        static func prepare(_ latex: String) -> String? {
            guard latex.utf8.count <= 2048 else { return nil }
            var work = 0
            for byte in latex.utf8 {
                switch byte {
                case 0x5C, 0x7B, 0x5B, 0x5E, 0x5F, 0x26:
                    work += 1
                    guard work <= 256 else { return nil }
                default:
                    break
                }
            }
            var input = Self(characters: latex, index: latex.startIndex)
            guard input.scan() else { return nil }
            guard !input.colorCommands.isEmpty else { return latex }
            var normalized = ""
            normalized.reserveCapacity(latex.utf8.count - 4 * input.colorCommands.count)
            var start = latex.startIndex
            for range in input.colorCommands {
                normalized.append(contentsOf: input.characters[start..<range.lowerBound])
                normalized.append(#"\color"#)
                start = range.upperBound
            }
            normalized.append(contentsOf: input.characters[start...])
            return normalized
        }

        private mutating func push(_ frame: Frame, cost: Int = 1) -> Bool {
            guard frames.count < 16, remainingWork >= cost else { return false }
            remainingWork -= cost
            frames.append(frame)
            return true
        }

        private mutating func completeArgument() {
            while case .argument(let remaining) = frames.last {
                frames.removeLast()
                if remaining > 1 {
                    frames.append(.argument(remaining - 1))
                    return
                }
            }
        }

        private mutating func close(_ frame: Frame, completesArgument: Bool = true) -> Bool {
            // One-character arguments return empty before }, ^, _, or &.
            completeArgument()
            while frames.last == .remainder { frames.removeLast() }
            guard frames.last == frame else { return false }
            frames.removeLast()
            if completesArgument { completeArgument() }
            return true
        }

        private mutating func command() -> String {
            let start = index
            if index < characters.endIndex, "{}$#%_| ,>;!\\".contains(characters[index]) {
                characters.formIndex(after: &index)
            } else {
                while index < characters.endIndex,
                      characters[index].isLowercase || characters[index].isUppercase {
                    characters.formIndex(after: &index)
                }
            }
            return String(characters[start..<index])
        }

        private mutating func skipSpaces() {
            while index < characters.endIndex {
                let character = characters[index]
                if character.unicodeScalars.count == 1,
                   let scalar = character.unicodeScalars.first,
                   scalar.value >= 0x21, scalar.value <= 0x7E { return }
                characters.formIndex(after: &index)
            }
        }

        private mutating func metadata() -> String? {
            skipSpaces()
            guard index < characters.endIndex, characters[index] == "{" else { return nil }
            characters.formIndex(after: &index)
            let start = index
            while index < characters.endIndex, characters[index] != "}" {
                guard characters[index] != "{", characters[index] != "\\" else { return nil }
                characters.formIndex(after: &index)
            }
            guard index < characters.endIndex else { return nil }
            let value = String(characters[start..<index])
            characters.formIndex(after: &index)
            return value
        }

        private mutating func delimiter() -> Bool {
            skipSpaces()
            guard index < characters.endIndex else { return false }
            let character = characters[index]
            characters.formIndex(after: &index)
            if character == "\\" { _ = command() }
            return true
        }

        private mutating func separator() -> Bool {
            completeArgument()
            while frames.last == .remainder { frames.removeLast() }
            // SwiftMath's currentEnv is shared by nested groups and table cells.
            if frames.contains(where: {
                if case .environment = $0 { return true }
                return $0 == .table
            }) { return true }
            return push(.table)
        }

        private mutating func scan() -> Bool {
            while index < characters.endIndex {
                let start = index
                let character = characters[index]
                characters.formIndex(after: &index)
                switch character {
                case "{":
                    guard push(.group) else { return false }
                case "}":
                    guard close(.group) else { return false }
                case "]" where frames.last(where: { $0 != .remainder }) == .degree:
                    guard close(.degree, completesArgument: false) else { return false }
                case "^", "_":
                    completeArgument()
                    guard push(.argument(1)) else { return false }
                case "&":
                    guard separator() else { return false }
                case "\\":
                    let name = command()
                    switch name {
                    case "frac", "binom":
                        guard push(.argument(2)) else { return false }
                    case "sqrt":
                        guard push(.argument(1), cost: 8) else { return false }
                        if index < characters.endIndex, characters[index] == "[" {
                            characters.formIndex(after: &index)
                            guard push(.degree) else { return false }
                        }
                    case "left":
                        guard delimiter(), push(.left) else { return false }
                    case "right":
                        guard delimiter(), close(.left) else { return false }
                    case "begin":
                        guard let name = metadata(), push(.environment(name)) else { return false }
                    case "end":
                        guard let name = metadata(), close(.environment(name)) else { return false }
                    case "color", "textcolor", "colorbox":
                        // Unlike .textcolor, SwiftMath's .color path never indexes
                        // subDisplays or assumes its argument is a CT line.
                        if name == "textcolor" { colorCommands.append(start..<index) }
                        guard metadata() != nil, push(.argument(1)) else { return false }
                    case "over", "atop", "choose", "brack", "brace":
                        guard push(.remainder) else { return false }
                    case "\\", "cr":
                        guard separator() else { return false }
                    case "limits", "nolimits":
                        break
                    default:
                        if MTMathAtomFactory.accents[name] != nil {
                            guard push(.argument(1), cost: 8) else { return false }
                        } else if name == "overline" || name == "underline"
                            || MTMathAtomFactory.fontStyleWithName(name) != nil {
                            guard push(.argument(1)) else { return false }
                        } else {
                            completeArgument()
                        }
                    }
                default:
                    // Ignoring non-ASCII and non-atoms can only overestimate an argument's
                    // lifetime. SwiftMath also ignores these except in text/font commands.
                    if character.unicodeScalars.count == 1,
                       let scalar = character.unicodeScalars.first,
                       scalar.value >= 0x21, scalar.value <= 0x7E,
                       !"$%#~'".contains(character) {
                        completeArgument()
                    }
                }
            }
            while frames.last == .remainder || frames.last == .table { frames.removeLast() }
            return frames.isEmpty
        }
    }

    // MARK: Source

    /// The markdown `range` names, for the source a formula keeps verbatim.
    static func source(_ range: SourceRange, in index: SourceIndex) -> String? {
        index.text(range)
    }

    /// Line starts in UTF-8 bytes: `SourceLocation.column` counts UTF-8 bytes from the line start.
    struct SourceIndex {
        private let markdown: String
        private let lineStarts: [Int]

        init(_ markdown: String) {
            self.markdown = markdown
            var starts = [0]
            for (offset, byte) in markdown.utf8.enumerated() where byte == 0x0A { starts.append(offset + 1) }
            lineStarts = starts
        }

        func text(_ range: SourceRange) -> String? {
            guard let start = offset(range.lowerBound), let end = offset(range.upperBound), start <= end else { return nil }
            let bytes = markdown.utf8
            guard let lower = bytes.index(bytes.startIndex, offsetBy: start, limitedBy: bytes.endIndex),
                  let upper = bytes.index(lower, offsetBy: end - start, limitedBy: bytes.endIndex) else { return nil }
            return String(decoding: bytes[lower..<upper], as: UTF8.self)
        }

        private func offset(_ location: SourceLocation) -> Int? {
            guard location.line >= 1, location.line <= lineStarts.count, location.column >= 1 else { return nil }
            return lineStarts[location.line - 1] + location.column - 1
        }
    }

    // MARK: Helpers

    /// The closer's index, where the character before it isn't whitespace and a `$` isn't
    /// followed by a digit (Pandoc's rule, which keeps `$5 and $10` prose).
    private static func closing(of delimiter: String, in characters: [Character], from start: Int, escaped: [Bool]) -> Int? {
        let width = delimiter.count
        var index = start
        while index + width <= characters.count {
            if delimiter == "$" {
                if characters[index] == "$", !escaped[index] {
                    // A `$` that can't close here can't be inside math either: the formula would
                    // have swallowed currency (`$5 and $10 … $x$`), so this candidate is prose.
                    guard !characters[index - 1].isWhitespace, index + 1 >= characters.count || !characters[index + 1].isNumber else { return nil }
                    return index
                }
                index += 1
            } else {
                if characters[index] == "$", characters[index + 1] == "$" {
                    return index
                }
                index += 1
            }
        }
        return nil
    }

    private static func latex(_ text: Text, from start: Int, to end: Int) -> String {
        text.source[start..<end].joined()
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1, scalar.isASCII else { return false }
        return CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
    }

    /// A numeric entity, or one of the five XML names. Named HTML entities beyond these can't be
    /// reproduced without cmark's table, so the text node stays prose.
    private static func entity<Body: Collection>(_ body: Body) -> [Character]? where Body.Element == Character {
        let name = String(body)
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            guard let value = UInt32(name.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
            return Array(String(scalar))
        }
        if name.hasPrefix("#") {
            guard let value = UInt32(name.dropFirst()), let scalar = Unicode.Scalar(value) else { return nil }
            return Array(String(scalar))
        }
        switch name {
        case "amp": return ["&"]
        case "lt": return ["<"]
        case "gt": return [">"]
        case "quot": return ["\""]
        case "apos": return ["'"]
        default: return nil
        }
    }
}
