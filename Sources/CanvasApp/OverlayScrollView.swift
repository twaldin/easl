import AppKit

/// AppKit resets scroller styles to the system preference. Keep text at its measured width
/// even when that preference requests legacy scrollers, which reserve a gutter.
final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}
