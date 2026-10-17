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


    static func make(_ object: CanvasObject, board: Board, remote: RemoteSource? = nil) -> any TileContent {
        if let remote {
            switch object.type {
            case .terminal: return TerminalTile(object: object, board: board, attach: remote.attachCommand(for: object))
            case .note: return NoteTile(object: object, board: board)
            case .question: return QuestionTile(object: object, board: board)
            case .html: return HtmlTile(object: object, board: board, files: remote.files)
            case .image: return ImageTile(object: object, board: board, files: remote.files)
            case .code: return CodeTile(object: object, board: board, git: remote.git, languages: remote.languages)
            case .changes: return ChangesTile(object: object, board: board, git: remote.git)
            case .browser: return RemoteBrowserTile(object: object, remote: remote)
            case .diagram: return DiagramTile(object: object, board: board, remote: remote)
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
