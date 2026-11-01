import AppKit
import WebKit
import ObjectiveC.runtime

@testable import CanvasApp
@testable import CanvasCore

/// An HTML tile's page takes the keyboard for its text fields: Return on the selected tile or a
/// click in a field, and the canvas takes it back on Esc or a click on the board. A page that
/// focuses a field on its own never captures keys. Runs local and remote boards.
@main
@MainActor
private enum HtmlKeyboard {
    private struct Failure: Error { let message: String }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
            throw Failure(message: message)
        }
    }

    private static func check(_ message: String) {
        FileHandle.standardOutput.write(Data("CHECK \(message)\n".utf8))
    }

    private static func key(_ code: UInt16, _ characters: String, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    /// Straight to the window's responder chain: the runner never activates a window on the
    /// machine it runs on, so an application-level key event would look for a key window tests
    /// don't have.
    private static func post(_ event: NSEvent, in window: NSWindow) {
        window.sendEvent(event)
    }

    private static func js(_ web: WKWebView, _ expression: String) async -> Any? {
        (try? await web.evaluateJavaScript(expression)) as Any?
    }

    private static func wait(until condition: @MainActor () -> Bool, _ message: String,
                             limit: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw Failure(message: message)
    }

    /// The quiz page: two fields that persist what is typed in them, the first focused as the
    /// page loads (DOM focus only: the page never takes the keyboard itself).
    private static func pageHTML() -> String {
        """
        <!doctype html><html><body style="margin:0;padding:8px;font-family:sans-serif">
        <p id="plain" style="height:40px">Plain page text.</p>
        <textarea id="thinking" style="display:block;width:320px;height:60px"></textarea>
        <textarea id="next" style="display:block;width:320px;height:60px"></textarea>
        <script>
        const kit = window.canvasKit;
        const wire = (field, key) => {
          if (!kit) return;
          field.addEventListener('input', () => kit.setState(key, field.value));
          kit.getState(key).then((value) => { if (typeof value === 'string' && !field.value) field.value = value; });
        };
        const thinking = document.getElementById('thinking');
        const next = document.getElementById('next');
        wire(thinking, 'thinking');
        wire(next, 'next');
        const focus = () => thinking.focus();
        focus();
        setTimeout(focus, 400);
        // The page's own Esc wins once (a dialog closes); the next one is the canvas's.
        document.addEventListener('keydown', (event) => {
          if (event.key !== 'Escape' || window.escaped) return;
          event.preventDefault();
          window.escaped = true;
        });
        </script></body></html>
        """
    }

    private static func htmlTile(_ canvas: CanvasView, _ object: CanvasObject) throws -> HtmlTile {
        guard let tile = canvas.tiles[object.id], let html = tile.content as? HtmlTile else {
            throw Failure(message: "\(object.id) is not an HTML tile")
        }
        return html
    }

    private static func page(in html: HtmlTile) async throws -> WKWebView {
        for _ in 0..<400 {
            if let web = html.webView { return web }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure(message: "HTML tile built no web view")
    }

    private static func loaded(_ web: WKWebView) async throws {
        for _ in 0..<240 {
            if let state = await js(web, "document.readyState") as? String, state == "complete" { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure(message: "the HTML page did not load")
    }

    /// A click straight to the page's view, as AppKit's hit-tested dispatch delivers it. Posted
    /// mouse events would wait for a key window that an unactivated test window never has.
    private static func click(_ selector: String, in web: WKWebView, window: NSWindow,
                              afterMouseDown: (@MainActor () throws -> Void)? = nil) async throws {
        guard let rect = await js(web, "document.querySelector('\(selector)').getBoundingClientRect().toJSON()") as? [String: Any],
              let x = rect["x"] as? Double, let y = rect["y"] as? Double else {
            throw Failure(message: "the page has no \(selector) to click")
        }
        let point = web.convert(NSPoint(x: x + 4, y: y + 4), to: nil)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            throw Failure(message: "could not build the click")
        }
        web.mouseDown(with: down)
        try afterMouseDown?()
        web.mouseUp(with: up)
    }

    private static func typed(_ text: String, in window: NSWindow) {
        for character in text { post(key(0, String(character), in: window), in: window) }
    }

    private static func state(_ board: Board, _ id: ObjectID, _ key: String) -> String? {
        board.objects[id]?.props["state"]?[key]?.string
    }

    static func main() async throws {
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"] else {
            fatalError("run.py must provide a disposable EASL_HOME")
        }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        if CommandLine.arguments.contains("--dom-clicks") || CommandLine.arguments.contains("--clobbered-click") || CommandLine.arguments.contains("--stale-focus-click") {
            let only = CommandLine.arguments.contains("--clobbered-click") ? "named activeElement form"
                : CommandLine.arguments.contains("--stale-focus-click") ? "stale focused field" : nil
            try await exerciseDOMClicks(only: only)
            return
        }
        if CommandLine.arguments.contains("--hostile-clicks") {
            try await exerciseHostileClicks()
            try await exerciseStaleClicks()
            return
        }
        let root = URL(fileURLWithPath: home).appendingPathComponent("board", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--document-grants") {
            try await exerciseDocumentGrant(root: root)
            return
        }
        if CommandLine.arguments.contains("--missing-selector") {
            try await exerciseWithoutSuppression(root: root)
            return
        }
        try await exercise(root: root, remote: nil, kind: "local")
        let host = RemoteHost(name: "html-keyboard-regression", sshTarget: "html-keyboard-regression.invalid",
                              socketPath: root.appendingPathComponent("absent.sock").path,
                              tmpdir: root.path, easlBin: "easl")
        let absent = EaslConnection(.unixSocket(host.socketPath))
        let mirror = BoardMirror(hostName: host.name, board: "html-keyboard-remote",
                                 connection: absent, diagrams: EaslConnection(.unixSocket(host.socketPath)))
        try await exercise(root: root, remote: RemoteSource(host: host, mirror: mirror), kind: "remote")
        try await exerciseWithoutSuppression(root: root.appendingPathComponent("missing-selector", isDirectory: true))
        try await exerciseHostileClicks()
        try await exerciseStaleClicks()
        try await exerciseDOMClicks()
        try await exerciseDocumentGrant(root: root.appendingPathComponent("replacement", isDirectory: true))
        try await exerciseMermaid(root: root.appendingPathComponent("mermaid", isDirectory: true))
        print("PASS HTML tile keyboard: Return, click into a field, Tab, Esc, board click, and no focus from a page on load (local and remote)")
    }

    private final class NativeClickTarget: NSView {
        var clicks = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { clicks += 1 }
    }

    private static func clickFixture(patch: String = "") async throws
        -> (window: CanvasWindow, web: HtmlWebView, native: NSTextView, other: NSTextView, elsewhere: NativeClickTarget) {
        let window = CanvasWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let web = HtmlWebView(frame: NSRect(x: 0, y: 180, width: 700, height: 320),
                              configuration: WKWebViewConfiguration())
        let native = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 100))
        let other = NSTextView(frame: NSRect(x: 350, y: 0, width: 340, height: 100))
        let elsewhere = NativeClickTarget(frame: NSRect(x: 0, y: 110, width: 700, height: 60))
        let views: [NSView] = [web, native, other, elsewhere]
        for view in views { window.contentView!.addSubview(view) }
        window.orderFrontRegardless()
        web.loadHTMLString("""
        <!doctype html><html><body style="margin:0;padding:8px">
        <button id="plain">Not a text field</button>
        <textarea id="field" style="display:block;width:320px;height:60px"></textarea>
        <script>
        window.pageKeys = 0;
        document.addEventListener('keydown', () => window.pageKeys++);
        \(patch)
        window.attackReady = true;
        </script></body></html>
        """, baseURL: nil)
        try await loaded(web)
        for _ in 0..<240 {
            if await js(web, "window.attackReady") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let ready = await js(web, "window.attackReady") as? Bool
        try require(ready == true, "the adversarial click page must be ready")
        try require(window.makeFirstResponder(native), "the native text target must hold the keyboard")
        return (window, web, native, other, elsewhere)
    }

    private static func pageTurn(_ web: WKWebView) async throws {
        let replied = await PageScript.value("""
        return new Promise(resolve => setTimeout(() => resolve(true), 0));
        """, in: .page, on: web) { ($0 as? Bool) == true }
        try require(replied, "the page must acknowledge a turn after the click or promise release")
    }

    private static func exerciseHostileClicks() async throws {
        let attacks: [(name: String, patch: String, delayed: Bool)] = [
            ("delayed true promise", """
            window.delayedGrant = new Promise(resolve => {
              window.releaseGrant = () => { window.released = true; resolve(true); };
            });
            Object.defineProperty(HTMLElement.prototype, 'isContentEditable', {
              get() { return window.delayedGrant; }
            });
            """, true),
            ("patched activeElement", """
            Object.defineProperty(Document.prototype, 'activeElement', {
              get() { return document.getElementById('field'); }
            });
            """, false),
            ("patched isContentEditable", """
            Object.defineProperty(HTMLElement.prototype, 'isContentEditable', {
              get() { return true; }
            });
            """, false)
        ]
        for attack in attacks {
            let fixture = try await clickFixture(patch: attack.patch)
            defer { fixture.window.close() }
            let target = attack.delayed ? fixture.other : fixture.native
            try await click("#plain", in: fixture.web, window: fixture.window) {
                if attack.delayed {
                    try require(fixture.window.makeFirstResponder(target),
                                "\(attack.name): the user must be able to focus another native target")
                }
            }
            if attack.delayed {
                try await pageTurn(fixture.web)
                try require(fixture.window.firstResponder === fixture.other,
                            "an unresolved page promise must leave the native target focused")
                _ = await js(fixture.web, "window.releaseGrant(); true")
                let released = await js(fixture.web, "window.released") as? Bool
                try require(released == true, "the delayed true promise must actually resolve")
            }
            try await pageTurn(fixture.web)
            try require(fixture.window.firstResponder === target,
                        "\(attack.name) must not steal the keyboard from the native target")
            typed("native", in: fixture.window)
            try require(target.string == "native",
                        "\(attack.name): typed text must reach the native target")
            let pageKeys = await js(fixture.web, "window.pageKeys") as? Int
            try require(pageKeys == 0, "\(attack.name): the page must not receive the native target's keys")
            check("\(attack.name) cannot authorize keyboard capture")
        }
    }

    private static func exerciseDOMClicks(only: String? = nil) async throws {
        let attacks: [(name: String, patch: String)] = [
            ("named activeElement form", """
            const fake = document.createElement('form');
            fake.name = 'activeElement';
            fake.contentEditable = 'true';
            fake.textContent = 'Not the focused editable';
            document.body.appendChild(fake);
            """),
            ("stale focused field", """
            document.getElementById('field').focus();
            document.getElementById('plain').addEventListener('mousedown', event => event.preventDefault());
            """)
        ]
        for attack in attacks where only == nil || only == attack.name {
            let fixture = try await clickFixture(patch: attack.patch)
            defer { fixture.window.close() }
            try await click("#plain", in: fixture.web, window: fixture.window)
            try await pageTurn(fixture.web)
            let granted = fixture.window.firstResponder === fixture.web
            typed("native", in: fixture.window)
            try await pageTurn(fixture.web)
            let pageKeys = await js(fixture.web, "window.pageKeys") as? Int
            check("\(attack.name): native click granted=\(granted), page keys=\(pageKeys ?? -1)")
            try require(!granted && fixture.window.firstResponder === fixture.native,
                        "\(attack.name): a click outside the real active editable must not grant the keyboard")
            try require(fixture.native.string == "native", "\(attack.name): typing must stay with the native target")
            try require(pageKeys == 0, "\(attack.name): the page must receive no keys")
            try await click("#field", in: fixture.web, window: fixture.window)
            try await wait(until: { fixture.window.firstResponder === fixture.web },
                           "\(attack.name): a new click inside the real editable must still grant")
            check("\(attack.name) refuses the outside click and accepts a real field click")
        }
    }

    private static func exerciseDocumentGrant(root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = Board(id: "html-keyboard-replacement", root: root)
        let canvas = CanvasView(board: board, viewport: nil, remote: nil)
        let window = CanvasWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        board.onEvent = { canvas.apply($0) }
        defer {
            board.onEvent = nil
            canvas.discard()
            window.close()
        }
        window.orderFrontRegardless()
        let frame = Frame(x: -350, y: -250, w: 700, h: 500)
        canvas.show(Viewport(rect: Frame(x: -410, y: -310, w: 820, h: 620), zoom: 1))
        let original = pageHTML().replacingOccurrences(of: "<script>", with: """
        <script>
        window.originalKeys = 0;
        document.addEventListener('keydown', () => window.originalKeys++);
        """)
        let object = board.create(type: .html, props: .object(["html": .string(original)]), frame: frame)
        let tile = try htmlTile(canvas, object)
        let web = try await page(in: tile)
        try await loaded(web)
        try await Task.sleep(for: .milliseconds(500))
        canvas.setSelection([object.id])
        try require(window.makeFirstResponder(canvas.document), "the canvas must hold keys before the grant")
        try await click("#next", in: web, window: window)
        try await wait(until: { window.firstResponder === web }, "the original document must receive a click grant")
        let focused = await js(web, "({id: document.activeElement?.id, focused: document.hasFocus()})")
        check("original document: selected=\(canvas.selection.contains(object.id)), DOM=\(String(describing: focused))")
        typed("old", in: window)
        try await pageTurn(web)
        for _ in 0..<200 {
            if await js(web, "window.originalKeys") as? Int == 3 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let originalKeys = await js(web, "window.originalKeys") as? Int
        check("original document: received keys=\(originalKeys ?? -1)")
        try require(originalKeys == 3, "the original grant must deliver real keys")
        let replacement = pageHTML()
            .replacingOccurrences(of: "wire(next, 'next');", with: "wire(next, 'replacement');")
            .replacingOccurrences(of: "<script>", with: """
        <script>
        window.replacementDocument = true;
        window.replacementKeys = 0;
        document.addEventListener('keydown', () => window.replacementKeys++);
        """)
        _ = try board.update(object.id, props: .object(["html": .string(replacement)]))
        for _ in 0..<240 {
            if await js(web, "window.replacementDocument") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let replaced = await js(web, "window.replacementDocument") as? Bool
        try require(replaced == true, "the agent HTML rewrite must commit a replacement document")
        try await Task.sleep(for: .milliseconds(500))
        typed("blocked", in: window)
        try await pageTurn(web)
        let keys = await js(web, "window.replacementKeys") as? Int
        check("replacement document: received keys before new click=\(keys ?? -1)")
        try require(keys == 0, "the replacement document must receive no keys from the old grant")
        try require(!web.acceptsFirstResponder, "the replacement must revoke native keyboard authorization")
        try await click("#next", in: web, window: window)
        try await wait(until: { window.firstResponder === web }, "a new document click must grant the keyboard again")
        typed("new", in: window)
        try await pageTurn(web)
        for _ in 0..<200 {
            if await js(web, "window.replacementKeys") as? Int == 3 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let newKeys = await js(web, "window.replacementKeys") as? Int
        try require(newKeys == 3, "the new click must deliver keys to the replacement document")
        check("an agent HTML rewrite revokes the old grant and a new click grants again")
    }

    private static func nativeClick(_ target: NativeClickTarget, window: NSWindow) throws {
        let point = target.convert(NSPoint(x: 10, y: 10), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw Failure(message: "could not build the later native click")
            }
            window.sendEvent(event)
        }
    }

    private static func exerciseStaleClicks() async throws {
        let fixture = try await clickFixture()
        defer { fixture.window.close() }
        try await click("#field", in: fixture.web, window: fixture.window)
        try await wait(until: { fixture.window.firstResponder === fixture.web },
                       "an unmodified native text-field click must grant the keyboard")
        try require(fixture.window.makeFirstResponder(fixture.native), "the native target must reclaim the keyboard")
        try require(!fixture.web.acceptsFirstResponder, "leaving the page must revoke its keyboard grant")

        try await click("#field", in: fixture.web, window: fixture.window) {
            try require(fixture.window.makeFirstResponder(fixture.other), "focus must move away during the click check")
            try require(fixture.window.makeFirstResponder(fixture.native), "focus must return before the click reply")
        }
        try await pageTurn(fixture.web)
        try require(fixture.window.firstResponder === fixture.native,
                    "restoring the original first responder must not revive a stale click")
        try require(!fixture.web.acceptsFirstResponder, "an away-and-back focus change must cancel click authorization")

        try await click("#field", in: fixture.web, window: fixture.window) {
            try nativeClick(fixture.elsewhere, window: fixture.window)
            try require(fixture.elsewhere.clicks == 1, "the later click must reach another native view")
            try require(fixture.window.firstResponder === fixture.native,
                        "the later native click fixture must keep the same first responder")
        }
        try await pageTurn(fixture.web)
        try require(fixture.window.firstResponder === fixture.native,
                    "a newer native click must cancel the page grant even without a focus change")
        try require(!fixture.web.acceptsFirstResponder, "the earlier page click must remain ungranted")
        typed("kept", in: fixture.window)
        try require(fixture.native.string == "kept", "native typing must survive both canceled click grants")
        check("focus away-and-back and a later native click permanently cancel pending grants")
    }

    private static func exerciseWithoutSuppression(root: URL) async throws {
        let responds = #selector(NSObject.responds(to:))
        let suppressed = NSSelectorFromString("_setShouldSuppressFirstResponderChanges:")
        guard let inherited = class_getInstanceMethod(HtmlWebView.self, responds),
              let encoding = method_getTypeEncoding(inherited) else {
            throw Failure(message: "the native selector-availability fixture needs responds(to:)")
        }
        let original = method_getImplementation(inherited)
        typealias Responds = @convention(c) (AnyObject, Selector, Selector) -> Bool
        let originalResponds = unsafeBitCast(original, to: Responds.self)
        let unavailable: @convention(block) (AnyObject, Selector) -> Bool = { object, selector in
            if selector == suppressed { return false }
            return originalResponds(object, responds, selector)
        }
        let replacement = imp_implementationWithBlock(unavailable)
        guard class_addMethod(HtmlWebView.self, responds, replacement, encoding) else {
            imp_removeBlock(replacement)
            throw Failure(message: "the selector-availability fixture must not replace an existing override")
        }
        defer {
            class_replaceMethod(HtmlWebView.self, responds, original, encoding)
            imp_removeBlock(replacement)
        }

        let window = CanvasWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let web = HtmlWebView(frame: window.contentView!.bounds, configuration: WKWebViewConfiguration())
        window.contentView!.addSubview(web)
        try require(!web.responds(to: suppressed), "the fixture must hide the private suppression selector")
        try require(!web.becomeFirstResponder(),
                    "without the private selector, a native responder request must refuse an ungranted page")
        _ = window.makeFirstResponder(web)
        try require(window.firstResponder !== web && (window.firstResponder as? NSView)?.isDescendant(of: web) != true,
                    "without the private selector, AppKit must not give an ungranted page the keyboard")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let boardWindow = CanvasWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        try await exercise(root: root, remote: nil, kind: "missing-selector", window: boardWindow)
        check("absent suppression selector: focus-on-load refused; Return and native field clicks grant; Esc revokes")
    }

    private static func exerciseMermaid(root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = Board(id: "html-mermaid", root: root)
        let canvas = CanvasView(board: board, viewport: nil, remote: nil)
        let window = CanvasWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        board.onEvent = { canvas.apply($0) }
        defer {
            board.onEvent = nil
            canvas.discard()
            window.close()
        }
        window.orderFrontRegardless()
        let source = "flowchart LR\nA[Alpha] --> B[Beta] --> C[Gamma] --> D[Delta] --> E[Epsilon]"
        let broken = "not a Mermaid diagram"
        let titledSource = "\n\u{00a0}\n  ---\n  title: Flow\n  ---\n  " +
            source.replacingOccurrences(of: "\n", with: "\n  ")
        let html = """
        <div style="display:flex;gap:12px">
        <div style="flex:1"><pre class="mermaid" id="declared">\(source)</pre></div>
        <aside id="sidebar" style="width:80px;flex-shrink:0">Sidebar</aside>
        </div>
        <pre id="fenced">```mermaid
        \(source)
        ```</pre>
        <pre id="fencecode"><code><span>```mermaid</span>
        \(source)
        <span>```</span></code></pre>
        <pre id="language"><code class="language-mermaid"><span>\(titledSource)</span></code></pre>
        <pre class="mermaid" id="broken">\(broken)</pre>
        <pre class="mermaid" id="multiline">flowchart LR
        A[First line<br>Second line] --> B[Done]</pre>
        """
        let frame = Frame(x: -210, y: -250, w: 420, h: 500)
        canvas.show(Viewport(rect: Frame(x: -260, y: -300, w: 520, h: 600), zoom: 1))
        let object = board.create(type: .html, props: .object(["html": .string(html)]), frame: frame)
        let tile = try htmlTile(canvas, object)
        let web = try await page(in: tile)
        var ready = false
        tile.whenLiveReady { ready = true }
        try await wait(until: { ready }, "the kit page must settle before rendering diagrams")
        let rendered = try await web.callAsyncJavaScript("""
        await canvasKit.renderMermaid();
        const manual = document.createElement('div');
        manual.id = 'manual';
        manual.className = 'mermaid';
        manual.textContent = source;
        document.body.append(manual);
        const multiline = document.createElement('div');
        multiline.id = 'manual-multiline';
        multiline.className = 'mermaid';
        multiline.innerHTML = 'flowchart LR\\nA[First line<br>Second line] --> B[Done]';
        document.body.append(multiline);
        await Promise.all([canvasKit.renderMermaid(), canvasKit.renderMermaid()]);
        return ['declared', 'fenced', 'fencecode', 'language', 'manual'].every(id => {
          const svg = document.querySelector('#' + id + ' svg');
          const labels = [...(svg?.querySelectorAll('text') || [])].map(node => node.textContent);
          return svg && labels.includes('Alpha') && labels.includes('Epsilon') &&
            (id !== 'language' || labels.includes('Flow')) && svg.getBoundingClientRect().height > 0;
        });
        """, arguments: ["source": source], contentWorld: .page) as? Bool
        try require(rendered == true, "all documented markup forms and awaited renderMermaid() must produce visible diagrams")
        let multiline = await js(web, """
        ['multiline', 'manual-multiline'].every(id => {
          const labels = [...document.querySelectorAll('#' + id + ' svg text, #' + id + ' svg tspan')];
          const first = labels.find(node => node.textContent === 'First line');
          const second = labels.find(node => node.textContent === 'Second line');
          return first && second && first !== second;
        })
        """) as? Bool
        try require(multiline == true, "HTML line breaks in labels must survive markup and manual rendering")
        let direction = await js(web, """
        (() => {
          const svg = document.querySelector('#declared svg');
          const labels = [...svg.querySelectorAll('text')];
          const a = labels.find(node => node.textContent === 'Alpha').getBoundingClientRect();
          const b = labels.find(node => node.textContent === 'Beta').getBoundingClientRect();
          const viewport = svg.parentElement;
          const control = document.querySelector('#declared button');
          return b.left > a.right && Math.abs(b.top - a.top) < 2 &&
            svg.getBoundingClientRect().width > viewport.clientWidth &&
            getComputedStyle(viewport).overflowX === 'auto' &&
            viewport.scrollHeight <= viewport.clientHeight &&
            control.tabIndex === 0 && !!control.getAttribute('aria-label');
        })()
        """) as? Bool
        try require(direction == true, "a narrow HTML tile must keep declared LR direction and natural-size overflow with a labelled keyboard-reachable control")
        let contained = await js(web, """
        document.documentElement.scrollWidth <= document.documentElement.clientWidth &&
          document.querySelector('#sidebar').getBoundingClientRect().right <= document.documentElement.clientWidth
        """) as? Bool
        try require(contained == true, "a diagram in a flex column must scroll internally without pushing its sidebar off the page")
        let fallback = await js(web, """
        (() => {
          const host = document.querySelector('#broken');
          return host.querySelector('pre').textContent === 'not a Mermaid diagram' &&
            host.querySelector('[role="status"]').textContent.length > 0 &&
            host.getBoundingClientRect().height > 0;
        })()
        """) as? Bool
        try require(fallback == true, "a failed diagram must show its original source and a diagnostic")
        try await click("#declared button", in: web, window: window)
        try await pageTurn(web)
        let fit = await js(web, """
        (() => {
          const svg = document.querySelector('#declared svg');
          return svg.getBoundingClientRect().width <= svg.parentElement.clientWidth &&
            svg.viewBox.baseVal.width > svg.parentElement.clientWidth;
        })()
        """) as? Bool
        try require(fit == true, "Fit must shrink the displayed diagram without changing its natural viewBox")
        try await click("#declared button", in: web, window: window)
        try await pageTurn(web)
        let natural = await js(web, """
        (() => {
          const svg = document.querySelector('#declared svg');
          const viewport = svg.parentElement;
          return svg.getBoundingClientRect().width > viewport.clientWidth &&
            viewport.scrollHeight <= viewport.clientHeight;
        })()
        """) as? Bool
        try require(natural == true, "100% must restore natural-size overflow")
        let exported = try await tile.exportDocument()
        let browser = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 500),
                                configuration: WKWebViewConfiguration())
        window.contentView!.addSubview(browser)
        defer { browser.removeFromSuperview() }
        browser.loadHTMLString(exported, baseURL: nil)
        for _ in 0..<240 {
            if await js(browser, "!!document.querySelector('#declared svg')") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let standalone = await js(browser, """
        (() => {
          const svg = document.querySelector('#declared svg');
          const viewport = svg.parentElement;
          return document.scripts.length === 0 && !document.querySelector('.mermaid button') &&
            svg.getBoundingClientRect().height > 0 &&
            svg.getBoundingClientRect().width > viewport.clientWidth &&
            viewport.scrollHeight <= viewport.clientHeight &&
            getComputedStyle(viewport).overflowX === 'auto';
        })()
        """) as? Bool
        try require(standalone == true, "script-free HTML export must retain visible scrollable diagrams without inert controls")
        check("Mermaid markup, LR direction, source diagnostics, Fit/100%, and script-free export")
    }

    private static func exercise(root: URL, remote: RemoteSource?, kind: String, window suppliedWindow: NSWindow? = nil) async throws {
        let board = remote.map { Board(remote: "html-keyboard-\(kind)", root: root, host: $0.mirror) }
            ?? Board(id: "html-keyboard-\(kind)", root: root)
        let canvas = CanvasView(board: board, viewport: nil, remote: remote)
        canvas.hasHorizontalScroller = false
        canvas.hasVerticalScroller = false
        let window = suppliedWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas.frame = window.contentView!.bounds
        window.contentView!.addSubview(canvas)
        board.onEvent = { canvas.apply($0) }
        defer {
            board.onEvent = nil
            canvas.discard()
            window.close()
        }
        window.orderFrontRegardless()
        let frame = Frame(x: -350, y: -250, w: 700, h: 500)
        let shown = CanvasView.docRect(frame)
        canvas.show(Viewport(rect: Frame(x: frame.x - 60, y: frame.y - 60, w: frame.w + 120, h: frame.h + 120), zoom: 1))
        try await Task.sleep(for: .milliseconds(250))
        window.makeFirstResponder(canvas.document)

        // Return on the selected tile gives the page the keyboard. The page's own field has DOM
        // focus but not the keyboard until then; typed text reaches the page's state, and Tab
        // moves to the next field. Esc hands the keyboard back with the tile selected.
        let returned = board.create(type: .html, props: .object(["title": .string("Quiz \(kind)"),
                                                                 "html": .string(pageHTML())]), frame: frame)
        let typing = try htmlTile(canvas, returned)
        let typingPage = try await page(in: typing)
        try await loaded(typingPage)
        try await Task.sleep(for: .milliseconds(500))
        canvas.setSelection([returned.id])
        try require(window.makeFirstResponder(canvas.document), "the canvas document must take the keyboard")
        try require(typingPage.acceptsFirstResponder == false, "the page must not accept the keyboard before the user asks")
        post(key(36, "\r", in: window), in: window)
        try await wait(until: { window.firstResponder === typingPage }, "Return must give the page the keyboard")
        typed("hello", in: window)
        try await wait(until: { state(board, returned.id, "thinking") == "hello" }, "typed text must reach props.state")
        // Delete in a field is the page's: it must not delete the tile or clear the selection.
        post(key(51, "\u{7f}", in: window), in: window)
        try await Task.sleep(for: .milliseconds(250))
        try require(board.objects[returned.id] != nil && canvas.selection == [returned.id],
                    "a key in the page must not act on the canvas")
        post(key(48, "\t", in: window), in: window)
        typed("!", in: window)
        try await wait(until: { state(board, returned.id, "next") == "!" }, "Tab must move to the next field in the page")
        check("Return and Tab type into \(kind) props.state; page keys never act on the canvas")
        // Delete with no field focused must stay in the page: it would otherwise delete the
        // tile and clear the selection.
        _ = await js(typingPage, "document.activeElement.blur()")
        try await Task.sleep(for: .milliseconds(150))
        let bodyFocused = await js(typingPage, "document.activeElement === document.body") as? Bool
        try require(bodyFocused == true, "the fixture must blur out of its fields")
        post(key(51, "\u{7f}", in: window), in: window)
        try await Task.sleep(for: .milliseconds(250))
        try require(board.objects[returned.id] != nil && canvas.selection == [returned.id],
                    "Delete in the page must not act on the canvas")
        post(key(53, "\u{1b}", in: window), in: window)
        try await Task.sleep(for: .milliseconds(300))
        let escaped = await js(typingPage, "window.escaped") as? Bool
        try require(escaped == true, "the page must see its own Esc")
        try require(window.firstResponder === typingPage, "an Esc the page handles must stay in the page")
        post(key(53, "\u{1b}", in: window), in: window)
        try await wait(until: { window.firstResponder === canvas.document }, "Esc must give the keyboard back to the canvas")
        try require(canvas.selection == [returned.id], "Esc must leave the tile selected")
        post(key(51, "\u{7f}", in: window), in: window)
        try await wait(until: { board.objects[returned.id] == nil }, "a canvas key must act after Esc")
        check("Esc returns \(kind) keyboard to the canvas and canvas keys act again")

        // A click in a text field takes the keyboard; a click on plain page text and a click on
        // the board leave it with the canvas.
        let clicked = board.create(type: .html, props: .object(["title": .string("Quiz click \(kind)"),
                                                                "html": .string(pageHTML())]), frame: frame)
        let clickTile = try htmlTile(canvas, clicked)
        let clickPage = try await page(in: clickTile)
        try await loaded(clickPage)
        try await Task.sleep(for: .milliseconds(500))
        canvas.setSelection([clicked.id])
        try require(window.makeFirstResponder(canvas.document), "the canvas must hold the keyboard before the click")
        try await click("#next", in: clickPage, window: window)
        try await wait(until: { window.firstResponder === clickPage }, "a click in a text field must give the page the keyboard")
        typed("clicked", in: window)
        try await wait(until: { state(board, clicked.id, "next") == "clicked" }, "clicked text must reach props.state")
        check("clicking a text field gives \(kind) the page the keyboard: clicked")
        // The page takes its own first Esc; the next one is the canvas's.
        post(key(53, "\u{1b}", in: window), in: window)
        try await Task.sleep(for: .milliseconds(250))
        post(key(53, "\u{1b}", in: window), in: window)
        try await wait(until: { window.firstResponder === canvas.document }, "Esc must leave the clicked page")
        try require(!clickPage.acceptsFirstResponder, "Esc must revoke the clicked page's keyboard permission")
        try require(!clickPage.becomeFirstResponder(), "a page must not regain the keyboard after Esc without another grant")
        try await click("#plain", in: clickPage, window: window)
        try await Task.sleep(for: .milliseconds(250))
        try require(window.firstResponder === canvas.document, "a click on plain page text must leave the keyboard with the canvas")
        guard let boardClick = NSEvent.mouseEvent(with: .leftMouseDown, location: shown.origin, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            throw Failure(message: "could not build the board click")
        }
        canvas.emptyMouseDown(boardClick)
        try require(window.firstResponder === canvas.document, "a board click must leave the keyboard with the canvas")
        check("plain page text and the board never take \(kind) keyboard")

        // A page that focuses a field by itself keeps DOM focus but not the keyboard; typing stays
        // with the canvas and Delete still acts on the board.
        canvas.setSelection([])
        try require(window.makeFirstResponder(canvas.document), "the canvas must hold the keyboard before the page loads")
        let autofocus = board.create(type: .html, props: .object(["title": .string("Autofocus \(kind)"),
                                                                  "html": .string(pageHTML())]), frame: frame)
        let autoTile = try htmlTile(canvas, autofocus)
        let autoPage = try await page(in: autoTile)
        try await loaded(autoPage)
        try await Task.sleep(for: .milliseconds(900))
        let active = await js(autoPage, "document.activeElement.id") as? String
        try require(active == "thinking", "the fixture must focus its own field")
        try require(window.firstResponder === canvas.document, "a page focusing a field on load must not capture keys")
        typed("x", in: window)
        try await Task.sleep(for: .milliseconds(300))
        let typedIntoPage = await js(autoPage, "document.getElementById('thinking').value") as? String
        try require(typedIntoPage == "", "keys must not reach a page that focused its own field")
        try require(state(board, autofocus.id, "thinking") == nil, "a page focusing its own field must not receive typed text")
        check("a \(kind) page focusing a field on load does not capture keys")
        canvas.setSelection([autofocus.id])
        post(key(51, "\u{7f}", in: window), in: window)
        try await wait(until: { board.objects[autofocus.id] == nil }, "Delete with the canvas keyboard must delete the selected tile")
        check("canvas keys act after a \(kind) page focused its own field")
    }
}
