import AppKit
import WebKit

@testable import CanvasApp
@testable import CanvasCore

@main
@MainActor
private enum HtmlSend {
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

    private static func pageHTML(marker: String, autoSend: Bool) -> String {
        """
        <button id="go" style="width:120px;height:40px">Go</button>
        <script>
        window.marker = "\(marker)";
        document.getElementById("go").addEventListener("click", () => {
          window.domSent = window.canvasKit.send({tag: "dom"});
        });
        if (\(autoSend)) {
          window.canvasKit.send({tag: "load"});
          setTimeout(() => window.canvasKit.send({tag: "timer"}), 250);
        }
        </script>
        """
    }

    private static func js(_ web: WKWebView, _ expression: String) async -> Any? {
        (try? await web.evaluateJavaScript(expression)) as Any?
    }

    private static func pageSend(_ web: WKWebView, _ tag: String) async throws {
        _ = try await web.callAsyncJavaScript("await window.canvasKit.send({tag: tag})", arguments: ["tag": tag], contentWorld: .page)
    }

    private static func wait(until condition: @MainActor () -> Bool, _ message: String, limit: Duration = .seconds(8)) async throws {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw Failure(message: message)
    }

    private static func waitMarker(_ marker: String, in web: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if await js(web, "window.marker") as? String == marker { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw Failure(message: "the replacement document must load")
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    private static func key(in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                         isARepeat: false, keyCode: 0)!
    }

    static func main() async throws {
        guard ProcessInfo.processInfo.environment["EASL_HOME"] != nil else {
            fatalError("run.py must provide a disposable EASL_HOME")
        }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("html-send-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = Board(id: "brd_htmlsend", root: root)
        let canvas = CanvasView(board: board, viewport: nil, remote: nil)
        let window = CanvasWindow(contentRect: NSRect(x: 40, y: 40, width: 1000, height: 700),
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
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(root.path)]))
        try board.reportLifecycle(tile: terminal.id, kind: "omp", state: .idle, message: nil, seq: 1, source: "canvas-omp", protocol: 3)
        let object = board.create(type: .html, props: .object(["html": .string(pageHTML(marker: "GEN1", autoSend: true))]), frame: frame, caller: terminal.id)
        let tile = try await htmlTile(canvas, object.id)
        let web = try await page(in: tile)
        try await loaded(web)
        window.layoutIfNeeded()
        try await wait(until: { (board.htmlMessages[terminal.id]?.count ?? 0) >= 2 }, "load and timer sends must queue without a gesture")
        let automatic = board.htmlMessages[terminal.id] ?? []
        try require(automatic.allSatisfy { $0.mayStartTurn == false }, "a load or timer send must not start a turn: \(automatic.map(\.mayStartTurn))")
        check("load and timer sends stayed inert")

        let inside = web.convert(NSPoint(x: web.bounds.width - 30, y: web.bounds.height / 2), to: nil)
        NSApp.sendEvent(mouse(.leftMouseDown, at: inside, in: window))
        try await pageSend(web, "native")
        guard let authorized = board.htmlMessages[terminal.id]?.last else {
            throw Failure(message: "the native send must be queued")
        }
        try require(authorized.text == "{\"tag\":\"native\"}" && authorized.mayStartTurn == true,
                    "a native mouse down in the tile must authorize one send, got \(authorized.text) mayStartTurn=\(String(describing: authorized.mayStartTurn))")
        check("native mouse down authorized one send")

        try await pageSend(web, "again")
        try require(board.htmlMessages[terminal.id]?.last?.mayStartTurn == false, "one native click must not authorize a second send")
        NSApp.sendEvent(mouse(.leftMouseUp, at: inside, in: window))
        try await pageSend(web, "up")
        try require(board.htmlMessages[terminal.id]?.last?.text == "{\"tag\":\"up\"}" && board.htmlMessages[terminal.id]?.last?.mayStartTurn == false,
                    "mouse up is the same click, not a second gesture")
        check("mouse up and a second send stayed inert")

        _ = await js(web, "document.getElementById('go').click()")
        try await wait(until: { board.htmlMessages[terminal.id]?.last?.text == "{\"tag\":\"dom\"}" }, "the DOM click handler must send")
        try require(board.htmlMessages[terminal.id]?.last?.mayStartTurn == false, "a DOM click must not arm a permit")
        check("DOM click did not authorize")

        NSApp.sendEvent(mouse(.leftMouseDown, at: inside, in: window))
        try await Task.sleep(for: .milliseconds(1600))
        try await pageSend(web, "late")
        try require(board.htmlMessages[terminal.id]?.last?.mayStartTurn == false, "a permit expires after 1.5 seconds")
        check("expired permit stayed inert")

        NSApp.sendEvent(mouse(.leftMouseDown, at: NSPoint(x: 4, y: 4), in: window))
        try await pageSend(web, "outside")
        try require(board.htmlMessages[terminal.id]?.last?.mayStartTurn == false, "a click outside the tile must not arm its permit")
        check("outside click did not authorize")
        try await Task.sleep(for: .seconds(10))

        let reloadGestureAt = ContinuousClock.now
        NSApp.sendEvent(mouse(.leftMouseDown, at: inside, in: window))
        try board.update(object.id, props: .object(["html": .string(pageHTML(marker: "GEN2", autoSend: false))]))
        try await waitMarker("GEN2", in: web)
        try await pageSend(web, "reloaded")
        try require(ContinuousClock.now - reloadGestureAt < .milliseconds(1500),
                    "the post-reload send must complete before the old permit would expire")
        try require(board.htmlMessages[terminal.id]?.last?.mayStartTurn == false, "a reload must drop the previous document's permit")
        check("reload reset the permit")

        NSApp.sendEvent(mouse(.leftMouseDown, at: inside, in: window))
        try await pageSend(web, "after-reload")
        try require(board.htmlMessages[terminal.id]?.last?.mayStartTurn == true, "a new native click in the replacement document must authorize again")
        check("a fresh click authorized the replacement document")

        try require(window.makeFirstResponder(canvas.document), "the canvas must hold the keyboard")
        NSApp.sendEvent(key(in: window))
        try await pageSend(web, "canvas-key")
        try require(board.htmlMessages[terminal.id]?.last?.mayStartTurn == false, "a key while the canvas owns the keyboard must not arm the page")
        try require(web.takeKeyboard(), "the tile must be able to take the keyboard")
        NSApp.sendEvent(key(in: window))
        try await pageSend(web, "tile-key")
        try require(board.htmlMessages[terminal.id]?.last?.mayStartTurn == true, "a native key while the tile owns the keyboard must authorize one send")
        try await pageSend(web, "same-key")
        try require(board.htmlMessages[terminal.id]?.last?.mayStartTurn == false, "one native key must not authorize a second send")
        check("keyboard ownership restricted the key gesture")
        check("native send gate held")
    }

    private static func htmlTile(_ canvas: CanvasView, _ id: ObjectID) async throws -> HtmlTile {
        for _ in 0..<400 {
            if let tile = canvas.tiles[id]?.content as? HtmlTile { return tile }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure(message: "\(id) is not an HTML tile")
    }

    private static func page(in html: HtmlTile) async throws -> HtmlWebView {
        for _ in 0..<400 {
            if let web = html.webView { return web }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure(message: "HTML tile built no web view")
    }

    private static func loaded(_ web: WKWebView) async throws {
        for _ in 0..<240 {
            let marker = await js(web, "window.marker") as? String
            let kit = await js(web, "typeof window.canvasKit") as? String
            if marker == "GEN1", kit == "object" { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure(message: "the HTML page did not load")
    }
}
