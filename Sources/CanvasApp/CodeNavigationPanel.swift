import AppKit
import CanvasCore

/// The popover for code navigation: hover docs, reference/definition/outline lists, and short
/// messages. It lives in the canvas document rather than a separate window, so it pans and zooms
/// with its tile, never takes keyboard focus, and shows up in `view.snapshot`. One at a time.
@MainActor
final class NavigationPanel: NSView {
    enum Kind { case hover, list, message }

    private(set) static weak var current: NavigationPanel?

    let kind: Kind
    /// Hover panels close when the pointer leaves them (it may enter to read long docs).
    var onPointerExit: (() -> Void)?

    static let maxSize = NSSize(width: 560, height: 360)
    private static let inset: CGFloat = 8

    init(kind: Kind, content: NSView, contentSize: NSSize) {
        self.kind = kind
        let width = min(Self.maxSize.width, contentSize.width) + Self.inset * 2
        let height = min(Self.maxSize.height, contentSize.height) + Self.inset * 2
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let bodyFrame = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        if contentSize.height > Self.maxSize.height || contentSize.width > Self.maxSize.width {
            let scroll = OverlayScrollView(frame: bodyFrame)
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = contentSize.height > Self.maxSize.height
            scroll.hasHorizontalScroller = contentSize.width > Self.maxSize.width
            scroll.autohidesScrollers = true
            content.frame = NSRect(origin: .zero, size: NSSize(width: max(contentSize.width, bodyFrame.width), height: contentSize.height))
            scroll.documentView = content
            addSubview(scroll)
            if let document = scroll.documentView, !document.isFlipped {
                document.scroll(NSPoint(x: 0, y: document.bounds.maxY))
            }
        } else {
            content.frame = bodyFrame
            addSubview(content)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor.controlBackgroundColor.setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    override func mouseExited(with event: NSEvent) {
        onPointerExit?()
    }

    /// A click on the panel itself (a message, hover docs, a list's background) stays here:
    /// passed on, the canvas would take it for a click on empty canvas and deselect the code
    /// tile the panel is about. A message or hover docs close.
    override func mouseDown(with event: NSEvent) {
        if kind != .list { dismiss() }
    }

    /// Shows the panel below `anchor` (a point in `view`), above the line when there's no room,
    /// inside the nearest canvas document (or the window) and clamped to what's visible.
    func show(below anchor: NSPoint, lineHeight: CGFloat, in view: NSView) {
        Self.current?.dismiss()
        let container = sequence(first: view, next: \.superview).first { $0 is CanvasDocumentView } ?? view.window?.contentView ?? view
        let point = container.convert(anchor, from: view)
        let visible = container.visibleRect.insetBy(dx: 8, dy: 8)
        var origin = NSPoint(x: point.x, y: 0)
        let flipped = container.isFlipped
        // "Below" in screen terms: +y in a flipped container, -y otherwise.
        let belowY = flipped ? point.y + lineHeight : point.y - lineHeight - frame.height
        let aboveY = flipped ? point.y - frame.height - 4 : point.y + 4
        let fitsBelow = flipped ? belowY + frame.height <= visible.maxY : belowY >= visible.minY
        origin.y = fitsBelow ? belowY : aboveY
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
        setFrameOrigin(origin)
        container.addSubview(self)
        Self.current = self
    }

    func dismiss() {
        removeFromSuperview()
        if Self.current === self { Self.current = nil }
    }

    func contains(windowPoint: NSPoint, in window: NSWindow?) -> Bool {
        window === self.window && bounds.contains(convert(windowPoint, from: nil))
    }

    // MARK: Content

    static func hover(_ markdown: String) -> NavigationPanel {
        let text = HoverText.render(markdown)
        let width = min(maxSize.width, ceil(text.boundingRect(with: NSSize(width: maxSize.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).width) + 12)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(text)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let height = ceil(view.layoutManager?.usedRect(for: view.textContainer!).height ?? 20)
        return NavigationPanel(kind: .hover, content: view, contentSize: NSSize(width: width, height: height))
    }

    static func message(_ text: String) -> NavigationPanel {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 360
        let size = label.fittingSize
        return NavigationPanel(kind: .message, content: label, contentSize: size)
    }

    struct Row {
        var title: String
        var detail: String
        var indent: Int = 0
        var action: @MainActor () -> Void
    }

    /// A list with a filter field that takes the keyboard while the panel is up (the user asked
    /// for it: Outline, Find References, several definitions) and gives it back when the panel
    /// goes: typing narrows the rows to titles containing the text, ↑/↓ move the highlight,
    /// Return picks it, Esc closes. `headerAction` adds a button at the title's trailing end (the
    /// references list's Open All), which ⌘↩ also presses. `note` is one line under the title
    /// (why the list is a text search: the language server's unavailable hint), whole in its tooltip.
    static func filterList(title: String, rows: [Row], headerAction: (title: String, run: @MainActor () -> Void)? = nil, note: String? = nil) -> NavigationPanel {
        let content = FilterList(title: title, rows: rows, headerAction: headerAction, note: note)
        return NavigationPanel(kind: .list, content: content, contentSize: content.frame.size)
    }

    /// Puts the keyboard in the panel's filter field, if it has one.
    func focusFilter() {
        (subviews.first as? FilterList)?.focus()
    }
}

private final class FlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
}

/// One clickable list row. Accepts the first click so a row works even when the window isn't
/// key, and never takes keyboard focus (code tiles leave focus with the prompt terminal).
private final class PanelRow: NSButton {
    let row: NavigationPanel.Row

    init(row: NavigationPanel.Row) {
        self.row = row
        super.init(frame: .zero)
        isBordered = false
        refusesFirstResponder = true
        alignment = .left
        wantsLayer = true
        layer?.cornerRadius = 4
        let title = NSMutableAttributedString(string: String(repeating: "    ", count: row.indent) + row.title,
                                              attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
        if !row.detail.isEmpty {
            title.append(NSAttributedString(string: "  " + row.detail, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        attributedTitle = title
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        target = self
        action = #selector(chosen)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The row Return would pick in a filter list.
    var isCurrent = false {
        didSet { layer?.backgroundColor = isCurrent ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor : nil }
    }

    @objc func chosen() {
        row.action()
    }
}

/// A small link-styled button in a list's title row.
private final class PanelAction: NSButton {
    private let run: @MainActor () -> Void

    init(title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(frame: .zero)
        isBordered = false
        refusesFirstResponder = true
        attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.linkColor])
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func clicked() {
        run()
    }
}

/// The filter field and rows of `NavigationPanel.filterList`.
private final class FilterList: NSView, NSTextFieldDelegate {
    private static let rowHeight: CGFloat = 20
    private static let fieldHeight: CGFloat = 22
    private static let headerHeight: CGFloat = 20

    private let field = NSTextField()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let buttons: [PanelRow]
    private let headerAction: (@MainActor () -> Void)?
    private var shown: [PanelRow] = []
    private var current = 0
    private weak var previousResponder: NSResponder?

    init(title: String, rows: [NavigationPanel.Row], headerAction: (title: String, run: @MainActor () -> Void)?, note: String?) {
        buttons = rows.map(PanelRow.init)
        self.headerAction = headerAction?.run
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        let action = headerAction.map { PanelAction(title: $0.title, run: $0.run) }
        let headerWidth = header.fittingSize.width + (action.map { $0.fittingSize.width + 16 } ?? 0)
        // A note (why there is no language server, and how to install one) gets room to read in
        // about three lines.
        let width = min(max(buttons.map(\.fittingSize.width).max() ?? 0, headerWidth, note == nil ? 240 : 400), NavigationPanel.maxSize.width)
        let line = note.map(NSTextField.init(labelWithString:))
        line?.font = .systemFont(ofSize: 10.5)
        line?.textColor = .tertiaryLabelColor
        line?.wrapAsNote()
        let noteHeight = line.map { $0.height(atWidth: width - 8) + 2 } ?? 0
        let top = Self.headerHeight + noteHeight
        let listHeight = min(CGFloat(rows.count) * Self.rowHeight, NavigationPanel.maxSize.height - top - Self.fieldHeight - 6)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: top + Self.fieldHeight + 6 + listHeight))
        header.frame = NSRect(x: 4, y: 0, width: width - 8 - (action.map { $0.fittingSize.width + 8 } ?? 0), height: 16)
        addSubview(header)
        if let line {
            line.frame = NSRect(x: 4, y: Self.headerHeight - 2, width: width - 8, height: noteHeight - 2)
            addSubview(line)
        }
        if let action {
            let size = action.fittingSize
            action.frame = NSRect(x: width - size.width - 2, y: 0, width: size.width, height: 16)
            addSubview(action)
        }
        field.placeholderString = "Filter"
        field.font = .systemFont(ofSize: 12)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.frame = NSRect(x: 0, y: top, width: width, height: Self.fieldHeight)
        addSubview(field)
        scroll.frame = NSRect(x: 0, y: top + Self.fieldHeight + 6, width: width, height: listHeight)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        addSubview(scroll)
        refilter()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    func focus() {
        guard let window else { return }
        previousResponder = window.firstResponder
        window.makeFirstResponder(field)
    }

    /// The panel is going: the keyboard goes back to whoever had it (a terminal through its own
    /// focus path), unless something else took it.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, let editor = window.firstResponder as? NSText, editor.delegate === field {
            CanvasView.returnKeyboard(to: previousResponder, in: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func refilter() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        for button in shown { button.removeFromSuperview() }
        shown = buttons.filter { query.isEmpty || $0.row.title.localizedCaseInsensitiveContains(query) }
        let width = scroll.contentSize.width
        for (index, button) in shown.enumerated() {
            button.frame = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: width, height: Self.rowHeight)
            document.addSubview(button)
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, CGFloat(shown.count) * Self.rowHeight))
        select(0)
    }

    private func select(_ index: Int) {
        for button in shown { button.isCurrent = false }
        guard !shown.isEmpty else { return }
        current = min(max(0, index), shown.count - 1)
        shown[current].isCurrent = true
        document.scrollToVisible(shown[current].frame)
    }

    func controlTextDidChange(_ notification: Notification) {
        refilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): select(current - 1)
        case #selector(NSResponder.moveDown(_:)): select(current + 1)
        case #selector(NSResponder.insertNewline(_:)): if shown.indices.contains(current) { shown[current].chosen() }
        case #selector(NSResponder.cancelOperation(_:)): (superview as? NavigationPanel)?.dismiss()
        default: return false
        }
        return true
    }

    /// ⌘↩ presses the header action (the references list's Open All) while the filter types.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let headerAction, event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              let editor = window?.firstResponder as? NSText, editor.delegate === field else { return super.performKeyEquivalent(with: event) }
        headerAction()
        return true
    }
}

/// Hover markdown → attributed text: code in monospace on a tinted background, headings bold,
/// rules as spacing, and the inline emphasis, code and links `HoverMarkdown` resolved.
@MainActor
enum HoverText {
    static let body = NSFont.systemFont(ofSize: 12)
    static let code = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    static func render(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in HoverMarkdown.blocks(markdown) {
            if result.length > 0 { result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 5)])) }
            switch block {
            case .code(_, let text):
                result.append(NSAttributedString(string: text + "\n", attributes: [.font: code, .foregroundColor: NSColor.labelColor,
                                                                                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)]))
            case .heading(let spans):
                result.append(inline(spans, font: NSFont.boldSystemFont(ofSize: 12)))
                result.append(NSAttributedString(string: "\n", attributes: [.font: body]))
            case .prose(let spans):
                result.append(inline(spans, font: body))
                result.append(NSAttributedString(string: "\n", attributes: [.font: body]))
            case .rule:
                result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
            }
        }
        // Drop the final newline so the popover has no empty last line.
        if result.string.hasSuffix("\n") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }

    private static func inline(_ spans: [HoverMarkdown.Span], font base: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for span in spans {
            var font = span.code ? code : base
            if span.strong { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if span.emphasis { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: span.link ? NSColor.linkColor : NSColor.labelColor]
            if span.code { attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12) }
            result.append(NSAttributedString(string: span.text, attributes: attributes))
        }
        return result
    }
}

extension NSTextField {
    /// Wraps onto as many lines as it needs: a panel's note (an install hint names the command
    /// and the variable to set), which one truncated line cut off, and whose tooltip an inactive
    /// app doesn't show.
    func wrapAsNote() {
        usesSingleLineMode = false
        cell?.wraps = true
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
    }

    /// Its height laid out `width` wide.
    func height(atWidth width: CGFloat) -> CGFloat {
        preferredMaxLayoutWidth = width
        return ceil(fittingSize.height)
    }
}
