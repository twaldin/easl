import AppKit
import WebKit
import Darwin

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

    private static let typingTypes: [ObjectType] = [.terminal, .note, .html, .browser, .code, .changes, .question]
    private static let boardTypes: [ObjectType] = [.image, .video, .diagram, .group, .shape]
    private static var scenarios: [Scenario] {
        var cases: [Scenario] = []
        for type in typingTypes + boardTypes {
            cases.append(Scenario(name: "click-\(type.rawValue)", baseline:
                type == .note || type == .html || boardTypes.contains(type) ? "feature regression" : "existing behavior control"))
        }
        for type in typingTypes {
            cases.append(Scenario(name: "title-\(type.rawValue)", baseline:
                type == .terminal ? "existing behavior control" : "feature regression"))
            cases.append(Scenario(name: "reentry-\(type.rawValue)", baseline:
                type == .terminal ? "existing behavior control" : "feature regression"))
            cases.append(Scenario(name: "cmd-escape-\(type.rawValue)", baseline: "existing behavior control"))
        }
        for type in typingTypes + [.image, .diagram] {
            cases.append(Scenario(name: "shift-body-\(type.rawValue)", baseline: "feature regression"))
            cases.append(Scenario(name: "shift-body-\(type.rawValue)-single", baseline: "feature regression"))
        }
        for name in ["marquee-one", "marquee-multi", "shift-title-multi", "shift-title-single", "group-selection", "move-terminal"] {
            cases.append(Scenario(name: name, baseline: "feature regression"))
        }
        for owner in ["terminal", "note", "html"] {
            for route in ["set-selection", "same-selection", "open-url", "go-to-shown", "question-link", "html-go-to", "leave-selected"] {
                cases.append(Scenario(name: "preserve-\(owner)-\(route)", baseline:
                    route == "leave-selected" ? "feature regression" :
                        owner == "terminal" || route == "same-selection" ? "existing behavior control" : "feature regression"))
            }
        }
        cases.append(Scenario(name: "terminal-literal-escape", baseline: "existing behavior control"))
        cases.append(Scenario(name: "note-click-caret", baseline: "feature regression"))
        cases.append(Scenario(name: "note-styled-click-caret", baseline: "feature regression"))
        cases.append(Scenario(name: "note-wrapped-click-caret", baseline: "feature regression"))
        cases.append(Scenario(name: "note-rule-click-caret", baseline: "feature regression"))
        cases.append(Scenario(name: "note-whitespace-click-caret", baseline: "feature regression"))
        cases.append(Scenario(name: "html-immediate-key", baseline: "feature regression"))
        cases.append(Scenario(name: "html-immediate-field-key", baseline: "feature regression"))
        cases.append(Scenario(name: "html-click-go-to", baseline: "feature regression"))
        cases.append(Scenario(name: "html-replacement-title", baseline: "feature regression"))
        cases.append(Scenario(name: "html-loading-entry", baseline: "feature regression"))
        cases.append(Scenario(name: "board-undo-redo", baseline: "existing behavior control"))
        cases.append(Scenario(name: "html-page-reload-entry", baseline: "feature regression"))
        cases.append(Scenario(name: "html-panel-replacement", baseline: "feature regression"))
        cases.append(Scenario(name: "keyboard-neighbor-note", baseline: "feature regression"))
        cases.append(Scenario(name: "keyboard-tab-note", baseline: "feature regression"))
        cases.append(Scenario(name: "html-undo-redo", baseline: "existing behavior control"))
        cases.append(Scenario(name: "browser-undo-redo", baseline: "existing behavior control"))
        cases.append(Scenario(name: "question-held-return", baseline: "feature regression"))
        for name in ["shift-note-text", "shift-html-text", "offscreen-go-note", "heading-go-note",
                     "note-command-backspace", "history-back-note", "html-panel-return"] {
            cases.append(Scenario(name: name, baseline:
                name == "html-panel-return" ? "existing bug regression" : "feature regression"))
        }
        for name in ["overview-card-click", "overview-card-drag", "title-drag-unselected", "resize-unselected",
                     "note-scrollbar", "note-scroll", "board-scroll", "note-navigation-caret"] {
            cases.append(Scenario(name: name, baseline: "feature regression"))
        }
        for name in ["move-body-image", "move-body-diagram", "overview-card-wobble", "overview-card-roundtrip",
                     "question-confidence", "browser-empty-undo", "html-empty-undo"] {
            cases.append(Scenario(name: name, baseline: "feature regression"))
        }
        cases.append(Scenario(name: "question-confidence-from-note", baseline: "existing behavior control"))
        for name in ["code-programmatic-delete", "code-programmatic-return", "code-programmatic-tab",
                     "note-first-drag-forward", "note-first-drag-reverse", "note-blank-body-caret",
                     "move-body-terminal-double-click"] {
            cases.append(Scenario(name: name, baseline: "feature regression"))
        }
        cases.append(Scenario(name: "note-panel-return", baseline: "existing bug regression"))
        for name in ["browser-interleaved-undo", "html-interleaved-undo"] {
            cases.append(Scenario(name: name, baseline: "existing bug regression"))
        }
        return cases
    }

    private final class ReloadEntryObserver: NSObject, WKNavigationDelegate {
        weak var tile: HtmlTile?
        var onStart: (() -> Void)?
        var committed = false

        init(tile: HtmlTile) { self.tile = tile }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let tile else { return .cancel }
            return await tile.webView(webView, decidePolicyFor: action)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            let delegate: (any WKNavigationDelegate)? = tile
            delegate?.webView?(webView, didStartProvisionalNavigation: navigation)
            onStart?()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            tile?.webView(webView, didCommit: navigation)
            committed = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            tile?.webView(webView, didFinish: navigation)
        }
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
                      } else if events.contains(where: {
                          $0.type == event.type && $0.windowNumber == event.windowNumber && $0.timestamp == event.timestamp
                      }) {
                          print("NATIVE batch=\(batch) type=\(event.type.rawValue) flags=\(event.modifierFlags.rawValue) point=\(event.locationInWindow)")
                      }
                  }
                  return event
              }) else { throw Failure("native event queue marker could not be installed") }
        defer { NSEvent.removeMonitor(monitor) }
        for event in events { NSApp.postEvent(event, atStart: false) }
        NSApp.postEvent(marker, atStart: false)
        try await wait("AppKit did not dispatch native event batch \(batch)") { delivered }
        await MainTurns.next()
        print("QUEUED batch=\(batch) events=\(events.map { $0.type.rawValue })")
        fflush(nil)
    }

    private static func click(_ point: NSPoint, flags: NSEvent.ModifierFlags = [], clickCount: Int = 1, in window: NSWindow) async throws {
        let down = mouse(.leftMouseDown, point, flags: flags, clickCount: clickCount, in: window)
        let up = mouse(.leftMouseUp, point, flags: flags, clickCount: clickCount, in: window)
        if flags.contains(.shift) {
            try await post([key(56, "", type: .flagsChanged, flags: flags, in: window), down, up,
                key(56, "", type: .flagsChanged, in: window)])
        } else {
            try await post([down, up])
        }
    }

    private static func typed(_ text: String, in window: NSWindow) async throws {
        for character in text {
            let text = String(character)
            let code: UInt16 = text == "\r" ? 36 : text == "\t" ? 48 : 0
            try await post([key(code, text, in: window)])
        }
    }

    private static func drag(_ start: NSPoint, _ end: NSPoint, in window: NSWindow) async throws {
        try await post([mouse(.leftMouseDown, start, in: window)])
        var events: [NSEvent] = []
        for step in 1...8 {
            let fraction = CGFloat(step) / 8
            events.append(mouse(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction), in: window))
        }
        events.append(mouse(.leftMouseUp, end, in: window))
        try await post(events)
    }

    private static func scroll(_ point: NSPoint, in window: NSWindow) async throws {
        guard let content = window.contentView else { throw Failure("native scroll window has no content") }
        let local = content.convert(point, from: nil)
        DevInput.replay(["pid": String(getpid()), "kind": "scroll", "window": String(window.windowNumber),
            "x": "\(local.x)", "y": "\(content.bounds.height - local.y)", "dx": "0", "dy": "-160"])
        try await post([])
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
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw Failure("git fixture setup failed") }
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
            print("DISPATCH active=\(NSApp.isActive) key=\(window.isKeyWindow) delegate=\(String(describing: NSApp.delegate)) responder=\(String(describing: window.firstResponder))")
            fflush(nil)
        }

        func create(_ type: ObjectType, x: Double = 30, y: Double = 45, width: Double = 450, height: Double = 290) async throws -> CanvasObject {
            var props: JSONValue
            switch type {
            case .terminal:
                guard AppPaths.zmx != nil else { throw Failure("fixture prerequisite: zmx is required for real terminal readback and owned-session cleanup") }
                let receipt = root.appendingPathComponent("input-\(terminals.count).bin")
                let ready = receipt.appendingPathExtension("ready")
                let script = "stty -echo -icanon min 1 time 0; : > " + ShellWords.quote([ready.path])
                    + "; exec /bin/cat >> " + ShellWords.quote([receipt.path])
                props = .object(["command": .array(["/bin/sh", "-c", .string(script)])])
            case .note: props = .object(["markdown": "First paragraph.\n\nSecond paragraph.\n"])
            case .html: props = .object(["html": .string(page)])
            case .browser: props = .object(["url": .string(root.appendingPathComponent("page.html").absoluteString)])
            case .code: props = .object(["path": "fixture.swift"])
            case .changes: props = .object(["diffBase": "HEAD"])
            case .question:
                props = try board.questionToCreate(.object(["question": "Which option?", "asker": .object(["name": "Selection test"]),
                    "options": .array([.object(["id": "one", "label": "One"]), .object(["id": "two", "label": "Two"])])]), caller: nil)
            case .image:
                let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                for y in 0..<8 { for x in 0..<8 { image.setColor(.systemBlue, atX: x, y: y) } }
                try image.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("image.png"))
                props = .object(["path": "image.png"])
            case .video:
                guard let resources = AppPaths.resources else { throw Failure("video fixture needs recorded EASL_RESOURCES") }
                props = .object(["path": .string(resources.appendingPathComponent("Tests/VideoPlayback/Fixtures/h264-aac.mp4").path),
                    "muted": true, "autoplay": false])
            case .diagram:
                props = .object(["kind": "graph", "knowledge": .object(["nodes": .array([.object(["id": "one", "label": "One node"])]), "edges": []])])
            case .group:
                let member = try await create(.note, x: x + 35, y: y + 60, width: width - 70, height: height - 100)
                props = .object(["title": "Selection group", "members": .array([.string(member.id)])])
            case .shape: props = .object(["kind": "rect"])
            default: throw Failure("unsupported fixture type \(type.rawValue)")
            }
            let object = board.create(type: type, props: props, frame: Frame(x: x, y: y, w: width, h: height))
            try require(board.objects[object.id]?.type == type, "created fixture must retain its real object identity")
            print("OBJECT board=\(board.id) id=\(object.id) type=\(type.rawValue) frame=\(object.frame)")
            fflush(nil)
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
            if type == .html || type == .browser { _ = try await web(object.id) }
            window.layoutIfNeeded()
            window.displayIfNeeded()
            try await ready(object.id)
            return object
        }

        func web(_ id: ObjectID) async throws -> WKWebView {
            try await wait("page did not build and finish loading") {
                guard let page = (self.canvas.tiles[id]?.content as? HtmlTile)?.webView
                    ?? (self.canvas.tiles[id]?.content as? BrowserTile)?.webView else { return false }
                return await js(page, "document.readyState === 'complete' && !!document.getElementById('field')") as? Bool == true
            }
            return ((canvas.tiles[id]?.content as? HtmlTile)?.webView
                ?? (canvas.tiles[id]?.content as? BrowserTile)?.webView)!
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
            print("HIT \(label) frame=\(target.frame) bounds=\(target.bounds) \(diagnostic(point))")
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

        func pagePoint(_ id: ObjectID, selector: String) async throws -> NSPoint {
            let web = try await web(id)
            guard let rect = await js(web, "document.querySelector('\(selector)').getBoundingClientRect().toJSON()") as? [String: Double],
                  let x = rect["x"], let y = rect["y"] else { throw Failure("missing page click target \(selector)") }
            let scale = web.pageZoom * web.magnification
            let point = web.convert(NSPoint(x: CGFloat(x + 10) * scale,
                y: web.isFlipped ? CGFloat(y + 10) * scale : web.bounds.height - CGFloat(y + 10) * scale), to: nil)
            return try checked(point, target: web, label: "\(id) \(selector)")
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

    private static func enter(_ object: CanvasObject, in f: Fixture) async throws {
        f.canvas.setSelection([object.id])
        guard let content = f.canvas.tiles[object.id]?.content else { throw Failure("missing typing owner") }
        try require(content.enterKeyboard(), "fixture owner must accept keyboard")
        try await wait("fixture owner did not receive keyboard") { f.canvas.focusedTile == object.id }
    }

    private static func assertInput(_ object: CanvasObject, in f: Fixture, marker: String = "x") async throws {
        try require(f.canvas.selection == [object.id], "single user selection must select the clicked tile")
        try await wait("single user selection did not give \(object.type.rawValue) typing") { f.canvas.focusedTile == object.id }
        switch object.type {
        case .terminal:
            let before = f.read(object.id)
            try await typed(marker, in: f.window)
            try await wait("native text did not reach the real terminal program") { f.read(object.id) == before + Data(marker.utf8) }
        case .note:
            guard let editor = f.window.firstResponder as? NSTextView, editor.isEditable else { throw Failure("single note click did not open its text editor") }
            let expected = (editor.string as NSString).replacingCharacters(in: editor.selectedRange(), with: marker)
            try await typed(marker, in: f.window)
            try require(editor.string == expected, "native text must replace exactly the clicked note's selected range")
        case .html, .browser:
            let web = try await f.web(object.id)
            try await typed(marker, in: f.window)
            try await wait("native key did not reach the selected page") { await js(web, "document.getElementById('keys').textContent") as? String == marker }
        case .question:
            try await post([key(18, "1", in: f.window), key(36, "\r", in: f.window)])
            try await wait("question number key and Return did not record an answer") { f.board.objects[object.id]?.props["answer"]?["option"]?.string == "one" }
        case .code, .changes:
            let responder = f.window.firstResponder
            try await post([key(125, "\u{f701}", in: f.window)])
            try require(f.canvas.focusedTile == object.id && f.window.firstResponder === responder,
                "navigation key must stay inside the selected \(object.type.rawValue) tile")
            try require(f.board.objects[object.id] != nil, "tile navigation must not act on board selection")
        default: throw Failure("input assertion needs a typing tile")
        }
    }

    private static func exerciseClick(_ action: String, _ type: ObjectType, _ f: Fixture) async throws {
        let object = try await f.create(type)
        f.window.makeFirstResponder(f.canvas.document)
        f.canvas.setSelection([])
        var previous: CanvasObject?
        var previousBytes = Data()
        if boardTypes.contains(type) {
            let terminal = try await f.create(.terminal, x: 560, y: 430, width: 340, height: 220)
            try await enter(terminal, in: f)
            try await typed("ready", in: f.window)
            try await wait("board-type control terminal must demonstrably receive native bytes before clicking") {
                f.read(terminal.id) == Data("ready".utf8)
            }
            previous = terminal
            previousBytes = f.read(terminal.id)
        }
        if action == "reentry" || action == "cmd-escape" {
            try await enter(object, in: f)
            try await post([key(53, "\u{1b}", flags: .command, in: f.window)])
            try await wait("Command-Escape must route through CanvasWindow/controller and return typing to board") {
                f.window.firstResponder === f.canvas.document && f.canvas.selection == [object.id]
            }
            if action == "cmd-escape" { return }
        }
        let point: NSPoint
        if type == .html || type == .browser, action == "click" {
            point = try await f.pagePoint(object.id, selector: "#plain")
        } else { point = try f.point(object.id, title: action != "click") }
        try await click(point, in: f.window)
        if typingTypes.contains(type) {
            try await assertInput(object, in: f)
        } else {
            try f.boardOwns([object.id])
            if let previous {
                try require(f.read(previous.id) == previousBytes, "target click must not emit bytes into the previous terminal")
            }
            let revision = f.board.revision
            try await typed("x", in: f.window)
            try f.boardOwns([object.id])
            if let previous {
                try require(f.read(previous.id) == previousBytes,
                    "clicking \(type.rawValue) must revoke previous terminal typing before subsequent keys")
            }
            try require(f.board.revision == revision, "unhandled typing on a selected \(type.rawValue) must not mutate the board")
            if let previous {
                try await enter(previous, in: f)
                try await typed("guard", in: f.window)
                try await wait("board-type click must emit no terminal bytes before the positive terminal control") {
                    f.read(previous.id) == previousBytes + Data("guard".utf8)
                }
            }
        }
    }

    private static func exerciseGesture(_ scenario: String, _ f: Fixture) async throws {
        let terminal = try await f.create(.terminal, x: 60, y: 90, width: 340, height: 220)
        let other = try await f.create(.note, x: 490, y: 90, width: 340, height: 220)
        try await enter(terminal, in: f)
        let before = f.read(terminal.id)
        switch scenario {
        case "marquee-one", "marquee-multi":
            guard let first = f.canvas.docFrame(terminal.id), let second = f.canvas.docFrame(other.id) else { throw Failure("marquee geometry missing") }
            let rect = (scenario == "marquee-one" ? first : first.union(second)).insetBy(dx: -20, dy: -20)
            try await drag(f.canvas.document.convert(rect.origin, to: nil),
                f.canvas.document.convert(NSPoint(x: rect.maxX, y: rect.maxY), to: nil), in: f.window)
            try f.boardOwns(scenario == "marquee-one" ? [terminal.id] : [terminal.id, other.id])
        case "shift-title-multi", "shift-title-single":
            try await click(try f.point(other.id, title: true), flags: .shift, in: f.window)
            try f.boardOwns([terminal.id, other.id])
            if scenario == "shift-title-single" {
                try await click(try f.point(other.id, title: true), flags: .shift, in: f.window)
                try f.boardOwns([terminal.id])
            }
        case "group-selection":
            let group = f.board.create(type: .group, props: .object(["members": .array([.string(terminal.id), .string(other.id)]), "title": "Group selection"]))
            try await f.ready(group.id)
            try await click(try f.point(group.id), in: f.window)
            try f.boardOwns([group.id])
        case "move-terminal":
            f.controller.moveTool(nil)
            let selection = f.canvas.selection
            let responder = f.window.firstResponder
            let start = try f.point(terminal.id)
            try await drag(start, NSPoint(x: start.x + 30, y: start.y + 20), in: f.window)
            try require(f.canvas.selection == selection && f.window.firstResponder === responder,
                "Move must preserve the exact pre-drag selection and responder")
            try f.boardOwns([terminal.id])
            try require(f.board.objects[terminal.id]?.frame == Frame(x: terminal.frame.x + 30, y: terminal.frame.y - 20,
                w: terminal.frame.w, h: terminal.frame.h), "Move must save the exact document-space delta")
        default: throw Failure("unknown gesture")
        }
        try await typed("x", in: f.window)
        try await enter(terminal, in: f)
        try await typed("guard", in: f.window)
        try await wait("board-owned gesture must emit no shell bytes before a subsequent positive terminal control") {
            f.read(terminal.id) == before + Data("guard".utf8)
        }
    }

    private static func exerciseMoveBodyDoubleClick(_ f: Fixture) async throws {
        let selected = try await f.create(.note, x: 30, y: 90, width: 340, height: 260)
        let terminal = try await f.create(.terminal, x: 470, y: 90, width: 370, height: 290)
        try await enter(terminal, in: f)
        try await typed("ready", in: f.window)
        try await wait("Move double-click terminal control must receive native input") {
            f.read(terminal.id) == Data("ready".utf8)
        }
        f.window.makeFirstResponder(f.canvas.document)
        f.canvas.setSelection([selected.id])
        f.controller.moveTool(nil)
        try f.boardOwns([selected.id])
        let responder = f.window.firstResponder
        let viewport = f.canvas.viewport
        let point = try f.point(terminal.id)
        guard let terminalFrame = f.canvas.tiles[terminal.id]?.frame,
              let selectedFrame = f.canvas.tiles[selected.id]?.frame else { throw Failure("Move click frames missing") }
        for count in [1, 2] {
            try await click(point, clickCount: count, in: f.window)
            try require(f.canvas.selection == [selected.id] && f.window.firstResponder === responder && f.canvas.focusedTile == nil,
                "Move-tool body click \(count) must preserve the prior selection and exact board typing owner")
            try require(f.canvas.viewport.zoom == viewport.zoom && f.canvas.viewport.rect == viewport.rect,
                "neither click of a Move-tool double-click may zoom or pan the viewport")
            try require(f.board.objects[terminal.id]?.frame == terminal.frame && f.board.objects[selected.id]?.frame == selected.frame
                && f.canvas.tiles[terminal.id]?.frame == terminalFrame && f.canvas.tiles[selected.id]?.frame == selectedFrame,
                "a Move-tool double-click without dragging must preserve saved and displayed tile frames")
        }
        try await post([key(9, "v", in: f.window)])
        try f.boardOwns([selected.id])
        f.controller.selectTool(nil)
        try await enter(terminal, in: f)
        try await typed("guard", in: f.window)
        try await wait("V after a Move-tool double-click must not reach the terminal before its positive input control") {
            f.read(terminal.id) == Data("readyguard".utf8)
        }
    }

    private static func exerciseCodeProgrammatic(_ action: String, _ f: Fixture) async throws {
        let code = try await f.create(.code, x: 30, y: 90, width: 380, height: 290)
        let destination = try await f.create(.note, x: 470, y: 90, width: 370, height: 290)
        guard let content = f.canvas.tiles[code.id]?.content,
              let rows = descendants(content).compactMap({ $0 as? CodeRowsView }).first else {
            throw Failure("code navigation fixture has no native rows")
        }
        try await wait("code navigation fixture must load its actual source rows") { (rows.painter?.rows.entryCount ?? 0) >= 80 }
        let point = try f.checked(rows.convert(NSPoint(x: 180, y: rows.bounds.minY + 15), to: nil),
            target: rows, label: "programmatic-selection code rows")
        try await click(point, in: f.window)
        try require(f.window.firstResponder === rows && f.canvas.focusedTile == code.id,
            "native code row click must establish the exact typing owner")
        f.canvas.setSelection([destination.id])
        try require(f.canvas.selection == [destination.id] && f.window.firstResponder === rows && f.canvas.focusedTile == code.id,
            "programmatic destination selection must preserve native code-row typing")
        switch action {
        case "delete":
            for (code, text) in [(UInt16(51), "\u{7f}"), (UInt16(117), "\u{f728}")] {
                try await post([key(code, text, in: f.window)])
                try require(f.board.objects[destination.id] != nil && f.canvas.selection == [destination.id]
                    && f.window.firstResponder === rows && f.canvas.focusedTile != destination.id,
                    "native backward and forward Delete forwarded by read-only code rows must not delete the selected destination")
            }
        case "return":
            try await post([key(36, "\r", in: f.window)])
            try require((f.canvas.tiles[destination.id]?.content as? NoteTile)?.isEditing == false
                && f.window.firstResponder === rows && f.canvas.selection == [destination.id],
                "Return unused by code rows must not enter the programmatically selected note")
        case "tab":
            try await post([key(48, "\t", in: f.window)])
            try require(f.canvas.selection == [destination.id] && f.window.firstResponder === rows,
                "Tab unused by code rows must not cycle the board selection or steal typing")
        default: throw Failure("unknown code forwarding action")
        }
        let before = rows.bounds.minY
        try await post([key(125, "\u{f701}", in: f.window)])
        try require(rows.bounds.minY > before && f.window.firstResponder === rows && f.canvas.focusedTile == code.id
            && f.canvas.selection == [destination.id] && f.board.objects[destination.id] != nil,
            "subsequent native Down must visibly scroll the original code rows without acting on the destination")
    }

    private static func exerciseShiftBody(_ type: ObjectType, single: Bool, _ f: Fixture) async throws {
        let terminal = try await f.create(.terminal, x: 30, y: 90, width: 340, height: 260)
        let target: CanvasObject
        let initial: CanvasObject
        if type == .terminal {
            target = terminal
            initial = try await f.create(.note, x: 470, y: 90, width: 340, height: 260)
        } else {
            target = try await f.create(type, x: 470, y: 90, width: 440, height: 320)
            initial = terminal
        }
        try await enter(terminal, in: f)
        try await typed("ready", in: f.window)
        try await wait("Shift-body terminal control must receive real native bytes") { f.read(terminal.id) == Data("ready".utf8) }
        if type == .terminal { try await enter(initial, in: f) }
        let before = f.read(terminal.id)
        let point: NSPoint
        if type == .html || type == .browser {
            point = try await f.pagePoint(target.id, selector: "#plain")
        } else if type == .question {
            guard let tile = f.canvas.tiles[target.id]?.content as? QuestionTile,
                  let page = descendants(tile).compactMap({ $0 as? QuestionPage }).first else {
                throw Failure("Shift-body question must expose its real native page")
            }
            point = try f.checked(page.convert(NSPoint(x: 20, y: 22), to: nil), target: page, label: "native question page body")
        } else if type == .code {
            try await wait("Shift-body code target must expose loaded native rows") {
                guard let content = f.canvas.tiles[target.id]?.content else { return false }
                return descendants(content).compactMap { $0 as? CodeRowsView }.contains { ($0.painter?.rows.entryCount ?? 0) > 0 }
            }
            guard let content = f.canvas.tiles[target.id]?.content,
                  let rows = descendants(content).compactMap({ $0 as? CodeRowsView }).first else {
                throw Failure("native code rows missing")
            }
            point = try f.checked(rows.convert(NSPoint(x: 180, y: rows.bounds.minY + 15), to: nil),
                target: rows, label: "native loaded code rows")
        } else { point = try f.point(target.id) }
        try await click(point, flags: .shift, in: f.window)
        try f.boardOwns([initial.id, target.id])
        if let note = f.canvas.tiles[target.id]?.content as? NoteTile {
            try require(!note.isEditing, "Shift-body selection must not open a note draft without a caret")
            _ = try f.board.update(target.id, props: .object(["markdown": "Agent update after Shift-selection.\n"]))
            try await wait("a Shift-selected note must display agent updates rather than retain a stale draft") {
                !note.isEditing && descendants(note).compactMap { $0 as? NSTextView }
                    .contains { !$0.isEditable && $0.string.contains("Agent update after Shift-selection.") }
            }
        }
        if type == .html {
            let web = try await f.web(target.id)
            _ = await js(web, "document.getElementById('field').focus(); true")
            try await post([])
            try f.boardOwns([initial.id, target.id])
        }
        if single {
            let secondPoint: NSPoint
            if type == .html || type == .browser {
                secondPoint = try await f.pagePoint(target.id, selector: "#plain")
            } else if type == .question {
                secondPoint = point
            } else { secondPoint = try f.point(target.id) }
            try await click(secondPoint, flags: .shift, in: f.window)
            try f.boardOwns([initial.id])
        }
        try await typed("x", in: f.window)
        try f.boardOwns(single ? [initial.id] : [initial.id, target.id])
        try require(f.read(terminal.id) == before, "Shift-body selection must not emit bytes into a terminal")
        try await enter(terminal, in: f)
        try await typed("guard", in: f.window)
        try await wait("Shift-body keys must leave terminal bytes exactly unchanged before the positive terminal control") {
            f.read(terminal.id) == before + Data("guard".utf8)
        }
    }

    private static func exercisePassiveMove(_ type: ObjectType, _ f: Fixture) async throws {
        let terminal = try await f.create(.terminal, x: 30, y: 90, width: 340, height: 260)
        let object = try await f.create(type, x: 470, y: 90, width: 440, height: 320)
        try await enter(terminal, in: f)
        let selection = f.canvas.selection
        let responder = f.window.firstResponder
        let before = f.read(terminal.id)
        let start = try f.point(object.id)
        let documentStart = f.canvas.document.convert(start, from: nil)
        let end = f.canvas.document.convert(NSPoint(x: documentStart.x + 80, y: documentStart.y + 40), to: nil)
        try await drag(start, end, in: f.window)
        try require(f.canvas.selection == selection && f.window.firstResponder === responder,
            "moving an unselected passive tile by its body must preserve exact selection and typing")
        try require(f.board.objects[object.id]?.frame == Frame(x: object.frame.x + 80, y: object.frame.y + 40,
            w: object.frame.w, h: object.frame.h), "a passive-body drag must commit its exact world-space delta")
        try await typed("x", in: f.window)
        try await wait("the original terminal must still receive keys after a passive-body drag") {
            f.read(terminal.id) == before + Data("x".utf8)
        }
    }

    private static func exerciseQuestionConfidence(_ f: Fixture, fromNote: Bool = false) async throws {
        let terminal = try await f.create(.terminal, x: 30, y: 90, width: 340, height: 260)
        let question = try await f.create(.question, x: 470, y: 90, width: 440, height: 320)
        _ = try f.board.update(question.id, props: .object(["askConfidence": true]))
        guard let tile = f.canvas.tiles[question.id]?.content as? QuestionTile,
              let page = descendants(tile).compactMap({ $0 as? QuestionPage }).first else {
            throw Failure("confidence fixture has no native question page")
        }
        try await wait("question confidence must expose its real native slider") {
            page.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }
                .contains { $0.accessibilityRole() == .slider } == true
        }
        guard let slider = page.accessibilityChildren()?.compactMap({ $0 as? NSAccessibilityElement })
            .first(where: { $0.accessibilityRole() == .slider }) else { throw Failure("confidence slider disappeared") }
        try await enter(terminal, in: f)
        let before = f.read(terminal.id)
        if fromNote {
            try await enter(question, in: f)
            try await post([key(48, "\t", in: f.window)])
            try await wait("confidence control must start with its native note field typing") {
                (f.window.firstResponder as? NSTextView)?.isEditable == true && f.canvas.focusedTile == question.id
            }
            try await typed("Draft", in: f.window)
        }
        let rect = slider.accessibilityFrame()
        let point = f.window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
        _ = try f.checked(point, target: page, label: "question confidence slider")
        try await click(point, in: f.window)
        try require(f.canvas.selection == [question.id] && f.canvas.focusedTile == question.id,
            "a confidence click must select the question and give it typing")
        guard let value = slider.accessibilityValue() as? NSNumber, value.doubleValue < 100 else {
            throw Failure("confidence click must leave room for a native right-arrow step")
        }
        try await post([key(124, "\u{f703}", flags: [.function, .numericPad], in: f.window)])
        try require((slider.accessibilityValue() as? NSNumber)?.doubleValue ?? -1 > value.doubleValue,
            "the next native arrow must adjust confidence, not reach the previous shell")
        try require(f.read(terminal.id) == before, "confidence arrow must not emit terminal bytes")
        try await enter(terminal, in: f)
        try await typed("guard", in: f.window)
        try await wait("confidence input must leave terminal bytes unchanged before its positive control") {
            f.read(terminal.id) == before + Data("guard".utf8)
        }
    }

    private static func exerciseOverview(_ scenario: String, _ f: Fixture) async throws {
        let terminal = try await f.create(.terminal, x: 600, y: 90, width: 340, height: 260)
        let note = try await f.create(.note, x: 30, y: 90, width: 440, height: 320)
        try await enter(terminal, in: f)
        f.canvas.show(Viewport(rect: Frame(x: -100, y: -100, w: 6000, h: 4100), zoom: 0.2))
        try await wait("overview target must actually render as a card before the gesture") {
            f.canvas.tiles[note.id]?.isLive == false && f.canvas.tiles[note.id]?.zoomedOut == true
        }
        guard let tile = f.canvas.tiles[note.id] else { throw Failure("overview note card is missing") }
        let start = try f.checked(tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil),
            target: tile, label: "overview card")
        try require(f.hit(start) === tile, "overview gesture must hit the card's native move handle")
        let zoom = f.canvas.viewport.zoom
        let selection = f.canvas.selection
        let responder = f.window.firstResponder
        let before = f.read(terminal.id)
        if scenario == "overview-card-click" || scenario == "overview-card-wobble" {
            if scenario == "overview-card-wobble" {
                let revision = f.board.revision
                try await drag(start, NSPoint(x: start.x + 1, y: start.y + 1), in: f.window)
                try require(f.board.revision == revision, "sub-threshold wobble must not save a frame edit")
            } else {
                try await click(start, in: f.window)
            }
            try await wait("clicking an overview note card must select it and give it typing") { f.canvas.focusedTile == note.id }
            try require(f.canvas.viewport.zoom == zoom, "a card click must not change overview zoom")
            try require(f.board.objects[note.id]?.frame == note.frame, "a card click must not move or resize the note")
            try await assertInput(note, in: f)
            try require(f.canvas.viewport.zoom == zoom, "typing into the clicked card must retain overview zoom")
            try require(f.read(terminal.id) == before, "card click typing must not reach the previous terminal")
        } else {
            let documentStart = f.canvas.document.convert(start, from: nil)
            let end = f.canvas.document.convert(NSPoint(x: documentStart.x + 200, y: documentStart.y + 100), to: nil)
            if scenario == "overview-card-roundtrip" {
                try await post([mouse(.leftMouseDown, start, in: f.window)])
                try await post([mouse(.leftMouseDragged, end, in: f.window),
                    mouse(.leftMouseDragged, start, in: f.window), mouse(.leftMouseUp, start, in: f.window)])
            } else {
                try await drag(start, end, in: f.window)
            }
            try require(f.canvas.viewport.zoom == zoom, "a card drag must not change overview zoom")
            try require(f.canvas.selection == selection && f.window.firstResponder === responder,
                "an overview card drag must preserve exact selection and responder")
            let dx = scenario == "overview-card-roundtrip" ? 0.0 : 200.0
            let dy = scenario == "overview-card-roundtrip" ? 0.0 : 100.0
            try require(f.board.objects[note.id]?.frame == Frame(x: note.frame.x + dx, y: note.frame.y + dy,
                w: note.frame.w, h: note.frame.h), "an overview drag must save exactly its final world-space frame")
            try await typed("x", in: f.window)
            try await wait("card drag must preserve the old terminal's typing") { f.read(terminal.id) == before + Data("x".utf8) }
        }
    }

    private static func exerciseGeometryGesture(_ scenario: String, _ f: Fixture) async throws {
        let terminal = try await f.create(.terminal, x: 30, y: 90, width: 340, height: 260)
        let note = try await f.create(.note, x: 470, y: 90, width: 440, height: 320)
        try await enter(terminal, in: f)
        let selection = f.canvas.selection
        let responder = f.window.firstResponder
        let before = f.read(terminal.id)
        guard let tile = f.canvas.tiles[note.id] else { throw Failure("geometry target missing") }
        let start: NSPoint
        if scenario == "title-drag-unselected" {
            start = try f.point(note.id, title: true)
        } else {
            start = try f.checked(tile.convert(NSPoint(x: tile.bounds.maxX - 3, y: tile.bounds.maxY - 3), to: nil),
                target: tile, label: "unselected resize grip")
        }
        try require(f.hit(start) === tile, "geometry gesture must hit the actual title or resize grip")
        let end = NSPoint(x: start.x + 40, y: start.y - 30)
        try await drag(start, end, in: f.window)
        let expected = scenario == "title-drag-unselected"
            ? Frame(x: note.frame.x + 40, y: note.frame.y + 30, w: note.frame.w, h: note.frame.h)
            : Frame(x: note.frame.x, y: note.frame.y, w: note.frame.w + 40, h: note.frame.h + 30)
        try require(f.board.objects[note.id]?.frame == expected, "geometry gesture must save its exact move or resize")
        try require(f.canvas.selection == selection && f.window.firstResponder === responder,
            "moving or resizing an unselected tile must not change selection or typing")
        try await typed("x", in: f.window)
        try await wait("geometry gesture must leave keys in the old terminal") { f.read(terminal.id) == before + Data("x".utf8) }
    }

    private static func exerciseNoteScroll(_ scenario: String, _ f: Fixture) async throws {
        let terminal = try await f.create(.terminal, x: 30, y: 90, width: 340, height: 260)
        let note = try await f.create(.note, x: 470, y: 90, width: 440, height: 320)
        let source = (1...120).map { "Paragraph \($0). Scrollable native prose.\n\n" }.joined()
        _ = try f.board.update(note.id, props: .object(["markdown": .string(source)]))
        guard let tile = f.canvas.tiles[note.id]?.content as? NoteTile else { throw Failure("scroll note missing") }
        try await wait("long rendered note must have a native scrollable document") {
            descendants(tile).compactMap { $0 as? NSTextView }.contains {
                !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor && $0.string.contains("Paragraph 120.")
                    && $0.bounds.height > ($0.enclosingScrollView?.contentSize.height ?? .greatestFiniteMagnitude) + 1
            }
        }
        guard let display = descendants(tile).compactMap({ $0 as? NSTextView }).first(where: {
            !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor
        }), let scrollView = display.enclosingScrollView else { throw Failure("rendered note's native scroll view missing") }
        try await enter(terminal, in: f)
        let selection = f.canvas.selection
        let responder = f.window.firstResponder
        let before = f.read(terminal.id)
        let origin = scrollView.contentView.bounds.origin
        if scenario == "note-scrollbar" {
            scrollView.flashScrollers()
            try await wait("the actual rendered note scrollbar knob must be visible and hittable") {
                guard let scroller = scrollView.verticalScroller, !scroller.isHidden, scroller.alphaValue > 0 else { return false }
                let knob = scroller.rect(for: .knob)
                guard knob.width > 0, knob.height > 0 else { return false }
                return f.hit(scroller.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)) === scroller
            }
            guard let scroller = scrollView.verticalScroller else { throw Failure("visible note scrollbar missing") }
            let knob = scroller.rect(for: .knob), slot = scroller.rect(for: .knobSlot)
            let start = try f.checked(scroller.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil),
                target: scroller, label: "rendered note scrollbar knob")
            let targetY = knob.midY < slot.midY ? slot.maxY - knob.height / 2 : slot.minY + knob.height / 2
            let end = scroller.convert(NSPoint(x: knob.midX, y: targetY), to: nil)
            try await post([mouse(.leftMouseDown, start, in: f.window),
                mouse(.leftMouseDragged, end, in: f.window), mouse(.leftMouseUp, end, in: f.window)])
        } else {
            try await scroll(try f.point(note.id), in: f.window)
        }
        try await wait("the native note scroll gesture must actually move the rendered document") { scrollView.contentView.bounds.origin != origin }
        try require(f.canvas.selection == selection && f.window.firstResponder === responder,
            "rendered note scrolling must preserve exact selection and responder")
        try require(!tile.isEditing && f.board.objects[note.id]?.props["markdown"]?.string == source,
            "scrolling a rendered note must never enter raw editing or change its markdown")
        try await typed("x", in: f.window)
        try await wait("note scrolling must keep subsequent typing in the previous terminal") { f.read(terminal.id) == before + Data("x".utf8) }
    }

    private static func exerciseBoardScroll(_ f: Fixture) async throws {
        let terminal = try await f.create(.terminal)
        try await enter(terminal, in: f)
        let selection = f.canvas.selection
        let responder = f.window.firstResponder
        let before = f.read(terminal.id)
        let viewport = f.canvas.viewport
        let clear = f.canvas.clearVisibleRect(of: f.canvas.document)
        let point = try f.checked(f.canvas.document.convert(NSPoint(x: clear.maxX - 40, y: clear.maxY - 40), to: nil),
            target: f.canvas.document, label: "empty board scroll")
        try await scroll(point, in: f.window)
        try await wait("native board scroll must actually pan the viewport") { f.canvas.viewport != viewport }
        try require(f.canvas.selection == selection && f.window.firstResponder === responder,
            "panning the board must preserve exact selection and responder")
        try await typed("x", in: f.window)
        try await wait("board scroll must keep terminal typing") { f.read(terminal.id) == before + Data("x".utf8) }
    }

    private static func requireVisibleCaret(_ editor: NSTextView, in f: Fixture) throws {
        let screenRect = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        let windowRect = f.window.convertFromScreen(screenRect)
        let caret = editor.convert(windowRect, from: nil)
        let clear = editor.visibleRect.intersection(editor.convert(f.canvas.contentView.bounds, from: f.canvas.contentView))
            .insetBy(dx: 4, dy: 4)
        let point = NSPoint(x: windowRect.midX, y: windowRect.midY)
        try require(screenRect.height > 0 && clear.contains(NSPoint(x: caret.midX, y: caret.midY))
            && (f.hit(point) === editor || f.hit(point)?.isDescendant(of: editor) == true),
            "navigation caret must be inside clear, native visible editor area, not merely inside the board; \(f.diagnostic(point)) caret=\(caret) clear=\(clear)")
    }

    private static func exerciseNoteNavigationCaret(_ f: Fixture) async throws {
        let note = try await f.create(.note, width: 1600, height: 2400)
        let source = (1...180).map { "Paragraph \($0). Visible navigation text.\n\n" }.joined()
        _ = try f.board.update(note.id, props: .object(["markdown": .string(source)]))
        try await wait("long navigation note must render before its non-prose entry") {
            guard let content = f.canvas.tiles[note.id]?.content else { return false }
            return descendants(content).compactMap { $0 as? NSTextView }.contains {
                !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor && $0.string.contains("Paragraph 180.")
            }
        }
        f.canvas.go(to: note.id)
        try await wait("user note navigation must open its native editor") {
            f.canvas.focusedTile == note.id && (f.window.firstResponder as? NSTextView)?.isEditable == true
        }
        guard let editor = f.window.firstResponder as? NSTextView else { throw Failure("navigated note editor missing") }
        try require(editor.selectedRange().location < (source as NSString).length,
            "non-prose navigation must not put the caret at the hidden end of a long note")
        try requireVisibleCaret(editor, in: f)
        let expected = (source as NSString).replacingCharacters(in: editor.selectedRange(), with: "HERE")
        try await typed("HERE", in: f.window)
        try require(editor.string == expected, "native typing must insert at the visible navigation caret")
        try requireVisibleCaret(editor, in: f)
    }

    private static func exercisePreservation(_ ownerType: ObjectType, route: String, _ f: Fixture) async throws {
        let owner = try await f.create(ownerType, x: 20, y: 110, width: 370, height: 310)
        let target = try await f.create(.note, x: 470, y: 110, width: 360, height: 220)
        var htmlSource: CanvasObject?
        var questionSource: CanvasObject?
        if route == "html-go-to" {
            htmlSource = try await f.create(.html, x: 450, y: 110, width: 440, height: 310)
            try await click(try await f.pagePoint(htmlSource!.id, selector: "#plain"), in: f.window)
        } else if route == "question-link" {
            let props = try f.board.questionToCreate(.object(["question": "Context navigation", "asker": .object(["name": "Selection test"]),
                "options": [], "context": .array([.object(["object": .string(target.id)])])]), caller: nil)
            questionSource = f.board.create(type: .question, props: props, frame: Frame(x: 450, y: 110, w: 440, h: 360))
        }
        try await enter(owner, in: f)
        if route == "same-selection" {
            f.canvas.setSelection([target.id])
            if f.canvas.focusedTile != owner.id {
                try require(f.canvas.tiles[owner.id]?.content.enterKeyboard() == true, "fixture must restore the old typing owner without changing selection")
                try await wait("previous owner did not regain native keyboard") { f.canvas.focusedTile == owner.id }
            }
        }
        let responder = f.window.firstResponder
        let note = responder as? NSTextView
        let originalNote = note?.string
        let originalBytes = f.read(owner.id)
        switch route {
        case "set-selection", "leave-selected": f.canvas.setSelection([target.id])
        case "same-selection": f.canvas.setSelection([target.id])
        case "go-to-shown": f.canvas.goToShown(target.id)
        case "open-url":
            let url = URL(string: "http://127.0.0.1:9/selection-typing")!
            let existing = f.board.create(type: .browser, props: .object(["url": .string(url.absoluteString)]), frame: Frame(x: 470, y: 110, w: 360, h: 220))
            let router = ApiRouter(registry: f.registry)
            router.showOpenedLink = { [weak canvas = f.canvas] _, opened, source in
                canvas?.showOpenedLink(opened, openedFrom: source)
            }
            var sockets: [Int32] = [-1, -1]
            try require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0, "API fixture needs a real local socket pair")
            defer { for fd in sockets { Darwin.close(fd) } }
            let connection = SocketServer.Connection(fd: sockets[0])
            let reply = await router.handle(.object(["id": "open-url", "method": "view.open_url",
                "params": .object(["board": .string(f.board.id), "url": .string(url.absoluteString)])]), connection: connection)
            try require(reply?["ok"] == .bool(true) && reply?["result"]?["existing"] == .bool(true)
                && reply?["result"]?["object"]?["id"]?.string == existing.id,
                "real view.open_url dispatch must reuse the already-open browser")
            try require(f.canvas.selection == [existing.id], "view.open_url's existing-tile route must update selection")
        case "question-link":
            guard let source = questionSource, let tile = f.canvas.tiles[source.id]?.content as? QuestionTile,
                  let page = descendants(tile).compactMap({ $0 as? QuestionPage }).first,
                  let link = page.accessibilityChildren()?.compactMap({ $0 as? NSAccessibilityElement }).first(where: { $0.accessibilityRole() == .link }) else {
                throw Failure("actual question context link did not expose its native accessibility geometry")
            }
            let rect = link.accessibilityFrame()
            try require(rect.width > 0 && rect.height > 0, "question link must have visible geometry")
            try await click(f.window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY)), in: f.window)
            try await wait("native question context link did not navigate") { f.canvas.selection == [target.id] }
        case "html-go-to":
            guard let source = htmlSource else { throw Failure("missing HTML source") }
            let web = try await f.web(source.id)
            let reply = try await web.callAsyncJavaScript("return await canvasKit.goTo({id})", arguments: ["id": target.id], contentWorld: .page)
            try require((reply as? [String: Any])?["id"] as? String == target.id, "real canvasKit.goTo must resolve destination")
        default: throw Failure("unknown preservation route")
        }
        if route != "open-url" {
            try require(f.canvas.selection == [target.id], "programmatic navigation must update the selection ring")
        }
        try require(f.window.firstResponder === responder && f.canvas.focusedTile == owner.id,
            "\(route) must preserve the user's exact \(ownerType.rawValue) responder \(String(describing: responder)); \(f.diagnostic())")
        if route == "leave-selected" {
            try await post([key(53, "\u{1b}", flags: .command, in: f.window)])
            try await wait("Command-Escape must leave typing while preserving the programmatic selection") {
                f.window.firstResponder === f.canvas.document && f.canvas.selection == [target.id]
            }
            try f.boardOwns([target.id])
            return
        }
        try await typed("x", in: f.window)
        switch ownerType {
        case .terminal:
            try await wait("typing after programmatic navigation left its terminal") { f.read(owner.id) == originalBytes + Data("x".utf8) }
        case .note:
            try require(note?.string != originalNote && note?.string.contains("x") == true, "typing after navigation must edit the previous note")
        case .html:
            let web = try await f.web(owner.id)
            try await wait("typing after navigation left its HTML owner") { await js(web, "document.getElementById('field').value") as? String == "x" }
        default: throw Failure("unsupported previous owner")
        }
    }

    private static func exerciseLiteralEscape(_ f: Fixture) async throws {
        let object = try await f.create(.terminal)
        try await click(try f.point(object.id), in: f.window)
        let before = f.read(object.id)
        try await post([key(53, "\u{1b}", in: f.window)])
        try await wait("plain Escape did not reach the real terminal program as a literal 0x1b byte") {
            f.read(object.id) == before + Data([0x1b])
        }
        try require(f.canvas.focusedTile == object.id && f.canvas.selection == [object.id], "plain Escape must keep terminal typing and selection")
        try await post([key(53, "\u{1b}", flags: .command, in: f.window)])
        try await wait("Command-Escape must leave terminal typing without clearing selection") {
            f.window.firstResponder === f.canvas.document && f.canvas.selection == [object.id]
        }
        try require(f.read(object.id) == before + Data([0x1b]), "Leave Tile must not send a second Escape byte to the terminal")
    }

    private static func exerciseUndo(_ type: ObjectType, _ f: Fixture, interleaved: Bool = false) async throws {
        let object = try await f.create(type, x: interleaved ? 470 : 30)
        let moved = Frame(x: object.frame.x + 30, y: object.frame.y + 20, w: object.frame.w, h: object.frame.h)
        _ = try f.board.update(object.id, frame: moved)
        try require(f.board.history.canUndo, "fixture must have a board move that erroneous CmdZ could undo")
        let web = try await f.web(object.id)
        f.window.makeFirstResponder(f.canvas.document)
        try await click(try await f.pagePoint(object.id, selector: "#field"), in: f.window)
        try await wait("single field click must transfer native typing") { f.canvas.focusedTile == object.id }
        try await typed("typed", in: f.window)
        try await wait("single click must let native keys edit page text") { await js(web, "document.getElementById('field').value") as? String == "typed" }
        var editedNote: CanvasObject?
        var noteEditor: NSTextView?
        if interleaved {
            let note = try await f.create(.note, x: 30, y: 45, width: 370, height: 290)
            try await enter(note, in: f)
            guard let editor = f.window.firstResponder as? NSTextView, editor.isEditable else {
                throw Failure("interleaved page Undo must edit an actual native note")
            }
            try await post([key(0, "a", flags: .command, in: f.window)])
            try await typed("Keep this note", in: f.window)
            try require(editor.string == "Keep this note", "native note typing must prepare a distinct undo history after the page edit")
            try await post([key(36, "\r", flags: .command, in: f.window)])
            try await wait("the interleaved note edit must commit before returning to the page") {
                f.board.objects[note.id]?.props["markdown"]?.string == "Keep this note"
            }
            editedNote = note
            noteEditor = editor
            try await click(try await f.pagePoint(object.id, selector: "#field"), in: f.window)
            try await wait("native page reentry must retain its original edit after the note edit") {
                let value = await js(web, "document.getElementById('field').value") as? String
                return f.canvas.focusedTile == object.id && value == "typed"
            }
        }
        try await post([key(6, "z", flags: .command, in: f.window)])
        try await wait("CmdZ must undo page typing") { await js(web, "document.getElementById('field').value") as? String == "" }
        try require(f.board.objects[object.id]?.frame == moved, "page CmdZ must not undo the board move")
        if let note = editedNote {
            try require(f.board.objects[note.id]?.props["markdown"]?.string == "Keep this note" && noteEditor?.string == "Keep this note",
                "page CmdZ must not undo either the saved note content or its native editor text")
        }
        try await post([key(6, "z", flags: [.command, .shift], in: f.window)])
        try await wait("Shift-CmdZ must redo page typing") { await js(web, "document.getElementById('field').value") as? String == "typed" }
        try require(f.board.objects[object.id]?.frame == moved && f.canvas.focusedTile == object.id,
            "page redo must preserve board position and typing owner")
        if let note = editedNote {
            try require(f.board.objects[note.id]?.props["markdown"]?.string == "Keep this note" && noteEditor?.string == "Keep this note",
                "page redo must restore only page text and leave the interleaved note unchanged")
            try await enter(note, in: f)
            try require((f.window.firstResponder as? NSTextView)?.string == "Keep this note",
                "reopening the note after page undo and redo must show the original committed note edit")
        }
    }

    private static func exerciseEmptyPageUndo(_ type: ObjectType, _ f: Fixture) async throws {
        let note = try await f.create(.note, x: 30, y: 90, width: 340, height: 260)
        let page = try await f.create(type, x: 470, y: 90, width: 440, height: 320)
        try await click(try f.point(note.id), in: f.window)
        try await wait("mixed undo fixture must edit a native note") {
            f.canvas.focusedTile == note.id && (f.window.firstResponder as? NSTextView)?.isEditable == true
        }
        try await post([key(0, "a", flags: .command, in: f.window)])
        try await typed("Committed note", in: f.window)
        try await post([key(36, "\r", flags: .command, in: f.window)])
        try await wait("mixed undo fixture must commit its native note edit") {
            f.board.objects[note.id]?.props["markdown"]?.string == "Committed note"
        }
        let web = try await f.web(page.id)
        try await click(try await f.pagePoint(page.id, selector: "#field"), in: f.window)
        try await wait("an untouched page must own typing before its Undo") { f.canvas.focusedTile == page.id }
        try await post([key(6, "z", flags: .command, in: f.window)])
        let value = await js(web, "document.getElementById('field').value") as? String
        try require(value == "" && f.board.objects[note.id]?.props["markdown"]?.string == "Committed note"
            && f.board.objects[page.id]?.frame == page.frame,
            "Undo in a page with no edits must not undo a committed note or a board object")
        try await typed("p", in: f.window)
        try await wait("empty page Undo must leave subsequent native typing in the page") {
            await js(web, "document.getElementById('field').value") as? String == "p"
        }
        try await click(try f.point(note.id), in: f.window)
        try await wait("the note must reopen with its committed text after the page's empty Undo") {
            (f.window.firstResponder as? NSTextView)?.string == "Committed note" && f.canvas.focusedTile == note.id
        }
    }

    private static func exerciseNoteCaret(_ f: Fixture, styled: Bool = false, wrapped: Bool = false) async throws {
        let object = try await f.create(.note)
        let prefix = wrapped ? "Prelude.\n\n" + String(repeating: "Wrapped words ", count: 12) : ""
        let renderedText = styled ? "First paragraph and second text." : "First paragraph."
        if styled {
            _ = try f.board.update(object.id, props: .object(["markdown": .string(prefix + "First **paragraph** and _second_ text.\n")]))
        }
        guard let tile = f.canvas.tiles[object.id]?.content as? NoteTile else { throw Failure("note tile is missing") }
        try await wait("prose did not render") {
            descendants(tile).compactMap { $0 as? NSTextView }.contains {
                !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor && $0.string.contains(renderedText)
            }
        }
        guard let text = descendants(tile).compactMap({ $0 as? NSTextView }).first(where: {
                  !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor && $0.string.contains(renderedText)
              }), let layout = text.textLayoutManager, let content = layout.textContentManager else {
            throw Failure("rendered prose must expose its native text geometry")
        }
        let word = (text.string as NSString).range(of: styled ? "paragraph" : "paragraph.")
        try require(word.location != NSNotFound, "rendered paragraph must contain the intended click word")
        guard let start = content.location(content.documentRange.location, offsetBy: word.location),
              let end = content.location(start, offsetBy: 1), let range = NSTextRange(location: start, end: end) else {
            throw Failure("intended word has no native text range")
        }
        layout.ensureLayout(for: content.documentRange)
        var point: NSPoint?
        layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, rect, _, _ in
            point = text.convert(NSPoint(x: rect.minX + text.textContainerOrigin.x + min(1, rect.width / 10),
                y: rect.midY + text.textContainerOrigin.y), to: nil)
            return false
        }
        guard let point else { throw Failure("intended prose character did not lay out") }
        f.window.makeFirstResponder(f.canvas.document)
        try await click(point, in: f.window)
        try await wait("one prose click must begin note editing") {
            (f.window.firstResponder as? NSTextView)?.isEditable == true && f.canvas.focusedTile == object.id
        }
        try require(text.textLayoutManager === layout, "a prose click must retain the rendered note's native TextKit 2 layout")
        guard let editor = f.window.firstResponder as? NSTextView else { throw Failure("note has no native editor") }
        let entrySelection = editor.selectedRange()
        try await typed("CLICK", in: f.window)
        let expected = styled ? prefix + "First **CLICKparagraph** and _second_ text.\n" : "First CLICKparagraph.\n\nSecond paragraph.\n"
        try require(editor.string == expected,
            "native click must insert immediately before the clicked word; rendered=\(word.location) entry=\(entrySelection) actual=\(editor.string.debugDescription) expected=\(expected.debugDescription)")
        try await post([key(36, "\r", flags: .command, in: f.window)])
        try await wait("saved markdown must retain the native click's exact insertion position") {
            f.board.objects[object.id]?.props["markdown"]?.string == expected
        }
    }

    private static func exerciseUnmappedNoteCaret(_ f: Fixture, whitespace: Bool) async throws {
        let object = try await f.create(.note)
        let source = whitespace ? " \n \n" : "Before.\n\n---\n\nAfter.\n"
        _ = try f.board.update(object.id, props: .object(["markdown": .string(source)]))
        guard let tile = f.canvas.tiles[object.id]?.content as? NoteTile else { throw Failure("note tile is missing") }
        func target() -> NSTextView? {
            descendants(tile).compactMap { $0 as? NSTextView }.first {
                guard !$0.isEditable, !$0.isHiddenOrHasHiddenAncestor, let storage = $0.textStorage, storage.length > 0 else { return false }
                return whitespace
                    ? storage.attribute(.noteSourcePosition, at: 0, effectiveRange: nil) == nil
                        && storage.attribute(.noteMarkdownLine, at: 0, effectiveRange: nil) == nil
                    : $0.string.contains("Before.") && $0.string.contains(" \n")
            }
        }
        try await wait("the intended non-prose row must render") { target() != nil }
        guard let text = target(), let layout = text.textLayoutManager, let content = layout.textContentManager else {
            throw Failure("rendered row must expose native text geometry")
        }
        let index = whitespace ? 0 : (text.string as NSString).range(of: " \n").location
        guard let start = content.location(content.documentRange.location, offsetBy: index),
              let end = content.location(start, offsetBy: 1), let range = NSTextRange(location: start, end: end) else {
            throw Failure("rendered row has no native character range")
        }
        layout.ensureLayout(for: content.documentRange)
        var point: NSPoint?
        layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, rect, _, _ in
            point = text.convert(NSPoint(x: rect.minX + text.textContainerOrigin.x + min(1, rect.width / 10),
                y: rect.midY + text.textContainerOrigin.y), to: nil)
            return false
        }
        guard let point else { throw Failure("rendered row did not lay out") }
        try await click(try f.checked(point, target: tile, label: "non-prose source caret"), in: f.window)
        try await wait("one rendered-row click must enter editing") {
            (f.window.firstResponder as? NSTextView)?.isEditable == true && f.canvas.focusedTile == object.id
        }
        try await typed("CLICK", in: f.window)
        let expected = whitespace ? source + "CLICK" : "Before.\n\nCLICK---\n\nAfter.\n"
        try require((f.window.firstResponder as? NSTextView)?.string == expected,
            "a rule or whitespace click must preserve its source position; actual=\(String(describing: (f.window.firstResponder as? NSTextView)?.string))")
    }

    private static func exerciseFirstNoteDrag(_ f: Fixture, reversed: Bool) async throws {
        let note = try await f.create(.note)
        guard let tile = f.canvas.tiles[note.id]?.content as? NoteTile else { throw Failure("drag note missing") }
        try await wait("first-drag note must expose rendered prose") {
            descendants(tile).compactMap { $0 as? NSTextView }.contains {
                !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor && $0.string.contains("First paragraph.")
            }
        }
        guard let text = descendants(tile).compactMap({ $0 as? NSTextView }).first(where: {
                  !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor && $0.string.contains("First paragraph.")
              }), let layout = text.textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: reversed ? 15 : 6),
              let end = content.location(start, offsetBy: 1), let range = NSTextRange(location: start, end: end) else {
            throw Failure("first prose drag must have native rendered character geometry")
        }
        layout.ensureLayout(for: content.documentRange)
        var down: NSPoint?
        layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, rect, _, _ in
            down = text.convert(NSPoint(x: rect.minX + text.textContainerOrigin.x + min(1, rect.width / 10),
                y: rect.midY + text.textContainerOrigin.y), to: nil)
            return false
        }
        guard let down else { throw Failure("first prose drag anchor did not lay out") }
        _ = try f.checked(down, target: tile, label: "first prose drag anchor")
        f.window.makeFirstResponder(f.canvas.document)
        f.canvas.setSelection([])
        try await post([mouse(.leftMouseDown, down, in: f.window)])
        guard let editor = f.window.firstResponder as? NSTextView, editor.isEditable else {
            throw Failure("the first single prose press must open the native editor before dragging")
        }
        print("CARET rendered=\(reversed ? 15 : 6) selected=\(editor.selectedRange()) point=\(down)")
        fflush(nil)
        try require(editor.selectedRange() == NSRange(location: reversed ? 15 : 6, length: 0),
            "rendered offset \(reversed ? 15 : 6) must map to the same raw-source caret; actual=\(editor.selectedRange())")
        let rect = editor.firstRect(forCharacterRange: NSRange(location: reversed ? 6 : 15, length: 1), actualRange: nil)
        try require(rect.width > 0 && rect.height > 0, "native drag destination must have editor character geometry")
        let up = f.window.convertPoint(fromScreen: NSPoint(x: rect.minX + min(1, rect.width / 10), y: rect.midY))
        _ = try f.checked(up, target: editor, label: "first prose drag destination")
        var events: [NSEvent] = []
        for step in 1...8 {
            let fraction = CGFloat(step) / 8
            events.append(mouse(.leftMouseDragged, NSPoint(x: down.x + (up.x - down.x) * fraction,
                y: down.y + (up.y - down.y) * fraction), in: f.window))
        }
        events.append(mouse(.leftMouseUp, up, in: f.window))
        try await post(events)
        try require(editor.selectedRange() == NSRange(location: 6, length: 9)
            && f.canvas.selection == [note.id] && f.canvas.focusedTile == note.id,
            "the first \(reversed ? "reversed" : "forward") prose drag must select exactly paragraph in the native editor")
        try await typed("X", in: f.window)
        let expected = "First X.\n\nSecond paragraph.\n"
        try require(editor.string == expected, "typing after the first prose drag must replace exactly the dragged source range")
        try await post([key(36, "\r", flags: .command, in: f.window)])
        try await wait("the first prose drag replacement must save at the same exact source range") {
            f.board.objects[note.id]?.props["markdown"]?.string == expected
        }
    }

    private static func exerciseBlankNoteCaret(_ f: Fixture) async throws {
        let note = try await f.create(.note)
        let source = "Final **paragraph**.\n"
        _ = try f.board.update(note.id, props: .object(["markdown": .string(source)]))
        guard let tile = f.canvas.tiles[note.id]?.content as? NoteTile else { throw Failure("blank-body note missing") }
        try await wait("blank-body note must render its final paragraph") {
            descendants(tile).compactMap { $0 as? NSTextView }.contains {
                !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor && $0.string.contains("Final paragraph.")
            }
        }
        guard let text = descendants(tile).compactMap({ $0 as? NSTextView }).first(where: {
                  !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor && $0.string.contains("Final paragraph.")
              }), let layout = text.textLayoutManager, let content = layout.textContentManager else {
            throw Failure("blank-body click needs laid-out native prose")
        }
        layout.ensureLayout(for: content.documentRange)
        var bottom: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout]) { fragment in
            bottom = max(bottom, fragment.layoutFragmentFrame.maxY)
            return true
        }
        try require(bottom > 0, "blank-body target must be below an actual final text fragment")
        let point = text.convert(NSPoint(x: text.textContainerOrigin.x + 20, y: text.textContainerOrigin.y + bottom + 35), to: nil)
        _ = try f.checked(point, target: tile, label: "blank note body below final line")
        f.window.makeFirstResponder(f.canvas.document)
        f.canvas.setSelection([])
        try await click(point, in: f.window)
        guard let editor = f.window.firstResponder as? NSTextView, editor.isEditable else {
            throw Failure("one blank-body click must open the native note editor")
        }
        try require(editor.selectedRange() == NSRange(location: (source as NSString).length, length: 0),
            "blank body below the final rendered fragment must place the caret at raw-source end, after Markdown and the trailing newline")
        try await typed("TAIL", in: f.window)
        try require(editor.string == source + "TAIL", "blank-body typing must append at raw-source end rather than prepend at offset zero")
        try await post([key(36, "\r", flags: .command, in: f.window)])
        try await wait("blank-body insertion must save at the exact raw-source end") {
            f.board.objects[note.id]?.props["markdown"]?.string == source + "TAIL"
        }
    }

    private static func exerciseImmediateHTMLKey(_ f: Fixture, field: Bool = false) async throws {
        let terminal = try await f.create(.terminal, x: 20, y: 110, width: 370, height: 310)
        let html = try await f.create(.html, x: 470, y: 110, width: 440, height: 310)
        let web = try await f.web(html.id)
        let selector = field ? "#second" : "#plain"
        let armed = await js(web, """
        document.querySelector('\(selector)').addEventListener('mousedown', () => {
          const until = performance.now() + 150;
          while (performance.now() < until) {}
          window.clickFinished = true;
        });
        true
        """) as? Bool
        try require(armed == true, "the page must delay its native click before the immediate-key trial")
        try await enter(terminal, in: f)
        let before = f.read(terminal.id)
        let point = try await f.pagePoint(html.id, selector: selector)
        let down = mouse(.leftMouseDown, point, in: f.window)
        let immediate = key(0, "x", in: f.window)
        let up = mouse(.leftMouseUp, point, in: f.window)
        NSApp.sendEvent(down)
        NSApp.sendEvent(immediate)
        try require(f.canvas.selection == [html.id] && f.canvas.focusedTile == html.id,
            "HTML mouse-down must synchronously move selection and typing away from the terminal before the back-to-back key; \(f.diagnostic(point)) web=\(web)")
        NSApp.sendEvent(up)
        try await wait("the delayed native page click must finish") {
            await js(web, "window.clickFinished === true && \(field ? "document.activeElement?.id === 'second'" : "true")") as? Bool == true
        }
        try require(f.read(terminal.id) == before, "an HTML click must not leak its immediate key to the previous terminal")
        try await typed("y", in: f.window)
        try await wait("the clicked HTML page must receive subsequent native keys") {
            let keys = await js(web, "document.getElementById('keys').textContent") as? String
            return keys == "y" || keys == "xy"
        }
        if field {
            let keys = await js(web, "document.getElementById('keys').textContent") as? String
            let value = await js(web, "document.getElementById('second').value") as? String
            try require(value == keys, "native field clicks must preserve the clicked textarea and caret")
            let first = await js(web, "document.getElementById('field').value") as? String
            try require(first == "", "typing in the clicked textarea must not edit the page's formerly focused field")
        }
        try require(f.read(terminal.id) == before, "neither pending nor subsequent HTML keys may reach the previous terminal")
        try require(f.canvas.selection == [html.id] && f.canvas.focusedTile == html.id, "the clicked HTML tile must retain selection and typing")
        try await enter(terminal, in: f)
        try await typed("guard", in: f.window)
        try await wait("immediate HTML keys must leave terminal bytes unchanged before the positive terminal control") {
            f.read(terminal.id) == before + Data("guard".utf8)
        }
    }

    private static func exerciseClickedHTMLGoTo(_ f: Fixture) async throws {
        let terminal = try await f.create(.terminal, x: 20, y: 110, width: 370, height: 310)
        let target = try await f.create(.note, x: 470, y: 450, width: 360, height: 180)
        let html = try await f.create(.html, x: 470, y: 110, width: 440, height: 310)
        _ = try f.board.update(html.id, props: .object(["html": .string(page.replacingOccurrences(
            of: "<p id=\"plain\">Selection typing fixture</p>",
            with: "<canvas-object id=\"\(target.id)\" style=\"display:block\" data-target=\"destination\">Destination</canvas-object>"))]))
        let web = try await f.web(html.id)
        try await wait("the object link must load in the replacement page") {
            await js(web, "!!document.querySelector('canvas-object[data-target]') && typeof canvasKit?.goTo === 'function'") as? Bool == true
        }
        try await enter(terminal, in: f)
        let before = f.read(terminal.id)
        let point = try await f.pagePoint(html.id, selector: "canvas-object[data-target]")
        try await post([mouse(.leftMouseDown, point, in: f.window)])
        try require(f.canvas.focusedTile == html.id, "a native HTML link mouse-down must take typing")
        let sourceResponder = f.window.firstResponder
        try await post([mouse(.leftMouseUp, point, in: f.window)])
        try await wait("the native HTML object link must select its destination") { f.canvas.selection == [target.id] }
        try require(f.canvas.focusedTile == html.id && f.window.firstResponder === sourceResponder,
            "goTo destination selection must preserve the clicked HTML source's exact responder")
        try await typed("y", in: f.window)
        try await wait("the clicked HTML source must receive subsequent keys after destination selection") {
            (await js(web, "document.getElementById('keys').textContent") as? String)?.hasSuffix("y") == true
        }
        try require(f.read(terminal.id) == before, "typing after an HTML object link must never return to the previous terminal")
        try require(f.canvas.selection == [target.id] && f.canvas.focusedTile == html.id,
            "the destination must retain its selection ring while the source HTML retains typing")
        try await enter(terminal, in: f)
        try await typed("guard", in: f.window)
        try await wait("HTML link keys must leave terminal bytes unchanged before the positive terminal control") {
            f.read(terminal.id) == before + Data("guard".utf8)
        }
    }

    private static func exerciseHTMLReplacementTitle(_ f: Fixture) async throws {
        let html = try await f.create(.html)
        try await click(try await f.pagePoint(html.id, selector: "#field"), in: f.window)
        try await wait("replacement fixture must start with a native HTML typing owner") { f.canvas.focusedTile == html.id }
        try await typed("old", in: f.window)
        _ = try f.board.update(html.id, props: .object(["html": .string(page.replacingOccurrences(
            of: "Selection typing fixture", with: "Replacement document"))]))
        let web = try await f.web(html.id)
        try await wait("replacement document must commit before the new title click") {
            await js(web, "document.getElementById('plain').textContent") as? String == "Replacement document"
        }
        try await click(try f.point(html.id, title: true), in: f.window)
        try await typed("new", in: f.window)
        try await wait("a fresh title selection must authorize typing in the replacement document") {
            await js(web, "document.getElementById('keys').textContent") as? String == "new"
        }
        try require(f.canvas.selection == [html.id] && f.canvas.focusedTile == html.id,
            "replacement title entry must retain the selected HTML typing owner")
    }

    private static func exerciseHTMLNavigationEntry(_ f: Fixture, pageInitiated: Bool) async throws {
        let html = try await f.create(.html)
        guard let tile = f.canvas.tiles[html.id]?.content as? HtmlTile else { throw Failure("reload HTML tile missing") }
        let web = try await f.web(html.id)
        let observer = ReloadEntryObserver(tile: tile)
        var entered = false
        observer.onStart = {
            f.canvas.setSelection([html.id])
            entered = tile.enterKeyboard()
        }
        web.navigationDelegate = observer
        defer { web.navigationDelegate = tile }
        if pageInitiated {
            _ = await js(web, "location.reload(); true")
        } else {
            _ = try f.board.update(html.id, props: .object(["html": .string(page.replacingOccurrences(
                of: "Selection typing fixture", with: "Native pending document"))]))
        }
        try await wait("navigation must start and receive a fresh native entry before commit") { entered }
        try await wait("the pending navigation must commit") { observer.committed }
        _ = try await f.web(html.id)
        try await typed("reload", in: f.window)
        try await wait("a fresh native entry during navigation must survive only that live commit") {
            await js(web, "document.getElementById('keys').textContent") as? String == "reload"
        }
        try require(f.canvas.focusedTile == html.id, "the completed HTML page must retain the fresh native typing owner")
    }

    private static func exerciseBoardUndo(_ f: Fixture) async throws {
        let object = try await f.create(.note)
        let moved = Frame(x: object.frame.x + 30, y: object.frame.y + 20, w: object.frame.w, h: object.frame.h)
        _ = try f.board.update(object.id, frame: moved)
        f.window.makeFirstResponder(f.canvas.document)
        try await post([key(6, "z", flags: .command, in: f.window)])
        try await wait("native CmdZ must reach the app's board undo menu route") { f.board.objects[object.id]?.frame == object.frame }
        try await post([key(6, "z", flags: [.command, .shift], in: f.window)])
        try await wait("native Shift-CmdZ must reach the app's board redo menu route") { f.board.objects[object.id]?.frame == moved }
    }

    private static func exerciseShiftText(_ type: ObjectType, _ f: Fixture) async throws {
        let object = try await f.create(type)
        if type == .note {
            try await enter(object, in: f)
            guard let editor = f.window.firstResponder as? NSTextView else { throw Failure("note must expose its native editor") }
            try await post([key(0, "a", flags: .command, in: f.window)])
            try await typed("abcdef", in: f.window)
            try require(editor.string == "abcdef", "native Select All and typing must prepare note text")
            let rect = editor.firstRect(forCharacterRange: NSRange(location: 1, length: 1), actualRange: nil)
            try require(rect.width > 0 && rect.height > 0, "shift-click character must have native geometry")
            let point = f.window.convertPoint(fromScreen: NSPoint(x: rect.minX + 1, y: rect.midY))
            print("SHIFT before=\(editor.selectedRange()) insertion=\(editor.characterIndexForInsertion(at: editor.convert(point, from: nil))) point=\(point) \(f.diagnostic(point))")
            fflush(nil)
            try require(editor.selectedRange() == NSRange(location: 6, length: 0)
                && editor.characterIndexForInsertion(at: editor.convert(point, from: nil)) == 1,
                "Shift-click geometry must target insertion 1 while the native caret remains at 6")
            try await click(point, flags: .shift, in: f.window)
            try require(f.window.firstResponder === editor && f.canvas.selection == [object.id] && f.canvas.focusedTile == object.id,
                "Shift-click inside the active note must retain its editor and selection; \(f.diagnostic(point))")
            let range = editor.selectedRange()
            print("SHIFT after=\(range) globalFlags=\(NSEvent.modifierFlags.rawValue)")
            fflush(nil)
            try require(range.length > 0 && NSMaxRange(range) == 6, "native Shift-click must extend note text selection from caret 6; actual=\(range)")
            let expected = (editor.string as NSString).replacingCharacters(in: range, with: "X")
            try await typed("X", in: f.window)
            try require(editor.string == expected, "typing must replace the Shift-clicked note text range")
        } else {
            let web = try await f.web(object.id)
            try await click(try await f.pagePoint(object.id, selector: "#field"), in: f.window)
            try await typed("abcdef", in: f.window)
            try await wait("HTML text must be ready before Shift-click") {
                await js(web, "document.getElementById('field').value") as? String == "abcdef"
            }
            let responder = f.window.firstResponder
            let point = try await f.pagePoint(object.id, selector: "#field")
            try await click(point, flags: .shift, in: f.window)
            try require(f.window.firstResponder === responder && f.canvas.selection == [object.id] && f.canvas.focusedTile == object.id,
                "Shift-click inside active HTML must retain its exact responder and selection; \(f.diagnostic(point))")
            try await wait("native Shift-click must extend HTML text selection") {
                await js(web, "(() => { const f = document.getElementById('field'); return f.selectionStart < f.selectionEnd && f.selectionEnd === 6 })()") as? Bool == true
            }
            guard let expected = await js(web, "(() => { const f = document.getElementById('field'); return f.value.slice(0, f.selectionStart) + 'X' + f.value.slice(f.selectionEnd) })()") as? String else {
                throw Failure("HTML native selection must be readable")
            }
            try await typed("X", in: f.window)
            try await wait("typing must replace the Shift-clicked HTML range") {
                await js(web, "document.getElementById('field').value") as? String == expected
            }
        }
    }

    private static func exerciseOffscreenGo(_ f: Fixture) async throws {
        let note = f.board.create(type: .note, props: .object(["markdown": "Offscreen note.\n"]),
            frame: Frame(x: 5000, y: 5000, w: 1800, h: 2000))
        try require(f.canvas.tiles[note.id]?.isLive != true, "navigation target must start offscreen, not already live")
        f.canvas.go(to: note.id)
        try await wait("offscreen user navigation must hand typing to its note") {
            f.canvas.focusedTile == note.id && (f.window.firstResponder as? NSTextView)?.isEditable == true
        }
        let viewport = f.canvas.viewport
        try require(viewport.zoom < 0.9 && viewport.rect.x <= note.frame.x
            && viewport.rect.x + viewport.rect.w >= note.frame.x + note.frame.w,
            "typing handoff must preserve Go to's fit of the oversized note, not recenter at 100%; \(f.diagnostic())")
        guard let editor = f.window.firstResponder as? NSTextView else { throw Failure("offscreen navigation editor missing") }
        try requireVisibleCaret(editor, in: f)
        try await assertInput(note, in: f)
    }

    private static func exerciseHeadingGo(_ f: Fixture) async throws {
        let note = try await f.create(.note, height: 600)
        let prefix = (1...40).map { "Paragraph \($0).\n\n" }.joined()
        let source = prefix + "## Destination\n\nHeading body.\n\n" + String(repeating: "Trailing paragraph.\n\n", count: 60)
        _ = try f.board.update(note.id, props: .object(["markdown": .string(source)]))
        f.canvas.go(to: note.id, heading: 81)
        try await wait("heading Go to must enter the source heading, not the note end") {
            guard let editor = f.window.firstResponder as? NSTextView else { return false }
            return f.canvas.focusedTile == note.id && editor.selectedRange() == NSRange(location: (prefix as NSString).length, length: 0)
        }
        guard let editor = f.window.firstResponder as? NSTextView else { throw Failure("heading navigation must open editor") }
        try requireVisibleCaret(editor, in: f)
        try await typed("HERE", in: f.window)
        try require(editor.string == prefix + "HERE" + String(source.dropFirst(prefix.count)), "typing after heading navigation must insert immediately before its source heading")
    }

    private static func exerciseCommandBackspace(_ f: Fixture) async throws {
        let note = try await f.create(.note)
        try await click(try f.point(note.id), in: f.window)
        try await wait("single note click must open an editor before the delete shortcut") {
            f.canvas.focusedTile == note.id && (f.window.firstResponder as? NSTextView)?.isEditable == true
        }
        guard let editor = f.window.firstResponder as? NSTextView else { throw Failure("note editor missing") }
        try await post([key(0, "a", flags: .command, in: f.window)])
        try await typed("keep", in: f.window)
        try await post([key(36, "\r", in: f.window)])
        try await typed("remove", in: f.window)
        try require(editor.string == "keep\nremove", "native text setup must replace the note")
        try await post([key(51, "\u{7f}", flags: .command, in: f.window)])
        try require(f.board.objects[note.id] != nil, "Command-Backspace in a note must not delete the tile")
        try require(editor.string == "keep\n" && f.window.firstResponder === editor,
            "native Command-Backspace must delete to start of line inside the active editor; actual=\(editor.string.debugDescription)")
    }

    private static func exerciseHistoryBack(_ f: Fixture) async throws {
        let first = try await f.create(.note, x: 20, y: 110, width: 340, height: 230)
        let second = try await f.create(.note, x: 470, y: 110, width: 340, height: 230)
        try await enter(first, in: f)
        try await post([key(124, "\u{f703}", flags: [.command, .option], in: f.window)])
        try await wait("native neighbor shortcut must first enter the second note") { f.canvas.focusedTile == second.id }
        try await post([key(33, "[", flags: .command, in: f.window)])
        try await wait("native user Back must return both selection and typing to the first note") {
            f.canvas.selection == [first.id] && f.canvas.focusedTile == first.id
        }
        try await assertInput(first, in: f)
    }

    private static func exercisePanelReturn(_ f: Fixture, replacement: Bool = false) async throws {
        var terminal: CanvasObject?
        if replacement {
            let previous = try await f.create(.terminal, x: 20, y: 110, width: 370, height: 310)
            try await enter(previous, in: f)
            try await typed("ready", in: f.window)
            try await wait("replacement-panel previous terminal must demonstrably receive native input") {
                f.read(previous.id) == Data("ready".utf8)
            }
            terminal = previous
        }
        let html = try await f.create(.html, x: replacement ? 470 : 30)
        try await click(try await f.pagePoint(html.id, selector: "#field"), in: f.window)
        try await wait("HTML field must own typing before opening Go to") { f.canvas.focusedTile == html.id }
        let responder = f.window.firstResponder
        if replacement {
            try await typed("old", in: f.window)
            let web = try await f.web(html.id)
            try await wait("the old HTML document must have a real native typing grant before replacement") {
                await js(web, "document.getElementById('field').value") as? String == "old"
            }
        }
        try await post([key(35, "p", flags: .command, in: f.window)])
        try await wait("native Command-P must give the navigator its text field") {
            f.window.firstResponder !== responder && f.window.firstResponder !== f.canvas.document
                && (f.window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        try require(!f.window.makeFirstResponder(responder), "page-initiated focus while a panel owns typing must stay denied")
        let panelResponder = f.window.firstResponder
        let oldWeb = try await f.web(html.id)
        _ = await js(oldWeb, "document.getElementById('second').focus(); true")
        try await post([])
        try await Task.sleep(for: .milliseconds(100))
        try require(f.window.firstResponder === panelResponder,
            "a generic page script-focus request must not steal native typing from the navigator")
        _ = await js(oldWeb, "document.getElementById('field').focus(); true")
        try await post([])
        try await Task.sleep(for: .milliseconds(100))
        try require(f.window.firstResponder === panelResponder,
            "restoring the original DOM field by script must still leave native typing with the navigator")
        if replacement {
            _ = try f.board.update(html.id, props: .object(["html": .string(page.replacingOccurrences(
                of: "Selection typing fixture", with: "Replacement while panel owns typing"))]))
            let web = try await f.web(html.id)
            try await wait("the HTML replacement must load while the panel retains typing") {
                await js(web, "document.getElementById('plain').textContent") as? String == "Replacement while panel owns typing"
            }
            _ = await js(web, "document.getElementById('second').focus(); true")
            try await post([])
            try await Task.sleep(for: .milliseconds(100))
            try require(f.window.firstResponder === panelResponder,
                "replacement-page script focus must remain denied while the panel owns keys")
            _ = await js(web, "document.getElementById('field').focus(); true")
            try await post([])
            try await Task.sleep(for: .milliseconds(100))
            try require(f.window.firstResponder === panelResponder,
                "preparing the replacement field must not authorize its native page responder")
        }
        try await post([key(53, "\u{1b}", in: f.window)])
        if replacement {
            guard let tile = f.canvas.tiles[html.id]?.content as? HtmlTile, let terminal else {
                throw Failure("replacement panel fixtures must retain their native owners")
            }
            try await wait("panel cancellation must restore the native HTML key sink without authorizing the replacement page") {
                f.window.firstResponder === tile && f.canvas.focusedTile == html.id && f.canvas.selection == [html.id]
            }
            try require(!f.window.makeFirstResponder(responder) && f.window.firstResponder === tile,
                "a stale old-page responder grant must not authorize the replacement document")
            let web = try await f.web(html.id)
            try await typed("blocked", in: f.window)
            let blockedField = await js(web, "document.getElementById('field').value") as? String
            let blockedKeys = await js(web, "document.getElementById('keys').textContent") as? String
            try require(blockedField == "" && blockedKeys == "" && f.read(terminal.id) == Data("ready".utf8)
                && f.window.firstResponder === tile && f.canvas.selection == [html.id],
                "keys owned by the restored HTML root must reach neither the replacement page nor the previous terminal")
            try await post([key(36, "\r", in: f.window)])
            try await wait("a fresh native Return on the restored HTML root must explicitly reenter the current page") {
                guard let current = f.window.firstResponder as? NSView else { return false }
                return current !== tile && (current === web || current.isDescendant(of: web)) && f.canvas.focusedTile == html.id
            }
            try await typed("returned", in: f.window)
            try await wait("keys after native root Return must reach only the newly authorized replacement field") {
                let field = await js(web, "document.getElementById('field').value") as? String
                let keys = await js(web, "document.getElementById('keys').textContent") as? String
                return field == "returned" && keys == "returned"
            }
            try require(f.canvas.selection == [html.id] && f.canvas.focusedTile == html.id,
                "explicit Return reentry must keep the HTML selection and typing owner")
            try await enter(terminal, in: f)
            try await typed("guard", in: f.window)
            try await wait("neither blocked root keys nor replacement-page keys may reach the previous terminal") {
                f.read(terminal.id) == Data("readyguard".utf8)
            }
        } else {
            try await wait("panel cancellation must restore the unchanged HTML responder") { f.window.firstResponder === responder }
            try await typed("returned", in: f.window)
            let web = try await f.web(html.id)
            try await wait("the next native keys after panel cancellation must reach the unchanged HTML field") {
                await js(web, "document.getElementById('field').value") as? String == "returned"
            }
            try require(f.canvas.selection == [html.id] && f.canvas.focusedTile == html.id, "restoring a panel must preserve selection and HTML typing")
        }
    }

    private static func exerciseNotePanelReturn(_ f: Fixture) async throws {
        let note = try await f.create(.note)
        try await enter(note, in: f)
        guard let editor = f.window.firstResponder as? NSTextView, editor.isEditable else {
            throw Failure("note panel fixture must start in an actual native editor")
        }
        try await post([key(0, "a", flags: .command, in: f.window)])
        try await typed("Before panel", in: f.window)
        try await post([key(0, "a", flags: .command, in: f.window)])
        try require(editor.string == "Before panel" && editor.selectedRange() == NSRange(location: 0, length: 12),
            "native note typing and Select All must establish the text range to restore")
        try await post([key(35, "p", flags: .command, in: f.window)])
        try await wait("native Command-P must move typing from the note into the navigator") {
            f.window.firstResponder !== editor && (f.window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        try await post([key(53, "\u{1b}", in: f.window)])
        try await wait("cancelling the navigator must resume actual note editing with the exact responder and range") {
            f.window.firstResponder === editor && editor.isEditable && !editor.isHiddenOrHasHiddenAncestor
                && editor.string == "Before panel" && editor.selectedRange() == NSRange(location: 0, length: 12)
                && f.canvas.focusedTile == note.id && f.canvas.selection == [note.id]
                && (f.canvas.tiles[note.id]?.content as? NoteTile)?.isEditing == true
        }
        try await typed("After panel", in: f.window)
        try require(editor.string == "After panel", "typing after panel cancellation must replace the restored note selection")
        try await post([key(36, "\r", flags: .command, in: f.window)])
        try await wait("the resumed native note edit must save the replacement text") {
            f.board.objects[note.id]?.props["markdown"]?.string == "After panel"
        }
    }


    private static func exerciseQuestionHeldReturn(_ f: Fixture) async throws {
        let question = try await f.create(.question)
        try f.board.answerQuestion(question.id, option: "one", note: nil, confidence: nil)
        f.window.makeFirstResponder(f.canvas.document)
        f.canvas.setSelection([])
        try await f.ready(question.id)
        try await click(try f.point(question.id, title: true), in: f.window)
        try await wait("a selected answered question must take typing without archiving") {
            f.canvas.focusedTile == question.id && f.board.objects[question.id]?.isHidden == false
        }
        try await post([key(36, "\r", isARepeat: true, in: f.window)])
        try require(f.board.objects[question.id]?.isHidden == false,
                    "Return already held before selecting an answered question must not archive it")
        try await post([key(36, "\r", in: f.window)])
        try await wait("a fresh Return must still archive an answered question") {
            f.board.objects[question.id]?.isHidden == true
        }
    }

    private static func run(_ name: String, _ f: Fixture) async throws {
        for action in ["click", "title", "reentry", "cmd-escape"] {
            if name.hasPrefix(action + "-"), let type = ObjectType(rawValue: String(name.dropFirst(action.count + 1))) {
                try await exerciseClick(action, type, f)
                return
            }
        }
        if name.hasPrefix("shift-body-") {
            let single = name.hasSuffix("-single")
            let suffix = String(name.dropFirst("shift-body-".count))
            let typeName = single ? String(suffix.dropLast("-single".count)) : suffix
            guard let type = ObjectType(rawValue: typeName) else { throw Failure("invalid Shift-body tile type") }
            try await exerciseShiftBody(type, single: single, f)
        } else if name.hasPrefix("overview-card-") {
            try await exerciseOverview(name, f)
        } else if name == "move-body-image" || name == "move-body-diagram" {
            try await exercisePassiveMove(name == "move-body-image" ? .image : .diagram, f)
        } else if name == "move-body-terminal-double-click" {
            try await exerciseMoveBodyDoubleClick(f)
        } else if name.hasPrefix("code-programmatic-") {
            try await exerciseCodeProgrammatic(String(name.dropFirst("code-programmatic-".count)), f)
        } else if name == "question-confidence" {
            try await exerciseQuestionConfidence(f)
        } else if name == "question-confidence-from-note" {
            try await exerciseQuestionConfidence(f, fromNote: true)
        } else if name == "browser-empty-undo" || name == "html-empty-undo" {
            try await exerciseEmptyPageUndo(name == "browser-empty-undo" ? .browser : .html, f)
        } else if name == "browser-interleaved-undo" || name == "html-interleaved-undo" {
            try await exerciseUndo(name == "browser-interleaved-undo" ? .browser : .html, f, interleaved: true)
        } else if name == "title-drag-unselected" || name == "resize-unselected" {
            try await exerciseGeometryGesture(name, f)
        } else if name == "note-scrollbar" || name == "note-scroll" {
            try await exerciseNoteScroll(name, f)
        } else if name == "board-scroll" {
            try await exerciseBoardScroll(f)
        } else if name == "note-navigation-caret" {
            try await exerciseNoteNavigationCaret(f)
        } else if name.hasPrefix("preserve-") {
            let suffix = String(name.dropFirst("preserve-".count))
            guard let dash = suffix.firstIndex(of: "-"), let owner = ObjectType(rawValue: String(suffix[..<dash])) else { throw Failure("invalid owner scenario") }
            try await exercisePreservation(owner, route: String(suffix[suffix.index(after: dash)...]), f)
        } else if name == "terminal-literal-escape" {
            try await exerciseLiteralEscape(f)
        } else if name == "note-click-caret" {
            try await exerciseNoteCaret(f)
        } else if name == "note-styled-click-caret" {
            try await exerciseNoteCaret(f, styled: true)
        } else if name == "note-wrapped-click-caret" {
            try await exerciseNoteCaret(f, styled: true, wrapped: true)
        } else if name == "note-rule-click-caret" || name == "note-whitespace-click-caret" {
            try await exerciseUnmappedNoteCaret(f, whitespace: name == "note-whitespace-click-caret")
        } else if name == "note-first-drag-forward" || name == "note-first-drag-reverse" {
            try await exerciseFirstNoteDrag(f, reversed: name == "note-first-drag-reverse")
        } else if name == "note-blank-body-caret" {
            try await exerciseBlankNoteCaret(f)
        } else if name == "html-immediate-key" {
            try await exerciseImmediateHTMLKey(f)
        } else if name == "html-immediate-field-key" {
            try await exerciseImmediateHTMLKey(f, field: true)
        } else if name == "html-click-go-to" {
            try await exerciseClickedHTMLGoTo(f)
        } else if name == "html-replacement-title" {
            try await exerciseHTMLReplacementTitle(f)
        } else if name == "html-loading-entry" {
            try await exerciseHTMLNavigationEntry(f, pageInitiated: false)
        } else if name == "html-page-reload-entry" {
            try await exerciseHTMLNavigationEntry(f, pageInitiated: true)
        } else if name == "html-panel-replacement" {
            try await exercisePanelReturn(f, replacement: true)
        } else if name == "board-undo-redo" {
            try await exerciseBoardUndo(f)
        } else if name == "question-held-return" {
            try await exerciseQuestionHeldReturn(f)
        } else if name == "shift-note-text" || name == "shift-html-text" {
            try await exerciseShiftText(name == "shift-note-text" ? .note : .html, f)
        } else if name == "offscreen-go-note" {
            try await exerciseOffscreenGo(f)
        } else if name == "heading-go-note" {
            try await exerciseHeadingGo(f)
        } else if name == "note-command-backspace" {
            try await exerciseCommandBackspace(f)
        } else if name == "history-back-note" {
            try await exerciseHistoryBack(f)
        } else if name == "html-panel-return" {
            try await exercisePanelReturn(f)
        } else if name == "note-panel-return" {
            try await exerciseNotePanelReturn(f)
        } else if name == "keyboard-tab-note" {
            let terminal = try await f.create(.terminal, x: 20, y: 110, width: 340, height: 230)
            let note = try await f.create(.note, x: 470, y: 110, width: 340, height: 230)
            f.canvas.setSelection([terminal.id])
            try f.boardOwns([terminal.id])
            try await post([key(48, "\t", in: f.window)])
            try await assertInput(note, in: f)
        } else if name == "keyboard-neighbor-note" {
            let terminal = try await f.create(.terminal, x: 20, y: 110, width: 340, height: 230)
            let note = try await f.create(.note, x: 470, y: 110, width: 340, height: 230)
            try await enter(terminal, in: f)
            try await post([key(124, "\u{f703}", flags: [.command, .option], in: f.window)])
            try await assertInput(note, in: f)
        } else if name == "html-undo-redo" || name == "browser-undo-redo" {
            try await exerciseUndo(name == "html-undo-redo" ? .html : .browser, f)
        } else {
            try await exerciseGesture(name, f)
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
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"], let name = CommandLine.arguments.dropFirst().first,
              scenarios.contains(where: { $0.name == name }) else {
            FileHandle.standardError.write(Data("FAIL runner must provide isolated EASL_HOME and a registered scenario\n".utf8))
            exit(2)
        }
        _ = CanvasApplication.shared
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        var fixture: Fixture?
        var failure: Error?
        do {
            let f = try await Fixture(home: URL(fileURLWithPath: home), changes: name.contains("changes"))
            fixture = f
            try await run(name, f)
        } catch { failure = error }
        if let fixture {
            if failure != nil {
                print("FAILURE STATE \(fixture.diagnostic())")
                for (id, group) in fixture.canvas.groups {
                    print("GROUP \(id) region=\(group.region) frame=\(group.frame) title=\(group.titleRect)")
                }
            }
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
