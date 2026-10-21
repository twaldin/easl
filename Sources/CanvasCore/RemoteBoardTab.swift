import Foundation

@MainActor
public struct RemoteBoardTab {
    /// The app's host-and-board key, including the host's socket path.
    public let id: String
    public let info: OpenedRemoteBoard
    public let board: Board
    /// False for a background attachment whose tab has closed.
    public let isOpen: Bool
    public let request: (String, JSONValue) async throws -> JSONValue

    public init(id: String, info: OpenedRemoteBoard, board: Board, isOpen: Bool,
                request: @escaping (String, JSONValue) async throws -> JSONValue) {
        self.id = id
        self.info = info
        self.board = board
        self.isOpen = isOpen
        self.request = request
    }
}
