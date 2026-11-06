import CoreGraphics

/// What a scroll event does on the canvas itself (empty canvas, or a tile that passes the scroll
/// on). A trackpad's precise scroll is AppKit's own pan (its momentum and rubber band); a mouse
/// wheel's line-based notch pans `lineHeight` screen points per line, as code and changes tiles
/// scroll a row per line, instead of NSScrollView's few points; with ⇧ a vertical wheel pans
/// sideways. ⌘-scroll zooms around the pointer, from a wheel or a trackpad (the Figma and Miro
/// convention; pinch still zooms). Linux study F4: a notch panned 1 pt and nothing zoomed.
public enum CanvasWheel {
    /// Screen points one wheel line pans.
    public static let lineHeight: CGFloat = 48
    /// Screen points of ⌘-scroll that double (or halve) the zoom: about 3 notches.
    public static let pointsPerDoubling: CGFloat = 144

    public enum Action: Equatable, Sendable {
        /// Leave it to the scroll view (a trackpad's precise pan).
        case system
        /// Pan the view by this much in screen points, as the content moves (positive y: down).
        case pan(dx: CGFloat, dy: CGFloat)
        /// Multiply the zoom by this, around the pointer.
        case zoom(CGFloat)
    }

    /// The action for a scroll of (`dx`, `dy`) (NSEvent's `scrollingDelta`), `precise` when it is
    /// in points (a trackpad or Magic Mouse) rather than lines, `command` and `shift` held.
    public static func action(dx: CGFloat, dy: CGFloat, precise: Bool, command: Bool, shift: Bool) -> Action {
        let scale = precise ? 1 : lineHeight
        // Scrolling up (content moving down) zooms in; a mostly sideways ⌘-scroll pans.
        if command, abs(dy) >= abs(dx), dy != 0 {
            return .zoom(pow(2, dy * scale / pointsPerDoubling))
        }
        guard !precise else { return .system }
        // AppKit turns a ⇧-wheel into a sideways scroll on most mice; one that still arrives
        // vertical goes sideways here.
        if shift, dx == 0 { return .pan(dx: dy * scale, dy: 0) }
        return .pan(dx: dx * scale, dy: dy * scale)
    }

    /// Whether a scroll of (`dx`, `dy`) goes sideways: a horizontal-dominant step, or a ⇧-wheel
    /// that AppKit left vertical (`action` pans it sideways).
    public static func sideways(dx: CGFloat, dy: CGFloat, precise: Bool, shift: Bool) -> Bool {
        abs(dx) > abs(dy) || (!precise && shift && dx == 0 && dy != 0)
    }

    public static func direction(dx: CGFloat, dy: CGFloat, precise: Bool, shift: Bool) -> CGVector {
        if sideways(dx: dx, dy: dy, precise: precise, shift: shift) {
            return CGVector(dx: dx == 0 ? dy : dx, dy: 0)
        }
        return CGVector(dx: 0, dy: dy)
    }

    public static func canScroll(offset: CGFloat, maximum: CGFloat, delta: CGFloat) -> Bool {
        maximum > 0.5 && (delta > 0 ? offset > 0.5 : delta < 0 && offset < maximum - 0.5)
    }
}

/// Gesture boundaries shared by the window's retained wheel destination.
public struct ScrollGesture: Sendable {
    public enum Step: Equatable, Sendable {
        case mayBegin, began, changed, ended, cancelled, momentumBegan, momentumChanged, momentumEnded
    }

    private var last: Step?
    private var lastTimestamp: Double?
    public init() {}

    public mutating func starts(step: Step?, timestamp: Double) -> Bool {
        defer {
            last = step
            lastTimestamp = timestamp
        }
        guard let step else {
            return last != nil || (lastTimestamp.map { timestamp - $0 >= 0.250 || timestamp < $0 } ?? true)
        }
        switch step {
        case .mayBegin:
            return last != .mayBegin
        case .began:
            return last != .mayBegin
        case .changed, .ended, .cancelled:
            return last != .mayBegin && last != .began && last != .changed
        case .momentumBegan, .momentumChanged, .momentumEnded:
            switch last {
            case .began?, .changed?, .ended?, .momentumBegan?, .momentumChanged?: return false
            default: return true
            }
        }
    }
}
