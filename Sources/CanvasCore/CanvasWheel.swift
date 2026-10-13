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
}

/// Who a trackpad gesture over a tile that scrolls goes to: the tile or the canvas behind it.
/// Its first movement decides, and the gesture keeps that owner to its end, momentum included,
/// so neither hands a gesture to the other halfway. A gesture whose start the tile didn't see
/// (a pan or its momentum slid the tile under the pointer) stays the canvas's.
public struct ScrollGesture: Sendable {
    public enum Owner: Equatable, Sendable { case tile, canvas }

    /// Where an event sits in its gesture (NSEvent's `phase`, then its `momentumPhase`).
    public enum Step: Equatable, Sendable {
        case began, changed, ended, momentumBegan, momentumChanged, momentumEnded
    }

    public private(set) var owner: Owner?
    /// The last step seen: what the next event must be to continue the same gesture.
    private var last: Step?

    public init() {}

    /// The owner of a gesture event at `step` that moved by (`dx`, `dy`); `tileTakes`: the tile
    /// scrolls a first movement like this one. Nil while the gesture hasn't moved yet.
    public mutating func owner(of step: Step, dx: CGFloat, dy: CGFloat, tileTakes: Bool) -> Owner? {
        if step == .began {
            owner = nil
        } else if !continues(step) {
            owner = .canvas
        }
        last = step
        if owner == nil, dx != 0 || dy != 0 { owner = tileTakes ? .tile : .canvas }
        return owner
    }

    private func continues(_ step: Step) -> Bool {
        switch step {
        case .began: false
        case .changed, .ended: last == .began || last == .changed
        case .momentumBegan: last == .ended
        case .momentumChanged, .momentumEnded: last == .momentumBegan || last == .momentumChanged
        }
    }
}
