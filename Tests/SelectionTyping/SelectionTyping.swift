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
                type == .note || type == .html ? "feature regression" : "existing behavior control"))
        }
        for type in typingTypes {
            cases.append(Scenario(name: "title-\(type.rawValue)", baseline:
                type == .terminal ? "existing behavior control" : "feature regression"))
            cases.append(Scenario(name: "reentry-\(type.rawValue)", baseline:
                type == .terminal ? "existing behavior control" : "feature regression"))
            cases.append(Scenario(name: "cmd-escape-\(type.rawValue)", baseline: "existing behavior control"))
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
        cases.append(Scenario(name: "html-immediate-key", baseline: "feature regression"))
        cases.append(Scenario(name: "html-immediate-field-key", baseline: "feature regression"))
        cases.append(Scenario(name: "html-click-go-to", baseline: "feature regression"))
        cases.append(Scenario(name: "board-undo-redo", baseline: "existing behavior control"))
        cases.append(Scenario(name: "keyboard-neighbor-note", baseline: "feature regression"))
        cases.append(Scenario(name: "keyboard-tab-note", baseline: "feature regression"))
        cases.append(Scenario(name: "html-undo-redo", baseline: "existing behavior control"))
        cases.append(Scenario(name: "browser-undo-redo", baseline: "existing behavior control"))
        return cases
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

    private static func key(_ code: UInt16, _ text: String, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: flags.contains(.shift) ? text.uppercased() : text,
            charactersIgnoringModifiers: flags.contains(.shift) ? text.uppercased() : text,
            isARepeat: false, keyCode: code)!
    }

    private static func mouse(_ type: NSEvent.EventType, _ point: NSPoint, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private static func post(_ events: [NSEvent]) {
        for event in events { NSApp.postEvent(event, atStart: false) }
        while let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }

    private static func click(_ point: NSPoint, flags: NSEvent.ModifierFlags = [], in window: NSWindow) {
        post([mouse(.leftMouseDown, point, flags: flags, in: window), mouse(.leftMouseUp, point, flags: flags, in: window)])
    }

    private static func typed(_ text: String, in window: NSWindow) {
        for character in text {
            let text = String(character)
            let code: UInt16 = text == "\r" ? 36 : text == "\t" ? 48 : 0
            post([key(code, text, in: window)])
        }
    }

    private static func drag(_ start: NSPoint, _ end: NSPoint, in window: NSWindow) {
        var events = [mouse(.leftMouseDown, start, in: window)]
        for step in 1...8 {
            let fraction = CGFloat(step) / 8
            events.append(mouse(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction), in: window))
        }
        events.append(mouse(.leftMouseUp, end, in: window))
        post(events)
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

        func point(_ id: ObjectID, title: Bool = false) throws -> NSPoint {
            if let group = canvas.groups[id] {
                return group.convert(NSPoint(x: group.titleRect.midX, y: group.titleRect.midY), to: nil)
            }
            if board.objects[id]?.type == .shape, let rect = canvas.docFrame(id) {
                return canvas.document.convert(NSPoint(x: rect.minX + 2, y: rect.midY), to: nil)
            }
            guard let tile = canvas.tiles[id], tile.isLive else { throw Failure("click target is not a live tile") }
            return title ? tile.convert(NSPoint(x: 120, y: TileFrameView.titleHeight / 2), to: nil)
                : tile.content.convert(NSPoint(x: min(75, tile.content.bounds.width / 2), y: 55 + tile.content.headerHeight), to: nil)
        }

        func pagePoint(_ id: ObjectID, selector: String) async throws -> NSPoint {
            let web = try await web(id)
            guard let rect = await js(web, "document.querySelector('\(selector)').getBoundingClientRect().toJSON()") as? [String: Double],
                  let x = rect["x"], let y = rect["y"] else { throw Failure("missing page click target \(selector)") }
            let scale = web.pageZoom * web.magnification
            return web.convert(NSPoint(x: CGFloat(x + 10) * scale,
                y: web.isFlipped ? CGFloat(y + 10) * scale : web.bounds.height - CGFloat(y + 10) * scale), to: nil)
        }

        func read(_ id: ObjectID) -> Data { receipts[id].flatMap { try? Data(contentsOf: $0) } ?? Data() }

        func boardOwns(_ selection: Set<ObjectID>) throws {
            try require(canvas.selection == selection, "selection must be \(selection), got \(canvas.selection)")
            try require(window.firstResponder === canvas.document, "board must own keys, got \(String(describing: window.firstResponder))")
            try require(canvas.focusedTile == nil, "no tile may retain typing during a board-owned gesture")
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
            typed(marker, in: f.window)
            try await wait("native text did not reach the real terminal program") { f.read(object.id) == before + Data(marker.utf8) }
        case .note:
            guard let editor = f.window.firstResponder as? NSTextView, editor.isEditable else { throw Failure("single note click did not open its text editor") }
            let before = editor.string
            typed(marker, in: f.window)
            try require(editor.string != before && editor.string.contains(marker), "native text must edit the clicked note")
        case .html, .browser:
            let web = try await f.web(object.id)
            typed(marker, in: f.window)
            try await wait("native key did not reach the selected page") { await js(web, "document.getElementById('keys').textContent") as? String == marker }
        case .question:
            post([key(18, "1", in: f.window), key(36, "\r", in: f.window)])
            try await wait("question number key and Return did not record an answer") { f.board.objects[object.id]?.props["answer"]?["option"]?.string == "one" }
        case .code, .changes:
            let responder = f.window.firstResponder
            post([key(125, "\u{f701}", in: f.window)])
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
        if action == "reentry" || action == "cmd-escape" {
            try await enter(object, in: f)
            post([key(53, "\u{1b}", flags: .command, in: f.window)])
            try await wait("Command-Escape must route through CanvasWindow/controller and return typing to board") {
                f.window.firstResponder === f.canvas.document && f.canvas.selection == [object.id]
            }
            if action == "cmd-escape" { return }
        }
        let point: NSPoint
        if type == .html || type == .browser, action == "click" {
            point = try await f.pagePoint(object.id, selector: "#plain")
        } else { point = try f.point(object.id, title: action != "click") }
        click(point, in: f.window)
        if typingTypes.contains(type) {
            try await assertInput(object, in: f)
        } else {
            try f.boardOwns([object.id])
            let revision = f.board.revision
            typed("x", in: f.window)
            try f.boardOwns([object.id])
            try require(f.board.revision == revision, "unhandled typing on a selected \(type.rawValue) must not mutate the board")
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
            drag(f.canvas.document.convert(rect.origin, to: nil),
                f.canvas.document.convert(NSPoint(x: rect.maxX, y: rect.maxY), to: nil), in: f.window)
            try f.boardOwns(scenario == "marquee-one" ? [terminal.id] : [terminal.id, other.id])
        case "shift-title-multi", "shift-title-single":
            click(try f.point(other.id, title: true), flags: .shift, in: f.window)
            try f.boardOwns([terminal.id, other.id])
            if scenario == "shift-title-single" {
                click(try f.point(other.id, title: true), flags: .shift, in: f.window)
                try f.boardOwns([terminal.id])
            }
        case "group-selection":
            let group = f.board.create(type: .group, props: .object(["members": .array([.string(terminal.id), .string(other.id)]), "title": "Group selection"]))
            f.window.layoutIfNeeded()
            click(try f.point(group.id), in: f.window)
            try f.boardOwns([group.id])
        case "move-terminal":
            f.controller.moveTool(nil)
            let start = try f.point(terminal.id)
            drag(start, NSPoint(x: start.x + 30, y: start.y + 20), in: f.window)
            try f.boardOwns([terminal.id])
            try require(f.board.objects[terminal.id]?.frame != terminal.frame, "Move must actually move the tile")
        default: throw Failure("unknown gesture")
        }
        typed("x", in: f.window)
        try await Task.sleep(for: .milliseconds(120))
        try require(f.read(terminal.id) == before, "board-owned gesture must not send stray keys to the shell")
    }

    private static func exercisePreservation(_ ownerType: ObjectType, route: String, _ f: Fixture) async throws {
        let owner = try await f.create(ownerType, x: 20, y: 110, width: 370, height: 310)
        let target = try await f.create(.note, x: 470, y: 110, width: 360, height: 220)
        var htmlSource: CanvasObject?
        var questionSource: CanvasObject?
        if route == "html-go-to" {
            htmlSource = try await f.create(.html, x: 450, y: 110, width: 440, height: 310)
            click(try await f.pagePoint(htmlSource!.id, selector: "#plain"), in: f.window)
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
            click(f.window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY)), in: f.window)
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
            "\(route) must preserve the user's existing \(ownerType.rawValue) typing owner")
        if route == "leave-selected" {
            post([key(53, "\u{1b}", flags: .command, in: f.window)])
            try await wait("Command-Escape must leave typing while preserving the programmatic selection") {
                f.window.firstResponder === f.canvas.document && f.canvas.selection == [target.id]
            }
            try f.boardOwns([target.id])
            return
        }
        typed("x", in: f.window)
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
        click(try f.point(object.id), in: f.window)
        let before = f.read(object.id)
        post([key(53, "\u{1b}", in: f.window)])
        try await wait("plain Escape did not reach the real terminal program as a literal 0x1b byte") {
            f.read(object.id) == before + Data([0x1b])
        }
        try require(f.canvas.focusedTile == object.id && f.canvas.selection == [object.id], "plain Escape must keep terminal typing and selection")
        post([key(53, "\u{1b}", flags: .command, in: f.window)])
        try await wait("Command-Escape must leave terminal typing without clearing selection") {
            f.window.firstResponder === f.canvas.document && f.canvas.selection == [object.id]
        }
        try require(f.read(object.id) == before + Data([0x1b]), "Leave Tile must not send a second Escape byte to the terminal")
    }

    private static func exerciseUndo(_ type: ObjectType, _ f: Fixture) async throws {
        let object = try await f.create(type)
        let moved = Frame(x: object.frame.x + 30, y: object.frame.y + 20, w: object.frame.w, h: object.frame.h)
        _ = try f.board.update(object.id, frame: moved)
        try require(f.board.history.canUndo, "fixture must have a board move that erroneous CmdZ could undo")
        let web = try await f.web(object.id)
        f.window.makeFirstResponder(f.canvas.document)
        click(try await f.pagePoint(object.id, selector: "#field"), in: f.window)
        try await wait("single field click must transfer native typing") { f.canvas.focusedTile == object.id }
        typed("typed", in: f.window)
        try await wait("single click must let native keys edit page text") { await js(web, "document.getElementById('field').value") as? String == "typed" }
        post([key(6, "z", flags: .command, in: f.window)])
        try await wait("CmdZ must undo page typing") { await js(web, "document.getElementById('field').value") as? String == "" }
        try require(f.board.objects[object.id]?.frame == moved, "page CmdZ must not undo the board move")
        post([key(6, "z", flags: [.command, .shift], in: f.window)])
        try await wait("Shift-CmdZ must redo page typing") { await js(web, "document.getElementById('field').value") as? String == "typed" }
        try require(f.board.objects[object.id]?.frame == moved && f.canvas.focusedTile == object.id,
            "page redo must preserve board position and typing owner")
    }

    private static func exerciseNoteCaret(_ f: Fixture, styled: Bool = false) async throws {
        let object = try await f.create(.note)
        let renderedText = styled ? "First paragraph and second text." : "First paragraph."
        if styled {
            _ = try f.board.update(object.id, props: .object(["markdown": "First **paragraph** and _second_ text.\n"]))
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
        click(point, in: f.window)
        try await wait("one prose click must begin note editing") {
            (f.window.firstResponder as? NSTextView)?.isEditable == true && f.canvas.focusedTile == object.id
        }
        guard let editor = f.window.firstResponder as? NSTextView else { throw Failure("note has no native editor") }
        typed("CLICK", in: f.window)
        let expected = styled ? "First **CLICKparagraph** and _second_ text.\n" : "First CLICKparagraph.\n\nSecond paragraph.\n"
        try require(editor.string == expected, "native click must insert inside the first paragraph, immediately before the clicked word")
        post([key(36, "\r", flags: .command, in: f.window)])
        try await wait("saved markdown must retain the native click's exact insertion position") {
            f.board.objects[object.id]?.props["markdown"]?.string == expected
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
        post([mouse(.leftMouseDown, point, in: f.window)])
        try require(f.canvas.selection == [html.id] && f.canvas.focusedTile == html.id,
            "HTML mouse-down must synchronously move selection and typing away from the terminal")
        post([mouse(.leftMouseUp, point, in: f.window), key(0, "x", in: f.window)])
        try await wait("the delayed native page click must finish") {
            await js(web, "window.clickFinished === true && \(field ? "document.activeElement?.id === 'second'" : "true")") as? Bool == true
        }
        try require(f.read(terminal.id) == before, "an HTML click must not leak its immediate key to the previous terminal")
        typed("y", in: f.window)
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
        post([mouse(.leftMouseDown, point, in: f.window)])
        try require(f.canvas.focusedTile == html.id, "a native HTML link mouse-down must synchronously take typing from the terminal")
        post([mouse(.leftMouseUp, point, in: f.window)])
        try await wait("the native HTML object link must select its destination") { f.canvas.selection == [target.id] }
        try require(f.canvas.focusedTile == html.id, "goTo destination selection must leave typing in the clicked HTML tile")
        typed("x", in: f.window)
        try await Task.sleep(for: .milliseconds(200))
        try require(f.read(terminal.id) == before, "typing after an HTML object link must never return to the previous terminal")
        try require(f.canvas.selection == [target.id] && f.canvas.focusedTile == html.id,
            "the destination must retain its selection ring while the source HTML retains typing")
    }

    private static func exerciseBoardUndo(_ f: Fixture) async throws {
        let object = try await f.create(.note)
        let moved = Frame(x: object.frame.x + 30, y: object.frame.y + 20, w: object.frame.w, h: object.frame.h)
        _ = try f.board.update(object.id, frame: moved)
        f.window.makeFirstResponder(f.canvas.document)
        post([key(6, "z", flags: .command, in: f.window)])
        try await wait("native CmdZ must reach the app's board undo menu route") { f.board.objects[object.id]?.frame == object.frame }
        post([key(6, "z", flags: [.command, .shift], in: f.window)])
        try await wait("native Shift-CmdZ must reach the app's board redo menu route") { f.board.objects[object.id]?.frame == moved }
    }

    private static func run(_ name: String, _ f: Fixture) async throws {
        for action in ["click", "title", "reentry", "cmd-escape"] {
            if name.hasPrefix(action + "-"), let type = ObjectType(rawValue: String(name.dropFirst(action.count + 1))) {
                try await exerciseClick(action, type, f)
                return
            }
        }
        if name.hasPrefix("preserve-") {
            let suffix = String(name.dropFirst("preserve-".count))
            guard let dash = suffix.firstIndex(of: "-"), let owner = ObjectType(rawValue: String(suffix[..<dash])) else { throw Failure("invalid owner scenario") }
            try await exercisePreservation(owner, route: String(suffix[suffix.index(after: dash)...]), f)
        } else if name == "terminal-literal-escape" {
            try await exerciseLiteralEscape(f)
        } else if name == "note-click-caret" {
            try await exerciseNoteCaret(f)
        } else if name == "note-styled-click-caret" {
            try await exerciseNoteCaret(f, styled: true)
        } else if name == "html-immediate-key" {
            try await exerciseImmediateHTMLKey(f)
        } else if name == "html-immediate-field-key" {
            try await exerciseImmediateHTMLKey(f, field: true)
        } else if name == "html-click-go-to" {
            try await exerciseClickedHTMLGoTo(f)
        } else if name == "board-undo-redo" {
            try await exerciseBoardUndo(f)
        } else if name == "keyboard-tab-note" {
            let terminal = try await f.create(.terminal, x: 20, y: 110, width: 340, height: 230)
            let note = try await f.create(.note, x: 470, y: 110, width: 340, height: 230)
            f.canvas.setSelection([terminal.id])
            try f.boardOwns([terminal.id])
            post([key(48, "\t", in: f.window)])
            try await assertInput(note, in: f)
        } else if name == "keyboard-neighbor-note" {
            let terminal = try await f.create(.terminal, x: 20, y: 110, width: 340, height: 230)
            let note = try await f.create(.note, x: 470, y: 110, width: 340, height: 230)
            try await enter(terminal, in: f)
            post([key(124, "\u{f703}", flags: [.command, .option], in: f.window)])
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
