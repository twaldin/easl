import AppKit
import CanvasCore

/// Window-space attention uses the shared needs-you role and preserves the classifier's reason.
@MainActor
enum AttentionStyle {
    case marker, blocked, needsYou

    var color: NSColor { TileChrome.color(.needsYou) }
    /// Existing high-contrast ink on the semantic attention background.
    static let ink = NSColor.black
    /// The raised hand leading a blocked bubble's or edge pill's text.
    var glyph: NSImage? { self == .blocked ? Self.hand : nil }
    private static let hand = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Needs you")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .bold).applying(NSImage.SymbolConfiguration(paletteColors: [ink])))
    static let glyphWidth: CGFloat = 18
    /// What the pill draws: one line of the message (`Attention.pillLine`), else the default.
    func text(_ message: String?) -> NSString {
        (Attention.pillLine(message) ?? (self == .marker ? "Look here" : "Needs you")) as NSString
    }
    /// The whole message, for tooltips; the pill's own text without one.
    func whole(_ message: String?) -> String {
        message.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? text(message) as String
    }
    /// A bubble's tooltip: its whole message when the pill cuts it (too wide, or more than one
    /// line), then what the bubble is.
    func toolTip(_ message: String?, truncated: Bool) -> String {
        let about: String = switch self {
        case .blocked: CanvasBasics.blockedBubble
        case .marker: CanvasBasics.marker
        case .needsYou: "Needs your attention. Click to go to the object."
        }
        return truncated || whole(message) != text(message) as String ? "\(whole(message))\n\n\(about)" : about
    }
}

/// Something on screen that needs the user: a static ring and a reason pill beside the object.
/// Lives in window space
/// above the canvas (`AttentionLayer`) and is re-placed on every pan and pinch step, so it keeps
/// its on-screen size at any zoom and follows the zoom smoothly while everything on the canvas
/// scales. Only the bubble takes clicks. The view spans its layer and draws nothing itself: the
/// ring and the bubble are views of their own, each sized to what it draws (the ring clipped to
/// the window), so moving one never leaves a stale copy of the other behind (a bubble clamped
/// at the window's edge while its object's ring reached past it once showed twice).
@MainActor
final class AttentionMarker: NSView {
    static let inset: CGFloat = 10
    static let bubbleHeight: CGFloat = 28
    static let gap: CGFloat = 6
    static let stroke: CGFloat = 1

    let objectID: ObjectID
    let style: AttentionStyle
    var message: String? {
        didSet {
            guard message != oldValue else { return }
            naturalWidth = Self.naturalWidth(message, style: style)
            bubble.text = style.text(message)
        }
    }
    var onClick: (() -> Void)?
    /// The bubble's width with its whole message; `PillLayout.bubbleWidth` caps it.
    private(set) var naturalWidth: CGFloat
    /// The ring and bubble have separate bounds so movement does not leave stale pixels.
    private let ring: MarkerRing
    private let bubble: MarkerBubble

    init(objectID: ObjectID, message: String?, style: AttentionStyle = .marker) {
        self.objectID = objectID
        self.message = message
        self.style = style
        naturalWidth = Self.naturalWidth(message, style: style)
        ring = MarkerRing(color: style.color)
        bubble = MarkerBubble(style: style, text: style.text(message))
        super.init(frame: .zero)
        addSubview(ring)
        addSubview(bubble)
        bubble.onClick = { [weak self] in self?.onClick?() }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    fileprivate static let bubbleAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [.font: TileChrome.font(.needsYou, scale: 1), .foregroundColor: AttentionStyle.ink, .paragraphStyle: paragraph]
    }()
    private static func naturalWidth(_ message: String?, style: AttentionStyle) -> CGFloat {
        (style.text(message).size(withAttributes: bubbleAttributes).width + 24 + (style.glyph == nil ? 0 : AttentionStyle.glyphWidth)).rounded(.up)
    }

    /// Places the marker: the ring hugs `target` (the object's rect in the superview's
    /// coordinates) at a fixed on-screen inset, and the bubble goes where `PillLayout` put it
    /// (`bubble`, same coordinates). The view spans its superview, so both are placed in its
    /// coordinates; the ring's view covers only the part of the ring near the window.
    func place(around target: NSRect, bubble rect: NSRect) {
        guard let superview else { return }
        if frame != superview.bounds { frame = superview.bounds }
        let ringRect = target.insetBy(dx: -Self.inset, dy: -Self.inset)
        let pad = Self.stroke
        let shown = ringRect.insetBy(dx: -pad, dy: -pad).intersection(bounds.insetBy(dx: -pad, dy: -pad))
        let ringFrame = shown.isNull ? .zero : shown.integral
        if ring.frame != ringFrame { ring.frame = ringFrame }
        ring.rect = ringRect.offsetBy(dx: -ringFrame.minX, dy: -ringFrame.minY)
        if bubble.frame != rect { bubble.frame = rect }
        // A cut message reads whole in the bubble's tooltip, with what the bubble is; set on
        // every placement, so a new message with the same bubble rect gets its own.
        let tip = style.toolTip(message, truncated: rect.width < naturalWidth)
        if bubble.toolTip != tip { bubble.toolTip = tip }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return bubble.frame.contains(convert(point, from: superview)) ? bubble : nil
    }
}

/// A marker's bubble: the message on a pill of the marker's color. It redraws only when its
/// text or size changes; moving it moves its layer.
@MainActor
private final class MarkerBubble: NSView {
    let style: AttentionStyle
    var text: NSString {
        didSet { if text != oldValue { needsDisplay = true } }
    }
    var onClick: (() -> Void)?

    init(style: AttentionStyle, text: NSString) {
        self.style = style
        self.text = text
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("draw.AttentionMarker", since: perfStart) }
        let pill = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        style.color.setFill()
        pill.fill()
        var textX = bounds.minX + 12
        if let glyph = style.glyph {
            glyph.draw(in: NSRect(x: textX, y: bounds.midY - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            textX += AttentionStyle.glyphWidth
        }
        let size = text.size(withAttributes: AttentionMarker.bubbleAttributes)
        text.draw(in: NSRect(x: textX, y: bounds.midY - size.height / 2, width: bounds.maxX - 12 - textX, height: size.height), withAttributes: AttentionMarker.bubbleAttributes)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// A static attention outline in window space.
@MainActor
private final class MarkerRing: NSView {
    private let color: NSColor
    var rect = NSRect.zero {
        didSet { if rect != oldValue { needsDisplay = true } }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        // Unclipping at the window's edge resizes the view with the ring where it was: redraw,
        // never stretch the old image.
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }


    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        path.lineWidth = AttentionMarker.stroke
        color.setStroke()
        path.stroke()
    }
}

/// Window-space layer over the canvas holding the attention markers; only their bubbles take
/// clicks, everything else passes through to the canvas.
@MainActor
final class AttentionLayer: NSView {
    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for marker in subviews.reversed() where !marker.isHidden {
            if let hit = marker.hitTest(local) { return hit }
        }
        return nil
    }
}

/// Window-space pills at the rim of the clear area for offscreen objects that need the user
/// (attention markers, blocked agents), each pointing at its object. Clicking one scrolls to its
/// object; nothing else here takes clicks.
@MainActor
final class AttentionEdgeView: NSView {
    struct Pointer {
        var id: ObjectID
        var message: String?
        var style: AttentionStyle
        /// Target center in this view's coordinates (outside the bounds).
        var target: NSPoint
        /// Where `PillLayout` put the pill, same coordinates.
        var frame: NSRect = .zero
    }

    var onReveal: ((ObjectID) -> Void)?
    private var chevrons: [EdgeChevron] = []

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return chevrons.first { $0.frame.contains(local) }
    }

    /// A pill's size for a message.
    static func size(for message: String?, style: AttentionStyle) -> NSSize { EdgeChevron.size(for: message, style: style) }

    func show(_ pointers: [Pointer]) {
        while chevrons.count > pointers.count { chevrons.removeLast().removeFromSuperview() }
        while chevrons.count < pointers.count {
            let chevron = EdgeChevron()
            addSubview(chevron)
            chevrons.append(chevron)
        }
        for (chevron, pointer) in zip(chevrons, pointers) {
            chevron.objectID = pointer.id
            chevron.message = pointer.message
            chevron.style = pointer.style
            // The pill shows the start of its message: the whole of it, and where the pill leads.
            let tip = "\(pointer.style.whole(pointer.message))\n\nThis object is off screen that way. Click to go there."
            if chevron.toolTip != tip { chevron.toolTip = tip }
            chevron.onClick = { [weak self] in self?.onReveal?(pointer.id) }
            chevron.angle = atan2(pointer.target.y - pointer.frame.midY, pointer.target.x - pointer.frame.midX)
            chevron.frame = pointer.frame
            chevron.needsDisplay = true
        }
    }
}

/// An edge pill: compact (an arrow toward its object and the start of its message, the whole
/// message in its tooltip), so it hides little of the tiles along the view's edge.
@MainActor
private final class EdgeChevron: NSView {
    var objectID: ObjectID = ""
    var message: String?
    var style = AttentionStyle.marker
    /// Direction to the target in flipped view space (radians, 0 = right, +π/2 = down).
    var angle: CGFloat = 0
    var onClick: (() -> Void)?

    private static let attributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: AttentionStyle.ink, .paragraphStyle: paragraph]
    }()
    /// The most of its message a pill shows.
    private static let maxTextWidth: CGFloat = 120
    private var text: NSString { style.text(message) }

    nonisolated override var isFlipped: Bool { true }

    static func size(for message: String?, style: AttentionStyle) -> NSSize {
        let width = min(style.text(message).size(withAttributes: attributes).width, maxTextWidth)
        return NSSize(width: (28 + (style.glyph == nil ? 0 : AttentionStyle.glyphWidth) + width + 10).rounded(.up), height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("draw.EdgeChevron", since: perfStart) }
        let pill = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        style.color.setFill()
        pill.fill()
        // Chevron glyph rotated toward the target.
        let center = NSPoint(x: 14, y: bounds.midY)
        var transform = AffineTransform(translationByX: center.x, byY: center.y)
        transform.rotate(byRadians: angle)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: -3, y: -5))
        arrow.line(to: NSPoint(x: 4, y: 0))
        arrow.line(to: NSPoint(x: -3, y: 5))
        arrow.transform(using: transform)
        arrow.lineWidth = 2.5
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        AttentionStyle.ink.setStroke()
        arrow.stroke()
        var textX: CGFloat = 28
        if let glyph = style.glyph {
            glyph.draw(in: NSRect(x: textX, y: bounds.midY - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            textX += AttentionStyle.glyphWidth
        }
        let size = text.size(withAttributes: Self.attributes)
        text.draw(in: NSRect(x: textX, y: bounds.midY - size.height / 2, width: bounds.width - 10 - textX, height: size.height), withAttributes: Self.attributes)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
