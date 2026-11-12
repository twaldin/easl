import CanvasCore
import Foundation

enum SurfaceOwner: Hashable, Sendable {
    case socket(SocketServer.Connection)
    case link(EaslConnection.Origin)

    var diagnosticRoute: BrowserStreamDiagnostic.Route {
        switch self {
        case .socket: .socket
        case .link: .relay
        }
    }

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

struct SurfaceRefusal: Error {
    let reason: BrowserStreamDiagnostic.Reason
    let failure: ApiRouter.Failure
    let operation: BrowserStreamDiagnostic.Operation

    init(_ reason: BrowserStreamDiagnostic.Reason, _ failure: ApiRouter.Failure, operation: BrowserStreamDiagnostic.Operation = .resolve) {
        self.reason = reason
        self.failure = failure
        self.operation = operation
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

    func tile(_ id: ObjectID) throws(SurfaceRefusal) -> (board: BoardID, tile: BrowserTile) {
        func refusal(_ reason: BrowserStreamDiagnostic.Reason) -> SurfaceRefusal {
            SurfaceRefusal(reason, ApiRouter.Failure("unavailable", "browser tile \(id) is not open in a window"))
        }
        guard let board = registry.board(containing: id) else { throw refusal(.tile_missing) }
        guard let tile = tiles(board, id) else { throw refusal(.tile_unmounted) }
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

    func tile(_ id: ObjectID) throws(SurfaceRefusal) -> (board: BoardID, tile: BrowserTile) {
        func closed(_ reason: BrowserStreamDiagnostic.Reason) -> SurfaceRefusal {
            SurfaceRefusal(reason, ApiRouter.Failure("unavailable", "this board's window closed"))
        }
        func absent(_ reason: BrowserStreamDiagnostic.Reason) -> SurfaceRefusal {
            SurfaceRefusal(reason, ApiRouter.Failure("unavailable", "browser tile \(id)'s page doesn't run on this Mac"))
        }
        guard isOpen else { throw closed(.peer_closed) }
        guard let mirror, let canvas, let remote = canvas.remote else { throw closed(.window_closed) }
        guard let object = mirror.board?.objects[id] else { throw absent(.tile_missing) }
        guard object.type == .browser else { throw absent(.tile_not_browser) }
        guard remote.drawsPage(object) else { throw absent(.drawn_elsewhere) }
        guard let tile = canvas.tiles[id]?.content as? BrowserTile else { throw absent(.tile_unmounted) }
        return (mirror.sessionBoardID, tile)
    }

    func hears(_ event: String, on board: BoardID) -> Bool {
        heard.contains(event)
    }
}
