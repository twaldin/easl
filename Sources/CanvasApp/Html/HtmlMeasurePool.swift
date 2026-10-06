import AppKit
import CanvasCore
import WebKit

/// A web view `HtmlTile.measure` borrows (`HtmlMeasurePool`), with handlers that serve whichever
/// scratch tile is being measured.
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

/// Web views kept between measures. An agent measures page after page (`object.measure`, `size:
/// "fit"`, `layout.check`), and a new web view per page costs a WebContent process launch and its
/// setup each time; a measure borrows a waiting one instead, at most `HtmlTile.maxMeasuring` of
/// them. Between measures a page is emptied (about:blank, its website data removed, so one
/// measured page never sees another's storage) and serves no tile; after `idleRelease` without a
/// measure they are all released. A page whose measure failed or was cancelled (a script that
/// never yields, a timeout) is discarded at once, and one whose emptying doesn't finish within
/// `cleanupLimit` too: what the page's process doesn't answer never holds a page.
@MainActor
enum HtmlMeasurePool {
    static let idleRelease: TimeInterval = 30
    static let cleanupLimit: TimeInterval = 2
    private static var idle: [HtmlMeasurePage] = []
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

    /// `page`'s measure succeeded: empty it, then keep it for the next, unless emptying takes
    /// longer than `cleanupLimit`.
    static func give(_ page: HtmlMeasurePage) {
        page.detach()
        page.web.load(URLRequest(url: URL(string: "about:blank")!))
        @MainActor final class Cleanup { var done = false }
        let cleanup = Cleanup()
        page.web.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            MainActor.assumeIsolated {
                guard !cleanup.done else { return }
                cleanup.done = true
                guard idle.count < HtmlTile.maxMeasuring else { return page.release() }
                idle.append(page)
                scheduleRelease()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + cleanupLimit) {
            MainActor.assumeIsolated {
                guard !cleanup.done else { return }
                cleanup.done = true
                Metrics.shared.record("html.measure.discard")
                page.discard()
            }
        }
    }

    /// `page`'s measure failed or was cancelled: it is never reused.
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
