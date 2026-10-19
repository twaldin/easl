import Foundation

public enum SurfaceLinkMode: Sendable, Equatable {
    case probing, jpeg, video
}

public struct SurfaceFrameFlow: Sendable {
    public enum State: Sendable, Equatable {
        case outstanding(frame: Int, refinement: Bool, sentAt: TimeInterval?)
        case granted(next: Int)
    }

    public enum Acknowledgement: Sendable, Equatable {
        case stale, invalid
        case granted
    }

    public private(set) var state: State = .outstanding(frame: 0, refinement: false, sentAt: nil)
    public private(set) var mode: SurfaceLinkMode
    private var superseded: Int?
    private var probeFrames = 0
    private var fastestAcknowledgement = TimeInterval.infinity

    public init(adaptive: Bool) {
        mode = adaptive ? .probing : .video
    }

    public var next: Int? {
        if case .granted(let next) = state { return next }
        return nil
    }

    public mutating func acknowledge(_ frame: Int, at now: TimeInterval) -> Acknowledgement {
        switch state {
        case .outstanding(let sent, let refinement, let sentAt):
            guard frame <= sent else { return .invalid }
            guard frame == sent else { return .stale }
            if mode == .probing, !refinement, let sentAt {
                probeFrames += 1
                fastestAcknowledgement = min(fastestAcknowledgement, now - sentAt)
                if probeFrames == 3 { mode = fastestAcknowledgement < 0.04 ? .jpeg : .video }
            }
            state = .granted(next: sent + 1)
            superseded = nil
            return .granted
        case .granted(let next):
            return frame < next ? .stale : .invalid
        }
    }

    public mutating func supersedeRefinement() -> Bool {
        guard case .outstanding(let frame, true, _) = state else { return false }
        state = .granted(next: frame + 1)
        superseded = min(superseded ?? frame, frame)
        return true
    }

    public mutating func publish(_ frame: Int, refinement: Bool, at now: TimeInterval) -> Int? {
        precondition(next == frame)
        let skipped = superseded
        state = .outstanding(frame: frame, refinement: refinement, sentAt: now)
        return skipped
    }
}

public final class SurfaceInputRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0

    public init() {}

    public var value: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    public func advance() {
        lock.lock()
        revision &+= 1
        lock.unlock()
    }
}
