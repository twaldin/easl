import AppKit
import Markdown

@MainActor
public protocol NoteMermaidBackend: AnyObject {
    func start(_ key: NoteMermaid.Key, completion: @escaping @MainActor (NoteMermaid.Outcome) -> Void) -> (@MainActor () -> Void)
}

/// Calls `ready` immediately before rendering, after all renderer preparation has completed.
/// Preparation has a 10-second bound; rendering has a separate 2-second bound.
/// Call `failed` for renderer failures, or `completion` for image/content outcomes.
/// Renderer failures and preparation timeouts retry once; warm timeouts and content failures do not.
@MainActor
public protocol NoteMermaidPreparingBackend: NoteMermaidBackend {
    func start(_ key: NoteMermaid.Key, ready: @escaping @MainActor () -> Void,
               failed: @escaping @MainActor (String) -> Void,
               completion: @escaping @MainActor (NoteMermaid.Outcome) -> Void) -> (@MainActor () -> Void)
}

extension NoteMermaidPreparingBackend {
    public func start(_ key: NoteMermaid.Key,
                      completion: @escaping @MainActor (NoteMermaid.Outcome) -> Void) -> (@MainActor () -> Void) {
        start(key, ready: {}, failed: { completion(.fallback($0)) }, completion: completion)
    }
}

@MainActor
public enum NoteMermaid {
    public enum Appearance: String, Hashable, Sendable {
        case light, dark
    }

    public struct Key: Hashable, Sendable {
        public let source: String
        public let width: Int
        public let appearance: Appearance
    }

    @MainActor
    public enum Outcome {
        case image(NSImage)
        case fallback(String)
    }

    public static func appearance(_ value: NSAppearance = NSAppearance.currentDrawing()) -> Appearance {
        value.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    public static var backend: (any NoteMermaidBackend)? {
        get { service.backend }
        set { service.install(newValue) }
    }

    public static func resolve(_ document: Document, width: CGFloat, appearance: Appearance) async -> [Int: Outcome] {
        await service.resolve(fences(in: document, width: width, appearance: appearance))
    }

    /// Registers before returning. Completion may run synchronously; cancelling delivers any
    /// completed outcomes once and aborts jobs only when no other consumer still needs them.
    public static func request(_ document: Document, width: CGFloat, appearance: Appearance,
                               completion: @escaping @MainActor ([Int: Outcome]) -> Void) -> (@MainActor () -> Void) {
        service.request(fences(in: document, width: width, appearance: appearance), completion: completion)
    }

    public static func cached(_ document: Document, width: CGFloat, appearance: Appearance) -> [Int: Outcome] {
        service.cached(fences(in: document, width: width, appearance: appearance))
    }

    public static func hasFences(in document: Document) -> Bool {
        func walk(_ markup: Markup) -> Bool {
            if let block = markup as? CodeBlock, isMermaid(block) { return true }
            return markup.children.contains { walk($0) }
        }
        return walk(document)
    }

    private static let service = Service()
    static let maxOccurrences = 20
    static let maxSourceBytes = 50 * 1024
    static let maxDimension = 8192
    static let maxPixels = 4 * 1024 * 1024
    static let cacheBytes = 32 * 1024 * 1024
    private static let maxQueued = 128
    private static let maxConsumers = 256
    private static let maxCacheEntries = 512

    static func isMermaid(_ block: CodeBlock) -> Bool {
        block.language?.trimmingCharacters(in: .whitespacesAndNewlines) == "mermaid"
    }

    static func listMarkerWidth(ordered: Bool, checkbox: Bool) -> CGFloat {
        ordered ? 22 : (checkbox ? 20 : 14)
    }

    static func effectiveWidth(_ width: CGFloat, indent: CGFloat) -> Int? {
        guard width.isFinite, width > 0 else { return nil }
        let available = width - 2 * ObjectMeasure.noteLineFragmentPadding - indent - 4
        guard available >= 1 else { return nil }
        return Int(min(CGFloat(maxDimension), available).rounded(.down))
    }

    private struct Fence {
        let line: Int
        let admission: Admission
    }

    private enum Admission {
        case key(Key)
        case fallback(String)
    }

    private static func fences(in document: Document, width: CGFloat, appearance: Appearance) -> [Fence] {
        var result: [Fence] = []
        var occurrences = 0
        func walk(_ markup: Markup, indent: CGFloat) {
            if let block = markup as? CodeBlock, isMermaid(block) {
                occurrences += 1
                let admission: Admission
                if occurrences > maxOccurrences {
                    admission = .fallback("Only the first 20 Mermaid fences in a note are rendered.")
                } else if block.code.utf8.count > maxSourceBytes {
                    admission = .fallback("Mermaid source exceeds 50 KiB.")
                } else if let width = effectiveWidth(width, indent: indent) {
                    admission = .key(Key(source: block.code, width: width, appearance: appearance))
                } else {
                    admission = .fallback("Mermaid needs a finite, positive rendering width.")
                }
                result.append(Fence(line: block.range?.lowerBound.line ?? 1, admission: admission))
                return
            }
            if let list = markup as? UnorderedList {
                for item in list.listItems {
                    walk(item, indent: indent + listMarkerWidth(ordered: false, checkbox: item.checkbox != nil) + 4)
                }
                return
            }
            if let list = markup as? OrderedList {
                for item in list.listItems {
                    walk(item, indent: indent + listMarkerWidth(ordered: true, checkbox: item.checkbox != nil) + 4)
                }
                return
            }
            let indent = indent + (markup is BlockQuote ? 14 : 0)
            for child in markup.children { walk(child, indent: indent) }
        }
        walk(document, indent: 0)
        return result
    }

    private struct CacheEntry {
        let outcome: Outcome
        let bytes: Int
        var access: UInt64
    }

    @MainActor
    private final class Attempt {
        enum Phase {
            case preparing, rendering
        }

        var phase: Phase
        let canRetry: Bool
        var deadline: Task<Void, Never>?
        var abort: (@MainActor () -> Void)?
        var abortOnReturn = false

        init(preparing: Bool) {
            phase = preparing ? .preparing : .rendering
            canRetry = preparing
        }

        func stop(aborting: Bool) {
            deadline?.cancel()
            deadline = nil
            abortOnReturn = aborting
            let abort = self.abort
            self.abort = nil
            if aborting { abort?() }
        }
    }

    @MainActor
    private final class Job {
        enum State {
            case queued
            case running(Attempt)
        }

        let key: Key
        var consumers: Set<UUID> = []
        var state: State = .queued
        var retries = 0

        init(_ key: Key) { self.key = key }
    }

    private struct Consumer {
        var pending: [Key: [Int]]
        var outcomes: [Int: Outcome]
        let completion: @MainActor ([Int: Outcome]) -> Void
    }

    @MainActor
    private final class Service {
        private(set) var backend: (any NoteMermaidBackend)?
        private var jobs: [Key: Job] = [:]
        private var queue: [Key] = []
        private var active = 0
        private var draining = false
        private var consumers: [UUID: Consumer] = [:]
        private var cache: [Key: CacheEntry] = [:]
        private var bytes = 0
        private var access: UInt64 = 0
        private var generation = UUID()

        func install(_ backend: (any NoteMermaidBackend)?) {
            generation = UUID()
            let oldJobs = Array(jobs.values)
            let oldConsumers = Array(consumers.values)
            jobs.removeAll()
            queue.removeAll()
            consumers.removeAll()
            active = 0
            cache.removeAll()
            bytes = 0
            self.backend = backend
            for job in oldJobs {
                if case .running(let attempt) = job.state {
                    attempt.stop(aborting: true)
                }
            }
            for consumer in oldConsumers { consumer.completion(consumer.outcomes) }
        }

        func cached(_ fences: [Fence]) -> [Int: Outcome] {
            guard backend != nil else { return [:] }
            var result: [Int: Outcome] = [:]
            for fence in fences {
                switch fence.admission {
                case .fallback(let reason): result[fence.line] = .fallback(reason)
                case .key(let key): result[fence.line] = lookup(key)
                }
            }
            return result
        }

        func resolve(_ fences: [Fence]) async -> [Int: Outcome] {
            guard backend != nil, !fences.isEmpty, !Task.isCancelled else { return [:] }
            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: [:])
                        return
                    }
                    _ = request(fences, id: id) { continuation.resume(returning: $0) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(id) }
            }
        }

        func request(_ fences: [Fence], id: UUID = UUID(),
                     completion: @escaping @MainActor ([Int: Outcome]) -> Void) -> (@MainActor () -> Void) {
            guard backend != nil, !fences.isEmpty else {
                completion([:])
                return {}
            }
            var outcomes: [Int: Outcome] = [:]
            var pending: [Key: [Int]] = [:]
            for fence in fences {
                switch fence.admission {
                case .fallback(let reason): outcomes[fence.line] = .fallback(reason)
                case .key(let key):
                    if let outcome = lookup(key) {
                        outcomes[fence.line] = outcome
                    } else {
                        pending[key, default: []].append(fence.line)
                    }
                }
            }
            guard !pending.isEmpty else {
                completion(outcomes)
                return {}
            }
            guard consumers.count < maxConsumers else {
                for lines in pending.values {
                    for line in lines { outcomes[line] = .fallback("Mermaid renderer is busy.") }
                }
                completion(outcomes)
                return {}
            }
            consumers[id] = Consumer(pending: pending, outcomes: outcomes, completion: completion)
            // Preserve document order rather than dictionary iteration order in the render queue.
            for fence in fences {
                guard case .key(let key) = fence.admission, consumers[id]?.pending[key] != nil else { continue }
                if let job = jobs[key] {
                    job.consumers.insert(id)
                } else if queue.count < maxQueued {
                    let job = Job(key)
                    job.consumers.insert(id)
                    jobs[key] = job
                    queue.append(key)
                } else {
                    deliver(.fallback("Mermaid renderer is busy."), key: key, to: id)
                }
            }
            drain()
            return { [weak self] in self?.cancel(id) }
        }

        private func cancel(_ id: UUID) {
            guard let consumer = consumers.removeValue(forKey: id) else { return }
            for key in consumer.pending.keys {
                guard let job = jobs[key] else { continue }
                job.consumers.remove(id)
                guard job.consumers.isEmpty else { continue }
                jobs.removeValue(forKey: key)
                switch job.state {
                case .queued:
                    queue.removeAll { $0 == key }
                case .running(let attempt):
                    active -= 1
                    attempt.stop(aborting: true)
                }
            }
            consumer.completion(consumer.outcomes)
            drain()
        }

        private func drain() {
            guard !draining else { return }
            draining = true
            defer { draining = false }
            while active < 2, !queue.isEmpty, let backend {
                let key = queue.removeFirst()
                guard let job = jobs[key], case .queued = job.state else { continue }
                let prepared = backend as? any NoteMermaidPreparingBackend
                let attempt = Attempt(preparing: prepared != nil)
                active += 1
                job.state = .running(attempt)
                armDeadline(job, attempt: attempt)
                let completion: @MainActor (Outcome) -> Void = { [weak self, weak job, weak attempt] outcome in
                    guard let job, let attempt else { return }
                    self?.finish(job, attempt: attempt, outcome: outcome, timedOut: false)
                }
                let abort: @MainActor () -> Void
                if let prepared {
                    abort = prepared.start(key, ready: { [weak self, weak job, weak attempt] in
                        guard let self, let job, let attempt, self.isCurrent(job, attempt: attempt),
                              case .preparing = attempt.phase else { return }
                        attempt.phase = .rendering
                        self.armDeadline(job, attempt: attempt)
                    }, failed: { [weak self, weak job, weak attempt] reason in
                        guard let job, let attempt else { return }
                        self?.finish(job, attempt: attempt, outcome: .fallback(reason),
                                     timedOut: false, rendererFailed: true)
                    }, completion: completion)
                } else {
                    abort = backend.start(key, completion: completion)
                }
                if isCurrent(job, attempt: attempt) {
                    attempt.abort = abort
                } else if attempt.abortOnReturn {
                    abort()
                }
            }
        }

        private func isCurrent(_ job: Job, attempt: Attempt) -> Bool {
            guard jobs[job.key] === job, case .running(let current) = job.state else { return false }
            return current === attempt
        }

        private func armDeadline(_ job: Job, attempt: Attempt) {
            attempt.deadline?.cancel()
            let preparing = attempt.phase == .preparing
            let expires = ContinuousClock.now.advanced(by: .seconds(preparing ? 10 : 2))
            attempt.deadline = Task { @MainActor [weak self, weak job, weak attempt] in
                do { try await Task.sleep(until: expires, clock: .continuous) }
                catch { return }
                guard let job, let attempt, !Task.isCancelled else { return }
                let reason = preparing
                    ? "Mermaid renderer preparation timed out after 10 seconds."
                    : "Mermaid rendering timed out after 2 seconds."
                self?.finish(job, attempt: attempt, outcome: .fallback(reason), timedOut: true)
            }
        }

        private func finish(_ job: Job, attempt: Attempt, outcome: Outcome, timedOut: Bool,
                            rendererFailed: Bool = false) {
            guard isCurrent(job, attempt: attempt) else { return }
            let outcome = bounded(outcome)
            let retry = attempt.canRetry && job.retries == 0
                && (rendererFailed || (timedOut && attempt.phase == .preparing))
            let generation = self.generation
            active -= 1
            if retry {
                job.retries += 1
                job.state = .queued
                queue.append(job.key)
            } else {
                jobs.removeValue(forKey: job.key)
            }
            attempt.stop(aborting: timedOut)
            // Aborting may cancel the job or replace the backend through reentrant callers.
            if retry {
                drain()
                return
            }
            guard self.generation == generation,
                  job.consumers.contains(where: { consumers[$0] != nil }) else { return }
            store(outcome, for: job.key)
            for consumer in job.consumers { deliver(outcome, key: job.key, to: consumer) }
            drain()
        }

        private func deliver(_ outcome: Outcome, key: Key, to id: UUID) {
            guard var consumer = consumers.removeValue(forKey: id), let lines = consumer.pending.removeValue(forKey: key) else { return }
            for line in lines { consumer.outcomes[line] = outcome }
            if consumer.pending.isEmpty {
                consumer.completion(consumer.outcomes)
            } else {
                consumers[id] = consumer
            }
        }

        private func bounded(_ outcome: Outcome) -> Outcome {
            switch outcome {
            case .fallback(let reason):
                return .fallback(String(decoding: reason.utf8.prefix(1024), as: UTF8.self))
            case .image(let image):
                let size = image.size
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                      size.width <= CGFloat(maxDimension), size.height <= CGFloat(maxDimension),
                      !image.representations.isEmpty else { return .fallback("Mermaid returned an invalid image.") }
                var pixels = 0
                for representation in image.representations {
                    let width = representation.pixelsWide
                    let height = representation.pixelsHigh
                    guard width > 0, height > 0, width <= maxDimension, height <= maxDimension,
                          width * height <= maxPixels - pixels else { return .fallback("Mermaid image exceeds the raster limit.") }
                    pixels += width * height
                }
                return outcome
            }
        }

        private func lookup(_ key: Key) -> Outcome? {
            guard var entry = cache[key] else { return nil }
            access &+= 1
            entry.access = access
            cache[key] = entry
            return entry.outcome
        }

        private func store(_ outcome: Outcome, for key: Key) {
            var cost = 512 + key.source.utf8.count * 2
            switch outcome {
            case .fallback(let reason): cost += reason.utf8.count * 2
            case .image(let image):
                for representation in image.representations {
                    if let bitmap = representation as? NSBitmapImageRep {
                        let (raster, overflow) = bitmap.bytesPerRow.multipliedReportingOverflow(by: bitmap.pixelsHigh)
                        guard !overflow, raster >= 0, raster <= cacheBytes - min(cost, cacheBytes) else { return }
                        cost += raster
                    } else {
                        cost += representation.pixelsWide * representation.pixelsHigh * 4
                    }
                }
            }
            guard cost <= cacheBytes else { return }
            while bytes + cost > cacheBytes || cache.count >= maxCacheEntries {
                guard let oldest = cache.min(by: { $0.value.access < $1.value.access }) else { break }
                bytes -= oldest.value.bytes
                cache.removeValue(forKey: oldest.key)
            }
            access &+= 1
            cache[key] = CacheEntry(outcome: outcome, bytes: cost, access: access)
            bytes += cost
        }
    }
}
