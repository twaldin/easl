import Foundation

enum HostFileReadResult: Sendable {
    case file(HostFile)
    case failure(HostFileError)
    case deferred
}

@MainActor
final class HostFileReads {
    private struct Pending {
        let request: HostFileRequest
        let payload: JSONValue
        let priority: HostReadPriority
        let files: HostFiles
        let continuation: CheckedContinuation<HostFile, Error>
        var batch: UUID?
    }

    private struct Batch {
        var members: Set<UUID>
        let command: Task<Void, Never>
    }

    private var pending: [UUID: Pending] = [:]
    private var waiting: [UUID] = []
    private var batches: [UUID: Batch] = [:]
    private var scheduled = false

    nonisolated init() {}

    func read(_ request: HostFileRequest, payload: JSONValue, files: HostFiles,
              priority: HostReadPriority) async throws -> HostFile {
        try Task.checkCancellation()
        let id = UUID()
        let file = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = Pending(request: request, payload: payload, priority: priority,
                                      files: files, continuation: continuation)
                waiting.append(id)
                if !scheduled {
                    scheduled = true
                    Task { [weak self] in
                        await Task.yield()
                        self?.flush()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
        try Task.checkCancellation()
        return file
    }

    private func flush() {
        scheduled = false
        let queued = waiting
        waiting = []
        for priority in [HostReadPriority.interactive, .visible, .background] {
            for bytes in [true, false] {
                let members = queued.filter { id in
                    guard let read = pending[id] else { return false }
                    return read.priority == priority && read.request.bytes == bytes
                }
                let limit = bytes ? 64 : 256
                for start in stride(from: 0, to: members.count, by: limit) {
                    begin(Array(members[start..<min(start + limit, members.count)]))
                }
            }
        }
    }

    private func begin(_ ids: [UUID]) {
        guard let first = ids.first, let files = pending[first]?.files,
              let priority = pending[first]?.priority else { return }
        let inputs = ids.compactMap { id -> (request: HostFileRequest, payload: JSONValue)? in
            guard let read = pending[id] else { return nil }
            return (read.request, read.payload)
        }
        let batch = UUID()
        for id in ids { pending[id]?.batch = batch }
        let command = Task { [self, files, priority, inputs, ids] in
            do {
                let results: [HostFileReadResult]
                if inputs.count == 1 {
                    results = [.file(try await files.readOne(inputs[0].request, payload: inputs[0].payload, priority: priority))]
                } else {
                    results = try await files.readBatch(inputs.map(\.payload), priority: priority)
                }
                complete(batch, ids: ids, result: .success(results))
            } catch {
                complete(batch, ids: ids, result: .failure(error))
            }
        }
        batches[batch] = Batch(members: Set(ids), command: command)
    }

    private func complete(_ batch: UUID, ids: [UUID], result: Result<[HostFileReadResult], Error>) {
        guard batches.removeValue(forKey: batch) != nil else { return }
        switch result {
        case .failure(let error):
            for id in ids {
                guard let read = pending.removeValue(forKey: id) else { continue }
                read.continuation.resume(throwing: error)
            }
        case .success(let results):
            for (id, result) in zip(ids, results) {
                guard let read = pending[id] else { continue }
                switch result {
                case .deferred:
                    begin([id])
                case .file(let file):
                    pending.removeValue(forKey: id)
                    read.continuation.resume(returning: file)
                case .failure(let error):
                    pending.removeValue(forKey: id)
                    read.continuation.resume(throwing: error)
                }
            }
        }
    }

    private func cancel(_ id: UUID) {
        guard let read = pending.removeValue(forKey: id) else { return }
        read.continuation.resume(throwing: CancellationError())
        guard let batch = read.batch else {
            waiting.removeAll { $0 == id }
            return
        }
        batches[batch]?.members.remove(id)
        if let active = batches[batch], active.members.isEmpty {
            batches.removeValue(forKey: batch)
            active.command.cancel()
        }
    }
}
