import AppKit
import CanvasCore

/// Window-space bar showing staged mentions as chips and the terminal they will drain into.
/// Each chip carries the `[n]` its mention gets in the sent context (`TrayChips`); a click on a
/// chip shows what it points at (`onReveal`). The bar lays itself out by hand (`TrayLayout`): it
/// asks the window for its natural width only weakly, so it never widens the window, and the
/// `→ target` label keeps its width while chips shrink and then scroll.
@MainActor
final class TrayBar: NSVisualEffectView {
    private let strip = TrayStrip()
    private let chips = FlippedView()
    /// "→ name": a click opens `targetMenu` (the board's terminals) under it.
    private let target = NSButton(title: "", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "Hyper-click (⌃⌥⇧⌘-click) anything, or ⇧⌘M, to point your agent at it")
    private var chipViews: [TrayChip] = []
    /// A chip was added: once laid out, the strip scrolls to show the newest.
    private var scrollToEnd = false
    var onUnstage: ((MentionID) -> Void)?
    /// A chip's label was clicked: show what its mention points at.
    var onReveal: ((Mention) -> Void)?
    /// The menu the target opens: the terminals to retarget to; nil for none.
    var targetMenu: (() -> NSMenu?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        hint.textColor = .secondaryLabelColor
        hint.font = ChromeText.font(.systemFont(ofSize: 12))
        hint.lineBreakMode = .byTruncatingTail
        target.isBordered = false
        target.setButtonType(.momentaryChange)
        target.alignment = .right
        target.lineBreakMode = .byTruncatingMiddle
        target.toolTip = CanvasBasics.trayTarget
        target.target = self
        target.action = #selector(targetClicked(_:))
        strip.drawsBackground = false
        strip.hasHorizontalScroller = true
        strip.hasVerticalScroller = false
        strip.autohidesScrollers = true
        strip.scrollerStyle = .overlay
        strip.horizontalScrollElasticity = .allowed
        strip.verticalScrollElasticity = .none
        strip.documentView = chips
        addSubview(strip)
        addSubview(target)
        // Below the window's size (NSLayoutPriorityWindowSizeStayPut is 500): the tray is cut
        // down to the window instead of pushing it wider; above everything else that would
        // squeeze it.
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(490), for: .horizontal)
        setContentHuggingPriority(NSLayoutConstraint.Priority(490), for: .horizontal)
        show([], targetTitle: nil, targetDrains: false, hasTerminal: false, board: nil)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// `targetTitle` is the prompt target's; without one, the hint says how to get one.
    /// `targetDrains`: the target runs an agent integration that takes the tray with its next
    /// prompt; any other target needs Hyper-V to paste the mentions.
    func show(_ mentions: [Mention], targetTitle: String?, targetDrains: Bool, hasTerminal: Bool, board: Board?) {
        let added = mentions.contains { mention in !chipViews.contains { $0.mention.id == mention.id } }
        for view in chips.subviews { view.removeFromSuperview() }
        chipViews = TrayChips.numbered(mentions).map { number, mention in
            let chip = TrayChip(mention: mention, number: number, changed: board.flatMap { TrayChips.changedNote(mention, on: $0) })
            chip.onRemove = { [weak self] id in self?.onUnstage?(id) }
            chip.onReveal = { [weak self] mention in self?.onReveal?(mention) }
            return chip
        }
        hint.font = ChromeText.font(.systemFont(ofSize: 12))
        if chipViews.isEmpty { chips.addSubview(hint) }
        chipViews.forEach(chips.addSubview)
        scrollToEnd = added
        let title = targetTitle.map { mentions.isEmpty || targetDrains ? "→ \($0) ▾" : "→ \($0) ▾ · ⌃⌥⇧⌘V pastes" } ?? (hasTerminal ? "→ choose a terminal ▾" : "→ no terminal yet (⌘T)")
        target.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: ChromeText.font(.systemFont(ofSize: 12, weight: .medium)),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        target.isEnabled = hasTerminal
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// What the tray would take with room to spare; the window's constraints cut it down.
    override var intrinsicContentSize: NSSize {
        NSSize(width: fitted(available: .greatestFiniteMagnitude).width, height: NSView.noIntrinsicMetric)
    }

    private func fitted(available: CGFloat) -> TrayLayout {
        let widths = chipViews.isEmpty ? [TrayLayout.Chip(natural: hint.drawnWidth)] : chipViews.map(\.widths)
        return TrayLayout.fit(chips: widths, target: ceil(target.intrinsicContentSize.width), available: available)
    }

    override func layout() {
        super.layout()
        let fit = fitted(available: bounds.width)
        let height = bounds.height
        let labelHeight = target.intrinsicContentSize.height
        target.frame = NSRect(x: bounds.maxX - TrayLayout.trailing - fit.target, y: ((height - labelHeight) / 2).rounded(), width: fit.target, height: labelHeight)
        strip.frame = NSRect(x: TrayLayout.leading, y: 0, width: fit.strip, height: height)
        chips.frame = NSRect(x: 0, y: 0, width: max(fit.content, fit.strip), height: height)
        if chipViews.isEmpty {
            let size = hint.intrinsicContentSize
            hint.frame = NSRect(x: 0, y: ((height - size.height) / 2).rounded(), width: min(hint.drawnWidth, fit.strip), height: size.height)
        }
        var x: CGFloat = 0
        for (chip, width) in zip(chipViews, fit.chips) {
            chip.frame = NSRect(x: x, y: ((height - TrayChip.height) / 2).rounded(), width: width, height: TrayChip.height)
            x += width + TrayLayout.spacing
        }
        if scrollToEnd {
            scrollToEnd = false
            chips.scroll(NSPoint(x: max(0, chips.frame.width - fit.strip), y: 0))
        }
    }

    @objc private func targetClicked(_ sender: NSButton) {
        guard let menu = targetMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }
}

/// The chips' strip: a vertical wheel scrolls it sideways too, for mice without a horizontal one.
private final class TrayStrip: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaX == 0, event.scrollingDeltaY != 0, let document = documentView, document.frame.width > contentView.bounds.width else {
            return super.scrollWheel(with: event)
        }
        let x = min(max(0, contentView.bounds.minX - event.scrollingDeltaY), document.frame.width - contentView.bounds.width)
        contentView.scroll(to: NSPoint(x: x, y: contentView.bounds.minY))
        reflectScrolledClipView(contentView)
    }
}

private extension NSTextField {
    /// The width the label draws its whole text in: its cell's size, which counts the cell's
    /// padding (`intrinsicContentSize` comes out a few points short, and the text truncates).
    var drawnWidth: CGFloat {
        ceil(cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 100)).width ?? intrinsicContentSize.width)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One staged mention: its number, its label (truncated first when the tray is short of room),
/// a word when its target changed, and ✕. A click anywhere but ✕ reveals it.
@MainActor
private final class TrayChip: NSView {
    static var height: CGFloat { ChromeText.scaled(22) }
    private static let insets = (left: CGFloat(8), right: CGFloat(4))
    private static let gap: CGFloat = 4
    /// Past this a label truncates even with room to spare.
    private static let labelLimit: CGFloat = 260

    let mention: Mention
    private let number: NSTextField
    private let label: NSTextField
    private let changed: NSTextField?
    private let remove = NSButton(title: "✕", target: nil, action: nil)
    /// The whole label's width, measured before `layout` cuts it to fit.
    private var labelWidth: CGFloat = 0
    var onRemove: ((MentionID) -> Void)?
    var onReveal: ((Mention) -> Void)?

    init(mention: Mention, number index: Int, changed note: String?) {
        self.mention = mention
        number = NSTextField(labelWithString: TrayChips.badge(index))
        label = NSTextField(labelWithString: mention.label)
        changed = note.map { NSTextField(labelWithString: "· \($0)") }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.22).cgColor
        number.font = ChromeText.font(.monospacedDigitSystemFont(ofSize: 12, weight: .semibold))
        number.textColor = .secondaryLabelColor
        label.font = ChromeText.font(.systemFont(ofSize: 12))
        // DOM labels lead with what a person recognizes and end with the CSS path; code
        // locations keep both the file name's start and its line.
        // What doesn't fit is cut by `TrayChips.fittedLabel` (code locations) or at the tail:
        // DOM labels lead with what a person recognizes, notes with their title.
        label.lineBreakMode = .byTruncatingTail
        labelWidth = label.drawnWidth
        changed?.font = ChromeText.font(.systemFont(ofSize: 12))
        remove.font = .systemFont(ofSize: ChromeText.size(NSFont.systemFontSize))
        changed?.textColor = .secondaryLabelColor
        remove.isBordered = false
        remove.target = self
        remove.action = #selector(removeClicked(_:))
        remove.setAccessibilityLabel("Remove \(TrayChips.badge(index)) \(mention.label)")
        for view in [number, label] + (changed.map { [$0] } ?? []) + [remove] { addSubview(view) }
        toolTip = Self.tooltip(for: mention)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(TrayChips.badge(index)) \(mention.label)\(note.map { ", \($0)" } ?? "")")
        setAccessibilityHelp("Shows what it points at")
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// With its whole label, and shrunk: the number, the changed note and ✕ always show
    /// (outside the label, so truncation never hides them).
    var widths: TrayLayout.Chip {
        let note = changed.map { Self.gap + $0.drawnWidth } ?? 0
        let natural = Self.insets.left + number.drawnWidth + Self.gap + min(labelWidth, Self.labelLimit)
            + note + Self.gap + ceil(remove.intrinsicContentSize.width) + Self.insets.right
        return TrayLayout.Chip(natural: natural, minimum: TrayLayout.minimumChip + note)
    }

    override func layout() {
        super.layout()
        func place(_ view: NSView, x: CGFloat, width: CGFloat) {
            let height = view.intrinsicContentSize.height
            view.frame = NSRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: max(0, width), height: height)
        }
        let removeWidth = remove.intrinsicContentSize.width
        place(remove, x: bounds.maxX - Self.insets.right - removeWidth, width: removeWidth)
        var right = remove.frame.minX - Self.gap
        if let changed {
            let width = changed.drawnWidth
            place(changed, x: right - width, width: width)
            right = changed.frame.minX - Self.gap
        }
        let numberWidth = number.drawnWidth
        place(number, x: Self.insets.left, width: numberWidth)
        place(label, x: number.frame.maxX + Self.gap, width: right - number.frame.maxX - Self.gap)
        let font = label.font ?? ChromeText.font(.systemFont(ofSize: 12))
        let padding = label.drawnWidth - ceil(NSAttributedString(string: label.stringValue, attributes: [.font: font]).size().width)
        label.stringValue = TrayChips.fittedLabel(mention, width: label.frame.width) { text in
            ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width) + padding
        }
    }

    /// A file outside the board root has a short label (`PathLabel`); the tooltip has its path.
    private static func tooltip(for mention: Mention) -> String {
        var lines: [String] = []
        switch mention.target {
        case .code(_, let path, _, _, _, _, _) where PathLabel.short(path) != path: lines.append(path)
        case .note(_, let item): lines.append((item.headings + [item.summary]).joined(separator: " › "))
        case .console(_, _, let entry): lines.append(contentsOf: [entry.text, entry.source].compactMap { $0 })
        default: lines.append(mention.label)
        }
        lines.append("Click to show it")
        return lines.joined(separator: "\n")
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onReveal?(mention) }
    }

    override func accessibilityPerformPress() -> Bool {
        onReveal?(mention)
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func removeClicked(_ sender: NSButton) {
        onRemove?(mention.id)
    }
}
