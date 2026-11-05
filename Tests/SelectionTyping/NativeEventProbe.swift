import AppKit
import Darwin

@MainActor
final class ProbeTextView: NSTextView {
    var mouseEntries = 0
    override func mouseDown(with event: NSEvent) {
        mouseEntries += 1
        print("ENTRY flags=\(event.modifierFlags.rawValue) global=\(NSEvent.modifierFlags.rawValue) before=\(selectedRange()) insertion=\(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))")
        fflush(nil)
        super.mouseDown(with: event)
        print("RETURN range=\(selectedRange())")
        fflush(nil)
    }
}

@MainActor
final class ProbeTicket {
    var continuation: CheckedContinuation<Void, any Error>?
    var monitor: Any?
    func finish(_ error: (any Error)? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}

@main
@MainActor
struct NativeEventProbe {
    static var sequence = 0
    static func dispatch(_ events: [NSEvent], pid: Bool = false, hid: Bool = false) async throws {
        sequence += 1
        let token = sequence
        let ticket = ProbeTicket()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            ticket.continuation = continuation
            ticket.monitor = NSEvent.addLocalMonitorForEvents(matching: [.applicationDefined, .leftMouseUp, .flagsChanged]) { event in
                MainActor.assumeIsolated {
                    if (!pid && !hid && event.type == .applicationDefined && event.subtype.rawValue == 197 && event.data1 == token)
                        || ((pid || hid) && event.type == events.last?.type) {
                        ticket.finish()
                    }
                }
                return event
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                ticket.finish(NSError(domain: "EventDeliveryDeadline", code: token))
            }
            for event in events {
                if hid { event.cgEvent!.post(tap: .cghidEventTap) }
                else if pid { event.cgEvent!.postToPid(getpid()) }
                else { NSApp.postEvent(event, atStart: false) }
            }
            if !pid && !hid {
                NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0, context: nil, subtype: 197, data1: token, data2: 0)!, atStart: false)
            }
        }
    }
    static func key(_ code: UInt16, _ text: String = "", type: NSEvent.EventType = .keyDown,
                    flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)!
    }
    static func run() async {
        print("OS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        for route in ["plain-app", "plain-cg-wrapped", "plain-hid-mouse", "plain-hid-all"] {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 300),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let frame = NSRect(x: 0, y: 0, width: 600, height: 300)
            let editor: NSTextView = route.hasPrefix("plain") ? NSTextView(frame: frame) : ProbeTextView(frame: frame)
            editor.isRichText = false
            editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            window.contentView = editor
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editor)
            do {
                let hidMouse = route.hasPrefix("plain-hid-")
                let hidFlags = route == "plain-hid-all"
                if hidMouse && !CGPreflightPostEventAccess() {
                    print("UNAVAILABLE route=\(route) postEventAccess=false")
                    continue
                }
                for letter in "abcdef" {
                    try await dispatch([key(0, String(letter), window: window), key(0, String(letter), type: .keyUp, window: window)])
                }
                let rect = editor.firstRect(forCharacterRange: NSRange(location: 1, length: 1), actualRange: nil)
                let screenPoint = NSPoint(x: rect.minX + 1, y: rect.midY)
                let point = window.convertPoint(fromScreen: screenPoint)
                let quartz = CGPoint(x: screenPoint.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screenPoint.y)
                let warp = CGWarpMouseCursorPosition(route == "app-queue-warp" ? quartz : CGPoint(x: 5, y: 5))
                print("BEFORE route=\(route) text=\(editor.string) range=\(editor.selectedRange()) insertion=\(editor.characterIndexForInsertion(at: editor.convert(point, from: nil))) key=\(window.isKeyWindow) warp=\(warp.rawValue)")
                try await dispatch([key(56, type: .flagsChanged, flags: .shift, window: window)], hid: hidFlags)
                var events: [NSEvent] = []
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: .shift,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                    if route == "plain-cg-wrapped" {
                        events.append(NSEvent(cgEvent: event.cgEvent!)!)
                    } else if hidMouse {
                        let cg = CGEvent(mouseEventSource: nil,
                            mouseType: type == .leftMouseDown ? .leftMouseDown : .leftMouseUp,
                            mouseCursorPosition: quartz, mouseButton: .left)!
                        cg.flags = .maskShift
                        cg.setIntegerValueField(.mouseEventClickState, value: 1)
                        events.append(NSEvent(cgEvent: cg)!)
                    } else { events.append(event) }
                }
                print("EVENT route=\(route) window=\(events[0].windowNumber) point=\(events[0].locationInWindow) flags=\(events[0].modifierFlags.rawValue)")
                try await dispatch(events, hid: hidMouse)
                try await dispatch([key(56, type: .flagsChanged, window: window)], hid: hidFlags)
                print("RESULT route=\(route) range=\(editor.selectedRange()) entries=\((editor as? ProbeTextView)?.mouseEntries ?? 0) global=\(NSEvent.modifierFlags.rawValue)")
            } catch {
                print("UNAVAILABLE route=\(route) error=\(error)")
            }
            fflush(nil)
        }
        NSApp.stop(nil)
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        Task { await run() }
        app.run()
    }
}
