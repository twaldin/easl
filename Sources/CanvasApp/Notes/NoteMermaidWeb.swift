import AppKit
import CanvasCore
import WebKit

@MainActor
final class NoteMermaidWeb: NoteMermaidBackend {
    private final class Job {
        let key: NoteMermaid.Key
        let completion: @MainActor (NoteMermaid.Outcome) -> Void
        var preparation: Task<Void, Never>?
        var page: Page?

        init(key: NoteMermaid.Key, completion: @escaping @MainActor (NoteMermaid.Outcome) -> Void) {
            self.key = key
            self.completion = completion
        }
    }

    private var jobs: [UUID: Job] = [:]
    private var idle: [Page] = []
    private var idleRelease: Timer?
    private var rules: WKContentRuleList?
    private var ruleLoad: Task<Void, Error>?
    private var assets: Assets?

    func start(_ key: NoteMermaid.Key, completion: @escaping @MainActor (NoteMermaid.Outcome) -> Void) -> (@MainActor () -> Void) {
        let id = UUID()
        let job = Job(key: key, completion: completion)
        jobs[id] = job
        job.preparation = Task { [weak self] in
            guard let self else { return }
            do {
                if self.ruleLoad == nil {
                    self.ruleLoad = Task { @MainActor [weak self] in
                        guard let compiled = try await WKContentRuleListStore.default().compileContentRuleList(
                            forIdentifier: "easl-note-mermaid-isolated-v1", encodedContentRuleList: Self.networkRules
                        ) else { throw URLError(.noPermissionsToReadFile) }
                        self?.rules = compiled
                    }
                }
                guard let ruleLoad = self.ruleLoad else { throw URLError(.noPermissionsToReadFile) }
                try await ruleLoad.value
                guard let rules = self.rules else { throw URLError(.noPermissionsToReadFile) }
                guard !Task.isCancelled, let current = self.jobs[id] else { return }
                if self.assets == nil {
                    guard let kitRoot = AppPaths.asset("kit") else { throw URLError(.fileDoesNotExist) }
                    self.assets = try Assets(kitRoot: kitRoot)
                }
                guard let assets = self.assets else { throw URLError(.fileDoesNotExist) }
                let page: Page
                if let reusable = self.idle.popLast() {
                    page = reusable
                } else {
                    guard self.jobs.values.compactMap(\.page).count + self.idle.count < 2 else {
                        self.finish(id, .fallback("Mermaid renderer is busy."))
                        return
                    }
                    page = Page(rules: rules, assets: assets)
                }
                current.page = page
                current.preparation = nil
                guard page.canTerminate else {
                    self.finish(id, .fallback("Mermaid rendering is unavailable on this WebKit version."))
                    return
                }
                page.web.appearance = NSAppearance(named: key.appearance == .dark ? .darkAqua : .aqua)
                WebStage.park(page.web, frame: NSRect(x: 0, y: 0, width: CGFloat(key.width), height: 1))
                page.failure = { [weak self] in self?.finish(id, .fallback("Mermaid renderer stopped.")) }
                if page.loaded {
                    self.draw(id)
                } else {
                    page.ready = { [weak self] in self?.draw(id) }
                    page.load()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.finish(id, .fallback("Mermaid renderer could not load its local resources."))
            }
        }
        return { [weak self] in self?.abort(id) }
    }

    private func abort(_ id: UUID) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.preparation?.cancel()
        job.page?.discard()
    }

    private func finish(_ id: UUID, _ outcome: NoteMermaid.Outcome, reusing page: Page? = nil) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.preparation?.cancel()
        if let page {
            page.ready = nil
            page.failure = nil
            page.web.removeFromSuperview()
            idle.append(page)
            scheduleIdleRelease()
        } else {
            job.page?.discard()
        }
        job.completion(outcome)
    }

    private func draw(_ id: UUID) {
        guard let job = jobs[id], let page = job.page else { return }
        page.ready = nil
        page.web.callAsyncJavaScript(Self.renderScript,
            arguments: ["source": job.key.source, "width": job.key.width, "dark": job.key.appearance == .dark],
            in: nil, in: .page
        ) { [weak self, weak page] result in
            MainActor.assumeIsolated {
                guard let self, let page, self.jobs[id]?.page === page else { return }
                guard case .success(let value) = result,
                      let dimensions = value as? [String: Double],
                      let width = dimensions["width"], let height = dimensions["height"],
                      width.isFinite, height.isFinite, width >= 1, height >= 1,
                      width <= 8192, height <= 8192, width * height <= 4_194_304 else {
                    self.finish(id, .fallback("Mermaid could not render this diagram."))
                    return
                }
                let size = NSSize(width: width, height: height)
                page.web.frame.size = size
                let snapshot = WKSnapshotConfiguration()
                snapshot.rect = NSRect(origin: .zero, size: size)
                let backingScale = max(1, page.web.window?.backingScaleFactor ?? 1)
                snapshot.snapshotWidth = NSNumber(value: width / Double(backingScale))
                page.web.takeSnapshot(with: snapshot) { [weak self, weak page] image, _ in
                    MainActor.assumeIsolated {
                        guard let self, let page, self.jobs[id]?.page === page else { return }
                        guard let pixels = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                              pixels.width <= 8192, pixels.height <= 8192,
                              pixels.width * pixels.height <= 4_194_304 else {
                            self.finish(id, .fallback("Mermaid snapshot failed."))
                            return
                        }
                        let raster = NSImage(cgImage: pixels, size: size)
                        page.web.callAsyncJavaScript("document.body.replaceChildren(); return true;", arguments: [:], in: nil, in: .page) { [weak self, weak page] reset in
                            MainActor.assumeIsolated {
                                guard let self, let page, self.jobs[id]?.page === page else { return }
                                guard case .success = reset else {
                                    self.finish(id, .fallback("Mermaid renderer could not reset."))
                                    return
                                }
                                self.finish(id, .image(raster), reusing: page)
                            }
                        }
                    }
                }
            }
        }
    }

    private func scheduleIdleRelease() {
        idleRelease?.invalidate()
        idleRelease = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for page in self.idle { page.discard() }
                self.idle.removeAll()
                self.idleRelease = nil
            }
        }
    }

    private static let networkRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^easl-note-mermaid://renderer/page$"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^easl-note-mermaid://renderer/mermaid\\.js$"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^easl-note-mermaid://renderer/kit\\.css$"},"action":{"type":"ignore-previous-rules"}}]"#

    private static let renderScript = #"""
    const host = document.createElement('div');
    host.id = 'diagram';
    host.style.width = width + 'px';
    document.body.replaceChildren(host);
    document.documentElement.style.colorScheme = dark ? 'dark' : 'light';
    const configuration = {
      startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default',
      fontFamily: getComputedStyle(document.documentElement).getPropertyValue('--canvas-font'),
      maxTextSize: 51200, maxEdges: 500, suppressErrorRendering: true,
      dompurifyConfig: { FORBID_TAGS: ['image', 'img', 'iframe', 'object', 'embed', 'script'] }
    };
    configuration.secure = [...new Set([...mermaid.mermaidAPI.getConfig().secure, 'dompurifyConfig', 'secure'])];
    mermaid.initialize(configuration);
    const result = await mermaid.render('noteDiagram', source);
    host.innerHTML = result.svg;
    for (const node of host.querySelectorAll('image,img,iframe,object,embed,script,video,audio,source,link,meta,base')) node.remove();
    for (const node of host.querySelectorAll('*')) {
      for (const attribute of [...node.attributes]) {
        const name = attribute.name.toLowerCase();
        const reference = name === 'href' || name === 'xlink:href';
        if (/^on/i.test(name) || /^(?:src|srcset|action|formaction)$/.test(name) ||
            (reference && (node.localName === 'a' || !attribute.value.startsWith('#')))) node.removeAttribute(attribute.name);
      }
    }
    const svg = host.querySelector('svg');
    if (!svg) throw new Error('No SVG');
    svg.style.maxWidth = '100%';
    const box = svg.getBoundingClientRect();
    if (![box.width, box.height].every(value => Number.isFinite(value) && value > 0)) throw new Error('Invalid dimensions');
    const scale = Math.min(1, width / box.width, 8192 / box.width, 8192 / box.height, Math.sqrt(4194304 / box.width / box.height));
    const outputWidth = Math.max(1, Math.floor(box.width * scale));
    const outputHeight = Math.max(1, Math.floor(box.height * scale));
    if (outputWidth * outputHeight > 4194304) throw new Error('Raster limit');
    svg.style.width = outputWidth + 'px';
    svg.style.height = outputHeight + 'px';
    svg.setAttribute('width', outputWidth);
    svg.setAttribute('height', outputHeight);
    host.style.width = outputWidth + 'px';
    host.style.height = outputHeight + 'px';
    return { width: outputWidth, height: outputHeight };
    """#

    @MainActor
    private final class Assets: NSObject, WKURLSchemeHandler {
        static let pageURL = URL(string: "easl-note-mermaid://renderer/page")!
        private let vendor: Data
        private let css: Data
        private static let document = Data("""
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src easl-note-mermaid://renderer/mermaid.js; style-src 'unsafe-inline' easl-note-mermaid://renderer/kit.css; img-src 'none'; font-src 'none'; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'">
        <link rel="stylesheet" href="easl-note-mermaid://renderer/kit.css">
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}body{font-family:var(--canvas-font)}svg{display:block}</style>
        </head><body><script src="easl-note-mermaid://renderer/mermaid.js"></script></body></html>
        """.utf8)

        init(kitRoot: URL) throws {
            vendor = try Data(contentsOf: kitRoot.appendingPathComponent("vendor/mermaid.min.js"), options: .alwaysMapped)
            css = try Data(contentsOf: kitRoot.appendingPathComponent("canvas-kit.css"), options: .alwaysMapped)
            super.init()
        }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url, task.request.httpMethod == "GET" else {
                task.didFailWithError(URLError(.noPermissionsToReadFile))
                return
            }
            let data: Data
            let type: String
            switch url.absoluteString {
            case Self.pageURL.absoluteString: data = Self.document; type = "text/html"
            case "easl-note-mermaid://renderer/mermaid.js": data = vendor; type = "text/javascript"
            case "easl-note-mermaid://renderer/kit.css": data = css; type = "text/css"
            default:
                task.didFailWithError(URLError(.noPermissionsToReadFile))
                return
            }
            task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    @MainActor
    private final class Page: NSObject, WKNavigationDelegate, WKUIDelegate {
        let web: WKWebView
        var loaded = false
        var ready: (@MainActor () -> Void)?
        var failure: (@MainActor () -> Void)?
        private static let termination = NSSelectorFromString("_killWebContentProcessAndResetState")
        var canTerminate: Bool { web.responds(to: Self.termination) }

        init(rules: WKContentRuleList, assets: Assets) {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.setURLSchemeHandler(assets, forURLScheme: "easl-note-mermaid")
            configuration.userContentController.add(rules)
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
            super.init()
            web.navigationDelegate = self
            web.uiDelegate = self
            WebStage.setOcclusionDetection(false, on: web)
        }

        func load() { web.load(URLRequest(url: Assets.pageURL)) }

        func discard() {
            ready = nil
            failure = nil
            web.navigationDelegate = nil
            web.uiDelegate = nil
            if canTerminate { _ = web.perform(Self.termination) }
            web.stopLoading()
            web.removeFromSuperview()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(!loaded && navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == Assets.pageURL ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            ready?()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure?() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure?() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loaded = false
            failure?()
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}
