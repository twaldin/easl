import Foundation

@MainActor
final class RemoteReplayQueue {
    enum Outcome {
        case applied(ViewerReplay)
        case refused(String)
        case expired
        case interrupted
    }

    private final class PromptReceipt {
        let params: [String: JSONValue]
        let connection: EaslConnection
        let continuation: CheckedContinuation<Void, Error>
        let changed: (BoardMirror.PromptDelivery) -> Void
        var task: Task<Void, Never>?

        init(params: [String: JSONValue], connection: EaslConnection,
             continuation: CheckedContinuation<Void, Error>,
             changed: @escaping (BoardMirror.PromptDelivery) -> Void) {
            self.params = params
            self.connection = connection
            self.continuation = continuation
            self.changed = changed
        }
    }

    private var promptReceipts: [String: PromptReceipt] = [:]
    private var promptReconciliationStopped = false

    func reconcilePrompt(_ params: [String: JSONValue], connection: EaslConnection,
                         changed: @escaping (BoardMirror.PromptDelivery) -> Void) async throws {
        let id = params["submission"]?["id"]?.string ?? ""
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !promptReconciliationStopped else {
                changed(.unknown)
                continuation.resume(throwing: BoardMirror.PromptOutcomeUnknown())
                return
            }
            let receipt = PromptReceipt(params: params, connection: connection,
                                        continuation: continuation, changed: changed)
            promptReceipts[id] = receipt
            changed(.checking)
            checkPrompt(id, receipt)
        }
    }

    func promptConnectionChanged(_ state: EaslConnection.State) {
        guard state == .online else { return }
        for (id, receipt) in promptReceipts { checkPrompt(id, receipt) }
    }

    func stopPromptReconciliation() {
        promptReconciliationStopped = true
        for receipt in promptReceipts.values {
            receipt.task?.cancel()
            receipt.changed(.unknown)
            receipt.continuation.resume(throwing: BoardMirror.PromptOutcomeUnknown())
        }
        promptReceipts.removeAll()
    }

    private func checkPrompt(_ id: String, _ receipt: PromptReceipt) {
        guard !promptReconciliationStopped, receipt.task == nil, receipt.connection.state == .online else { return }
        receipt.task = Task {
            defer { receipt.task = nil }
            var params = receipt.params
            params["reconcile"] = .bool(true)
            while !Task.isCancelled {
                let result: JSONValue
                do {
                    result = try await receipt.connection.request("agent.prompt", .object(params), timeout: .seconds(30))
                } catch let failure as EaslConnection.Failure where failure.isHostResponse {
                    receipt.changed(.unknown)
                    return
                } catch {
                    guard !promptReconciliationStopped else { return }
                    receipt.changed(.checking)
                    guard receipt.connection.state == .online else { return }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    continue
                }
                guard !promptReconciliationStopped else { return }
                switch result["delivery"]?.string {
                case "pending":
                    receipt.changed(.checking)
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                case "unknown":
                    receipt.changed(.unknown)
                    return
                case "not-delivered":
                    promptReceipts.removeValue(forKey: id)
                    receipt.changed(.notDelivered)
                    receipt.continuation.resume(throwing: ApiRouter.Failure(
                        result["error"]?["code"]?.string ?? "not_delivered",
                        result["error"]?["message"]?.string ?? "The host confirmed this prompt was not delivered."))
                    return
                case "typed", "message":
                    promptReceipts.removeValue(forKey: id)
                    receipt.changed(.delivered)
                    receipt.continuation.resume()
                    return
                default:
                    receipt.changed(.unknown)
                    return
                }
            }
        }
    }

    private struct Redo {
        var made: Int
        var steps: [UndoHistory.Step]
    }

    private var asked = 0
    private var answered = 0
    private var writes: [(write: RemoteWrite, after: Int)] = []
    private var redoSnapshot: Redo?
    private(set) var last: Task<String?, Never>?

    private var pending: Bool { answered < asked }

    func hold(_ write: RemoteWrite) -> Bool {
        guard pending else { return false }
        writes.append((write, asked))
        return true
    }

    func containsWrite(where matches: (RemoteWrite) -> Bool) -> Bool {
        writes.contains { matches($0.write) }
    }

    func discardWrites() -> [RemoteWrite] {
        let discarded = writes.map(\.write)
        writes.removeAll()
        return discarded
    }

    func enqueue(on board: Board?, redo: Bool, hostName: String,
                 perform: @escaping @MainActor (UndoHistory.Step) async -> Outcome,
                 release: @escaping @MainActor ([RemoteWrite]) -> Void) -> Task<String?, Never> {
        if !pending, let board { redoSnapshot = Redo(made: board.history.lastID, steps: board.history.redoSteps) }
        asked += 1
        let ticket = asked, made = board?.history.lastID ?? 0, previous = last
        let task = Task { () -> String? in
            _ = await previous?.value
            defer {
                answered = ticket
                let ready = writes.filter { $0.after <= ticket }.map(\.write)
                writes.removeAll { $0.after <= ticket }
                release(ready)
                if !pending { redoSnapshot = nil }
            }
            guard let board else { return nil }
            if made > (redoSnapshot?.made ?? made) { redoSnapshot = Redo(made: made, steps: []) }
            guard let step = (redo ? redoSnapshot?.steps ?? [] : board.history.undoSteps).last(where: { $0.id <= made }) else { return nil }
            let outcome = await perform(step)
            switch outcome {
            case .applied(let reply):
                let replayed = board.reconcile(reply, asked: step, redo: redo)
                if redo {
                    if let id = reply.step {
                        redoSnapshot?.steps.removeAll { $0.id == id }
                    } else {
                        redoSnapshot?.steps.removeAll { $0.changesBoard }
                    }
                } else if reply.pushed, let replayed {
                    redoSnapshot?.steps.append(replayed)
                }
                if !step.changesBoard, !reply.retired { return step.notice(redo: redo, author: board.authorName(step.author)) }
                return notice(of: reply, step: replayed, redo: redo, on: board, hostName: hostName)
            case .refused(let reason):
                return reason
            case .expired:
                board.history.remove(redo: redo) { $0.changesBoard && $0.id <= step.id }
                redoSnapshot?.steps.removeAll { $0.changesBoard && $0.id <= step.id }
                return "Couldn't \(redo ? "redo" : "undo"): \(hostName) no longer keeps that change"
            case .interrupted:
                return nil
            }
        }
        last = task
        return task
    }

    func rebase(_ id: ObjectID, from before: Int, to after: Int, target: (ObjectID) -> ObjectID?) {
        guard let first = writes.first(where: { target($0.write.object) == id }),
              case .update(_, _, let seen, _, _, _, _) = first.write, seen == before else { return }
        for index in writes.indices {
            guard case .update(let local, let step, let seen?, let frame, let z, let props, let expires) = writes[index].write,
                  target(local) == id else { continue }
            writes[index].write = .update(local, step: step, seen: seen + after - before, frame: frame, z: z, props: props, expires: expires)
        }
    }

    private func notice(of reply: ViewerReplay, step: UndoHistory.Step?, redo: Bool, on board: Board, hostName: String) -> String {
        let done = redo ? "redone" : "undone"
        guard reply.step != nil else { return "Nothing to \(redo ? "redo" : "undo") on \(hostName)" }
        if reply.retired { return "Couldn't \(redo ? "redo" : "undo"): \(hostName) no longer keeps the outcome of that request" }
        guard !reply.changed.isEmpty || !reply.deleted.isEmpty else {
            return reply.kept.isEmpty ? "Nothing \(done): what it changed is gone" : "Nothing \(done): everything it touched changed since"
        }
        let summary = step.map(\.summary).flatMap { $0.isEmpty ? nil : $0 } ?? "a change on \(hostName)"
        let author = step.flatMap { board.authorName($0.author) }.map { "\($0): " } ?? ""
        var text = "\(redo ? "Redid" : "Undid") \(author)\(summary)"
        if !reply.kept.isEmpty { text += " · kept \(reply.kept.count) someone changed since" }
        if reply.pushed { text += redo ? " · ⌘Z undoes" : " · ⇧⌘Z redoes" }
        return text
    }
}
