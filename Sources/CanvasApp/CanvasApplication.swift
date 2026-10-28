import AppKit

/// With `EASL_NO_ACTIVATE=1` (development and agent testing on a shared machine) the app never
/// activates, so nothing it does can steal focus or switch the user's Space.
final class CanvasApplication: NSApplication {
    static let neverActivate = ProcessInfo.processInfo.environment["EASL_NO_ACTIVATE"] == "1"
    private(set) static var replayWindow: NSWindow?

    override func activate(ignoringOtherApps flag: Bool) {
        if !Self.neverActivate { super.activate(ignoringOtherApps: flag) }
    }

    override func activate() {
        if !Self.neverActivate { super.activate() }
    }

    // MARK: Input replay

    // Replayed key presses (`DevInput`) go to a window that can't become key (the app never
    // activates). AppKit would offer them to the main menu only and resolve untargeted menu
    // actions (Select All, Copy, Paste) past the focused view to the app delegate. Both are
    // dispatched as for the key window a real key press has.

    /// A key press for a board window while no window is key: key equivalents to the window
    /// (`CanvasWindow`'s navigation shortcuts, then its views), then the main menu, then keyDown
    /// to the first responder.
    override func sendEvent(_ event: NSEvent) {
        // A streamed page's input runs from its marker (`SurfaceEventQueue`). A key that page
        // didn't handle comes back here from WebKit; it is the viewer's, and would otherwise
        // reach this Mac's canvas (Delete deletes tiles) or its menus (⌘W, ⌘Q).
        if SurfaceEventQueue.consumes(event) { return }
        let previousWindow = Self.replayWindow
        if DevInput.enabled { Self.replayWindow = event.window }
        defer { Self.replayWindow = previousWindow }
        if let window = (event.window ?? keyWindow) as? ShortcutSettingsWindow,
           window.captureKeyEvent(event) { return }
        if DevInput.enabled, event.type == .keyDown || event.type == .keyUp,
           let window = event.window, window !== keyWindow, window.windowController is CanvasWindowController {
            if event.type == .keyDown, let controller = window.windowController as? CanvasWindowController,
               !controller.canvas.admitsKeyDown(event) { return }
            if event.type == .keyDown, window.performKeyEquivalent(with: event) || mainMenu?.performKeyEquivalent(with: event) == true { return }
            return window.sendEvent(event)
        }
        super.sendEvent(event)
    }

    /// Replayed actions follow the exact replay window's responder chain before AppKit's.
    override func target(forAction action: Selector, to target: Any?, from sender: Any?) -> Any? {
        if target == nil, DevInput.enabled,
           let window = Self.replayWindow ?? (keyWindow == nil ? CanvasWindowController.frontmost?.window : nil) {
            var responder = window.firstResponder
            while let current = responder {
                if current.responds(to: action) { return current }
                responder = current.nextResponder
            }
        }
        return super.target(forAction: action, to: target, from: sender)
    }
}
