import CoreFoundation
import Darwin
import Foundation
import os

/// Always-on performance counters behind `app.metrics`, `easl metrics` and the debug HUD
/// (docs/design.md, "Monitoring"). Every counter is kept for three windows: since launch (or the
/// last reset), the last 60 s and the last 10 min. Safe from any thread; recording is a lock and a
/// dictionary update, so hooks sit on per-call paths (API calls, routings, saves, flips), never per
/// frame or per draw.
///
/// Spans (`span`) also emit an `os_signpost` interval (subsystem `net.waldin.easl`, category
/// `perf`), so an Instruments capture comes labelled. On the main thread they name the work a long
/// stretch did: the main-thread monitor (`monitorMainThread`) times each run-loop turn, and any turn
/// over `logStretch` writes one `app.log` line naming the spans inside it.
public final class Metrics: @unchecked Sendable {
    public static let shared = Metrics()

    /// A main-thread stretch this long or longer is logged with its cause.
    public static let logStretch = 250.0
    /// Stretches this long count as hitches in `main.stretch50`.
    public static let hitchStretch = 50.0

    /// One window's totals: how many, how long (ms, and the longest), how many bytes.
    public struct Tally: Equatable, Sendable {
        public var n = 0
        public var ms = 0.0
        public var maxMs = 0.0
        public var bytes = 0

        mutating func add(_ other: Tally) {
            n += other.n
            ms += other.ms
            maxMs = max(maxMs, other.maxMs)
            bytes += other.bytes
        }

        var json: JSONValue {
            var out: [String: JSONValue] = ["n": .number(Double(n))]
            if ms > 0 { out["ms"] = .number((ms * 10).rounded() / 10); out["maxMs"] = .number((maxMs * 10).rounded() / 10) }
            if bytes > 0 { out["bytes"] = .number(Double(bytes)) }
            return .object(out)
        }
    }

    /// A counter: its total and per-second / per-10-second buckets for the recent windows.
    struct Series {
        var total = Tally()
        var seconds = [Tally](repeating: Tally(), count: 60)
        var secondStamps = [Int](repeating: -1, count: 60)
        var tens = [Tally](repeating: Tally(), count: 60)
        var tenStamps = [Int](repeating: -1, count: 60)

        mutating func add(_ tally: Tally, at now: Double) {
            total.add(tally)
            let second = Int(now)
            let s = second % 60
            if secondStamps[s] != second { secondStamps[s] = second; seconds[s] = Tally() }
            seconds[s].add(tally)
            let ten = second / 10
            let t = ten % 60
            if tenStamps[t] != ten { tenStamps[t] = ten; tens[t] = Tally() }
            tens[t].add(tally)
        }

        func window(_ seconds: Int, at now: Double) -> Tally {
            var out = Tally()
            let second = Int(now)
            if seconds <= 60 {
                for i in 0..<60 where secondStamps[i] > second - seconds { out.add(self.seconds[i]) }
            } else {
                let ten = second / 10
                for i in 0..<60 where tenStamps[i] > ten - seconds / 10 { out.add(tens[i]) }
            }
            return out
        }
    }

    struct Offender {
        var n = 0
        var ms = 0.0
    }

    /// The longest main-thread stretch since the last reset, with what ran in it.
    public struct Stretch: Sendable {
        public var ms: Double
        public var cause: String
        public var at: Double
    }

    private let lock = NSLock()
    private var since: Double
    private var series: [String: Series] = [:]
    private var gauges: [String: Double] = [:]
    private var offenders: [String: [String: Offender]] = [:]
    private var longest: Stretch?
    private var hudShown = false
    private var watchUntil = 0.0
    private let signposter = OSSignposter(subsystem: "net.waldin.easl", category: "perf")
    private let launched: Double
    private let process = ProcessSampler()
    /// The main thread's turn in progress: its start on `now()`'s clock, which names it (a reset
    /// doesn't move it); nil while the loop sleeps. Set at every run-loop activity under `lock`,
    /// where the stall watchdog claims turns, so it never claims one that has already ended.
    private var turnStart: Double?
    private var stalls: StallSampler?
    private var stallPolicy = StallSampling()
    /// The one sample in flight: its turn, its file once `sample` has finished, and once the
    /// turn has ended first, that turn's line (all of it) and when it ended. A late file gets a
    /// tagged line and names the window's `longest` if that turn still is it.
    private var stallPending: (turn: Double, file: String?, ended: Stretch?)?
    private var stallsSampled = 0
    private var stallNewest: String?
    /// Where a long stretch's line goes: `app.log` (NSLog), or a test's list.
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) }) {
        launched = Self.now()
        since = launched
        self.log = log
    }

    /// Seconds on a monotonic clock.
    public static func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    // MARK: Recording

    /// Adds one occurrence (or `count`) to `name`, with its duration and size when it has them.
    public func record(_ name: String, ms: Double = 0, bytes: Int = 0, count: Int = 1) {
        let tally = Tally(n: count, ms: ms, maxMs: ms, bytes: bytes)
        let now = Self.now()
        lock.lock()
        series[name, default: Series()].add(tally, at: now)
        lock.unlock()
    }

    /// Batches summed on the main actor (`KeyLatency` in the app) are handed in before a snapshot
    /// or reset taken there, so a key typed before a reset lands in the epoch it belongs to.
    @MainActor public static var flushBeforeSnapshot: (@MainActor () -> Void)?

    /// Adds a batch summed elsewhere (`KeyLatency`): `count` occurrences, their total and longest.
    public func record(_ name: String, batchMs ms: Double, maxMs: Double, count: Int) {
        guard count > 0 else { return }
        let tally = Tally(n: count, ms: ms, maxMs: maxMs)
        let now = Self.now()
        lock.lock()
        series[name, default: Series()].add(tally, at: now)
        lock.unlock()
    }

    /// Sets a level (live tiles of a kind, subscribers).
    public func gauge(_ name: String, _ value: Double) {
        lock.lock()
        gauges[name] = value
        lock.unlock()
    }

    /// Moves a level by `delta`.
    public func adjust(_ name: String, by delta: Double) {
        lock.lock()
        gauges[name, default: 0] += delta
        lock.unlock()
    }

    /// Counts `key` in the top-offender list `list` (who wrote most, what triggered routings).
    public func offender(_ list: String, _ key: String, ms: Double = 0) {
        lock.lock()
        offenders[list, default: [:]][key, default: Offender()].n += 1
        offenders[list, default: [:]][key, default: Offender()].ms += ms
        lock.unlock()
    }

    /// Times `body` as `name` (milliseconds), inside an `os_signpost` interval `signpost` with
    /// `detail`; on the main thread the span is also what a long stretch's log line names.
    @discardableResult
    public func span<T>(_ signpost: StaticString, _ name: @autoclosure () -> String, detail: @autoclosure () -> String = "", bytes: Int = 0,
                        _ body: () throws -> T) rethrows -> T {
        let label = name()
        let text = detail()
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(signpost, id: id, "\(label, privacy: .public) \(text, privacy: .public)")
        let main = Thread.isMainThread
        if main { MainMonitor.installed?.push() }
        let start = Self.now()
        defer {
            let ms = (Self.now() - start) * 1000
            signposter.endInterval(signpost, state)
            record(label, ms: ms, bytes: bytes)
            if main { MainMonitor.installed?.pop(text.isEmpty ? label : "\(label) \(text)", ms: ms) }
        }
        return try body()
    }

    /// Marks a point in Instruments (a burst coalesced, a routing dropped as stale).
    public func event(_ signpost: StaticString, _ detail: String) {
        signposter.emitEvent(signpost, "\(detail, privacy: .public)")
    }

    // MARK: Main thread

    /// Starts timing main run-loop turns: busy time, stretches over 50 and 250 ms, the longest,
    /// and an `app.log` line for every stretch over `logStretch`. Call once, on the main thread.
    public func monitorMainThread() {
        MainMonitor.install(self)
    }

    /// Samples the process (`/usr/bin/sample`, into `directory`) while the main thread has been in
    /// one turn for `StallSampling.threshold` seconds, at most every `StallSampling.minInterval`;
    /// the stretch's cause then names the file. Not for measured runs: `sample` suspends the
    /// task's threads briefly while it walks their stacks.
    public func sampleStalls(into directory: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard stalls == nil else { return }
        let sampler = StallSampler(directory: directory, metrics: self)
        sampler.start()
        stalls = sampler
    }

    /// The stall watchdog, awake at `now`: the main thread's turn in progress, when the policy
    /// samples it now, becomes the sample in flight. Nil once that turn has ended: it isn't
    /// sampled, and the policy doesn't count it.
    func claimStall(at now: Double) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard stallPolicy.shouldSample(turnStart: turnStart, now: now), let turnStart else { return nil }
        stallPending = (turnStart, nil, nil)
        return turnStart
    }

    /// The sample of the turn that started at `turn` is in `file`.
    func stallSampled(_ turn: Double, file: String) {
        var line: String?
        lock.lock()
        stallsSampled += 1
        stallNewest = file
        if let pending = stallPending, pending.turn == turn {
            if let ended = pending.ended {
                line = Self.busyLine(ended.ms, "\(file); \(ended.cause)")
                if let stretch = longest, stretch.at == ended.at { longest?.cause = "\(file); \(stretch.cause)" }
                stallPending = nil
            } else {
                stallPending?.file = file
            }
        }
        lock.unlock()
        if let line { log(line) }
    }

    /// A main run-loop activity at `now`: the turn that started at `ended.start` is over (`ended.ms`
    /// of it since the last reset) and `next` begins (nil: the loop sleeps). `cause` is what the
    /// turn ran since the reset; `wholeCause`, when a reset dropped some of that, all of it.
    fileprivate func mainTurn(ended: (start: Double, ms: Double)?, next: Double?, at now: Double,
                              cause: @autoclosure () -> String, wholeCause: String?) {
        var line: String?
        lock.lock()
        turnStart = next
        if let ended {
            let ms = ended.ms
            let tally = Tally(n: 1, ms: ms, maxMs: ms)
            if ms >= Self.hitchStretch { series["main.stretch50", default: Series()].add(tally, at: now) }
            if ms >= Self.logStretch { series["main.stretch250", default: Series()].add(tally, at: now) }
            let longer = ms >= Self.hitchStretch && ms > (longest?.ms ?? 0)
            let sampled = stallPending?.turn == ended.start
            if longer || ms >= Self.logStretch || sampled {
                let text = cause()
                var tag = ""
                if ms >= Self.logStretch { line = Self.busyLine(ms, text) }
                if sampled {
                    // The sampled turn's line is all of it, though a reset may have cut what the
                    // window counts.
                    let whole = Stretch(ms: (now - ended.start) * 1000, cause: wholeCause ?? text, at: now)
                    if let file = stallPending?.file {
                        tag = "\(file); "
                        stallPending = nil
                    } else {
                        stallPending?.ended = whole
                    }
                    line = Self.busyLine(whole.ms, tag + whole.cause)
                }
                if longer { longest = Stretch(ms: ms, cause: tag + text, at: now) }
            }
        }
        lock.unlock()
        if let line { log(line) }
    }

    private static func busyLine(_ ms: Double, _ cause: String) -> String {
        String(format: "easl: main thread busy %.0f ms: %@", ms, cause)
    }

    fileprivate func mainBusy(_ ms: Double, turns: Int) {
        let now = Self.now()
        lock.lock()
        series["main.busy", default: Series()].add(Tally(n: turns, ms: ms, maxMs: 0), at: now)
        lock.unlock()
    }

    // MARK: Reading

    /// Clears every counter and the longest stretch; gauges (current levels) stay.
    public func reset() {
        lock.lock()
        series = [:]
        offenders = [:]
        longest = nil
        since = Self.now()
        lock.unlock()
        process.reset()
    }

    /// When counters were last reset (0: never); the main-thread monitor rebases on it.
    fileprivate var resetAt: Double {
        lock.lock()
        defer { lock.unlock() }
        return since == launched ? 0 : since
    }

    /// While the HUD shows, the process is sampled every second instead of every 10.
    public func sampleFast(_ on: Bool) {
        lock.lock()
        hudShown = on
        lock.unlock()
        updateSampling()
    }

    /// A `--watch` read: sample every second until reads stop for 3 s.
    public func watching() {
        lock.lock()
        watchUntil = Self.now() + 3
        lock.unlock()
        updateSampling()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3.1) { [self] in updateSampling() }
    }

    private func updateSampling() {
        lock.lock()
        let fast = hudShown || watchUntil > Self.now()
        lock.unlock()
        process.fast(fast)
    }

    /// Everything, as `app.metrics` returns it.
    public func snapshot() -> JSONValue {
        let now = Self.now()
        lock.lock()
        let series = self.series
        let gauges = self.gauges
        let offenders = self.offenders
        let longest = self.longest
        let since = self.since
        let stallsSampled = self.stallsSampled
        let stallNewest = self.stallNewest
        lock.unlock()
        var counters: [String: JSONValue] = [:]
        for (name, s) in series {
            counters[name] = .object(["total": s.total.json, "last60s": s.window(60, at: now).json, "last10m": s.window(600, at: now).json])
        }
        var top: [String: JSONValue] = [:]
        for (list, entries) in offenders {
            top[list] = .array(entries.sorted { $0.value.n != $1.value.n ? $0.value.n > $1.value.n : $0.key < $1.key }.prefix(5).map { key, value in
                var entry: [String: JSONValue] = ["key": .string(key), "n": .number(Double(value.n))]
                if value.ms > 0 { entry["ms"] = .number((value.ms * 10).rounded() / 10) }
                return .object(entry)
            })
        }
        var result: [String: JSONValue] = [
            "uptimeS": .number((now - launched).rounded()),
            "sinceS": .number((now - since).rounded()),
            "counters": .object(counters),
            "gauges": .object(gauges.mapValues { .number($0) }),
            "top": .object(top),
            "process": process.snapshot(),
        ]
        if let longest {
            result["longest"] = .object(["ms": .number(longest.ms.rounded()), "cause": .string(longest.cause), "agoS": .number((now - longest.at).rounded())])
        }
        var stalls: [String: JSONValue] = ["sampled": .number(Double(stallsSampled))]
        if let stallNewest { stalls["newest"] = .string(stallNewest) }
        result["stalls"] = .object(stalls)
        return .object(result)
    }
}

/// One unit of a gauge held for as long as this lives (a live web view): released exactly once,
/// however its owner lets go of it.
public final class GaugeHold: Sendable {
    private let name: String

    public init(_ name: String) {
        self.name = name
        Metrics.shared.adjust(name, by: 1)
    }

    deinit { Metrics.shared.adjust(name, by: -1) }
}

/// The main run loop's turns, timed by an observer: a turn runs from waking (or the end of the
/// previous turn) until the loop next checks timers or goes to sleep. Main-thread spans inside a
/// turn are kept so a long turn can say what it did. Main thread only: `monitorMainThread`
/// installs one on the main run loop; a test drives its own with chosen times.
final class MainMonitor {
    nonisolated(unsafe) fileprivate static var installed: MainMonitor?
    nonisolated(unsafe) private static var observer: CFRunLoopObserver?
    private let metrics: Metrics
    private var turns: RunLoopTurns
    private var depth = 0
    /// Spans that ended in this turn: (nesting depth, label, ms), in end order.
    private var spans: [(depth: Int, label: String, ms: Double)] = []

    init(_ metrics: Metrics, at now: Double) {
        self.metrics = metrics
        turns = RunLoopTurns(at: now, reset: metrics.resetAt)
    }

    fileprivate static func install(_ metrics: Metrics) {
        guard observer == nil else { return }
        let monitor = MainMonitor(metrics, at: Metrics.now())
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeTimers.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            monitor.loop(sleeping: activity == .beforeWaiting, at: Metrics.now())
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        installed = monitor
    }

    /// A span begins on the main thread.
    func push() { depth += 1 }

    /// The innermost open span ends: `label`, `ms` long.
    func pop(_ label: String, ms: Double) {
        depth -= 1
        // Keep the turn's record small: only spans that could matter to a long stretch.
        if ms >= 1 || depth == 0 { spans.append((depth, label, ms)) }
        if spans.count > 64 { spans.removeFirst(spans.count - 64) }
    }

    /// A run-loop activity at `now`: the loop goes to sleep (`sleeping`), or wakes or checks timers.
    func loop(sleeping: Bool, at now: Double) {
        let started = turns.turnStart
        // Spans that ended before a reset are not the new window's (open ones keep their depth);
        // a sampled turn's own line still names them.
        var wholeCause: String?
        if turns.rebase(reset: metrics.resetAt) {
            wholeCause = cause()
            spans.removeAll(keepingCapacity: true)
        }
        let step = turns.activity(sleeping: sleeping, at: now)
        metrics.mainTurn(ended: started.map { (start: $0, ms: step.turn ?? 0) }, next: turns.turnStart, at: now, cause: cause(), wholeCause: wholeCause)
        spans.removeAll(keepingCapacity: true)
        if let busy = step.flush { metrics.mainBusy(busy.ms, turns: busy.turns) }
    }

    /// The turn's top-level spans, longest first, each with its longest nested span.
    private func cause() -> String {
        var parts: [(ms: Double, text: String)] = []
        var children: [(depth: Int, label: String, ms: Double)] = []
        for span in spans {
            if span.depth == 0 {
                var text = String(format: "%@ %.0f ms", span.label, span.ms)
                if let child = children.max(by: { $0.ms < $1.ms }) { text += String(format: " (%@ %.0f ms)", child.label, child.ms) }
                parts.append((span.ms, text))
                children = []
            } else {
                children.append(span)
            }
        }
        if let child = children.max(by: { $0.ms < $1.ms }) { parts.append((child.ms, String(format: "%@ %.0f ms", child.label, child.ms))) }
        guard !parts.isEmpty else { return "untagged work" }
        return parts.sorted { $0.ms > $1.ms }.prefix(3).map(\.text).joined(separator: "; ")
    }
}

/// Run-loop turn timing (times in seconds, results in ms): each observed activity ends the turn
/// in progress, and busy time is handed over about once a second. A metrics reset rebases it, so
/// busy time and the part of a turn before the reset don't count toward the new window.
public struct RunLoopTurns: Sendable {
    /// When the turn in progress began (nil while the loop sleeps). A reset doesn't move it: it
    /// names the turn, which a stall sample is correlated by.
    public private(set) var turnStart: Double?
    private var busy = 0.0
    private var turns = 0
    private var flushed: Double
    private var reset: Double

    public init(at now: Double, reset: Double = 0) {
        flushed = now
        self.reset = reset
    }

    /// Applies a reset made at `reset` (a no-op for one already seen); true when it was new.
    public mutating func rebase(reset: Double) -> Bool {
        guard reset > self.reset else { return false }
        self.reset = reset
        busy = 0
        turns = 0
        flushed = reset
        return true
    }

    /// One run-loop activity at `now`: the length of the turn it ended since the last reset (ms),
    /// and the busy time and turn count due to be recorded, once a second.
    public mutating func activity(sleeping: Bool, at now: Double) -> (turn: Double?, flush: (ms: Double, turns: Int)?) {
        var turn: Double?
        if let start = turnStart {
            let ms = (now - max(start, reset)) * 1000
            busy += ms
            turns += 1
            turn = ms
        }
        turnStart = sleeping ? nil : now
        guard now - flushed >= 1 else { return (turn, nil) }
        defer { busy = 0; turns = 0; flushed = now }
        return (turn, (busy, turns))
    }
}

/// The process's CPU, wakeups, memory and energy (`proc_pid_rusage`), and its WebKit helpers'
/// (processes macOS holds easl responsible for), sampled on a utility queue every 10 s, or every
/// second while `fast`.
final class ProcessSampler: @unchecked Sendable {
    struct Sample {
        var at: Double
        var cpuNs: Double
        var interruptWakeups: Double
        var idleWakeups: Double
        var energyNJ: Double
        var footprint: Double
        var peak: Double
    }

    struct Helper {
        var pid: Int32
        var name: String
        var cpuNs: Double
        var footprint: Double
        var at: Double
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "easl.metrics.process", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var samples: [Sample] = []
    private var base: Sample?
    private var helpers: [Int32: Helper] = [:]
    private var helperCPU: [Int32: Double] = [:]
    private var interval: Double = 10
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    init() {
        // Set before `self` is shared with the queue: `snapshot` reads it from the caller's thread.
        base = Self.sample(getpid())
        queue.async { [self] in schedule() }
    }

    private func schedule() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(interval > 1 ? 1000 : 100))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func fast(_ on: Bool) {
        queue.async { [self] in
            let wanted: Double = on ? 1 : 10
            guard wanted != interval else { return }
            interval = wanted
            schedule()
            tick()
        }
    }

    func reset() {
        queue.async { [self] in
            lock.lock()
            base = Self.sample(getpid())
            samples = []
            lock.unlock()
        }
    }

    private func tick() {
        guard let now = Self.sample(getpid()) else { return }
        let found = Self.helpers()
        lock.lock()
        samples.append(now)
        let cutoff = now.at - 660
        samples.removeAll { $0.at < cutoff }
        var next: [Int32: Helper] = [:]
        for helper in found {
            if let previous = helpers[helper.pid], helper.at > previous.at {
                helperCPU[helper.pid] = (helper.cpuNs - previous.cpuNs) / ((helper.at - previous.at) * 1e9) * 100
            }
            next[helper.pid] = helper
        }
        helpers = next
        helperCPU = helperCPU.filter { next[$0.key] != nil }
        lock.unlock()
    }

    static func sample(_ pid: Int32) -> Sample? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return nil }
        return Sample(at: Metrics.now(), cpuNs: Double(info.ri_user_time + info.ri_system_time) * timebase,
                      interruptWakeups: Double(info.ri_interrupt_wkups), idleWakeups: Double(info.ri_pkg_idle_wkups),
                      energyNJ: Double(info.ri_billed_energy), footprint: Double(info.ri_phys_footprint),
                      peak: Double(info.ri_lifetime_max_phys_footprint))
    }

    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    private static let responsible: Responsible? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Responsible.self)
    }()

    /// Processes other than easl that macOS holds easl responsible for (WebKit's content, GPU and
    /// networking processes).
    static func helpers() -> [Helper] {
        guard let responsible else { return [] }
        let me = getpid()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard found > 0 else { return [] }
        var out: [Helper] = []
        for pid in pids.prefix(Int(found)) where pid > 0 && pid != me && responsible(pid) == me {
            guard let sample = sample(pid) else { continue }
            var name = [UInt8](repeating: 0, count: 256)
            proc_name(pid, &name, UInt32(name.count))
            out.append(Helper(pid: pid, name: String(decoding: name.prefix { $0 != 0 }, as: UTF8.self), cpuNs: sample.cpuNs, footprint: sample.footprint, at: sample.at))
        }
        return out
    }

    func snapshot() -> JSONValue {
        guard let current = Self.sample(getpid()) else { return .object([:]) }
        lock.lock()
        let samples = self.samples
        let base = self.base
        let helpers = self.helpers
        let helperCPU = self.helperCPU
        lock.unlock()
        func rates(_ from: Sample?) -> (cpu: Double, wakeups: Double, idle: Double, energy: Double)? {
            guard let from, current.at - from.at >= 0.5 else { return nil }
            let seconds = current.at - from.at
            return ((current.cpuNs - from.cpuNs) / (seconds * 1e9) * 100, (current.interruptWakeups - from.interruptWakeups) / seconds,
                    (current.idleWakeups - from.idleWakeups) / seconds, (current.energyNJ - from.energyNJ) / seconds / 1e6)
        }
        // The oldest sample within each window (the window is as long as samples reach).
        func oldest(within seconds: Double) -> Sample? { samples.first { current.at - $0.at <= seconds + 5 } }
        var windows: [String: JSONValue] = [:]
        for (name, from) in [("total", base), ("last60s", oldest(within: 60)), ("last10m", oldest(within: 600))] {
            guard let r = rates(from) else { continue }
            windows[name] = .object([
                "cpuPercent": .number((r.cpu * 10).rounded() / 10),
                "interruptWakeupsPerS": .number((r.wakeups * 10).rounded() / 10),
                "idleWakeupsPerS": .number((r.idle * 10).rounded() / 10),
                "energyMJPerS": .number((r.energy * 100).rounded() / 100),
            ])
        }
        return .object([
            "footprintMB": .number((current.footprint / 1_048_576).rounded()),
            "peakFootprintMB": .number((current.peak / 1_048_576).rounded()),
            "windows": .object(windows),
            "helpers": .array(helpers.values.sorted { $0.pid < $1.pid }.map { helper in
                var entry: [String: JSONValue] = ["pid": .number(Double(helper.pid)), "name": .string(helper.name),
                                                  "footprintMB": .number((helper.footprint / 1_048_576).rounded())]
                if let cpu = helperCPU[helper.pid] { entry["cpuPercent"] = .number((cpu * 10).rounded() / 10) }
                return .object(entry)
            }),
        ])
    }
}
