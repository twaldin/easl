import Foundation

final class VideoAudioWorkQueue: @unchecked Sendable {
    private struct Pending {
        var order: [UUID] = []
        var work: [UUID: @Sendable () -> Void] = [:]
        var running = false
    }

    private let pending = Locked(Pending())
    private let queue = DispatchQueue(label: "easl.video.audio", qos: .userInitiated)

    func schedule(_ id: UUID, _ work: @escaping @Sendable () -> Void) {
        let start = pending.withLock { pending in
            if pending.work[id] == nil { pending.order.append(id) }
            pending.work[id] = work
            guard !pending.running else { return false }
            pending.running = true
            return true
        }
        if start { queue.async { [self] in drain() } }
    }

    func cancel(_ id: UUID) {
        pending.withLock { pending in
            pending.work[id] = nil
            pending.order.removeAll { $0 == id }
        }
    }

    private func drain() {
        while true {
            let work = pending.withLock { pending -> (@Sendable () -> Void)? in
                guard !pending.order.isEmpty else {
                    pending.running = false
                    return nil
                }
                return pending.work.removeValue(forKey: pending.order.removeFirst())
            }
            guard let work else { return }
            work()
        }
    }
}
