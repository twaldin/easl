import AppKit
import QuartzCore

/// Development performance probes (`EASL_DEV_PERF=1`; see docs/testing.md "Performance
/// probes"). Off, every call returns after one flag check.
///
/// A span covers an input-replay burst (plus a settle after it) or an idle window
/// (`dev-input <pid> perf <ms>`). While it runs, a display link on the canvas window counts frames
/// and missed vsyncs, a main run-loop observer measures each busy stretch of the main thread
/// (from waking to going back to sleep: a stretch over one frame is a hitch), and code paths
/// report counts (`count`, e.g. draws per view type) and timed sections (`time`). When the span
/// ends, `app.log` gets one `DevPerf:` line per phase.
@MainActor
enum DevPerf {
    static let enabled = ProcessInfo.processInfo.environment["EASL_DEV_PERF"] == "1"
    /// Pause after a burst's last step that still belongs to it: the liveness pass, card and
    /// live flips, and the redraws they cause.
    static let settle: TimeInterval = 1.5

    private struct Phase {
        let name: String
        let start = CACurrentMediaTime()
        var end: CFTimeInterval?
        var frames = 0, missed = 0
        var longestFrame = 0.0
        var lastFrame: CFTimeInterval?
        var busy = 0.0, hitches = 0, longestBusy = 0.0
        /// The main thread's CPU time over its busy stretches, and the most one stretch took:
        /// what the stretch needed, whatever else the Mac ran (a stretch's wall time grows
        /// with preemption; its CPU time doesn't).
        var cpu = 0.0, longestCpu = 0.0
        var counts: [String: Int] = [:]
        var timings: [String: (count: Int, total: Double, max: Double)] = [:]

        init(name: String) { self.name = name }
    }

    private final class Span {
        let label: String
        var phases: [Phase]
        var link: CADisplayLink?
        var period = 1.0 / 60
        init(label: String, phase: String) {
            self.label = label
            phases = [Phase(name: phase)]
        }
    }

    private static var span: Span?
    private static var observer: CFRunLoopObserver?
    private static var wokeAt: CFTimeInterval?

    // MARK: Probes

    static func count(_ name: @autoclosure () -> String, _ amount: Int = 1) {
        guard enabled, let span else { return }
        span.phases[span.phases.count - 1].counts[name(), default: 0] += amount
    }

    /// Times `body` on the main thread and records it under `name`.
    static func time<T>(_ name: @autoclosure () -> String, _ body: () throws -> T) rethrows -> T {
        guard enabled, span != nil else { return try body() }
        let start = CACurrentMediaTime()
        defer { record(name(), ms: (CACurrentMediaTime() - start) * 1000) }
        return try body()
    }

    static func record(_ name: String, ms: Double) {
        guard enabled, let span else { return }
        let index = span.phases.count - 1
        var entry = span.phases[index].timings[name] ?? (0, 0, 0)
        entry.count += 1
        entry.total += ms
        entry.max = max(entry.max, ms)
        span.phases[index].timings[name] = entry
    }

    /// Start of a section timed with `record(_:since:)`; nil when no span runs (cheap in draws).
    static func mark() -> CFTimeInterval? {
        enabled && span != nil ? CACurrentMediaTime() : nil
    }

    static func record(_ name: @autoclosure () -> String, since start: CFTimeInterval?) {
        guard let start else { return }
        record(name(), ms: (CACurrentMediaTime() - start) * 1000)
    }

    // MARK: Spans

    /// Starts a span on `window` (its display link paces the frames), ending any open one.
    static func begin(_ label: String, phase: String, window: NSWindow?) {
        guard enabled else { return }
        if span != nil { end() }
        installObserver()
        let span = Span(label: label, phase: phase)
        self.span = span
        wokeAt = CACurrentMediaTime()
        guard let view = window?.contentView else { return }
        let link = view.displayLink(target: Ticker.shared, selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        span.link = link
    }

    /// Closes the current phase and opens the next one.
    static func phase(_ name: String) {
        guard enabled, let span else { return }
        span.phases[span.phases.count - 1].end = CACurrentMediaTime()
        span.phases.append(Phase(name: name))
    }

    static func end() {
        guard enabled, let span else { return }
        span.link?.invalidate()
        self.span = nil
        let period = span.period * 1000
        for phase in span.phases {
            let ms = ((phase.end ?? CACurrentMediaTime()) - phase.start) * 1000
            let counts = phase.counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            let timings = phase.timings.sorted { $0.key < $1.key }.map {
                String(format: "%@=%d/%.1f/%.1f", $0.key, $0.value.count, $0.value.total, $0.value.max)
            }.joined(separator: " ")
            NSLog("DevPerf: %@ %@ %.0f ms: frames %d missed %d (vsync %.1f ms, longest frame %.1f ms), main busy %.0f ms, hitches %d (longest %.1f ms), main cpu %.0f ms (longest %.1f ms); counts: %@; timings (n/total/max ms): %@",
                  span.label, phase.name, ms, phase.frames, phase.missed, period, phase.longestFrame,
                  phase.busy, phase.hitches, phase.longestBusy, phase.cpu, phase.longestCpu, counts, timings)
        }
    }

    /// An idle span of `ms` milliseconds on the front canvas window.
    static func idle(ms: Double, window: NSWindow?) {
        begin("idle", phase: "idle", window: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) { MainActor.assumeIsolated { end() } }
    }

    fileprivate static func frame(_ link: CADisplayLink) {
        guard let span else { return }
        let index = span.phases.count - 1
        let period = link.duration > 0 ? link.duration : span.period
        span.period = period
        let now = link.timestamp
        if let last = span.phases[index].lastFrame {
            let interval = now - last
            span.phases[index].longestFrame = max(span.phases[index].longestFrame, interval * 1000)
            span.phases[index].missed += max(0, Int((interval / period).rounded()) - 1)
        } else if index > 0, let last = span.phases[index - 1].lastFrame {
            // A phase's first frame continues the previous phase's pacing.
            span.phases[index].missed += max(0, Int(((now - last) / period).rounded()) - 1)
        }
        span.phases[index].lastFrame = now
        span.phases[index].frames += 1
    }

    private static func installObserver() {
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            MainActor.assumeIsolated { runLoop(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private static func runLoop(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6
        if activity == .afterWaiting {
            wokeAt = now
            wokeCpu = cpu
            return
        }
        guard let woke = wokeAt, let span else { return }
        wokeAt = nil
        let index = span.phases.count - 1
        let ms = (now - woke) * 1000
        span.phases[index].busy += ms
        span.phases[index].longestBusy = max(span.phases[index].longestBusy, ms)
        if ms > span.period * 1000 { span.phases[index].hitches += 1 }
        let used = cpu - wokeCpu
        span.phases[index].cpu += used
        span.phases[index].longestCpu = max(span.phases[index].longestCpu, used)
    }

    @MainActor private final class Ticker: NSObject {
        static let shared = Ticker()
        @objc func tick(_ link: CADisplayLink) {
            DevPerf.frame(link)
        }
    }
}
