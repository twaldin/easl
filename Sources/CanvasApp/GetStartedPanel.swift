import AppKit
import CanvasCore

/// Help › Get Started (`GetStarted`): a floating panel inside the board window, never modal, at
/// the leading side so the practice note beside it and the tray below stay in view. It says
/// what Hyper-click is in one sentence, the three ways to do it, then walks through one:
/// Hyper-click the practice note (the chip shows in the tray), then send it with a prompt.
/// Each step turns into a green check when done. ×, Esc while it has the keyboard (or on the
/// canvas once nothing is selected), Done, or the menu item again close it; Tab and ⇧Tab walk
/// its buttons (from the canvas too), Space presses one. Closing is what stops it opening at
/// launch.
@MainActor
final class GetStartedPanel: NSVisualEffectView {
    static let width: CGFloat = 400
    /// Its offset from the window's leading edge.
    static let leading: CGFloat = 20
    static let karabiner = URL(string: "https://karabiner-elements.pqrs.org")!

    /// What the tray's target is, for step 2's words.
    enum Target: Equatable {
        /// No terminal on the board.
        case none
        /// Terminals, none the target yet.
        case choose
        /// An agent that takes the tray with its next prompt.
        case agent
        /// A terminal without an integrated agent (a shell, aider): Hyper-V pastes.
        case plain
    }

    var isOpen: Bool { !isHidden }
    var onClose: (() -> Void)?
    var onNewTerminal: (() -> Void)?
    var onShowPractice: (() -> Void)?

    private let stepOne = StepRow(number: 1)
    private let stepTwo = StepRow(number: 2)
    private let newTerminal = KeyButton(title: "New Terminal  ⌘T", target: nil, action: nil)
    private let showPractice = KeyButton(title: "Show Practice Note", target: nil, action: nil)
    private let finish = KeyButton(title: "Close", target: nil, action: nil)
    private let closeButton = KeyButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Get Started") ?? NSImage(), target: nil, action: nil)
    private let karabiner = KeyButton(title: "Get Karabiner-Elements \u{2197}", target: nil, action: nil)
    private let footer = GetStartedPanel.wrapping("", size: 12, color: .secondaryLabelColor)
    private weak var previousResponder: NSResponder?
    private var shown: (GetStarted.Step, Target)?

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Get Started")

        let title = NSTextField(labelWithString: "Get Started")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close (Esc). Help › Get Started opens it again."
        let header = NSStackView(views: [title, NSView(), closeButton])
        header.orientation = .horizontal

        let lead = Self.wrapping("Hyper-click (hold ⌃⌥⇧⌘ and click) a line of code, a note, a page element or a command's output, and it goes with your next prompt to your agent.", size: 13, color: .labelColor)

        let chord = Self.item("⌃⌥⇧⌘-click", "hold Control, Option, Shift and Command, and click. On a PC keyboard: Ctrl+Alt+Shift+Win.")
        let capsLock = Self.item("Caps Lock", "one key for all four with Karabiner-Elements (free): Complex Modifications › Add predefined rule › \u{201C}Change caps_lock to command+control+option+shift\u{201D}.")
        karabiner.target = self
        karabiner.action = #selector(karabinerClicked)
        karabiner.isBordered = false
        karabiner.attributedTitle = NSAttributedString(string: karabiner.title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.linkColor])
        karabiner.toolTip = "Opens karabiner-elements.pqrs.org in your browser. easl installs nothing."
        karabiner.setAccessibilityLabel("Get Karabiner-Elements, opens its website")
        let keyboard = Self.item("⇧⌘M", "from the keyboard (Edit › Mention): mentions the selected tile, or the text you selected in it.")

        for button in [newTerminal, showPractice, finish] {
            button.bezelStyle = .push
            button.controlSize = .regular
            button.target = self
        }
        newTerminal.action = #selector(newTerminalClicked)
        showPractice.action = #selector(showPracticeClicked)
        finish.action = #selector(closeClicked)
        showPractice.toolTip = "Scrolls to the practice note, or puts it back if you closed it"
        stepTwo.accessory = newTerminal
        let buttons = NSStackView(views: [showPractice, NSView(), finish])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [header, lead, Self.heading("Three ways to Hyper-click"), chord, keyboard, capsLock, karabiner,
                                        Self.heading("Try it"), stepOne, stepTwo, footer, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: header)
        stack.setCustomSpacing(2, after: capsLock)
        stack.setCustomSpacing(10, after: karabiner)
        stack.setCustomSpacing(10, after: stepTwo)
        stack.setCustomSpacing(12, after: footer)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        show(.point(unstaged: false), target: .none)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Esc closes; Return does too once the walk-through is done. Not a key equivalent on
    /// Done: Return typed into a terminal must stay the terminal's. Tab and ⇧Tab walk the
    /// buttons, the keys reaching here from the one that has the keyboard.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 53: close()
        case 36, 76 where shown?.0 == .done: close()
        case 48 where modifiers.isEmpty || modifiers == .shift: step(backward: modifiers == .shift)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    /// Opens with the keyboard, so Esc closes it and Tab reaches its buttons.
    func open() {
        guard let window else { return }
        isHidden = false
        previousResponder = window.firstResponder
        window.makeFirstResponder(self)
    }

    /// Tab (⇧Tab) on the canvas: the first (last) button takes the keyboard; the canvas gets it
    /// back past the last (first) one, or when the panel closes.
    func takeKeyboard(backward: Bool) {
        guard isOpen, let window, let button = backward ? keyButtons.last : keyButtons.first else { return }
        if !hasKeyboard { previousResponder = window.firstResponder }
        window.makeFirstResponder(button)
    }

    /// Its buttons in reading order, as Tab walks them: whichever show now.
    private var keyButtons: [NSButton] {
        [closeButton, karabiner, newTerminal, showPractice, finish].filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    private var hasKeyboard: Bool {
        (window?.firstResponder as? NSView).map { $0 === self || $0.isDescendant(of: self) } ?? false
    }

    /// The next (previous) button takes the keyboard; past the ends, what had it before.
    private func step(backward: Bool) {
        guard let window else { return }
        let buttons = keyButtons
        let index = buttons.firstIndex { $0 === window.firstResponder }
        let next = index.map { $0 + (backward ? -1 : 1) } ?? (backward ? buttons.count - 1 : 0)
        if buttons.indices.contains(next) {
            window.makeFirstResponder(buttons[next])
        } else {
            CanvasView.returnKeyboard(to: previousResponder, in: window)
        }
    }

    /// Hides the panel and hands the keyboard back, as easl Basics does.
    func close() {
        guard isOpen else { return }
        let hadKeyboard = hasKeyboard
        isHidden = true
        if hadKeyboard, let window { CanvasView.returnKeyboard(to: previousResponder, in: window) }
        previousResponder = nil
        onClose?()
    }

    /// Shows the walk-through at `step`, step 2 worded for where the mention would go.
    func show(_ step: GetStarted.Step, target: Target) {
        guard shown.map({ $0 != (step, target) }) ?? true else { return }
        let previous = shown?.0
        shown = (step, target)
        switch step {
        case .point(let unstaged):
            stepOne.set(done: false, active: true, unstaged
                ? "It came off the tray: a second Hyper-click on something staged, or deleting its token, takes it back off. Hyper-click the practice note once more."
                : "Hyper-click a paragraph of the practice note, or select it and press ⇧⌘M. A purple chip appears in the tray at the bottom.")
            stepTwo.set(done: false, active: false, "Send it: ask your agent anything, and the chip goes with your prompt.")
        case .send:
            stepOne.set(done: true, active: false, "Staged. The purple token in the tray is your mention; deleting it takes it back off.")
            stepTwo.set(done: false, active: true, Self.sendText(target))
        case .done:
            stepOne.set(done: true, active: false, "Staged. The purple chip in the tray was your mention.")
            stepTwo.set(done: true, active: false, "Sent. Your agent got the practice note with your prompt; its answer is in its terminal.")
        }
        newTerminal.isHidden = step != .send || target != .none
        footer.stringValue = step == .done
            ? "That's the whole loop: Hyper-click what you mean, then prompt. Help › easl Basics explains the rest; Help › Get Started opens this again."
            : "Close this any time; Help › Get Started opens it again."
        finish.title = step == .done ? "Done" : "Close"
        showPractice.isHidden = step == .done
        guard let previous, previous != step else { return }
        switch step {
        case .send: announce("Staged. Step 2: send it with a prompt.")
        case .done: announce("Sent. Your agent got the mention with your prompt.")
        case .point(true): announce("The mention came off the tray. Hyper-click the practice note once more.")
        case .point: break
        }
    }

    private static func sendText(_ target: Target) -> String {
        switch target {
        case .none:
            "Press ⌘T for a terminal, run claude, codex, omp or opencode in it, and ask something, like \u{201C}what does this note say?\u{201D}. The chip waits in the tray for your prompt; answering the agent's own questions (Codex asks to trust the folder) doesn't use it."
        case .choose:
            "Click \u{201C}\u{2192} choose a terminal\u{201D} at the right of the tray to pick your agent's terminal, then ask it something there."
        case .agent:
            "Press ⌘I and type a question after the token, like \u{201C}what does this note say?\u{201D}, then ⌘↩. Or ask in your agent's terminal and press Return: the mention goes with that prompt, to the terminal the tray's \u{2192} names; answering the agent's own questions doesn't use it."
        case .plain:
            "In the terminal, run claude, codex, omp or opencode and ask it something, like \u{201C}what does this note say?\u{201D}. The chip goes with your prompt. Any other program: ⌃⌥⇧⌘V pastes it in."
        }
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    @objc private func closeClicked() { close() }
    @objc private func newTerminalClicked() { onNewTerminal?() }
    @objc private func showPracticeClicked() { onShowPractice?() }
    @objc private func karabinerClicked() { NSWorkspace.shared.open(Self.karabiner) }

    fileprivate static func wrapping(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.isSelectable = false
        label.preferredMaxLayoutWidth = width - 32
        return label
    }

    /// easl Basics' section heading: uppercase 11 pt bold in the label color.
    private static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.labelColor, .kern: 0.6,
        ]))
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityLabel(text)
        return label
    }

    /// easl Basics' item: the term in semibold, then " — text".
    private static func item(_ term: String, _ text: String) -> NSTextField {
        let string = NSMutableAttributedString(string: term, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        string.append(NSAttributedString(string: " — \(text)", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
        let label = NSTextField(labelWithAttributedString: string)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = width - 32
        return label
    }
}

/// One step of the walk-through: a numbered circle that turns into a green check, its text
/// (secondary until it's the step to do), and an optional button under the text.
@MainActor
private final class StepRow: NSStackView {
    private let number: Int
    private let icon = NSImageView()
    private let text = GetStartedPanel.wrapping("", size: 13, color: .labelColor)
    private let column = NSStackView()

    var accessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let accessory { column.addArrangedSubview(accessory) }
        }
    }

    init(number: Int) {
        self.number = number
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .top
        spacing = 8
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        text.preferredMaxLayoutWidth = GetStartedPanel.width - 32 - 26
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.addArrangedSubview(text)
        addArrangedSubview(icon)
        addArrangedSubview(column)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func set(done: Bool, active: Bool, _ string: String) {
        icon.image = NSImage(systemSymbolName: done ? "checkmark.circle.fill" : "\(number).circle", accessibilityDescription: nil)
        icon.contentTintColor = done ? .systemGreen : active ? .labelColor : .secondaryLabelColor
        text.stringValue = string
        text.textColor = done || active ? .labelColor : .secondaryLabelColor
        setAccessibilityLabel("Step \(number), \(done ? "done" : active ? "to do now" : "next"): \(string)")
    }
}

/// A button Tab reaches whatever the system's keyboard navigation setting says (Get Started is
/// the first thing a keyboard-only user meets, and its buttons never got a focus ring); Space
/// presses it.
private final class KeyButton: NSButton {
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor && isEnabled }
    override var acceptsFirstResponder: Bool { isEnabled }
}
