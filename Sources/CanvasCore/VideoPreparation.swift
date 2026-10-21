import Foundation

@MainActor
public final class VideoPreparation<Value: Sendable> {
    public enum State: Equatable, Sendable {
        case idle
        case preparing
        case ready
        case failed(String)
    }

    public private(set) var state: State = .idle
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    public init() {}

    deinit { task?.cancel() }

    @discardableResult
    public func start(_ prepare: @escaping @Sendable () async throws -> Value,
                      completion: @escaping @MainActor (Result<Value, Error>) -> Void) -> Task<Void, Never> {
        cancel()
        let generation = generation
        state = .preparing
        let task = Task.detached { [weak self] in
            let result: Result<Value, Error>
            do {
                let value = try await prepare()
                try Task.checkCancellation()
                result = .success(value)
            } catch {
                guard !Task.isCancelled else { return }
                result = .failure(error)
            }
            await self?.finish(result, generation: generation, completion: completion)
        }
        self.task = task
        return task
    }

    public func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        state = .idle
    }

    private func finish(_ result: Result<Value, Error>, generation: UInt64,
                        completion: @MainActor (Result<Value, Error>) -> Void) {
        guard self.generation == generation else { return }
        task = nil
        switch result {
        case .success: state = .ready
        case .failure(let error): state = .failed(error.localizedDescription)
        }
        completion(result)
    }
}
