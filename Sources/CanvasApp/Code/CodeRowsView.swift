import AppKit
import CanvasCore

/// Draws the visible rows of a code document (CTLine per visible row, cached only while
/// visible) and scrolls itself vertically (rows soft-wrap, so there is nothing to scroll
/// sideways): its bounds origin is the scroll offset, so its own coordinates are document
/// coordinates. No scroll or clip view: those re-lay out and rebuild tracking
/// areas on every frame of a canvas pan, even behind a zoomed-out card. Also handles character
/// selection, ⌘C, gutter clicks, and "Edit Here".
@MainActor
final class CodeRowsView: NSView {
    var painter: CodePainter? {
        didSet {
            needsDisplay = true
            scroll(toY: bounds.minY)
        }
    }

    /// A gutter sign was clicked (peek or unpeek).
    var onSign: ((Int) -> Void)?
    /// The user scrolled, clicked, or selected here.
    var onInteract: (() -> Void)?
    /// The offset changed (by the user or programmatically).
    var onScroll: (() -> Void)?
    var onEditHere: ((NSPoint) -> Void)?
    /// Esc with the keyboard in the rows: back to the canvas.
    var onEscape: (() -> Void)?
    /// Whether "Edit Here" is offered: the rows are the working-tree file (not a deleted file's
    /// base, not a pinned commit).
    var canEdit = true

    private var inspectingClosedBoard: Bool {
        (window?.windowController as? CanvasWindowController)?.hostBoardClosed == true
    }

    let cache = CodeLineCache()
    private var anchor: CodeRows.Position?

    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    private var contentHeight: CGFloat { painter?.contentHeight ?? 0 }

    /// Scroll so `y` (document coordinates) is the top, clamped to the content.
    func scroll(toY y: CGFloat) {
        let clamped = CGPoint(x: 0, y: min(max(0, y), max(0, contentHeight - bounds.height)).rounded())
        guard clamped != bounds.origin else { return }
        setBoundsOrigin(clamped)
        needsDisplay = true
        onScroll?()
    }

    /// The row at the top of the view, past its padding.
    var topRow: Int { CodePainter.row(atY: bounds.minY + CodeMetrics.verticalPadding) }

    /// The range tint depends on which rows the whole viewport shows, so a resize redraws all of
    /// it, not just the newly exposed strip.
    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { needsDisplay = true }
        scroll(toY: bounds.minY)
    }

    override func draw(_ dirtyRect: NSRect) {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("draw.CodeRowsView", since: perfStart) }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let painter else {
            NSColor.textBackgroundColor.setFill()
            dirtyRect.fill()
            return
        }
        painter.draw(in: context, rect: bounds, cache: cache)
        drawScrollIndicator(contentHeight: painter.contentHeight)
    }

    /// A thin thumb along the right edge when the file is taller than the view.
    private func drawScrollIndicator(contentHeight: CGFloat) {
        guard contentHeight > bounds.height + 0.5 else { return }
        let length = max(24, bounds.height * bounds.height / contentHeight)
        let y = bounds.minY + (bounds.height - length) * bounds.minY / (contentHeight - bounds.height)
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.maxX - 5, y: y + 2, width: 3, height: length - 4), xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Laid-out lines carry resolved colors.
        cache.removeAll()
        needsDisplay = true
    }

    /// Not live: nothing laid out or rasterized is kept.
    func releaseCaches() {
        cache.removeAll()
        layer?.contents = nil
    }

    // MARK: Hit testing

    func isInGutter(_ point: NSPoint) -> Bool {
        guard let painter else { return false }
        return point.x < painter.gutterWidth
    }

    /// Text position nearest a point: its visual row (clamped to the rows) and the line offset
    /// under `x` within that row's slice of the line.
    func position(at point: NSPoint) -> CodeRows.Position? {
        guard let painter, painter.rows.count > 0,
              let segment = painter.rows.segment(min(max(0, CodePainter.row(atY: point.y)), painter.rows.count - 1)) else { return nil }
        let line = painter.line(segment, cache: cache)
        return CodeRows.Position(entry: segment.entry, offset: painter.offset(in: segment, x: point.x, line: line))
    }

    // MARK: Mouse

    /// Scrolls vertically when the rows overflow; anything else (sideways, a file that fits)
    /// goes on to the canvas, which pans.
    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= CodeMetrics.rowHeight
            dy *= CodeMetrics.rowHeight
        }
        guard abs(dy) >= abs(dx), dy != 0, contentHeight > bounds.height + 0.5 else { return super.scrollWheel(with: event) }
        onInteract?()
        scroll(toY: bounds.minY - dy)
    }

    override func mouseDown(with event: NSEvent) {
        onInteract?()
        let point = convert(event.locationInWindow, from: nil)
        if !inspectingClosedBoard, isInGutter(point), let sign = painter?.sign(atY: point.y) {
            onSign?(sign)
            return
        }
        window?.makeFirstResponder(self)
        guard let position = position(at: point) else { return }
        if event.modifierFlags.contains(.shift), let selection = painter?.selection {
            anchor = position < selection.start ? selection.end : selection.start
        } else {
            anchor = position
        }
        select(to: position)
    }

    override func mouseDragged(with event: NSEvent) {
        guard anchor != nil else { return }
        // Dragging past an edge scrolls toward it.
        let point = convert(event.locationInWindow, from: nil)
        let dy = point.y < bounds.minY ? point.y - bounds.minY : point.y > bounds.maxY ? point.y - bounds.maxY : 0
        if dy != 0 { scroll(toY: bounds.minY + dy) }
        guard let position = position(at: point) else { return }
        select(to: position)
    }

    override func mouseUp(with event: NSEvent) {
        anchor = nil
    }

    // MARK: Keyboard

    /// With the keyboard in the rows (Return on the selected tile, or a click): ↑/↓ (j/k) a row,
    /// PageUp/PageDown (⇧Space/Space) a page, Home/End the ends; Esc hands the keyboard back.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard modifiers.isEmpty || (modifiers == .shift && event.keyCode == 49) else { return super.keyDown(with: event) }
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        let row = CodeMetrics.rowHeight
        let page = max(row, bounds.height - 2 * row)
        let delta: CGFloat
        switch event.keyCode {
        case 125: delta = row
        case 126: delta = -row
        case 121: delta = page
        case 116: delta = -page
        case 49: delta = modifiers == .shift ? -page : page
        case 115: delta = -contentHeight
        case 119: delta = contentHeight
        default:
            switch event.charactersIgnoringModifiers {
            case "j": delta = row
            case "k": delta = -row
            default: return super.keyDown(with: event)
            }
        }
        onInteract?()
        scroll(toY: bounds.minY + delta)
    }

    private func select(to position: CodeRows.Position) {
        guard let anchor else { return }
        painter?.selection = anchor < position ? (anchor, position) : (position, anchor)
        onInteract?()
    }

    /// The selected logical lines (not visual rows), joined by newlines.
    var selectedText: String? {
        guard let painter, let selection = painter.selection, selection.start < selection.end else { return nil }
        return painter.document.text(rows: painter.rows, from: selection.start, to: selection.end)
    }

    /// Entries the selection spans, when it selects anything.
    var selectedEntries: ClosedRange<Int>? {
        guard let selection = painter?.selection, selection.start < selection.end else { return nil }
        return selection.start.entry...selection.end.entry
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText else { return }
        NSPasteboard.general.clear(privately: inspectingClosedBoard)
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard let painter, painter.rows.entryCount > 0 else { return }
        let last = painter.rows.entryCount - 1
        self.painter?.selection = (CodeRows.Position(entry: 0, offset: 0), CodeRows.Position(entry: last, offset: painter.text(ofEntry: last).length))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if !inspectingClosedBoard, let mention = CanvasView.mentionItem(in: self, for: event) { menu.addItem(mention) }
        if canEdit, !inspectingClosedBoard {
            let edit = NSMenuItem(title: "Edit Here", action: #selector(editHere(_:)), keyEquivalent: "")
            edit.target = self
            edit.representedObject = NSValue(point: convert(event.locationInWindow, from: nil))
            menu.addItem(edit)
        }
        if selectedText != nil {
            let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
        return menu
    }

    @objc private func editHere(_ sender: NSMenuItem) {
        guard let point = (sender.representedObject as? NSValue)?.pointValue else { return }
        onEditHere?(point)
    }

    // MARK: Accessibility

    /// At most this many lines of a long range are read out.
    static let accessibleLineLimit = 1000

    /// The lines VoiceOver reads (`CodeTile.accessibleText`): the tile's range when it has one
    /// (capped at `accessibleLineLimit`), else the lines in view; nil before the file loaded.
    var accessibleLines: ClosedRange<Int>? {
        guard let painter, painter.document.notice == nil, painter.document.text.lineCount > 0 else { return nil }
        if let range = painter.rangeLines { return range.lowerBound...min(range.upperBound, range.lowerBound + Self.accessibleLineLimit - 1) }
        let lines = painter.visibleRows(bounds.insetBy(dx: 0, dy: min(CodeMetrics.verticalPadding, bounds.height / 2))).compactMap { row -> Int? in
            guard case .line(let line)? = painter.rows.row(row) else { return nil }
            return line
        }
        guard let first = lines.min(), let last = lines.max() else { return nil }
        return first...last
    }

    /// `accessibleLines`, each after its line number.
    func accessibleText() -> AccessibleText? {
        guard let painter, let lines = accessibleLines else { return nil }
        return AccessibleText(numbered: lines.map { ($0, painter.document.text(of: .line($0))) })
    }
}

extension CodeRowsView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(copy(_:)) ? selectedText != nil : true
    }
}
