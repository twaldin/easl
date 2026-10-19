import Foundation

public struct BoardCloseResult: Sendable {
    public struct Terminal: Sendable {
        public let id: ObjectID
        public let name: String

        init(_ object: CanvasObject) {
            id = object.id
            if let name = object.props["name"]?.string, !name.isEmpty {
                self.name = name
            } else if let title = object.props["title"]?.string, !title.isEmpty {
                name = title
            } else {
                name = "Terminal"
            }
        }

        var json: JSONValue { .object(["id": .string(id), "name": .string(name)]) }
    }

    public let board: BoardID
    public let root: String
    public let kept: [Terminal]
    public let ended: [Terminal]

    @MainActor
    public init(board: Board, ended: [CanvasObject] = []) {
        self.board = board.id
        root = board.root.path
        let endedIDs = Set(ended.map(\.id))
        kept = board.objects.values.filter { $0.type == .terminal && !endedIDs.contains($0.id) }
            .sorted { $0.id < $1.id }.map(Terminal.init)
        self.ended = ended.sorted { $0.id < $1.id }.map(Terminal.init)
    }

    var json: JSONValue {
        .object(["board": .string(board), "root": .string(root),
                 "kept": .array(kept.map(\.json)), "ended": .array(ended.map(\.json))])
    }
}

extension Board {
    /// A window opened during shutdown must not start the session again.
    public func beginEndingSession(_ id: ObjectID) {
        endingSessions.insert(id)
    }

    public func endEndingSession(_ id: ObjectID) {
        endingSessions.remove(id)
    }

    public func isEndingSession(_ id: ObjectID) -> Bool {
        endingSessions.contains(id)
    }
}
