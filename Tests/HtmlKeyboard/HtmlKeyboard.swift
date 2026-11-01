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
        if CommandLine.arguments.contains("--exports") {
            try await exerciseExports(root: root)
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
        try await exerciseExports(root: root.appendingPathComponent("exports", isDirectory: true))
        print("PASS HTML tile keyboard: Return, click into a field, Tab, Esc, board click, and no focus from a page on load (local and remote)")
    }

    private static func exerciseExports(root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("let exportAnswer = 42\n".utf8).write(to: root.appendingPathComponent("export.swift"))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<2 {
            for x in 0..<3 { bitmap.setColor(NSColor(deviceRed: 0.1, green: 0.3, blue: 0.9, alpha: 1), atX: x, y: y) }
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("export.png"))
        let board = Board(id: "html-export-regression", root: root)
        let object = board.create(type: .html, props: .object(["html": .string(exportHTML())]),
                                  frame: Frame(x: 0, y: 0, w: 900, h: 900))
        let tile = HtmlTile(object: object, board: board)
        let document = try await tile.exportDocument()
        check("real HtmlTile.exportDocument returned \(document.utf8.count) bytes")
        let file = root.appendingPathComponent("export.html")
        try Data(document.utf8).write(to: file)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 900),
                            configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView!.addSubview(web)
        defer { web.stopLoading(); window.close() }
        web.loadFileURL(file, allowingReadAccessTo: root)
        var reopened = false
        for _ in 0..<240 {
            reopened = await js(web, "location.protocol === 'file:' && document.readyState === 'complete' && !!document.getElementById('picture')") as? Bool == true
            if reopened { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try require(reopened, "the exported file must finish loading in an ordinary WKWebView")
        try await pageTurn(web)
        guard let failures = await js(web, #"""
        (() => {
          const failures = [];
          const expect = (ok, name) => { if (!ok) failures.push(name); };
          expect(document.characterSet === 'UTF-8', 'export encoding stays UTF-8');
          expect(document.title === 'export-clean' && !document.body.hasAttribute('data-executed'),
                 'event execution: title=' + document.title + ', marker=' + document.body.getAttribute('data-executed'));
          const first = document.head.firstElementChild;
          expect(first?.localName === 'meta' && first.httpEquiv.toLowerCase() === 'content-security-policy', 'CSP first head element');
          const policy = first?.content || '';
          for (const directive of ["default-src 'none'", "script-src 'none'", "object-src 'none'",
                                   "frame-src 'none'", "form-action 'none'", "base-uri 'none'",
                                   "img-src data:", "style-src 'unsafe-inline'", "font-src data:"]) {
            expect(policy.split(';').some(part => part.trim() === directive), 'CSP ' + directive);
          }
          expect(document.scripts.length === 0, 'no scripts');
          expect(!document.querySelector('iframe,frame,object,embed,applet,portal,base,form'), 'no active elements or forms');
          expect(![...document.querySelectorAll('meta[http-equiv]')].some(meta => meta.httpEquiv.toLowerCase() !== 'content-security-policy'), 'no author http-equiv meta');
          expect(!document.querySelector('svg set,svg animate,svg animateMotion,svg animateTransform'), 'no SVG animation');
          expect(!document.getElementById('namespace-cursor')?.hasAttribute('cursor'), 'no resource URL activated by namespace reparse');
          const urlAttrs = new Set(['href', 'xlink:href', 'src', 'action', 'formaction', 'data', 'poster', 'background', 'ping']);
          for (const element of document.querySelectorAll('*')) {
            for (const attribute of element.attributes) {
              const name = attribute.name.toLowerCase();
              expect(!name.startsWith('on'), 'event attribute ' + element.localName + '.' + name);
              expect(name !== 'srcdoc', 'srcdoc attribute');
              if (!urlAttrs.has(name)) continue;
              const value = attribute.value.replace(/[\u0000-\u0020\u007f]/g, '').toLowerCase();
              const image = name === 'src' && element.localName === 'img' && value.startsWith('data:');
              expect(image || !/^(javascript|vbscript|data):/.test(value), 'unsafe URL ' + element.localName + '.' + name);
            }
          }
          const decodeCSS = text => text.replace(/\\([0-9a-f]{1,6})\s?|\\([^\r\n])/gi,
            (_, hex, char) => hex ? String.fromCodePoint(parseInt(hex, 16) || 0xfffd) : char);
          const css = [...document.querySelectorAll('style')].map(node => node.textContent)
            .concat([...document.querySelectorAll('[style]')].map(node => node.getAttribute('style'))).join('\n');
          const decoded = decodeCSS(css).replace(/[\u0000-\u0020\u007f]/g, '').toLowerCase();
          expect(!decoded.includes('expression(') && !/url\(["']?(javascript|vbscript):/.test(decoded), 'no dangerous CSS, including escapes');
          expect(!css.includes('beacon.invalid'), 'no resource URLs hidden by variable shorthand expansion');
          expect(!css.includes('probe.png'), 'no Unicode whitespace reinterpreted as a relative resource URL');
          const image = document.querySelector('#picture');
          expect(image?.src.startsWith('data:image/') && image.complete && image.naturalWidth === 3 && image.naturalHeight === 2,
                 'inlined image decoded at 3x2');
          expect(image?.getBoundingClientRect().width === 30 && image?.getBoundingClientRect().height === 20, 'image rendered at 30x20');
          expect(document.querySelector('#octet-image')?.naturalWidth === 1, 'image bytes with generic MIME type');
          expect(document.querySelector('#selected-image')?.naturalWidth === 1, 'selected picture data source');
          const diagram = document.querySelector('#diagram svg');
          expect(diagram && diagram.getBoundingClientRect().width > 0 && diagram.getBoundingClientRect().height > 0
                 && diagram.textContent.includes('Start') && diagram.textContent.includes('Finish'), 'settled real Mermaid SVG');
          expect(document.querySelector('#formula .katex .katex-html')?.getBoundingClientRect().height > 0, 'rendered KaTeX');
          expect([...document.fonts].some(font => font.family.includes('KaTeX') && font.status === 'loaded'), 'embedded KaTeX fonts loaded');
          expect(document.querySelector('canvas-code .ck-line .ck-text')?.textContent === 'let exportAnswer = 42', 'rendered canvas-code row');
          expect(document.querySelector('#table td')?.textContent === 'table survives' &&
                 document.querySelector('#table').getBoundingClientRect().height > 0, 'table content and print-only styles');
          expect(getComputedStyle(document.querySelector('#responsive')).color === 'rgb(1, 2, 3)', 'responsive CSS range query');
          expect(getComputedStyle(document.querySelector('canvas-pane'), '::before').content.includes('Before'), 'kit pane label');
          for (const [id, href] of [['https', 'https://example.invalid/export'], ['http', 'http://example.invalid/export'],
                                    ['mail', 'mailto:export@example.invalid'], ['fragment', '#table']]) {
            expect(document.getElementById(id)?.getAttribute('href') === href, 'ordinary link ' + id);
          }
          expect(document.getElementById('form-text')?.textContent === 'form text survives', 'unwrapped form content');
          return failures;
        })()
        """#) as? [String] else { throw Failure(message: "could not inspect reopened export") }
        check("export reopened in ordinary WKWebView: \(failures.isEmpty ? "no violations" : failures.joined(separator: "; "))")
        try require(failures.isEmpty, "export must be self-contained and inert: \(failures.joined(separator: "; "))")
        let withoutPolicy = document.replacingOccurrences(of: #"<meta http-equiv="Content-Security-Policy"[^>]*>"#,
                                                          with: "", options: .regularExpression)
        let fallback = root.appendingPathComponent("export-without-policy.html")
        try Data(withoutPolicy.utf8).write(to: fallback)
        web.loadFileURL(fallback, allowingReadAccessTo: root)
        var fallbackLoaded = false
        for _ in 0..<240 {
            fallbackLoaded = await js(web, "location.pathname.endsWith('export-without-policy.html') && document.readyState === 'complete' && !!document.getElementById('picture')") as? Bool == true
            if fallbackLoaded { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try require(fallbackLoaded, "the exported file without policy must finish loading")
        try await pageTurn(web)
        let independentlyInert = await js(web, """
        document.title === 'export-clean' && !document.body.hasAttribute('data-executed') &&
        document.scripts.length === 0 && !document.querySelector('meta[http-equiv], [onerror], [onload]') &&
        !!document.querySelector('#diagram svg') && !!document.querySelector('#formula .katex-html') &&
        document.querySelector('#picture').naturalWidth === 3 &&
        document.querySelector('canvas-code .ck-text').textContent === 'let exportAnswer = 42'
        """) as? Bool
        try require(independentlyInert == true, "sanitized export must remain inert without CSP, including comment and SVG reparsing")
        for tag in ["iframe", "x:html"] {
            let invalidRoot = board.create(type: .html, props: .object(["html": .string("""
            <p>Replaced document root</p><script>
            document.addEventListener('DOMContentLoaded', () => {
              const frame = document.createElementNS('http://www.w3.org/1999/xhtml', '\(tag)');
              frame.setAttribute('srcdoc', '<p>Active document root</p>');
              document.replaceChild(frame, document.documentElement);
            });
            </script>
            """)]), frame: Frame(x: 0, y: 0, w: 300, h: 200))
            let invalidTile = HtmlTile(object: invalidRoot, board: board)
            var rejectedRoot = false
            do { _ = try await invalidTile.exportDocument() }
            catch is ExportFailure { rejectedRoot = true }
            try require(rejectedRoot, "a \(tag) document root must fail export instead of bypassing sanitization")
        }
        let encodingObject = board.create(type: .html, props: .object(["html": .string(#"""
        <title>encoding-clean</title><p>Encoding proof</p><script>
        document.addEventListener('DOMContentLoaded', () => {
          for (const meta of document.querySelectorAll('meta[charset]')) meta.remove();
          const charset = document.createElement('meta');
          charset.setAttribute('charset', 'iso-2022-jp');
          document.head.append(charset);
          const escape = String.fromCharCode(27);
          document.documentElement.setAttribute('data-shift', escape + '$B');
          const reset = document.createElement('p');
          reset.textContent = escape + '(B" ';
          const image = document.createElement('img');
          image.src = 'data:image/png,invalid';
          image.alt = escape + '$B';
          const tail = document.createElement('span');
          tail.textContent = escape + '(B" onerror="document.title=\'encoding-executed\'" ';
          document.body.replaceChildren(reset, image, tail);
        });
        </script>
        """#)]), frame: Frame(x: 0, y: 0, w: 300, h: 200))
        let encodingTile = HtmlTile(object: encodingObject, board: board)
        let encodedDocument = try await encodingTile.exportDocument()
        for policy in [true, false] {
            let contents = policy ? encodedDocument : encodedDocument.replacingOccurrences(
                of: #"<meta http-equiv="Content-Security-Policy"[^>]*>"#, with: "", options: .regularExpression)
            let encodedFile = root.appendingPathComponent("encoding-\(policy).html")
            try Data(contents.utf8).write(to: encodedFile)
            web.loadFileURL(encodedFile, allowingReadAccessTo: root)
            var encodingLoaded = false
            for _ in 0..<240 {
                encodingLoaded = await js(web, "location.pathname.endsWith('encoding-\(policy).html') && document.readyState === 'complete'") as? Bool == true
                if encodingLoaded { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try require(encodingLoaded, "the encoding regression file must load")
            try await pageTurn(web)
            let encodingSafe = await js(web, """
            document.characterSet === 'UTF-8' && document.title === 'encoding-clean' &&
            !document.querySelector('[onerror]') &&
            (\(policy ? "true" : "false") === (document.head.firstElementChild?.getAttribute('http-equiv') === 'Content-Security-Policy'))
            """) as? Bool
            try require(encodingSafe == true, "author encoding must not reconstruct active markup or hide the policy")
        }
        print("PASS HTML export: inert events/URLs/CSS, first-head CSP, image, Mermaid, KaTeX, code, table and ordinary links")
    }

    private static func exportHTML() -> String {
        #"""
        <!doctype html><html><head><title>export-clean</title></head><body>
        <img id="picture" src="export.png" width="30" height="20">
        <img id="octet-image" src="data:application/octet-stream;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=">
        <picture><source srcset="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII="><img id="selected-image" src="export.png"></picture>
        <canvas-pane label="Before">Pane content</canvas-pane>
        <style media="print">#table { display:none }</style>
        <style>@media (width < 2000px) { #responsive { color:rgb(1,2,3) } }</style>
        <p id="responsive">Responsive content</p>
        <pre id="diagram" class="mermaid">flowchart LR
        A[Start] --> B[Finish]</pre>
        <p id="formula">$x^2 + y^2$</p>
        <canvas-code path="export.swift" lines="1"></canvas-code>
        <table id="table"><tr><td>table survives</td></tr></table>
        <a id="https" href="https://example.invalid/export">HTTPS</a>
        <a id="http" href="http://example.invalid/export">HTTP</a>
        <a id="mail" href="mailto:export@example.invalid">Mail</a>
        <a id="fragment" href="#table">Fragment</a>
        <template id="attacks">
          <img src="data:image/png,invalid" onerror="if(location.protocol==='file:'){document.title='image-executed';document.body.dataset.executed='image'}">
          <x-export-attack onload="void(0)"></x-export-attack>
          <svg xmlns="http://www.w3.org/2000/svg" onload="if(location.protocol==='file:'){document.title='svg-executed';document.body.dataset.executed='svg'}">
            <a href="javascript:document.title='svg-link-executed'" xlink:href="javascript:document.title='xlink-executed'" xmlns:xlink="http://www.w3.org/1999/xlink"><text>unsafe SVG link</text>
              <set attributeName="href" to="javascript:document.title='set-executed'" begin="0s"/>
              <animate attributeName="href" values="javascript:document.title='animate-executed'" dur="1s"/>
            </a>
          </svg>
          <svg><a id="dynamic-xlink"><text>script-created XLink</text></a></svg>
          <svg><style>.roundtrip { content: "&lt;img src=data:image/png,invalid onerror=document.title='style-executed'&gt;"; }</style></svg>
          <math onmouseover="document.title='math-executed'"><mi>x</mi></math>
          <a href="JaVa&#x09;ScRi&#x0a;Pt:document.title='link-executed'" ping="data:text/plain,ping">unsafe mixed/control link</a>
          <a href="vbscript:msgbox(1)">VBScript</a><a href="data:text/html,active">data navigation</a>
          <iframe srcdoc="&lt;script&gt;if(parent.location.protocol==='file:')parent.document.title='frame-executed'&lt;/script&gt;"></iframe>
          <iframe src="data:text/html,frame"></iframe>
          <form action="javascript:document.title='form-executed'"><span id="form-text">form text survives</span>
            <button formaction="data:text/html,submit">Submit</button>
          </form>
          <object data="data:text/html,object"></object><embed src="data:text/html,embed">
          <applet code="none"></applet><portal src="data:text/html,portal"></portal>
          <meta http-equiv="refresh" content="3600;url=data:text/html,refresh">
          <meta http-equiv="default-style" content="author-style">
          <base href="#author-base">
          <video poster="javascript:document.title='poster-executed'"></video>
          <div background="javascript:document.title='background-executed'" onpointerenter="document.title='pointer-executed'"
               style="width:expression(1);background-image:url('javascript:document.title=1')">unsafe CSS</div>
          <div style="background-image:u\72l('java\73 cript:document.title=2');height:expre\73sion(1)">escaped inline CSS</div>
          <div style="--c:red;background:var(--c) url(https://beacon.invalid/inline)">variable shorthand</div>
          <div style="background-image:url('&#160;data:image/png,/../../probe.png')">Unicode URL whitespace</div>
          <style>
          .attack { width:expression(1); background:url("javascript:document.title=3") }
          .escaped { background:u\72l("java\73 cript:document.title=4");height:expre\73sion(1) }
          .variable-shorthand { --c:red; background:var(--c) url(https://beacon.invalid/sheet) }
          .variable-fallback { background:var(--missing, url('javascript:document.title=5')) }
          .comment-strings::before { content:"/*" url(https://beacon.invalid/comment) "*/" }
          </style>
        </template>
        <script>
        const attacks = document.getElementById('attacks');
        document.body.append(attacks.content);
        attacks.remove();
        document.documentElement.insertBefore(document.createComment("--><script>document.title='comment-executed'<" + "/script><!--"), document.head);
        document.querySelector('#dynamic-xlink').setAttribute('xlink:href', "javascript:document.title='dynamic-xlink-executed'");
        document.documentElement.insertBefore(document.createElement('div'), document.head);
        document.documentElement.insertBefore(document.createTextNode('text before head'), document.head);
        const mismatchedSVG = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        const mismatchedRect = document.createElement('rect');
        mismatchedRect.id = 'namespace-cursor';
        mismatchedRect.setAttribute('cursor', 'url(https://example.invalid/cursor.png), auto');
        mismatchedSVG.append(mismatchedRect);
        document.body.append(mismatchedSVG);
        customElements.define('x-export-attack', class extends HTMLElement {
          static observedAttributes = ['onload'];
          attributeChangedCallback(name, oldValue, value) {
            if (value === null) this.getRootNode().querySelector('#picture')?.setAttribute('onerror', "document.title='reaction-executed'");
          }
        });
        Object.defineProperty(HTMLHtmlElement.prototype, 'outerHTML', {
          get() { return '<html><head><title>forged-export</title></head><body><img id="picture" src="data:image/png,invalid" onerror="document.title=\'prototype-executed\'"></body></html>'; }
        });
        </script>
        </body></html>
        """#
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
