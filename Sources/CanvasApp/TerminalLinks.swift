import AppKit
import CanvasCore
import GhosttyKit
import GhosttyTerminal

/// The Ghostty view of a terminal tile, with ⌘-hover and ⌘-click on `path:line` references
/// (`TerminalReferences`) that resolve to a file. Everything else (URLs included) stays Ghostty's.
@MainActor
final class CanvasTerminalView: TerminalView {
    /// The reference at a point in this view's coordinates, if it names an existing file.
    var linkAt: ((NSPoint) -> TerminalReferences.Hit?)?
    var onHover: ((TerminalReferences.Hit?) -> Void)?
    /// A ⌘-clicked reference; `newTile` for ⌥⌘- or ⇧⌘-click (always a tile of its own).
    var onOpen: ((TerminalReferences.Hit, _ newTile: Bool) -> Void)?
    /// A ⌘-click that found no file to open (`linkAt` was nil) at a point in this view's coordinates.
    var onMissedLink: ((NSPoint, _ newTile: Bool) -> Void)?
    /// Keyboard focus came or went: libghostty-spm has just told Ghostty the view is focused
    /// or not, without asking whether its window is key in an active app.
    var onFocusChange: (() -> Void)?
    /// Whether the terminal has scrollback to scroll (more rows than its screen).
    var hasScrollback: (() -> Bool)?

    private var swallowedMouseUp = false
    private var hovered: TerminalReferences.Hit?
    /// AppKit takes keyboard focus from a view it hides, and a terminal is hidden whenever its
    /// tile turns into its card (panned offscreen, zoomed out, a resize that took it out of
    /// view): the terminal that lost focus that way gets it back when shown again, unless
    /// something took it meanwhile. One at a time: focusing any terminal forgets it.
    private static weak var refocusTarget: CanvasTerminalView?

    override func becomeFirstResponder() -> Bool {
        Self.refocusTarget = nil
        let became = super.becomeFirstResponder()
        onFocusChange?()
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isHiddenOrHasHiddenAncestor { Self.refocusTarget = self }
        onFocusChange?()
        return resigned
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        guard Self.refocusTarget === self, let window else { return }
        Self.refocusTarget = nil
        // Nothing chose a responder since: AppKit leaves the window or hands the canvas the focus.
        if window.firstResponder == nil || window.firstResponder === window || window.firstResponder is CanvasDocumentView {
            window.makeFirstResponder(self)
        }
    }

    /// Out of the key-view loop, so hiding one terminal never passes the focus to another
    /// (which would then take the refocus when it is hidden in turn).
    override var canBecomeKeyView: Bool { false }

    /// A ⌥⌘-click is on its way to Ghostty as a ⌘-click (below), so a web link it opens goes to the
    /// default browser (`TerminalTile.openLink`).
    private(set) var forcingDefaultBrowser = false

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let point = convert(event.locationInWindow, from: nil)
        if flags.contains(.command), let hit = linkAt?(point) {
            // Ghostty never sees this click, so it neither selects nor opens anything.
            swallowedMouseUp = true
            setHover(nil)
            onOpen?(hit, !flags.isDisjoint(with: [.option, .shift]))
            return
        }
        if flags.contains(.command) { onMissedLink?(point, !flags.isDisjoint(with: [.option, .shift])) }
        forcingDefaultBrowser = Self.isOptionCommand(flags)
        super.mouseDown(with: forcingDefaultBrowser ? Self.commandOnly(event) : event)
    }

    /// Ghostty opens a URL only for a click with exactly ⌘ (its `link-url` modifiers must equal
    /// the click's, so ⌥⌘ finds no link). ⌥⌘-click on a URL is the user's way to ask for the
    /// default browser, so Ghostty gets the click as a plain ⌘-click and `forcingDefaultBrowser`
    /// says where the URL goes.
    private static func isOptionCommand(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .option, .control, .shift]) == [.command, .option]
    }

    private static func commandOnly(_ event: NSEvent) -> NSEvent {
        NSEvent.mouseEvent(with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags.subtracting(.option),
                           timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                           clickCount: event.clickCount, pressure: event.pressure) ?? event
    }

    /// In a window that isn't key, AppKit hands a view only a plain ⌘-click; ⌥⌘- and ⇧⌘-clicks
    /// on a reference open it there too, and a ⌥⌘-click is always taken (it may be on a URL).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if let event, Self.isOptionCommand(event.modifierFlags) { return true }
        if let event, event.modifierFlags.contains(.command), linkAt?(convert(event.locationInWindow, from: nil)) != nil { return true }
        return super.acceptsFirstMouse(for: event)
    }

    override func mouseUp(with event: NSEvent) {
        if swallowedMouseUp {
            swallowedMouseUp = false
            return
        }
        defer { forcingDefaultBrowser = false }
        super.mouseUp(with: forcingDefaultBrowser ? Self.commandOnly(event) : event)
    }

    /// Scrolling goes to the terminal (its scrollback, or a program that reads the wheel) except
    /// when it would pan over a code tile too: a horizontal-dominant step pans the canvas, and
    /// over a terminal without keyboard focus a vertical step pans unless the terminal has
    /// scrollback to scroll (a full-screen TUI in the alternate screen has none; click in first).
    override func scrollWheel(with event: NSEvent) {
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        if horizontal || (window?.firstResponder !== self && hasScrollback?() != true) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil), command: event.modifierFlags.contains(.command))
    }

    /// How long the key waited in the event queue for the main thread (`event.timestamp` is the
    /// press, on the uptime clock) and how long handing it to Ghostty took: `easl metrics` "keys".
    /// A main-thread stall holds every key typed during it and releases them together, late and
    /// in order; a long wait here is the board's doing, upstream of the terminal, zmx and the
    /// program. A wait over `Metrics.hitchStretch` is logged with the stretch that caused it.
    override func keyDown(with event: NSEvent) {
        let waited = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
        let start = Metrics.now()
        super.keyDown(with: event)
        Metrics.shared.record("key.wait", ms: waited)
        Metrics.shared.record("key.handle", ms: (Metrics.now() - start) * 1000)
        if waited >= Metrics.hitchStretch { NSLog("easl: a key waited %.0f ms for the main thread", waited) }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), command: event.modifierFlags.contains(.command))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHover(nil)
    }

    private func updateHover(at point: NSPoint, command: Bool) {
        setHover(command && bounds.contains(point) ? linkAt?(point) : nil)
        if hovered != nil { NSCursor.pointingHand.set() }
    }

    private func setHover(_ hit: TerminalReferences.Hit?) {
        guard hit != hovered else { return }
        hovered = hit
        onHover?(hit)
    }
}

extension TerminalSurface {
    /// Ghostty's handle for this surface, for its public C API where libghostty-spm has no
    /// wrapper. The wrapper keeps it private, so it's taken by reflection; nil if a package
    /// update renames it.
    var handle: ghostty_surface_t? {
        Mirror(reflecting: self).children.first(where: { $0.label == "surface" })?.value as? ghostty_surface_t
    }

    /// The text of viewport row `row`, `columns` cells wide. libghostty-spm reads a grid's text
    /// only for its in-memory backend (`InMemoryTerminalSession.readViewportText`); for exec
    /// surfaces it's read through Ghostty's C API the same way.
    func viewportRow(_ row: Int, columns: Int) -> String? {
        guard row >= 0, columns > 0, let handle else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(columns - 1), y: UInt32(row)),
            rectangle: false)
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(handle, selection, &out) else { return nil }
        defer { ghostty_surface_free_text(handle, &out) }
        guard let text = out.text, out.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: text, count: Int(out.text_len)), as: UTF8.self)
    }
}

/// Underlines the hovered reference over the terminal; transparent to the mouse.
@MainActor
final class TerminalLinkUnderline: NSView {
    var rects: [NSRect] = [] { didSet { if rects != oldValue { needsDisplay = true } } }
    var color: NSColor = .labelColor

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        rects.forEach { $0.fill() }
    }
}
