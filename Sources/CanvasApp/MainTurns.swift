import Foundation

/// Spreads a burst of main-actor work over wakes of the main thread. Background results for
/// dozens of tiles (a batch creating 65 code tiles: their models and cards) arrive together, and
/// each installs on the main actor; run back to back they froze the window for most of a second.
/// Work queued here runs one item per wake of the main run loop, in arrival order: each once the
/// loop has run out of work due now and is about to sleep, where the window commits its frame, so
/// input, timers and drawing run between them and no item lengthens the busy stretch that queued
/// it. A main-queue turn of its own wouldn't: the run loop doesn't sleep between main-queue turns.
@MainActor
enum MainTurns {
    private static var queue: [@MainActor () -> Void] = []
    private static var handedOver = false
    private static var observer: CFRunLoopObserver?

    /// Returns on a wake of its own, after everything already waiting.
    static func next() async {
        await withCheckedContinuation { continuation in
            onWake { continuation.resume() }
        }
    }

    /// Runs `body` on a wake of its own, after everything already waiting.
    static func onWake(_ body: @escaping @MainActor () -> Void) {
        queue.append(body)
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated { handOver() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    /// The loop is about to sleep: the next item goes on the main queue, which wakes it again.
    private static func handOver() {
        guard !handedOver, !queue.isEmpty else { return }
        handedOver = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                handedOver = false
                queue.removeFirst()()
            }
        }
    }
}
