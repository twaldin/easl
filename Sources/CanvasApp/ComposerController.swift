import AppKit
import CanvasCore

/// The composer's behaviour for one board window (docs/design.md, Composer): keeps the bar's
/// tokens and the tray one-to-one (`ComposerSync`), sends the draft to every target through
/// `agent.prompt` (`ComposerSend`, `send`), walks the board's sent prompts on ↑ and ↓, and keeps
/// the draft, the history and the extra targets for this user beside the boards
/// (`AppPaths.composer`), never in the board file.
@MainActor
final class ComposerController {
    let board: Board
    let bar: ComposerBar
    private(set) var state: ComposerState
    /// The tray's target, as the window settles it (`PromptTarget`).
    var promptTarget: () -> ObjectID? = { nil }
    /// One terminal's `agent.prompt` from the user (`ApiRouter.composerPrompt`).
    var send: ((_ text: String, _ terminal: ObjectID, _ mentions: [Mention], _ answer: Bool) async throws -> Void)?
    /// Says something for a moment (`CanvasView.showNotice`).
    var notice: (String) -> Void = { _ in }
    /// How the composer names a terminal (as the target menu does).
    var name: (ObjectID) -> String = { $0 }
    /// The extra targets changed, for the target label.
    var onTargetsChange: (() -> Void)?

    /// Where the draft, history and targets are kept; nil keeps them in memory only (a remote
    /// board, which leaves nothing on disk).
    private let file: URL?
    /// The composer is changing the tray itself: the tray events that causes are already in the draft.
    private var syncing = false
    /// The sent prompt ↑/↓ shows (an index into the history; the count for the empty draft past
    /// the newest) and the draft as recalled, while it is unchanged.
    private var recall: (index: Int, shown: ComposerDraft)?
    private var saveWork: DispatchWorkItem?

    init(board: Board, bar: ComposerBar, file: URL?) {
        self.board = board
        self.bar = bar
        self.file = file
        // A damaged file never reaches the sync with marks its tokens don't match.
        state = (file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(ComposerState.self, from: $0) } ?? ComposerState()).repaired
        state.alsoTo.removeAll { board.objects[$0]?.type != .terminal }
        var draft = state.draft
        syncing = true
        _ = ComposerSync.trayChanged(&draft, caret: nil, on: board)
        state.draft = draft
        // Sent as the app quit, before any terminal took it.
        let recovering = !state.outgoing.isEmpty
        state.recoverOutgoing(on: board)
        syncing = false
        bar.show(state.draft, board: board)
        if recovering { scheduleSave() }
        bar.onEdit = { [weak self] previous in self?.edited(previous: previous) }
        // Prompts their agent never drained come back after a while (`Board.expireComposerPrompts`),
        // checked every minute while the window is open.
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.board.expireComposerPrompts()
            }
        }
        bar.onSend = { [weak self] in self?.sendDraft() }
        bar.onRecall = { [weak self] older in self?.recall(older: older) ?? false }
    }

    /// The terminals a send goes to, each once: the tray's target first, then the others picked
    /// in the menu.
    var targets: [ObjectID] {
        guard let primary = promptTarget() else { return [] }
        return ComposerState.unique([primary] + state.alsoTo.filter { board.objects[$0]?.type == .terminal })
    }

    func setAlsoTo(_ ids: [ObjectID]) {
        state.alsoTo = ComposerState.unique(ids)
        scheduleSave()
        onTargetsChange?()
    }

    /// Terminals gone from the board leave the targets.
    func objectsChanged() {
        let kept = state.alsoTo.filter { board.objects[$0]?.type == .terminal }
        if kept != state.alsoTo { setAlsoTo(kept) }
        refreshQuestion()
    }

    // MARK: Tray and draft

    /// The tray changed (a Hyper-click, ⇧⌘M, Remove Mention, the API, a prompt typed in the
    /// terminal taking it): tokens follow, new ones at the caret while the composer has the
    /// keyboard, else at the end.
    func trayChanged() {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        var draft = bar.draft
        let before = draft
        let caret = ComposerSync.trayChanged(&draft, caret: bar.caret, on: board)
        show(draft, caret: caret, replacing: before)
        state.draft = draft
        scheduleSave()
    }

    private func edited(previous: ComposerDraft) {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        var draft = bar.draft
        let typed = draft
        var caret = bar.caret
        ComposerSync.edited(&draft, previous: previous, caret: &caret, on: board)
        show(draft, caret: caret, replacing: typed)
        state.draft = draft
        if let recall, recall.shown != draft { self.recall = nil }
        scheduleSave()
    }

    /// The bar shows `draft`: rebuilt when its text or tokens changed, else its tokens rebound
    /// (numbers, labels), keeping the text and its undo.
    private func show(_ draft: ComposerDraft, caret: Int?, replacing before: ComposerDraft) {
        if draft.text != before.text || draft.tokens.map(\.id) != before.tokens.map(\.id) {
            bar.show(draft, caret: caret, board: board)
        } else {
            bar.rebind(draft, board: board)
        }
    }

    /// ↑ (older) in an empty composer, or while it shows a recalled prompt unchanged: the
    /// board's earlier prompt, tokens staged again; ↓ walks back to the empty composer.
    private func recall(older: Bool) -> Bool {
        let current = bar.draft
        let index: Int
        if let recall, recall.shown == current {
            index = recall.index
        } else if older, current.isEmpty, !state.history.isEmpty {
            index = state.history.count
        } else {
            return false
        }
        let next = index + (older ? -1 : 1)
        guard next >= 0, next <= state.history.count else { return true }
        var draft = next < state.history.count ? state.history[next] : ComposerDraft()
        var caret: Int?
        syncing = true
        ComposerSync.edited(&draft, previous: current, caret: &caret, on: board)
        syncing = false
        bar.show(draft, board: board)
        state.draft = draft
        recall = next < state.history.count ? (next, draft) : nil
        scheduleSave()
        return true
    }

    // MARK: Questions

    /// A blocked target's question shows above the text, which answers it.
    func refreshQuestion() {
        let blocked = targets.compactMap { id in board.objects[id].flatMap { Self.isBlocked($0) ? $0 : nil } }
        guard let first = blocked.first else { return bar.showQuestion(nil, answering: nil) }
        let message = first.props["lifecycle"]?["message"]?.string ?? "a question or approval"
        let more = blocked.count > 1 ? " (+\(blocked.count - 1) more blocked)" : ""
        let answered = blocked.count == targets.count ? blocked.map { name($0.id) }.joined(separator: " and ") : nil
        bar.showQuestion("\(name(first.id)) asks: \(message)\(more)", answering: answered)
    }

    private static func isBlocked(_ terminal: CanvasObject) -> Bool {
        terminal.props["lifecycle"]?["state"]?.string == LifecycleState.blocked.rawValue
    }

    // MARK: Sending

    /// ⌘↩: the prompt to every target (`ComposerSend`). The submitted draft leaves the composer
    /// at once and its mentions leave the tray; each target that drains gets them queued with
    /// its own prompt, numbered from 1; a terminal without an integration gets their context
    /// pasted ahead of the text; a blocked target takes the text as its answer, alone. What the
    /// user types or stages while it goes in is the next draft. When no target took the text it
    /// comes back ahead of that, and when none took the mentions, the tokens do.
    func sendDraft() {
        guard let send else { return }
        let targets = self.targets
        guard !targets.isEmpty else {
            if !bar.draft.isEmpty {
                notice(board.objects.values.contains { $0.type == .terminal } ? "Pick a terminal to send to: click → at the right of the composer" : "No terminal to send to yet: ⌘T opens one")
            }
            return
        }
        syncing = true
        guard let (outgoing, remaining) = ComposerSend.begin(bar.draft, targets: targets, on: board) else {
            syncing = false
            return
        }
        bar.show(remaining, board: board)
        board.arrangeTray(remaining.tokens.map(\.id))
        syncing = false
        state.draft = remaining
        state.sending(outgoing.draft)
        recall = nil
        save()
        if !outgoing.takesMentions, !outgoing.draft.tokens.isEmpty, !outgoing.deliveries.allSatisfy(\.answer) {
            notice("Mentions stay staged: a slash command or shell escape doesn't take them")
        }
        let board = self.board
        Task { @MainActor [weak self] in
            var failures: [String] = []
            var reached: Set<ObjectID> = []
            for delivery in outgoing.deliveries {
                let text = await outgoing.text(for: delivery, on: board)
                do {
                    try await send(text, delivery.terminal, delivery.mentions, delivery.answer)
                    if reached.isEmpty {
                        self?.state.reached(outgoing.draft)
                        self?.scheduleSave()
                    }
                    reached.insert(delivery.terminal)
                } catch {
                    let message = (error as? ApiRouter.Failure)?.message ?? error.localizedDescription
                    failures.append("\(self?.name(delivery.terminal) ?? delivery.terminal): \(message)")
                }
            }
            self?.finished(outgoing, reached: reached, failures: failures)
        }
    }

    private func finished(_ outgoing: ComposerSend, reached: Set<ObjectID>, failures: [String]) {
        syncing = true
        let current = bar.draft
        let settled = outgoing.settle(reached: reached, into: current, on: board)
        if settled.draft != current { bar.show(settled.draft, board: board) }
        syncing = false
        state.draft = settled.draft
        if !settled.sent { state.returned(outgoing.draft) }
        if !failures.isEmpty {
            notice((settled.sent ? "Not sent to " : "Nothing sent: ") + failures.joined(separator: "; ") + (settled.mentionsReturned ? ". The mentions stay staged" : ""))
        }
        scheduleSave()
    }

    /// Mentions a terminal never took (its agent went, the prompt waited too long) are staged
    /// again (`Board.onComposerMentionsReturned`); their tokens come with the tray change.
    func mentionsReturned(from terminal: ObjectID, count: Int) {
        notice("\(count == 1 ? "A mention" : "\(count) mentions") sent to \(name(terminal)) came back: its agent never took \(count == 1 ? "it" : "them")")
    }

    // MARK: Saving

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes the draft, the history and the extra targets now (window closing, app quitting).
    func save() {
        saveWork?.cancel()
        saveWork = nil
        state.draft = bar.draft
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: file, options: .atomic)
        } catch {
            NSLog("easl: composer state for board \(board.id) not saved: \(error)")
        }
    }
}
