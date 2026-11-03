import AppKit
import CanvasCore
import WebKit

/// The WebKit side of the cmux subset: runs validated commands against a browser tile's page.
/// Commands work whether or not the tile is on screen; a released page is rebuilt from its URL.
extension BrowserTile {
    /// `driver`: the terminal sending the command (`CmuxRouter.driver`), nil when unknown. A
    /// command that can act on the page (navigate, click, type, run script) takes the credit
    /// for what the page does next, as it starts and again as it ends (`NavigationCredit`).
    func perform(_ command: CmuxBrowserCommand, driver: ObjectID?) async throws -> JSONValue {
        let deadline: Date
        if case .wait(_, let timeoutMs) = command {
            deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        } else {
            deadline = Date().addingTimeInterval(30)
        }
        let webView = ensureWebView()
        switch command {
        case .navigate, .back, .forward, .reload, .urlGet:
            await markDriven()
        default:
            try await markDriven(deadline: deadline).get()
        }
        let acts = Self.acts(command)
        if acts { credit.agent(driver) }
        defer {
            if acts { credit.agent(driver) }
            scheduleSnapshotRefresh()
        }
        switch command {
        case .navigate(let url):
            load(url)
            return .object(["url": .string(url)])
        case .back:
            if webView.canGoBack { track(webView.goBack()) }
            return .object(location(webView))
        case .forward:
            if webView.canGoForward { track(webView.goForward()) }
            return .object(location(webView))
        case .reload:
            reload()
            return .object(location(webView))
        case .urlGet:
            var result = location(webView)
            result["title"] = .string(webView.title ?? "")
            return .object(result)
        case .eval(let script):
            return .object(["value": try await evaluate(script, in: webView, deadline: deadline)])
        case .snapshot(let interactive, let maxDepth):
            return try await call("return window.__canvasCmux.snapshot(interactive, maxDepth)",
                                  ["interactive": interactive, "maxDepth": maxDepth.map { $0 as Any } ?? NSNull()], in: webView, deadline: deadline)
        case .screenshot:
            return try await screenshot(webView)
        case .element(let action, let selector):
            return try await act(action.rawValue, selector, "", in: webView, deadline: deadline)
        case .type(let selector, let text):
            return try await act("type", selector, text, in: webView, deadline: deadline)
        case .fill(let selector, let text):
            return try await act("fill", selector, text, in: webView, deadline: deadline)
        case .press(let key):
            return try await call("return window.__canvasCmux.press(key)", ["key": key], in: webView, deadline: deadline)
        case .scroll(let dx, let dy):
            return try await call("return window.__canvasCmux.scroll(dx, dy)", ["dx": dx, "dy": dy], in: webView, deadline: deadline)
        case .wait(let condition, _):
            try await wait(for: condition, deadline: deadline)
            return .object(location(ensureWebView()))
        }
    }

    /// Whether a command can change the page's location or open a tile.
    private static func acts(_ command: CmuxBrowserCommand) -> Bool {
        switch command {
        case .navigate, .back, .forward, .reload, .eval, .element, .type, .fill, .press: true
        case .urlGet, .snapshot, .screenshot, .scroll, .wait: false
        }
    }

    /// `object.reload`: the page loaded again as the reload button loads it (a failed load is
    /// retried), whether or not the tile is on screen, credited to `driver`; then up to
    /// `timeoutMs` for it to finish loading.
    func reloadPage(driver: ObjectID?, timeoutMs: Int) async throws -> JSONValue {
        await markDriven()
        credit.agent(driver)
        defer {
            credit.agent(driver)
            scheduleSnapshotRefresh()
        }
        reload()
        var loaded = false
        if timeoutMs > 0 {
            do {
                try await wait(for: .loadState(.complete), deadline: Date().addingTimeInterval(Double(timeoutMs) / 1000))
                loaded = true
            } catch let error as CmuxError where error.code == "timeout" {}
        }
        var result = location(ensureWebView())
        result["id"] = .string(objectID)
        if let failure = loadFailure {
            result["failed"] = .string(failure.reason)
            loaded = false
        }
        result["loaded"] = .bool(loaded)
        return .object(result)
    }

    private func location(_ webView: WKWebView) -> [String: JSONValue] {
        ["url": .string(webView.url?.absoluteString ?? object.props["url"]?.string ?? "about:blank")]
    }

    private func act(_ action: String, _ selector: String, _ text: String, in webView: WKWebView, deadline: Date) async throws -> JSONValue {
        try await call("return window.__canvasCmux.act(action, selector, text)", ["action": action, "selector": selector, "text": text], in: webView, deadline: deadline)
    }

    // MARK: Waits

    /// Checks the condition, then parks until the page changes; never polls.
    func wait(for condition: CmuxWaitCondition, deadline: Date) async throws {
        while true {
            guard board.objects[objectID] != nil else { throw CmuxError("not_found", "surface \(objectID) was closed") }
            let webView = ensureWebView()
            do {
                if try await satisfied(condition, in: webView, deadline: deadline) { return }
            } catch ScriptError.documentChanged {
                if Date() < deadline { continue }
            }
            guard Date() < deadline else { throw CmuxError("timeout", "timed out waiting for \(Self.describe(condition))") }
            await nextChange(before: deadline)
        }
    }

    private func satisfied(_ condition: CmuxWaitCondition, in webView: WKWebView, deadline: Date) async throws -> Bool {
        switch condition {
        case .urlContains(let fragment):
            return webView.url?.absoluteString.contains(fragment) == true
        case .loadState(let state):
            guard commitsSinceRelease > 0 else { return false }
            // `interactive` only needs the destination document to have replaced the old one
            // (DOMContentLoaded); `complete` also waits for WebKit to finish every subresource.
            switch state {
            case .interactive: guard uncommittedNavigations.isEmpty else { return false }
            case .complete: guard pendingNavigations.isEmpty, !webView.isLoading else { return false }
            }
            let ready: String?
            do {
                ready = try await call("return document.readyState", [:], in: webView, deadline: deadline, recheckOnCommit: true).string
            } catch is CmuxError {
                return false
            }
            return state == .complete ? ready == "complete" : ready == "interactive" || ready == "complete"
        case .selector(let selector):
            let remaining = max(0, Int(deadline.timeIntervalSinceNow * 1000))
            do {
                return try await call("return await window.__canvasCmux.waitFor(selector, timeout)",
                                      ["selector": selector, "timeout": remaining], in: webView, deadline: deadline, recheckOnCommit: true) == .bool(true)
            } catch let error as CmuxError where error.code != "invalid_params" {
                return false
            }
        }
    }

    private static func describe(_ condition: CmuxWaitCondition) -> String {
        switch condition {
        case .loadState(let state): "load state \(state.rawValue)"
        case .urlContains(let fragment): "a URL containing \(fragment)"
        case .selector(let selector): "selector \(selector)"
        }
    }

    // MARK: JavaScript

    /// Runs `body` as an async function in the automation world, installing the helper if the
    /// document predates it. Results must be JSON-shaped.
    private func call(_ body: String, _ arguments: [String: Any], in webView: WKWebView, deadline: Date, recheckOnCommit: Bool = false) async throws -> JSONValue {
        try await javascript(deadline: deadline, recheckOnCommit: recheckOnCommit) { finish in
            webView.callAsyncJavaScript(BrowserScripts.ensure + body, arguments: arguments, in: nil, in: BrowserScripts.world) {
                finish($0.map { Optional($0) })
            }
        }
    }

    /// `browser.eval` in the page's own world: an expression's promise is awaited; statements
    /// run as a program (see `CmuxEval`). Neither is subject to the page's CSP.
    private func evaluate(_ script: String, in webView: WKWebView, deadline: Date) async throws -> JSONValue {
        try await javascript(deadline: deadline) { finish in
            if let body = CmuxEval.awaitingBody(script) {
                webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) {
                    finish($0.map { Optional($0) })
                }
            } else {
                webView.evaluateJavaScript(script) { value, error in
                    if let error { finish(.failure(error)) }
                    else { finish(.success(value)) }
                }
            }
        }
    }

    enum ScriptError: Error { case documentChanged }

    struct ScriptCall {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timer: Timer
        let recheckOnCommit: Bool
    }

    private func javascript(deadline: Date, recheckOnCommit: Bool = false, start: (@escaping @MainActor (Result<Any?, Error>) -> Void) -> Void) async throws -> JSONValue {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let id = UUID()
                // Even a zero-budget condition check needs one WebKit round trip.
                let limit = deadline.addingTimeInterval(0.1)
                let timer = Timer(timeInterval: max(0, limit.timeIntervalSinceNow), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.finishJavaScript(id, with: .failure(CmuxError("timeout", "timed out waiting for page JavaScript")))
                    }
                }
                scriptCalls[id] = ScriptCall(continuation: continuation, timer: timer, recheckOnCommit: recheckOnCommit)
                RunLoop.main.add(timer, forMode: .common)
                start { [weak self] result in
                    switch result {
                    case .success(let value): self?.finishJavaScript(id, with: .success(Self.json(value)))
                    case .failure(let error): self?.finishJavaScript(id, with: .failure(Self.cmuxError(error)))
                    }
                }
            }
        } catch ScriptError.documentChanged where !recheckOnCommit {
            throw CmuxError("js_error", "the page became unavailable before JavaScript returned")
        }
    }

    private func finishJavaScript(_ id: UUID, with result: Result<JSONValue, Error>) {
        guard let call = scriptCalls.removeValue(forKey: id) else { return }
        call.timer.invalidate()
        call.continuation.resume(with: result)
    }

    func invalidateJavaScriptWaits() {
        let ids = scriptCalls.compactMap { $0.value.recheckOnCommit ? $0.key : nil }
        for id in ids {
            finishJavaScript(id, with: .failure(ScriptError.documentChanged))
        }
    }

    func invalidateJavaScript() {
        let calls = scriptCalls.values
        scriptCalls.removeAll()
        for call in calls {
            call.timer.invalidate()
            call.continuation.resume(throwing: ScriptError.documentChanged)
        }
    }

    /// Page exceptions named like `not_found: …` (the helper's own failures) keep their code.
    static func cmuxError(_ error: Error) -> CmuxError {
        let nsError = error as NSError
        guard nsError.domain == WKError.errorDomain else { return CmuxError("js_error", nsError.localizedDescription) }
        switch WKError.Code(rawValue: nsError.code) {
        case .javaScriptExceptionOccurred:
            let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String ?? nsError.localizedDescription
            if let match = message.firstMatch(of: /^(not_found|invalid_params): (.*)$/) {
                return CmuxError(String(match.1), String(match.2))
            }
            // Awaited expressions report line 0 (the async wrapper), which says nothing.
            let line = (nsError.userInfo["WKJavaScriptExceptionLineNumber"] as? NSNumber).flatMap { $0.intValue > 0 ? " (line \($0))" : nil } ?? ""
            return CmuxError("js_error", message + line)
        case .javaScriptResultTypeIsUnsupported:
            return CmuxError("js_error", "the script's result can't be serialized: return JSON-like values, not DOM nodes or functions (a promise is awaited only when the script is one expression)")
        default:
            return CmuxError("js_error", nsError.localizedDescription)
        }
    }

    /// Foundation values from WebKit (NSNumber, NSString, NSArray, NSDictionary, NSNull, NSDate).
    static func json(_ value: Any?) -> JSONValue {
        switch value {
        case nil, is NSNull: return .null
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String: return .string(string)
        case let date as Date: return .number(date.timeIntervalSince1970 * 1000)
        case let array as [Any]: return .array(array.map { json($0) })
        case let object as [String: Any]: return .object(object.mapValues { json($0) })
        // WebKit's callback overlay boxes undefined as Optional<Any>.none inside Any.
        case let value? where (value as AnyObject) is NSNull: return .null
        default: return .string(String(describing: value!))
        }
    }

    // MARK: Screenshot

    /// The viewport at one image pixel per CSS pixel, which is what omp compares against
    /// `innerWidth`/`innerHeight`.
    private func screenshot(_ webView: WKWebView) async throws -> JSONValue {
        let size = webView.bounds.size
        guard size.width >= 1, size.height >= 1 else { throw CmuxError("unavailable", "the browser tile has no visible area") }
        let zoom = webView.pageZoom * webView.magnification
        let width = Int((size.width / zoom).rounded()), height = Int((size.height / zoom).rounded())
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image: NSImage
        do {
            image = try await webView.takeSnapshot(configuration: configuration)
        } catch {
            throw CmuxError("unavailable", "screenshot failed: \(error.localizedDescription)")
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CmuxError("unavailable", "screenshot buffer unavailable")
        }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CmuxError("unavailable", "PNG encoding failed") }
        return .object([
            "png_base64": .string(png.base64EncodedString()),
            "width": .number(Double(width)),
            "height": .number(Double(height)),
            "url": .string(webView.url?.absoluteString ?? ""),
        ])
    }
}
