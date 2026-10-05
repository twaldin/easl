import AppKit
import CanvasCore

/// The composer (docs/design.md, Composer): the bar at the bottom of the board window where the
/// user writes a prompt for the terminals its "→ target" names. Each staged mention is an inline
/// token (`TokenAttachment`) showing the `[n]` it is sent as and what it points at; a click on a
/// token shows that (`onReveal`). One line while it doesn't have the keyboard, a few once it does
/// (up to `maxLines`). A blocked target's question shows above the text. The bar only shows and
/// edits the draft; `ComposerController` keeps it in step with the tray and sends it.
@MainActor
final class ComposerBar: NSVisualEffectView, NSTextViewDelegate {
    let text = ComposerTextView(usingTextLayoutManager: false)
    private let scroll = NSScrollView()
    private let placeholder = NSTextField(labelWithString: "")
    private let question = NSTextField(labelWithString: "")
    /// "→ name ▾": a click opens `targetMenu` (the board's terminals, several can be checked).
    private let target = NSButton(title: "", target: nil, action: nil)
    /// The draft as last shown or synced, to tell what an edit changed.
    private(set) var shown = ComposerDraft()
    private var answering: String?
    /// The text's undo history (`undoManager(for:)`).
    private let undo = UndoManager()

    /// The user changed the text (typing, deleting, ⌘Z, a paste): the draft before it.
    var onEdit: ((ComposerDraft) -> Void)?
    var onSend: (() -> Void)?
    /// ↑ (true) or ↓ in the text: whether the composer recalled a sent prompt instead of moving.
    var onRecall: ((Bool) -> Bool)?
    var onReveal: ((Mention) -> Void)?
    /// It took or gave up the keyboard.
    var onFocusChange: (() -> Void)?
    var targetMenu: (() -> NSMenu?)?

    /// The text's font, at the chrome text size (`ChromeText`), as are the bar's heights.
    static var font: NSFont { ChromeText.font(.systemFont(ofSize: 13)) }
    static var unfocusedHeight: CGFloat { ChromeText.scaled(34) }
    static let maxLines: CGFloat = 8
    private static let insets = (left: CGFloat(12), right: CGFloat(12), vertical: CGFloat(8))
    private static var questionHeight: CGFloat { ChromeText.scaled(18) }
    private static var labelFont: NSFont { ChromeText.font(.systemFont(ofSize: 12, weight: .medium)) }
    /// What the target label says, to draw it again at a new chrome text size.
    private var targetShown: (title: String?, extra: [String], hasTerminal: Bool) = (nil, [], false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        text.isRichText = true
        text.importsGraphics = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.font = Self.font
        text.textColor = .labelColor
        text.typingAttributes = Self.attributes
        text.textContainerInset = NSSize(width: 0, height: 0)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = true
        text.delegate = self
        text.setAccessibilityLabel("Prompt")
        text.onSend = { [weak self] in self?.onSend?() }
        text.onRecall = { [weak self] older in self?.onRecall?(older) ?? false }
        text.onFocusChange = { [weak self] in self?.focusChanged() }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = text
        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = Self.font
        placeholder.lineBreakMode = .byTruncatingTail
        question.textColor = .systemOrange
        question.font = Self.labelFont
        question.lineBreakMode = .byTruncatingTail
        question.isHidden = true
        target.isBordered = false
        target.setButtonType(.momentaryChange)
        target.alignment = .right
        target.lineBreakMode = .byTruncatingMiddle
        target.toolTip = CanvasBasics.trayTarget
        target.target = self
        target.action = #selector(targetClicked(_:))
        target.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [question, placeholder, scroll, target] as [NSView] { addSubview(view) }
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(490), for: .horizontal)
        showTarget(title: nil, extra: [], hasTerminal: false)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }

    static var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor]
    }

    var hasKeyboard: Bool { window?.firstResponder === text }

    /// Where typing goes in the text (UTF-16), while the composer has the keyboard.
    var caret: Int? { hasKeyboard ? text.selectedRange().location : nil }

    /// The draft the text holds now: each token's mark, with any other attachment (a pasted
    /// copy that lost its mention) left out.
    var draft: ComposerDraft {
        guard let storage = text.textStorage else { return ComposerDraft() }
        var out = ""
        var tokens: [Mention] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            let piece = (storage.string as NSString).substring(with: range)
            if let token = value as? TokenAttachment {
                for _ in 0..<range.length {
                    out += ComposerDraft.mark
                    tokens.append(token.mention)
                }
            } else {
                out += piece.replacingOccurrences(of: ComposerDraft.mark, with: "")
            }
        }
        return ComposerDraft(text: out, tokens: tokens)
    }

    /// Shows `draft`, the caret at `caret` (nil: the end). Its own undo steps go: they edited a
    /// text that changed under them.
    func show(_ draft: ComposerDraft, caret: Int? = nil, board: Board?) {
        let attributed = NSMutableAttributedString()
        var index = 0
        for scalar in draft.text.unicodeScalars {
            if ComposerDraft.mark.unicodeScalars.first == scalar, index < draft.tokens.count {
                let token = TokenAttachment(mention: draft.tokens[index], number: index + 1, changed: board.flatMap { TrayChips.changedNote(draft.tokens[index], on: $0) })
                attributed.append(NSAttributedString(attachment: token))
                attributed.addAttributes(Self.attributes, range: NSRange(location: attributed.length - 1, length: 1))
                index += 1
            } else {
                attributed.append(NSAttributedString(string: String(scalar), attributes: Self.attributes))
            }
        }
        text.textStorage?.setAttributedString(attributed)
        text.typingAttributes = Self.attributes
        undo.removeAllActions()
        let length = (draft.text as NSString).length
        text.setSelectedRange(NSRange(location: min(caret ?? length, length), length: 0))
        shown = draft
        refresh()
    }

    /// The tokens stand for these mentions now (the same marks, restaged under new ids), with
    /// their numbers and changed notes; the text stays as it is.
    func rebind(_ draft: ComposerDraft, board: Board) {
        guard let storage = text.textStorage else { return }
        var index = 0
        var changed = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let token = value as? TokenAttachment, index < draft.tokens.count else { return }
            let mention = draft.tokens[index]
            let note = TrayChips.changedNote(mention, on: board)
            if token.mention != mention || token.number != index + 1 || token.changed != note {
                token.mention = mention
                token.number = index + 1
                token.changed = note
                changed = true
            }
            index += 1
        }
        if changed, let layout = text.layoutManager {
            layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
            text.needsDisplay = true
        }
        shown = draft
        refresh()
    }

    /// The question a blocked target asks, which the text answers; nil when none is blocked.
    func showQuestion(_ text: String?, answering name: String?) {
        question.stringValue = text ?? ""
        question.toolTip = text
        question.isHidden = text == nil
        answering = name
        refresh()
    }

    /// `title`: the tray's target (nil: none yet); `extra`: the other terminals picked in the
    /// menu, which get the prompt too.
    func showTarget(title: String?, extra: [String], hasTerminal: Bool) {
        targetShown = (title, extra, hasTerminal)
        let also = extra.isEmpty ? "" : extra.count == 1 ? " + \(extra[0])" : " + \(extra.count) more"
        let label = title.map { "→ \($0)\(also) ▾" } ?? (hasTerminal ? "→ choose a terminal ▾" : "→ no terminal yet (⌘T)")
        target.attributedTitle = NSAttributedString(string: label, attributes: [
            .font: Self.labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        target.toolTip = extra.isEmpty ? CanvasBasics.trayTarget : "Sends to \(([title].compactMap { $0 } + extra).joined(separator: ", ")). \(CanvasBasics.trayTarget)"
        target.isEnabled = hasTerminal
        refresh()
    }

    /// View › Chrome Text Size changed: the text, its tokens, the question, the placeholder and
    /// the target label redraw at the new size, and the bar takes its new height. The text keeps
    /// its undo history (only its font changes).
    func chromeTextChanged() {
        placeholder.font = Self.font
        question.font = Self.labelFont
        if let storage = text.textStorage {
            storage.addAttribute(.font, value: Self.font, range: NSRange(location: 0, length: storage.length))
            text.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        }
        text.typingAttributes = Self.attributes
        showTarget(title: targetShown.title, extra: targetShown.extra, hasTerminal: targetShown.hasTerminal)
        text.needsDisplay = true
    }

    /// The composer takes the keyboard.
    func focus() {
        text.rememberPrevious()
        window?.makeFirstResponder(text)
    }

    private func focusChanged() {
        refresh()
        onFocusChange?()
    }

    private func refresh() {
        let empty = text.string.isEmpty
        placeholder.isHidden = !empty
        placeholder.stringValue = if let answering {
            "Answer \(answering) · ⌘↩ sends"
        } else if hasKeyboard {
            "Write a prompt; Hyper-click things to mention them here · ⌘↩ sends · Esc leaves"
        } else {
            "Hyper-click (⌃⌥⇧⌘-click) anything, or ⇧⌘M, to point your agent at it · ⌘I writes a prompt"
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // MARK: Layout

    private var lineHeight: CGFloat {
        max(ceil(text.layoutManager?.defaultLineHeight(for: Self.font) ?? 16), TokenCell.height + 2)
    }

    /// The text's height as laid out at the current width.
    private var textHeight: CGFloat {
        guard let layout = text.layoutManager, let container = text.textContainer else { return lineHeight }
        layout.ensureLayout(for: container)
        return max(ceil(layout.usedRect(for: container).height), lineHeight)
    }

    override var intrinsicContentSize: NSSize {
        let questionRow = question.isHidden ? 0 : Self.questionHeight
        guard hasKeyboard else { return NSSize(width: NSView.noIntrinsicMetric, height: Self.unfocusedHeight + questionRow) }
        let lines = min(max(textHeight, lineHeight * 2), lineHeight * Self.maxLines)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(Self.unfocusedHeight, lines + Self.insets.vertical * 2) + questionRow)
    }

    override func layout() {
        super.layout()
        let insets = Self.insets
        var top: CGFloat = 0
        if !question.isHidden {
            question.frame = NSRect(x: insets.left, y: 6, width: bounds.width - insets.left - insets.right, height: Self.questionHeight - 2)
            top = Self.questionHeight
        }
        let targetSize = target.intrinsicContentSize
        let targetWidth = min(ceil(targetSize.width), bounds.width * 0.45)
        let rowHeight = bounds.height - top
        let firstLine = hasKeyboard ? insets.vertical + lineHeight / 2 : rowHeight / 2
        target.frame = NSRect(x: bounds.maxX - insets.right - targetWidth, y: top + (firstLine - targetSize.height / 2).rounded(), width: targetWidth, height: targetSize.height)
        let textWidth = max(0, target.frame.minX - 12 - insets.left)
        text.maxSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        text.setFrameSize(NSSize(width: textWidth, height: text.frame.height))
        // One line while it hasn't the keyboard: the last, where new tokens go.
        let last = lastLine
        let textHeight = hasKeyboard ? rowHeight - insets.vertical * 2 : max(lineHeight, last.height)
        scroll.frame = NSRect(x: insets.left, y: top + ((rowHeight - textHeight) / 2).rounded(), width: textWidth, height: textHeight)
        text.minSize = NSSize(width: textWidth, height: textHeight)
        text.setFrameSize(NSSize(width: textWidth, height: max(textHeight, self.textHeight)))
        let size = placeholder.intrinsicContentSize
        placeholder.frame = NSRect(x: insets.left, y: scroll.frame.minY + ((lineHeight - size.height) / 2).rounded(), width: textWidth, height: size.height)
        if !hasKeyboard {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: last.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// The text's last line as laid out (empty: none).
    private var lastLine: NSRect {
        guard let layout = text.layoutManager, let container = text.textContainer else { return .zero }
        layout.ensureLayout(for: container)
        guard layout.numberOfGlyphs > 0 else { return .zero }
        return layout.lineFragmentRect(forGlyphAt: layout.numberOfGlyphs - 1, effectiveRange: nil)
    }

    // MARK: NSTextViewDelegate

    /// The composer's own undo history, never the window's (a note being edited keeps its own):
    /// replacing the draft from outside clears only this.
    func undoManager(for view: NSTextView) -> UndoManager? {
        undo
    }

    func textDidChange(_ notification: Notification) {
        let previous = shown
        shown = draft
        refresh()
        onEdit?(previous)
    }

    func textView(_ textView: NSTextView, clickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        guard let token = cell.attachment as? TokenAttachment else { return }
        onReveal?(token.mention)
    }

    /// Typing after a token never takes its look.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any], toAttributes newTypingAttributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        Self.attributes
    }

    @objc private func targetClicked(_ sender: NSButton) {
        guard let menu = targetMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }
}

/// The composer's text: ⌘↩ sends, Esc gives the keyboard back to whoever had it, ↑ and ↓ in
/// an empty composer walk the board's sent prompts. Pastes come in as plain text, and a copy
/// writes each token as its `[n]`.
@MainActor
final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onRecall: ((Bool) -> Bool)?
    var onFocusChange: (() -> Void)?
    /// What had the keyboard before the composer took it, to give it back on Esc.
    weak var previous: NSResponder?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The window offers key equivalents to every view; only the focused composer sends.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            onSend?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)) {
            leave()
        } else {
            super.doCommand(by: selector)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        leave()
    }

    override func moveUp(_ sender: Any?) {
        if onRecall?(true) != true { super.moveUp(sender) }
    }

    override func moveDown(_ sender: Any?) {
        if onRecall?(false) != true { super.moveDown(sender) }
    }

    /// Esc: the keyboard goes back to the terminal, tile or board that had it. A note whose edit
    /// ended as the composer took the keyboard (its hidden editor) is entered again through its
    /// own keyboard path; anything else no longer shown leaves the keyboard with the board.
    func leave() {
        guard let window else { return }
        let before = previous === self ? nil : previous
        if let view = before as? NSView, view.window === window, view.isHiddenOrHasHiddenAncestor {
            var ancestor: NSView? = view
            while let current = ancestor {
                if let note = current as? NoteTile, note.enterKeyboard() { return }
                ancestor = current.superview
            }
        }
        CanvasView.returnKeyboard(to: before, in: window)
    }

    /// Remembers what has the keyboard, before the composer takes it (⌘I, a click): by the time
    /// `becomeFirstResponder` runs, the window no longer says.
    func rememberPrevious() {
        guard let current = window?.firstResponder, current !== self, current !== window else { return }
        previous = current
    }

    override func mouseDown(with event: NSEvent) {
        rememberPrevious()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        DispatchQueue.main.async { [weak self] in self?.onFocusChange?() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        DispatchQueue.main.async { [weak self] in self?.onFocusChange?() }
        return true
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else { return false }
        var out = ""
        for range in selectedRanges.map(\.rangeValue) {
            storage.enumerateAttribute(.attachment, in: range) { value, part, _ in
                if let token = value as? TokenAttachment {
                    out += TrayChips.badge(token.number)
                } else {
                    out += (storage.string as NSString).substring(with: part).replacingOccurrences(of: ComposerDraft.mark, with: "")
                }
            }
        }
        pboard.clearContents()
        return pboard.setString(out, forType: .string)
    }
}

/// One token in the composer's text: a staged mention, drawn as its chip.
final class TokenAttachment: NSTextAttachment {
    var mention: Mention
    var number: Int
    /// "page changed" or "edited" when its target changed since it was staged.
    var changed: String?

    @MainActor init(mention: Mention, number: Int, changed: String?) {
        self.mention = mention
        self.number = number
        self.changed = changed
        super.init(data: nil, ofType: nil)
        attachmentCell = TokenCell()
    }

    required init?(coder: NSCoder) { fatalError("unused") }
}

/// Draws a token as the tray's chips were drawn: purple, its `[n]`, its label cut to fit
/// (`TrayChips.fittedLabel`: a code location keeps its lines) and its changed note, at the
/// chrome text size (`ChromeText`).
final class TokenCell: NSTextAttachmentCell {
    @MainActor static var height: CGFloat { ChromeText.scaled(18) }
    @MainActor private static var padding: CGFloat { ChromeText.scaled(6) }
    @MainActor private static var labelLimit: CGFloat { ChromeText.scaled(200) }
    @MainActor private static var numberFont: NSFont { ChromeText.font(.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)) }
    @MainActor private static var labelFont: NSFont { ChromeText.font(.systemFont(ofSize: 12)) }

    private var token: TokenAttachment? { attachment as? TokenAttachment }

    @MainActor private var pieces: (number: NSAttributedString, label: NSAttributedString) {
        guard let token else { return (NSAttributedString(), NSAttributedString()) }
        let labelFont = Self.labelFont, limit = Self.labelLimit
        let number = NSAttributedString(string: TrayChips.badge(token.number) + " ", attributes: [.font: Self.numberFont, .foregroundColor: NSColor.secondaryLabelColor])
        let measure: (String) -> CGFloat = { ceil(NSAttributedString(string: $0, attributes: [.font: labelFont]).size().width) }
        var label = TrayChips.fittedLabel(token.mention, width: limit, measure: measure)
        if measure(label) > limit {
            while label.count > 1, measure(label + "…") > limit { label.removeLast() }
            label += "…"
        }
        if let changed = token.changed { label += " · \(changed)" }
        return (number, NSAttributedString(string: label, attributes: [.font: labelFont, .foregroundColor: NSColor.labelColor]))
    }

    nonisolated override func cellSize() -> NSSize {
        MainActor.assumeIsolated {
            let (number, label) = pieces
            return NSSize(width: ceil(number.size().width + label.size().width) + Self.padding * 2, height: Self.height)
        }
    }

    /// Centred on the text's line: as far below the baseline as the chip is taller than the
    /// text's cap height, about.
    nonisolated override func cellBaselineOffset() -> NSPoint {
        MainActor.assumeIsolated { NSPoint(x: 0, y: -ChromeText.scaled(4)) }
    }

    nonisolated override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        MainActor.assumeIsolated {
            let chip = cellFrame.insetBy(dx: 1, dy: 0)
            NSColor.systemPurple.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()
            let (number, label) = pieces
            let y = chip.minY + ((chip.height - label.size().height) / 2).rounded()
            number.draw(at: NSPoint(x: chip.minX + Self.padding - 1, y: y))
            label.draw(at: NSPoint(x: chip.minX + Self.padding - 1 + number.size().width, y: y))
        }
    }
}
