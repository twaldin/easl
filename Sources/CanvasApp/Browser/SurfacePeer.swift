import CanvasCore
import Foundation

enum SurfaceOwner: Hashable, Sendable {
    case socket(SocketServer.Connection)
    case link(EaslConnection.Origin)

    @discardableResult
    func send(_ line: EventLine, whileCurrent: (@Sendable () -> Bool)? = nil) -> Bool {
        switch self {
        case .socket(let connection): connection.send(encoded: line.line, whileCurrent: whileCurrent)
        case .link(let origin): origin.push(line, whileCurrent: whileCurrent)
        }
    }

    static func == (lhs: SurfaceOwner, rhs: SurfaceOwner) -> Bool {
        switch (lhs, rhs) {
        case (.socket(let a), .socket(let b)): a === b
        case (.link(let a), .link(let b)): a == b
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .socket(let connection): hasher.combine(ObjectIdentifier(connection))
        case .link(let origin): hasher.combine(origin)
        }
    }
}

@MainActor
protocol SurfacePeer {
    var owner: SurfaceOwner { get }
    var isOpen: Bool { get }
    func tile(_ id: ObjectID) throws -> (board: BoardID, tile: BrowserTile)
    func hears(_ event: String, on board: BoardID) -> Bool
}

@MainActor
struct SocketPeer: SurfacePeer {
    let connection: SocketServer.Connection
    let registry: BoardRegistry
    let tiles: (Board, ObjectID) -> BrowserTile?

    var owner: SurfaceOwner { .socket(connection) }

    var isOpen: Bool { connection.isOpen }

    func tile(_ id: ObjectID) throws -> (board: BoardID, tile: BrowserTile) {
        guard let board = registry.board(containing: id), let tile = tiles(board, id) else {
            throw ApiRouter.Failure("unavailable", "browser tile \(id) is not open in a window")
        }
        return (board.id, tile)
    }

    func hears(_ event: String, on board: BoardID) -> Bool {
        registry.subscribes(connection, to: event, on: board)
    }
}

@MainActor
struct RelayPeer: SurfacePeer {
    let origin: EaslConnection.Origin
    let heard: Set<String>
    private weak var mirror: BoardMirror?
    private weak var canvas: CanvasView?
    private let serving: Int?

    init(origin: EaslConnection.Origin, heard: Set<String>, mirror: BoardMirror, canvas: CanvasView) {
        self.origin = origin
        self.heard = heard
        self.mirror = mirror
        self.canvas = canvas
        serving = mirror.serving
    }

    var owner: SurfaceOwner { .link(origin) }

    var isOpen: Bool { origin.isOpen && serving != nil && mirror?.serving == serving }

    func tile(_ id: ObjectID) throws -> (board: BoardID, tile: BrowserTile) {
        guard isOpen, let mirror, let canvas, let remote = canvas.remote else {
            throw ApiRouter.Failure("unavailable", "this board's window closed")
        }
        guard let object = mirror.board?.objects[id], object.type == .browser, remote.drawsPage(object),
              let tile = canvas.tiles[id]?.content as? BrowserTile else {
            throw ApiRouter.Failure("unavailable", "browser tile \(id)'s page doesn't run on this Mac")
        }
        return (mirror.sessionBoardID, tile)
    }

    func hears(_ event: String, on board: BoardID) -> Bool {
        heard.contains(event)
    }
}
