import AppKit
import CanvasCore

/// Tells terminals when the user is away (`IdleRedraw`). The Mac's time since its last input
/// event (`CGEventSource.secondsSinceLastEventType`, any event, the session's combined state) is
/// sampled on a timer the policy paces; the app's own input events arrive through a local monitor
/// and restore full rate at once. A change posts `changed`; `TerminalTile` reads `isIdle` and
/// pulses its surface.
/// The development idle pin overrides both redraw and installation idle checks until cleared.
@MainActor
final class UserIdleWatch {
    static let shared = UserIdleWatch()
    static let changed = Notification.Name("easl.userIdle.changed")
    static let sampled = Notification.Name("easl.userIdle.sampled")

    private(set) var policy = IdleRedraw()
    private var pinned = false
    private var timer: DispatchSourceTimer?
    private var monitor: Any?
    private let sessionIdle: () -> TimeInterval
    private let uptime: () -> TimeInterval
    private var lastInput: TimeInterval?

    init(sessionIdle: @escaping () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sessionIdle = sessionIdle
        self.uptime = uptime
    }

    var isIdle: Bool { policy.isIdle }
    private(set) var idleSeconds: TimeInterval = 0

    /// AppKit events can arrive without resetting the session's HID clock.
    func currentIdleSeconds() -> TimeInterval {
        if pinned { return idleSeconds }
        let system = sessionIdle()
        return lastInput.map { min(system, uptime() - $0) } ?? system
    }
    /// Terminals shown and able to draw (`TerminalTile.updateSurfaceVisibility`).
    private(set) var drawable = 0

    func terminalDrawable(_ on: Bool) {
        let was = drawable
        drawable = max(0, drawable + (on ? 1 : -1))
        if (was == 0 && drawable > 0) || (was > 0 && drawable == 0) { sample() }
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
        case "on": pinned = true; apply(idleSeconds: AppUpdate.automaticIdleThreshold)
        case "off": pinned = true; apply(idleSeconds: 0)
        default: pinned = false; sample()
        }
        if pinned { sample(notifyUpdater: true) }
    }

    private func sample(notifyUpdater: Bool = false) {
        timer?.cancel()
        timer = nil
        let idle = currentIdleSeconds()
        apply(idleSeconds: idle)
        if notifyUpdater { NotificationCenter.default.post(name: Self.sampled, object: self) }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = max(drawable > 0 ? 1 : 60, policy.nextSample(idleSeconds: idle))
        timer.schedule(deadline: .now() + interval, leeway: .milliseconds(200))
        timer.setEventHandler { MainActor.assumeIsolated { self.sample(notifyUpdater: true) } }
        timer.resume()
        self.timer = timer
    }

    private func input() {
        lastInput = uptime()
        guard !pinned else { return }
        if policy.isIdle { apply(idleSeconds: 0) }
    }

    private func apply(idleSeconds: TimeInterval) {
        self.idleSeconds = idleSeconds
        guard policy.sampled(idleSeconds: idleSeconds) else { return }
        NSLog("UserIdleWatch: terminals %@", policy.isIdle ? "redraw twice a second (idle)" : "redraw at full rate (active)")
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}
