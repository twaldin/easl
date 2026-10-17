import AppKit
import CanvasCore

/// Help › easl Basics: a floating panel inside the board window (an overlay like Go to, never
/// modal) with the short legend in `CanvasBasics`: lifecycle dots, markers, the follow tile, the
/// tray and Hyper-click, zoom and cards, the keyboard. It stays open while the canvas is used
/// beside it, so the user can try what it says; ×, Esc while it has the keyboard, or the menu
/// item again close it, and the keyboard goes back to whoever had it.
@MainActor
final class BasicsPanel: NSVisualEffectView {
    static let width: CGFloat = 440

    private let text = BasicsTextView()
    private let scroll = OverlayScrollView()
    private weak var previousResponder: NSResponder?
    var isOpen: Bool { !isHidden }
    /// The panel's Hide Board Chrome button (the View menu's item, for presenting).
    var onHideChrome: (() -> Void)?

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
        setAccessibilityRole(.group)
        setAccessibilityLabel("easl Basics")

        let title = NSTextField(labelWithString: "easl Basics")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close easl Basics") ?? NSImage(), target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "Close (Esc)"
        let hide = NSButton(title: "Hide Board Chrome", target: self, action: #selector(hideChromeClicked))
        hide.controlSize = .small
        hide.bezelStyle = .push
        hide.font = .systemFont(ofSize: 11)
        hide.toolTip = "For presenting: hides the toolbar, tray, selection rings, author marks, code headers and agents' markers. Esc brings them back (View › Hide Board Chrome)."
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 14, height: 4)
        text.frame = NSRect(x: 0, y: 0, width: Self.width, height: 400)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textStorage?.setAttributedString(Self.legend())
        text.onEscape = { [weak self] in self?.close() }
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        for view in [title, hide, close, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            hide.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            hide.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Opens with the keyboard (so Esc closes it) and the legend scrolled to the top.
    func open() {
        guard let window else { return }
        isHidden = false
        previousResponder = window.firstResponder
        window.makeFirstResponder(text)
        text.scrollToBeginningOfDocument(nil)
    }

    /// Hides the panel; the keyboard goes back to whoever had it before, if the legend still
    /// had it (`CanvasView.returnKeyboard`).
    func close() {
        guard isOpen else { return }
        let hadKeyboard = window?.firstResponder === text
        isHidden = true
        if hadKeyboard, let window { CanvasView.returnKeyboard(to: previousResponder, in: window) }
        previousResponder = nil
    }

    @objc private func closeClicked() { close() }
    @objc private func hideChromeClicked() { onHideChrome?() }

    private static func legend() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSMutableParagraphStyle()
        body.paragraphSpacing = 5
        body.headIndent = 0
        let heading = NSMutableParagraphStyle()
        heading.paragraphSpacingBefore = 8
        heading.paragraphSpacing = 3
        for (index, section) in CanvasBasics.sections.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            // Headings in the label color, set apart by size, caps and spacing: the secondary
            // label color read 4.0:1 on the translucent panel.
            result.append(NSAttributedString(string: section.title.uppercased() + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.labelColor, .paragraphStyle: heading, .kern: 0.6,
            ]))
            for (itemIndex, item) in section.items.enumerated() {
                result.append(NSAttributedString(string: item.term, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: body]))
                let end = itemIndex == section.items.count - 1 ? "" : "\n"
                result.append(NSAttributedString(string: " — \(item.text)\(end)", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: body]))
            }
        }
        return result
    }
}

/// The legend's text: selectable, read-only, and Esc closes the panel.
@MainActor
private final class BasicsTextView: NSTextView {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return onEscape?() ?? () }
        super.keyDown(with: event)
    }
}
