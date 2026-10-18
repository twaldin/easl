import AppKit
import CanvasCore

/// Tells terminals when the user is away (`IdleRedraw`). The Mac's time since its last input
/// event (`CGEventSource.secondsSinceLastEventType`, any event, the session's combined state) is
/// sampled on a timer the policy paces; the app's own input events arrive through a local monitor
/// and restore full rate at once. A change posts `changed`; `TerminalTile` reads `isIdle` and
/// pulses its surface.
@MainActor
final class UserIdleWatch {
    static let shared = UserIdleWatch()
    static let changed = Notification.Name("easl.userIdle.changed")
    static let sampled = Notification.Name("easl.userIdle.sampled")

    private(set) var policy = IdleRedraw()
    private var pinned = false
    private var timer: DispatchSourceTimer?
    private var monitor: Any?

    var isIdle: Bool { policy.isIdle }
    private(set) var idleSeconds: TimeInterval = 0

    /// A fresh whole-session sample, including input outside easl since the last timer tick.
    func currentIdleSeconds() -> TimeInterval {
        pinned ? idleSeconds : CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
    /// Terminals shown and able to draw (`TerminalTile.updateSurfaceVisibility`).
    private(set) var drawable = 0

    func terminalDrawable(_ on: Bool) {
        let was = drawable
        drawable = max(0, drawable + (on ? 1 : -1))
        if was == 0, drawable > 0 { sample() }
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
        case "on": pinned = true; timer?.cancel(); timer = nil; apply(idleSeconds: AppUpdate.automaticIdleThreshold)
        case "off": pinned = true; timer?.cancel(); timer = nil; apply(idleSeconds: 0)
        default: pinned = false; sample()
        }
    }

    private func sample() {
        timer?.cancel()
        timer = nil
        guard !pinned else { return }
        let idle = currentIdleSeconds()
        apply(idleSeconds: idle)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + policy.nextSample(idleSeconds: idle), leeway: .milliseconds(200))
        timer.setEventHandler { MainActor.assumeIsolated { self.sample() } }
        timer.resume()
        self.timer = timer
    }

    private func input() {
        guard idleSeconds > 0 || policy.isIdle else { return }
        apply(idleSeconds: 0)
        sample()  // the pace is the active one again
    }

    private func apply(idleSeconds: TimeInterval) {
        self.idleSeconds = idleSeconds
        NotificationCenter.default.post(name: Self.sampled, object: self)
        guard policy.sampled(idleSeconds: idleSeconds) else { return }
        NSLog("UserIdleWatch: terminals %@", policy.isIdle ? "redraw twice a second (idle)" : "redraw at full rate (active)")
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}
