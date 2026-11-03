import AppKit
import WebKit
import CanvasCore

@testable import CanvasApp

@main @MainActor
private enum ClearBrowsingData {
    static var failures = 0

    static func require(_ value: Bool, _ message: String) {
        if !value { FileHandle.standardError.write(Data("FAIL \(message)\n".utf8)); failures += 1 }
    }

    static func button(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(title, in: $0) }.first
    }

    static func main() async throws {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let profiles: [(String, WKWebsiteDataStore)] = [
            ("default", BrowserProfile.store),
            ("local", BrowserProfile.store(named: "local")),
            ("remote-only", WKWebsiteDataStore(forIdentifier: BrowserProfile.identifier(profile: "remote-only", home: AppPaths.support))),
            ("closed-board-only", WKWebsiteDataStore(forIdentifier: BrowserProfile.identifier(profile: "closed-board-only", home: AppPaths.support))),
        ]
        for (_, store) in profiles {
            let cookie = HTTPCookie(properties: [.domain: "clear-regression.invalid", .path: "/", .name: "signed-in", .value: "fixture", .expires: Date().addingTimeInterval(3600)])!
            await store.httpCookieStore.setCookie(cookie)
        }
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASL_HOME"]!).appendingPathComponent("extension")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Clear regression","version":"1.0"}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><title>Extension sentinel</title>".utf8).write(to: folder.appendingPathComponent("page.html"))
        let configuration = WKWebExtensionController.Configuration(identifier: UUID())
        configuration.defaultWebsiteDataStore = BrowserProfile.store
        let pages = WKWebViewConfiguration()
        pages.websiteDataStore = BrowserProfile.store
        configuration.webViewConfiguration = pages
        let controller = WKWebExtensionController(configuration: configuration)
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        try controller.load(context)
        let page = WKWebView(frame: .zero, configuration: context.webViewConfiguration!)
        let loader = Load()
        let url = context.baseURL.appendingPathComponent("page.html")
        try await loader.load(page, url: url)
        _ = try await page.evaluateJavaScript("localStorage.setItem('clear-regression','kept')")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            BrowserProfile.confirmClear(in: window, profiles: ["local"]) { done.resume() }
            Task { @MainActor in
                let deadline = ContinuousClock.now + .seconds(5)
                while window.attachedSheet == nil && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
                guard let content = window.attachedSheet?.contentView, let clear = button("Clear", in: content) else { fatalError("Clear sheet did not appear") }
                clear.performClick(nil)
            }
        }
        for (name, store) in profiles {
            let cookies = await store.httpCookieStore.allCookies()
            require(!cookies.contains { $0.name == "signed-in" }, "\(name) site cookies cleared")
            print("\(name)_site_cookie_count=\(cookies.filter { $0.name == "signed-in" }.count)")
        }
        try await loader.load(page, url: url)
        let sentinel = try await page.evaluateJavaScript("localStorage.getItem('clear-regression')") as? String
        require(sentinel == "kept", "extension-origin localStorage preserved")
        print("extension_localStorage=\(sentinel ?? "null")")
        try controller.unload(context)
        window.close()
        if failures != 0 { exit(1) }
        print("PASS all saved browser profiles clear site cookies and keep extension-origin storage")
    }
}

@MainActor
private final class Load: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Error>?
    func load(_ page: WKWebView, url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            page.navigationDelegate = self
            page.load(URLRequest(url: url))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
}
