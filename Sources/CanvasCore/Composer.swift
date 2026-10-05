import Foundation

/// The composer's draft (docs/design.md, Composer): the prompt the user writes in the tray bar,
/// with one inline token per staged mention. A token is an object replacement character (U+FFFC,
/// as its attachment is in the text view) in `text`, standing for the mention at the same place
/// in `tokens`; the text after a token is that mention's note. Sent, the n-th token reads `[n]`:
/// the tray is kept in token order (`Board.arrangeTray`) and mentions handed to other terminals
/// go in the same order (`Board.handOff`), so `[n]` is the number the context gives the mention.
public struct ComposerDraft: Codable, Equatable, Sendable {
    public static let mark = "\u{FFFC}"
    static let markUnit: unichar = 0xFFFC

    public var text: String
    public var tokens: [Mention]

    public init(text: String = "", tokens: [Mention] = []) {
        self.text = text
        self.tokens = tokens
    }

    /// Nothing typed and no tokens.
    public var isEmpty: Bool {
        tokens.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The prompt as typed into the agent: each token as `[n]`, n its place among the tokens,
    /// without the whitespace around it all.
    public var prompt: String {
        var number = 0
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar.value == UInt32(Self.markUnit) {
                number += 1
                out += TrayChips.badge(number)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where each token's mark is, as UTF-16 offsets (the text view's).
    var markOffsets: [Int] {
        let text = self.text as NSString
        return (0..<text.length).filter { text.character(at: $0) == Self.markUnit }
    }

    /// Inserts a token for `mention` at `offset` (UTF-16; nil: the end), spaced from the text
    /// around it, and returns the offset after it, where its note goes.
    @discardableResult
    public mutating func insert(_ mention: Mention, at offset: Int?) -> Int {
        let current = text as NSString
        let at = min(max(offset ?? current.length, 0), current.length)
        let index = markOffsets.filter { $0 < at }.count
        var piece = Self.mark
        if at > 0, !Self.isSpace(current.character(at: at - 1)) { piece = " " + piece }
        let spaced = at < current.length && Self.isSpace(current.character(at: at))
        if !spaced { piece += " " }
        text = current.replacingCharacters(in: NSRange(location: at, length: 0), with: piece)
        tokens.insert(mention, at: index)
        return at + (piece as NSString).length + (spaced ? 1 : 0)
    }

    /// Takes out the tokens at these places among the tokens, each with the space after it (or,
    /// at the end of a line, the one before it); `caret` stays with the text it was in. A draft
    /// left with only whitespace is emptied.
    public mutating func removeTokens(at indices: Set<Int>, caret: inout Int?) {
        guard !indices.isEmpty else { return }
        let marks = markOffsets
        let edited = NSMutableString(string: text)
        for index in indices.sorted(by: >) where index < marks.count {
            var range = NSRange(location: marks[index], length: 1)
            if range.upperBound < edited.length, Self.isSpace(edited.character(at: range.upperBound)), edited.character(at: range.upperBound) != 0x0A {
                range.length += 1
            } else if range.location > 0, edited.character(at: range.location - 1) == 0x20 {
                range.location -= 1
                range.length += 1
            }
            edited.deleteCharacters(in: range)
            if let at = caret, at > range.location { caret = at - min(range.length, at - range.location) }
        }
        text = edited as String
        tokens = tokens.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
        if isEmpty {
            text = ""
            if caret != nil { caret = 0 }
        }
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }
}

/// What the composer keeps for one board, for this user only: the draft, the prompts sent from
/// it (newest last) and the terminals it also sends to besides the tray's target. Saved by the app
/// beside the boards, never in the board file: a board will soon have several clients, and one
/// person's half-written prompt and history aren't the board's.
public struct ComposerState: Codable, Equatable, Sendable {
    public var draft: ComposerDraft
    public var history: [ComposerDraft]
    /// Terminals picked in the target menu besides the tray's target (`PromptTarget`).
    public var alsoTo: [ObjectID]

    public static let historyLimit = 100

    public init(draft: ComposerDraft = ComposerDraft(), history: [ComposerDraft] = [], alsoTo: [ObjectID] = []) {
        self.draft = draft
        self.history = history
        self.alsoTo = alsoTo
    }

    /// A sent draft joins the history, unless it repeats the last one.
    public mutating func record(_ sent: ComposerDraft) {
        if let last = history.last, last.text == sent.text, last.tokens.map(\.target) == sent.tokens.map(\.target) { return }
        history.append(sent)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }
}

/// Keeps the composer's tokens and the board's tray one-to-one, in the same order: every staged
/// mention has one token, and every token stands for a staged mention.
@MainActor
public enum ComposerSync {
    /// The tray changed by anything but the composer (a Hyper-click, ⇧⌘M, Remove Mention, the
    /// API, a prompt typed in the terminal taking the tray): tokens whose mention left it go; a
    /// mention new to it gets a token at `caret` (the composer has the keyboard) or at the end;
    /// then the tray takes the token order. `holding`: mentions a sent prompt took, waiting for
    /// the drain; they get no token and stay first. Returns the caret.
    public static func trayChanged(_ draft: inout ComposerDraft, caret: Int?, on board: Board, holding: [MentionID] = []) -> Int? {
        var caret = caret
        let staged = Dictionary(board.tray.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        draft.removeTokens(at: Set(draft.tokens.indices.filter { staged[draft.tokens[$0].id] == nil || holding.contains(draft.tokens[$0].id) }), caret: &caret)
        // The tray's copy: a label or "edited" flag may have changed.
        draft.tokens = draft.tokens.map { staged[$0.id] ?? $0 }
        for mention in board.tray where !holding.contains(mention.id) && !draft.tokens.contains(where: { $0.id == mention.id }) {
            let end = draft.insert(mention, at: caret)
            if caret != nil { caret = end }
        }
        board.arrangeTray(holding + draft.tokens.map(\.id))
        return caret
    }

    /// The user edited the draft (typing, deleting, ⌘Z, a paste, recalling a sent prompt): a
    /// token that went unstages its mention; a token whose mention isn't staged (⌘Z after
    /// deleting it, a recalled prompt's) stages its target again and stands for the tray's
    /// mention; a second token of one mention goes, as does one whose object is gone; then the
    /// tray takes the token order.
    public static func edited(_ draft: inout ComposerDraft, previous: ComposerDraft, caret: inout Int?, on board: Board, holding: [MentionID] = []) {
        let kept = Set(draft.tokens.map(\.id))
        for gone in previous.tokens where !kept.contains(gone.id) && board.tray.contains(where: { $0.id == gone.id }) {
            try? board.unstage(gone.id)
        }
        var seen: Set<MentionID> = []
        var dropped: Set<Int> = []
        for (index, token) in draft.tokens.enumerated() {
            guard let mention = board.tray.first(where: { $0.id == token.id }) ?? (try? board.stage(token.target)), !seen.contains(mention.id) else {
                dropped.insert(index)
                continue
            }
            seen.insert(mention.id)
            draft.tokens[index] = mention
        }
        draft.removeTokens(at: dropped, caret: &caret)
        board.arrangeTray(holding + draft.tokens.map(\.id))
    }
}
