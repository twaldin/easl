import AppKit

/// Development input replay (`EASL_DEV_INPUT=1`, driven by `scripts/dev-input.swift`).
/// Agents test the UI while the window sits on a Space nobody is viewing, where real HID input
/// can't reach it and posting system events needs a TCC grant. Events go into this app's own
/// queue, so the Hyper monitor, hit testing, and responders run exactly as for real input.
/// See docs/testing.md.
@MainActor
enum DevInput {
    static let notification = Notification.Name("canvas.dev.input")
    /// Where replayed modifier changes happen; real input uses the actual mouse location.
    static var pointer: NSPoint?
    /// The enter/exit tracking areas the last replayed `move` was inside.
    static var hovered: [NSTrackingArea] = []
    /// Files a replayed `panel` chose in an open panel, by panel, until its completion reads them.
    private static var panelChoices: [ObjectIdentifier: [URL]] = [:]

    static let enabled = ProcessInfo.processInfo.environment["EASL_DEV_INPUT"] == "1"

    /// What an open panel that ended with OK chose: a replayed `panel`'s file, else its own.
    static func chosen(in panel: NSOpenPanel) -> [URL] {
        panelChoices.removeValue(forKey: ObjectIdentifier(panel)) ?? panel.urls
    }

    static func install() {
        guard enabled else { return }
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            var fields: [String: String] = [:]
            for (key, value) in note.userInfo ?? [:] {
                if let key = key as? String { fields[key] = "\(value)" }
            }
            MainActor.assumeIsolated { replay(fields) }
        }
    }

    static func modifiers(_ names: String?) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in (names ?? "").split(separator: "+") {
            switch name {
            case "hyper": flags.formUnion([.control, .option, .shift, .command])
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        return flags
    }

    /// A button whose key equivalent is `key`. The Delete key types DEL (`\u{7f}`), and AppKit
    /// matches it to a backspace equivalent (`\u{8}`, the close sheets' ⌘⌫) as well.
    private static func button(in view: NSView?, keyEquivalent key: String) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, !key.isEmpty, button.keyEquivalent == key || key == "\u{7f}" && button.keyEquivalent == "\u{8}" { return button }
        return view.subviews.lazy.compactMap { button(in: $0, keyEquivalent: key) }.first
    }

    static func replay(_ fields: [String: String]) {
        guard fields["pid"] == String(getpid()) else { return }
        // `--repeat N --interval ms`: a burst like a trackpad's event stream. The log line reports
        // the longest gap between consecutive steps (the longest stall a person sees as frozen
        // frames) and the mean lateness against the schedule. Steps come from one strict repeating
        // timer: separate `asyncAfter` calls get leeway proportional to their delay, which showed
        // up as stalls growing through the burst while the main thread sat idle.
        if let count = Int(fields["repeat"] ?? ""), count > 1 {
            var single = fields
            single["repeat"] = nil
            let interval = (Double(fields["interval"] ?? "") ?? 8) / 1000
            @MainActor final class Burst {
                let start = Date()
                var step = 0, last: Date?, gap = 0.0, gapStep = 0, lateness = 0.0
                var timer: DispatchSourceTimer?
            }
            let burst = Burst()
            DevPerf.begin("burst of \(count) \(fields["kind"] ?? "")", phase: "gesture", window: CanvasWindowController.frontmost?.window)
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            burst.timer = timer
            timer.schedule(deadline: .now(), repeating: interval, leeway: .nanoseconds(0))
            timer.setEventHandler {
                MainActor.assumeIsolated {
                    let now = Date(), step = burst.step
                    burst.step += 1
                    burst.lateness += max(0, now.timeIntervalSince(burst.start) - interval * Double(step)) * 1000
                    if let last = burst.last, now.timeIntervalSince(last) * 1000 > burst.gap {
                        burst.gap = now.timeIntervalSince(last) * 1000
                        burst.gapStep = step
                    }
                    burst.last = now
                    // A scroll burst is one trackpad gesture: began, changed…, ended.
                    var event = single
                    event["phase"] = step == 0 ? "began" : step == count - 1 ? "ended" : "changed"
                    replay(event)
                    guard step == count - 1 else { return }
                    burst.timer?.cancel()
                    burst.timer = nil
                    NSLog("DevInput: burst of %d %@ took %.0f ms (scheduled %.0f ms), longest gap %.1f ms before step %d, mean lateness %.1f ms",
                          count, fields["kind"] ?? "", Date().timeIntervalSince(burst.start) * 1000, interval * 1000 * Double(count - 1),
                          burst.gap, burst.gapStep, burst.lateness / Double(count))
                    DevPerf.phase("settle")
                    DispatchQueue.main.asyncAfter(deadline: .now() + DevPerf.settle) { MainActor.assumeIsolated { DevPerf.end() } }
                }
            }
            timer.resume()
            return
        }
        if fields["kind"] == "perf" {
            // A performance probe span over an idle stretch (DevPerf): what redraws and runs while
            // nobody touches the app, also with the window minimized or covered (no frames then).
            let window = CanvasWindowController.frontmost?.window ?? NSApp.windows.first { $0.windowController is CanvasWindowController }
            return DevPerf.idle(ms: Double(fields["ms"] ?? "") ?? 5000, window: window)
        }
        guard let window = CanvasWindowController.frontmost?.window, let content = window.contentView else { return }
        let flags = modifiers(fields["mods"])
        func number(_ key: String) -> CGFloat { CGFloat(Double(fields[key] ?? "") ?? 0) }
        /// Window content points with a top-left origin → window coordinates.
        func point(_ x: String, _ y: String) -> NSPoint {
            window.contentView!.convert(NSPoint(x: number(x), y: content.bounds.height - number(y)), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, _ at: NSPoint, clicks: Int = 1) {
            let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
            NSApp.postEvent(event, atStart: false)
        }
        switch fields["kind"] {
        case "click":
            let at = point("x", "y")
            let clicks = Int(fields["clicks"] ?? "") ?? 1
            for click in 1...max(1, clicks) {
                mouse(.leftMouseDown, at, clicks: click)
                mouse(.leftMouseUp, at, clicks: click)
            }
        case "rightclick":
            let at = point("x", "y")
            mouse(.rightMouseDown, at)
            mouse(.rightMouseUp, at)
        case "menu", "mainmenu":
            // A shown context menu runs a tracking loop posted events can't drive: build the menu
            // a right-click at x,y would show (the hit view, then its superviews), or for
            // `mainmenu` take the menu bar, and perform the item at `path`, titles separated by
            // "/" (e.g. "Content Zoom/150%", "Edit/Send Mentions To/codex"; "//" is a slash in a
            // title: "Review Changes/Branch vs origin//main"). Submenus filled as they open
            // (their delegate's `menuNeedsUpdate`) are filled first.
            var menu: NSMenu?
            if fields["kind"] == "mainmenu" {
                menu = NSApp.mainMenu
            } else {
                let at = point("x", "y")
                guard let frame = content.superview, let hit = content.hitTest(frame.convert(at, from: nil)),
                      let event = NSEvent.mouseEvent(with: .rightMouseDown, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                menu = CodeNavigation.menu(for: event) ?? sequence(first: hit, next: \.superview).lazy.compactMap { $0.menu(for: event) }.first
            }
            var titles = (fields["path"] ?? "").replacingOccurrences(of: "//", with: "\u{0}").split(separator: "/").map { $0.replacingOccurrences(of: "\u{0}", with: "/") }
            while let current = menu, !titles.isEmpty {
                current.delegate?.menuNeedsUpdate?(current)
                let title = titles.removeFirst()
                guard let index = current.items.firstIndex(where: { $0.title == title }) else {
                    return NSLog("DevInput: no menu item %@ in [%@]", title, current.items.map(\.title).joined(separator: ", "))
                }
                if titles.isEmpty { current.performActionForItem(at: index) } else { menu = current.items[index].submenu }
            }
        case "move":
            // Tracking-area events come from the window server; a posted mouseMoved never reaches
            // their owners. Deliver them to the areas under the point directly: mouseMoved, and
            // mouseEntered/mouseExited as the point enters and leaves areas (a tile's hover
            // controls), against where the last replayed move was.
            let at = point("x", "y")
            guard let frame = content.superview, let hit = content.hitTest(frame.convert(at, from: nil)),
                  let event = NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
            var entered: [NSTrackingArea] = []
            for view in sequence(first: hit, next: \.superview) {
                let local = view.convert(at, from: nil)
                for area in view.trackingAreas {
                    let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                    guard rect.contains(local) else { continue }
                    if area.options.contains(.mouseEnteredAndExited) { entered.append(area) }
                    guard area.options.contains(.mouseMoved) else { continue }
                    // Owners needn't be responders (any object implementing mouseMoved:).
                    let moved = #selector(NSResponder.mouseMoved(with:))
                    if let owner = area.owner as? NSObject, owner.responds(to: moved) { owner.perform(moved, with: event) }
                }
            }
            // Real enter/exit events, to easl's own owners only: AppKit's and WebKit's private
            // owners read state a replayed event doesn't carry.
            func deliver(_ type: NSEvent.EventType, _ selector: Selector, to areas: [NSTrackingArea]) {
                for area in areas {
                    guard let owner = area.owner as? NSObject, NSStringFromClass(Swift.type(of: owner)).hasPrefix("CanvasApp."), owner.responds(to: selector),
                          let crossing = NSEvent.enterExitEvent(with: type, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                                trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil) else { continue }
                    owner.perform(selector, with: crossing)
                }
            }
            deliver(.mouseExited, #selector(NSResponder.mouseExited(with:)), to: hovered.filter { old in !entered.contains { $0 === old } })
            deliver(.mouseEntered, #selector(NSResponder.mouseEntered(with:)), to: entered.filter { new in !hovered.contains { $0 === new } })
            hovered = entered
        case "drag":
            let start = point("x", "y")
            let end = point("toX", "toY")
            mouse(.leftMouseDown, start)
            for step in 1...8 {
                let t = CGFloat(step) / 8
                mouse(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
            // `--hold`: the button stays down (a shot of the gesture mid-drag); `release` ends it.
            if fields["hold"] == nil { mouse(.leftMouseUp, end) }
        case "release":
            mouse(.leftMouseUp, point("x", "y"))
        case "flags":
            // Holding (or releasing) modifiers with the pointer at x,y: drives hover outlines.
            pointer = point("x", "y")
            if let event = NSEvent.keyEvent(with: .flagsChanged, location: point("x", "y"), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0) {
                NSApp.postEvent(event, atStart: false)
            }
        case "text":
            // Typing goes to a sheet (e.g. the group-name prompt) when one is open.
            ((window.attachedSheet ?? window).firstResponder as? NSTextInputClient)?.insertText(fields["text"] ?? "", replacementRange: NSRange(location: NSNotFound, length: 0))
        case "panel":
            // An open panel (a page's file upload) runs out of process, where no replayed click
            // or key reaches its file list: choose `path` in it (as Upload with that file
            // selected would).
            guard let panel = window.attachedSheet as? NSOpenPanel else { return NSLog("DevInput: no open panel") }
            panelChoices[ObjectIdentifier(panel)] = [URL(fileURLWithPath: fields["path"] ?? "")]
            window.endSheet(panel, returnCode: .OK)
        case "command":
            (window.attachedSheet ?? window).firstResponder?.doCommand(by: NSSelectorFromString(fields["selector"] ?? ""))
        case "shortcut", "key":
            guard let key = Key(fields["key"] ?? "") else { return NSLog("DevInput: unknown key %@", fields["key"] ?? "") }
            // A sheet in a window that isn't key ignores key equivalents (an alert's default button
            // only gets Return once key), so press the matching button, or accept on Return. A save
            // panel runs out of process, where no replayed event reaches: Return saves under the
            // name it suggested.
            if let sheet = window.attachedSheet {
                if let pressed = button(in: sheet.contentView, keyEquivalent: key.characters) { return pressed.performClick(nil) }
                if key.code == Key.returnCode { return window.endSheet(sheet, returnCode: sheet is NSSavePanel ? .OK : .alertFirstButtonReturn) }
            }
            // Through the application's own dispatch, as a key press arrives: key equivalents
            // (window, then its views, then the main menu), then keyDown to the first responder,
            // with the physical key code Ghostty and the text system read.
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = key.event(type, modifiers: flags, window: window) { NSApp.postEvent(event, atStart: false) }
            }
        case "scroll":
            // Pixel units are a trackpad's precise scroll; `lines`, a mouse wheel's notches (not
            // continuous: AppKit reports them as lines, without precise deltas).
            let lines = fields["lines"] != nil
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: lines ? .line : .pixel, wheelCount: 2, wheel1: Int32(number("dy")), wheel2: Int32(number("dx")), wheel3: 0) else { return }
            if lines { cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0) }
            // CGEvent locations are global with a top-left origin (primary display), not Cocoa's.
            let at = point("x", "y")
            let screen = window.convertPoint(toScreen: at)
            cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
            // A burst step is a continuous (trackpad-precise) delta without a gesture phase: on
            // macOS 26 a replayed phased gesture only moves the view by its first step (NSScrollView
            // tracks the rest of a real gesture itself and drops directly delivered steps). A
            // single step is a phaseless wheel notch, which AppKit animates as a smooth scroll.
            if fields["phase"] != nil { cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
            // `--gesture`: the burst as a trackpad gesture with its phases (began and ended carry no
            // movement), for views that own a gesture from its first event (a changes tile's scroll).
            if fields["gesture"] != nil, let phase = fields["phase"], let field = CGEventField(rawValue: 99) {
                let phases: [String: Int64] = ["began": 1, "changed": 2, "ended": 4]
                cg.setIntegerValueField(field, value: phases[phase] ?? 2)
                if phase != "changed" {
                    cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
                    cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
                    cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
                    cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
                    cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
                    cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
                }
            }
            // A window-less event's locationInWindow is its screen location, which only matches the
            // window near the primary display's origin; hand it to the view under the point instead
            // of relying on sendEvent's hit test (windows on other displays got nothing).
            guard let event = NSEvent(cgEvent: cg), let frame = content.superview,
                  let hit = content.hitTest(frame.convert(at, from: nil)) else { return }
            if (window as? CanvasWindow)?.zoomsCanvas(event, at: at) == true { return }
            hit.scrollWheel(with: event)
        case "magnify":
            // A trackpad pinch step as a real gesture event: CG type 29 (gesture) with HID type 8
            // (zoom) becomes an NSEvent of type .magnify, so NSScrollView runs its own live
            // magnification (scaled layers mid-gesture, a redraw at the end) exactly as for a pinch.
            guard let cg = CGEvent(source: nil), let type = CGEventType(rawValue: 29),
                  let hidType = CGEventField(rawValue: 110), let zoom = CGEventField(rawValue: 113),
                  let gesturePhase = CGEventField(rawValue: 132) else { return }
            cg.type = type
            cg.setIntegerValueField(hidType, value: 8)
            cg.setDoubleValueField(zoom, value: Double(number("amount")))
            let phases: [String: Int64] = ["began": 1, "changed": 2, "ended": 4]
            cg.setIntegerValueField(gesturePhase, value: phases[fields["phase"] ?? ""] ?? 2)
            let at = point("x", "y")
            // A window-less event's locationInWindow is its Cocoa screen location; make that the
            // replayed point, or the scroll view ignores a pinch that seems to be outside it.
            cg.location = CGPoint(x: at.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - at.y)
            guard let event = NSEvent(cgEvent: cg), event.type == .magnify, let frame = content.superview,
                  let hit = content.hitTest(frame.convert(at, from: nil)) else { return }
            var view: NSView? = hit
            while let current = view, !(current is NSScrollView) { view = current.superview }
            // Live magnification anchors at the real pointer (wherever the user's mouse is), so put
            // the document point that was under the replayed point back under it after each step.
            let clip = (view as? NSScrollView)?.contentView
            let anchor = clip?.convert(at, from: nil)
            hit.magnify(with: event)
            if let clip, let anchor, let scroll = view as? NSScrollView {
                let drift = clip.convert(at, from: nil)
                clip.scroll(to: NSPoint(x: clip.bounds.minX + anchor.x - drift.x, y: clip.bounds.minY + anchor.y - drift.y))
                scroll.reflectScrolledClipView(clip)
            }
        default:
            NSLog("DevInput: unknown kind \(fields["kind"] ?? "nil")")
        }
    }
}

extension DevInput {
    /// A key on a US ANSI keyboard, from a single character (`p`, `9`, `+`, `\r`) or a name
    /// (`return`, `escape`, `tab`, `space`, `delete`, `forwarddelete`, arrows, `home`, `end`,
    /// `pageup`, `pagedown`): its virtual key code, the characters it types, and whether it
    /// implies Shift (`+`, `A`, `?`).
    struct Key {
        static let returnCode: UInt16 = 36
        var code: UInt16
        var characters: String
        var shift = false
        /// Arrows and the navigation block carry these flags on real key events.
        var extraFlags: NSEvent.ModifierFlags = []

        private static let named: [String: Key] = {
            func function(_ code: UInt16, _ scalar: Int, arrow: Bool = false) -> Key {
                Key(code: code, characters: String(Character(UnicodeScalar(UInt32(scalar))!)), extraFlags: arrow ? [.function, .numericPad] : .function)
            }
            return [
                "return": Key(code: returnCode, characters: "\r"), "enter": Key(code: returnCode, characters: "\r"),
                "tab": Key(code: 48, characters: "\t"), "space": Key(code: 49, characters: " "),
                "delete": Key(code: 51, characters: "\u{7f}"), "backspace": Key(code: 51, characters: "\u{7f}"),
                "escape": Key(code: 53, characters: "\u{1b}"), "esc": Key(code: 53, characters: "\u{1b}"),
                "forwarddelete": function(117, NSDeleteFunctionKey), "home": function(115, NSHomeFunctionKey), "end": function(119, NSEndFunctionKey),
                "pageup": function(116, NSPageUpFunctionKey), "pagedown": function(121, NSPageDownFunctionKey),
                "left": function(123, NSLeftArrowFunctionKey, arrow: true), "right": function(124, NSRightArrowFunctionKey, arrow: true),
                "down": function(125, NSDownArrowFunctionKey, arrow: true), "up": function(126, NSUpArrowFunctionKey, arrow: true),
            ]
        }()

        /// Unshifted characters by key code, then the shifted ones.
        private static let plain: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "`": 50, "\r": 36, "\n": 36, "\t": 48, " ": 49, "\u{1b}": 53, "\u{7f}": 51, "\u{8}": 51,
        ]
        private static let shifted: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
            "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
        ]

        init(code: UInt16, characters: String, shift: Bool = false, extraFlags: NSEvent.ModifierFlags = []) {
            self.code = code
            self.characters = characters
            self.shift = shift
            self.extraFlags = extraFlags
        }

        init?(_ name: String) {
            if let key = Self.named[name.lowercased()] { self = key; return }
            guard name.count == 1, let character = name.first else { return nil }
            if let code = Self.plain[character] {
                self.init(code: code, characters: character == "\n" ? "\r" : character == "\u{8}" ? "\u{7f}" : name)
            } else if let base = Self.shifted[character] ?? (character.isUppercase ? Character(character.lowercased()) : nil), let code = Self.plain[base] {
                self.init(code: code, characters: name, shift: true)
            } else {
                return nil
            }
        }

        /// A key down or up as the window server delivers it: `characters` with Control applied
        /// (⌃C is ETX), `charactersIgnoringModifiers` with only Shift.
        @MainActor
        func event(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent? {
            var flags = modifiers.union(extraFlags)
            if shift { flags.insert(.shift) }
            var ignoring = characters
            if flags.contains(.shift), !shift, characters.count == 1, let character = characters.first {
                ignoring = Self.shifted.first { $0.value == character }.map { String($0.key) } ?? characters.uppercased()
            }
            var typed = ignoring
            if flags.contains(.control), let scalar = ignoring.lowercased().unicodeScalars.first, ("a"..."z").contains(scalar) {
                typed = String(UnicodeScalar(UInt8(scalar.value - 96)))
            }
            return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: typed, charactersIgnoringModifiers: ignoring,
                                    isARepeat: false, keyCode: code)
        }
    }
}
