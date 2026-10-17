import AppKit
import CanvasCore

/// The list a browser tile's error badge opens, over the top right of its page: the page's
/// errors newest first (uncaught errors, console errors, failed requests), each with where
/// and when, then those of the page easl released before this one loaded (`PageReport`).
/// A click on a row shows its whole message and its stack; a `file:line` that maps to a file
/// under the board root (`PageSource`) opens it as a code tile at that line. A Hyper-click on
/// a row mentions that entry (`BrowserTile.problemMention`).
@MainActor
final class PageProblemsView: NSView {
    static let preferredWidth: CGFloat = 440
    /// Rows the list shows per load; the API has the rest.
    static let maxRows = 50
    private static let headerHeight: CGFloat = 30
    private static let footerHeight: CGFloat = 24
    private static let inset: CGFloat = 10

    var onClose: (() -> Void)?
    /// The list's height changed (a row opened or closed).
    var onResize: (() -> Void)?
    /// The repo file and line a `source` or stack frame names; nil when none.
    var resolve: ((String) -> (file: String, line: Int)?)?
    var onOpenSource: ((_ file: String, _ line: Int) -> Void)?
    private let title = NSTextField(labelWithString: "")
    private let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") ?? NSImage(), target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "Click an entry for its stack · Hyper-click to mention it to your agent")
    private let scroll = OverlayScrollView()
    private let rowsView = FlippedView()
    /// Rows and section labels, top to bottom.
    private var items: [NSView] = []
    private var rows: [Row] { items.compactMap { $0 as? Row } }
    /// Entries shown whole, kept across refreshes.
    private var expanded: Set<PageLogEntry> = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        self.shadow = shadow
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        close.isBordered = false
        close.toolTip = "Close"
        close.target = self
        close.action = #selector(closeClicked)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = rowsView
        [title, close, scroll, hint].forEach(addSubview)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Page errors")
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    /// The page's errors, newest first, then the released page's (`previous`) under a label
    /// saying when it went and whether the page loaded again since (`reloaded`).
    func show(_ entries: [PageLogEntry], previous: PageReport.Released?, reloaded: Bool) {
        items.forEach { $0.removeFromSuperview() }
        items = entries.prefix(Self.maxRows).map(row)
        if let previous {
            let time = DateFormatter.localizedString(from: previous.at, dateStyle: .none, timeStyle: .medium)
            let problems = previous.log.problems
            let none = problems.isEmpty ? ": no errors" : ""
            let label = reloaded
                ? "Before easl released the page at \(time) (out of view) and loaded it again\(none)"
                : "Before easl released the page at \(time) (out of view)\(none)"
            items.append(SectionLabel(label))
            items += problems.prefix(Self.maxRows).map(row)
        }
        items.forEach(rowsView.addSubview)
        let count = entries.count
        title.stringValue = switch (count, previous) {
        case (0, _?): reloaded ? "No errors since the page reloaded" : "Page released"
        case (1, _): "1 error on this page"
        default: "\(count) errors on this page"
        }
        needsLayout = true
        layoutRows()
    }

    private func row(_ entry: PageLogEntry) -> Row {
        let row = Row(entry, expanded: expanded.contains(entry), resolve: resolve)
        row.onToggle = { [weak self, weak row] in
            guard let self, let row else { return }
            if row.isExpanded { self.expanded.insert(row.entry) } else { self.expanded.remove(row.entry) }
            self.layoutRows()
            self.onResize?()
        }
        row.onOpenSource = { [weak self] file, line in self?.onOpenSource?(file, line) }
        return row
    }

    /// Header, every row at `width`, and the footer.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let rowWidth = width - 2
        return Self.headerHeight + items.reduce(0) { $0 + Self.height(of: $1, width: rowWidth) } + Self.footerHeight
    }

    private static func height(of item: NSView, width: CGFloat) -> CGFloat {
        (item as? Row)?.height(width: width) ?? (item as? SectionLabel)?.height(width: width) ?? 0
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutRows()
    }

    private func layoutRows() {
        let inset = Self.inset
        title.frame = NSRect(x: inset, y: 8, width: max(0, bounds.width - inset * 2 - 22), height: 16)
        close.frame = NSRect(x: bounds.width - inset - 16, y: 7, width: 16, height: 16)
        scroll.frame = NSRect(x: 1, y: Self.headerHeight, width: max(0, bounds.width - 2),
                              height: max(0, bounds.height - Self.headerHeight - Self.footerHeight))
        hint.frame = NSRect(x: inset, y: bounds.height - Self.footerHeight + 5, width: max(0, bounds.width - inset * 2), height: 14)
        let width = scroll.contentSize.width
        var y: CGFloat = 0
        for item in items {
            let height = Self.height(of: item, width: width)
            item.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        rowsView.frame = NSRect(x: 0, y: 0, width: width, height: y)
    }

    /// The entry of the row under `point` (this view's coordinates), where the list shows it.
    func entry(at point: NSPoint) -> PageLogEntry? {
        guard scroll.frame.contains(point) else { return nil }
        let local = rowsView.convert(point, from: self)
        return rows.first { $0.frame.contains(local) }?.entry
    }

    /// The visible part of `entry`'s row, in this view's coordinates.
    func rowRect(of entry: PageLogEntry) -> NSRect? {
        guard let row = rows.first(where: { $0.entry == entry }) else { return nil }
        let rect = convert(row.frame, from: rowsView).intersection(scroll.frame)
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    @objc private func closeClicked() { onClose?() }

    /// "Before easl released the page at 14:16:38 …" over the released page's rows.
    private final class SectionLabel: NSView {
        private let label: NSTextField

        init(_ text: String) {
            label = NSTextField(wrappingLabelWithString: text)
            super.init(frame: .zero)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        nonisolated override var isFlipped: Bool { true }

        func height(width: CGFloat) -> CGFloat {
            10 + ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 20, height: .greatestFiniteMagnitude)).height ?? 14) + 4
        }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            label.frame = NSRect(x: 10, y: 10, width: bounds.width - 20, height: bounds.height - 14)
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.08).setFill()
            bounds.fill()
        }
    }

    /// One entry: what it said (up to three lines, all of it when open), then what kind, where
    /// (a link when it maps to a repo file) and when, then, open, its stack.
    private final class Row: NSView {
        let entry: PageLogEntry
        private(set) var isExpanded: Bool
        var onToggle: (() -> Void)?
        var onOpenSource: ((String, Int) -> Void)?
        private let message = NSTextField(wrappingLabelWithString: "")
        private let kind = NSTextField(labelWithString: "")
        private let source: LinkText?
        private let when = NSTextField(labelWithString: "")
        private let disclosure = NSImageView()
        private let frames: [LinkText]
        private static let messageFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        private static let frameFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        private static let maxMessageLines = 3
        private static let detailHeight: CGFloat = 14
        private static let frameHeight: CGFloat = 14
        /// Stack frames an open row lists; the mention carries them too.
        private static let maxFrames = 30

        init(_ entry: PageLogEntry, expanded: Bool, resolve: ((String) -> (file: String, line: Int)?)?) {
            self.entry = entry
            isExpanded = expanded
            source = entry.shortSource.map { short in LinkText(short, font: .systemFont(ofSize: 11), target: entry.source.flatMap { resolve?($0) }) }
            frames = entry.frames.prefix(Self.maxFrames).map { LinkText($0, font: Self.frameFont, target: resolve?($0)) }
            super.init(frame: .zero)
            message.stringValue = entry.text
            message.font = Self.messageFont
            message.textColor = .labelColor
            message.lineBreakMode = .byWordWrapping
            message.cell?.truncatesLastVisibleLine = true
            for label in [kind, when] {
                label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
            }
            kind.stringValue = entry.noun + (entry.shortSource == nil ? "" : " ·")
            when.stringValue = entry.clockTime.map { (entry.shortSource == nil ? " · " : "· ") + $0 } ?? ""
            disclosure.imageScaling = .scaleProportionallyDown
            disclosure.contentTintColor = .tertiaryLabelColor
            [message, kind, when, disclosure].forEach(addSubview)
            if let source {
                source.toolTip = entry.source.map { source.link == nil ? $0 : "\($0)\nClick to open it" }
                source.onClick = { [weak self] target in self?.onOpenSource?(target.file, target.line) }
                addSubview(source)
            }
            for frame in frames {
                frame.lineBreakMode = .byTruncatingMiddle
                frame.onClick = { [weak self] target in self?.onOpenSource?(target.file, target.line) }
                addSubview(frame)
            }
            toolTip = "\(entry.text)\n\nClick for the whole message and stack · Hyper-click to mention it to your agent"
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("\(entry.noun): \(entry.text)")
            apply()
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        nonisolated override var isFlipped: Bool { true }

        /// Whether opening shows anything more: a stack, or a message cut short.
        private var opens: Bool {
            let width = max(1, bounds.width - 20)
            return !frames.isEmpty || Self.textHeight(entry.text, width: width) > Self.clippedHeight(width: width)
        }

        /// Measures wrapped message text as the message field lays it out (its insets and line
        /// height), all of it: the field's own line limit doesn't apply here.
        private static let measure: NSTextFieldCell = {
            let cell = NSTextFieldCell(textCell: "")
            cell.font = messageFont
            cell.wraps = true
            cell.lineBreakMode = .byWordWrapping
            return cell
        }()

        private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
            measure.stringValue = text
            return ceil(measure.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height)
        }

        private static func clippedHeight(width: CGFloat) -> CGFloat {
            textHeight(Array(repeating: "X", count: maxMessageLines).joined(separator: "\n"), width: width)
        }

        private func messageHeight(width: CGFloat) -> CGFloat {
            let full = Self.textHeight(entry.text, width: width)
            return isExpanded ? full : min(full, Self.clippedHeight(width: width))
        }

        private var stackHeight: CGFloat {
            isExpanded && !frames.isEmpty ? 4 + CGFloat(frames.count) * Self.frameHeight : 0
        }

        func height(width: CGFloat) -> CGFloat {
            8 + messageHeight(width: width - 20) + 2 + Self.detailHeight + stackHeight + 8
        }

        private func apply() {
            message.maximumNumberOfLines = isExpanded ? 0 : Self.maxMessageLines
            frames.forEach { $0.isHidden = !isExpanded }
            disclosure.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
            setAccessibilityHelp(isExpanded ? "Shows less" : "Shows the whole message and its stack")
            needsLayout = true
        }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            let width = bounds.width - 20
            let height = messageHeight(width: width)
            message.frame = NSRect(x: 10, y: 8, width: width, height: height)
            let y = 8 + height + 2
            disclosure.isHidden = !opens
            disclosure.frame = NSRect(x: bounds.width - 22, y: y + 1, width: 12, height: 12)
            var x: CGFloat = 10
            let right = bounds.width - 26
            for label in [kind, source, when].compactMap({ $0 }) {
                let fitted = min(ceil(label.attributedStringValue.size().width) + 4, max(0, right - x))
                label.frame = NSRect(x: x, y: y, width: fitted, height: Self.detailHeight)
                x += fitted + 3
            }
            var frameY = y + Self.detailHeight + 4
            for frame in frames {
                frame.frame = NSRect(x: 18, y: frameY, width: max(0, bounds.width - 28), height: Self.frameHeight)
                frameY += Self.frameHeight
            }
        }

        /// The row takes clicks (open, close) except on its links.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let hit = super.hitTest(point) else { return nil }
            if let link = hit as? LinkText, link.link != nil { return link }
            return self
        }

        /// A click opens the row even while the window isn't key, as the page's own clicks act.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) {
            guard opens, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            toggle()
        }

        override func accessibilityPerformPress() -> Bool {
            guard opens else { return false }
            toggle()
            return true
        }

        private func toggle() {
            isExpanded.toggle()
            apply()
            onToggle?()
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemRed.withAlphaComponent(0.8).setFill()
            NSRect(x: 0, y: 8, width: 3, height: bounds.height - 16).fill()
            NSColor.separatorColor.setFill()
            NSRect(x: 10, y: bounds.height - 1, width: bounds.width - 10, height: 1).fill()
        }
    }

    /// A `file:line` or stack frame: link-coloured, with a pointing hand, when it names a repo
    /// file (`link`), which a click opens; plain secondary text otherwise.
    private final class LinkText: NSTextField {
        let link: (file: String, line: Int)?
        var onClick: (((file: String, line: Int)) -> Void)?

        init(_ text: String, font: NSFont, target: (file: String, line: Int)?) {
            self.link = target
            super.init(frame: .zero)
            stringValue = text
            self.font = font
            isEditable = false
            isSelectable = false
            isBordered = false
            drawsBackground = false
            lineBreakMode = .byTruncatingMiddle
            textColor = link == nil ? .secondaryLabelColor : .linkColor
            if link != nil {
                setAccessibilityRole(.link)
                setAccessibilityLabel("\(text), opens \((link!.file as NSString).lastPathComponent) at line \(link!.line)")
            }
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { link != nil }

        override func resetCursorRects() {
            if link != nil { addCursorRect(bounds, cursor: .pointingHand) }
        }

        override func mouseDown(with event: NSEvent) {
            guard link == nil else { return }
            super.mouseDown(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            guard let link, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            onClick?(link)
        }

        override func accessibilityPerformPress() -> Bool {
            guard let link else { return false }
            onClick?(link)
            return true
        }
    }
}

private final class FlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
}
