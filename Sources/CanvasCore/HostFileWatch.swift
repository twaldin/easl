import Foundation

/// A live remote tile's poll of its host (docs/design.md "Client mode"): every `interval`, one
/// metadata-only probe, and `changed` when its observation differs from the one before, starting
/// from the observation taken with the bytes the tile shows. A failed probe is an observation
/// too, so the first success after it reloads. Runs until cancelled or dropped.
/// Probes run off the main actor; change notifications are delivered on it.
@MainActor
public final class HostFileWatch {
    private var task: Task<Void, Never>?

    public convenience init(
        files: HostFiles,
        request: HostFileRequest,
        baseline: HostFileObservation? = nil,
        interval: Duration = .seconds(2),
        changed: @escaping @MainActor (HostFileObservation) -> Void
    ) {
        var metadata = request
        metadata.bytes = false
        self.init(baseline: baseline, interval: interval, probe: { [metadata] in
            do {
                return .version(try await files.read(metadata, priority: .background).version)
            } catch is CancellationError {
                return nil
            } catch let error as HostFileError {
                return .failure(error)
            } catch {
                return .failure(.unavailable(String(describing: error)))
            }
        }, changed: changed)
    }

    /// A nil `probe` result skips that poll without replacing the prior observation.
    /// Polling continues at `interval` until cancelled or dropped.
    public init<Observation: Equatable & Sendable>(
        baseline: Observation?,
        interval: Duration = .seconds(2),
        probe: @escaping @Sendable () async -> Observation?,
        changed: @escaping @MainActor (Observation) -> Void
    ) {
        task = Task.detached(priority: Task.currentPriority) {
            var prior = baseline
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                let observation = await probe()
                guard !Task.isCancelled else { return }
                guard let observation else { continue }
                if let prior, prior != observation {
                    await MainActor.run {
                        if !Task.isCancelled { changed(observation) }
                    }
                }
                prior = observation
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
