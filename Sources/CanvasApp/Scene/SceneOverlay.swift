import AppKit

/// Transparent document-space chrome, drawn by views so `view.snapshot` captures it too.
final class SceneOverlay: NSView {
    private let foreground = SceneForeground(frame: .zero)
    private var ringViews: [SceneRing] = []

    var outline: NSRect? {
        get { foreground.outline }
        set { foreground.outline = newValue }
    }
    struct Ring: Equatable {
        var rect: NSRect
        var dashed: Bool
    }
    var rings: [Ring] = [] {
        didSet {
            guard rings != oldValue else { return }
            while ringViews.count > rings.count { ringViews.removeLast().remove() }
            for (index, ring) in rings.enumerated() {
                if index == ringViews.count {
                    ringViews.append(SceneRing(ring, in: self, below: foreground))
                } else {
                    ringViews[index].update(ring)
                }
            }
        }
    }
    var marquee: NSBezierPath? {
        get { foreground.marquee }
        set { foreground.marquee = newValue }
    }
    var flash: (rect: NSRect, strength: CGFloat)? {
        get { foreground.flash }
        set { foreground.flash = newValue }
    }
    var focusHoles: [NSRect]? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        foreground.frame = bounds
        foreground.autoresizingMask = [.width, .height]
        foreground.isHidden = true
        addSubview(foreground)
    }

    required init?(coder: NSCoder) { fatalError("unused") }
    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("draw.SceneOverlay", since: perfStart) }
        if let holes = focusHoles {
            let dim = NSBezierPath(rect: dirtyRect)
            for hole in holes { dim.append(NSBezierPath(roundedRect: hole.insetBy(dx: -12, dy: -12), xRadius: 10, yRadius: 10)) }
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill()
            dim.fill()
        }
    }
}

@MainActor
private final class SceneRing {
    private var ring: SceneOverlay.Ring
    private var path: NSBezierPath
    private let strips: [RingStrip]

    init(_ ring: SceneOverlay.Ring, in parent: NSView, below foreground: NSView) {
        self.ring = ring
        path = NSBezierPath(roundedRect: ring.rect.insetBy(dx: -3, dy: -3), xRadius: 9, yRadius: 9)
        strips = (0..<4).map { _ in RingStrip(frame: .zero) }
        for strip in strips { parent.addSubview(strip, positioned: .below, relativeTo: foreground) }
        place()
        display()
    }

    func remove() { strips.forEach { $0.removeFromSuperview() } }

    func update(_ ring: SceneOverlay.Ring) {
        guard ring != self.ring else { return }
        let moved = ring.rect != self.ring.rect
        self.ring = ring
        if moved {
            path = NSBezierPath(roundedRect: ring.rect.insetBy(dx: -3, dy: -3), xRadius: 9, yRadius: 9)
            place()
        }
        display()
    }

    private func place() {
        let outer = ring.rect.insetBy(dx: -6, dy: -6)
        let height = min(16, outer.height / 2), width = min(6, outer.width / 2)
        strips[0].place(NSRect(x: outer.minX, y: outer.minY, width: outer.width, height: height))
        strips[1].place(NSRect(x: outer.minX, y: outer.maxY - height, width: outer.width, height: height))
        strips[2].place(NSRect(x: outer.minX, y: outer.minY + height, width: width, height: outer.height - 2 * height))
        strips[3].place(NSRect(x: outer.maxX - width, y: outer.minY + height, width: width, height: outer.height - 2 * height))
    }

    private func display() {
        path.lineWidth = 2.5
        path.setLineDash(ring.dashed ? [6, 4] : [], count: ring.dashed ? 2 : 0, phase: 0)
        for strip in strips {
            strip.path = path
            strip.needsDisplay = true
        }
    }
}

private final class RingStrip: NSView {
    var path: NSBezierPath?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("unused") }
    nonisolated override var isFlipped: Bool { true }

    func place(_ rect: NSRect) {
        frame = rect
        bounds = rect
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        path?.stroke()
    }
}

private final class SceneForeground: NSView {
    var outline: NSRect? { didSet { invalidate(oldValue, outline) } }
    var marquee: NSBezierPath? {
        didSet { invalidate(oldValue.map { $0.bounds.insetBy(dx: -$0.lineWidth, dy: -$0.lineWidth) }, marquee.map { $0.bounds.insetBy(dx: -$0.lineWidth, dy: -$0.lineWidth) }) }
    }
    var flash: (rect: NSRect, strength: CGFloat)? {
        didSet { invalidate(oldValue?.rect, flash?.rect) }
    }

    nonisolated override var isFlipped: Bool { true }

    private func invalidate(_ old: NSRect?, _ new: NSRect?) {
        isHidden = outline == nil && marquee == nil && flash == nil
        for rect in [old, new].compactMap({ $0 }) where !rect.isNull {
            setNeedsDisplay(rect.insetBy(dx: -6, dy: -6))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let marquee {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            marquee.fill()
            marquee.setLineDash([4 * marquee.lineWidth, 3 * marquee.lineWidth], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            marquee.stroke()
        }
        if let flash {
            let path = NSBezierPath(roundedRect: flash.rect.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4)
            path.lineWidth = 3
            NSColor.systemPurple.withAlphaComponent(flash.strength).setStroke()
            NSColor.systemPurple.withAlphaComponent(0.3 * flash.strength).setFill()
            path.fill()
            path.stroke()
        }
        if let outline {
            let path = NSBezierPath(roundedRect: outline.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4)
            path.lineWidth = 2
            NSColor.systemPurple.setStroke()
            NSColor.systemPurple.withAlphaComponent(0.08).setFill()
            path.fill()
            path.stroke()
        }
    }
}
