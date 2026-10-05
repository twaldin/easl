import Foundation

/// Whether the API is busy, for work that should wait out a burst of calls (the board's arrow
/// routing, `ShapeLayer`) and for keeping macOS from throttling easl while it serves them.
///
/// A burst is calls arriving back to back: an agent that measures a page, writes it, measures the
/// next. The API is quiet once no call has been in flight for `quietGap`. Calls that wait on
/// something else for a long time (`waits`: an agent's turn, a render, a page load) don't count,
/// so they never hold routing back.
///
/// While calls are in flight, and for `holdAfter` after the last one, easl holds a user-initiated
/// activity (`ProcessInfo.beginActivity`): a hidden or occluded window otherwise lets App Nap and
/// background QoS slow every main-thread job of the burst several times over.
@MainActor
public final class ApiActivity {
    public static let shared = ApiActivity()

    /// How long the API stays idle before a burst counts as over.
    public static let quietGap: TimeInterval = 0.3
    /// How long the activity is held after the last call.
    public static let holdAfter: TimeInterval = 2
    /// Methods that wait (on an agent, a page, a render) rather than work: they don't make a burst.
    static let waits: Set<String> = ["agent.wait", "agent.prompt", "agent.read", "view.render", "view.snapshot", "object.reload", "tray.drain", "events.subscribe"]

    private var inFlight = 0
    private var lastEnded = -Double.infinity
    private var waiters: [() -> Void] = []
    private var check: DispatchWorkItem?
    private var activity: NSObjectProtocol?
    private var release: DispatchWorkItem?
    /// Nested `dispatch` depth: a board change made while this is positive came from the API.
    public private(set) var dispatching = 0

    /// A call started (`ApiRouter.handle`).
    public func began(_ method: String) {
        hold()
        guard !Self.waits.contains(method) else { return }
        inFlight += 1
    }

    /// A call ended.
    public func ended(_ method: String) {
        hold()
        guard !Self.waits.contains(method) else { return }
        inFlight = max(0, inFlight - 1)
        lastEnded = Metrics.now()
        if inFlight == 0 { scheduleCheck(after: Self.quietGap) }
    }

    /// Runs `body` as the API's synchronous work on the board (`ApiRouter.dispatch`).
    public func dispatch<T>(_ body: () throws -> T) rethrows -> T {
        dispatching += 1
        defer { dispatching -= 1 }
        return try body()
    }

    public var isQuiet: Bool {
        inFlight == 0 && Metrics.now() - lastEnded >= Self.quietGap
    }

    /// Runs `body` on a later main-queue turn once the API is quiet: right away (next turn) when it
    /// already is, else when the current burst ends.
    public func whenQuiet(_ body: @escaping @MainActor () -> Void) {
        if isQuiet {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
            return
        }
        waiters.append(body)
        if inFlight == 0 { scheduleCheck(after: max(0, Self.quietGap - (Metrics.now() - lastEnded))) }
    }

    private func scheduleCheck(after delay: TimeInterval) {
        check?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isQuiet else { return }
                let ready = self.waiters
                self.waiters = []
                if !ready.isEmpty { Metrics.shared.event("api", "quiet: \(ready.count) deferred") }
                for body in ready { body() }
            }
        }
        check = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.001, execute: work)
    }

    private func hold() {
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                             reason: "serving easl API calls")
            Metrics.shared.record("api.activity.begin")
        }
        release?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.inFlight == 0, let activity = self.activity else { return }
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
        }
        release = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdAfter, execute: work)
    }
}
