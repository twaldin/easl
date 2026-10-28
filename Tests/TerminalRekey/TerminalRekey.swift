import AppKit

@testable import CanvasApp
@testable import CanvasCore

@main
@MainActor
private enum TerminalRekey {
    private struct Failure: Error { let message: String }
    private enum Owner: String, CaseIterable {
        case terminal, composer, otherTile, otherWindow, movedBeforeInitialFocus
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
            throw Failure(message: message)
        }
    }

    private static func turn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func terminal(_ canvas: CanvasView, _ id: ObjectID) throws -> TerminalTile {
        guard let terminal = canvas.tiles[id]?.content as? TerminalTile else {
            throw Failure(message: "missing terminal \(id)")
        }
        return terminal
    }

    static func main() {
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"] else {
            fatalError("run.py must provide a disposable EASL_HOME")
        }
        setenv("EASL_DEV_INPUT", "1", 1)
        _ = CanvasApplication.shared
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        Task { @MainActor in
            do {
                try require(app is CanvasApplication, "replay fixture must use the real application dispatch")
                let ghostty = URL(fileURLWithPath: home).appendingPathComponent("ghostty")
                try FileManager.default.createDirectory(at: ghostty, withIntermediateDirectories: true)
                try "keybind = super+d=new_split:right\nkeybind = super+shift+d=close_surface\nkeybind = alt+d=new_split:right\n"
                    .write(to: ghostty.appendingPathComponent("config"), atomically: true, encoding: .utf8)
                for owner in Owner.allCases {
                    try await exercise(owner, root: URL(fileURLWithPath: home).appendingPathComponent(owner.rawValue))
                }
                try await exerciseKeys(root: URL(fileURLWithPath: home).appendingPathComponent("keys"))
                try await exerciseCanonicalKeys(root: URL(fileURLWithPath: home).appendingPathComponent("canonical-keys"))
                print("PASS terminal rekey: synchronous keyboard ownership, selection, and no focus theft")
                try "PASS".write(toFile: home + "/result", atomically: true, encoding: .utf8)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
                try? "FAIL \(error)".write(toFile: home + "/result", atomically: true, encoding: .utf8)
                exit(1)
            }
        }
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    private static func exercise(_ owner: Owner, root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = RemoteHost(name: "terminal-rekey", sshTarget: "terminal-rekey.invalid",
                              socketPath: root.appendingPathComponent("absent.sock").path,
                              tmpdir: root.path, easlBin: "easl")
        let mirror = BoardMirror(hostName: host.name, board: "terminal-rekey-\(owner.rawValue)",
                                 connection: EaslConnection(.unixSocket(host.socketPath)),
                                 diagrams: EaslConnection(.unixSocket(host.socketPath)))
        let remote = RemoteSource(host: host, mirror: mirror)
        let board = Board(remote: "terminal-rekey-\(owner.rawValue)", root: root, host: mirror)
        let canvas = CanvasView(board: board, viewport: nil, remote: remote)
        let window = CanvasWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        board.onEvent = { canvas.apply($0) }
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        window.contentView!.addSubview(composer)
        let otherWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 200),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        let otherEditor = NSTextView(frame: otherWindow.contentView!.bounds)
        otherWindow.contentView!.addSubview(otherEditor)
        defer {
            board.onEvent = nil
            mirror.close()
            canvas.discard()
            otherWindow.close()
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<100 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(NSApp.isActive && window.isKeyWindow,
                    "fixture must be active and key: active=\(NSApp.isActive) key=\(window.isKeyWindow)")
        let frame = Frame(x: -350, y: -200, w: 700, h: 400)
        canvas.show(Viewport(rect: Frame(x: -450, y: -300, w: 900, h: 600), zoom: 1))
        let provisional = board.create(type: .terminal, props: .object([:]), frame: frame)
        let first = try terminal(canvas, provisional.id)
        try require(window.makeFirstResponder(canvas.document), "canvas must initially own keyboard")
        canvas.showNew(provisional)
        if owner != .movedBeforeInitialFocus {
            await turn()
            try require(window.firstResponder === first.terminal, "user flow must focus provisional terminal")
            try require(canvas.tiles[provisional.id]?.isLive == true, "fixture terminal must remain live in the viewport")
        }

        let expected: NSResponder
        switch owner {
        case .terminal:
            expected = first.terminal
        case .composer, .movedBeforeInitialFocus:
            try require(window.makeFirstResponder(composer), "composer must take keyboard")
            expected = composer
        case .otherTile:
            let other = board.create(type: .terminal, props: .object([:]), frame: frame)
            let tile = try terminal(canvas, other.id)
            tile.focus()
            expected = tile.terminal
        case .otherWindow:
            otherWindow.makeKeyAndOrderFront(nil)
            try require(otherWindow.makeFirstResponder(otherEditor), "other window editor must take keyboard")
            try require(otherWindow.isKeyWindow && !window.isKeyWindow, "other window must be key")
            expected = first.terminal
        }
        try require(canvas.selection == [provisional.id], "selection must remain provisional before rekey")
        if owner == .movedBeforeInitialFocus {
            await turn()
            try require(window.firstResponder === composer,
                        "deferred initial takeKeyboard must respect focus moved to composer before rekey")
        }
        var canonical = provisional
        canonical.id = "canonical-\(owner.rawValue)"
        canonical.rev += 1
        board.rekeyHost(provisional.id, as: canonical)
        let replacement = try terminal(canvas, canonical.id)
        try require(canvas.selection == [canonical.id], "\(owner.rawValue): selection must follow canonical id")
        try require(canvas.tiles[provisional.id] == nil, "provisional tile must be removed")
        if owner == .terminal {
            try require(window.firstResponder === replacement.terminal,
                        "canonical terminal must own keyboard synchronously when rekey returns")
        } else if owner == .otherWindow {
            try require(otherWindow.isKeyWindow && otherWindow.firstResponder === otherEditor,
                        "rekey must not take keyboard from another key window")
            try require(window.firstResponder !== replacement.terminal,
                        "inactive terminal window must not acquire canonical focus")
        } else {
            try require(window.firstResponder === expected, "\(owner.rawValue): rekey must preserve keyboard owner")
        }
        await turn()
        await turn()
        if owner == .terminal {
            try require(window.firstResponder === replacement.terminal, "canonical focus must survive queued work")
        } else if owner == .otherWindow {
            try require(otherWindow.isKeyWindow && otherWindow.firstResponder === otherEditor,
                        "queued work must not steal another window's focus")
        } else {
            try require(window.firstResponder === expected, "\(owner.rawValue): deferred initial focus must not steal keyboard")
        }
        if owner == .composer || owner == .movedBeforeInitialFocus || owner == .otherWindow {
            let targetWindow = owner == .otherWindow ? otherWindow : window
            let editor = owner == .otherWindow ? otherEditor : composer
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: targetWindow.windowNumber, context: nil,
                                         characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
            NSApp.sendEvent(event)
            try require(editor.string == "x", "\(owner.rawValue): key must route to the existing editor")
        }
        print("CHECK \(owner.rawValue)")
    }

    private static func exerciseKeys(root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = RemoteHost(name: "terminal-keys", sshTarget: "terminal-keys.invalid",
                              socketPath: root.appendingPathComponent("absent.sock").path,
                              tmpdir: root.path, easlBin: "easl")
        let mirror = BoardMirror(hostName: host.name, board: "terminal-keys",
                                 connection: EaslConnection(.unixSocket(host.socketPath)),
                                 diagrams: EaslConnection(.unixSocket(host.socketPath)))
        let remote = RemoteSource(host: host, mirror: mirror)
        let board = Board(remote: "terminal-keys", root: root, host: mirror)
        let window = CanvasWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let registry = BoardRegistry(store: BoardStore(directory: root.appendingPathComponent("boards")))
        let controller = CanvasWindowController(window: window, board: board, registry: registry,
                                                viewport: nil, composerState: ComposerState(), remote: remote)
        let canvas = controller.canvas
        board.onEvent = { canvas.apply($0) }
        let previousMenu = NSApp.mainMenu
        let previousShortcuts = AppShortcuts.current
        NSApp.mainMenu = AppDelegate.makeMenu()
        AppShortcuts.configure(KeyboardShortcuts())
        defer {
            NSApp.mainMenu = previousMenu
            AppShortcuts.configure(previousShortcuts)
            board.onEvent = nil
            mirror.close()
            canvas.discard()
            window.close()
            withExtendedLifetime(controller) {}
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<100 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(window.isKeyWindow, "key-routing fixture must have the key window")
        canvas.show(Viewport(rect: Frame(x: -450, y: -300, w: 900, h: 600), zoom: 1))
        let provisional = board.create(type: .terminal, props: .object([:]),
                                       frame: Frame(x: -350, y: -200, w: 700, h: 400))
        let first = try terminal(canvas, provisional.id)
        canvas.showNew(provisional)
        await turn()
        try require(window.firstResponder === first.terminal, "key-routing fixture must focus terminal")
        func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: characters, charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: code)!
            NSApp.sendEvent(event)
        }
        func hideNotice() {
            canvas.subviews.compactMap { $0 as? NoticePill }.forEach { $0.isHidden = true }
        }
        func refusalVisible() -> Bool {
            guard let pill = canvas.subviews.compactMap({ $0 as? NoticePill }).first,
                  !pill.isHidden, pill.alphaValue == 1 else { return false }
            return pill.subviews.compactMap { $0 as? NSTextField }.first?.stringValue ==
                "Terminal not ready. Nothing typed; try again after it starts."
        }
        let objects = board.objects
        let selection = canvas.selection
        func refuse(_ name: String, _ characters: String, _ code: UInt16,
                    _ flags: NSEvent.ModifierFlags) throws {
            hideNotice()
            key(characters, code, flags)
            try require(board.objects == objects && canvas.selection == selection,
                        "\(name): refused key must not mutate board or selection")
            try require(window.firstResponder === first.terminal,
                        "\(name): refused key must keep terminal keyboard ownership")
            try require(refusalVisible(), "\(name): refusal must visibly explain that nothing was typed")
        }
        try refuse("Escape", "\u{1b}", 53, [])
        try refuse("Command-V", "v", 9, .command)
        try refuse("typing", "x", 7, [])
        try refuse("Return", "\r", 36, [])
        let background = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 300, height: 200),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        background.isReleasedWhenClosed = false
        defer { background.close() }
        background.makeKeyAndOrderFront(nil)
        try require(background.isKeyWindow && !window.isKeyWindow, "replay target must not be the key window")
        try refuse("background Escape", "\u{1b}", 53, [])
        try refuse("background Command-V", "v", 9, .command)
        try refuse("background typing", "x", 7, [])
        window.makeKeyAndOrderFront(nil)
        background.close()
        var custom = KeyboardShortcuts()
        try custom.set(ShortcutBinding(key: "v", modifiers: .control), for: "paste")
        try custom.set(ShortcutBinding(key: "r", modifiers: .option), for: "rectangleTool")
        try custom.set(ShortcutBinding(key: "=", modifiers: .control), for: "zoomIn")
        AppShortcuts.configure(custom)
        try refuse("custom paste", "v", 9, .control)
        try refuse("custom drawing", "r", 15, .option)
        try refuse("non-Command Ghostty remap", "d", 2, .option)
        var customUndo = custom
        try customUndo.set(ShortcutBinding(key: "z", modifiers: .control), for: "undoCanvas")
        try customUndo.set(ShortcutBinding(key: "z", modifiers: [.control, .shift]), for: "redoCanvas")
        AppShortcuts.configure(customUndo)
        try refuse("custom undo", "z", 6, .control)
        try refuse("custom redo", "z", 6, [.control, .shift])
        AppShortcuts.configure(custom)
        canvas.zoom(to: 0.5)
        let zoom = canvas.viewport.zoom
        hideNotice()
        key("=", 24, .control)
        try require(canvas.viewport.zoom > zoom && !refusalVisible(), "custom non-Command Zoom In must still zoom: before=\(zoom) after=\(canvas.viewport.zoom) refused=\(refusalVisible())")
        hideNotice()
        key("z", 6, .command)
        try require(!refusalVisible(), "Command-Z must retain existing undo routing")
        hideNotice()
        key("m", 46, .command)
        for _ in 0..<100 {
            if window.isMiniaturized { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(window.isMiniaturized && !refusalVisible(), "Command-M must still minimize the window: minimized=\(window.isMiniaturized) refused=\(refusalVisible())")
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        let neighbor = board.create(type: .terminal, props: .object([:]),
                                    frame: Frame(x: 500, y: -200, w: 700, h: 400))
        canvas.showNew(provisional)
        key("\u{f703}", 124, [.command, .option])
        try require(canvas.selection == [neighbor.id], "Command-Option-Right must still navigate to the neighboring tile")
        canvas.showNew(provisional)
        hideNotice()
        key("\u{1b}", 53, .command)
        try require(window.firstResponder === canvas.document && !refusalVisible(),
                    "Command-Escape must leave the provisional terminal without a refusal")
        canvas.showNew(provisional)
        hideNotice()
        key("w", 13, .command)
        try require(window.attachedSheet != nil && !refusalVisible(),
                    "Command-W must still offer the terminal close confirmation")
        if let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            sheet.orderOut(nil)
        }
        await turn()
        canvas.showNew(provisional)
        guard let pending = canvas.focusedTerminal, let object = board.objects[pending] else {
            throw Failure(message: "canonical control requires a focused provisional terminal")
        }
        var canonical = object
        canonical.id = "canonical-keys"
        canonical.rev += 1
        hideNotice()
        controller.focusComposer(nil)
        guard let editor = window.firstResponder as? ComposerTextView else {
            throw Failure(message: "real composer control must own keyboard")
        }
        key("x", 7, [])
        try require(editor.string == "x" && !refusalVisible(), "composer typing must remain available")
        board.rekeyHost(pending, as: canonical)
        await turn()
        await turn()
        try require(window.firstResponder === editor && editor.string == "x",
                    "refused keys must not replay into the composer after canonical replacement")
        key("x", 7, [])
        try require(editor.string == "xx", "composer must keep accepting keys after canonical replacement")
        canvas.showNew(neighbor)
        hideNotice()
        let priorIDs = Set(board.objects.keys)
        key("d", 2, .command)
        let created = Set(board.objects.keys).subtracting(priorIDs)
        try require(created.count == 1 && created.first.flatMap { board.objects[$0]?.type } == .terminal &&
                    canvas.selection == created && canvas.focusedTerminal == created.first && !refusalVisible(),
                    "Ghostty New Terminal remap must create and focus one provisional terminal")
        key("d", 2, [.command, .shift])
        guard let closeSheet = window.attachedSheet else {
            throw Failure(message: "Ghostty Close Terminal remap must offer the close confirmation")
        }
        try require(!refusalVisible(), "Ghostty Close Terminal remap must not show a provisional refusal")
        window.endSheet(closeSheet, returnCode: .alertSecondButtonReturn)
        closeSheet.orderOut(nil)
        for _ in 0..<100 {
            if Set(board.objects.keys) == priorIDs { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(Set(board.objects.keys) == priorIDs && created.allSatisfy { canvas.tiles[$0] == nil } && !refusalVisible(),
                    "Ghostty Close Terminal remap must remove only the newly focused terminal")
        print("CHECK provisional refusal, application commands, canonical terminal, and composer")
    }

    private static func exerciseCanonicalKeys(root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = BoardRegistry(store: BoardStore(directory: root.appendingPathComponent("boards")))
        let hostBoard = try await registry.open(root: root)
        let object = hostBoard.create(type: .terminal, props: .object([:]),
                                      frame: Frame(x: -350, y: -200, w: 700, h: 400))
        let router = ApiRouter(registry: registry)
        let socketDirectory = URL(fileURLWithPath: "/tmp").appendingPathComponent("easl-rk-\(UUID().uuidString.prefix(12))")
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: socketDirectory) }
        let socket = socketDirectory.appendingPathComponent("s").path
        let server = SocketServer(path: socket) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
        defer { server.stop() }
        let host = RemoteHost(name: "canonical-keys", sshTarget: "canonical-keys.invalid",
                              socketPath: socket, tmpdir: root.path, easlBin: "easl")
        let mirror = BoardMirror(hostName: host.name, board: hostBoard.id,
                                 connection: EaslConnection(.unixSocket(socket)),
                                 diagrams: EaslConnection(.unixSocket(socket)))
        defer { mirror.close() }
        let board = try await mirror.load()
        try require(!mirror.isProvisional(object.id), "canonical control must use a host-confirmed identity")
        let canvas = CanvasView(board: board, viewport: nil, remote: RemoteSource(host: host, mirror: mirror))
        let window = CanvasWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        defer {
            canvas.discard()
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        canvas.show(Viewport(rect: Frame(x: -450, y: -300, w: 900, h: 600), zoom: 1))
        canvas.showNew(object)
        await turn()
        let tile = try terminal(canvas, object.id)
        try require(window.firstResponder === tile.terminal, "canonical control must focus the terminal")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil,
                                     characters: "x", charactersIgnoringModifiers: "x",
                                     isARepeat: false, keyCode: 7)!
        NSApp.sendEvent(event)
        let refused = canvas.subviews.compactMap { $0 as? NoticePill }.contains { pill in
            !pill.isHidden && pill.subviews.compactMap { $0 as? NSTextField }.contains {
                $0.stringValue == "Terminal not ready. Nothing typed; try again after it starts."
            }
        }
        try require(!refused && window.firstResponder === tile.terminal,
                    "host-confirmed terminal input must bypass provisional refusal without canvas focus changes")
        print("CHECK host-confirmed terminal input routing")
    }
}
