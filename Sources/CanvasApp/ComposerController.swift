import AppKit
import CanvasCore

/// The composer's behaviour for one board window (docs/design.md, Composer): keeps the bar's
/// tokens and the tray one-to-one (`ComposerSync`), sends the draft to every target through
/// `agent.prompt` (`send`), walks the board's sent prompts on ↑ and ↓, and keeps the draft, the
/// history and the extra targets for this user beside the boards (`AppPaths.composer`), never in
/// the board file.
@MainActor
final class ComposerController {
    let board: Board
    let bar: ComposerBar
    private(set) var state: ComposerState
    /// The tray's target, as the window settles it (`PromptTarget`).
    var promptTarget: () -> ObjectID? = { nil }
    /// One terminal's `agent.prompt` from the user (`ApiRouter.composerPrompt`).
    var send: ((_ text: String, _ terminal: ObjectID, _ mentions: [MentionTarget], _ answering: Bool) async throws -> Void)?
    /// Says something for a moment (`CanvasView.showNotice`).
    var notice: (String) -> Void = { _ in }
    /// How the composer names a terminal (as the target menu does).
    var name: (ObjectID) -> String = { $0 }
    /// The extra targets changed, for the target label.
    var onTargetsChange: (() -> Void)?

    private let file: URL
    /// The composer is changing the tray itself: the tray events that causes are already in the draft.
    private var syncing = false
    /// The sent prompt ↑/↓ shows (an index into the history; the count for the empty draft past
    /// the newest) and the draft as recalled, while it is unchanged.
    private var recall: (index: Int, shown: ComposerDraft)?
    /// Mentions a prompt just took to the tray's target, until its integration drains them (or
    /// `inFlightTimeout` passes): they get no token, and stay first in the tray, so the prompt's
    /// `[n]` stay theirs even if the user stages more before the drain.
    private var inFlight: [MentionID] = []
    private var saveWork: DispatchWorkItem?
    static let inFlightTimeout: TimeInterval = 30

    init(board: Board, bar: ComposerBar, file: URL) {
        self.board = board
        self.bar = bar
        self.file = file
        state = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ComposerState.self, from: $0) } ?? ComposerState()
        state.alsoTo.removeAll { board.objects[$0]?.type != .terminal }
        var draft = state.draft
        syncing = true
        _ = ComposerSync.trayChanged(&draft, caret: nil, on: board)
        syncing = false
        state.draft = draft
        bar.show(draft, board: board)
        bar.onEdit = { [weak self] previous in self?.edited(previous: previous) }
        bar.onSend = { [weak self] in self?.sendDraft() }
        bar.onRecall = { [weak self] older in self?.recall(older: older) ?? false }
    }

    /// The terminals a send goes to: the tray's target first, then the others picked in the menu.
    var targets: [ObjectID] {
        guard let primary = promptTarget() else { return [] }
        return [primary] + state.alsoTo.filter { $0 != primary && board.objects[$0]?.type == .terminal }
    }

    func setAlsoTo(_ ids: [ObjectID]) {
        state.alsoTo = ids
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
        inFlight.removeAll { id in !board.tray.contains { $0.id == id } }
        var draft = bar.draft
        let before = draft
        let caret = ComposerSync.trayChanged(&draft, caret: bar.caret, on: board, holding: inFlight)
        if draft.text != before.text || draft.tokens.map(\.id) != before.tokens.map(\.id) {
            bar.show(draft, caret: caret, board: board)
        } else {
            bar.rebind(draft, board: board)
        }
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
        ComposerSync.edited(&draft, previous: previous, caret: &caret, on: board, holding: inFlight)
        if draft.text != typed.text {
            bar.show(draft, caret: caret, board: board)
        } else {
            bar.rebind(draft, board: board)
        }
        state.draft = draft
        if let recall, recall.shown != draft { self.recall = nil }
        scheduleSave()
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
        ComposerSync.edited(&draft, previous: current, caret: &caret, on: board, holding: inFlight)
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

    /// ⌘↩: the prompt to every target. The tray's target takes the mentions with its prompt as
    /// any prompt does (its integration drains the tray); another agent gets them handed to its
    /// next prompt with the same numbers; a terminal without an integration gets their context
    /// pasted ahead of the text, as Hyper-V pastes it. A blocked target takes the text as its
    /// answer, without the mentions.
    func sendDraft() {
        let draft = bar.draft
        guard !draft.isEmpty, let send else { return }
        let targets = self.targets
        guard let primary = targets.first else {
            return notice(self.board.objects.values.contains { $0.type == .terminal } ? "Pick a terminal to send to: click → at the right of the composer" : "No terminal to send to yet: ⌘T opens one")
        }
        self.board.arrangeTray(inFlight + draft.tokens.map(\.id))
        let mentions = draft.tokens.compactMap { token in self.board.tray.first { $0.id == token.id } }
        let prompt = draft.prompt
        let board = self.board
        Task { @MainActor [weak self] in
            var failures: [String] = []
            var sent = false, primaryTakes = false, delivered = false
            for id in targets {
                guard let terminal = board.objects[id] else { continue }
                let answering = Self.isBlocked(terminal)
                var text = prompt
                var handing: [MentionTarget] = []
                let drains = PromptTarget.drains(terminal)
                if !answering, !mentions.isEmpty {
                    if !drains {
                        // Ends on its own line, as Hyper-V's paste does.
                        text = await board.context(for: mentions, caller: id) + "\n" + prompt
                    } else if id != primary {
                        handing = mentions.map(\.target)
                    }
                }
                do {
                    try await send(text, id, handing, answering)
                    sent = true
                    if !answering, !mentions.isEmpty {
                        if id == primary, drains { primaryTakes = true } else { delivered = true }
                    }
                } catch {
                    let message = (error as? ApiRouter.Failure)?.message ?? error.localizedDescription
                    failures.append("\(self?.name(id) ?? id): \(message)")
                }
            }
            self?.sent(draft, mentions: mentions, sent: sent, primaryTakes: primaryTakes, delivered: delivered, failures: failures)
        }
    }

    private func sent(_ draft: ComposerDraft, mentions: [Mention], sent: Bool, primaryTakes: Bool, delivered: Bool, failures: [String]) {
        if !failures.isEmpty { notice("Not sent to " + failures.joined(separator: "; ")) }
        guard sent else { return }
        state.record(draft)
        recall = nil
        let ids = mentions.map(\.id)
        syncing = true
        if primaryTakes {
            inFlight += ids
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.inFlightTimeout) { [weak self] in
                guard let self else { return }
                self.inFlight.removeAll { ids.contains($0) }
                self.trayChanged()
            }
        } else if delivered {
            board.commit(ids)
        }
        // What wasn't delivered (every target took the text as an answer) stays staged.
        let kept = primaryTakes || delivered ? [] : draft.tokens.filter { token in board.tray.contains { $0.id == token.id } }
        var next = ComposerDraft()
        for token in kept { next.insert(token, at: nil) }
        syncing = false
        bar.show(next, board: board)
        state.draft = next
        board.arrangeTray(inFlight + next.tokens.map(\.id))
        scheduleSave()
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
