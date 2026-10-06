import Foundation

/// A terminal color as SGR names it: the theme's default, a palette index (0–15 theme colors,
/// 16–255 the xterm cube and grays), or direct RGB.
public enum TerminalColor: Equatable, Sendable {
    case standard
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    /// RGB for palette indexes 16–255 (the xterm 6×6×6 cube and the gray ramp); nil for 0–15,
    /// which the theme defines.
    public static func xterm(_ index: UInt8) -> (UInt8, UInt8, UInt8)? {
        switch index {
        case 0..<16: return nil
        case 16..<232:
            let cube = Int(index) - 16
            let level = { (value: Int) -> UInt8 in value == 0 ? 0 : UInt8(55 + value * 40) }
            return (level(cube / 36), level((cube / 6) % 6), level(cube % 6))
        default:
            let gray = UInt8(8 + (Int(index) - 232) * 10)
            return (gray, gray, gray)
        }
    }
}

public struct TerminalStyle: Equatable, Sendable {
    public var foreground: TerminalColor = .standard
    public var background: TerminalColor = .standard
    public var bold = false
    public var faint = false
    public var italic = false
    public var underline = false
    public var inverse = false
    public var invisible = false
    public var strikethrough = false

    public init() {}

    /// Applies one SGR parameter list (`ESC [ … m`). Sub-parameters (`38:2::r:g:b`) arrive split on ':'.
    mutating func apply(_ parameters: [[Int?]]) {
        var index = 0
        let params = parameters.isEmpty ? [[0]] : parameters
        func color(from list: [Int?], rest: inout Int) -> TerminalColor? {
            // Colon form: everything is in `list` (38:5:n, 38:2::r:g:b or 38:2:r:g:b).
            if list.count > 1 {
                let values = list.dropFirst().map { $0 ?? 0 }
                switch values.first {
                case 5: return values.count >= 2 ? .indexed(UInt8(clamping: values[1])) : nil
                case 2:
                    let rgb = values.count >= 5 ? Array(values.suffix(3)) : Array(values.dropFirst())
                    return rgb.count == 3 ? .rgb(UInt8(clamping: rgb[0]), UInt8(clamping: rgb[1]), UInt8(clamping: rgb[2])) : nil
                default: return nil
                }
            }
            // Semicolon form: the following parameters.
            let base = rest
            func next(_ offset: Int) -> Int? { base + offset < params.count ? params[base + offset].first ?? 0 : nil }
            switch next(1) {
            case 5?:
                defer { rest += 2 }
                return next(2).map { .indexed(UInt8(clamping: $0)) }
            case 2?:
                defer { rest += 4 }
                guard let r = next(2), let g = next(3), let b = next(4) else { return nil }
                return .rgb(UInt8(clamping: r), UInt8(clamping: g), UInt8(clamping: b))
            default:
                return nil
            }
        }
        while index < params.count {
            let list = params[index]
            let code = list.first.flatMap { $0 } ?? 0
            switch code {
            case 0: self = TerminalStyle()
            case 1: bold = true
            case 2: faint = true
            case 3: italic = true
            case 4: underline = (list.count > 1 ? (list[1] ?? 1) : 1) != 0
            case 7: inverse = true
            case 8: invisible = true
            case 9: strikethrough = true
            case 21: underline = true
            case 22: bold = false; faint = false
            case 23: italic = false
            case 24: underline = false
            case 27: inverse = false
            case 28: invisible = false
            case 29: strikethrough = false
            case 30...37: foreground = .indexed(UInt8(code - 30))
            case 38: if let value = color(from: list, rest: &index) { foreground = value }
            case 39: foreground = .standard
            case 40...47: background = .indexed(UInt8(code - 40))
            case 48: if let value = color(from: list, rest: &index) { background = value }
            case 49: background = .standard
            case 58: _ = color(from: list, rest: &index)  // underline color: not drawn
            case 90...97: foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: background = .indexed(UInt8(code - 100 + 8))
            default: break
            }
            index += 1
        }
    }
}

public struct TerminalRun: Equatable, Sendable {
    public var text: String
    public var style: TerminalStyle

    public init(text: String, style: TerminalStyle) {
        self.text = text
        self.style = style
    }
}

public struct TerminalLine: Equatable, Sendable {
    public var runs: [TerminalRun] = []
    public var text: String { runs.map(\.text).joined() }

    public init(runs: [TerminalRun] = []) {
        self.runs = runs
    }
}

/// The last `limit` lines of `zmx history --vt` output as styled runs: SGR colors and
/// attributes, carried across lines; other escape sequences (cursor moves, modes, OSC titles)
/// are dropped. Fed chunk by chunk, so a long scrollback is never held whole. The last cursor
/// position (`ESC [ row ; col H`) says which row of the screen the output ends on: rows below
/// it are blank on screen but absent from the output.
public struct TerminalStyledTail: Sendable {
    public let limit: Int
    private var lines: [TerminalLine] = []
    private var partial = Data()
    private var style = TerminalStyle()
    public private(set) var cursorRow: Int?

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public mutating func append(_ bytes: Data) {
        var start = bytes.startIndex
        while let newline = bytes[start...].firstIndex(of: 0x0A) {
            if partial.isEmpty {
                add(bytes[start..<newline])
            } else {
                partial.append(bytes[start..<newline])
                add(partial)
                partial.removeAll(keepingCapacity: true)
            }
            start = bytes.index(after: newline)
        }
        partial.append(bytes[start...])
    }

    /// The last `limit` lines; a trailing partial line (the cursor's) counts when it has text.
    public mutating func finish() -> [TerminalLine] {
        if !partial.isEmpty {
            let before = lines.count
            add(partial)
            partial.removeAll()
            if lines.count > before, lines.last?.text.allSatisfy(\.isWhitespace) == true { lines.removeLast() }
        }
        return Array(lines.suffix(limit))
    }

    private mutating func add(_ bytes: Data) {
        lines.append(parse(String(decoding: bytes, as: UTF8.self)))
        if lines.count >= 2 * limit { lines.removeFirst(lines.count - limit) }
    }

    private enum State { case text, escape, csi, osc, oscEscape }

    private mutating func parse(_ line: String) -> TerminalLine {
        var result = TerminalLine()
        var text = ""
        var column = 0
        var state = State.text
        var parameters = ""
        func flush(_ result: inout TerminalLine, _ text: inout String, _ style: TerminalStyle) {
            guard !text.isEmpty else { return }
            if let last = result.runs.last, last.style == style {
                result.runs[result.runs.count - 1].text += text
            } else {
                result.runs.append(TerminalRun(text: text, style: style))
            }
            text = ""
        }
        for character in line {
            switch state {
            case .text:
                switch character {
                case "\u{1B}": state = .escape
                case "\r": break
                case "\t":
                    let spaces = 8 - column % 8
                    text += String(repeating: " ", count: spaces)
                    column += spaces
                default:
                    guard let scalar = character.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F else { break }
                    text.append(character)
                    column += Self.cellWidth(character)
                }
            case .escape:
                switch character {
                case "[":
                    state = .csi
                    parameters = ""
                case "]": state = .osc
                default: state = .text  // two-byte escapes (ESC =, ESC 7, …)
                }
            case .csi:
                guard let value = character.unicodeScalars.first?.value, (0x40...0x7E).contains(value) else {
                    parameters.append(character)
                    continue
                }
                state = .text
                switch character {
                case "m" where !parameters.contains(where: { "?<=>".contains($0) }):
                    flush(&result, &text, style)
                    style.apply(Self.sgrParameters(parameters))
                case "H", "f":
                    cursorRow = parameters.split(separator: ";", omittingEmptySubsequences: false).first.flatMap { Int($0) } ?? 1
                default:
                    break
                }
            case .osc:
                if character == "\u{07}" { state = .text } else if character == "\u{1B}" { state = .oscEscape }
            case .oscEscape:
                state = character == "\\" ? .text : .osc
            }
        }
        flush(&result, &text, style)
        return result
    }

    static func sgrParameters(_ text: String) -> [[Int?]] {
        guard !text.isEmpty else { return [] }
        return text.split(separator: ";", omittingEmptySubsequences: false).map { part in
            part.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        }
    }

    /// Terminal cells a character occupies: 2 for East Asian wide characters and emoji
    /// presentation, 0 for combining marks, else 1 (Nerd Font icons included).
    public static func cellWidth(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        let value = scalar.value
        if scalar.properties.isEmojiPresentation { return 2 }
        let wide: [ClosedRange<UInt32>] = [0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                                           0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
                                           0xFFE0...0xFFE6, 0x20000...0x3FFFD]
        return wide.contains { $0.contains(value) } ? 2 : 1
    }

    /// Terminal cells `text` occupies on one row (`cellWidth` of each character).
    public static func width(_ text: some StringProtocol) -> Int {
        text.reduce(0) { $0 + cellWidth($1) }
    }
}
