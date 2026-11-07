import AppKit
import WebKit
import ObjectiveC
import CanvasCore
@testable import CanvasApp

extension BrowserInitialAdmission {
    private enum UndoRoute: String { case hid, replay }
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

    private static func activate(_ window: CanvasWindow, route: UndoRoute) async throws {
        if route == .hid {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await until("HID requires the active owned test window and Post Event access") {
                NSApp.isActive && window.isKeyWindow && CGPreflightPostEventAccess()
            }
        } else {
            window.orderFrontRegardless()
            try expect(DevInput.enabled && !window.isKeyWindow,
                       "replay must exercise the non-key-window CanvasApplication route")
        }
    }

    private static func press(_ name: String, flags: NSEvent.ModifierFlags = [],
                              in window: CanvasWindow, route: UndoRoute) async throws {
        guard let key = DevInput.Key(name) else { throw WheelFailure(description: "unknown fixture key \(name)") }
        if route == .replay {
            let names: [(NSEvent.ModifierFlags, String)] = [(.command, "cmd"), (.shift, "shift"), (.option, "opt"), (.control, "ctrl")]
            let mods = names.filter { flags.contains($0.0) }.map(\.1).joined(separator: "+")
            emit("REPLAY_ENQUEUE window=\(window.windowNumber) key=\(name) code=\(key.code) mods=\(mods)")
            DevInput.replay(["pid": String(getpid()), "kind": "key", "window": String(window.windowNumber),
                             "key": name, "mods": mods])
            try await SurfaceEventQueue.run {
                emit("REPLAY_RECEIPT window=\(window.windowNumber) code=\(key.code) down/up queue checkpoint responder=\(String(describing: window.firstResponder))")
            }
            await MainTurns.next()
            return
        }
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
        try await until("\(route.rawValue) must deliver key-up for \(name) to the owned window") { observed }
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

    private static func page(_ fixture: WheelFixture, root: URL, scriptUndo: Bool, route: UndoRoute) async throws -> (CanvasObject, WKWebView) {
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
        try await activate(window, route: route)
        do {
            try await press("u", in: window, route: route)
            try await until("native u must create drawing-page text and undo history") {
                await pageMatches(web, "field.value === 'u'") && web.undoManager?.canUndo == true
            }
        } catch {
            await observe(web, "seed-\(route.rawValue)-failure")
            throw error
        }
        await observe(web, "seed-\(route.rawValue)")
        return (object, web)
    }

    private static func undoCase(_ test: UndoCase, route: UndoRoute, remote: Bool, root: URL) async throws {
        let label = "\(remote ? "relay" : "direct")-\(test.rawValue)-\(route.rawValue)"
        let directory = root.appendingPathComponent(label)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try await WheelFixture(root: directory, mode: .current, editing: true)
        defer { fixture.close() }
        AppShortcuts.configure(KeyboardShortcuts())
        let (object, web) = try await page(fixture, root: directory, scriptUndo: test == .script, route: route)
        var controller = fixture.hostController!
        var remoteTile: RemoteBrowserTile?
        if remote {
            let pair = try await viewer(fixture, object: object, root: directory)
            controller = pair.0
            remoteTile = pair.1
        }
        guard let window = controller.window as? CanvasWindow else { throw WheelFailure(description: "fixture lost its CanvasWindow") }
        try await activate(window, route: route)
        let stream = fixture.streams.last?.id
        var passed = true
        if test == .script {
            try await press("z", flags: .command, in: window, route: route)
            let undo = await eventually { await pageMatches(web, "undos === 1 && field.value === 'u'") }
            await observe(web, label + "-undo")
            try await press("z", flags: [.command, .shift], in: window, route: route)
            let redo = await eventually { await pageMatches(web, "undos === 1 && redos === 1 && field.value === 'u' && !historyEvents.includes('historyUndo') && !historyEvents.includes('historyRedo')") }
            await observe(web, label + "-redo")
            passed = undo && redo
        } else {
            try await press("a", flags: .command, in: window, route: route)
            try await until("Select All must select the native seed") { await pageMatches(web, "field.selectionStart === 0 && field.selectionEnd === 1") }
            if test == .batch && remote { fixture.holdNextReply = true }
            try await press(test == .batch ? "a" : "v", in: window, route: route)
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
                try await press("z", flags: .command, in: window, route: route)
                let navigated = await eventually { controller.canvas.viewport != before }
                let untouched = await pageMatches(web, "field.value === 'v'")
                passed = navigated && untouched
                emit("BINDING \(label) navigated=\(navigated) text_unchanged=\(untouched)")
                controller.canvas.setSelection([object.id], cause: .boardGesture)
                if let remoteTile { window.makeFirstResponder(remoteTile) }
                else { window.makeFirstResponder(web) }
                undoFlags = [.command, .option]
            }
            if test == .batch { try await press("b", in: window, route: route) }
            try await press("z", flags: undoFlags, in: window, route: route)
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
            try await press("z", flags: [.command, .shift], in: window, route: route)
            let restored = test == .batch ? "ab" : "v"
            let redo = await eventually { await pageMatches(web, "field.value === '\(restored)' && historyEvents.includes('historyRedo')") }
            await observe(web, label + "-redo")
            passed = passed && undo && redo
        }
        if remote {
            try expect(fixture.errors.isEmpty && remoteTile?.hasOpenStream == true && fixture.streams.last?.id == stream,
                       "\(label) must keep its stream without protocol errors: \(fixture.errors)")
            try await press("x", in: window, route: route)
            try await until("\(label) must accept later ordinary typing") { await pageMatches(web, "field.value.endsWith('x')") }
        }
        try expect(fixture.board.objects[object.id]?.frame == object.frame && controller.board.objects[object.id]?.frame == object.frame,
                   "\(label) must not undo a board object")
        try expect(passed, "\(label) must match page-owned undo, redo and configured navigation")
        emit("PASS \(label)")
    }

    @MainActor
    private final class UndoProbe {
        var label = ""
        weak var expectedPage: WKWebView?
        private let targets = NSMapTable<NSEvent, WKWebView>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .weakMemory)
        private var replacements: [(Method, IMP, IMP)] = []
        private(set) var records: [JSONValue] = []

        init() throws {
            typealias EventMethod = @convention(c) (AnyObject, Selector, NSEvent) -> Void
            let down = #selector(NSResponder.keyDown(with:))
            guard let keyMethod = class_getInstanceMethod(BrowserWebView.self, down),
                  let appMethod = class_getInstanceMethod(CanvasApplication.self, #selector(NSApplication.sendEvent(_:))) else {
                throw WheelFailure(description: "temporary unhandled-key probe cannot install")
            }
            let originalKey = method_getImplementation(keyMethod)
            let forwardKey = unsafeBitCast(originalKey, to: EventMethod.self)
            let keyBlock: @convention(block) (WKWebView, NSEvent) -> Void = { [self] web, event in
                MainActor.assumeIsolated {
                    if SurfaceEventQueue.isSynthesized(event) {
                        targets.setObject(web, forKey: event)
                        record("drawer.keyDown", event, target: web)
                    }
                    forwardKey(web, down, event)
                }
            }
            let keyIMP = imp_implementationWithBlock(keyBlock)
            replacements.append((keyMethod, originalKey, keyIMP))
            method_setImplementation(keyMethod, keyIMP)
            let selector = #selector(NSApplication.sendEvent(_:))
            let originalApp = method_getImplementation(appMethod)
            let forwardApp = unsafeBitCast(originalApp, to: EventMethod.self)
            let appBlock: @convention(block) (NSApplication, NSEvent) -> Void = { [self] app, event in
                MainActor.assumeIsolated {
                    if event.type == .keyDown, event.keyCode == 6 {
                        let target = targets.object(forKey: event)
                        record(SurfaceEventQueue.consumes(event) ? "drawer.unhandled" : "app.keyDown", event, target: target)
                    }
                    forwardApp(app, selector, event)
                }
            }
            let appIMP = imp_implementationWithBlock(appBlock)
            replacements.append((appMethod, originalApp, appIMP))
            method_setImplementation(appMethod, appIMP)
        }

        private func record(_ phase: String, _ event: NSEvent, target: WKWebView?) {
            let record: JSONValue = .object(["label": .string(label), "phase": .string(phase),
                "code": .number(Double(event.keyCode)), "mods": .number(Double(event.modifierFlags.rawValue)),
                "synthesized": .bool(SurfaceEventQueue.isSynthesized(event)), "target_found": .bool(target != nil),
                "target_matches_expected": .bool(target != nil && target === expectedPage),
                "event": .string(String(describing: ObjectIdentifier(event))),
                "target": .string(target.map { String(describing: ObjectIdentifier($0)) } ?? "none")])
            records.append(record)
            if let bytes = try? JSONEncoder().encode(record) { BrowserInitialAdmission.emit("PROBE \(String(decoding: bytes, as: UTF8.self))") }
        }

        func restore() {
            for (method, original, replacement) in replacements.reversed() {
                method_setImplementation(method, original)
                imp_removeBlock(replacement)
            }
            replacements.removeAll()
        }
    }

    private static func probeUndo(root: URL, route: UndoRoute) async throws {
        let fixture = try await WheelFixture(root: root, mode: .current, editing: true)
        defer { fixture.close() }
        let (object, web) = try await page(fixture, root: root, scriptUndo: false, route: route)
        let (controller, _) = try await viewer(fixture, object: object, root: root)
        guard let window = controller.window as? CanvasWindow else { throw WheelFailure(description: "probe lost viewer window") }
        try await activate(window, route: route)
        try await until("probe must receive the viewer focus before diagnostic input") {
            fixture.inputs.contains { $0["kind"]?.string == "focus" && $0["on"]?.bool == true }
        }
        let probe = try UndoProbe()
        defer { probe.restore() }
        probe.label = "textarea-\(route.rawValue)-viewer"
        probe.expectedPage = web
        try await press("z", flags: .command, in: window, route: route)
        let viewerReturned = await eventually {
            probe.records.contains { $0["phase"]?.string == "drawer.unhandled" && $0["target_matches_expected"]?.bool == true }
        }
        let viewerKeys = fixture.inputs.filter { $0["kind"]?.string == "key" && $0["code"]?.int == 6 }
        let viewerBytes = try JSONEncoder().encode(viewerKeys)
        emit("VIEWER_WIRE \(route.rawValue) returned_unhandled=\(viewerReturned) \(String(decoding: viewerBytes, as: UTF8.self))")
        await observe(web, "probe-\(route.rawValue)-viewer")
        let unchanged = await pageMatches(web, "field.value === 'u'")
        try expect(unchanged, "PREMISE REFUTED: base viewer undo already changed the native field")
        probe.label = "textarea-\(route.rawValue)-wire-diagnostic"
        guard let stream = fixture.streams.last else { throw WheelFailure(description: "probe has no owned drawing stream") }
        let next = (fixture.inputs.compactMap { $0["seq"]?.int }.max() ?? 0) + 1
        let events: [JSONValue] = [true, false].enumerated().map { offset, down in
            .object(["kind": .string("key"), "seq": .number(Double(next + offset)), "action": .string(down ? "down" : "up"),
                     "code": .number(6), "chars": .string("z"), "plain": .string("z"), "mods": .number(Double(NSEvent.ModifierFlags.command.rawValue))])
        }
        emit("PROBE_INJECTION \(route.rawValue) existing owned surface.input boundary; diagnostic bypasses viewer interception")
        let reply = await fixture.handle(.object(["id": .string("probe"), "method": .string("surface.input"),
            "params": .object(["stream": .string(stream.id), "events": .array(events)])]), stream.connection)
        try expect(reply?["ok"]?.bool == true, "probe raw input must be accepted by the base drawer")
        let returned = await eventually {
            probe.records.contains { $0["label"]?.string == probe.label && $0["phase"]?.string == "drawer.unhandled" && $0["target_matches_expected"]?.bool == true }
        }
        await observe(web, "probe-\(route.rawValue)-after-unhandled")
        let reached = probe.records.contains { $0["label"]?.string == probe.label && $0["phase"]?.string == "drawer.keyDown" && $0["target_matches_expected"]?.bool == true }
        emit("PREMISE \(route.rawValue) drawer_key=\(reached) returned_unhandled_with_target=\(returned)")
        try expect(reached && returned, "PREMISE REFUTED: base textarea must return the synthesized undo key with its recoverable target page")
    }

    static func remoteUndo(root: URL) async throws {
        guard let route = UndoRoute(rawValue: ProcessInfo.processInfo.environment["EASL_UNDO_ROUTE"] ?? ""),
              let phase = ProcessInfo.processInfo.environment["EASL_UNDO_PHASE"] else {
            throw WheelFailure(description: "runner must name the undo route and phase")
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
        emit("ROUTE \(route.rawValue) \(route == .hid ? "CGEvent cghidEventTap, active key window" : "DevInput.replay, non-key window") phase=\(phase)")
        if phase == "probe" {
            do {
                try await probeUndo(root: root, route: route)
                emit("PASS probe-\(route.rawValue)")
            } catch {
                emit("FAIL probe-\(route.rawValue): \(error)")
                throw error
            }
            return
        }
        try expect(phase == "direct" || phase == "relay", "unknown undo phase")
        var failures: [String] = []
        for test in UndoCase.allCases {
            do { try await undoCase(test, route: route, remote: phase == "relay", root: root) }
            catch {
                emit("FAIL \(phase)-\(test.rawValue)-\(route.rawValue): \(error)")
                failures.append(test.rawValue)
            }
        }
        try expect(failures.isEmpty, "\(phase) \(route.rawValue) failed cases: \(failures.joined(separator: ","))")
    }
}
