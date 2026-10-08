import Foundation

/// When nobody has touched the Mac for a while, terminals redraw slowly. A working agent's
/// spinner retitles and reprints every 80 ms, and each frame a visible board updates costs a
/// Core Animation commit of its whole layer tree and a WindowServer composite: fifteen such
/// terminals kept a board at ~120 updates a second all night for an empty chair (easl 15–19 %
/// GPU, WindowServer ~50 % CPU; 2026-10-07). Only drawing slows: PTY reading, output, titles,
/// agent reports and `agent.read` run at full speed, and the first input brings full rate back.
///
/// How a terminal slows: Ghostty presents from a display link of its own on every change, which
/// no frame rate of ours bounds, but it draws nothing while its surface is occluded (the path a
/// covered window already uses). So an idle terminal is kept occluded and shown for one redraw
/// `idleHertz` times a second, for `pulse` seconds each: long enough for Ghostty to draw the
/// current screen once it is told it is visible, short enough that a spinner's next change
/// rarely lands inside it.
///
/// Pure policy. `UserIdleWatch` (CanvasApp) feeds it the Mac's time since the last input event
/// and the app's own input events; `TerminalTile` pulses its surface while `isIdle`.
public struct IdleRedraw: Equatable, Sendable {
    /// Seconds without input before terminals slow down.
    public static let threshold: TimeInterval = 60
    /// Redraws per second for an idle terminal: a spinner still reads as moving at 2, and each
    /// redraw after an occlusion is a full one for Ghostty (measured 2026-10-08: at 5 a second,
    /// 15 terminals cost the app +22 % CPU for GPU −64 % and WindowServer −4 points; 2 halves
    /// that cost).
    public static let idleHertz = 2.0
    /// How long each redraw's visibility lasts.
    public static let pulse: TimeInterval = 0.05

    public private(set) var isIdle = false

    public init() {}

    /// The Mac's time since its last input event, sampled; true when the state changed.
    @discardableResult
    public mutating func sampled(idleSeconds: TimeInterval) -> Bool {
        let idle = idleSeconds >= Self.threshold
        defer { isIdle = idle }
        return idle != isIdle
    }

    /// An input event reached the app; true when the state changed.
    @discardableResult
    public mutating func input() -> Bool { sampled(idleSeconds: 0) }

    /// How long until the next sample is worth taking: while active, until the threshold could
    /// first be crossed (a sample a minute at most); while idle, every second, so input anywhere
    /// on the Mac, not only in easl, restores full rate within a second.
    public func nextSample(idleSeconds: TimeInterval) -> TimeInterval {
        isIdle ? 1 : max(1, Self.threshold - idleSeconds)
    }
}
