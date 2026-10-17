import Foundation

@MainActor
final class RemoteReplayQueue {
    enum Outcome {
        case applied(ViewerReplay)
        case refused(String)
        case expired
        case interrupted
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
              case .update(_, _, let seen, _, _, _) = first.write, seen == before else { return }
        for index in writes.indices {
            guard case .update(let local, let step, let seen?, let frame, let z, let props) = writes[index].write,
                  target(local) == id else { continue }
            writes[index].write = .update(local, step: step, seen: seen + after - before, frame: frame, z: z, props: props)
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
