import AppKit
import WebKit

@testable import CanvasApp
@testable import CanvasCore

@main
@MainActor
private enum HtmlGoTo {
    private struct Failure: Error { let message: String }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
    }

    private static func wait(_ message: String, until condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure(message: message)
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    private static func key(_ characters: String, code: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: code)!
    }

    private static func js(_ web: WKWebView, _ expression: String) async -> Any? {
        try? await web.evaluateJavaScript(expression)
    }

    private static func call(_ web: WKWebView, target: [String: String]) async throws -> [String: Any] {
        let result = try await web.callAsyncJavaScript("return await canvasKit.goTo(target)", arguments: ["target": target], contentWorld: .page)
        guard let result = result as? [String: Any] else { throw Failure(message: "goTo returned no object") }
        return result
    }

    private static func refused(_ web: WKWebView, target: [String: String]) async throws -> String {
        do {
            _ = try await call(web, target: target)
        } catch let error as Failure {
            throw error
        } catch {
            let detail = String(describing: error)
            try require(!detail.contains("is not a function") && !detail.contains("unknown message type"), "the API must exist before a refusal can count: \(detail)")
            return detail
        }
        throw Failure(message: "goTo accepted a forbidden request")
    }

    private static func textViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    private static func noteLinkPoint(_ note: NoteTile) -> NSPoint? {
        for text in textViews(note) where !text.isEditable {
            guard let storage = text.textStorage, let layout = text.textLayoutManager,
                  let content = layout.textContentManager else { continue }
            layout.ensureLayout(for: content.documentRange)
            var point: NSPoint?
            storage.enumerateAttribute(.noteLink, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                guard value != nil, let start = content.location(content.documentRange.location, offsetBy: range.location),
                      let end = content.location(start, offsetBy: range.length), let textRange = NSTextRange(location: start, end: end) else { return }
                layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
                    point = text.convert(NSPoint(x: rect.midX + text.textContainerOrigin.x, y: rect.midY + text.textContainerOrigin.y), to: nil)
                    return false
                }
                if point != nil { stop.pointee = true }
            }
            if let point { return point }
        }
        return nil
    }

    static func main() async throws {
        guard let home = ProcessInfo.processInfo.environment["EASL_HOME"] else { fatalError("run.py must supply an isolated home") }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let root = URL(fileURLWithPath: home).appendingPathComponent("board")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let board = Board(id: "brd_htmlgoto", root: root)
        let canvas = CanvasView(board: board, viewport: nil, remote: nil)
        canvas.hasHorizontalScroller = false
        canvas.hasVerticalScroller = false
        let window = CanvasWindow(contentRect: NSRect(x: 40, y: 40, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
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
        let target = board.create(type: .note, props: .object(["markdown": .string("Destination"), "key": .string("destination")]),
                                  frame: Frame(x: 6000, y: 6000, w: 360, h: 220))
        let foreignBoard = Board(id: "brd_other", root: root.appendingPathComponent("other"))
        let foreign = foreignBoard.create(type: .note, props: .object(["markdown": .string("Other board"), "key": .string("foreign")]))
        let html = """
        <canvas-object id="\(target.id)">Destination by id</canvas-object>
        <canvas-object key="destination">Destination by key</canvas-object>
        <script>
        window.refusals = [];
        const attempt = () => canvasKit.goTo({id:'\(target.id)'}).then(() => refusals.push('ACCEPTED'), e => refusals.push(String(e)));
        attempt();
        setTimeout(attempt, 250);
        </script>
        """
        canvas.show(Viewport(rect: Frame(x: -410, y: -310, w: 1000, h: 700), zoom: 1))
        let source = board.create(type: .html, props: .object(["html": .string(html)]), frame: Frame(x: -350, y: -250, w: 700, h: 500))
        try await wait("HTML tile did not build") { (canvas.tiles[source.id]?.content as? HtmlTile)?.webView != nil }
        guard let tile = canvas.tiles[source.id]?.content as? HtmlTile, let web = tile.webView else { throw Failure(message: "HTML tile disappeared") }
        try await wait("kit API did not load") { await js(web, "typeof canvasKit?.goTo") as? String == "function" }
        try await wait("load and timer calls did not finish") { (await js(web, "window.refusals?.length") as? Int) == 2 }
        let refusals = await js(web, "window.refusals") as? [String] ?? []
        try require(refusals.count == 2 && refusals.allSatisfy { !$0.contains("ACCEPTED") }, "load and timer calls must be refused")
        let initial = canvas.viewport
        try require(canvas.selection != [target.id] && !initial.rect.rect.intersects(target.frame.rect), "target must start unselected and offscreen")
        _ = await js(web, "document.querySelector('canvas-object').click()")
        try await Task.sleep(for: .milliseconds(100))
        try require(canvas.viewport.matches(initial) && canvas.selection != [target.id], "script-dispatched click must not navigate")
        _ = try await refused(web, target: ["id": target.id])
        print("PASS load, timer, and script-dispatched click cannot navigate")

        func arm() async throws {
            canvas.setSelection([])
            var point = NSPoint.zero
            try await wait("gesture point is not inside the live HTML page") {
                window.layoutIfNeeded()
                guard !web.isLoading, !web.isHiddenOrHasHiddenAncestor else { return false }
                point = web.convert(NSPoint(x: web.bounds.width - 30, y: web.bounds.height / 2), to: nil)
                guard let content = window.contentView, let hit = content.hitTest(content.convert(point, from: nil)) else { return false }
                return hit === web || hit.isDescendant(of: web)
            }
            NSApp.sendEvent(mouse(.leftMouseDown, at: point, in: window))
            NSApp.sendEvent(mouse(.leftMouseUp, at: point, in: window))
        }

        func back(to viewport: Viewport) throws {
            try require(canvas.canNavigateBack, "goTo must record Navigate Back")
            canvas.navigateBack()
            try require(canvas.viewport.matches(viewport), "Navigate Back must restore the source viewport")
        }

        for lookup in [["id": target.id], ["key": "destination"]] {
            let before = canvas.viewport
            try await arm()
            let reply = try await call(web, target: lookup)
            try require(reply["id"] as? String == target.id, "goTo must resolve the requested object")
            try require(canvas.selection == [target.id], "goTo must select the destination")
            try require(canvas.viewport.rect.rect.intersects(target.frame.rect) && !canvas.viewport.matches(before), "goTo must reveal the offscreen destination")
            try back(to: before)
        }
        print("PASS id and key navigate, select, and return through Back")
        canvas.setSelection([])

        guard let bounds = try await web.evaluateJavaScript("""
        (() => { const r = document.querySelector('canvas-object[key]').getBoundingClientRect();
        return {x:r.x+r.width/2,y:r.y+r.height/2}; })()
        """) as? [String: Double], let x = bounds["x"], let y = bounds["y"] else {
            throw Failure(message: "key component has no native click geometry")
        }
        let scale = web.pageZoom * web.magnification
        var componentPoint = NSPoint.zero
        try await wait("key component is not inside the live HTML page") {
            window.layoutIfNeeded()
            componentPoint = web.convert(NSPoint(x: CGFloat(x) * scale, y: web.isFlipped ? CGFloat(y) * scale : web.bounds.height - CGFloat(y) * scale), to: nil)
            guard let content = window.contentView, let hit = content.hitTest(content.convert(componentPoint, from: nil)) else { return false }
            return !web.isHiddenOrHasHiddenAncestor && (hit === web || hit.isDescendant(of: web))
        }
        NSApp.sendEvent(mouse(.leftMouseDown, at: componentPoint, in: window))
        NSApp.sendEvent(mouse(.leftMouseUp, at: componentPoint, in: window))
        try await wait("native canvas-object key click did not navigate") {
            canvas.selection == [target.id] && canvas.viewport.rect.rect.intersects(target.frame.rect)
        }
        try back(to: initial)
        print("PASS native canvas-object key click navigates, selects, and records Back")

        _ = try await refused(web, target: ["id": target.id])
        try await arm()
        try await Task.sleep(for: .milliseconds(1600))
        _ = try await refused(web, target: ["id": target.id])
        print("PASS permits are one-shot and expire")

        for lookup in [["id": "obj_missing"], ["key": "missing"], ["id": foreign.id], ["key": "foreign"]] {
            let before = canvas.viewport
            try await arm()
            let error = try await refused(web, target: lookup)
            try require(error.contains("not found") || error.contains("no object") || error.contains("notFound"), "missing or foreign target must report lookup failure: \(error)")
            try require(canvas.viewport.matches(before), "failed lookup must not move the view")
        }
        print("PASS missing and other-board targets report errors without navigation")

        for lookup in [["id": target.id, "zoom": "fit"], ["id": target.id, "key": "destination"], [:]] {
            try await arm()
            _ = try await refused(web, target: lookup)
        }
        try await arm()
        let extraArgumentRefused = try await web.callAsyncJavaScript("""
        try { await canvasKit.goTo({id}, {zoom:'fit'}); return false; }
        catch { return true; }
        """, arguments: ["id": target.id], contentWorld: .page) as? Bool
        try require(extraArgumentRefused == true && canvas.viewport.matches(initial), "the removed zoom argument must reject without navigation")
        print("PASS zoom, ambiguous targets, and empty targets are rejected")

        canvas.setSelection([])
        try require(web.takeKeyboard(), "HTML page must take keyboard for Enter")
        NSApp.sendEvent(key("a", code: 0, in: window))
        _ = try await refused(web, target: ["id": target.id])
        _ = await js(web, "document.querySelector('canvas-object[id]').focus()")
        NSApp.sendEvent(key("\r", code: 36, in: window))
        try await wait("native Enter on the id component did not navigate") {
            canvas.selection == [target.id] && canvas.viewport.rect.rect.intersects(target.frame.rect)
        }
        try back(to: initial)
        print("PASS only native Enter, not ordinary typing, authorizes keyboard navigation")

        _ = try board.update(target.id, frame: Frame(x: 6000, y: 6000, w: 2000, h: 1200))
        try await arm()
        _ = try await call(web, target: ["id": target.id])
        try require(canvas.viewport.zoom < initial.zoom && canvas.selection == [target.id], "oversized targets must fit exactly like question context links")
        try back(to: initial)
        print("PASS oversized targets inherit existing fitting behavior")

        let note = board.create(type: .note, props: .object(["markdown": .string("[Destination](easl:key/destination)")]), frame: Frame(x: -350, y: 600, w: 700, h: 240))
        canvas.show(Viewport(rect: Frame(x: -410, y: 540, w: 1000, h: 700), zoom: 1))
        try await wait("note link did not lay out") {
            guard let tile = canvas.tiles[note.id]?.content as? NoteTile else { return false }
            return noteLinkPoint(tile) != nil
        }
        guard let noteTile = canvas.tiles[note.id]?.content as? NoteTile, let notePoint = noteLinkPoint(noteTile) else { throw Failure(message: "note link disappeared") }
        let noteBefore = canvas.viewport
        canvas.setSelection([])
        NSApp.sendEvent(mouse(.leftMouseDown, at: notePoint, in: window))
        NSApp.sendEvent(mouse(.leftMouseUp, at: notePoint, in: window))
        try await wait("note link did not navigate") { canvas.selection == [target.id] && canvas.viewport.rect.rect.intersects(target.frame.rect) }
        try back(to: noteBefore)
        print("PASS native Markdown key link selects, navigates, and supports Back")

        canvas.show(initial)
        try await arm()
        board.deactivate()
        let closed = try await refused(web, target: ["id": target.id])
        try require(closed.contains("closed"), "closed board must report closure: \(closed)")
        print("PASS closed boards refuse navigation")
    }
}
