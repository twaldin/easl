import AppKit
import CanvasCore

@testable import CanvasApp

@main
@MainActor
private enum TerminalEcho {
    static func main() {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let text = NSTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(text)
        window.makeKeyAndOrderFront(nil)
        precondition(window.makeFirstResponder(text))
        defer { window.close() }

        var systemIdle = 120.0
        var now = 100.0
        let watch = UserIdleWatch(sessionIdle: { systemIdle }, uptime: { now })
        watch.start()
        precondition(watch.isIdle, "a stale HID clock starts idle")
        func typeA() {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: "a", charactersIgnoringModifiers: "a",
                                         isARepeat: false, keyCode: 0)!
            app.sendEvent(event)
        }
        typeA()
        precondition(text.string == "a", "the native key must reach the first responder")
        precondition(!watch.isIdle, "native app input immediately restores drawing")
        now = 100.25
        watch.pin("auto")
        precondition(!watch.isIdle, "a stale HID sample must not undo recent native app input")
        precondition(abs(watch.currentIdleSeconds() - 0.25) < 0.0001)

        now = 150
        typeA()
        precondition(text.string == "aa")
        now = 209.9
        watch.pin("auto")
        precondition(!watch.isIdle, "input while active extends the full-rate interval")
        now = 210
        watch.pin("auto")
        precondition(watch.isIdle, "terminals become idle after a minute without either input source")
        systemIdle = 0.1
        now = 220
        watch.pin("auto")
        precondition(!watch.isIdle && watch.currentIdleSeconds() == 0.1, "input elsewhere on the Mac restores drawing")
        watch.pin("on")
        typeA()
        precondition(watch.isIdle, "the explicit development pin still overrides native input")
        watch.pin("off")
        precondition(!watch.isIdle && watch.currentIdleSeconds() == 0)
        now = 400
        systemIdle = 120
        watch.pin("on")
        typeA()
        precondition(watch.isIdle)
        watch.pin("auto")
        precondition(!watch.isIdle, "clearing a pin restores activity observed while pinned")
        print("PASS native input survives stale HID samples, active input renews the interval, idle expires, other-app input and explicit pins remain effective")
        print("TERMINAL_ECHO_COMPLETE")
    }
}
