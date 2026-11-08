import AppKit
import WebKit
import CanvasCore
@testable import CanvasApp

extension BrowserInitialAdmission {
    // DevInput replay does not model native Command-key equivalents; these cases use HID.
    private enum UndoCase: String, CaseIterable { case textarea, script, batch, bindings }

    private static func observe(_ web: WKWebView, _ label: String) async {
        let state = try? await web.evaluateJavaScript("JSON.stringify({value:field.value,keys:window.keys,releases:window.releases,history:window.historyEvents,undos:window.undos,redos:window.redos})")
        emit("OBS \(label) \(state as? String ?? "unavailable")")
    }

    private static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(12)
        while !(await condition()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private static func activate(_ window: CanvasWindow) async throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await until("HID requires the active owned test window and Post Event access") {
            NSApp.isActive && window.isKeyWindow && CGPreflightPostEventAccess()
        }
    }

    private static func press(_ name: String, flags: NSEvent.ModifierFlags = [],
                              in window: CanvasWindow) async throws {
        guard let key = DevInput.Key(name) else { throw WheelFailure(description: "unknown fixture key \(name)") }
        var observed = false
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp, handler: { event in
            MainActor.assumeIsolated {
                if event.windowNumber == window.windowNumber && event.keyCode == key.code { observed = true }
            }
            return event
        }) else { throw WheelFailure(description: "cannot observe native key release") }
        defer { NSEvent.removeMonitor(monitor) }
        try expect(window.isKeyWindow && NSApp.isActive, "HID key must target the active owned window")
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw WheelFailure(description: "cannot create HID event source")
        }
        let modifiers: [(CGKeyCode, NSEvent.ModifierFlags)] = [(55, .command), (56, .shift), (58, .option), (59, .control)]
        func post(_ code: CGKeyCode, down: Bool, modifiers: NSEvent.ModifierFlags) throws {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
                throw WheelFailure(description: "cannot create HID keyboard event")
            }
            event.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
            event.post(tap: .cghidEventTap)
        }
        var held: NSEvent.ModifierFlags = []
        defer {
            for (code, modifier) in modifiers.reversed() where held.contains(modifier) {
                held.remove(modifier)
                try? post(code, down: false, modifiers: held)
            }
        }
        for (code, modifier) in modifiers where flags.contains(modifier) {
            held.insert(modifier)
            try post(code, down: true, modifiers: held)
        }
        try post(key.code, down: true, modifiers: flags)
        try post(key.code, down: false, modifiers: flags)
        for (code, modifier) in modifiers.reversed() where flags.contains(modifier) {
            held.remove(modifier)
            try post(code, down: false, modifiers: held)
        }
        try await until("HID must deliver key-up for \(name) to the owned window") { observed }
        await MainTurns.next()
    }

    private static func viewer(_ fixture: WheelFixture, object: CanvasObject, root: URL) async throws -> (CanvasWindowController, RemoteBrowserTile) {
        let host = RemoteHost(name: "undo-fixture", sshTarget: "undo-fixture.invalid", socketPath: fixture.path,
                              tmpdir: root.path, easlBin: "easl", server: .app)
        let mirror = BoardMirror(hostName: host.name, board: fixture.board.id,
                                 connection: EaslConnection(.unixSocket(fixture.path)),
                                 diagrams: EaslConnection(.unixSocket(fixture.path)))
        fixture.mirror = mirror
        let board = try await mirror.load()
        let window = CanvasWindow(contentRect: NSRect(x: 50, y: 50, width: 1000, height: 750),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        fixture.viewerWindow = window
        let controller = CanvasWindowController(window: window, board: board, registry: fixture.registry,
                                                viewport: nil, composerState: ComposerState(),
                                                remote: RemoteSource(host: host, mirror: mirror))
        fixture.controller = controller
        controller.isBoardOpen = true
        board.onEvent = { [weak controller] in controller?.apply($0) }
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        controller.canvas.show(Viewport(rect: Frame(x: -100, y: -100, w: 1000, h: 750), zoom: 1))
        guard let tile = controller.canvas.tiles[object.id]?.content as? RemoteBrowserTile else {
            throw WheelFailure(description: "viewer must contain the production RemoteBrowserTile")
        }
        try await until("viewer must acknowledge the real drawing surface") {
            tile.hasOpenStream && fixture.acknowledgements > 0
        }
        controller.canvas.setSelection([object.id], cause: .boardGesture)
        try expect(window.makeFirstResponder(tile), "remote page must own typing")
        return (controller, tile)
    }

    private static func page(_ fixture: WheelFixture, root: URL, scriptUndo: Bool) async throws -> (CanvasObject, WKWebView) {
        let file = root.appendingPathComponent("page.html")
        try """
        <!doctype html><meta charset="utf-8"><title>undo-ready</title>
        <textarea id="field" autofocus></textarea>
        <script>
        window.keys = []; window.releases = []; window.historyEvents = []; window.undos = 0; window.redos = 0;
        field.addEventListener('input', event => historyEvents.push(event.inputType));
        field.addEventListener('keydown', event => {
          keys.push({key:event.key,meta:event.metaKey,shift:event.shiftKey,alt:event.altKey});
          if (\(scriptUndo ? "true" : "false") && event.metaKey && !event.altKey && !event.ctrlKey && event.key.toLowerCase() === 'z') {
            event.preventDefault();
            if (event.shiftKey) ++window.redos; else ++window.undos;
          }
        });
        field.addEventListener('keyup', event => releases.push({key:event.key,meta:event.metaKey,shift:event.shiftKey,alt:event.altKey}));
        </script>
        """.write(to: file, atomically: true, encoding: .utf8)
        let object = fixture.board.create(type: .browser, props: .object(["url": .string(file.absoluteString)]),
                                          frame: Frame(x: 30, y: 30, w: 600, h: 500))
        guard let tile = fixture.hostCanvas.tiles[object.id]?.content as? BrowserTile,
              let controller = fixture.hostController, let window = fixture.hostWindow as? CanvasWindow else {
            throw WheelFailure(description: "direct control requires a real BrowserTile and CanvasWindowController")
        }
        await tile.markDriven()
        try await until("drawing page must load") { tile.webView?.isLoading == false && tile.webView?.title == "undo-ready" }
        guard let web = tile.webView else { throw WheelFailure(description: "drawing page disappeared") }
        controller.canvas.setSelection([object.id], cause: .boardGesture)
        try expect(window.makeFirstResponder(web), "drawing page must own native typing")
        let focused = await pageMatches(web, "field.focus(); document.activeElement === field")
        try expect(focused, "native seed must target the textarea")
        try await activate(window)
        do {
            try await press("u", in: window)
            try await until("native u must create drawing-page text and undo history") {
                await pageMatches(web, "field.value === 'u'") && web.undoManager?.canUndo == true
            }
        } catch {
            await observe(web, "seed-hid-failure")
            throw error
        }
        await observe(web, "seed-hid")
        return (object, web)
    }

    private static func undoCase(_ test: UndoCase, remote: Bool, root: URL) async throws {
        let label = "\(remote ? "relay" : "direct")-\(test.rawValue)-hid"
        let directory = root.appendingPathComponent(label)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try await WheelFixture(root: directory, mode: .current, editing: true)
        defer { fixture.close() }
        AppShortcuts.configure(KeyboardShortcuts())
        let (object, web) = try await page(fixture, root: directory, scriptUndo: test == .script)
        var controller = fixture.hostController!
        var remoteTile: RemoteBrowserTile?
        if remote {
            let pair = try await viewer(fixture, object: object, root: directory)
            controller = pair.0
            remoteTile = pair.1
        }
        guard let window = controller.window as? CanvasWindow else { throw WheelFailure(description: "fixture lost its CanvasWindow") }
        try await activate(window)
        let stream = fixture.streams.last?.id
        var passed = true
        if test == .script {
            try await press("z", flags: .command, in: window)
            let undo = await eventually { await pageMatches(web, "undos === 1 && field.value === 'u'") }
            await observe(web, label + "-undo")
            try await press("z", flags: [.command, .shift], in: window)
            let redo = await eventually { await pageMatches(web, "undos === 1 && redos === 1 && field.value === 'u' && !historyEvents.includes('historyUndo') && !historyEvents.includes('historyRedo')") }
            await observe(web, label + "-redo")
            passed = undo && redo
        } else {
            try await press("a", flags: .command, in: window)
            try await until("Select All must select the native seed") { await pageMatches(web, "field.selectionStart === 0 && field.selectionEnd === 1") }
            if test == .batch && remote { fixture.holdNextReply = true }
            try await press(test == .batch ? "a" : "v", in: window)
            try await until("replacement must reach the native field") { await pageMatches(web, "field.value === '\(test == .batch ? "a" : "v")'") }
            if test == .batch && remote { try await until("prime input reply must be held") { fixture.heldReply != nil } }
            var undoFlags: NSEvent.ModifierFlags = .command
            if test == .bindings {
                var shortcuts = KeyboardShortcuts()
                try shortcuts.set(ShortcutBinding(key: "z", modifiers: [.command, .option]), for: "undoCanvas")
                try shortcuts.set(ShortcutBinding(key: "z"), for: "zoomToFit")
                AppShortcuts.configure(shortcuts)
                controller.canvas.show(Viewport(rect: Frame(x: -500, y: -400, w: 1250, h: 937.5), zoom: 0.8))
                let before = controller.canvas.viewport
                try await press("z", flags: .command, in: window)
                let navigated = await eventually { controller.canvas.viewport != before }
                let untouched = await pageMatches(web, "field.value === 'v'")
                passed = navigated && untouched
                emit("BINDING \(label) navigated=\(navigated) text_unchanged=\(untouched)")
                controller.canvas.setSelection([object.id], cause: .boardGesture)
                if let remoteTile { window.makeFirstResponder(remoteTile) }
                else { window.makeFirstResponder(web) }
                undoFlags = [.command, .option]
            }
            if test == .batch { try await press("b", in: window) }
            try await press("z", flags: undoFlags, in: window)
            if test == .batch && remote {
                fixture.heldReply?.resume()
                fixture.heldReply = nil
                try await until("queued typing must leave the held request") {
                    fixture.inputBatches.contains { batch in batch.contains { $0["kind"]?.string == "key" && $0["plain"]?.string == "b" } }
                }
                let together = fixture.inputBatches.contains { batch in
                    batch.contains { $0["kind"]?.string == "key" && $0["action"]?.string == "down" && $0["plain"]?.string == "b" }
                    && batch.contains { $0["kind"]?.string == "key" && $0["action"]?.string == "down" && $0["code"]?.int == 6 && ($0["mods"]?.int ?? 0) & Int(NSEvent.ModifierFlags.command.rawValue) != 0 }
                }
                let bytes = try JSONEncoder().encode(fixture.inputBatches)
                emit("BATCH \(label) together=\(together) \(String(decoding: bytes, as: UTF8.self))")
                passed = passed && together
            }
            let undo = await eventually { await pageMatches(web, "field.value === 'u' && historyEvents.includes('historyUndo')") }
            await observe(web, label + "-undo")
            try await press("z", flags: [.command, .shift], in: window)
            let restored = test == .batch ? "ab" : "v"
            let redo = await eventually { await pageMatches(web, "field.value === '\(restored)' && historyEvents.includes('historyRedo')") }
            await observe(web, label + "-redo")
            passed = passed && undo && redo
        }
        if remote {
            try expect(fixture.errors.isEmpty && remoteTile?.hasOpenStream == true && fixture.streams.last?.id == stream,
                       "\(label) must keep its stream without protocol errors: \(fixture.errors)")
            try await press("x", in: window)
            try await until("\(label) must accept later ordinary typing") { await pageMatches(web, "field.value.endsWith('x')") }
        }
        try expect(fixture.board.objects[object.id]?.frame == object.frame && controller.board.objects[object.id]?.frame == object.frame,
                   "\(label) must not undo a board object")
        try expect(passed, "\(label) must match page-owned undo, redo and configured navigation")
        emit("PASS \(label)")
    }


    static func remoteUndo(root: URL) async throws {
        guard let phase = ProcessInfo.processInfo.environment["EASL_UNDO_PHASE"] else {
            throw WheelFailure(description: "runner must name the undo phase")
        }
        let oldMenu = NSApp.mainMenu
        let oldDelegate = NSApp.delegate
        let shortcuts = AppShortcuts.current
        let delegate = AppDelegate()
        NSApp.delegate = delegate
        NSApp.mainMenu = AppDelegate.makeMenu()
        defer {
            withExtendedLifetime(delegate) {}
            AppShortcuts.configure(shortcuts)
            NSApp.mainMenu = oldMenu
            NSApp.delegate = oldDelegate
        }
        emit("ROUTE hid CGEvent cghidEventTap, active key window phase=\(phase)")
        try expect(phase == "direct" || phase == "relay", "unknown undo phase")
        var failures: [String] = []
        for test in UndoCase.allCases {
            do { try await undoCase(test, remote: phase == "relay", root: root) }
            catch {
                emit("FAIL \(phase)-\(test.rawValue)-hid: \(error)")
                failures.append(test.rawValue)
            }
        }
        try expect(failures.isEmpty, "\(phase) HID failed cases: \(failures.joined(separator: ","))")
    }
}
