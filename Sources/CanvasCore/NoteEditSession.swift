import Foundation

/// One edit of a note's markdown by the user. A conflict is someone else changing the markdown
/// after the edit began; it is never resolved implicitly (clicking away, focus moving to a
/// terminal). Only an explicit confirmation, given while the conflict is shown, saves over it;
/// keeping theirs instead leaves the user's text one ⌘Z away (`keepTheirs`).
@MainActor
public final class NoteEditSession {
    public enum Outcome: Equatable {
        case saved
        case unchanged
        /// Not saved: the markdown changed under the edit and the user hasn't chosen to overwrite.
        case conflict
    }

    public let objectID: ObjectID
    /// The markdown the edit started from, or last saved.
    public private(set) var base: String
    public private(set) var conflicted = false
    /// Our own save echoes back as an update; it isn't someone else's change.
    private var writing = false

    public init(_ object: CanvasObject) {
        objectID = object.id
        base = object.props["markdown"]?.string ?? ""
    }

    /// A new revision of the note arrived while editing.
    public func observe(_ object: CanvasObject) {
        guard !writing, object.id == objectID, (object.props["markdown"]?.string ?? "") != base else { return }
        conflicted = true
    }

    /// Save `text`. `confirmed` is the user's explicit "save mine" (⌘↩); it overwrites only a
    /// conflict that was already shown, so a change detected at this very commit is shown first.
    public func commit(_ text: String, confirmed: Bool, on board: Board) throws -> Outcome {
        let current = try board.object(objectID)
        let theirs = current.props["markdown"]?.string ?? ""
        if theirs != base, !(conflicted && confirmed) {
            conflicted = true
            return .conflict
        }
        guard text != theirs else { return .unchanged }
        writing = true
        defer { writing = false }
        // Main-actor isolation makes the check and the write atomic; the current `rev` is passed
        // because a change that isn't to the markdown (a moved frame) is not a conflict.
        try board.update(objectID, rev: current.rev, props: .object(["markdown": .string(text)]))
        base = text
        conflicted = false
        return .saved
    }

    /// Esc with the conflict shown: their markdown stays, and the user's `text` becomes the
    /// board's latest undo step, as if theirs had replaced it: ⌘Z puts `text` over theirs, ⇧⌘Z
    /// theirs back. Remote recovery refuses if the markdown changed again. Returns whether
    /// there was anything of the user's to keep (an edit that changed nothing, or matches
    /// theirs, records nothing).
    @discardableResult
    public func keepTheirs(discarding text: String, on board: Board) -> Bool {
        guard let current = board.objects[objectID] else { return false }
        let theirs = current.props["markdown"]?.string ?? ""
        guard text != base, text != theirs else { return false }
        if board.isRemote {
            board.history.recordNoteRecovery(NoteRecovery(objectID: objectID, yours: text, theirs: theirs))
        } else {
            var yours = current
            yours.props = current.props.merging(.object(["markdown": .string(text)]))
            board.history.record(.updated(before: yours, after: current))
        }
        return true
    }
}

/// Unsubmitted text kept by a remote viewer. Undo replaces `theirs` with `yours`; redo replaces
/// `yours` with `theirs`, each guarded against the host's current note revision and markdown.
public struct NoteRecovery: Equatable, Sendable {
    public let objectID: ObjectID
    public let yours: String
    public let theirs: String

    public init(objectID: ObjectID, yours: String, theirs: String) {
        self.objectID = objectID
        self.yours = yours
        self.theirs = theirs
    }
}
