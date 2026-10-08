import AppKit
import CanvasCore

/// Tells terminals when the user is away (`IdleRedraw`). The Mac's time since its last input
/// event (`CGEventSource.secondsSinceLastEventType`, any event, the session's combined state) is
/// sampled on a timer the policy paces; the app's own input events arrive through a local monitor
/// and restore full rate at once. A change posts `changed`; `TerminalTile` reads `isIdle` and
/// pulses its surface.
///
/// Sampling runs only while a terminal is shown and could draw (`terminalDrawable`): with every
/// board hidden or minimized there is nothing to slow down, and a fresh sample starts it again.
///
/// Development (`dev-input <pid> idle on|off|auto`): `on` feeds the policy an idle time past the
/// threshold and stops sampling the Mac (its idle time is the user's, not the check's), so a check
/// can watch terminals slow down and then, on a replayed key or click, speed up through the same
/// input path; `off` feeds zero; `auto` samples the Mac again.
@MainActor
final class UserIdleWatch {
    static let shared = UserIdleWatch()
    static let changed = Notification.Name("easl.userIdle.changed")

    private(set) var policy = IdleRedraw()
    private var pinned = false
    private var timer: DispatchSourceTimer?
    private var monitor: Any?

    var isIdle: Bool { policy.isIdle }
    /// Terminals shown and able to draw (`TerminalTile.updateSurfaceVisibility`).
    private(set) var drawable = 0

    /// A terminal became able to draw, or stopped: sampling runs only while any can.
    func terminalDrawable(_ on: Bool) {
        let was = drawable
        drawable = max(0, drawable + (on ? 1 : -1))
        if was == 0, drawable > 0 { sample() } else if drawable == 0 { timer?.cancel(); timer = nil }
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                              .leftMouseDragged, .scrollWheel, .magnify, .mouseMoved]) { [weak self] event in
            self?.input()
            return event
        }
        sample()
    }

    func pin(_ state: String) {
        switch state {
        case "on": pinned = true; apply(idleSeconds: IdleRedraw.threshold)
        case "off": pinned = true; apply(idleSeconds: 0)
        default: pinned = false; sample()
        }
    }

    private func sample() {
        timer?.cancel()
        timer = nil
        guard !pinned, drawable > 0 else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        apply(idleSeconds: idle)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + policy.nextSample(idleSeconds: idle), leeway: .milliseconds(200))
        timer.setEventHandler { MainActor.assumeIsolated { self.sample() } }
        timer.resume()
        self.timer = timer
    }

    private func input() {
        guard policy.isIdle else { return }
        apply(idleSeconds: 0)
        sample()  // the pace is the active one again
    }

    private func apply(idleSeconds: TimeInterval) {
        guard policy.sampled(idleSeconds: idleSeconds) else { return }
        NSLog("UserIdleWatch: terminals %@", policy.isIdle ? "redraw twice a second (idle)" : "redraw at full rate (active)")
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}
