import AppKit
import CanvasCore

/// Maps an object type to its tile content view. Arrows, shapes, and groups are drawn by the
/// canvas itself and have no tile.
@MainActor
enum TileFactory {
    static func hasTile(_ type: ObjectType) -> Bool {
        ![.arrow, .shape, .group].contains(type)
    }

    /// An object whose tile the board doesn't show: an archived question (`QuestionSpec.archived`).
    static func hidden(_ object: CanvasObject) -> Bool {
        object.type == .question && QuestionSpec(object.props).archived
    }

    /// On a remote board (`remote`), terminals attach to the host's sessions and the tiles drawn
    /// from the host's files or pages show the host's rendering (docs/design.md "Client mode").
    static func make(_ object: CanvasObject, board: Board, remote: RemoteSource? = nil) -> any TileContent {
        if let remote {
            switch object.type {
            case .terminal: return TerminalTile(object: object, board: board, attach: remote.attachCommand(for: object.id))
            case .note: return NoteTile(object: object, board: board)
            case .question: return QuestionTile(object: object, board: board)
            case .code, .changes, .html, .browser, .image, .diagram: return RemoteImageTile(object: object, remote: remote)
            default: return CardTile(object: object)
            }
        }
        return switch object.type {
        case .terminal: TerminalTile(object: object, board: board)
        case .code: CodeTile(object: object, board: board)
        case .note: NoteTile(object: object, board: board)
        case .browser: BrowserTile(object: object, board: board)
        case .html: HtmlTile(object: object, board: board)
        case .changes: ChangesTile(object: object, board: board)
        case .image: ImageTile(object: object, board: board)
        case .diagram: DiagramTile(object: object, board: board)
        case .question: QuestionTile(object: object, board: board)
        default: CardTile(object: object)
        }
    }
}
