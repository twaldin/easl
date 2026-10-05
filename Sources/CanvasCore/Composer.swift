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
/// it (newest last), the terminals it also sends to besides the tray's target, and the drafts
/// on their way out. Saved by the app beside the boards, never in the board file: a board will
/// soon have several clients, and one person's half-written prompt and history aren't the board's.
public struct ComposerState: Codable, Equatable, Sendable {
    public var draft: ComposerDraft
    public var history: [ComposerDraft]
    /// Terminals picked in the target menu besides the tray's target (`PromptTarget`), each once.
    public var alsoTo: [ObjectID]
    /// Drafts sent with ⌘↩ that no terminal has taken yet (`sending`, `reached`): kept so
    /// quitting meanwhile loses nothing (`recoverOutgoing`).
    public var outgoing: [ComposerDraft]

    public static let historyLimit = 100

    public init(draft: ComposerDraft = ComposerDraft(), history: [ComposerDraft] = [], alsoTo: [ObjectID] = [], outgoing: [ComposerDraft] = []) {
        self.draft = draft
        self.history = history
        self.alsoTo = alsoTo
        self.outgoing = outgoing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        draft = try container.decodeIfPresent(ComposerDraft.self, forKey: .draft) ?? ComposerDraft()
        history = try container.decodeIfPresent([ComposerDraft].self, forKey: .history) ?? []
        alsoTo = try container.decodeIfPresent([ObjectID].self, forKey: .alsoTo) ?? []
        outgoing = try container.decodeIfPresent([ComposerDraft].self, forKey: .outgoing) ?? []
    }

    /// As read from disk: drafts whose marks and tokens don't match lose their tokens
    /// (`ComposerDraft.repaired`), and each extra target is kept once.
    public var repaired: ComposerState {
        ComposerState(draft: draft.repaired, history: history.map(\.repaired), alsoTo: Self.unique(alsoTo), outgoing: outgoing.map(\.repaired))
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

    /// `sent` left the composer and its text is going in.
    public mutating func sending(_ sent: ComposerDraft) {
        outgoing.append(sent)
    }

    /// `sent`'s text went into a terminal: it is in the history now, no longer on its way.
    public mutating func reached(_ sent: ComposerDraft) {
        guard let index = outgoing.firstIndex(of: sent) else { return }
        outgoing.remove(at: index)
        record(sent)
    }

    /// `sent` went nowhere (its text reached no terminal): no longer on its way.
    public mutating func returned(_ sent: ComposerDraft) {
        if let index = outgoing.firstIndex(of: sent) { outgoing.remove(at: index) }
    }

    /// Drafts still on their way when the app last quit never reached a terminal: they come
    /// back ahead of the draft, their tokens staged again.
    @MainActor
    public mutating func recoverOutgoing(on board: Board) {
        guard !outgoing.isEmpty else { return }
        var restored = outgoing.reduce(ComposerDraft()) { $0.followed(by: $1) }.followed(by: draft)
        var caret: Int?
        ComposerSync.edited(&restored, previous: draft, caret: &caret, on: board)
        draft = restored
        outgoing = []
    }
}

/// A prompt the composer typed into one terminal whose integration drains, waiting for that
/// prompt's drain. A terminal's prompts form a queue in the order they were typed, which is the
/// order its agent submits them (prompts it queues mid-turn included): the next drain from that
/// terminal that carries a `prompt` (its integration's submission drain, whatever the text, which
/// the agent may have rewritten) is the oldest one's, and takes its `mentions` (numbered from 1)
/// instead of the tray, whatever the tray, the prompt target or the composer's later prompts are
/// by then. A drain without a `prompt` (Hyper-V, a script, the CLI, an older integration) never
/// sees the queue. A prompt without mentions (a prompt with no tokens, an answer) takes nothing.
public struct ComposerPrompt: Equatable, Sendable {
    public var id: String
    /// The text as typed; only compared, for the log, with the text its drain says it submits.
    public var prompt: String
    public var mentions: [Mention]
    /// The text answers a question or approval the agent was blocked on. A dialog takes it
    /// without any prompt (Claude Code's): it is dropped once the agent is past that question
    /// (`answerSettledAt`), unless a submission drain (Codex answers a queued question with a
    /// prompt) claims it first.
    public var answer: Bool
    public var queuedAt: Date
    /// An answer's agent left `blocked` for `working` or `idle` at this time.
    public var answerSettledAt: Date?

    /// A safety cap: a prompt that waited this long for its drain is taken as never coming
    /// (prompts queued behind a long turn wait as long as that turn).
    public static let lifetime: TimeInterval = 2 * 3600
    /// How long an answer stays after its agent is past the question, for the drain of an
    /// answer that became a prompt (Codex's hook reports `working`, then drains).
    public static let answerGrace: TimeInterval = 2
}

extension Board {
    /// Queues the composer's prompt `text` to `terminal` before the text goes in, behind the
    /// prompts already waiting there, with copies of `mentions` (ids of their own, so each
    /// terminal's delivery is its own). Returns its id, to withdraw it if the text can't be typed.
    @discardableResult
    public func queueComposerPrompt(_ text: String, to terminal: ObjectID, mentions: [Mention], answer: Bool = false, now: Date = Date()) -> String {
        expireComposerPrompts(now: now)
        let copies = answer ? [] : mentions.map { Mention(id: IDs.make("men"), target: $0.target, label: $0.label, stagedAt: $0.stagedAt, edited: $0.edited) }
        let blocked = objects[terminal]?.props["lifecycle"]?["state"]?.string == LifecycleState.blocked.rawValue
        let prompt = ComposerPrompt(id: IDs.make("cmp"), prompt: text, mentions: copies, answer: answer, queuedAt: now, answerSettledAt: answer && !blocked ? now : nil)
        composerPrompts[terminal, default: []].append(prompt)
        return prompt.id
    }

    /// The text never reached the terminal: its queued prompt goes (the composer restores it).
    public func withdrawComposerPrompt(_ id: String) {
        for (terminal, queue) in composerPrompts where queue.contains(where: { $0.id == id }) {
            let left = queue.filter { $0.id != id }
            composerPrompts[terminal] = left.isEmpty ? nil : left
        }
    }

    /// The composer's prompt `caller`'s submission drain of `submitted` belongs to: the oldest
    /// waiting. One without mentions is taken now (nothing to deliver or commit); one with
    /// mentions stays until they are committed (`tray.commit`), so a peek loses nothing. When
    /// neither text contains the other (the agent rewrote more than it wraps), one log line
    /// says so, with lengths only.
    func claimComposerPrompt(for caller: ObjectID, submitted: String, now: Date = Date()) -> ComposerPrompt? {
        expireComposerPrompts(now: now)
        guard var queue = composerPrompts[caller], let first = queue.first else { return nil }
        let sent = first.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let seen = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sent.contains(seen), !seen.contains(sent) {
            NSLog("easl: composer prompt to \(caller) claimed by a drain whose text differs (sent \(sent.count) characters, drained \(seen.count))")
        }
        if first.mentions.isEmpty {
            queue.removeFirst()
            composerPrompts[caller] = queue.isEmpty ? nil : queue
        }
        return first
    }

    /// `tile`'s agent reported `state`: once it is past a question (working or idle, no longer
    /// blocked), the answers waiting there have `ComposerPrompt.answerGrace` left.
    func composerAgentReported(_ tile: ObjectID, state: LifecycleState, now: Date = Date()) {
        guard state == .working || state == .idle, var queue = composerPrompts[tile] else { return }
        for index in queue.indices where queue[index].answer && queue[index].answerSettledAt == nil {
            queue[index].answerSettledAt = now
        }
        composerPrompts[tile] = queue
    }

    /// Drops answers whose agent is past the question (`answerGrace` ago), and gives back the
    /// mentions of prompts that waited `ComposerPrompt.lifetime`. The app calls this every
    /// minute; queueing and claiming call it too.
    public func expireComposerPrompts(now: Date = Date()) {
        for (terminal, queue) in composerPrompts {
            let settled = { (prompt: ComposerPrompt) in prompt.answerSettledAt.map { now.timeIntervalSince($0) > ComposerPrompt.answerGrace } ?? false }
            let expired = { (prompt: ComposerPrompt) in now.timeIntervalSince(prompt.queuedAt) > ComposerPrompt.lifetime }
            let left = queue.filter { !settled($0) && !expired($0) }
            guard left.count != queue.count else { continue }
            composerPrompts[terminal] = left.isEmpty ? nil : left
            returnUndelivered(queue.filter { !settled($0) && expired($0) }, from: terminal)
        }
    }

    /// Drops delivered mentions from the composer's prompts, and each prompt they leave empty
    /// (its drain came: the prompts behind it are next). Returns how many were delivered.
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

    /// `terminal`'s agent is gone (released, exited to the shell) or the terminal is: its
    /// prompts will never drain, and their mentions go back to the tray
    /// (`onComposerMentionsReturned`).
    public func dropComposerPrompts(of terminal: ObjectID) {
        guard let queue = composerPrompts.removeValue(forKey: terminal) else { return }
        returnUndelivered(queue, from: terminal)
    }

    /// A deleted object leaves every queued prompt's mentions; a deleted terminal's own prompts
    /// return their mentions to the tray.
    func forgetComposerPrompts(of id: ObjectID) {
        for (terminal, queue) in composerPrompts {
            composerPrompts[terminal] = queue.map { prompt in
                var prompt = prompt
                prompt.mentions.removeAll { $0.target.objectIDs.contains(id) }
                return prompt
            }
        }
        dropComposerPrompts(of: id)
    }

    /// Stages the undelivered mentions of `prompts` again (each target once, those still on the
    /// board) and says so.
    private func returnUndelivered(_ prompts: [ComposerPrompt], from terminal: ObjectID) {
        let mentions = prompts.flatMap(\.mentions)
        let returned = mentions.compactMap { try? stage($0.target) }
        if !returned.isEmpty { onComposerMentionsReturned?(terminal, returned) }
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

        /// The tokens' mentions go with it.
        public var carriesMentions: Bool { !mentions.isEmpty || pastesContext }
    }

    /// The draft as submitted, its tokens the mentions they stood for.
    public let draft: ComposerDraft
    public let deliveries: [Delivery]

    /// Some target takes the tokens' mentions, so they left the tray. Not when every target only
    /// gets an answer, or the text is a slash command or shell escape (`PromptTarget.skipsDrain`):
    /// the tokens stay staged.
    public var takesMentions: Bool { deliveries.contains(where: \.carriesMentions) }

    /// Starts sending `draft` to `targets` (the tray's target first): the tokens' mentions leave
    /// the tray (`Board.withdraw`) when a target takes them, and the composer is left with
    /// `remaining` (empty, or the tokens alone when none does). Nil when there is nothing to
    /// send or nowhere to send it.
    public static func begin(_ draft: ComposerDraft, targets: [ObjectID], on board: Board) -> (send: ComposerSend, remaining: ComposerDraft)? {
        guard !draft.isEmpty, !targets.isEmpty else { return nil }
        let mentions = draft.tokens.map { token in board.tray.first { $0.id == token.id } ?? token }
        let deliveries = ComposerState.unique(targets).compactMap { id -> Delivery? in
            guard let terminal = board.objects[id], terminal.type == .terminal else { return nil }
            let answer = terminal.props["lifecycle"]?["state"]?.string == LifecycleState.blocked.rawValue
            let drains = PromptTarget.drains(terminal)
            let takes = !answer && drains && !PromptTarget.skipsDrain(draft.prompt, in: terminal)
            return Delivery(terminal: id, answer: answer, mentions: takes ? mentions : [], pastesContext: !answer && !drains && !mentions.isEmpty)
        }
        guard !deliveries.isEmpty else { return nil }
        let send = ComposerSend(draft: ComposerDraft(text: draft.text, tokens: mentions), deliveries: deliveries)
        var remaining = ComposerDraft()
        if send.takesMentions {
            board.withdraw(mentions.map(\.id))
        } else {
            for mention in mentions { remaining.insert(mention, at: nil) }
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

    /// Every delivery is done and the text went into `reached`. The composer then shows `draft`,
    /// from `current` (what the user wrote meanwhile): when the text reached no terminal, the
    /// submitted draft comes back ahead of it; when it reached terminals but none that took the
    /// mentions (only a blocked one's answer went in), the tokens come back ahead of it. Their
    /// mentions are staged again. `sent`: the text went in somewhere (it joins the history).
    /// `mentionsReturned`: the second case.
    public func settle(reached: Set<ObjectID>, into current: ComposerDraft, on board: Board) -> (draft: ComposerDraft, sent: Bool, mentionsReturned: Bool) {
        let back: ComposerDraft
        if reached.isEmpty {
            back = draft
        } else if takesMentions, !draft.tokens.isEmpty, !deliveries.contains(where: { $0.carriesMentions && reached.contains($0.terminal) }) {
            back = draft.tokens.reduce(into: ComposerDraft()) { $0.insert($1, at: nil) }
        } else {
            return (current, true, false)
        }
        var restored = back.followed(by: current)
        var caret: Int?
        ComposerSync.edited(&restored, previous: current, caret: &caret, on: board)
        return (restored, !reached.isEmpty, !reached.isEmpty)
    }
}
