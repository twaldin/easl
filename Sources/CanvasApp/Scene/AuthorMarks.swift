import AppKit
import CanvasCore

/// Creation-time names stay fixed. Objects without a snapshot retain legacy live resolution.
extension CanvasView {
    /// The name `object`'s author mark shows, nil for none (and while the chrome is hidden).
    func authorName(of object: CanvasObject) -> String? {
        guard !chromeHidden else { return nil }
        return AuthorMark.name(of: object, in: board.objects) { [tiles] in (tiles[$0]?.content as? TerminalTile)?.program }
    }

    /// Shows `id`'s author mark as it is now.
    func syncAuthor(_ id: ObjectID) {
        guard let object = board.objects[id] else { return }
        let name = authorName(of: object)
        if object.type == .group { groups[id]?.author = name } else { tiles[id]?.setAuthor(name) }
    }

    /// The marks of `terminal`'s agent's objects, when the name they show changed (a rename, a
    /// new program, the terminal came or went). Cheap when it didn't: called on every retitle.
    func syncAuthors(of terminal: ObjectID) {
        let name = board.objects[terminal].flatMap { object in
            object.type == .terminal ? AuthorMark.name(of: object, program: (tiles[terminal]?.content as? TerminalTile)?.program) : nil
        }
        guard name != authorNames[terminal] else { return }
        authorNames[terminal] = name
        for object in board.objects.values where object.authorName == nil && object.createdBy == .agent(tile: terminal) { syncAuthor(object.id) }
    }
}
