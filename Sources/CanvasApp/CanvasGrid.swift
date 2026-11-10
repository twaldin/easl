import AppKit
import CanvasCore

/// The dot grid on screen: a fixed layer behind the scrolled document, filled by Core Animation
/// with one small pattern tile (`CanvasDocumentView.gridTile`) and repositioned on every pan and
/// pinch step. The document used to draw the grid itself; mid-pinch its bitmap was only scaled
/// (dots grew and shrank) and at the end it redrew with new spacing, so the dots popped. Here dots
/// stay 2 points on screen and the finer level fades in and out (RenderMath.gridLevel).
@MainActor
final class CanvasGrid: NSView {
    private let dots = CALayer()
    private var tile: CGImage?
    private var origin = CGPoint.zero
    private var scale: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dots.anchorPoint = .zero
        dots.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(dots)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }

    /// Appearance changes: the fill and dot colors are dynamic.
    override func updateLayer() {
        layer?.backgroundColor = TileChrome.color(.canvas).cgColor
        tile = nil
        apply()
    }

    /// `origin`: where document point (0, 0) is in this view; `scale`: screen points per unit.
    func update(origin: CGPoint, scale: CGFloat) {
        self.origin = origin
        self.scale = scale
        apply()
    }

    private func apply() {
        guard scale > 0, bounds.width > 0 else { return }
        let backing = window?.backingScaleFactor ?? 2
        let (spacing, fade) = RenderMath.gridLevel(scale: Double(scale))
        let period = CGFloat(spacing) * scale
        let pixels = CanvasDocumentView.gridPixels(period * backing)
        var color = CGColor(gray: 0.5, alpha: 0.35)
        effectiveAppearance.performAsCurrentDrawingAppearance { color = CanvasDocumentView.dotColor.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let next = CanvasDocumentView.gridTile(pixels: pixels, dot: 2 * backing, color: color, fade: CGFloat(fade)), next !== tile {
            tile = next
            dots.backgroundColor = NSColor(patternImage: NSImage(cgImage: next, size: NSSize(width: CGFloat(pixels) / backing, height: CGFloat(pixels) / backing))).cgColor
        }
        // The tile is a whole number of pixels; stretch it to the exact period so the dots stay on
        // the document's lattice across the whole window. The layer spans one extra period on each
        // side and shifts by the pan's remainder; a tile's center dot is document point (0, 0).
        let stretch = period / (CGFloat(pixels) / backing)
        func phase(_ value: CGFloat) -> CGFloat {
            let remainder = (value - period / 2).truncatingRemainder(dividingBy: period)
            return (remainder < 0 ? remainder + period : remainder) - period
        }
        dots.transform = CATransform3DMakeScale(stretch, stretch, 1)
        dots.position = CGPoint(x: phase(origin.x), y: phase(origin.y))
        dots.bounds = CGRect(x: 0, y: 0, width: (bounds.width + 2 * period) / stretch, height: (bounds.height + 2 * period) / stretch)
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        apply()
    }

    /// `cacheDisplay` (view.snapshot) draws views rather than compositing layers.
    override func draw(_ dirtyRect: NSRect) {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("draw.CanvasGrid", since: perfStart) }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        CanvasDocumentView.drawBackground(in: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y).applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)),
                                          pointsPerUnit: scale, pixelsPerPoint: window?.backingScaleFactor ?? 2)
        context.restoreGState()
    }
}
