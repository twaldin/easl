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

/// The runtime: a 1 s watchdog on a utility queue (one wakeup a second, with leeway) claims the
/// main thread's turn in progress from `Metrics` when the policy says to sample it, runs
/// `/usr/bin/sample <pid> 1 -mayDie -file <dir>/<UTC>.txt` with a clean environment, waits for it
/// at most 15 s (a stuck child is killed), prunes the directory, and hands `Metrics` the file for
/// that turn so the stretch's cause can name it. The claim comes before any file or process work,
/// under the lock the main thread ends its turns with: a turn that ended as the watchdog woke is
/// never sampled, and a claimed turn's end always finds its sample.
/// Off under `EASL_DEV_PERF=1` (a sampler suspends the task's threads briefly; measured runs
/// must not see that).
final class StallSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "easl.metrics.stalls", qos: .utility)
    private let directory: URL
    private weak var metrics: Metrics?
    private let now: () -> Double
    private let sample: (_ file: URL) -> Bool
    private var timer: DispatchSourceTimer?

    /// `now` and `sample` are the clock and the child (`StallSampler.sample(into:)`): a test
    /// stands in for both and calls `tick` itself.
    init(directory: URL, metrics: Metrics, now: @escaping () -> Double = Metrics.now, sample: @escaping (_ file: URL) -> Bool = StallSampler.sample(into:)) {
        self.directory = directory
        self.metrics = metrics
        self.now = now
        self.sample = sample
    }

    /// Starts the watchdog.
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    /// One wakeup of the watchdog.
    func tick() {
        guard let metrics, let turn = metrics.claimStall(at: now()) else { return }
        let name = StallSampling.fileName(at: Date())
        let file = directory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sample(file), let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return }
        metrics.stallSampled(turn, file: "stalls/\(name)")
        prune()
    }

    /// Runs `/usr/bin/sample` on this process for a second into `file`, with a clean
    /// environment, waiting at most 15 s: true when it finished successfully.
    static func sample(into file: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), "1", "-mayDie", "-file", file.path]
        process.environment = [:]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return false }
        if done.wait(timeout: .now() + 15) == .timedOut {
            // `terminate()` is only SIGTERM: a wedged child could ignore it and outlive the
            // bounded wait. Kill this exact child and give its termination callback a bound too.
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 1)
            return false
        }
        return process.terminationStatus == 0
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
