import AppKit
import WebKit

/// Where web views wait while nobody sees them but WebKit must still treat them as visible
/// (a detached or hidden-ancestor view, or one in a window that isn't on screen — minimized,
/// in a background tab, the app hidden — is a hidden page: no layout, no requestAnimationFrame):
/// a transparent, click-through panel that joins every Space without activating easl.
/// Window occlusion detection is off. The panel is ordered in only while it holds a web view,
/// so it never keeps the app alive after the last board window closes.
@MainActor
enum WebStage {
    private static var window: NSWindow?

    /// Parks `view` in the stage at `frame` (its size is what the page lays out at).
    static func park(_ view: NSView, frame: NSRect) {
        let stage = window ?? makeWindow()
        view.frame = frame
        if view.superview !== stage.contentView { stage.contentView?.addSubview(view) }
        if !stage.isVisible { stage.orderBack(nil) }
    }

    static func isParked(_ view: NSView) -> Bool {
        window.map { view.window === $0 } ?? false
    }

    private static func makeWindow() -> NSWindow {
        let screen = NSScreen.screens.first?.frame ?? .zero
        let frame = NSRect(x: screen.minX, y: screen.minY, width: 1, height: 1)
        let stage = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        stage.hidesOnDeactivate = false
        stage.isReleasedWhenClosed = false
        stage.alphaValue = 0
        stage.ignoresMouseEvents = true
        stage.hasShadow = false
        stage.isExcludedFromWindowsMenu = true
        stage.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        stage.contentView = StageView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        window = stage
        return stage
    }

    /// Orders the stage out once its last web view leaves (moved to a tile, released).
    private final class StageView: NSView {
        override func willRemoveSubview(_ subview: NSView) {
            super.willRemoveSubview(subview)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.subviews.isEmpty else { return }
                    self.window?.orderOut(nil)
                }
            }
        }
    }

    /// WebKit SPI `-[WKWebView _setWindowOcclusionDetectionEnabled:]` (macOS 10.13+); skipped if absent.
    static func setOcclusionDetection(_ enabled: Bool, on webView: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, enabled)
    }

    /// Runs `body` once the UI process has shown the page's next committed frame (WebKit SPI
    /// `-[WKWebView _doAfterNextPresentationUpdate:]`), so what the page drew is on screen;
    /// after a short delay when the SPI is absent.
    static func afterNextPresentationUpdate(_ webView: WKWebView, _ body: @escaping @MainActor () -> Void) {
        let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard webView.responds(to: selector) else {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { body() } }
        }
        typealias Method = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        unsafeBitCast(webView.method(for: selector), to: Method.self)(webView, selector) {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }
}
