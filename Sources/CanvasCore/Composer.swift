import Foundation

/// The composer's draft (docs/design.md, Composer): the prompt the user writes in the tray bar,
/// with one inline token per staged mention. A token is an object replacement character (U+FFFC,
/// as its attachment is in the text view) in `text`, standing for the mention at the same place
/// in `tokens`; the text after a token is that mention's note. Sent, the n-th token reads `[n]`,
/// and each target gets the tokens' mentions numbered from 1 in token order
/// (`Board.queueComposerPrompt`), so `[n]` is the number the context gives the mention.
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

    /// Every mark stands for one token. A draft read from disk whose marks and tokens don't
    /// match (a damaged file) keeps its words and loses its tokens.
    public var repaired: ComposerDraft {
        guard markOffsets.count != tokens.count else { return self }
        return ComposerDraft(text: text.replacingOccurrences(of: Self.mark, with: ""), tokens: [])
    }

    /// This draft, then `other` after a space: the words and tokens of both, in order.
    public func followed(by other: ComposerDraft) -> ComposerDraft {
        guard !other.isEmpty else { return self }
        guard !isEmpty else { return other }
        return ComposerDraft(text: text + " " + other.text, tokens: tokens + other.tokens)
    }

    /// Inserts a token for `mention` at `offset` (UTF-16; nil: the end), spaced from the text
    /// around it, and returns the offset after it, where its note goes.
    @discardableResult
    public mutating func insert(_ mention: Mention, at offset: Int?) -> Int {
        let current = text as NSString
        let at = min(max(offset ?? current.length, 0), current.length)
        let index = min(markOffsets.filter { $0 < at }.count, tokens.count)
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
    /// Terminals picked in the target menu besides the tray's target (`PromptTarget`), each once.
    public var alsoTo: [ObjectID]

    public static let historyLimit = 100

    public init(draft: ComposerDraft = ComposerDraft(), history: [ComposerDraft] = [], alsoTo: [ObjectID] = []) {
        self.draft = draft
        self.history = history
        self.alsoTo = alsoTo
    }

    /// As read from disk: drafts whose marks and tokens don't match lose their tokens
    /// (`ComposerDraft.repaired`), and each extra target is kept once.
    public var repaired: ComposerState {
        ComposerState(draft: draft.repaired, history: history.map(\.repaired), alsoTo: Self.unique(alsoTo))
    }

    /// `ids` in order, each once.
    public static func unique(_ ids: [ObjectID]) -> [ObjectID] {
        var seen: Set<ObjectID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    /// A sent draft joins the history, unless it repeats the last one.
    public mutating func record(_ sent: ComposerDraft) {
        if let last = history.last, last.text == sent.text, last.tokens.map(\.target) == sent.tokens.map(\.target) { return }
        history.append(sent)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }
}

/// A prompt the composer sent to one terminal, waiting for the drain of the prompt it typed:
/// that drain takes `mentions` (numbered from 1) instead of the tray, whatever the tray, the
/// prompt target or the composer's later prompts are by then. An answer to a question the agent
/// was blocked on has none, and keeps the tray out of the drain its answer may cause (Codex's
/// queued questions are answered by a prompt).
public struct ComposerPrompt: Equatable, Sendable {
    public var id: String
    public var mentions: [Mention]
    public var answer: Bool
    public var queuedAt: Date

    /// How long an answer waits for a drain: an answer typed into a dialog causes none (Claude
    /// Code's questions, approvals), and the prompt after it must take the tray again.
    public static let answerLifetime: TimeInterval = 10
}

extension Board {
    /// Queues the composer's prompt to `terminal` before its text goes in: copies of `mentions`
    /// (ids of their own, so each terminal's delivery is its own), or an answer. A prompt drops
    /// the answers waiting before it (they caused no drain). Returns its id, to withdraw it if
    /// the text can't be typed.
    @discardableResult
    public func queueComposerPrompt(to terminal: ObjectID, mentions: [Mention], answer: Bool = false, now: Date = Date()) -> String {
        let copies = answer ? [] : mentions.map { Mention(id: IDs.make("men"), target: $0.target, label: $0.label, stagedAt: $0.stagedAt, edited: $0.edited) }
        let prompt = ComposerPrompt(id: IDs.make("cmp"), mentions: copies, answer: answer, queuedAt: now)
        var queue = composerPrompts[terminal] ?? []
        if !answer { queue.removeAll(where: \.answer) }
        queue.append(prompt)
        composerPrompts[terminal] = queue
        return prompt.id
    }

    /// The text never reached the terminal: its queued prompt goes.
    public func withdrawComposerPrompt(_ id: String) {
        for (terminal, queue) in composerPrompts {
            let left = queue.filter { $0.id != id }
            composerPrompts[terminal] = left.isEmpty ? nil : left
        }
    }

    /// The composer's prompt `caller`'s drain belongs to, oldest first: an answer past its
    /// lifetime is dropped; one without mentions is taken now (nothing to commit), one with
    /// mentions stays until they are committed, so a peeking drain that is cancelled loses nothing.
    func nextComposerPrompt(for caller: ObjectID, now: Date = Date()) -> ComposerPrompt? {
        var queue = composerPrompts[caller] ?? []
        queue.removeAll { $0.answer && now.timeIntervalSince($0.queuedAt) > ComposerPrompt.answerLifetime }
        let first = queue.first
        if first?.mentions.isEmpty == true { queue.removeFirst() }
        composerPrompts[caller] = queue.isEmpty ? nil : queue
        return first
    }

    /// Drops delivered mentions from the composer's prompts, and each prompt left with none.
    /// Returns how many were delivered.
    func commitComposerPrompts(_ ids: [MentionID]) -> Int {
        var count = 0
        for (terminal, queue) in composerPrompts {
            var left: [ComposerPrompt] = []
            for var prompt in queue {
                let before = prompt.mentions.count
                prompt.mentions.removeAll { ids.contains($0.id) }
                count += before - prompt.mentions.count
                if before == 0 || !prompt.mentions.isEmpty { left.append(prompt) }
            }
            composerPrompts[terminal] = left.isEmpty ? nil : left
        }
        return count
    }

    /// A deleted terminal takes its queue with it; a deleted object its mentions in every queue.
    func forgetComposerPrompts(of id: ObjectID) {
        composerPrompts[id] = nil
        for (terminal, queue) in composerPrompts {
            composerPrompts[terminal] = queue.map { prompt in
                var prompt = prompt
                prompt.mentions.removeAll { $0.target.objectIDs.contains(id) }
                return prompt
            }
        }
    }
}

/// Keeps the composer's tokens and the board's tray one-to-one, in the same order: every staged
/// mention has one token, and every token stands for a staged mention.
@MainActor
public enum ComposerSync {
    /// The tray changed by anything but the composer (a Hyper-click, ⇧⌘M, Remove Mention, the
    /// API, a prompt typed in the terminal taking the tray): tokens whose mention left it go; a
    /// mention new to it gets a token at `caret` (the composer has the keyboard) or at the end;
    /// then the tray takes the token order. Returns the caret.
    public static func trayChanged(_ draft: inout ComposerDraft, caret: Int?, on board: Board) -> Int? {
        var caret = caret
        let staged = Dictionary(board.tray.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        draft.removeTokens(at: Set(draft.tokens.indices.filter { staged[draft.tokens[$0].id] == nil }), caret: &caret)
        // The tray's copy: a label or "edited" flag may have changed.
        draft.tokens = draft.tokens.map { staged[$0.id] ?? $0 }
        for mention in board.tray where !draft.tokens.contains(where: { $0.id == mention.id }) {
            let end = draft.insert(mention, at: caret)
            if caret != nil { caret = end }
        }
        board.arrangeTray(draft.tokens.map(\.id))
        return caret
    }

    /// The user edited the draft (typing, deleting, ⌘Z, a paste, recalling a sent prompt): a
    /// token that went unstages its mention; a token whose mention isn't staged (⌘Z after
    /// deleting it, a recalled prompt's) stages its target again and stands for the tray's
    /// mention; a second token of one mention goes, as does one whose object is gone; then the
    /// tray takes the token order.
    public static func edited(_ draft: inout ComposerDraft, previous: ComposerDraft, caret: inout Int?, on board: Board) {
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
        board.arrangeTray(draft.tokens.map(\.id))
    }
}

/// One ⌘↩ of the composer: the draft it submitted and what each target gets. `begin` takes the
/// draft out of the composer before anything is awaited, so what the user types or stages while
/// the text goes in is the next draft's, never lost or sent by mistake.
@MainActor
public struct ComposerSend {
    /// What one target gets.
    public struct Delivery: Equatable, Sendable {
        public var terminal: ObjectID
        /// The target is blocked on a question or approval: the text is its answer, alone.
        public var answer: Bool
        /// The mentions its integration takes with this prompt (`Board.queueComposerPrompt`).
        public var mentions: [Mention]
        /// A terminal without an integration: the mentions' context is pasted ahead of the text.
        public var pastesContext: Bool
    }

    /// The draft as submitted, its tokens the mentions they stood for.
    public let draft: ComposerDraft
    public let deliveries: [Delivery]

    /// Every target was blocked: the text answers them all and the tokens stay staged.
    public var answersOnly: Bool { deliveries.allSatisfy(\.answer) }

    /// Starts sending `draft` to `targets` (the tray's target first): the tokens' mentions leave
    /// the tray (`Board.withdraw`), unless every target only gets an answer, and the composer is
    /// left with `remaining` (empty, or the tokens alone after an answer). Nil when there is
    /// nothing to send or nowhere to send it.
    public static func begin(_ draft: ComposerDraft, targets: [ObjectID], on board: Board) -> (send: ComposerSend, remaining: ComposerDraft)? {
        guard !draft.isEmpty, !targets.isEmpty else { return nil }
        let mentions = draft.tokens.map { token in board.tray.first { $0.id == token.id } ?? token }
        let deliveries = ComposerState.unique(targets).compactMap { id -> Delivery? in
            guard let terminal = board.objects[id], terminal.type == .terminal else { return nil }
            let answer = terminal.props["lifecycle"]?["state"]?.string == LifecycleState.blocked.rawValue
            let drains = PromptTarget.drains(terminal)
            return Delivery(terminal: id, answer: answer, mentions: answer || !drains ? [] : mentions, pastesContext: !answer && !drains && !mentions.isEmpty)
        }
        guard !deliveries.isEmpty else { return nil }
        let send = ComposerSend(draft: ComposerDraft(text: draft.text, tokens: mentions), deliveries: deliveries)
        var remaining = ComposerDraft()
        if send.answersOnly {
            for mention in mentions { remaining.insert(mention, at: nil) }
        } else {
            board.withdraw(mentions.map(\.id))
        }
        return (send, remaining)
    }

    /// The text typed into `delivery`'s terminal: the prompt, `[n]` for each token, with the
    /// mentions' context ahead of it (numbered from 1, ending on its own line, as Hyper-V pastes
    /// it) for a terminal without an integration.
    public func text(for delivery: Delivery, on board: Board) async -> String {
        guard delivery.pastesContext else { return draft.prompt }
        return await board.context(for: draft.tokens, caller: delivery.terminal) + "\n" + draft.prompt
    }

    /// Nothing went in anywhere: the submitted draft comes back ahead of what the user typed
    /// since (`current`), its tokens staged again.
    public func restore(into current: ComposerDraft, on board: Board) -> ComposerDraft {
        var restored = draft.followed(by: current)
        var caret: Int?
        ComposerSync.edited(&restored, previous: current, caret: &caret, on: board)
        return restored
    }
}
