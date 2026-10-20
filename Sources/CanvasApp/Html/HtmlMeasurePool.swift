import AppKit
import CanvasCore
import WebKit

@MainActor
final class HtmlMeasurePage {
    let web: HtmlWebView
    let scheme: HtmlSchemeHandler
    let channel: HtmlChannelHandler
    private let count = GaugeHold("html.measure.pages")

    init(rules: WKContentRuleList) {
        scheme = HtmlSchemeHandler(tile: nil)
        channel = HtmlChannelHandler(tile: nil)
        web = HtmlWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: HtmlTile.configuration(rules: rules, scheme: scheme, channel: channel))
        WebStage.setOcclusionDetection(false, on: web)
    }

    /// Serves no tile and tells no delegate anything.
    func detach() {
        scheme.tile = nil
        channel.tile = nil
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.stopLoading()
    }

    func release() {
        detach()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.removeFromSuperview()
    }

    /// Releases the page and ends its WebContent process, which may be stuck in a script that
    /// never yields (WebKit SPI `-[WKWebView _killWebContentProcess]`; skipped if absent): it
    /// answers nothing, so nothing may wait on it.
    func discard() {
        let kill = NSSelectorFromString("_killWebContentProcess")
        if web.responds(to: kill) { _ = web.perform(kill) }
        release()
    }
}

@MainActor
enum HtmlMeasurePool {
    static let idleRelease: TimeInterval = 30
    static let cleanupLimit: TimeInterval = 2
    private static var idle: [HtmlMeasurePage] = []
    private(set) static var cleaning = 0
    private static var releaseTimer: Timer?

    /// A page serving `tile`, with `rules` as its only network rules.
    static func take(for tile: HtmlTile, rules: WKContentRuleList) -> HtmlMeasurePage {
        let page: HtmlMeasurePage
        if let waiting = idle.popLast() {
            page = waiting
            let content = page.web.configuration.userContentController
            content.removeAllContentRuleLists()
            content.add(rules)
            Metrics.shared.record("html.measure.reuse")
        } else {
            page = HtmlMeasurePage(rules: rules)
        }
        page.scheme.tile = tile
        page.channel.tile = tile
        return page
    }

    static func clearForReuse(_ page: HtmlMeasurePage) {
        cleaning += 1
        page.detach()
        page.web.load(URLRequest(url: URL(string: "about:blank")!))
        @MainActor final class Cleanup { var done = false }
        let cleanup = Cleanup()
        page.web.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            MainActor.assumeIsolated {
                guard !cleanup.done else { return }
                cleanup.done = true
                cleaning -= 1
                guard idle.count < HtmlTile.offscreenPageLimit else { return page.release() }
                idle.append(page)
                scheduleRelease()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + cleanupLimit) {
            MainActor.assumeIsolated {
                guard !cleanup.done else { return }
                cleanup.done = true
                cleaning -= 1
                Metrics.shared.record("html.measure.discard")
                page.discard()
            }
        }
    }

    static func discard(_ page: HtmlMeasurePage) {
        Metrics.shared.record("html.measure.discard")
        page.discard()
    }

    private static func scheduleRelease() {
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: idleRelease, repeats: false) { _ in
            MainActor.assumeIsolated {
                for page in idle { page.release() }
                idle = []
            }
        }
    }
}
