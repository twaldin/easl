import AppKit
import CanvasCore
import CryptoKit
import WebKit

/// Compiled network rule lists, one per distinct allowlist, shared by every HTML tile.
@MainActor
enum HtmlRuleLists {
    private static var compiled: [String: WKContentRuleList] = [:]

    static func list(allowing hosts: [String]) async throws -> WKContentRuleList {
        let json = HtmlKit.networkRules(allow: hosts)
        let identifier = "canvas-html-" + SHA256.hash(data: Data(json.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        if let list = compiled[identifier] { return list }
        guard let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else {
            throw HtmlError.malformed("content rule list \(identifier) did not compile")
        }
        compiled[identifier] = list
        return list
    }
}

/// Serves `canvas-kit://html/<tileId>` (the tile's html behind the kit head), `/kit/…` from
/// resources/kit, and images: `<img src="out/chart.png">` (board-relative, resolved against the
/// page URL) or an absolute path inside the board root or the temp directory
/// (`LocalImage.pageFile`). Everything else is 404, including other tiles' pages.
@MainActor
final class HtmlSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The tile whose page this serves; a pooled measure page (`HtmlMeasurePool`) serves one
    /// tile per measure, and none while it waits.
    weak var tile: HtmlTile?
    private static let kitRoot = AppPaths.asset("kit")
    /// Kit files never change while the app runs; mapped reads keep repeat loads cheap.
    private static var kitCache: [String: Data] = [:]
    /// Image requests still being read; a task WebKit stopped meanwhile gets no reply.
    private var reading: Set<ObjectIdentifier> = []

    init(tile: HtmlTile?) {
        self.tile = tile
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == HtmlKit.host, let tile else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        if url.path == HtmlKit.pageURL(tile: tile.objectID).path {
            respond(task, url: url, data: Data(HtmlKit.document(html: tile.html).utf8), type: "text/html", cache: "no-store")
        } else if let kitRoot = Self.kitRoot, let file = HtmlKit.kitFile(requestPath: url.path, kitRoot: kitRoot),
                  let data = Self.kitCache[file.path] ?? (try? Data(contentsOf: file, options: .alwaysMapped)) {
            Self.kitCache[file.path] = data
            respond(task, url: url, data: data, type: HtmlKit.mimeType(file), cache: "max-age=31536000, immutable")
        } else if let file = LocalImage.pageFile(requestPath: url.path, root: tile.boardRoot) {
            let key = ObjectIdentifier(task)
            reading.insert(key)
            Task { @MainActor [weak self] in
                let data = await offPool { try? Data(contentsOf: file) }
                guard let self, self.reading.remove(key) != nil else { return }
                if let data {
                    self.respond(task, url: url, data: data, type: HtmlKit.mimeType(file), cache: "no-store")
                } else {
                    self.notFound(task, url: url)
                }
            }
        } else {
            notFound(task, url: url)
        }
    }

    private func notFound(_ task: any WKURLSchemeTask, url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
        task.didReceive(response)
        task.didReceive(Data("not found".utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        reading.remove(ObjectIdentifier(task))
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, type: String, cache: String) {
        let headers = ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": cache]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }
}

/// The page's one native channel (`window.webkit.messageHandlers.canvas`). Only the tile's own
/// top-level canvas-kit document may post; bodies are validated by `HtmlMessage` before use.
@MainActor
final class HtmlChannelHandler: NSObject, WKScriptMessageHandlerWithReply {
    /// As `HtmlSchemeHandler.tile`.
    weak var tile: HtmlTile?

    init(tile: HtmlTile?) {
        self.tile = tile
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let tile, message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == HtmlKit.scheme,
              let source = message.webView, source === tile.webView || source === tile.renderWebView else { return (nil, "not allowed") }
        guard let body = message.body as? [String: Any], JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return (nil, HtmlError.malformed("message must be an object").description) }
        do {
            let parsed = try HtmlMessage.parse(data)
            let reply = try await tile.handle(parsed, rendering: source === tile.renderWebView)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply), options: .fragmentsAllowed)
            return (object, nil)
        } catch let error as HtmlError {
            return (nil, error.description)
        } catch let error as BoardError {
            return (nil, "\(error)")
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}

/// HTML tiles never take keyboard focus: the prompt target terminal keeps it while the user
/// clicks through explainers. Clicks still work, including on the (never key) dev window.
final class HtmlWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var lastClick: (time: TimeInterval, flags: NSEvent.ModifierFlags)?

    /// The modifiers of the last click on the page when it was within `seconds` (a link the page
    /// follows just after one is the user's: the web view tells a script's navigation from a click
    /// only by its type, and `a.click()` looks like one).
    func recentClick(within seconds: TimeInterval = 2) -> NSEvent.ModifierFlags? {
        guard let lastClick, ProcessInfo.processInfo.systemUptime - lastClick.time <= seconds else { return nil }
        return lastClick.flags
    }

    override func mouseDown(with event: NSEvent) {
        lastClick = (ProcessInfo.processInfo.systemUptime, event.modifierFlags)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        lastClick = (ProcessInfo.processInfo.systemUptime, event.modifierFlags)
        super.mouseUp(with: event)
    }

    /// WebKit's context menu leads with Mention: the element under the right-click.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        CanvasView.insertMention(into: menu, in: self, for: event)
    }
}
