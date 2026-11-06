import AppKit
import WebKit

/// WebKit copies wheel events before reporting them as unhandled.
struct PageWheelID: Equatable {
    private let timestamp: TimeInterval
    private let phase: NSEvent.Phase
    private let momentumPhase: NSEvent.Phase

    init(_ event: NSEvent) {
        timestamp = event.timestamp
        phase = event.phase
        momentumPhase = event.momentumPhase
    }
}

@MainActor
enum PageWheelHandoff {
    static func configure(_ webView: WKWebView) -> Bool {
        let getter = NSSelectorFromString("_rubberBandingEnabled")
        let setter = NSSelectorFromString("_setRubberBandingEnabled:")
        let callback = NSSelectorFromString("_webView:didNotHandleWheelEvent:")
        guard webView.responds(to: getter), webView.responds(to: setter),
              webView.uiDelegate?.responds(to: callback) == true else { return false }
        typealias SetEdges = @convention(c) (AnyObject, Selector, UInt) -> Void
        let setEdges = unsafeBitCast(webView.method(for: setter), to: SetEdges.self)
        setEdges(webView, setter, UInt(0))
        typealias GetEdges = @convention(c) (AnyObject, Selector) -> UInt
        let getEdges = unsafeBitCast(webView.method(for: getter), to: GetEdges.self)
        return getEdges(webView, getter) == 0
    }
}
