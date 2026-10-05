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

    func release() {
        web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.removeFromSuperview()
    }
}

/// Web views kept between measures. An agent measures page after page (`object.measure`, `size:
/// "fit"`, `layout.check`), and a new web view per page costs a WebContent process launch and its
/// setup each time; a measure borrows a waiting one instead, at most `HtmlTile.maxMeasuring` of
/// them. Between measures a page is emptied (about:blank, its website data removed, so one
/// measured page never sees another's storage) and serves no tile; after `idleRelease` without a
/// measure they are all released.
@MainActor
enum HtmlMeasurePool {
    static let idleRelease: TimeInterval = 30
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

    /// `page`'s measure ended: empty it, then keep it for the next.
    static func give(_ page: HtmlMeasurePage) {
        page.scheme.tile = nil
        page.channel.tile = nil
        page.web.navigationDelegate = nil
        page.web.uiDelegate = nil
        page.web.stopLoading()
        page.web.load(URLRequest(url: URL(string: "about:blank")!))
        Task { @MainActor in
            await page.web.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            guard idle.count < HtmlTile.maxMeasuring else { return page.release() }
            idle.append(page)
            scheduleRelease()
        }
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
