import Darwin
import Foundation
import StallCapture

public struct StallSampling: Sendable {
    /// Keep a captured stack only when its turn lasts this long (s).
    public static let threshold = 0.25
    /// Capture early enough to leave scheduling and CPU-bracketing margin for a 300 ms stall.
    public static let captureDelay = 0.15
    /// At most one sample this often (s): a stalling app shouldn't spend its time being sampled.
    public static let minInterval = 300.0
    /// Files kept, newest by modification time first.
    public static let keep = 20

    private var lastSample: Double?
    private var previousSample: Double?
    private var sampledTurn: Double?

    public init() {}

    /// Claims one early capture of the published turn, or none while the loop sleeps.
    public mutating func shouldSample(turnStart: Double?, now: Double) -> Bool {
        guard let turnStart, now >= turnStart + Self.captureDelay else { return false }
        guard sampledTurn != turnStart else { return false }
        if let lastSample, now < lastSample + Self.minInterval { return false }
        previousSample = lastSample
        lastSample = now
        sampledTurn = turnStart
        return true
    }

    func deadline(turnStart: Double?) -> Double? {
        guard let turnStart, sampledTurn != turnStart else { return nil }
        return max(turnStart + Self.captureDelay, (lastSample ?? -.infinity) + Self.minInterval)
    }

    static func qualifies(turnStart: Double, at now: Double) -> Bool {
        now >= turnStart + threshold
    }

    mutating func cancelled(turn: Double) {
        guard sampledTurn == turn else { return }
        lastSample = previousSample
    }

    /// Of `files` (with their modification times), the ones beyond the newest `keep`.
    public static func stale(_ files: [(url: URL, modified: Date)]) -> [URL] {
        guard files.count > keep else { return [] }
        return files.sorted { $0.modified > $1.modified }.dropFirst(keep).map(\.url)
    }

    /// The file name for a sample taken at `date`: UTC to the second, sortable.
    public static func fileName(at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return f.string(from: date) + ".txt"
    }
}

final class StallSampler: @unchecked Sendable {
    let queue = DispatchQueue(label: "easl.metrics.stalls", qos: .userInitiated)
    private let directory: URL
    private weak var metrics: Metrics?
    private let now: () -> Double
    private let sample: ((_ file: URL) -> Bool)?
    private let captured: (() -> Void)?
    private let capture: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var pending: (turn: Double, record: EaslStallRecord)?

    init?(directory: URL, metrics: Metrics, now: @escaping () -> Double = Metrics.now,
          sample: ((_ file: URL) -> Bool)? = nil, captured: (() -> Void)? = nil) {
        self.directory = directory
        self.metrics = metrics
        self.now = now
        self.sample = sample
        self.captured = captured
        capture = sample == nil ? easl_stall_create() : nil
        if sample == nil && capture == nil { return nil }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
        if let capture { easl_stall_destroy(capture) }
    }

    func publish(turn: Double?) {
        if let capture { easl_stall_publish(capture, turn?.bitPattern ?? 0) }
    }

    func schedule(at deadline: Double?) {
        timer?.schedule(deadline: deadline.map { DispatchTime(uptimeNanoseconds: UInt64($0 * 1e9)) } ?? .distantFuture,
                        leeway: .milliseconds(1))
    }

    func finish(_ turn: Double) {
        queue.async { [weak self] in
            guard let self, pending?.turn == turn else { return }
            finishPending()
        }
    }

    func tick() {
        guard let metrics else { return }
        if pending != nil { finishPending() }
        guard pending == nil, let turn = metrics.claimStall(at: now(), sampler: self) else { return }
        var record = EaslStallRecord()
        if sample == nil {
            guard let capture, easl_stall_capture(capture, turn.bitPattern, &record) else {
                metrics.stallFailed(turn, cancelled: record.error == EASL_STALL_ERROR_TURN_CHANGED)
                prune()
                return
            }
        }
        pending = (turn, record)
        captured?()
        finishPending()
    }

    private func finishPending() {
        guard let pending, let metrics else { return }
        switch metrics.prepareStall(pending.turn, at: now()) {
        case .wait: return
        case .discard:
            self.pending = nil
            return
        case .write: break
        }
        self.pending = nil
        defer { prune() }
        let name = StallSampling.fileName(at: Date())
        let file = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sample?(file) ?? write(pending.record, into: file, turn: pending.turn),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            try? FileManager.default.removeItem(at: file)
            metrics.stallFailed(pending.turn)
            return
        }
        if !metrics.stallSampled(pending.turn, file: "stalls/\(name)") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func write(_ record: EaslStallRecord, into file: URL, turn: Double) -> Bool {
        let count = Int(record.frame_count)
        guard let symbols = withUnsafeBytes(of: record.frames, { bytes in
            backtrace_symbols(bytes.bindMemory(to: UnsafeMutableRawPointer?.self).baseAddress, Int32(count))
        }) else { return false }
        defer { free(symbols) }
        let state = Self.state(runState: record.run_state, suspendCount: record.suspend_count, cpuNs: record.cpu_ns)
        let latency = (Double(record.captured_ns) / 1e9 - turn) * 1000
        var text = """
        easl main-thread stall
        Capture latency ms: \(latency)
        Capture uptime ns: \(record.captured_ns)
        State: \(state) (Mach run_state=\(record.run_state), suspend_count=\(record.suspend_count))
        Main CPU ns: \(record.cpu_ns) over \(record.bracket_ns) ns before capture
        Suspension ns: \(record.suspend_ns)
        Walk status: \(record.walk_status), error: \(record.error)
        Main thread stack:

        """
        for index in 0..<count {
            text += String(cString: symbols[index]!)
            if record.has_link_register && index == 1 { text += " [LR candidate; may be stale]" }
            text += "\n"
        }
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }

    static func state(runState: Int32, suspendCount: Int32, cpuNs: UInt64) -> String {
        if suspendCount > 0 { return "not running" }
        if runState == TH_STATE_WAITING || runState == TH_STATE_UNINTERRUPTIBLE { return "blocked in a wait" }
        return runState == TH_STATE_RUNNING && cpuNs > 0 ? "on-CPU" : "not running"
    }

    private func prune() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let files = urls.compactMap { url -> (url: URL, modified: Date)? in
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return (url, date)
        }
        for url in StallSampling.stale(files) { try? FileManager.default.removeItem(at: url) }
    }
}
