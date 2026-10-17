import Foundation

@MainActor
public final class HostFileWatch {
    private var task: Task<Void, Never>?

    public init(
        files: HostFiles,
        request: HostFileRequest,
        baseline: HostFileObservation? = nil,
        interval: Duration = .seconds(2),
        changed: @escaping @MainActor (HostFileObservation) -> Void
    ) {
        var metadata = request
        metadata.bytes = false
        task = Task { @MainActor [metadata] in
            var prior = baseline
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                let observation: HostFileObservation
                do {
                    observation = .version(try await files.read(metadata).version)
                } catch is CancellationError {
                    return
                } catch let error as HostFileError {
                    observation = .failure(error)
                } catch {
                    observation = .failure(.unavailable(String(describing: error)))
                }
                guard !Task.isCancelled else { return }
                if let prior, prior != observation {
                    changed(observation)
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
