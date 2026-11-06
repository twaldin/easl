// Run only in the claimed macOS guest, from the resources checkout:
// python3 Tests/TileScrolling/run.py --bin-path "$NATIVE_BIN_PATH" --resources "$PWD" --output "$EVIDENCE_OUT" --harness-source "$SCROLL_ACCEPTANCE_SOURCE"
// NATIVE_BIN_PATH must contain an existing native, testing-enabled build; use this
// exact source for 94969df3 and candidate. The runner links but never rebuilds Easl.
// Queue synthesis must qualify before interpreting a routing assertion failure.

import AppKit
import WebKit
import Darwin
import GhosttyTerminal

@testable import CanvasCore

@testable import CanvasApp

extension JSONValue: @retroactive ExpressibleByStringLiteral, @retroactive ExpressibleByBooleanLiteral, @retroactive ExpressibleByArrayLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}


@MainActor
private enum SelectionTyping {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private struct Scenario: Encodable {
        let name: String
        let baseline: String
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message) }
    }

    private static func wait(_ message: String, until condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(message)
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func js(_ web: WKWebView, _ expression: String) async -> Any? {
        try? await web.evaluateJavaScript(expression)
    }

    private static let page = """
    <!doctype html><meta charset="utf-8"><style>body{margin:0;padding:20px}textarea{width:240px;height:100px;display:block}</style>
    <p id="plain">Selection typing fixture</p><textarea id="field"></textarea><textarea id="second"></textarea><output id="keys"></output>
    <script>
    document.getElementById('field').focus();
    document.addEventListener('keydown', event => {
      if (event.key.length === 1) document.getElementById('keys').textContent += event.key;
    });
    </script>
    """

    private static func key(_ code: UInt16, _ text: String, type: NSEvent.EventType = .keyDown, flags: NSEvent.ModifierFlags = [], isARepeat: Bool = false, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: flags.contains(.shift) ? text.uppercased() : text,
            charactersIgnoringModifiers: flags.contains(.shift) ? text.uppercased() : text,
            isARepeat: isARepeat, keyCode: code)!
    }

    private static var mouseEventNumber = 0

    private static func mouse(_ type: NSEvent.EventType, _ point: NSPoint, flags: NSEvent.ModifierFlags = [], clickCount: Int = 1, in window: NSWindow) -> NSEvent {
        mouseEventNumber += 1
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: mouseEventNumber, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private static var eventBatch = 0

    private static func post(_ events: [NSEvent]) async throws {
        eventBatch += 1
        let batch = eventBatch
        var delivered = false
        guard let marker = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            subtype: 27183, data1: batch, data2: 0),
              let monitor = NSEvent.addLocalMonitorForEvents(matching: .any, handler: { event in
                  MainActor.assumeIsolated {
                      if event.type == .applicationDefined, event.subtype.rawValue == 27183, event.data1 == batch {
                          delivered = true
                      }
                  }
                  return event
              }) else { throw Failure("native event queue marker could not be installed") }
        defer { NSEvent.removeMonitor(monitor) }
        for event in events { NSApp.postEvent(event, atStart: false) }
        NSApp.postEvent(marker, atStart: false)
        try await wait("AppKit did not dispatch native event batch \(batch)") { delivered }
        await MainTurns.next()
    }
    private static func drag(_ start: NSPoint, _ end: NSPoint, in window: NSWindow) async throws {
        try await post([mouse(.leftMouseDown, start, in: window)])
        for step in 1...8 {
            let fraction = CGFloat(step) / 8
            try await post([mouse(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction), in: window)])
        }
        try await post([mouse(.leftMouseUp, end, in: window)])
    }
    @MainActor
    private final class Fixture {
        let root: URL
        let registry: BoardRegistry
        let board: Board
        let window: CanvasWindow
        let controller: CanvasWindowController
        var canvas: CanvasView { controller.canvas }
        var terminals: [CanvasObject] = []
        var receipts: [ObjectID: URL] = [:]
        private let delegate = AppDelegate()
        private let oldDelegate: NSApplicationDelegate?
        private let oldWindowsMenu: NSMenu?
        private let oldHelpMenu: NSMenu?
        private let oldMenu: NSMenu?

        init(home: URL, changes: Bool) async throws {
            oldMenu = NSApp.mainMenu
            oldDelegate = NSApp.delegate
            oldWindowsMenu = NSApp.windowsMenu
            oldHelpMenu = NSApp.helpMenu
            root = home.appendingPathComponent("board")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("fixture.swift")
            try Data((1...80).map { "let line\($0) = \($0)\n" }.joined().utf8).write(to: source)
            if changes {
                for arguments in [["init", "-q"], ["add", "fixture.swift"],
                    ["-c", "user.name=Selection Typing", "-c", "user.email=selection@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"]] {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    process.arguments = arguments
                    process.currentDirectoryURL = root
                    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                        do { try process.run() }
                        catch {
                            process.terminationHandler = nil
                            continuation.resume(throwing: error)
                        }
                    }
                    guard status == 0 else { throw Failure("git fixture setup failed") }
                }
                try Data("let changed = true\n".utf8).write(to: source)
            }
            try Data(page.utf8).write(to: root.appendingPathComponent("page.html"))
            registry = BoardRegistry(store: BoardStore(directory: home.appendingPathComponent("boards")))
            board = try await registry.open(root: root)
            window = CanvasWindow(contentRect: NSRect(x: 40, y: 40, width: 1200, height: 820),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            controller = CanvasWindowController(window: window, board: board, registry: registry,
                viewport: nil, composerState: ComposerState())
            controller.isBoardOpen = true
            board.onEvent = { [weak controller] in controller?.apply($0) }
            NSApp.delegate = delegate
            NSApp.mainMenu = AppDelegate.makeMenu()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.layoutIfNeeded()
            canvas.hasHorizontalScroller = false
            canvas.hasVerticalScroller = false
            canvas.show(Viewport(rect: Frame(x: -100, y: -100, w: 1200, h: 820), zoom: 1))
            window.makeFirstResponder(canvas.document)
            try await Task.sleep(for: .milliseconds(150))
            try await wait("isolated dispatch fixture must be active with a key board window") {
                NSApp.isActive && self.window.isKeyWindow
            }
        }

        func create(_ type: ObjectType, x: Double = 30, y: Double = 45, width: Double = 450, height: Double = 290) async throws -> CanvasObject {
            var props: JSONValue
            switch type {
            case .terminal:
                guard AppPaths.zmx != nil else { throw Failure("fixture prerequisite: zmx is required for real terminal readback and owned-session cleanup") }
                let receipt = root.appendingPathComponent("input-\(terminals.count).bin")
                let ready = receipt.appendingPathExtension("ready")
                let history = CommandLine.arguments.contains("terminal-history-unfocused")
                let alternate = CommandLine.arguments.contains("terminal-alternate-typing")
                let output = history
                    ? "i=1; while [ $i -le 160 ]; do printf 'HISTORY ROW %03d\\r\\n' $i; i=$((i+1)); done; printf 'LIVE SCROLL READY'"
                    : (alternate ? "printf '\\033[?1049h\\033[?1007hLIVE SCROLL READY'" : "printf '\\033[3J\\033[2J\\033[HLIVE SCROLL READY'")
                let go = root.appendingPathComponent("scroll-output-go")
                let script = "stty -echo -icanon min 1 time 0; : > " + ShellWords.quote([ready.path])
                    + "; (while [ ! -e " + ShellWords.quote([go.path]) + " ]; do sleep 0.05; done; "
                    + output + ") & exec /bin/cat >> " + ShellWords.quote([receipt.path])
                props = .object(["command": .array(["/bin/sh", "-c", .string(script)])])
            case .note: props = .object(["markdown": "First paragraph.\n\nSecond paragraph.\n"])
            case .html: props = .object(["html": .string(page)])
            case .browser: props = .object(["url": .string(root.appendingPathComponent("page.html").absoluteString)])
            case .image:
                let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
                for y in 0..<8 { for x in 0..<8 { image.setColor(blue, atX: x, y: y) } }
                try image.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("image.png"))
                props = .object(["path": "image.png"])
            default: throw Failure("unsupported fixture type \(type.rawValue)")
            }
            let object = board.create(type: type, props: props, frame: Frame(x: x, y: y, w: width, h: height))
            try require(board.objects[object.id]?.type == type, "created fixture must retain its real object identity")
            if type == .terminal {
                receipts[object.id] = root.appendingPathComponent("input-\(terminals.count).bin")
                terminals.append(object)
                let sessions = terminals.map { ["tile": $0.id, "session": TerminalTile.sessionName($0.id), "home": AppPaths.support.path] }
                try JSONEncoder().encode(sessions).write(to: AppPaths.support.appendingPathComponent("sessions.json"), options: .atomic)
                try await wait("real terminal program did not enter raw input mode") {
                    FileManager.default.fileExists(atPath: self.receipts[object.id]!.appendingPathExtension("ready").path)
                        && (self.canvas.tiles[object.id]?.content as? TerminalTile)?.surface != nil
                }
            }
            window.layoutIfNeeded()
            window.displayIfNeeded()
            try await ready(object.id)
            return object
        }

        func hit(_ point: NSPoint) -> NSView? {
            guard let content = window.contentView else { return nil }
            return content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        }

        func diagnostic(_ point: NSPoint? = nil) -> String {
            let hit = point.flatMap { self.hit($0) }
            let objects = board.objects.values.sorted { $0.id < $1.id }.map { "\($0.id):\($0.type.rawValue)" }
            return "board=\(board.id) objects=\(objects) selection=\(canvas.selection) focused=\(String(describing: canvas.focusedTile)) responder=\(String(describing: window.firstResponder)) point=\(String(describing: point)) hit=\(String(describing: hit)) viewport=\(canvas.viewport)"
        }

        func ready(_ id: ObjectID) async throws {
            try await wait("target \(id) must have laid-out native geometry; \(diagnostic())") {
                self.window.layoutIfNeeded()
                self.window.displayIfNeeded()
                if let group = self.canvas.groups[id] {
                    guard group.region.width > 0, group.region.height > 0, group.titleRect.width > 0 else { return false }
                    let point = group.convert(NSPoint(x: group.titleRect.midX, y: group.titleRect.midY), to: nil)
                    return self.hit(point) === group && group.objectID == id
                }
                if self.board.objects[id]?.type == .shape {
                    return self.canvas.docFrame(id).map { $0.width > 0 && $0.height > 0 } ?? false
                }
                guard let tile = self.canvas.tiles[id], tile.isLive else { return false }
                return tile.objectID == id && tile.window === self.window && tile.bounds.width > 0 && tile.content.bounds.height > 0
            }
        }

        func checked(_ point: NSPoint, target: NSView, label: String) throws -> NSPoint {
            let hit = hit(point)
            try require(hit === target || hit?.isDescendant(of: target) == true,
                "\(label) must be genuinely hittable before its native mouse event; \(diagnostic(point))")
            return point
        }

        func point(_ id: ObjectID, title: Bool = false) throws -> NSPoint {
            if let group = canvas.groups[id] {
                try require(group.region.width > 0 && group.region.height > 0 && group.titleRect.width > 0,
                    "group must be laid out before clicking; \(diagnostic()) region=\(group.region)")
                return try checked(group.convert(NSPoint(x: group.titleRect.midX, y: group.titleRect.midY), to: nil),
                    target: group, label: "group \(id)")
            }
            if board.objects[id]?.type == .shape, let rect = canvas.docFrame(id) {
                return try checked(canvas.document.convert(NSPoint(x: rect.minX + 2, y: rect.midY), to: nil),
                    target: canvas.document, label: "shape \(id)")
            }
            guard let tile = canvas.tiles[id], tile.isLive else { throw Failure("click target is not a live tile") }
            let point = title ? tile.convert(NSPoint(x: 120, y: TileFrameView.titleHeight / 2), to: nil)
                : tile.content.convert(NSPoint(x: min(75, tile.content.bounds.width / 2), y: 55 + tile.content.headerHeight), to: nil)
            _ = try checked(point, target: tile, label: "\(id) \(board.objects[id]?.type.rawValue ?? "missing") title=\(title)")
            try require(title ? hit(point) === tile : hit(point)?.isDescendant(of: tile.content) == true,
                "the click must hit the requested \(title ? "title handle" : "native body"), not a card, control or another fixture; \(diagnostic(point))")
            return point
        }

        func read(_ id: ObjectID) -> Data { receipts[id].flatMap { try? Data(contentsOf: $0) } ?? Data() }

        func boardOwns(_ selection: Set<ObjectID>) throws {
            try require(canvas.selection == selection, "selection must be \(selection), got \(canvas.selection); \(diagnostic())")
            try require(window.firstResponder === canvas.document, "board must own keys; \(diagnostic())")
            try require(canvas.focusedTile == nil, "no tile may retain typing during a board-owned gesture; \(diagnostic())")
        }

        func cleanup() async throws {
            board.onEvent = nil
            controller.discard()
            window.delegate = nil
            window.close()
            NSApp.mainMenu = oldMenu
            NSApp.windowsMenu = oldWindowsMenu
            NSApp.helpMenu = oldHelpMenu
            NSApp.delegate = oldDelegate
            var failures: [String] = []
            for object in terminals {
                do {
                    try await TerminalTile.endSession(object, board: board.id)
                    print("CLEANUP ended \(TerminalTile.sessionName(object.id))")
                } catch { failures.append(String(describing: error)) }
            }
            if !failures.isEmpty { throw Failure("owned terminal cleanup failed: \(failures.joined(separator: "; "))") }
        }
    }

    private static func click(_ point: NSPoint, in window: NSWindow) async throws {
        try await post([mouse(.leftMouseDown, point, in: window), mouse(.leftMouseUp, point, in: window)])
    }
    private static func typed(_ text: String, in window: NSWindow) async throws {
        for character in text {
            let text = String(character)
            let code: UInt16 = text == " " ? 49 : 0
            try await post([key(code, text, in: window), key(code, text, type: .keyUp, in: window)])
        }
    }

    // CG-backed AppKit queue events are synthetic, not physical trackpad/HID proof.
    private static func wheel(_ point: NSPoint, dy: Int32, dx: Int32 = 0, phase: Int64 = 0,
                              momentum: Int64 = 0, flags: CGEventFlags = [], in f: Fixture) async throws {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: dy, wheel2: dx, wheel3: 0),
              let phaseField = CGEventField(rawValue: 99),
              let momentumField = CGEventField(rawValue: 123),
              let screen = NSScreen.screens.first else { throw Failure("CG scroll construction failed") }
        cg.location = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
        cg.flags = flags
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(f.window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(f.window.windowNumber))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(phaseField, value: phase)
        cg.setIntegerValueField(momentumField, value: momentum)
        guard let event = NSEvent(cgEvent: cg) else { throw Failure("CG scroll has no NSEvent") }
        event.setValue(f.window, forKey: "_window")
        event.setValue(NSNumber(value: f.window.windowNumber), forKey: "_windowNumber")
        try require(event.window === f.window && event.windowNumber == f.window.windowNumber,
                    "event synthesis prerequisite: CG-backed NSEvent must target the owned CanvasWindow")
        try require(abs(event.locationInWindow.x - point.x) < 1 && abs(event.locationInWindow.y - point.y) < 1,
                    "event synthesis prerequisite: window \(f.window.frame), Quartz \(cg.location), expected \(point), received \(event.locationInWindow)")
        let decodedPhase: UInt = phase == 1 ? NSEvent.Phase.began.rawValue
            : phase == 2 ? NSEvent.Phase.changed.rawValue : phase == 4 ? NSEvent.Phase.ended.rawValue : 0
        let decodedMomentum: UInt = momentum == 1 ? NSEvent.Phase.began.rawValue
            : momentum == 2 ? NSEvent.Phase.changed.rawValue : momentum == 3 ? NSEvent.Phase.ended.rawValue : 0
        try require(event.phase.rawValue == decodedPhase && event.momentumPhase.rawValue == decodedMomentum,
                    "event synthesis prerequisite: CG phases must decode to the requested AppKit phases")
        var observed = false
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { delivered in
            MainActor.assumeIsolated {
                if delivered.window === f.window {
                    observed = true
                    print("SYNTHETIC scroll x=\(delivered.locationInWindow.x) y=\(delivered.locationInWindow.y) dy=\(delivered.scrollingDeltaY) phase=\(delivered.phase.rawValue) momentum=\(delivered.momentumPhase.rawValue)")
                }
            }
            return delivered
        }) else { throw Failure("scroll dispatch monitor unavailable") }
        defer { NSEvent.removeMonitor(monitor) }
        let selection = f.canvas.selection, focus = f.canvas.focusedTile
        let responder = f.window.firstResponder
        try await post([event])
        try require(observed, "AppKit must dispatch the scroll through the target window")
        try await Task.sleep(for: .milliseconds(60))
        try require(f.canvas.selection == selection && f.canvas.focusedTile == focus && f.window.firstResponder === responder,
                    "scroll must preserve selection, typing and exact keyboard responder")
    }

    private static func boardPoint(_ f: Fixture) throws -> NSPoint {
        let visible = f.canvas.document.visibleRect
        for x in [visible.maxX - 30, visible.midX, visible.minX + 30] {
            for y in [visible.minY + 30, visible.midY, visible.maxY - 30] {
                let point = f.canvas.document.convert(NSPoint(x: x, y: y), to: nil)
                if f.hit(point) === f.canvas.document { return point }
            }
        }
        throw Failure("empty-board fixture has no visible document hit: \(f.diagnostic())")
    }
    private static func boardKeys(_ f: Fixture) async throws {
        try await click(try boardPoint(f), in: f.window)
        try f.boardOwns([])
    }
    private static func longNote(_ f: Fixture, x: Double = 30) async throws -> (CanvasObject, NSTextView, NSScrollView) {
        let note = try await f.create(.note, x: x, y: 90, width: 360, height: 290)
        _ = try f.board.update(note.id, props: .object(["markdown": .string((1...120).map { "Paragraph \($0). Native scroll acceptance prose.\n\n" }.joined())]))
        guard let tile = f.canvas.tiles[note.id]?.content as? NoteTile else { throw Failure("missing rendered note") }
        try await wait("rendered native note must expose all seeded prose") {
            descendants(tile).compactMap { $0 as? NSTextView }.contains {
                !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor && $0.string.contains("Paragraph 120.")
                    && $0.bounds.height > ($0.enclosingScrollView?.contentSize.height ?? .greatestFiniteMagnitude) + 1
            }
        }
        guard let text = descendants(tile).compactMap({ $0 as? NSTextView }).first(where: {
            !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor && $0.string.contains("Paragraph 120.")
        }), let scroll = text.enclosingScrollView else { throw Failure("native note scroll missing") }
        return (note, text, scroll)
    }
    private static func notePoint(_ text: NSTextView, _ f: Fixture) throws -> NSPoint {
        guard let tile = text.enclosingScrollView?.superview as? NoteTile else {
            throw Failure("rendered note must retain its native display scroll view")
        }
        return try f.checked(text.convert(NSPoint(x: text.visibleRect.minX + 45, y: text.visibleRect.minY + 45), to: nil),
                             target: tile, label: "rendered note prose")
    }
    private static func scrollbar(_ tile: TerminalTile) -> TerminalScrollbar? {
        // Observation only: pinned Ghostty publishes this geometry through its delegate.
        guard let optional = Mirror(reflecting: tile).children.first(where: { $0.label == "scrollbar" })?.value else { return nil }
        return Mirror(reflecting: optional).children.first?.value as? TerminalScrollbar
    }
    private static func terminal(_ f: Fixture, history: Bool) async throws -> (CanvasObject, TerminalTile) {
        let object = try await f.create(.terminal, width: 450, height: 290)
        guard let tile = f.canvas.tiles[object.id]?.content as? TerminalTile else { throw Failure("missing terminal") }
        try await click(try f.point(object.id), in: f.window)
        try require(f.window.firstResponder === tile.terminal, "native click must give terminal typing before handshake")
        try await typed("!", in: f.window)
        try await wait("live terminal input must reach fixture before output is released") { f.read(object.id) == Data("!".utf8) }
        try Data().write(to: f.root.appendingPathComponent("scroll-output-go"))
        try await wait("live attached Ghostty must display post-handshake output") {
            tile.screenRows().contains { $0.text.contains("LIVE SCROLL READY") }
        }
        try await wait("terminal must report expected active-screen history geometry") {
            scrollbar(tile).map { history ? $0.total > $0.len : $0.total == $0.len } == true
        }
        return (object, tile)
    }
    @MainActor
    private final class DelayedWheelDelegate: NSObject, WKUIDelegate {
        nonisolated(unsafe) let original: NSObject
        var pending: [(WKWebView, NSEvent)] = []
        var holding = true
        static let callback = NSSelectorFromString("_webView:didNotHandleWheelEvent:")

        init(original: NSObject) { self.original = original }

        nonisolated override func responds(to selector: Selector!) -> Bool {
            MainActor.assumeIsolated {
                super.responds(to: selector) || original.responds(to: selector)
            }
        }

        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            MainActor.preconditionIsolated()
            return original.responds(to: selector) ? original : super.forwardingTarget(for: selector)
        }

        @objc(_webView:didNotHandleWheelEvent:)
        func unhandled(_ web: WKWebView, event: NSEvent) {
            if holding { pending.append((web, event)) }
            else { forward(web, event) }
        }

        private func forward(_ web: WKWebView, _ event: NSEvent) {
            guard original.responds(to: Self.callback) else { return }
            typealias Callback = @convention(c) (AnyObject, Selector, WKWebView, NSEvent) -> Void
            let invoke = unsafeBitCast(original.method(for: Self.callback), to: Callback.self)
            invoke(original, Self.callback, web, event)
        }

        func release() {
            holding = false
            let answers = pending
            pending.removeAll()
            for (web, event) in answers { forward(web, event) }
        }
    }


    private static func loseAndRestoreKey(_ f: Fixture) async throws {
        let other = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 120, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        try await wait("focus fixture prerequisite: second real window must take key status") {
            other.isKeyWindow && !f.window.isKeyWindow
        }
        f.window.makeKeyAndOrderFront(nil)
        try await wait("focus fixture prerequisite: owned board window must regain key status") { f.window.isKeyWindow }
    }

    private static func panelScroll(_ panel: NavigationPanel) throws -> NSScrollView {
        guard let scroll = descendants(panel).compactMap({ $0 as? NSScrollView }).first(where: {
            ($0.documentView?.frame.height ?? 0) > $0.contentSize.height + 100
        }) else { throw Failure("panel fixture prerequisite: native panel must expose a scrollable document") }
        return scroll
    }

    private static func nativePanel(_ name: String, _ f: Fixture) async throws {
        let embedded = name.hasPrefix("browser-") || name.hasPrefix("html-")
        let panel: NavigationPanel
        if name == "references-panel-outside-tile" {
            panel = NavigationPanel.filterList(title: "References", rows: (1...100).map {
                NavigationPanel.Row(title: "Reference \($0)", detail: "fixture.swift", action: {})
            })
        } else {
            panel = NavigationPanel.hover((1...100).map { "Documentation paragraph \($0).\n\n" }.joined())
        }
        try await boardKeys(f)
        var pageView: WKWebView?
        if embedded {
            let object = try await f.create(name.hasPrefix("browser-") ? .browser : .html,
                                            width: 660, height: 540)
            guard let content = f.canvas.tiles[object.id]?.content else { throw Failure("missing page tile") }
            try await wait("page fixture prerequisite: embedded panel needs a loaded real WKWebView") {
                pageView = (content as? BrowserTile)?.webView ?? (content as? HtmlTile)?.webView
                guard let pageView else { return false }
                return await js(pageView, "document.readyState === 'complete'") as? Bool == true
            }
            panel.setFrameOrigin(NSPoint(x: 20, y: content.headerHeight + 20))
            content.addSubview(panel, positioned: .above, relativeTo: nil)
        } else {
            panel.show(below: NSPoint(x: 120, y: 100), lineHeight: 20, in: f.canvas.document)
        }
        defer { panel.dismiss() }
        f.window.layoutIfNeeded()
        let scroll = try panelScroll(panel)
        scroll.verticalScrollElasticity = .none
        let origin = scroll.contentView.bounds.origin
        let viewport = f.canvas.viewport
        let point = try f.checked(scroll.convert(NSPoint(x: 40, y: 40), to: nil),
                                  target: scroll, label: "native documentation/reference panel")
        if let pageView {
            try require(f.hit(point) !== pageView && f.hit(point)?.isDescendant(of: pageView) != true,
                        "embedded native panel prerequisite: hit must be outside WKWebView but inside its tile")
        } else {
            try require(panel.superview === f.canvas.document, "outside panel must live directly in real canvas document")
        }
        try await wheel(point, dy: -70, phase: 1, in: f)
        try await wait("panel first directional wheel must visibly scroll native content, not board") {
            scroll.contentView.bounds.origin != origin
        }
        let afterBegin = scroll.contentView.bounds.origin
        try await wheel(try boardPoint(f), dy: -50, phase: 2, in: f)
        try await wheel(try boardPoint(f), dy: 0, phase: 4, in: f)
        try await wheel(try boardPoint(f), dy: -40, momentum: 1, in: f)
        try await wheel(try boardPoint(f), dy: 0, momentum: 3, in: f)
        try require(scroll.contentView.bounds.origin != afterBegin && f.canvas.viewport == viewport,
                    "native panel must retain wheel and momentum outside its bounds without panning board")
        try f.boardOwns([])
        if let pageView {
            let field = await js(pageView, "document.getElementById('field').value") as? String
            try require(field == "", "embedded native scroll must not type into page")
        }
        print("OFFSETS panel=\(origin) -> \(scroll.contentView.bounds.origin) board=\(viewport) -> \(f.canvas.viewport)")
    }

    private static let scenarios: [Scenario] = [
        Scenario(name: "board-crosses-note", baseline: "expected regression failure: board gesture currently enters note"),
        Scenario(name: "content-crosses-note", baseline: "expected regression failure: no retained original content target"),
        Scenario(name: "content-keeps-owner-with-command", baseline: "expected regression failure: Command changes an existing content gesture to board zoom"),
        Scenario(name: "content-edge-momentum-new-gesture", baseline: "expected regression failure: new gesture at content edge is swallowed; no-chain substeps are controls"),
        Scenario(name: "phaseless-250ms-owner", baseline: "expected regression failure: per-event re-hit-test has no 250ms burst lock"),
        Scenario(name: "hover-panel-outside-tile", baseline: "expected regression failure: native panel outside tile pans board"),
        Scenario(name: "references-panel-outside-tile", baseline: "expected regression failure: native references list outside tile pans board"),
        Scenario(name: "browser-native-panel", baseline: "expected regression failure: browser tile steals native non-WebKit panel wheel"),
        Scenario(name: "html-native-panel", baseline: "expected regression failure: HTML tile steals native non-WebKit panel wheel"),
        Scenario(name: "focus-loss-content-owner", baseline: "expected regression failure: crossed content owner not retained; focus preservation is an unchanged control"),
        Scenario(name: "focus-loss-cancels-space-only", baseline: "new Space cancellation regression; baseline has no Space pan, not a fail-before claim"),
        Scenario(name: "focus-loss-pending-page-answer", baseline: "expected regression failure: fitting page swallows wheel; delayed real delegate delivery, not natural RTT"),
        Scenario(name: "terminal-history-unfocused", baseline: "existing-pass control (#100), NOT a fail-before claim"),
        Scenario(name: "non-scrolling-image", baseline: "existing-pass control, NOT a fail-before claim"),
        Scenario(name: "space-board-over-tile", baseline: "expected regression failure: Space-drag is not implemented"),
        Scenario(name: "space-typing-once", baseline: "existing-pass control, NOT a fail-before claim"),
        Scenario(name: "space-click-replays", baseline: "new Space-pan click replay regression; baseline ordinary click is the control"),
        Scenario(name: "terminal-horizontal-unfocused", baseline: "safety control: horizontal wheel must never send non-typing program bytes"),
        Scenario(name: "terminal-empty-unfocused", baseline: "expected regression failure: unfocused no-history vertical scroll swallowed"),
        Scenario(name: "terminal-alternate-typing", baseline: "existing-pass control: native alternate-scroll arrows preserved")
    ]

    private static func run(_ name: String, _ f: Fixture) async throws {
        if name == "hover-panel-outside-tile" || name == "references-panel-outside-tile"
            || name == "browser-native-panel" || name == "html-native-panel" {
            try await nativePanel(name, f)
        } else if name == "focus-loss-pending-page-answer" {
            let object = try await f.create(.html, width: 540, height: 420)
            guard let tile = f.canvas.tiles[object.id]?.content as? HtmlTile else { throw Failure("missing HTML fixture") }
            try await wait("page fixture prerequisite: fitting page must finish loading") {
                guard let web = tile.webView else { return false }
                return await js(web, "document.readyState === 'complete' && document.documentElement.scrollHeight <= innerHeight") as? Bool == true
            }
            guard let web = tile.webView, let original = web.uiDelegate as? NSObject else {
                throw Failure("pending-page fixture prerequisite: real page must have an NSObject UI delegate")
            }
            let proxy = DelayedWheelDelegate(original: original)
            web.uiDelegate = proxy
            defer { web.uiDelegate = original as? any WKUIDelegate }
            try await boardKeys(f)
            let point = try f.checked(web.convert(NSPoint(x: 250, y: 150), to: nil), target: web, label: "fitting WK page")
            let viewport = f.canvas.viewport
            let pageOffset = await js(web, "scrollY") as? Double
            try require(pageOffset != nil, "page offset observation prerequisite: scrollY must be readable")
            try await wheel(point, dy: -45, phase: 1, in: f)
            try await wait("pending-page fixture prerequisite: WebKit must issue a real unhandled first-wheel callback") {
                !proxy.pending.isEmpty
            }
            try require(f.canvas.viewport == viewport, "board must wait while genuine page answer is withheld")
            try await wheel(try boardPoint(f), dy: -35, phase: 2, in: f)
            try require(f.canvas.viewport == viewport, "pending page must accumulate movement without early board pan")
            try await loseAndRestoreKey(f)
            try f.boardOwns([])
            print("DELAYED-DELEGATE callbacks=\(proxy.pending.count) originalSupportsReply=\(original.responds(to: DelayedWheelDelegate.callback))")
            proxy.release()
            try await wait("delayed real page answer must hand accumulated movement to board after key loss") { f.canvas.viewport != viewport }
            let handedOff = f.canvas.viewport
            try require(abs(handedOff.rect.y - viewport.rect.y - 80 / viewport.zoom) < 2
                        && abs(handedOff.rect.x - viewport.rect.x) < 2,
                        "page answer must replay both pending vertical deltas exactly once without horizontal movement")
            try await wheel(point, dy: -30, phase: 2, in: f)
            try await wheel(point, dy: 0, phase: 4, in: f)
            try await wheel(point, dy: -25, momentum: 1, in: f)
            try await wheel(point, dy: 0, momentum: 3, in: f)
            let afterPageOffset = await js(web, "scrollY") as? Double
            let field = await js(web, "document.getElementById('field').value") as? String
            try require(f.canvas.viewport != handedOff && afterPageOffset == pageOffset && field == "",
                        "asynchronous board owner must retain changed/momentum with unchanged fitting-page offset and text")
            try f.boardOwns([])
            print("OFFSETS page=\(String(describing: pageOffset)) -> \(String(describing: afterPageOffset)) board=\(viewport) -> \(handedOff) -> \(f.canvas.viewport)")
        } else if name == "focus-loss-content-owner" {
            let (_, text, scroll) = try await longNote(f)
            try await boardKeys(f)
            let viewport = f.canvas.viewport
            let origin = scroll.contentView.bounds.origin
            try await wheel(try notePoint(text, f), dy: -60, phase: 1, in: f)
            try await wait("content must visibly own first wheel before focus loss") { scroll.contentView.bounds.origin != origin }
            let afterBegin = scroll.contentView.bounds.origin
            try await loseAndRestoreKey(f)
            try f.boardOwns([])
            try await wheel(try boardPoint(f), dy: -60, phase: 2, in: f)
            try await wheel(try boardPoint(f), dy: 0, phase: 4, in: f)
            try await wheel(try boardPoint(f), dy: -50, momentum: 1, in: f)
            try await wheel(try boardPoint(f), dy: 0, momentum: 3, in: f)
            try require(scroll.contentView.bounds.origin.y > afterBegin.y && f.canvas.viewport == viewport,
                        "real key loss must retain content owner through continuation and momentum")
            try f.boardOwns([])
            print("OFFSETS note=\(origin) -> \(scroll.contentView.bounds.origin) board=\(viewport) -> \(f.canvas.viewport)")
        } else if name == "focus-loss-cancels-space-only" {
            let image = try await f.create(.image)
            try await boardKeys(f)
            let point = try f.point(image.id)
            let frame = f.board.objects[image.id]?.frame
            let before = f.canvas.viewport
            try await post([key(49, " ", in: f.window), mouse(.leftMouseDown, point, in: f.window),
                            mouse(.leftMouseDragged, NSPoint(x: point.x + 45, y: point.y + 30), in: f.window)])
            try require(f.canvas.viewport != before, "real Space drag must pan before losing key; baseline lacks Space pan, not a focus-loss fail-before claim")
            try await loseAndRestoreKey(f)
            let cancelled = f.canvas.viewport
            try await post([mouse(.leftMouseDragged, NSPoint(x: point.x + 100, y: point.y + 70), in: f.window),
                            mouse(.leftMouseUp, NSPoint(x: point.x + 100, y: point.y + 70), in: f.window),
                            key(49, " ", type: .keyUp, in: f.window)])
            try require(f.canvas.viewport == cancelled && f.board.objects[image.id]?.frame == frame,
                        "focus loss must cancel Space pan and discard its remaining drag without moving tile")
            try f.boardOwns([])
            print("OFFSETS board=\(before) -> \(cancelled) -> \(f.canvas.viewport)")
        } else if name == "board-crosses-note" || name == "content-crosses-note" || name == "phaseless-250ms-owner" {
            let (_, first, firstScroll) = try await longNote(f)
            let (_, second, secondScroll) = try await longNote(f, x: 480)
            try await boardKeys(f)
            let firstOrigin = firstScroll.contentView.bounds.origin
            let secondOrigin = secondScroll.contentView.bounds.origin
            if name == "content-crosses-note" {
                let viewport = f.canvas.viewport
                try await wheel(try notePoint(first, f), dy: -80, phase: 1, in: f)
                try await wait("first content event must visibly scroll original note") { firstScroll.contentView.bounds.origin != firstOrigin }
                let afterBegin = firstScroll.contentView.bounds.origin
                try await wheel(try notePoint(second, f), dy: -80, phase: 2, in: f)
                try await wheel(try boardPoint(f), dy: -80, phase: 4, in: f)
                try await wheel(try notePoint(second, f), dy: -80, momentum: 1, in: f)
                try await wheel(try boardPoint(f), dy: -80, momentum: 2, in: f)
                try await wheel(try boardPoint(f), dy: 0, momentum: 3, in: f)
                try require(firstScroll.contentView.bounds.origin.y > afterBegin.y, "original note must keep scrolling after pointer leaves")
                try require(secondScroll.contentView.bounds.origin == secondOrigin && f.canvas.viewport == viewport,
                            "content owner must retain all events through crossing and momentum")
            } else {
                let phased = name == "board-crosses-note"
                try await wheel(try boardPoint(f), dy: -35, phase: phased ? 1 : 0, in: f)
                let afterBegin = f.canvas.viewport
                try await wheel(try notePoint(first, f), dy: -45, phase: phased ? 2 : 0, in: f)
                try await wheel(try notePoint(second, f), dy: -45, phase: phased ? 2 : 0, in: f)
                try require(f.canvas.viewport != afterBegin, "retained board owner must keep panning across tiles")
                try require(firstScroll.contentView.bounds.origin == firstOrigin && secondScroll.contentView.bounds.origin == secondOrigin,
                            "crossed notes must not consume board-owned gesture")
                if phased {
                    try await wheel(try notePoint(first, f), dy: 0, phase: 4, in: f)
                    let beforeMomentum = f.canvas.viewport
                    try await wheel(try notePoint(first, f), dy: -30, momentum: 1, in: f)
                    try await wheel(try notePoint(second, f), dy: -30, momentum: 2, in: f)
                    try await wheel(try boardPoint(f), dy: 0, momentum: 3, in: f)
                    try require(f.canvas.viewport != beforeMomentum && firstScroll.contentView.bounds.origin == firstOrigin
                                && secondScroll.contentView.bounds.origin == secondOrigin, "board must also retain momentum over content")
                } else {
                    try await Task.sleep(for: .milliseconds(320))
                    let viewport = f.canvas.viewport
                    try await wheel(try notePoint(first, f), dy: -80, in: f)
                    try await wait("new wheel burst after 250ms must scroll note") { firstScroll.contentView.bounds.origin != firstOrigin }
                    try require(f.canvas.viewport == viewport, "expired burst must choose content instead of board")
                }
            }
        } else if name == "content-keeps-owner-with-command" {
            let (_, text, scroll) = try await longNote(f)
            try await boardKeys(f)
            let viewport = f.canvas.viewport
            let origin = scroll.contentView.bounds.origin
            try await wheel(try notePoint(text, f), dy: -80, phase: 1, in: f)
            try await wait("first event must scroll note") { scroll.contentView.bounds.origin != origin }
            try await wheel(try boardPoint(f), dy: -90, phase: 2, flags: .maskCommand, in: f)
            try await wheel(try boardPoint(f), dy: 0, phase: 4, in: f)
            try require(f.canvas.viewport == viewport, "Command cannot change an existing content owner to board zoom")
        } else if name == "content-edge-momentum-new-gesture" {
            let (_, text, _) = try await longNote(f)
            try await boardKeys(f)
            let viewport = f.canvas.viewport
            try await wheel(try notePoint(text, f), dy: -30000, phase: 1, in: f)
            try await wait("native note must visibly reach bottom") { text.visibleRect.maxY >= text.bounds.maxY - 2 }
            try await wheel(try boardPoint(f), dy: -90, phase: 2, in: f)
            try await wheel(try boardPoint(f), dy: 0, phase: 4, in: f)
            try await wheel(try boardPoint(f), dy: -90, momentum: 1, in: f)
            try await wheel(try boardPoint(f), dy: -90, momentum: 2, in: f)
            try await wheel(try boardPoint(f), dy: 0, momentum: 3, in: f)
            try require(f.canvas.viewport == viewport,
                        "edge must never chain existing content gesture or momentum to board")
            try await wheel(try notePoint(text, f), dy: -90, phase: 1, in: f)
            try await wheel(try notePoint(text, f), dy: 0, phase: 4, in: f)
            try require(f.canvas.viewport != viewport, "new downward gesture at content bottom must pan board")
        } else if name == "non-scrolling-image" || name == "space-board-over-tile" {
            let image = try await f.create(.image)
            try await boardKeys(f)
            let point = try f.point(image.id)
            let viewport = f.canvas.viewport
            let frame = f.board.objects[image.id]?.frame
            if name == "space-board-over-tile" {
                try await post([key(49, " ", in: f.window)])
                try await drag(point, NSPoint(x: point.x + 75, y: point.y + 45), in: f.window)
                try await post([key(49, " ", type: .keyUp, in: f.window)])
                try f.boardOwns([])
            } else { try await wheel(point, dy: -90, in: f) }
            try require(f.canvas.viewport != viewport, "non-scrolling tile / board-key Space-drag must pan board")
            try require(f.board.objects[image.id]?.frame == frame, "pan must not move the tile")
        } else if name == "space-typing-once" {
            let note = try await f.create(.note)
            try await click(try f.point(note.id), in: f.window)
            guard let editor = f.window.firstResponder as? NSTextView, editor.isEditable else { throw Failure("native click must start note typing") }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            let text = editor.string, viewport = f.canvas.viewport
            try await post([key(49, " ", in: f.window), key(49, " ", type: .keyUp, in: f.window)])
            try await Task.sleep(for: .milliseconds(320))
            try require(editor.string == text + " ", "typing Space must insert exactly once, without delayed resend")
            try require(f.canvas.viewport == viewport && f.window.firstResponder === editor, "typing Space must not pan or transfer keys")
        } else if name == "space-click-replays" {
            let note = try await f.create(.note)
            try await boardKeys(f)
            let point = try f.point(note.id)
            let viewport = f.canvas.viewport
            let frame = f.board.objects[note.id]?.frame
            try await post([key(49, " ", in: f.window)])
            try await click(point, in: f.window)
            try await post([key(49, " ", type: .keyUp, in: f.window)])
            guard let editor = f.window.firstResponder as? NSTextView, editor.isEditable else {
                throw Failure("non-drag Space click must replay native note click and enter typing")
            }
            try require(f.canvas.viewport == viewport && f.board.objects[note.id]?.frame == frame,
                        "non-drag Space click must neither pan nor move its tile")
            let before = editor.string
            try await typed("x", in: f.window)
            try require(editor.string.count == before.count + 1 && editor.string.contains("x"),
                        "replayed click must leave normal native typing available without inserting Space")
        } else {
            let history = name == "terminal-history-unfocused"
            let (object, tile) = try await terminal(f, history: history)
            if name != "terminal-alternate-typing" { try await boardKeys(f) }
            let point = try f.point(object.id)
            try require(f.hit(point)?.isDescendant(of: tile.terminal) == true, "wheel target must hit actual Ghostty body")
            let viewport = f.canvas.viewport, before = f.read(object.id)
            let screen = tile.screenRows().map(\.text)
            let geometry = scrollbar(tile)
            print("TERMINAL geometry=\(String(describing: geometry)) screen=\(screen)")
            try await wheel(point, dy: name == "terminal-horizontal-unfocused" ? 0 : (history ? 120 : -40),
                            dx: name == "terminal-horizontal-unfocused" ? -80 : 0, in: f)
            if name == "terminal-horizontal-unfocused" {
                try require(f.read(object.id) == before && tile.screenRows().map(\.text) == screen,
                            "non-typing horizontal terminal wheel must not send program bytes or scroll vertical history")
                try require(f.canvas.viewport != viewport, "non-typing horizontal terminal wheel must pan board")
            } else if history {
                try await wait("unfocused history must visibly scroll older terminal text") { tile.screenRows().map(\.text) != screen }
                try require(f.canvas.viewport == viewport && f.read(object.id) == before, "unfocused history must neither pan nor send program input")
            } else if name == "terminal-empty-unfocused" {
                try require(f.canvas.viewport != viewport && f.read(object.id) == before, "non-typing no-history terminal must pan without program input")
            } else {
                try await wait("typing alternate screen must deliver native Down-arrow bytes") { f.read(object.id).count > before.count }
                let bytes = f.read(object.id).dropFirst(before.count)
                let arrow = Array(Data([0x1b, 0x5b, 0x42]))
                try require(bytes.count % 3 == 0 && stride(from: 0, to: bytes.count, by: 3).allSatisfy {
                    Array(bytes.dropFirst($0).prefix(3)) == arrow
                }, "alternate-scroll receipt must contain only one or more native Down arrows")
                try require(f.canvas.viewport == viewport, "typing alternate-screen program gesture must not pan board")
                print("PROGRAM RECEIPT \(bytes.map { String(format: "%02x", $0) }.joined())")
            }
        }
    }

    static func main() async {
        if CommandLine.arguments.dropFirst().first == "--list" {
            do {
                FileHandle.standardOutput.write(try JSONEncoder().encode(scenarios))
                FileHandle.standardOutput.write(Data("\n".utf8))
                return
            } catch { fatalError("cannot encode scenario registry: \(error)") }
        }
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"],
              let name = CommandLine.arguments.dropFirst().first,
              scenarios.contains(where: { $0.name == name }) else {
            FileHandle.standardError.write(Data("FAIL runner must provide isolated EASL_HOME and a registered scenario\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        var fixture: Fixture?
        var failure: Error?
        do {
            let f = try await Fixture(home: URL(fileURLWithPath: home), changes: false)
            fixture = f
            try await run(name, f)
        } catch { failure = error }
        if let fixture {
            if failure != nil { print("FAILURE STATE \(fixture.diagnostic())") }
            do { try await fixture.cleanup() }
            catch {
                FileHandle.standardError.write(Data("FAIL cleanup: \(error)\n".utf8))
                if failure == nil { failure = error }
            }
        }
        if let failure {
            FileHandle.standardError.write(Data("FAIL \(name): \(failure)\n".utf8))
            exit(1)
        }
        print("PASS \(name)")
    }
}

@MainActor
@_cdecl("SelectionTypingMain")
func selectionTypingMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    let app = CanvasApplication.shared
    Task { @MainActor in
        await SelectionTyping.main()
        Darwin.exit(0)
    }
    app.run()
    return 0
}
