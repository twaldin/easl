import Darwin
import Foundation

/// When the main thread has been in one run-loop turn for a second or more, a backtrace of the
/// whole process is worth more than the stretch's length: `StallSampler` runs `/usr/bin/sample`
/// on easl itself from a utility thread while the stall is still going, into `stalls/` in the
/// easl home, and the stretch's cause names the file. `StallSampling` is the policy, apart from
/// the clock, the process and the file system so it can be tested as a unit: a turn is sampled
/// once, at most one sample every five minutes, and only the newest twenty files are kept.
public struct StallSampling: Sendable, Equatable {
    /// A turn this long (s) is a stall worth a sample.
    public static let threshold = 1.0
    /// At most one sample this often (s): a stalling app shouldn't spend its time being sampled.
    public static let minInterval = 300.0
    /// Files kept, newest by modification time first.
    public static let keep = 20

    private var lastSample: Double?
    private var sampledTurn: Double?

    public init() {}

    /// A watchdog tick at `now` with the main thread's current turn started at `turnStart` (nil
    /// while it sleeps): true when a sample should be taken now.
    public mutating func shouldSample(turnStart: Double?, now: Double) -> Bool {
        guard let turnStart, now - turnStart >= Self.threshold else { return false }
        guard sampledTurn != turnStart else { return false }
        if let lastSample, now - lastSample < Self.minInterval { return false }
        lastSample = now
        sampledTurn = turnStart
        return true
    }

    /// Of `files` (with their modification times), the ones beyond the newest `keep`.
    public static func stale(_ files: [(url: URL, modified: Date)], keep: Int = keep) -> [URL] {
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

/// The runtime: a 1 s watchdog on a utility queue (one wakeup a second, with leeway) reads the
/// main thread's current turn start that `Metrics` publishes, and when the policy says so runs
/// `/usr/bin/sample <pid> 1 -mayDie -file <dir>/<UTC>.txt` with a clean environment, waits for it
/// at most 15 s (a stuck child is killed), prunes the directory, and tells `Metrics` which turn
/// was sampled into which file so the stretch's cause can name it when the turn ends.
/// Off under `EASL_DEV_PERF=1` (a sampler suspends the task's threads briefly; measured runs
/// must not see that).
final class StallSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "easl.metrics.stalls", qos: .utility)
    private let directory: URL
    private let turnStart: () -> Double?
    private let sampling: (_ turnStart: Double) -> Void
    private let sampled: (_ turnStart: Double, _ file: String) -> Void
    private var timer: DispatchSourceTimer?
    private var policy = StallSampling()

    init(directory: URL, turnStart: @escaping () -> Double?, sampling: @escaping (Double) -> Void, sampled: @escaping (Double, String) -> Void) {
        self.directory = directory
        self.turnStart = turnStart
        self.sampled = sampled
        self.sampling = sampling
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    private func tick() {
        let start = turnStart()
        guard policy.shouldSample(turnStart: start, now: Metrics.now()), let start else { return }
        let name = StallSampling.fileName(at: Date())
        let file = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), "1", "-mayDie", "-file", file.path]
        process.environment = [:]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        sampling(start)
        do { try process.run() } catch { return }
        if done.wait(timeout: .now() + 15) == .timedOut {
            // `terminate()` is only SIGTERM: a wedged child could ignore it and outlive the
            // bounded wait. Kill this exact child and give its termination callback a bound too.
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 1)
            return
        }
        guard process.terminationStatus == 0,
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return }
        sampled(start, "stalls/\(name)")
        prune()
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
