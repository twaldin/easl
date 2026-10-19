import Foundation

@MainActor
public final class RemoteUpdateActivity {
    public static let shared = RemoteUpdateActivity()

    public enum Kind: String, Sendable {
        case browser, board, terminal
    }

    private struct Session {
        let kind: Kind
        let board: BoardID
        let tile: ObjectID?
        let isLive: (@MainActor () -> Bool)?
    }

    private var live: [String: Session] = [:]
    private var latestActivity: TimeInterval?

    public init() {}

    public func begin(session: String, kind: Kind, board: BoardID, tile: ObjectID? = nil,
                      isLive: (@MainActor () -> Bool)? = nil) {
        live[session] = Session(kind: kind, board: board, tile: tile, isLive: isLive)
    }

    public func record(session: String, kind: Kind, board: BoardID, tile: ObjectID? = nil,
                       now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                       isLive: (@MainActor () -> Bool)? = nil) {
        begin(session: session, kind: kind, board: board, tile: tile, isLive: isLive)
        latestActivity = max(latestActivity ?? now, now)
    }

    public func end(session: String) {
        live[session] = nil
    }

    public func idleSeconds(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        sweep()
        guard let latestActivity else { return AppUpdate.automaticIdleThreshold }
        return max(0, now - latestActivity)
    }

    public var sessions: JSONValue {
        sweep()
        return .array(live.keys.sorted().map { id in
            let session = live[id]!
            return .object([
                "session": .string(id),
                "kind": .string(session.kind.rawValue),
                "board": .string(session.board),
                "tile": session.tile.map(JSONValue.string) ?? .null,
            ])
        })
    }

    private func sweep() {
        for (id, session) in live where session.isLive?() == false {
            live[id] = nil
        }
    }
}
